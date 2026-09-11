//! The `Vault` facade (spec §12 item 1.11's prerequisite): the one API a
//! platform app actually calls — open/create a vault, list and manage
//! keys, sign, and handle the CTAP2/custom-protocol requests — built by
//! composing every other module in this crate (`container`, `kdf`,
//! `aead`, `manifest`, `keys`, `keyblob`, `master_blob`, `retention`,
//! `throttle`, `merge`, `protocol`, `ctap2`). No platform may bypass this
//! module to call those lower-level modules directly for anything this
//! facade already covers (spec §2's "sole implementation" constraint
//! exists precisely so this surface can be the single UniFFI-exported
//! entry point).
//!
//! ## What is, and is not, in scope here
//!
//! In scope, and implemented below: vault create/open, compartment
//! unlock/lock (spec §4.1's multi-compartment model), the §5.1 core key
//! operations (list/create/discard/change-passphrase/reveal), a
//! retention-cache-backed signing primitive, the custom local-signing
//! protocol (§7) and CTAP2 (§6.6) request handlers wired to real vault
//! state instead of the test-only fakes in `protocol.rs`/`ctap2.rs`, the
//! §5.3 three-way import merge applied against an *already-decrypted*
//! incoming manifest, and — via `packet.rs` — §5.2's export/import
//! packets (`.vltkey`/`.vltpack`, all three transfer-encryption options)
//! and §5.4's backup flows (which are just `export_packet` called with
//! every key, or with none for the "master key only" shortcut).
//!
//! ## Passphrase prompting crosses the FFI boundary
//!
//! `protocol::SigningBackend`/`ctap2::Ctap2Backend`'s doc comments say the
//! real implementation "shows the same password-prompt UI" — that UI is
//! inherently native (a window, screen-capture-blocked per spec §5.0) and
//! cannot live in this crate. Rather than reimplementing that prompt once
//! per platform (which would violate spec §2's "no parallel logic"
//! spirit for exactly the parts that *can* be shared), the retention
//! cache is the shared state: if a key's material is already cached,
//! signing needs no prompt at all; otherwise [`PassphrasePrompter`] — a
//! UniFFI foreign-implemented trait — is invoked synchronously so the
//! platform can show its native dialog and hand back what the user typed
//! (or `None` for cancel). Every byte of crypto, parsing, and protocol
//! dispatch stays in this crate either way.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use uuid::Uuid;

use ctap_types::ctap2::{self as ctap2_wire, get_assertion, make_credential};

use crate::ctap2::{self, Ctap2Backend, CredentialCandidate};
use crate::error::VaultError;
use crate::kdf::{self, DeviceProfile, KdfParams};
use crate::keyblob::{self, KeyBlob};
use crate::keys::{self};
use crate::manifest::{Fido2Info, KeyEntry, KeyType, Manifest, Purpose};
use crate::master_blob;
use crate::merge::{self, DuplicateReason, DuplicateWarning, VaultCompartment};
use crate::packet::{self, EmbeddedMasterKey, ExportEncryption};
use crate::protocol::{self, PublicKeyInfo, SignOutcome, SigningBackend};
use crate::retention::RetentionCache;
use crate::throttle::{SecretId, ThrottleTracker};

/// Errors surfaced across the facade. Wraps every internal error as an
/// opaque message (never key material or passphrases, same invariant as
/// [`VaultError`] itself) — kept as a single "flat" variant rather than
/// mirroring every [`VaultError`] case 1:1 so adding a new internal error
/// variant is never a breaking FFI change.
#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
#[cfg_attr(feature = "uniffi", uniffi(flat_error))]
pub enum FacadeError {
    #[error("{0}")]
    Failed(String),
}

impl From<VaultError> for FacadeError {
    fn from(e: VaultError) -> Self {
        FacadeError::Failed(e.to_string())
    }
}

impl FacadeError {
    fn msg(s: impl Into<String>) -> Self {
        FacadeError::Failed(s.into())
    }
}

type FacadeResult<T> = std::result::Result<T, FacadeError>;

/// Which device-class KDF target to benchmark against when a vault or
/// compartment is created (spec §4.2). Mirrors [`DeviceProfile`] as a
/// UniFFI-exportable type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum FacadeDeviceProfile {
    Desktop,
    Mobile,
}

