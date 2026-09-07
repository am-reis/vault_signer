use thiserror::Error;

/// Errors surfaced across every `vaultcore` module.
///
/// Variants never carry key material, passphrases, or manifest content —
/// per the threat-model invariant (spec §3) that diagnostic output must
/// never leak sensitive data, error messages here are restricted to
/// structural/opaque information only.
#[derive(Debug, Error)]
pub enum VaultError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("archive error: {0}")]
    Archive(String),

    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("KDF error: {0}")]
    Kdf(String),

    #[error("AEAD encryption failed")]
    EncryptFailed,

    #[error("AEAD decryption failed (wrong key or tampered ciphertext)")]
    DecryptFailed,

    #[error("blob integrity check failed (sha256 mismatch)")]
    IntegrityCheckFailed,

    #[error("unsupported key_type: {0} (v1 accepts only ed25519, ecdsa-p256)")]
    UnsupportedKeyType(String),

    #[error("manifest validation error: {0}")]
    InvalidManifest(String),

    #[error("key generation error: {0}")]
    KeyGen(String),

    #[error("container header error: {0}")]
    InvalidHeader(String),

    #[error("secret is locked out; retry after backoff elapses")]
    LockedOut,

    #[error("key not found: {0}")]
    KeyNotFound(String),
}

pub type Result<T> = std::result::Result<T, VaultError>;
