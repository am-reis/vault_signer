//! Export packets (spec §5.2): `.vltkey` (single key) and `.vltpack`
//! (multiple keys, optionally the master key too), both "the same
//! archive format as `.vlt`" per spec §4.1 — built on
//! `container::build_archive_bytes`/`parse_archive_bytes`, the same
//! generic zip-entry primitives the container format itself uses, rather
//! than inventing a second archive layout.
//!
//! Two layers, matching spec §5.2 exactly:
//! - The **inner packet**: a manifest fragment (metadata for the
//!   selected keys only), their `.kblob` files copied byte-for-byte
//!   (each already independently encrypted under its own per-key
//!   passphrase — this module never touches that layer), and optionally
//!   the sender's still-encrypted `encrypted_master_blob` + the KDF
//!   parameters it was sealed under (spec §5.2.1's "include master key"
//!   toggle) — copied as opaque ciphertext, never decrypted here either.
//! - The **transfer-encryption wrapper** (spec §5.2.2): option 1 ("just
//!   package the keys as-is") ships the inner packet's bytes completely
//!   unwrapped — its manifest fragment travels in the clear, exactly as
//!   spec §5.2.2 discloses. Options 2 and 3 wrap those same bytes in one
//!   additional AEAD layer keyed off, respectively, the destination
//!   vault's master password or a fresh one-time transfer password (spec
//!   §5.2.2 requires *both* the manifest fragment and the key blobs to
//!   be covered by this layer when it's used — wrapping the fully-built
//!   inner-packet bytes rather than re-wrapping each piece separately
//!   achieves that by construction).
//!
//! What this module does **not** do: decide *how* to merge an imported
//! packet into a local vault (spec §5.3) — that is `merge.rs`'s job,
//! unchanged. [`import_packet`] only unwraps the transfer-encryption
//! layer (if any) and hands back the inner packet's plain contents;
//! turning that into a `Manifest` for `merge.rs` and deciding which of
//! the three duality options to apply is the caller's (the `Vault`
//! facade's) job.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::aead;
use crate::container::{build_archive_bytes, parse_archive_bytes};
use crate::error::{Result, VaultError};
use crate::kdf::{self, KdfParams};
use crate::manifest::KeyEntry;

const PACKET_HEADER_ENTRY: &str = "packet.json";
const KEY_BLOBS_DIR: &str = "key_blobs";
const MASTER_ENTRY: &str = "master.blob";

const WRAPPER_HEADER_ENTRY: &str = "wrapper.json";
const SEALED_ENTRY: &str = "sealed.bin";

/// The sender's still-encrypted master-key material for one compartment,
/// carried opaquely (spec §5.2.1). Never decrypted by this module.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddedMasterKey {
    pub compartment_id: Uuid,
    pub kdf_params_master: KdfParams,
}