impl From<FacadeDeviceProfile> for DeviceProfile {
    fn from(p: FacadeDeviceProfile) -> Self {
        match p {
            FacadeDeviceProfile::Desktop => DeviceProfile::Desktop,
            FacadeDeviceProfile::Mobile => DeviceProfile::Mobile,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum FacadeKeyType {
    Ed25519,
    EcdsaP256,
}

impl From<FacadeKeyType> for KeyType {
    fn from(t: FacadeKeyType) -> Self {
        match t {
            FacadeKeyType::Ed25519 => KeyType::Ed25519,
            FacadeKeyType::EcdsaP256 => KeyType::EcdsaP256,
        }
    }
}

impl From<KeyType> for FacadeKeyType {
    fn from(t: KeyType) -> Self {
        match t {
            KeyType::Ed25519 => FacadeKeyType::Ed25519,
            KeyType::EcdsaP256 => FacadeKeyType::EcdsaP256,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum FacadePurpose {
    Fido2,
    CustomSigning,
    Both,
}

impl From<FacadePurpose> for Purpose {
    fn from(p: FacadePurpose) -> Self {
        match p {
            FacadePurpose::Fido2 => Purpose::Fido2,
            FacadePurpose::CustomSigning => Purpose::CustomSigning,
            FacadePurpose::Both => Purpose::Both,
        }
    }
}

impl From<Purpose> for FacadePurpose {
    fn from(p: Purpose) -> Self {
        match p {
            Purpose::Fido2 => FacadePurpose::Fido2,
            Purpose::CustomSigning => FacadePurpose::CustomSigning,
            Purpose::Both => FacadePurpose::Both,
        }
    }
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CompartmentInfo {
    pub compartment_id: String,
    pub label: String,
    pub unlocked: bool,
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Fido2InfoView {
    pub rp_id: String,
    pub credential_id_b64: String,
    pub user_handle_b64: String,
    pub sign_count: u32,
    pub discoverable: bool,
}

impl From<&Fido2Info> for Fido2InfoView {
    fn from(f: &Fido2Info) -> Self {
        Self {
            rp_id: f.rp_id.clone(),
            credential_id_b64: f.credential_id_b64.clone(),
            user_handle_b64: f.user_handle_b64.clone(),
            sign_count: f.sign_count,
            discoverable: f.discoverable,
        }
    }
}

/// Everything §5.1's "View list" is allowed to show — never raw key
/// material, and `public_key_hex` is non-secret (see `manifest.rs`).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct KeyInfo {
    pub key_id: String,
    pub compartment_id: String,
    pub label: String,
    pub description: String,
    pub resource: String,
    pub key_type: FacadeKeyType,
    pub purpose: FacadePurpose,
    pub fido2: Option<Fido2InfoView>,
    pub created_at: String,
    pub last_used_at: Option<String>,
    pub tags: Vec<String>,
    pub public_key_hex: String,
}

fn key_info_view(compartment_id: Uuid, entry: &KeyEntry) -> KeyInfo {
    KeyInfo {
        key_id: entry.key_id.to_string(),
        compartment_id: compartment_id.to_string(),
        label: entry.label.clone(),
        description: entry.description.clone(),
        resource: entry.resource.clone(),
        key_type: entry.key_type.into(),
        purpose: entry.purpose.into(),
        fido2: entry.fido2.as_ref().map(Fido2InfoView::from),
        created_at: entry
            .created_at
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_default(),
        last_used_at: entry
            .last_used_at
            .and_then(|t| t.format(&time::format_description::well_known::Rfc3339).ok()),
        tags: entry.tags.clone(),
        public_key_hex: entry.public_key_hex.clone(),
    }
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DuplicateWarningInfo {
    pub incoming_key_id: String,
    pub matched_local_key_id: String,
    pub matched_in_compartment: String,
    pub reason: String,
}

impl From<&DuplicateWarning> for DuplicateWarningInfo {
    fn from(w: &DuplicateWarning) -> Self {
        Self {
            incoming_key_id: w.incoming_key_id.to_string(),
            matched_local_key_id: w.matched_local_key_id.to_string(),
            matched_in_compartment: w.matched_in_compartment.to_string(),
            reason: match &w.reason {
                DuplicateReason::KeyId => "key_id".to_string(),
                DuplicateReason::Fido2Credential { rp_id, credential_id_b64 } => {
                    format!("fido2:{rp_id}:{credential_id_b64}")
                }
            },
        }
    }
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct IdRemapEntry {
    pub old_key_id: String,
    pub new_key_id: String,
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct MergeOutcomeInfo {
    pub warnings: Vec<DuplicateWarningInfo>,
    pub id_remap: Vec<IdRemapEntry>,
}

/// One incoming `.kblob`'s raw bytes to copy in verbatim (spec §5.3.4:
/// "incoming per-key blobs are copied ... unchanged"), keyed by the
/// **post-rename** key_id ([`MergeOutcomeInfo::id_remap`] maps back to
/// whatever key_id the packet originally used).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct IncomingKeyBlob {
    pub key_id: String,
    pub blob_bytes: Vec<u8>,
}

/// Spec §5.2.2's three export-encryption choices, as a UniFFI-exportable
/// type (mirrors [`ExportEncryption`], which borrows its password to
/// avoid an extra clone internally — this owned version is what crosses
/// the FFI boundary).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum FacadeExportEncryption {
    /// Option 1: "Just package the keys as-is" — the manifest fragment
    /// travels in the clear; the UI must disclose this (spec §5.2.2).
    AsIs,
    /// Option 2: "Re-encrypt for the destination vault's master
    /// password" — the exporter already knows it (spec §5.2.2: "choose
    /// this only if you know the master password of the vault you're
    /// importing into").
    DestinationMasterPassword { password: String },
    /// Option 3: "Protect with a one-time transfer password".
    OneTimeTransferPassword { password: String },
}

/// What [`Vault::import_packet`] found, before any merge decision is
/// made — spec §5.3 step 2's "inspect the packet's manifest fragment."
/// `manifest_json` is a full, validatable [`Manifest`] (a fresh
/// `vault_id`/`created_at` synthesized around the packet's key list) so
/// it can be passed directly to `Vault::merge_*` unchanged.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ImportedPacketInfo {
    pub manifest_json: String,
    pub key_blobs: Vec<IncomingKeyBlob>,
    /// Present iff the packet was exported with "include master key"
    /// on (spec §5.2.1) — triggers spec §5.3's unskippable
    /// master-key-duality screen. Only the KDF params are surfaced
    /// (not the still-encrypted blob bytes): `Vault::merge_*` re-derives
    /// rather than decrypting this blob, so that's all a caller needs to
    /// drive the three duality options.
    pub embedded_master_compartment_id: Option<String>,
    pub embedded_master_kdf_params_json: Option<String>,
}

/// A platform-supplied UI hook for prompting the user for a per-key
/// passphrase mid-request (spec §5.5 throttling, §7 custom protocol, §6.6
/// CTAP2): implemented natively per platform (a password dialog with
/// screen-capture blocking, spec §5.0). Returning `None` means the user
/// declined/cancelled — never returns wrong-vs-right, since verifying the
/// passphrase against real key material is this crate's job, not the
/// prompter's.
#[cfg_attr(feature = "uniffi", uniffi::export(with_foreign))]
pub trait PassphrasePrompter: Send + Sync {
    fn prompt(&self, caller_identity: String, key_id: String) -> Option<String>;
}

/// A compartment's state while unlocked: the plaintext manifest plus the
/// Argon2id-derived master key (never the raw passphrase) needed to
/// re-encrypt it after a mutation. Caching the derived key rather than
/// the passphrase means a mutation never needs to re-prompt for the
/// master password, while still never retaining the passphrase itself
/// beyond the moment it was typed. Wiped on lock via `HashMap::remove`
/// dropping this struct, whose `Zeroizing` field zeroes on drop.
struct UnlockedCompartment {
    manifest: Manifest,
    master_key: zeroize::Zeroizing<[u8; kdf::DERIVED_KEY_LEN]>,
}

struct VaultState {
    container: crate::container::Container,
    unlocked: HashMap<Uuid, UnlockedCompartment>,
}

/// The facade object every platform binds to. Thread-safe (a `Mutex`
/// around all mutable state) since UniFFI objects are shared as `Arc` and
/// may be called from multiple native threads (e.g. the CTAP2 extension
/// and the custom-protocol listener running concurrently).
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct Vault {
    path: PathBuf,
    state: Mutex<VaultState>,
    retention: RetentionCache,
    throttle: ThrottleTracker,
}

const DEFAULT_KEY_RETENTION_SECS: u32 = crate::retention::DEFAULT_RETENTION_SECS;

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl Vault {
    /// Create a brand-new `.vlt` at `path` with a single compartment,
    /// benchmarking Argon2id params for `profile` (spec §4.2) and writing
    /// the container atomically (spec §4.6). Fails if `path` already
    /// exists and parses as a container.
    #[cfg_attr(feature = "uniffi", uniffi::constructor)]
    pub fn create(
        path: String,
        compartment_label: String,
        master_passphrase: String,
        profile: FacadeDeviceProfile,
    ) -> FacadeResult<std::sync::Arc<Self>> {
        let path = PathBuf::from(path);
        let compartment_id = Uuid::new_v4();
        let kdf_params = kdf::benchmark(profile.into())?;
        let manifest = Manifest::new(Uuid::new_v4());
        let master_key = kdf::derive(master_passphrase.as_bytes(), &kdf_params)?;

        let mut container = crate::container::Container::new();
        container.header.compartments.push(crate::container::CompartmentHeader {
            compartment_id,
            label: compartment_label,
            kdf_params_master: kdf_params,
        });
        let blob = master_blob::encrypt_with_key(compartment_id, manifest.clone(), &master_key)?;
        container.master_blobs.insert(compartment_id, blob);
        container.write_atomic(&path)?;

        let mut unlocked = HashMap::new();
        unlocked.insert(compartment_id, UnlockedCompartment { manifest, master_key });

        Ok(std::sync::Arc::new(Self {
            path,
            state: Mutex::new(VaultState { container, unlocked }),
            retention: RetentionCache::new(),
            throttle: ThrottleTracker::new(),
        }))
    }

    /// Open an existing `.vlt`. No compartment is unlocked yet — call
    /// [`Vault::unlock_compartment`] before any key operation.
    #[cfg_attr(feature = "uniffi", uniffi::constructor)]
    pub fn open(path: String) -> FacadeResult<std::sync::Arc<Self>> {
        let path = PathBuf::from(path);
        let container = crate::container::Container::open(&path)?;
        Ok(std::sync::Arc::new(Self {
            path,
            state: Mutex::new(VaultState { container, unlocked: HashMap::new() }),
            retention: RetentionCache::new(),
            throttle: ThrottleTracker::new(),
        }))
    }

    pub fn path(&self) -> String {
        self.path.to_string_lossy().to_string()
    }

    pub fn list_compartments(&self) -> Vec<CompartmentInfo> {
        let state = self.state.lock().unwrap();
        state
            .container
            .header
            .compartments
            .iter()
            .map(|c| CompartmentInfo {
                compartment_id: c.compartment_id.to_string(),
                label: c.label.clone(),
                unlocked: state.unlocked.contains_key(&c.compartment_id),
            })
            .collect()
    }

    pub fn is_compartment_unlocked(&self, compartment_id: String) -> bool {
        let Ok(id) = Uuid::parse_str(&compartment_id) else { return false };
        self.state.lock().unwrap().unlocked.contains_key(&id)
    }

    /// Unlock one compartment (spec §5.3 option 2's per-compartment
    /// selection at the vault-unlock screen). Throttled per compartment
    /// (spec §5.5), independent of every other compartment's or key's
    /// throttle state.
    pub fn unlock_compartment(&self, compartment_id: String, passphrase: String) -> FacadeResult<()> {
        let id = parse_uuid(&compartment_id)?;
        let secret = SecretId::compartment(id);
        self.throttle.check(&secret).map_err(FacadeError::from)?;

        let mut state = self.state.lock().unwrap();
        let header = state
            .container
            .header
            .compartments
            .iter()
            .find(|c| c.compartment_id == id)
            .ok_or_else(|| FacadeError::msg("no such compartment"))?
            .clone();
        let blob = state
            .container
            .master_blobs
            .get(&id)
            .ok_or_else(|| FacadeError::msg("compartment has no master blob"))?
            .clone();

        let master_key = kdf::derive(passphrase.as_bytes(), &header.kdf_params_master)?;
        match master_blob::decrypt_with_key(id, &blob, &master_key) {
            Ok(plaintext) => {
                self.throttle.record_success(&secret);
                state.unlocked.insert(id, UnlockedCompartment { manifest: plaintext.manifest, master_key });
                Ok(())
            }
            Err(_) => {
                self.throttle.record_failure(&secret);
                Err(FacadeError::msg("incorrect master passphrase"))
            }
        }
    }

    /// Wipe one compartment's in-memory plaintext manifest (spec §4.5
    /// invariant (c) applied to the master-key layer, not just per-key
    /// retention). Does not touch the retention cache for that
    /// compartment's keys — call [`Vault::lock_all`] to wipe both layers.
    pub fn lock_compartment(&self, compartment_id: String) {
        if let Ok(id) = Uuid::parse_str(&compartment_id) {
            self.state.lock().unwrap().unlocked.remove(&id);
        }
    }

    /// Wipe every unlocked compartment's manifest and the entire
    /// retention cache (spec §4.5 invariant (c): explicit lock, app
    /// suspend, OS screen-lock).
    pub fn lock_all(&self) {
        self.state.lock().unwrap().unlocked.clear();
        self.retention.wipe_all();
    }

    /// Add a new, independently-passphrased compartment (spec §5.3 option
    /// 2's "keep both master keys side by side", also usable standalone
    /// for a user who wants multiple compartments from the start).
    pub fn add_compartment(
        &self,
        label: String,
        master_passphrase: String,
        profile: FacadeDeviceProfile,
    ) -> FacadeResult<CompartmentInfo> {
        let compartment_id = Uuid::new_v4();
        let kdf_params = kdf::benchmark(profile.into())?;
        let manifest = Manifest::new(Uuid::new_v4());
        let master_key = kdf::derive(master_passphrase.as_bytes(), &kdf_params)?;
        let blob = master_blob::encrypt_with_key(compartment_id, manifest.clone(), &master_key)?;

        let mut state = self.state.lock().unwrap();
        state.container.header.compartments.push(crate::container::CompartmentHeader {
            compartment_id,
            label: label.clone(),
            kdf_params_master: kdf_params,
        });
        state.container.master_blobs.insert(compartment_id, blob);
        state.unlocked.insert(compartment_id, UnlockedCompartment { manifest, master_key });
        state.container.write_atomic(&self.path)?;

        Ok(CompartmentInfo { compartment_id: compartment_id.to_string(), label, unlocked: true })
    }

    /// §5.1 "View list": every key in one unlocked compartment.
    pub fn list_keys(&self, compartment_id: String) -> FacadeResult<Vec<KeyInfo>> {
        let id = parse_uuid(&compartment_id)?;
        let state = self.state.lock().unwrap();
        let unlocked = unlocked_compartment(&state, id)?;
        Ok(unlocked.manifest.keys.iter().map(|k| key_info_view(id, k)).collect())
    }

    /// §5.1 "Create key": generate a keypair in memory, seal it under
    /// `key_passphrase`, write the blob, update and re-persist the
    /// manifest, then zero the generation buffer (the `Zeroizing` wrapper
    /// on [`keys::generate`]'s output does this on drop). `fido2` is only
    /// accepted (and required) when `purpose` includes FIDO2 — manual
    /// creation of a *bindable* passkey needs an already-known
    /// `rp_id`/`user_handle` pair; ordinary FIDO2 registration instead
    /// goes through [`Vault::handle_fido2_make_credential`], which
    /// supplies these fields itself from the live ceremony.
    #[allow(clippy::too_many_arguments)]
    pub fn create_key(
        &self,
        compartment_id: String,
        key_type: FacadeKeyType,
        purpose: FacadePurpose,
        label: String,
        description: String,
        resource: String,
        tags: Vec<String>,
        key_passphrase: String,
        fido2_rp_id: Option<String>,
        fido2_user_handle_b64: Option<String>,
    ) -> FacadeResult<KeyInfo> {
        let compartment_id_uuid = parse_uuid(&compartment_id)?;
        let purpose: Purpose = purpose.into();
        let fido2 = if purpose.includes_fido2() {
            let rp_id = fido2_rp_id.ok_or_else(|| FacadeError::msg("fido2 purpose requires fido2_rp_id"))?;
            let user_handle_b64 =
                fido2_user_handle_b64.ok_or_else(|| FacadeError::msg("fido2 purpose requires fido2_user_handle_b64"))?;
            Some(Fido2Info {
                rp_id,
                credential_id_b64: base64_encode(Uuid::new_v4().as_bytes()),
                user_handle_b64,
                sign_count: 0,
                discoverable: true,
            })
        } else {
            if fido2_rp_id.is_some() || fido2_user_handle_b64.is_some() {
                return Err(FacadeError::msg("fido2 fields supplied for a non-fido2 purpose"));
            }
            None
        };

        let generated = keys::generate(key_type.into())?;
        let key_id = Uuid::new_v4();
        let kdf_params = KdfParams::new(kdf::FLOOR_MEMORY_KIB, kdf::FLOOR_ITERATIONS, kdf::FLOOR_PARALLELISM)?;
        let blob = keyblob::seal(key_passphrase.as_bytes(), &generated.private_key, key_id, key_type.into(), &label, kdf_params)?;
        let blob_bytes = blob.to_bytes()?;
        let entry = KeyEntry {
            key_id,
            label,
            description,
            resource,
            key_type: key_type.into(),
            purpose,
            fido2,
            created_at: time::OffsetDateTime::now_utc(),
            last_used_at: None,
            tags,
            blob_file: format!("{}/{key_id}.kblob", crate::container::KEY_BLOBS_DIR),
            blob_sha256: crate::manifest::blob_sha256_hex(&blob_bytes),
            public_key_hex: hex::encode(&generated.public_key),
        };

        let mut state = self.state.lock().unwrap();
        {
            let unlocked = unlocked_compartment_mut(&mut state, compartment_id_uuid)?;
            unlocked.manifest.keys.push(entry.clone());
            unlocked.manifest.validate()?;
        }
        state.container.key_blobs.insert(key_id, blob_bytes);
        self.persist_locked(&mut state, compartment_id_uuid)?;

        Ok(key_info_view(compartment_id_uuid, &entry))
    }

    /// §5.1 "Discard key": the caller must have already obtained
    /// confirmation via its own two-step UI flow; `confirm_text` must
    /// match the key's current label or resource exactly, or this fails
    /// closed without deleting anything.
    pub fn discard_key(&self, compartment_id: String, key_id: String, confirm_text: String) -> FacadeResult<()> {
        let compartment_id = parse_uuid(&compartment_id)?;
        let key_id = parse_uuid(&key_id)?;
        let mut state = self.state.lock().unwrap();
        let unlocked = unlocked_compartment_mut(&mut state, compartment_id)?;
        let entry = unlocked
            .manifest
            .keys
            .iter()
            .find(|k| k.key_id == key_id)
            .ok_or_else(|| FacadeError::msg("no such key"))?;
        if confirm_text != entry.label && confirm_text != entry.resource {
            return Err(FacadeError::msg("confirmation text does not match the key's label or resource"));
        }
        unlocked.manifest.keys.retain(|k| k.key_id != key_id);
        state.container.key_blobs.remove(&key_id);
        self.persist_locked(&mut state, compartment_id)?;
        self.retention.wipe(&key_id);
        Ok(())
    }

    /// §5.1 "Change key passphrase": re-seal the existing private key
    /// bytes under a fresh passphrase and fresh KDF salt, without
    /// changing anything else about the manifest entry.
    pub fn change_key_passphrase(
        &self,
        compartment_id: String,
        key_id: String,
        old_passphrase: String,
        new_passphrase: String,
    ) -> FacadeResult<()> {
        let compartment_id = parse_uuid(&compartment_id)?;
        let key_id = parse_uuid(&key_id)?;
        let secret = SecretId::key(key_id);
        self.throttle.check(&secret).map_err(FacadeError::from)?;

        let mut state = self.state.lock().unwrap();
        let (key_type, label) = {
            let unlocked = unlocked_compartment(&state, compartment_id)?;
            let entry = find_key(&unlocked.manifest, key_id)?;
            (entry.key_type, entry.label.clone())
        };
        let blob_bytes = state.container.key_blobs.get(&key_id).cloned().ok_or_else(|| FacadeError::msg("no such key blob"))?;
        let blob = KeyBlob::from_bytes(&blob_bytes)?;

        let private_key = match keyblob::open(&blob, old_passphrase.as_bytes(), key_id, key_type, &label) {
            Ok(k) => {
                self.throttle.record_success(&secret);
                k
            }
            Err(_) => {
                self.throttle.record_failure(&secret);
                return Err(FacadeError::msg("incorrect passphrase"));
            }
        };

        let new_kdf_params = KdfParams::new(kdf::FLOOR_MEMORY_KIB, kdf::FLOOR_ITERATIONS, kdf::FLOOR_PARALLELISM)?;
        let new_blob = keyblob::seal(new_passphrase.as_bytes(), &private_key, key_id, key_type, &label, new_kdf_params)?;
        let new_blob_bytes = new_blob.to_bytes()?;

        {
            let unlocked = unlocked_compartment_mut(&mut state, compartment_id)?;
            let entry = unlocked.manifest.keys.iter_mut().find(|k| k.key_id == key_id).unwrap();
            entry.blob_sha256 = crate::manifest::blob_sha256_hex(&new_blob_bytes);
        }
        state.container.key_blobs.insert(key_id, new_blob_bytes);
        self.persist_locked(&mut state, compartment_id)?;
        Ok(())
    }

    /// §5.1 "Reveal raw key": returns the hex-encoded private key once,
    /// gated by the per-key passphrase and the same throttling every
    /// other passphrase surface uses. The caller is responsible for the
    /// "danger zone" warning UI and screen-capture blocking (spec §5.0) —
    /// this call performs no clipboard or persistence side effects.
    pub fn reveal_raw_key_hex(&self, compartment_id: String, key_id: String, passphrase: String) -> FacadeResult<String> {
        let compartment_id = parse_uuid(&compartment_id)?;
        let key_id_uuid = parse_uuid(&key_id)?;
        let private_key = self.decrypt_key(compartment_id, key_id_uuid, &passphrase)?;
        Ok(hex::encode(&*private_key))
    }

    /// Decrypt `key_id`'s private key and cache it in the retention cache
    /// for `retention_secs` (spec §4.5: 0-300s), throttled like every
    /// other passphrase surface. After this call, [`Vault::sign`] and the
    /// protocol/CTAP2 handlers can use the key without re-prompting until
    /// it expires or is explicitly locked.
    pub fn unlock_key(&self, compartment_id: String, key_id: String, passphrase: String, retention_secs: u32) -> FacadeResult<()> {
        let compartment_id = parse_uuid(&compartment_id)?;
        let key_id_uuid = parse_uuid(&key_id)?;
        let private_key = self.decrypt_key(compartment_id, key_id_uuid, &passphrase)?;
        self.retention.insert(key_id_uuid, private_key.to_vec(), retention_secs)?;
        Ok(())
    }

    pub fn is_key_unlocked(&self, key_id: String) -> bool {
        let Ok(id) = Uuid::parse_str(&key_id) else { return false };
        self.retention.contains(&id)
    }

    pub fn lock_key(&self, key_id: String) {
        if let Ok(id) = Uuid::parse_str(&key_id) {
            self.retention.wipe(&id);
        }
    }

    /// Sign `message` with a key already unlocked into the retention
    /// cache (via [`Vault::unlock_key`]). Does not itself prompt — use
    /// [`Vault::handle_protocol_request`]/[`Vault::handle_fido2_get_assertion`]
    /// for the prompting flows, or call [`Vault::unlock_key`] first.
    pub fn sign(&self, key_id: String, message: Vec<u8>) -> FacadeResult<Vec<u8>> {
        let key_id_uuid = parse_uuid(&key_id)?;
        let key_type = {
            let state = self.state.lock().unwrap();
            find_key_anywhere(&state, key_id_uuid).ok_or_else(|| FacadeError::msg("no such key"))?.0
        };
        self.retention
            .use_key(&key_id_uuid, |bytes| keys::sign(key_type, bytes, &message))
            .ok_or_else(|| FacadeError::msg("key is not unlocked"))?
            .map_err(FacadeError::from)
    }

    pub fn public_key_of(&self, compartment_id: String, key_id: String) -> FacadeResult<Vec<u8>> {
        let compartment_id = parse_uuid(&compartment_id)?;
        let key_id = parse_uuid(&key_id)?;
        let state = self.state.lock().unwrap();
        let unlocked = unlocked_compartment(&state, compartment_id)?;
        let entry = find_key(&unlocked.manifest, key_id)?;
        hex::decode(&entry.public_key_hex).map_err(|e| FacadeError::msg(e.to_string()))
    }

    /// The custom local signing protocol (spec §7): parse, dispatch, and
    /// answer one JSON-RPC request against every currently-unlocked
    /// compartment's keys. Prompts via `prompter` only if the target key
    /// isn't already warm in the retention cache.
    pub fn handle_protocol_request(
        &self,
        caller_identity: String,
        raw_json: Vec<u8>,
        prompter: std::sync::Arc<dyn PassphrasePrompter>,
    ) -> Vec<u8> {
        let backend = VaultProtocolBackend { vault: self, prompter };
        protocol::handle_request(&backend, &self.throttle, &caller_identity, &raw_json)
    }

    /// CTAP2 credential candidates for `rp_id` across every unlocked
    /// compartment — a read-only helper a native CTAP2 extension can use
    /// to decide whether it has anything to offer before even calling
    /// [`Vault::handle_fido2_get_assertion`].
    pub fn credential_candidates(&self, rp_id: String) -> Vec<CredentialCandidateInfo> {
        let backend = VaultCtap2Backend { vault: self, prompter: None };
        backend.credentials_for_rp(&rp_id).into_iter().map(CredentialCandidateInfo::from).collect()
    }

    /// `authenticatorMakeCredential` (spec §6.6), fully wired: generates
    /// the keypair, seals it under `key_passphrase`, persists it into
    /// `compartment_id`'s manifest, and returns everything a transport
    /// or a platform passkey-registration API needs.
    #[allow(clippy::too_many_arguments)]
    pub fn handle_fido2_make_credential(
        &self,
        compartment_id: String,
        request_cbor: Vec<u8>,
        user_present: bool,
        user_verified: bool,
        key_passphrase: String,
        label: String,
        description: String,
        resource: String,
    ) -> FacadeResult<Fido2MakeCredentialResult> {
        let compartment_id_uuid = parse_uuid(&compartment_id)?;
        let request = parse_make_credential(&request_cbor)?;
        let backend = VaultCtap2Backend { vault: self, prompter: None };
        let outcome = ctap2::handle_make_credential(&backend, &request, user_present, user_verified)
            .map_err(|e| FacadeError::msg(format!("{e:?}")))?;

        let key_id = Uuid::new_v4();
        let kdf_params = KdfParams::new(kdf::FLOOR_MEMORY_KIB, kdf::FLOOR_ITERATIONS, kdf::FLOOR_PARALLELISM)?;
        let blob = keyblob::seal(
            key_passphrase.as_bytes(),
            &outcome.generated_key.private_key,
            key_id,
            outcome.generated_key.key_type,
            &label,
            kdf_params,
        )?;
        let blob_bytes = blob.to_bytes()?;
        let entry = KeyEntry {
            key_id,
            label,
            description,
            resource,
            key_type: outcome.generated_key.key_type,
            purpose: Purpose::Fido2,
            fido2: Some(Fido2Info {
                rp_id: outcome.rp_id.clone(),
                credential_id_b64: base64_encode(&outcome.credential_id),
                user_handle_b64: base64_encode(&outcome.user_handle),
                sign_count: 0,
                discoverable: outcome.discoverable,
            }),
            created_at: time::OffsetDateTime::now_utc(),
            last_used_at: None,
            tags: vec![],
            blob_file: format!("{}/{key_id}.kblob", crate::container::KEY_BLOBS_DIR),
            blob_sha256: crate::manifest::blob_sha256_hex(&blob_bytes),
            public_key_hex: hex::encode(&outcome.generated_key.public_key),
        };

        let mut state = self.state.lock().unwrap();
        {
            let unlocked = unlocked_compartment_mut(&mut state, compartment_id_uuid)?;
            unlocked.manifest.keys.push(entry);
            unlocked.manifest.validate()?;
        }
        state.container.key_blobs.insert(key_id, blob_bytes);
        self.persist_locked(&mut state, compartment_id_uuid)?;

        Ok(Fido2MakeCredentialResult {
            response_cbor: outcome.response_cbor,
            attestation_object: outcome.attestation_object,
            credential_id: outcome.credential_id,
            rp_id: outcome.rp_id,
            user_handle: outcome.user_handle,
            key_id: key_id.to_string(),
        })
    }

    /// `authenticatorGetAssertion` (spec §6.6): matches a credential
    /// across every unlocked compartment, signs (prompting via `prompter`
    /// if the key isn't already cached, throttled like every other
    /// passphrase surface per §5.5), persists the incremented
    /// `sign_count`, and returns everything a transport or a platform
    /// passkey-assertion API needs.
    pub fn handle_fido2_get_assertion(
        &self,
        request_cbor: Vec<u8>,
        user_present: bool,
        user_verified: bool,
        prompter: std::sync::Arc<dyn PassphrasePrompter>,
    ) -> FacadeResult<Fido2AssertionResult> {
        let request = parse_get_assertion(&request_cbor)?;
        let backend = VaultCtap2Backend { vault: self, prompter: Some(prompter) };
        let outcome = ctap2::handle_get_assertion(&backend, &request, user_present, user_verified)
            .map_err(|e| FacadeError::msg(format!("{e:?}")))?;

        let mut state = self.state.lock().unwrap();
        if let Some(compartment_id) = find_compartment_for_key(&state, outcome.key_id) {
            let unlocked = unlocked_compartment_mut(&mut state, compartment_id)?;
            if let Some(entry) = unlocked.manifest.keys.iter_mut().find(|k| k.key_id == outcome.key_id) {
                if let Some(fido2) = entry.fido2.as_mut() {
                    fido2.sign_count = outcome.new_sign_count;
                }
                entry.last_used_at = Some(time::OffsetDateTime::now_utc());
            }
            self.persist_locked(&mut state, compartment_id)?;
        }

        Ok(Fido2AssertionResult {
            response_cbor: outcome.response_cbor,
            credential_id: outcome.credential_id,
            user_handle: outcome.user_handle,
            rp_id: outcome.rp_id,
            authenticator_data: outcome.authenticator_data,
            signature: outcome.signature,
        })
    }

    /// [`Vault::handle_fido2_make_credential`], for a caller whose OS
    /// integration hands it decomposed request fields rather than raw
    /// CTAP2 bytes — e.g. macOS's `ASPasskeyCredentialRequest` inside an
    /// `ASCredentialProviderExtension` (spec §6.1). Builds the equivalent
    /// CTAP2 request CBOR (`ctap2::build_make_credential_request_cbor`)
    /// and delegates to the exact same, already-tested path — this
    /// method exists so that encoding never has to happen in platform
    /// code (spec §2).
    #[allow(clippy::too_many_arguments)]
    pub fn handle_fido2_make_credential_native(
        &self,
        compartment_id: String,
        rp_id: String,
        user_id: Vec<u8>,
        client_data_hash: Vec<u8>,
        algorithms: Vec<i32>,
        exclude_credential_ids: Vec<Vec<u8>>,
        discoverable: bool,
        user_verification_requested: bool,
        user_present: bool,
        user_verified: bool,
        key_passphrase: String,
        label: String,
        description: String,
        resource: String,
    ) -> FacadeResult<Fido2MakeCredentialResult> {
        let algorithms_i64: Vec<i64> = algorithms.iter().map(|&a| a as i64).collect();
        let request_cbor = ctap2::build_make_credential_request_cbor(
            &rp_id,
            &user_id,
            &client_data_hash,
            &algorithms_i64,
            &exclude_credential_ids,
            discoverable,
            user_verification_requested,
        );
        self.handle_fido2_make_credential(compartment_id, request_cbor, user_present, user_verified, key_passphrase, label, description, resource)
    }

    /// [`Vault::handle_fido2_get_assertion`]'s decomposed-fields
    /// counterpart — see
    /// [`Vault::handle_fido2_make_credential_native`]'s doc comment.
    #[allow(clippy::too_many_arguments)]
    pub fn handle_fido2_get_assertion_native(
        &self,
        rp_id: String,
        client_data_hash: Vec<u8>,
        allow_credential_ids: Vec<Vec<u8>>,
        user_verification_requested: bool,
        user_present: bool,
        user_verified: bool,
        prompter: std::sync::Arc<dyn PassphrasePrompter>,
    ) -> FacadeResult<Fido2AssertionResult> {
        let request_cbor = ctap2::build_get_assertion_request_cbor(&rp_id, &client_data_hash, &allow_credential_ids, user_verification_requested);
        self.handle_fido2_get_assertion(request_cbor, user_present, user_verified, prompter)
    }

    /// Spec §5.3 option 1: merge `incoming_manifest_json`'s keys into
    /// `target_compartment_id` (which must already be unlocked), keeping
    /// that compartment's existing master key. `incoming_key_blobs` are
    /// copied in verbatim, keyed by their *post-merge* key_id — use
    /// [`MergeOutcomeInfo::id_remap`] to translate from whatever key_id
    /// the incoming manifest originally used.
    pub fn merge_reencrypt_discard_incoming(
        &self,
        target_compartment_id: String,
        incoming_manifest_json: String,
        incoming_key_blobs: Vec<IncomingKeyBlob>,
    ) -> FacadeResult<MergeOutcomeInfo> {
        let target = parse_uuid(&target_compartment_id)?;
        let incoming = Manifest::from_json(incoming_manifest_json.as_bytes())?;
        let mut state = self.state.lock().unwrap();
        let local = self.local_compartments(&state);
        let result = merge::merge_reencrypt_discard_incoming(local, target, &incoming)?;
        self.apply_merge_result(&mut state, result, incoming_key_blobs)
    }

    /// Spec §5.3 option 2: the incoming manifest becomes its own new
    /// compartment under `new_master_passphrase`; the existing local
    /// compartments are untouched.
    pub fn merge_side_by_side(
        &self,
        incoming_manifest_json: String,
        incoming_key_blobs: Vec<IncomingKeyBlob>,
        new_compartment_label: String,
        new_master_passphrase: String,
        profile: FacadeDeviceProfile,
    ) -> FacadeResult<MergeOutcomeInfo> {
        let incoming = Manifest::from_json(incoming_manifest_json.as_bytes())?;
        let new_compartment_id = Uuid::new_v4();
        let mut state = self.state.lock().unwrap();
        let local = self.local_compartments(&state);
        let result = merge::merge_side_by_side(local, &incoming, new_compartment_id, new_compartment_label.clone())?;

        let new_kdf_params = kdf::benchmark(profile.into())?;
        let new_master_key = kdf::derive(new_master_passphrase.as_bytes(), &new_kdf_params)?;
        let new_compartment_manifest = result
            .updated_compartments
            .iter()
            .find(|c| c.id == new_compartment_id)
            .expect("merge_side_by_side always creates the requested new compartment")
            .manifest
            .clone();
        let blob = master_blob::encrypt_with_key(new_compartment_id, new_compartment_manifest.clone(), &new_master_key)?;
        state.container.header.compartments.push(crate::container::CompartmentHeader {
            compartment_id: new_compartment_id,
            label: new_compartment_label,
            kdf_params_master: new_kdf_params,
        });
        state.container.master_blobs.insert(new_compartment_id, blob);
        state
            .unlocked
            .insert(new_compartment_id, UnlockedCompartment { manifest: new_compartment_manifest, master_key: new_master_key });

        let outcome = self.apply_merge_result_metadata(&result);
        self.copy_incoming_blobs(&mut state, &result.id_remap, incoming_key_blobs);
        state.container.write_atomic(&self.path)?;
        Ok(outcome)
    }

    /// Spec §5.3 option 3: replace `target_compartment_id`'s master key
    /// with the incoming one. `confirmation_phrase` must equal
    /// [`merge::REPLACE_CONFIRMATION_PHRASE`] exactly.
    pub fn merge_replace_local_with_incoming(
        &self,
        target_compartment_id: String,
        incoming_manifest_json: String,
        incoming_key_blobs: Vec<IncomingKeyBlob>,
        incoming_master_passphrase: String,
        incoming_kdf_params_json: String,
        confirmation_phrase: String,
    ) -> FacadeResult<MergeOutcomeInfo> {
        let target = parse_uuid(&target_compartment_id)?;
        let incoming = Manifest::from_json(incoming_manifest_json.as_bytes())?;
        let incoming_kdf_params: KdfParams =
            serde_json::from_str(&incoming_kdf_params_json).map_err(|e| FacadeError::msg(e.to_string()))?;

        let mut state = self.state.lock().unwrap();
        let local = self.local_compartments(&state);
        let result = merge::merge_replace_local_with_incoming(local, target, &incoming, &confirmation_phrase)?;

        let merged_manifest = result
            .updated_compartments
            .iter()
            .find(|c| c.id == target)
            .expect("merge_replace_local_with_incoming keeps the target compartment id")
            .manifest
            .clone();
        let incoming_master_key = kdf::derive(incoming_master_passphrase.as_bytes(), &incoming_kdf_params)?;
        let blob = master_blob::encrypt_with_key(target, merged_manifest.clone(), &incoming_master_key)?;

        if let Some(header) = state.container.header.compartments.iter_mut().find(|c| c.compartment_id == target) {
            header.kdf_params_master = incoming_kdf_params;
        }
        state.container.master_blobs.insert(target, blob);
        state.unlocked.insert(target, UnlockedCompartment { manifest: merged_manifest, master_key: incoming_master_key });

        let outcome = self.apply_merge_result_metadata(&result);
        self.copy_incoming_blobs(&mut state, &result.id_remap, incoming_key_blobs);
        state.container.write_atomic(&self.path)?;
        Ok(outcome)
    }

    /// Spec §5.2's packet export, and §5.4's backup flows (which are
    /// just this with every key_id, or with none at all for the
    /// "master key only" shortcut). `key_ids` may be empty. Every
    /// selected key's `.kblob` is copied byte-for-byte from the
    /// container — this never re-encrypts a key, only the optional
    /// outer transfer-encryption layer (spec §5.2.2) is new crypto.
    pub fn export_packet(
        &self,
        compartment_id: String,
        key_ids: Vec<String>,
        include_master_key: bool,
        encryption: FacadeExportEncryption,
    ) -> FacadeResult<Vec<u8>> {
        let compartment_id = parse_uuid(&compartment_id)?;
        let state = self.state.lock().unwrap();
        let unlocked = unlocked_compartment(&state, compartment_id)?;

        let mut keys = Vec::with_capacity(key_ids.len());
        let mut key_blobs = HashMap::with_capacity(key_ids.len());
        for key_id_str in &key_ids {
            let key_id = parse_uuid(key_id_str)?;
            let entry = find_key(&unlocked.manifest, key_id)?.clone();
            let blob = state.container.key_blobs.get(&key_id).cloned().ok_or_else(|| FacadeError::msg("no such key blob"))?;
            keys.push(entry);
            key_blobs.insert(key_id, blob);
        }

        let embedded_master = if include_master_key {
            let header = state
                .container
                .header
                .compartments
                .iter()
                .find(|c| c.compartment_id == compartment_id)
                .ok_or_else(|| FacadeError::msg("no such compartment"))?;
            let blob = state
                .container
                .master_blobs
                .get(&compartment_id)
                .cloned()
                .ok_or_else(|| FacadeError::msg("compartment has no master blob"))?;
            Some((EmbeddedMasterKey { compartment_id, kdf_params_master: header.kdf_params_master.clone() }, blob))
        } else {
            None
        };
        drop(state);

        let inner = packet::build_inner_packet(keys, &key_blobs, embedded_master)?;
        let export_encryption = match &encryption {
            FacadeExportEncryption::AsIs => ExportEncryption::AsIs,
            FacadeExportEncryption::DestinationMasterPassword { password } => ExportEncryption::DestinationMasterPassword(password.as_bytes()),
            FacadeExportEncryption::OneTimeTransferPassword { password } => ExportEncryption::OneTimeTransferPassword(password.as_bytes()),
        };
        Ok(packet::export_packet(inner, export_encryption)?)
    }

    /// Spec §5.2's single-key export (`.vltkey`): always "as-is" — a
    /// standalone key is already protected by its own passphrase, so the
    /// §5.2.2 transfer-encryption choice doesn't apply to it.
    pub fn export_single_key(&self, compartment_id: String, key_id: String) -> FacadeResult<Vec<u8>> {
        self.export_packet(compartment_id, vec![key_id], false, FacadeExportEncryption::AsIs)
    }

    /// Spec §5.3 step 1: unwrap a `.vltkey`/`.vltpack`'s transfer-
    /// encryption layer (if any) and surface what it contains, ready for
    /// one of the `merge_*` methods above. Does not itself merge or copy
    /// anything into this vault — that is a separate, explicit call once
    /// the caller has decided which of the three duality options to use
    /// (spec §5.3 step 3 requires that to be an unskippable, deliberate
    /// choice when an embedded master key is present).
    pub fn import_packet(&self, packet_bytes: Vec<u8>, transfer_password: Option<String>) -> FacadeResult<ImportedPacketInfo> {
        let inner = packet::import_packet(&packet_bytes, transfer_password.as_deref().map(str::as_bytes))?;

        let mut manifest = Manifest::new(Uuid::new_v4());
        manifest.keys = inner.keys;
        let manifest_json = String::from_utf8(manifest.to_json()?).map_err(|e| FacadeError::msg(e.to_string()))?;

        let key_blobs = inner
            .key_blobs
            .into_iter()
            .map(|(key_id, blob_bytes)| IncomingKeyBlob { key_id: key_id.to_string(), blob_bytes })
            .collect();

        let (embedded_master_compartment_id, embedded_master_kdf_params_json) = match inner.embedded_master {
            Some(meta) => {
                let kdf_json = serde_json::to_string(&meta.kdf_params_master).map_err(|e| FacadeError::msg(e.to_string()))?;
                (Some(meta.compartment_id.to_string()), Some(kdf_json))
            }
            None => (None, None),
        };

        Ok(ImportedPacketInfo { manifest_json, key_blobs, embedded_master_compartment_id, embedded_master_kdf_params_json })
    }
}

// ---- Internal helpers (not exported over FFI) ----

impl Vault {
    fn decrypt_key(&self, compartment_id: Uuid, key_id: Uuid, passphrase: &str) -> FacadeResult<zeroize::Zeroizing<Vec<u8>>> {
        let secret = SecretId::key(key_id);
        self.throttle.check(&secret).map_err(FacadeError::from)?;

        let state = self.state.lock().unwrap();
        let (key_type, label) = {
            let unlocked = unlocked_compartment(&state, compartment_id)?;
            let entry = find_key(&unlocked.manifest, key_id)?;
            (entry.key_type, entry.label.clone())
        };
        let blob_bytes = state.container.key_blobs.get(&key_id).cloned().ok_or_else(|| FacadeError::msg("no such key blob"))?;
        drop(state);
        let blob = KeyBlob::from_bytes(&blob_bytes)?;

        match keyblob::open(&blob, passphrase.as_bytes(), key_id, key_type, &label) {
            Ok(k) => {
                self.throttle.record_success(&secret);
                Ok(k)
            }
            Err(_) => {
                self.throttle.record_failure(&secret);
                Err(FacadeError::msg("incorrect passphrase"))
            }
        }
    }

    /// Re-encrypt `compartment_id`'s current in-memory manifest under its
    /// cached master key and write the whole container atomically (spec
    /// §4.6) — called after every manifest mutation (key create/discard/
    /// passphrase change) so a change is never left only in memory.
    fn persist_locked(&self, state: &mut VaultState, compartment_id: Uuid) -> FacadeResult<()> {
        let unlocked = unlocked_compartment(state, compartment_id)?;
        let manifest = unlocked.manifest.clone();
        let blob = master_blob::encrypt_with_key(compartment_id, manifest, &unlocked.master_key)?;
        state.container.master_blobs.insert(compartment_id, blob);
        state.container.write_atomic(&self.path)?;
        Ok(())
    }
}

fn parse_uuid(s: &str) -> FacadeResult<Uuid> {
    Uuid::parse_str(s).map_err(|_| FacadeError::msg("invalid UUID"))
}

fn unlocked_compartment(state: &VaultState, id: Uuid) -> FacadeResult<&UnlockedCompartment> {
    state.unlocked.get(&id).ok_or_else(|| FacadeError::msg("compartment is not unlocked"))
}

fn unlocked_compartment_mut(state: &mut VaultState, id: Uuid) -> FacadeResult<&mut UnlockedCompartment> {
    state.unlocked.get_mut(&id).ok_or_else(|| FacadeError::msg("compartment is not unlocked"))
}

fn find_key(manifest: &Manifest, key_id: Uuid) -> FacadeResult<&KeyEntry> {
    manifest.keys.iter().find(|k| k.key_id == key_id).ok_or_else(|| FacadeError::msg("no such key"))
}

fn find_key_anywhere(state: &VaultState, key_id: Uuid) -> Option<(KeyType, Uuid)> {
    for (compartment_id, unlocked) in &state.unlocked {
        if let Some(entry) = unlocked.manifest.keys.iter().find(|k| k.key_id == key_id) {
            return Some((entry.key_type, *compartment_id));
        }
    }
    None
}

fn find_compartment_for_key(state: &VaultState, key_id: Uuid) -> Option<Uuid> {
    find_key_anywhere(state, key_id).map(|(_, c)| c)
}

fn base64_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn parse_make_credential(bytes: &[u8]) -> FacadeResult<make_credential::Request<'_>> {
    match ctap2_wire::Request::deserialize(bytes) {
        Ok(ctap2_wire::Request::MakeCredential(r)) => Ok(r),
        Ok(_) => Err(FacadeError::msg("expected an authenticatorMakeCredential request")),
        Err(_) => Err(FacadeError::msg("malformed CTAP2 request")),
    }
}

fn parse_get_assertion(bytes: &[u8]) -> FacadeResult<get_assertion::Request<'_>> {
    match ctap2_wire::Request::deserialize(bytes) {
        Ok(ctap2_wire::Request::GetAssertion(r)) => Ok(r),
        Ok(_) => Err(FacadeError::msg("expected an authenticatorGetAssertion request")),
        Err(_) => Err(FacadeError::msg("malformed CTAP2 request")),
    }
}

/// What [`Vault::handle_fido2_make_credential`] hands back — every field
/// a platform's passkey-registration completion API needs, already
/// decomposed (spec §2: no platform re-derives these by parsing
/// `response_cbor` itself). `attestation_object` is exactly what macOS's
/// `ASPasskeyRegistrationCredential.attestationObject` (and the
/// equivalent field on other platforms' passkey APIs) wants.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Fido2MakeCredentialResult {
    pub response_cbor: Vec<u8>,
    pub attestation_object: Vec<u8>,
    pub credential_id: Vec<u8>,
    pub rp_id: String,
    pub user_handle: Vec<u8>,
    pub key_id: String,
}

/// What [`Vault::handle_fido2_get_assertion`] hands back — see
/// [`Fido2MakeCredentialResult`]'s doc comment for why these are
/// decomposed rather than leaving the caller to parse `response_cbor`.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Fido2AssertionResult {
    pub response_cbor: Vec<u8>,
    pub credential_id: Vec<u8>,
    pub user_handle: Vec<u8>,
    pub rp_id: String,
    pub authenticator_data: Vec<u8>,
    pub signature: Vec<u8>,
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CredentialCandidateInfo {
    pub key_id: String,
    pub credential_id_b64: String,
    pub discoverable: bool,
}

impl From<CredentialCandidate> for CredentialCandidateInfo {
    fn from(c: CredentialCandidate) -> Self {
        Self { key_id: c.key_id.to_string(), credential_id_b64: base64_encode(&c.credential_id), discoverable: c.discoverable }
    }
}

/// Ties an unlocked [`Vault`]'s state, the retention cache, and a
/// [`PassphrasePrompter`] into the [`SigningBackend`] the custom protocol
/// (`protocol.rs`) requires.
struct VaultProtocolBackend<'a> {
    vault: &'a Vault,
    prompter: std::sync::Arc<dyn PassphrasePrompter>,
}

impl SigningBackend for VaultProtocolBackend<'_> {
    fn list_public_keys(&self) -> Vec<PublicKeyInfo> {
        let state = self.vault.state.lock().unwrap();
        state
            .unlocked
            .values()
            .flat_map(|u| u.manifest.keys.iter())
            .filter_map(|entry| {
                let public_key = hex::decode(&entry.public_key_hex).ok()?;
                Some(PublicKeyInfo { key_id: entry.key_id, label: entry.label.clone(), public_key, resource: entry.resource.clone() })
            })
            .collect()
    }

    fn sign(&self, caller_identity: &str, key_id: Uuid, message: &[u8]) -> SignOutcome {
        let Some((key_type, public_key, compartment_id)) = ({
            let state = self.vault.state.lock().unwrap();
            find_key_anywhere(&state, key_id).and_then(|(kt, cid)| {
                unlocked_compartment(&state, cid).ok().and_then(|u| find_key(&u.manifest, key_id).ok()).and_then(|e| {
                    hex::decode(&e.public_key_hex).ok().map(|pk| (kt, pk, cid))
                })
            })
        }) else {
            return SignOutcome::KeyNotFound;
        };

        if !self.vault.retention.contains(&key_id) {
            match self.prompter.prompt(caller_identity.to_string(), key_id.to_string()) {
                None => return SignOutcome::UserDeclined,
                Some(passphrase) => match self.vault.decrypt_key(compartment_id, key_id, &passphrase) {
                    Ok(k) => {
                        // Deliberately not recorded against the throttle
                        // tracker here: `protocol::handle_request` already
                        // records success/failure for this exact secret
                        // based on the `SignOutcome` this function
                        // returns, and `decrypt_key` above already did so
                        // too — recording twice would double-count one
                        // real attempt.
                        if self.vault.retention.insert(key_id, k.to_vec(), DEFAULT_KEY_RETENTION_SECS).is_err() {
                            return SignOutcome::UserDeclined;
                        }
                    }
                    Err(_) => return SignOutcome::PassphraseIncorrect,
                },
            }
        }

        match self.vault.retention.use_key(&key_id, |bytes| keys::sign(key_type, bytes, message)) {
            Some(Ok(signature)) => SignOutcome::Signed { signature, public_key },
            _ => SignOutcome::UserDeclined,
        }
    }
}

/// Ties an unlocked [`Vault`]'s state, the retention cache, and an
/// optional [`PassphrasePrompter`] into the [`Ctap2Backend`] `ctap2.rs`
/// requires. `prompter` is `None` for the read-only
/// [`Vault::credential_candidates`]/make-credential paths, which never
/// need to sign with an existing key.
struct VaultCtap2Backend<'a> {
    vault: &'a Vault,
    prompter: Option<std::sync::Arc<dyn PassphrasePrompter>>,
}

impl Ctap2Backend for VaultCtap2Backend<'_> {
    fn credentials_for_rp(&self, rp_id: &str) -> Vec<CredentialCandidate> {
        let state = self.vault.state.lock().unwrap();
        state
            .unlocked
            .values()
            .flat_map(|u| u.manifest.keys.iter())
            .filter_map(|entry| {
                let fido2 = entry.fido2.as_ref()?;
                if fido2.rp_id != rp_id {
                    return None;
                }
                use base64::Engine;
                let credential_id = base64::engine::general_purpose::STANDARD.decode(&fido2.credential_id_b64).ok()?;
                let user_handle = base64::engine::general_purpose::STANDARD.decode(&fido2.user_handle_b64).ok()?;
                Some(CredentialCandidate {
                    key_id: entry.key_id,
                    credential_id,
                    user_handle,
                    discoverable: fido2.discoverable,
                    sign_count: fido2.sign_count,
                })
            })
            .collect()
    }

