//! AEAD wrapper (spec §4.3): XChaCha20-Poly1305, 256-bit keys, 24-byte
//! random nonces, project-wide for container/manifest/key-blob encryption.
//!
//! Note on the RustCrypto crate name: the spec's "xchacha20poly1305 crate"
//! refers to the RustCrypto AEAD implementation, which is published as the
//! `chacha20poly1305` crate and exposes the `XChaCha20Poly1305` type used
//! here — there is no separately published `xchacha20poly1305` crate.

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use zeroize::Zeroizing;

use crate::error::{Result, VaultError};

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 24;

pub fn random_nonce() -> Result<[u8; NONCE_LEN]> {
    let mut nonce = [0u8; NONCE_LEN];
    getrandom::fill(&mut nonce).map_err(|e| VaultError::Kdf(e.to_string()))?;
    Ok(nonce)
}

/// Encrypt `plaintext` under `key`, with an optional `aad` (associated
/// data, e.g. a key-id fingerprint) authenticated but not encrypted.
/// Returns `nonce || ciphertext_with_tag`.
pub fn encrypt(key: &[u8; KEY_LEN], plaintext: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
    let cipher = XChaCha20Poly1305::new(&Key::from(*key));
    let nonce_bytes = random_nonce()?;
    let nonce = XNonce::from(nonce_bytes);
    let ciphertext = cipher
        .encrypt(
            &nonce,
            chacha20poly1305::aead::Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| VaultError::EncryptFailed)?;
    let mut out = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// Decrypt a buffer produced by [`encrypt`]. Returns a `Zeroizing` buffer
/// since the plaintext is, in every real call site, key material or a
/// manifest containing sensitive metadata.
pub fn decrypt(key: &[u8; KEY_LEN], nonce_and_ciphertext: &[u8], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if nonce_and_ciphertext.len() < NONCE_LEN {
        return Err(VaultError::DecryptFailed);
    }
    let (nonce_bytes, ciphertext) = nonce_and_ciphertext.split_at(NONCE_LEN);
    let cipher = XChaCha20Poly1305::new(&Key::from(*key));
    let nonce = XNonce::try_from(nonce_bytes).map_err(|_| VaultError::DecryptFailed)?;
    let plaintext = cipher
        .decrypt(&nonce, chacha20poly1305::aead::Payload { msg: ciphertext, aad })
        .map_err(|_| VaultError::DecryptFailed)?;
    Ok(Zeroizing::new(plaintext))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> [u8; KEY_LEN] {
        [0x42u8; KEY_LEN]
    }

    #[test]
    fn roundtrip() {
        let key = test_key();
        let ct = encrypt(&key, b"top secret private key bytes", b"key-id-fingerprint").unwrap();
        let pt = decrypt(&key, &ct, b"key-id-fingerprint").unwrap();
        assert_eq!(&*pt, b"top secret private key bytes");
    }

    #[test]
    fn wrong_key_fails_closed() {
        let ct = encrypt(&test_key(), b"secret", b"aad").unwrap();
        let wrong_key = [0x99u8; KEY_LEN];
        assert!(decrypt(&wrong_key, &ct, b"aad").is_err());
    }

    #[test]
    fn wrong_aad_fails_closed() {
        let key = test_key();
        let ct = encrypt(&key, b"secret", b"aad-one").unwrap();
        assert!(decrypt(&key, &ct, b"aad-two").is_err());
    }

    #[test]
    fn tampered_ciphertext_byte_fails_closed_not_silently_corrupt() {
        let key = test_key();
        let mut ct = encrypt(&key, b"secret payload", b"aad").unwrap();
        let last = ct.len() - 1;
        ct[last] ^= 0x01;
        let result = decrypt(&key, &ct, b"aad");
        assert!(result.is_err(), "tampered ciphertext must fail to decrypt, never silently corrupt");
    }

    #[test]
    fn tampered_nonce_fails_closed() {
        let key = test_key();
        let mut ct = encrypt(&key, b"secret payload", b"aad").unwrap();
        ct[0] ^= 0x01;
        assert!(decrypt(&key, &ct, b"aad").is_err());
    }

    #[test]
    fn truncated_buffer_fails_closed() {
        let key = test_key();
        assert!(decrypt(&key, &[0u8; 4], b"aad").is_err());
    }

    #[test]
    fn nonces_are_random_per_call() {
        let key = test_key();
        let ct1 = encrypt(&key, b"same plaintext", b"").unwrap();
        let ct2 = encrypt(&key, b"same plaintext", b"").unwrap();
        assert_ne!(&ct1[..NONCE_LEN], &ct2[..NONCE_LEN]);
        assert_ne!(ct1, ct2);
    }
}