/// The inner packet's plain contents, once any transfer-encryption
/// wrapper has been removed (or if there never was one).
#[derive(Debug, Clone)]
pub struct InnerPacket {
    /// The manifest fragment: metadata for the selected keys only.
    pub keys: Vec<KeyEntry>,
    /// key_id -> that key's raw `.kblob` bytes, copied unchanged.
    pub key_blobs: HashMap<Uuid, Vec<u8>>,
    pub embedded_master: Option<EmbeddedMasterKey>,
    /// The embedded master's own still-encrypted blob bytes, if present
    /// — kept separate from [`EmbeddedMasterKey`] since a caller
    /// deciding *how* to merge (spec §5.3) mostly only needs the KDF
    /// params, not these bytes (see `packet.rs`'s module doc).
    pub embedded_master_blob: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PacketHeader {
    keys: Vec<KeyEntry>,
    embedded_master: Option<EmbeddedMasterKey>,
}

fn key_blob_entry_name(key_id: Uuid) -> String {
    format!("{KEY_BLOBS_DIR}/{key_id}.kblob")
}

/// Build the inner packet's raw archive bytes (spec §5.2's shared
/// `.vltkey`/`.vltpack` shape). `key_blobs` must contain an entry for
/// every `key_id` referenced in `keys`.
pub fn build_inner_packet(
    keys: Vec<KeyEntry>,
    key_blobs: &HashMap<Uuid, Vec<u8>>,
    embedded_master: Option<(EmbeddedMasterKey, Vec<u8>)>,
) -> Result<Vec<u8>> {
    for key in &keys {
        if !key_blobs.contains_key(&key.key_id) {
            return Err(VaultError::InvalidManifest(format!("missing key blob for key_id {}", key.key_id)));
        }
    }

    let (embedded_master_meta, embedded_master_blob) = match embedded_master {
        Some((meta, blob)) => (Some(meta), Some(blob)),
        None => (None, None),
    };

    let header = PacketHeader { keys: keys.clone(), embedded_master: embedded_master_meta };
    let mut entries = Vec::with_capacity(2 + keys.len());
    entries.push((PACKET_HEADER_ENTRY.to_string(), serde_json::to_vec_pretty(&header)?));
    for key in &keys {
        let blob = key_blobs.get(&key.key_id).expect("checked above");
        entries.push((key_blob_entry_name(key.key_id), blob.clone()));
    }
    if let Some(blob) = embedded_master_blob {
        entries.push((MASTER_ENTRY.to_string(), blob));
    }

    build_archive_bytes(&entries)
}

/// Parse an inner packet's raw archive bytes back out (the inverse of
/// [`build_inner_packet`]).
pub fn parse_inner_packet(bytes: &[u8]) -> Result<InnerPacket> {
    let mut entries = parse_archive_bytes(bytes)?;
    let header_bytes = entries
        .remove(PACKET_HEADER_ENTRY)
        .ok_or_else(|| VaultError::InvalidHeader("missing packet.json".into()))?;
    let header: PacketHeader = serde_json::from_slice(&header_bytes)?;

    let mut key_blobs = HashMap::with_capacity(header.keys.len());
    for key in &header.keys {
        let name = key_blob_entry_name(key.key_id);
        let blob = entries
            .remove(&name)
            .ok_or_else(|| VaultError::InvalidHeader(format!("packet is missing blob for key_id {}", key.key_id)))?;
        key_blobs.insert(key.key_id, blob);
    }
    let embedded_master_blob = entries.remove(MASTER_ENTRY);
    if header.embedded_master.is_some() != embedded_master_blob.is_some() {
        return Err(VaultError::InvalidHeader("packet's embedded-master metadata and blob disagree on presence".into()));
    }

    Ok(InnerPacket { keys: header.keys, key_blobs, embedded_master: header.embedded_master, embedded_master_blob })
}

/// Spec §5.2.2's three export-encryption choices.
pub enum ExportEncryption<'a> {
    /// Option 1: "Just package the keys as-is" — no additional layer;
    /// the manifest fragment travels in the clear.
    AsIs,
    /// Option 2: "Re-encrypt for the destination vault's master
    /// password" — the caller supplies that password directly.
    DestinationMasterPassword(&'a [u8]),
    /// Option 3: "Protect with a one-time transfer password".
    OneTimeTransferPassword(&'a [u8]),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WrapperHeader {
    kdf_params: KdfParams,
}

fn wrap(inner_bytes: &[u8], passphrase: &[u8]) -> Result<Vec<u8>> {
    let kdf_params = KdfParams::new(kdf::FLOOR_MEMORY_KIB, kdf::FLOOR_ITERATIONS, kdf::FLOOR_PARALLELISM)?;
    let derived = kdf::derive(passphrase, &kdf_params)?;
    let sealed = aead::encrypt(&derived, inner_bytes, &[])?;
    let header = WrapperHeader { kdf_params };
    build_archive_bytes(&[
        (WRAPPER_HEADER_ENTRY.to_string(), serde_json::to_vec(&header)?),
        (SEALED_ENTRY.to_string(), sealed),
    ])
}

/// Produce the final `.vltpack`/`.vltkey` bytes for `inner_bytes`
/// (from [`build_inner_packet`]) under the chosen export-encryption
/// option.
pub fn export_packet(inner_bytes: Vec<u8>, encryption: ExportEncryption<'_>) -> Result<Vec<u8>> {
    match encryption {
        ExportEncryption::AsIs => Ok(inner_bytes),
        ExportEncryption::DestinationMasterPassword(password) => wrap(&inner_bytes, password),
        ExportEncryption::OneTimeTransferPassword(password) => wrap(&inner_bytes, password),
    }
}

/// Unwrap and parse a `.vltpack`/`.vltkey`'s bytes back into an
/// [`InnerPacket`] (spec §5.3 step 1: "Decrypt the transfer/wrapping
/// layer if present"). `transfer_password` is required if — and only
/// if — the packet was produced with
/// [`ExportEncryption::DestinationMasterPassword`] or
/// [`ExportEncryption::OneTimeTransferPassword`]; which one it was is
/// indistinguishable from the bytes alone (both use the identical
/// wrapper shape), which is intentional — the caller already knows
/// which password to prompt for based on how the packet arrived.
pub fn import_packet(bytes: &[u8], transfer_password: Option<&[u8]>) -> Result<InnerPacket> {
    // An "as-is" (option 1) packet parses directly as an inner packet;
    // a wrapped one (option 2/3) parses as a two-entry wrapper archive
    // instead. Distinguish by trying the wrapper shape first, since its
    // header name is unambiguous.
    if let Ok(entries) = parse_archive_bytes(bytes) {
        if entries.contains_key(WRAPPER_HEADER_ENTRY) {
            let header: WrapperHeader = serde_json::from_slice(
                entries.get(WRAPPER_HEADER_ENTRY).expect("checked contains_key"),
            )?;
            let sealed = entries.get(SEALED_ENTRY).ok_or_else(|| VaultError::InvalidHeader("wrapped packet missing sealed.bin".into()))?;
            let password = transfer_password.ok_or_else(|| {
                VaultError::InvalidManifest("this packet is transfer-encrypted; a password is required to import it".into())
            })?;
            let derived = kdf::derive(password, &header.kdf_params)?;
            let inner_bytes = aead::decrypt(&derived, sealed, &[])?;
            return parse_inner_packet(&inner_bytes);
        }
    }
    parse_inner_packet(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{KeyType, Purpose};
    use time::OffsetDateTime;

    fn sample_key(label: &str) -> (KeyEntry, Vec<u8>) {
        let key_id = Uuid::new_v4();
        let entry = KeyEntry {
            key_id,
            label: label.to_string(),
            description: String::new(),
            resource: "example.com".into(),
            key_type: KeyType::Ed25519,
            purpose: Purpose::CustomSigning,
            fido2: None,
            created_at: OffsetDateTime::now_utc(),
            last_used_at: None,
            tags: vec![],
            blob_file: format!("key_blobs/{key_id}.kblob"),
            blob_sha256: "a".repeat(64),
            public_key_hex: "bb".repeat(32),
        };
        (entry, b"fake-encrypted-kblob-bytes".to_vec())
    }

    #[test]
    fn as_is_roundtrips_and_travels_unwrapped() {
        let (key, blob) = sample_key("Deploy key");
        let mut blobs = HashMap::new();
        blobs.insert(key.key_id, blob.clone());

        let inner = build_inner_packet(vec![key.clone()], &blobs, None).unwrap();
        let packet_bytes = export_packet(inner.clone(), ExportEncryption::AsIs).unwrap();
        // Option 1 ships the inner bytes completely unwrapped.
        assert_eq!(packet_bytes, inner);

        let imported = import_packet(&packet_bytes, None).unwrap();
        assert_eq!(imported.keys.len(), 1);
        assert_eq!(imported.keys[0].label, "Deploy key");
        assert_eq!(imported.key_blobs.get(&key.key_id).unwrap(), &blob);
        assert!(imported.embedded_master.is_none());
    }

    #[test]
    fn wrapped_packet_requires_password_and_hides_manifest_without_it() {
        let (key, blob) = sample_key("Deploy key");
        let mut blobs = HashMap::new();
        blobs.insert(key.key_id, blob);
        let inner = build_inner_packet(vec![key], &blobs, None).unwrap();

        let packet_bytes = export_packet(inner, ExportEncryption::OneTimeTransferPassword(b"correct horse")).unwrap();

        assert!(import_packet(&packet_bytes, None).is_err(), "must require a password");
        assert!(import_packet(&packet_bytes, Some(b"wrong")).is_err());

        // The manifest fragment must not be readable without unwrapping.
        assert!(String::from_utf8_lossy(&packet_bytes).find("Deploy key").is_none());

        let imported = import_packet(&packet_bytes, Some(b"correct horse")).unwrap();
        assert_eq!(imported.keys[0].label, "Deploy key");
    }

    #[test]
    fn embedded_master_key_roundtrips() {
        let (key, blob) = sample_key("Passkey");
        let mut blobs = HashMap::new();
        blobs.insert(key.key_id, blob);
        let compartment_id = Uuid::new_v4();
        let kdf_params = KdfParams::new(kdf::FLOOR_MEMORY_KIB, kdf::FLOOR_ITERATIONS, kdf::FLOOR_PARALLELISM).unwrap();
        let meta = EmbeddedMasterKey { compartment_id, kdf_params_master: kdf_params };
        let master_blob_bytes = b"fake-encrypted-master-blob".to_vec();

        let inner = build_inner_packet(vec![key], &blobs, Some((meta, master_blob_bytes.clone()))).unwrap();
        let imported = import_packet(&inner, None).unwrap();
        let embedded = imported.embedded_master.unwrap();
        assert_eq!(embedded.compartment_id, compartment_id);
        assert_eq!(imported.embedded_master_blob.unwrap(), master_blob_bytes);
    }

    #[test]
    fn missing_blob_for_a_listed_key_is_rejected_at_build_time() {
        let (key, _) = sample_key("Orphaned");
        let result = build_inner_packet(vec![key], &HashMap::new(), None);
        assert!(result.is_err());
    }

    #[test]
    fn tampered_wrapped_packet_fails_closed() {
        let (key, blob) = sample_key("k");
        let mut blobs = HashMap::new();
        blobs.insert(key.key_id, blob);
        let inner = build_inner_packet(vec![key], &blobs, None).unwrap();
        let mut packet_bytes = export_packet(inner, ExportEncryption::OneTimeTransferPassword(b"pw")).unwrap();
        let last = packet_bytes.len() - 1;
        packet_bytes[last] ^= 0xFF;
        assert!(import_packet(&packet_bytes, Some(b"pw")).is_err());
    }
}