    fn sign(&self, key_id: Uuid, message: &[u8]) -> Option<Vec<u8>> {
        let (key_type, compartment_id) = {
            let state = self.vault.state.lock().unwrap();
            find_key_anywhere(&state, key_id)?
        };

        let secret = SecretId::key(key_id);
        if !self.vault.retention.contains(&key_id) {
            self.vault.throttle.check(&secret).ok()?;
            let prompter = self.prompter.as_ref()?;
            let passphrase = prompter.prompt("FIDO2 assertion".to_string(), key_id.to_string())?;
            match self.vault.decrypt_key(compartment_id, key_id, &passphrase) {
                Ok(k) => {
                    self.vault.retention.insert(key_id, k.to_vec(), DEFAULT_KEY_RETENTION_SECS).ok()?;
                }
                Err(_) => return None,
            }
        }

        self.vault.retention.use_key(&key_id, |bytes| keys::sign(key_type, bytes, message))?.ok()
    }
}

impl Vault {
    fn local_compartments(&self, state: &VaultState) -> Vec<VaultCompartment> {
        state
            .container
            .header
            .compartments
            .iter()
            .filter_map(|header| {
                state.unlocked.get(&header.compartment_id).map(|u| VaultCompartment {
                    id: header.compartment_id,
                    label: header.label.clone(),
                    manifest: u.manifest.clone(),
                })
            })
            .collect()
    }

