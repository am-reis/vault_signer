//! Per-key blob format (spec §4.1's `key_blobs/<key_id>.kblob`):
//!
//! ```text
//! kdf_params_key (Argon2id params + unique salt for this key)
//! aead_alg
//! ciphertext = AEAD(key_passphrase_derived_key, raw_private_key || key_metadata_fingerprint)
//! ```
//!
//! `key_metadata_fingerprint` binds the encrypted private key to the
//! manifest metadata describing it (`key_id`, `key_type`, `label`): if a
//! manifest entry and its blob ever drift out of sync (e.g. a corrupted
//! or mismatched restore), [`open`] fails closed with
//! [`VaultError::IntegrityCheckFailed`] instead of silently returning
//! key material for the wrong entry.
//!
//! This module only handles the per-key encryption layer. Whether a
//! given key requires the per-key passphrase *and* an unlocked master
//! key/compartment, and any passphrase-attempt throttling around calling
//! [`open`], are the caller's responsibility (spec §3: opening the vault
//! reveals metadata only, a second independent secret is required per
//! key; §5.5 throttling applies to this entry point too).

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::aead;
use crate::container::AEAD_ALG;
use crate::error::{Result, VaultError};
use crate::kdf::{self, KdfParams};
use crate::manifest::KeyType;

const FINGERPRINT_LEN: usize = 32;

/// Raw private key length for each v1 key type. Both are 32 bytes today
/// (an Ed25519 seed, and a P-256 scalar); kept as a function rather than
/// a shared constant so a future key type with a different length is a
/// one-line addition here, not a search-and-replace.
fn private_key_len(key_type: KeyType) -> usize {
    match key_type {
        KeyType::Ed25519 => 32,
        KeyType::EcdsaP256 => 32,
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyBlob {
    pub kdf_params: KdfParams,
    pub aead_alg: String,
    /// `nonce || ciphertext_with_tag`, as produced by [`aead::encrypt`].
    pub ciphertext: Vec<u8>,
}

impl KeyBlob {
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        Ok(serde_json::from_slice(bytes)?)
    }
}

fn key_metadata_fingerprint(key_id: Uuid, key_type: KeyType, label: &str) -> [u8; FINGERPRINT_LEN] {
    let mut hasher = Sha256::new();
    hasher.update(key_id.as_bytes());
    hasher.update(key_type_tag(key_type));
    hasher.update(label.as_bytes());
    hasher.finalize().into()
}

fn key_type_tag(key_type: KeyType) -> &'static [u8] {
    match key_type {
        KeyType::Ed25519 => b"ed25519",
        KeyType::EcdsaP256 => b"ecdsa-p256",
    }
}

/// AAD binds the ciphertext to its key_id so a `.kblob` file cannot be
/// silently swapped for a different key's blob under the same
/// passphrase and still decrypt.
fn aad_for(key_id: Uuid) -> Vec<u8> {
    key_id.as_bytes().to_vec()
}

/// Encrypt `private_key` under a key derived from `passphrase` and
/// `kdf_params` (the caller supplies already-benchmarked params — see
/// `kdf::benchmark` — so this function never benchmarks itself). The
/// caller must zeroize `private_key` and `passphrase` after this
/// returns; nothing here retains them beyond the call.
pub fn seal(
    passphrase: &[u8],
    private_key: &[u8],
    key_id: Uuid,
    key_type: KeyType,
    label: &str,
    kdf_params: KdfParams,
) -> Result<KeyBlob> {
    if private_key.len() != private_key_len(key_type) {
        return Err(VaultError::KeyGen(format!(
            "private key length {} does not match expected {} for {key_type:?}",
            private_key.len(),
            private_key_len(key_type)
        )));
    }
    let derived = kdf::derive(passphrase, &kdf_params)?;
    let mut plaintext = Zeroizing::new(Vec::with_capacity(private_key.len() + FINGERPRINT_LEN));
    plaintext.extend_from_slice(private_key);
    plaintext.extend_from_slice(&key_metadata_fingerprint(key_id, key_type, label));

    let ciphertext = aead::encrypt(&derived, &plaintext, &aad_for(key_id))?;
    Ok(KeyBlob {
        kdf_params,
        aead_alg: AEAD_ALG.to_string(),
        ciphertext,
    })
}

