//! Manifest schema (spec §4.4), stored as JSON inside the encrypted
//! master blob. `key_type` accepts only `ed25519` and `ecdsa-p256` in
//! v1 — any other value is rejected at parse time by construction, since
//! `KeyType` has no other variants; do not add `ecdsa-p384` or `rsa-2048`
//! here until a future manifest version explicitly scopes that addition
//! (spec §1.2, §4.3, §4.4).

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::error::{Result, VaultError};

pub const MANIFEST_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum KeyType {
    Ed25519,
    EcdsaP256,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Purpose {
    Fido2,
    CustomSigning,
    Both,
}

impl Purpose {
    pub fn includes_fido2(self) -> bool {
        matches!(self, Purpose::Fido2 | Purpose::Both)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fido2Info {
    pub rp_id: String,
    pub credential_id_b64: String,
    pub user_handle_b64: String,
    /// Persisted and incremented on every assertion; CTAP2 requires this
    /// for relying-party clone detection (spec §4.4).
    pub sign_count: u32,
    pub discoverable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyEntry {
    pub key_id: Uuid,
    pub label: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub resource: String,
    pub key_type: KeyType,
    pub purpose: Purpose,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fido2: Option<Fido2Info>,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339::option", default)]
    pub last_used_at: Option<OffsetDateTime>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub blob_file: String,
    pub blob_sha256: String,
}

impl KeyEntry {
    /// Enforces the invariant that the `fido2` block is present iff
    /// `purpose` includes fido2 (spec §4.4).
    pub fn validate(&self) -> Result<()> {
        let has_fido2 = self.fido2.is_some();
        if self.purpose.includes_fido2() != has_fido2 {
            return Err(VaultError::InvalidManifest(format!(
                "key {}: fido2 block presence ({has_fido2}) does not match purpose ({:?})",
                self.key_id, self.purpose
            )));
        }
        if self.blob_sha256.len() != 64 || !self.blob_sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(VaultError::InvalidManifest(format!(
                "key {}: blob_sha256 must be a 64-char hex digest",
                self.key_id
            )));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub manifest_version: u32,
    pub vault_id: Uuid,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(default)]
    pub keys: Vec<KeyEntry>,
}

impl Manifest {
    pub fn new(vault_id: Uuid) -> Self {
        Self {
            manifest_version: MANIFEST_VERSION,
            vault_id,
            created_at: OffsetDateTime::now_utc(),
            keys: Vec::new(),
        }
    }

    /// Validates the manifest as a whole: version, per-key invariants,
    /// and key_id uniqueness. Called on every parse of untrusted/on-disk
    /// data before it is used.
    pub fn validate(&self) -> Result<()> {
        if self.manifest_version != MANIFEST_VERSION {
            return Err(VaultError::InvalidManifest(format!(
                "unsupported manifest_version {} (expected {MANIFEST_VERSION})",
                self.manifest_version
            )));
        }
        let mut seen = std::collections::HashSet::new();
        for key in &self.keys {
            key.validate()?;
            if !seen.insert(key.key_id) {
                return Err(VaultError::InvalidManifest(format!(
                    "duplicate key_id in manifest: {}",
                    key.key_id
                )));
            }
        }
        Ok(())
    }

    pub fn to_json(&self) -> Result<Vec<u8>> {
        self.validate()?;
        Ok(serde_json::to_vec_pretty(self)?)
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        let manifest: Self = serde_json::from_slice(bytes)?;
        manifest.validate()?;
        Ok(manifest)
    }
}

/// SHA-256 digest of a key blob, hex-encoded, for the manifest's
/// `blob_sha256` integrity field (spec §4.4) — lets a corrupted/truncated
/// blob be detected before an expensive Argon2id derivation is attempted.
pub fn blob_sha256_hex(blob_bytes: &[u8]) -> String {
    let digest = Sha256::digest(blob_bytes);
    hex::encode(digest)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_key(purpose: Purpose, fido2: Option<Fido2Info>) -> KeyEntry {
        KeyEntry {
            key_id: Uuid::new_v4(),
            label: "Deploy signing key".into(),
            description: String::new(),
            resource: "example.com".into(),
            key_type: KeyType::Ed25519,
            purpose,
            fido2,
            created_at: OffsetDateTime::now_utc(),
            last_used_at: None,
            tags: vec![],
            blob_file: "key_blobs/x.kblob".into(),
            blob_sha256: "a".repeat(64),
        }
    }

    fn sample_fido2() -> Fido2Info {
        Fido2Info {
            rp_id: "example.com".into(),
            credential_id_b64: "abc".into(),
            user_handle_b64: "def".into(),
            sign_count: 0,
            discoverable: true,
        }
    }

    #[test]
    fn rejects_unknown_key_type_at_parse_time() {
        let json = r#"{"key_id":"00000000-0000-0000-0000-000000000000","label":"x",
            "key_type":"rsa-2048","purpose":"custom-signing",
            "created_at":"2024-01-01T00:00:00Z","blob_file":"key_blobs/x.kblob",
            "blob_sha256":""}"#;
        let result: std::result::Result<KeyEntry, _> = serde_json::from_str(json);
        assert!(result.is_err(), "rsa-2048 must be rejected in v1");
    }

    #[test]
    fn rejects_ecdsa_p384_at_parse_time() {
        let json = r#"{"key_id":"00000000-0000-0000-0000-000000000000","label":"x",
            "key_type":"ecdsa-p384","purpose":"custom-signing",
            "created_at":"2024-01-01T00:00:00Z","blob_file":"key_blobs/x.kblob",
            "blob_sha256":""}"#;
        let result: std::result::Result<KeyEntry, _> = serde_json::from_str(json);
        assert!(result.is_err());
    }

    #[test]
    fn fido2_purpose_requires_fido2_block() {
        let key = sample_key(Purpose::Fido2, None);
        assert!(key.validate().is_err());
        let key = sample_key(Purpose::Fido2, Some(sample_fido2()));
        assert!(key.validate().is_ok());
    }

    #[test]
    fn custom_signing_purpose_rejects_fido2_block() {
        let key = sample_key(Purpose::CustomSigning, Some(sample_fido2()));
        assert!(key.validate().is_err());
        let key = sample_key(Purpose::CustomSigning, None);
        assert!(key.validate().is_ok());
    }

    #[test]
    fn both_purpose_requires_fido2_block() {
        let key = sample_key(Purpose::Both, Some(sample_fido2()));
        assert!(key.validate().is_ok());
        let key = sample_key(Purpose::Both, None);
        assert!(key.validate().is_err());
    }

    #[test]
    fn duplicate_key_ids_rejected() {
        let mut manifest = Manifest::new(Uuid::new_v4());
        let key = sample_key(Purpose::CustomSigning, None);
        manifest.keys.push(key.clone());
        manifest.keys.push(key);
        assert!(manifest.validate().is_err());
    }

    #[test]
    fn manifest_roundtrips_through_json() {
        let mut manifest = Manifest::new(Uuid::new_v4());
        manifest.keys.push(sample_key(Purpose::Both, Some(sample_fido2())));
        let json = manifest.to_json().unwrap();
        let back = Manifest::from_json(&json).unwrap();
        assert_eq!(manifest.vault_id, back.vault_id);
        assert_eq!(back.keys.len(), 1);
    }

    #[test]
    fn wrong_manifest_version_rejected() {
        let mut manifest = Manifest::new(Uuid::new_v4());
        manifest.manifest_version = 2;
        assert!(manifest.validate().is_err());
    }

    #[test]
    fn blob_sha256_hex_is_stable() {
        let a = blob_sha256_hex(b"hello world");
        let b = blob_sha256_hex(b"hello world");
        assert_eq!(a, b);
        assert_eq!(a.len(), 64);
        assert_ne!(a, blob_sha256_hex(b"hello world!"));
    }
}