    fn apply_merge_result_metadata(&self, result: &merge::MergeResult) -> MergeOutcomeInfo {
        MergeOutcomeInfo {
            warnings: result.warnings.iter().map(DuplicateWarningInfo::from).collect(),
            id_remap: result.id_remap.iter().map(|(old, new)| IdRemapEntry { old_key_id: old.to_string(), new_key_id: new.to_string() }).collect(),
        }
    }

    fn copy_incoming_blobs(&self, state: &mut VaultState, id_remap: &HashMap<Uuid, Uuid>, incoming_key_blobs: Vec<IncomingKeyBlob>) {
        for blob in incoming_key_blobs {
            let Ok(original_id) = Uuid::parse_str(&blob.key_id) else { continue };
            let final_id = id_remap.get(&original_id).copied().unwrap_or(original_id);
            state.container.key_blobs.insert(final_id, blob.blob_bytes);
        }
    }

    /// Applies an option-1/option-3-shaped [`merge::MergeResult`] (one
    /// that updates an existing compartment in place) back into
    /// `state.unlocked`/`state.container` and persists atomically. Option
    /// 2 (new compartment) has its own inline handling since it also
    /// needs a freshly benchmarked master key, not just an existing one.
    fn apply_merge_result(
        &self,
        state: &mut VaultState,
        result: merge::MergeResult,
        incoming_key_blobs: Vec<IncomingKeyBlob>,
    ) -> FacadeResult<MergeOutcomeInfo> {
        for updated in &result.updated_compartments {
            if let Some(unlocked) = state.unlocked.get_mut(&updated.id) {
                unlocked.manifest = updated.manifest.clone();
            }
            // Bug found via real device testing (Android, spec §5.3
            // option 1): updating `state.unlocked[id].manifest` above
            // only refreshes the plaintext working copy this process
            // reads from — `write_atomic` below serializes
            // `state.container`, so without also re-encrypting the new
            // manifest back into `state.container.master_blobs[id]`, the
            // file on disk keeps the *pre-merge* master blob. Every
            // in-memory read (list_keys, sign, even this same
            // `Vault` instance's own re-reads) looks correct because
            // they all go through `state.unlocked`; only a fresh
            // `Vault::open` — a real app restart — decrypts from the
            // stale blob and silently loses the merge. Mirrors
            // `persist_locked`'s re-encrypt step, which every *other*
            // manifest-mutating method already goes through.
            if let Some(unlocked) = state.unlocked.get(&updated.id) {
                let blob = master_blob::encrypt_with_key(updated.id, unlocked.manifest.clone(), &unlocked.master_key)?;
                state.container.master_blobs.insert(updated.id, blob);
            }
        }
        let outcome = self.apply_merge_result_metadata(&result);
        self.copy_incoming_blobs(state, &result.id_remap, incoming_key_blobs);
        state.container.write_atomic(&self.path)?;
        Ok(outcome)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ciborium::Value;
    use ed25519_dalek::Verifier;
    use tempfile::tempdir;

    fn vault_path(dir: &tempfile::TempDir) -> String {
        dir.path().join("test.vlt").to_string_lossy().to_string()
    }

    fn create_test_vault(dir: &tempfile::TempDir) -> (std::sync::Arc<Vault>, String) {
        let vault = Vault::create(vault_path(dir), "Personal".into(), "master pw".into(), FacadeDeviceProfile::Desktop).unwrap();
        let compartment_id = vault.list_compartments()[0].compartment_id.clone();
        (vault, compartment_id)
    }

    struct FixedPrompter(Mutex<Option<String>>);
    impl PassphrasePrompter for FixedPrompter {
        fn prompt(&self, _caller_identity: String, _key_id: String) -> Option<String> {
            self.0.lock().unwrap().take()
        }
    }
    fn prompter_with(passphrase: &str) -> std::sync::Arc<dyn PassphrasePrompter> {
        std::sync::Arc::new(FixedPrompter(Mutex::new(Some(passphrase.to_string()))))
    }
    fn prompter_declines() -> std::sync::Arc<dyn PassphrasePrompter> {
        std::sync::Arc::new(FixedPrompter(Mutex::new(None)))
    }

    #[test]
    fn create_and_reopen_roundtrips() {
        let dir = tempdir().unwrap();
        let path = vault_path(&dir);
        let (vault, compartment_id) = create_test_vault(&dir);
        drop(vault);

        let reopened = Vault::open(path).unwrap();
        assert!(!reopened.is_compartment_unlocked(compartment_id.clone()));
        reopened.unlock_compartment(compartment_id.clone(), "master pw".into()).unwrap();
        assert!(reopened.is_compartment_unlocked(compartment_id));
    }

    #[test]
    fn unlock_with_wrong_master_passphrase_fails_and_throttles() {
        let dir = tempdir().unwrap();
        let path = vault_path(&dir);
        let (vault, compartment_id) = create_test_vault(&dir);
        drop(vault);

        let reopened = Vault::open(path).unwrap();
        assert!(reopened.unlock_compartment(compartment_id.clone(), "wrong".into()).is_err());
        assert!(reopened.unlock_compartment(compartment_id, "master pw".into()).is_ok());
    }

    #[test]
    fn create_key_list_and_sign_roundtrip() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);

