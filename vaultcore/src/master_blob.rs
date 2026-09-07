//! Master-key compartment blob (spec §4.1): what a compartment's
//! `encrypted_master_blob` decrypts to — `manifest.json` plus
//! `key_index` (the list of `key_id`s owned by that compartment).
//!
//! `key_index` is redundant with `manifest.keys[].key_id` (the spec's
//! tree lists both explicitly, presumably so a reader can enumerate a
//! compartment's keys without walking the full manifest); [`validate`]
//! enforces they always agree so that redundancy can't silently drift.
//!
//! Opening a vault (the master password) reveals this plaintext —
//! metadata only, never raw key material (spec §3, §4.1). Each key's
//! own private bytes stay behind the independent per-key passphrase
//! layer in `keyblob.rs`.
//!
//! [`decrypt`] returns a plain (not `Zeroizing`) [`MasterBlobPlaintext`]:
//! `Manifest` pulls in third-party types (`Uuid`, `OffsetDateTime`) that
//! don't implement `Zeroize`, and this data is metadata (labels,
//! resource/rp_id values), not the raw private key material spec §3's
//! zeroizing invariant is written around. The caller is still
//! responsible for not logging or persisting it beyond the retention
//! cache's normal lifetime.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::aead;
use crate::error::{Result, VaultError};
use crate::kdf::{self, KdfParams};
use crate::manifest::Manifest;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MasterBlobPlaintext {
    pub manifest: Manifest,
    pub key_index: Vec<Uuid>,
}

impl MasterBlobPlaintext {
    /// Builds `key_index` from `manifest.keys` so the two can never
    /// disagree at construction time.
    pub fn new(manifest: Manifest) -> Self {
        let key_index = manifest.keys.iter().map(|k| k.key_id).collect();
        Self { manifest, key_index }
    }

    pub fn validate(&self) -> Result<()> {
        self.manifest.validate()?;
        let manifest_ids: HashSet<Uuid> = self.manifest.keys.iter().map(|k| k.key_id).collect();
        let index_ids: HashSet<Uuid> = self.key_index.iter().copied().collect();
        if manifest_ids != index_ids {
            return Err(VaultError::InvalidManifest(
                "key_index does not match the set of key_ids in manifest.keys".into(),
            ));
        }
        if index_ids.len() != self.key_index.len() {
            return Err(VaultError::InvalidManifest("key_index contains duplicate key_ids".into()));
        }
        Ok(())
    }

    fn to_json(&self) -> Result<Vec<u8>> {
        self.validate()?;
        Ok(serde_json::to_vec(self)?)
    }

    fn from_json(bytes: &[u8]) -> Result<Self> {
        let value: Self = serde_json::from_slice(bytes)?;
        value.validate()?;
        Ok(value)
    }
}

/// AAD binds the ciphertext to the compartment it belongs to, so a
/// master blob cannot be silently swapped between compartments under
/// the same passphrase and still decrypt.
fn aad_for(compartment_id: Uuid) -> Vec<u8> {
    compartment_id.as_bytes().to_vec()
}

/// Encrypt a compartment's manifest for storage as
/// `Container::master_blobs[compartment_id]`. The caller supplies
/// already-benchmarked `kdf_params` (see `kdf::benchmark`); this
/// function never benchmarks itself.
pub fn encrypt(compartment_id: Uuid, manifest: Manifest, passphrase: &[u8], kdf_params: &KdfParams) -> Result<Vec<u8>> {
    let plaintext = MasterBlobPlaintext::new(manifest);
    let json = plaintext.to_json()?;
    let derived = kdf::derive(passphrase, kdf_params)?;
    aead::encrypt(&derived, &json, &aad_for(compartment_id))
}

/// Decrypt a compartment's master blob back into its plaintext manifest
/// and key_index. See the module doc comment for why this isn't wrapped
/// in `Zeroizing`.
pub fn decrypt(
    compartment_id: Uuid,
    nonce_and_ciphertext: &[u8],
    passphrase: &[u8],
    kdf_params: &KdfParams,
) -> Result<MasterBlobPlaintext> {
    let derived = kdf::derive(passphrase, kdf_params)?;
    let json = aead::decrypt(&derived, nonce_and_ciphertext, &aad_for(compartment_id))?;
    MasterBlobPlaintext::from_json(&json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kdf::{FLOOR_ITERATIONS, FLOOR_MEMORY_KIB, FLOOR_PARALLELISM};

    fn test_params() -> KdfParams {
        KdfParams::new(FLOOR_MEMORY_KIB, FLOOR_ITERATIONS, FLOOR_PARALLELISM).unwrap()
    }

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let compartment_id = Uuid::new_v4();
        let manifest = Manifest::new(Uuid::new_v4());
        let params = test_params();
        let ct = encrypt(compartment_id, manifest.clone(), b"master pw", &params).unwrap();
        let back = decrypt(compartment_id, &ct, b"master pw", &params).unwrap();
        assert_eq!(back.manifest.vault_id, manifest.vault_id);
    }

    #[test]
    fn wrong_passphrase_fails_closed() {
        let compartment_id = Uuid::new_v4();
        let manifest = Manifest::new(Uuid::new_v4());
        let params = test_params();
        let ct = encrypt(compartment_id, manifest, b"right", &params).unwrap();
        assert!(decrypt(compartment_id, &ct, b"wrong", &params).is_err());
    }

    #[test]
    fn wrong_compartment_fails_closed() {
        let compartment_id = Uuid::new_v4();
        let other_id = Uuid::new_v4();
        let manifest = Manifest::new(Uuid::new_v4());
        let params = test_params();
        let ct = encrypt(compartment_id, manifest, b"pw", &params).unwrap();
        assert!(decrypt(other_id, &ct, b"pw", &params).is_err());
    }

    #[test]
    fn key_index_out_of_sync_rejected() {
        let mut plaintext = MasterBlobPlaintext::new(Manifest::new(Uuid::new_v4()));
        plaintext.key_index.push(Uuid::new_v4()); // not present in manifest.keys
        assert!(plaintext.validate().is_err());
    }
}