/// Decrypt `blob` with `passphrase`, verifying it matches the manifest
/// metadata (`key_id`, `key_type`, `label`) currently on record for it.
/// Fails closed — wrong passphrase, tampered ciphertext, and
/// metadata/blob desync are all indistinguishable
/// [`VaultError::DecryptFailed`] /
/// [`VaultError::IntegrityCheckFailed`] outcomes, never a silent return
/// of the wrong key.
pub fn open(
    blob: &KeyBlob,
    passphrase: &[u8],
    key_id: Uuid,
    key_type: KeyType,
    label: &str,
) -> Result<Zeroizing<Vec<u8>>> {
    let derived = kdf::derive(passphrase, &blob.kdf_params)?;
    let plaintext = aead::decrypt(&derived, &blob.ciphertext, &aad_for(key_id))?;

    let expected_len = private_key_len(key_type) + FINGERPRINT_LEN;
    if plaintext.len() != expected_len {
        return Err(VaultError::IntegrityCheckFailed);
    }
    let (private_key, fingerprint) = plaintext.split_at(private_key_len(key_type));
    let expected_fingerprint = key_metadata_fingerprint(key_id, key_type, label);
    if fingerprint != expected_fingerprint {
        return Err(VaultError::IntegrityCheckFailed);
    }

    Ok(Zeroizing::new(private_key.to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kdf::{FLOOR_ITERATIONS, FLOOR_MEMORY_KIB, FLOOR_PARALLELISM};

    fn test_params() -> KdfParams {
        KdfParams::new(FLOOR_MEMORY_KIB, FLOOR_ITERATIONS, FLOOR_PARALLELISM).unwrap()
    }

    #[test]
    fn seal_and_open_roundtrip() {
        let key_id = Uuid::new_v4();
        let private_key = [7u8; 32];
        let blob = seal(
            b"correct horse battery staple",
            &private_key,
            key_id,
            KeyType::Ed25519,
            "Deploy signing key",
            test_params(),
        )
        .unwrap();

        let opened = open(&blob, b"correct horse battery staple", key_id, KeyType::Ed25519, "Deploy signing key").unwrap();
        assert_eq!(&*opened, &private_key);
    }

    #[test]
    fn wrong_passphrase_fails_closed() {
        let key_id = Uuid::new_v4();
        let blob = seal(b"right", &[1u8; 32], key_id, KeyType::Ed25519, "k", test_params()).unwrap();
        assert!(open(&blob, b"wrong", key_id, KeyType::Ed25519, "k").is_err());
    }

    #[test]
    fn mismatched_key_id_fails_closed_even_with_right_passphrase() {
        let key_id = Uuid::new_v4();
        let other_id = Uuid::new_v4();
        let blob = seal(b"pw", &[1u8; 32], key_id, KeyType::Ed25519, "k", test_params()).unwrap();
        // Right passphrase, but decrypting as if this blob belonged to a
        // different key_id must fail (AAD mismatch).
        assert!(open(&blob, b"pw", other_id, KeyType::Ed25519, "k").is_err());
    }

    #[test]
    fn label_desync_detected_via_fingerprint() {
        let key_id = Uuid::new_v4();
        let blob = seal(b"pw", &[1u8; 32], key_id, KeyType::Ed25519, "Original label", test_params()).unwrap();
        // AAD (key_id) matches, so AEAD decryption itself succeeds; the
        // fingerprint check must be what catches the metadata mismatch.
        let result = open(&blob, b"pw", key_id, KeyType::Ed25519, "Renamed label");
        assert!(matches!(result, Err(VaultError::IntegrityCheckFailed)));
    }

    #[test]
    fn key_type_desync_detected() {
        let key_id = Uuid::new_v4();
        let blob = seal(b"pw", &[1u8; 32], key_id, KeyType::Ed25519, "k", test_params()).unwrap();
        let result = open(&blob, b"pw", key_id, KeyType::EcdsaP256, "k");
        assert!(result.is_err());
    }

    #[test]
    fn rejects_wrong_length_private_key_at_seal_time() {
        let result = seal(b"pw", &[1u8; 16], Uuid::new_v4(), KeyType::Ed25519, "k", test_params());
        assert!(result.is_err());
    }

    #[test]
    fn blob_bytes_roundtrip() {
        let key_id = Uuid::new_v4();
        let blob = seal(b"pw", &[9u8; 32], key_id, KeyType::EcdsaP256, "k", test_params()).unwrap();
        let bytes = blob.to_bytes().unwrap();
        let back = KeyBlob::from_bytes(&bytes).unwrap();
        let opened = open(&back, b"pw", key_id, KeyType::EcdsaP256, "k").unwrap();
        assert_eq!(&*opened, &[9u8; 32]);
    }
}