        let key = vault
            .create_key(
                compartment_id.clone(),
                FacadeKeyType::Ed25519,
                FacadePurpose::CustomSigning,
                "Deploy key".into(),
                "".into(),
                "example.com".into(),
                vec!["work".into()],
                "key pw".into(),
                None,
                None,
            )
            .unwrap();
        assert_eq!(key.label, "Deploy key");
        assert!(!key.public_key_hex.is_empty());

        let keys = vault.list_keys(compartment_id.clone()).unwrap();
        assert_eq!(keys.len(), 1);

        vault.unlock_key(compartment_id.clone(), key.key_id.clone(), "key pw".into(), 30).unwrap();
        assert!(vault.is_key_unlocked(key.key_id.clone()));

        let signature = vault.sign(key.key_id.clone(), b"hello world".to_vec()).unwrap();
        let public_key_bytes = hex::decode(&key.public_key_hex).unwrap();
        let verifying_key = ed25519_dalek::VerifyingKey::from_bytes(&public_key_bytes.clone().try_into().unwrap()).unwrap();
        let sig = ed25519_dalek::Signature::from_bytes(&signature.try_into().unwrap());
        assert!(verifying_key.verify(b"hello world", &sig).is_ok());

        // Also reachable via the standalone getter without unlocking again.
        let pk_again = vault.public_key_of(compartment_id, key.key_id).unwrap();
        assert_eq!(pk_again, public_key_bytes);
    }

    #[test]
    fn sign_without_unlock_fails() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let key = vault
            .create_key(
                compartment_id,
                FacadeKeyType::Ed25519,
                FacadePurpose::CustomSigning,
                "k".into(),
                "".into(),
                "".into(),
                vec![],
                "pw".into(),
                None,
                None,
            )
            .unwrap();
        assert!(vault.sign(key.key_id, b"m".to_vec()).is_err());
    }

    #[test]
    fn discard_key_requires_matching_confirmation() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let key = vault
            .create_key(
                compartment_id.clone(),
                FacadeKeyType::Ed25519,
                FacadePurpose::CustomSigning,
                "Deploy key".into(),
                "".into(),
                "example.com".into(),
                vec![],
                "pw".into(),
                None,
                None,
            )
            .unwrap();

        assert!(vault.discard_key(compartment_id.clone(), key.key_id.clone(), "wrong text".into()).is_err());
        assert_eq!(vault.list_keys(compartment_id.clone()).unwrap().len(), 1);

        vault.discard_key(compartment_id.clone(), key.key_id, "Deploy key".into()).unwrap();
        assert!(vault.list_keys(compartment_id).unwrap().is_empty());
    }

    #[test]
    fn change_key_passphrase_then_old_passphrase_no_longer_works() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let key = vault
            .create_key(
                compartment_id.clone(),
                FacadeKeyType::Ed25519,
                FacadePurpose::CustomSigning,
                "k".into(),
                "".into(),
                "".into(),
                vec![],
                "old pw".into(),
                None,
                None,
            )
            .unwrap();

        vault
            .change_key_passphrase(compartment_id.clone(), key.key_id.clone(), "old pw".into(), "new pw".into())
            .unwrap();

        assert!(vault.reveal_raw_key_hex(compartment_id.clone(), key.key_id.clone(), "old pw".into()).is_err());
        let revealed = vault.reveal_raw_key_hex(compartment_id, key.key_id, "new pw".into()).unwrap();
        assert_eq!(revealed.len(), 64); // 32-byte ed25519 seed, hex-encoded
    }

    #[test]
    fn mutations_persist_across_reopen_without_recaching_passphrase() {
        let dir = tempdir().unwrap();
        let path = vault_path(&dir);
        let (vault, compartment_id) = create_test_vault(&dir);
        vault
            .create_key(
                compartment_id.clone(),
                FacadeKeyType::Ed25519,
                FacadePurpose::CustomSigning,
                "Persisted key".into(),
                "".into(),
                "".into(),
                vec![],
                "key pw".into(),
                None,
                None,
            )
            .unwrap();
        drop(vault);

        let reopened = Vault::open(path).unwrap();
        reopened.unlock_compartment(compartment_id.clone(), "master pw".into()).unwrap();
        let keys = reopened.list_keys(compartment_id).unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].label, "Persisted key");
    }

    #[test]
    fn protocol_sign_request_prompts_once_then_uses_retention_cache() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let key = vault
            .create_key(
                compartment_id,
                FacadeKeyType::Ed25519,
                FacadePurpose::CustomSigning,
                "k".into(),
                "".into(),
                "svc".into(),
                vec![],
                "key pw".into(),
                None,
                None,
            )
            .unwrap();

        use base64::Engine;
        let message_b64 = base64::engine::general_purpose::STANDARD.encode(b"payload");
        let req = serde_json::json!({
            "method": "vaultsigner.sign",
            "params": { "key_id": key.key_id, "message_b64": message_b64, "algorithm": "ed25519" },
            "id": 1,
        });
        let raw = serde_json::to_vec(&req).unwrap();

        let resp = vault.handle_protocol_request("Test App".into(), raw.clone(), prompter_with("key pw"));
        let resp: serde_json::Value = serde_json::from_slice(&resp).unwrap();
        assert!(resp.get("result").is_some(), "expected success, got {resp:?}");
        assert!(vault.is_key_unlocked(key.key_id));

        // Second call must not need the prompter at all (already cached).
        let resp2 = vault.handle_protocol_request("Test App".into(), raw, prompter_declines());
        let resp2: serde_json::Value = serde_json::from_slice(&resp2).unwrap();
        assert!(resp2.get("result").is_some(), "expected cached signing to succeed, got {resp2:?}");
    }

    #[test]
    fn protocol_sign_wrong_passphrase_returns_passphrase_incorrect() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let key = vault
            .create_key(
                compartment_id,
                FacadeKeyType::Ed25519,
                FacadePurpose::CustomSigning,
                "k".into(),
                "".into(),
                "".into(),
                vec![],
                "right pw".into(),
                None,
                None,
            )
            .unwrap();

        use base64::Engine;
        let req = serde_json::json!({
            "method": "vaultsigner.sign",
            "params": { "key_id": key.key_id, "message_b64": base64::engine::general_purpose::STANDARD.encode(b"m"), "algorithm": "ed25519" },
            "id": 1,
        });
        let resp = vault.handle_protocol_request("caller".into(), serde_json::to_vec(&req).unwrap(), prompter_with("wrong pw"));
        let resp: serde_json::Value = serde_json::from_slice(&resp).unwrap();
        assert_eq!(resp["error"]["code"], "passphrase_incorrect");
    }

    fn cbor_make_credential_request(rp_id: &str, user_id: &[u8], alg: i64) -> Vec<u8> {
        let rp = Value::Map(vec![(Value::Text("id".into()), Value::Text(rp_id.to_string()))]);
        let user = Value::Map(vec![(Value::Text("id".into()), Value::Bytes(user_id.to_vec()))]);
        let params = Value::Array(vec![Value::Map(vec![
            (Value::Text("alg".into()), Value::Integer(alg.into())),
            (Value::Text("type".into()), Value::Text("public-key".into())),
        ])]);
        let fields = vec![
            (1, Value::Bytes(vec![0u8; 32])),
            (2, rp),
            (3, user),
            (4, params),
            (
                7,
                Value::Map(vec![
                    (Value::Text("rk".into()), Value::Bool(true)),
                    (Value::Text("up".into()), Value::Bool(true)),
                ]),
            ),
        ];
        let map = Value::Map(fields.into_iter().map(|(k, v)| (Value::Integer(k.into()), v)).collect());
        let mut body = Vec::new();
        ciborium::into_writer(&map, &mut body).unwrap();
        let mut out = vec![0x01u8];
        out.extend_from_slice(&body);
        out
    }

    fn cbor_get_assertion_request(rp_id: &str) -> Vec<u8> {
        let fields = vec![(1, Value::Text(rp_id.to_string())), (2, Value::Bytes(vec![0u8; 32]))];
        let map = Value::Map(fields.into_iter().map(|(k, v)| (Value::Integer(k.into()), v)).collect());
        let mut body = Vec::new();
        ciborium::into_writer(&map, &mut body).unwrap();
        let mut out = vec![0x02u8];
        out.extend_from_slice(&body);
        out
    }

    #[test]
    fn fido2_make_credential_then_get_assertion_roundtrip() {
        use ctap_types::webauthn::ES256;
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);

        let make_req = cbor_make_credential_request("example.com", b"user-1", ES256 as i64);
        let make_result = vault
            .handle_fido2_make_credential(
                compartment_id.clone(),
                make_req,
                true,
                true,
                "passkey pw".into(),
                "example.com passkey".into(),
                "".into(),
                "example.com".into(),
            )
            .unwrap();
        assert_eq!(make_result.response_cbor[0], 0x00);
        // attestation_object must be exactly response_cbor without its
        // leading status byte (spec §2: decomposed once here, not
        // re-derived by platform code).
        assert_eq!(make_result.attestation_object, make_result.response_cbor[1..]);
        assert_eq!(make_result.rp_id, "example.com");
        assert!(!make_result.credential_id.is_empty());
        assert_eq!(make_result.user_handle, b"user-1");

        let keys = vault.list_keys(compartment_id).unwrap();
        assert_eq!(keys.len(), 1);
        assert!(keys[0].fido2.is_some());
        assert_eq!(keys[0].key_id, make_result.key_id);

        let get_req = cbor_get_assertion_request("example.com");
        let assertion_result = vault
            .handle_fido2_get_assertion(get_req, true, true, prompter_with("passkey pw"))
            .unwrap();
        assert_eq!(assertion_result.response_cbor[0], 0x00);
        assert_eq!(assertion_result.rp_id, "example.com");
        assert_eq!(assertion_result.credential_id, make_result.credential_id);
        assert!(!assertion_result.authenticator_data.is_empty());
        assert!(!assertion_result.signature.is_empty());
        assert!(vault.is_key_unlocked(keys[0].key_id.clone()));
    }

    #[test]
    fn fido2_native_make_credential_then_get_assertion_roundtrip() {
        use ctap_types::webauthn::ES256;
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);

        let make_result = vault
            .handle_fido2_make_credential_native(
                compartment_id.clone(),
                "example.com".into(),
                b"user-1".to_vec(),
                vec![9u8; 32],
                vec![ES256],
                vec![],
                true,
                true,
                true,
                true,
                "passkey pw".into(),
                "example.com passkey".into(),
                "".into(),
                "example.com".into(),
            )
            .unwrap();
        assert_eq!(make_result.rp_id, "example.com");
        assert_eq!(make_result.user_handle, b"user-1");

        let assertion_result = vault
            .handle_fido2_get_assertion_native("example.com".into(), vec![3u8; 32], vec![], false, true, true, prompter_with("passkey pw"))
            .unwrap();
        assert_eq!(assertion_result.credential_id, make_result.credential_id);
        assert!(!assertion_result.signature.is_empty());
    }

    #[test]
    fn credential_candidates_lists_fido2_keys_for_matching_rp() {
        use ctap_types::webauthn::ES256;
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let make_req = cbor_make_credential_request("example.com", b"user-1", ES256 as i64);
        vault
            .handle_fido2_make_credential(compartment_id, make_req, true, true, "pw".into(), "k".into(), "".into(), "".into())
            .unwrap();

        assert_eq!(vault.credential_candidates("example.com".into()).len(), 1);
        assert_eq!(vault.credential_candidates("other.example".into()).len(), 0);
    }

    #[test]
    fn merge_option1_reencrypts_into_target_compartment() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);

        let mut incoming = Manifest::new(Uuid::new_v4());
        let incoming_key_id = Uuid::new_v4();
        incoming.keys.push(KeyEntry {
            key_id: incoming_key_id,
            label: "Imported key".into(),
            description: String::new(),
            resource: "other.example".into(),
            key_type: KeyType::Ed25519,
            purpose: Purpose::CustomSigning,
            fido2: None,
            created_at: time::OffsetDateTime::now_utc(),
            last_used_at: None,
            tags: vec![],
            blob_file: format!("key_blobs/{incoming_key_id}.kblob"),
            blob_sha256: "a".repeat(64),
            public_key_hex: "bb".repeat(32),
        });
        let incoming_json = String::from_utf8(incoming.to_json().unwrap()).unwrap();

        let outcome = vault
            .merge_reencrypt_discard_incoming(
                compartment_id.clone(),
                incoming_json,
                vec![IncomingKeyBlob { key_id: incoming_key_id.to_string(), blob_bytes: b"fake-blob-bytes".to_vec() }],
            )
            .unwrap();
        assert!(outcome.warnings.is_empty());

        let keys = vault.list_keys(compartment_id).unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].label, "Imported key");
    }

    /// Regression test for a real bug found by driving the Android app on
    /// a device and force-stopping it mid-session (see PROGRESS.md's
    /// Phase 4 entry): `merge_reencrypt_discard_incoming`'s in-memory
    /// result (checked by the test above) looked correct, but the merged
    /// key silently vanished after the vault was closed and reopened —
    /// `apply_merge_result` updated `state.unlocked[id].manifest` (the
    /// plaintext working copy) and `state.container.key_blobs` (the raw
    /// sealed key bytes) but never re-encrypted the updated manifest back
    /// into `state.container.master_blobs[id]`, so `write_atomic`
    /// persisted a container whose master blob still decrypts to the
    /// *pre-merge* manifest — orphaning the newly-copied `.kblob` (it's
    /// on disk, but no manifest entry ever points to it again). This test
    /// drops the `Vault` and re-opens the same path from disk, which the
    /// existing `merge_option1_reencrypts_into_target_compartment` test
    /// above never did — checking only the same in-memory instance is
    /// exactly how this got past that test, past `vault.rs`'s other
    /// merge-option-1 coverage, and past macOS's own interactive
    /// verification (see PROGRESS.md's Phase 2 item 2.4 entry, which
    /// explicitly notes only the no-embedded-master-key path — the *same*
    /// facade method, just reached without the duality screen — was
    /// exercised live, and not through a close-then-reopen).
    #[test]
    fn merge_option1_key_survives_close_and_reopen() {
        let dir = tempdir().unwrap();
        let path = vault_path(&dir);
        let (vault, compartment_id) = create_test_vault(&dir);

        let mut incoming = Manifest::new(Uuid::new_v4());
        let incoming_key_id = Uuid::new_v4();
        incoming.keys.push(KeyEntry {
            key_id: incoming_key_id,
            label: "Imported key".into(),
            description: String::new(),
            resource: "other.example".into(),
            key_type: KeyType::Ed25519,
            purpose: Purpose::CustomSigning,
            fido2: None,
            created_at: time::OffsetDateTime::now_utc(),
            last_used_at: None,
            tags: vec![],
            blob_file: format!("key_blobs/{incoming_key_id}.kblob"),
            blob_sha256: "a".repeat(64),
            public_key_hex: "bb".repeat(32),
        });
        let incoming_json = String::from_utf8(incoming.to_json().unwrap()).unwrap();

        vault
            .merge_reencrypt_discard_incoming(
                compartment_id.clone(),
                incoming_json,
                vec![IncomingKeyBlob { key_id: incoming_key_id.to_string(), blob_bytes: b"fake-blob-bytes".to_vec() }],
            )
            .unwrap();

        // The bug: everything above looks fine (same assertions as the
        // test above would pass here too). Drop this instance entirely
        // and re-open the same file fresh, exactly like an app restart.
        drop(vault);
        let reopened = Vault::open(path).unwrap();
        reopened.unlock_compartment(compartment_id.clone(), "master pw".into()).unwrap();

        let keys = reopened.list_keys(compartment_id).unwrap();
        assert_eq!(keys.len(), 1, "the imported key must still be listed after a close+reopen, not just in the same in-memory session");
        assert_eq!(keys[0].label, "Imported key");
    }

    fn create_key_in(vault: &Vault, compartment_id: &str, label: &str, key_passphrase: &str) -> KeyInfo {
        vault
            .create_key(
                compartment_id.to_string(),
                FacadeKeyType::Ed25519,
                FacadePurpose::CustomSigning,
                label.into(),
                "".into(),
                "example.com".into(),
                vec![],
                key_passphrase.into(),
                None,
                None,
            )
            .unwrap()
    }

    #[test]
    fn export_as_is_then_import_into_another_vault_preserves_key_passphrase() {
        let source_dir = tempdir().unwrap();
        let (source, source_compartment) = create_test_vault(&source_dir);
        let key = create_key_in(&source, &source_compartment, "Deploy key", "key pw");

        let packet_bytes = source
            .export_packet(source_compartment, vec![key.key_id.clone()], false, FacadeExportEncryption::AsIs)
            .unwrap();

        let dest_dir = tempdir().unwrap();
        let (dest, dest_compartment) = create_test_vault(&dest_dir);
        let imported = dest.import_packet(packet_bytes, None).unwrap();
        assert!(imported.embedded_master_compartment_id.is_none());
        assert_eq!(imported.key_blobs.len(), 1);

        let outcome = dest
            .merge_reencrypt_discard_incoming(dest_compartment.clone(), imported.manifest_json, imported.key_blobs)
            .unwrap();
        assert!(outcome.warnings.is_empty());

        // The imported key's *own* passphrase (independent of either
        // vault's master password) must still work unchanged.
        dest.unlock_key(dest_compartment, key.key_id.clone(), "key pw".into(), 30).unwrap();
        let signature = dest.sign(key.key_id, b"cross-vault import works".to_vec()).unwrap();
        assert_eq!(signature.len(), 64);
    }

    #[test]
    fn export_with_transfer_password_requires_it_on_import() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let key = create_key_in(&vault, &compartment_id, "k", "key pw");

        let packet_bytes = vault
            .export_packet(
                compartment_id,
                vec![key.key_id],
                false,
                FacadeExportEncryption::OneTimeTransferPassword { password: "transfer secret".into() },
            )
            .unwrap();

        assert!(vault.import_packet(packet_bytes.clone(), None).is_err());
        assert!(vault.import_packet(packet_bytes.clone(), Some("wrong".into())).is_err());
        let imported = vault.import_packet(packet_bytes, Some("transfer secret".into())).unwrap();
        assert_eq!(imported.key_blobs.len(), 1);
    }

    #[test]
    fn export_including_master_key_surfaces_kdf_params_for_option3() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let key = create_key_in(&vault, &compartment_id, "k", "key pw");

        let packet_bytes = vault
            .export_packet(compartment_id.clone(), vec![key.key_id], true, FacadeExportEncryption::AsIs)
            .unwrap();
        let imported = vault.import_packet(packet_bytes, None).unwrap();
        assert_eq!(imported.embedded_master_compartment_id.as_deref(), Some(compartment_id.as_str()));
        assert!(imported.embedded_master_kdf_params_json.is_some());
        // Sanity: it must actually be well-formed KdfParams JSON.
        let _: KdfParams = serde_json::from_str(&imported.embedded_master_kdf_params_json.unwrap()).unwrap();
    }

    #[test]
    fn backup_master_key_only_shortcut_has_no_keys() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        create_key_in(&vault, &compartment_id, "k", "key pw");

        // Spec §5.4's "back up master key only" shortcut: no key_ids.
        let packet_bytes = vault.export_packet(compartment_id, vec![], true, FacadeExportEncryption::AsIs).unwrap();
        let imported = vault.import_packet(packet_bytes, None).unwrap();
        assert!(imported.key_blobs.is_empty());
        assert!(imported.embedded_master_compartment_id.is_some());
    }

    #[test]
    fn export_single_key_produces_an_as_is_importable_packet() {
        let dir = tempdir().unwrap();
        let (vault, compartment_id) = create_test_vault(&dir);
        let key = create_key_in(&vault, &compartment_id, "Solo key", "key pw");

        let vltkey_bytes = vault.export_single_key(compartment_id, key.key_id).unwrap();
        let imported = vault.import_packet(vltkey_bytes, None).unwrap();
        assert_eq!(imported.key_blobs.len(), 1);
        assert!(imported.embedded_master_compartment_id.is_none());
    }
}
