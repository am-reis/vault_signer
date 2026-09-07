//! Key generation and signing (spec §1.5, §4.3): Ed25519 (default) and
//! ECDSA P-256 (mandatory for FIDO2 `ES256`) are the only key types v1
//! generates.
//!
//! Randomness is drawn directly from the OS CSPRNG (`getrandom`) for
//! every byte of key material, never through an intermediate userspace
//! stream-cipher DRBG (spec §4.3: "OS CSPRNG only ... never a userspace
//! PRNG"). Ed25519 seeds need no rejection sampling (any 32 bytes is a
//! valid seed under RFC 8032's clamping); P-256 uses `elliptic_curve`'s
//! `Generate` trait, which draws directly from `getrandom::SysRng` and
//! internally rejection-samples to stay within the field/group order.
//!
//! P-256 public keys are stored **uncompressed** (`0x04 || x || y`, 65
//! bytes), not SEC1-compressed (33 bytes): both CTAP2's COSE key
//! encoding (spec §6, via `ctap2.rs`) and most WebAuthn-adjacent tooling
//! want `x`/`y` directly, and storing them pre-split as plain byte
//! ranges avoids every downstream consumer needing an
//! elliptic-curve-library-specific point-decompression step just to
//! read a public key that was already computed once at generation time.

use ed25519_dalek::{Signer as Ed25519Signer, SigningKey as Ed25519SigningKey};
use p256::ecdsa::{Signature as P256Signature, SigningKey as P256SigningKey};
use p256::elliptic_curve::Generate;
use zeroize::Zeroizing;

use crate::error::{Result, VaultError};
use crate::manifest::KeyType;

/// A freshly generated keypair, immediately ready for AEAD-wrapping into
/// a key blob. `private_key` is zeroize-wrapped; the caller is
/// responsible for zeroing any intermediate generation buffers and never
/// persisting `private_key` in plaintext beyond the moment of creation
/// (spec §5.1 "Create key").
pub struct GeneratedKeyPair {
    pub key_type: KeyType,
    pub private_key: Zeroizing<Vec<u8>>,
    pub public_key: Vec<u8>,
}

pub fn generate(key_type: KeyType) -> Result<GeneratedKeyPair> {
    match key_type {
        KeyType::Ed25519 => {
            let mut seed = Zeroizing::new([0u8; 32]);
            getrandom::fill(seed.as_mut()).map_err(|e| VaultError::KeyGen(e.to_string()))?;
            let signing_key = Ed25519SigningKey::from_bytes(&seed);
            let public_key = signing_key.verifying_key().to_bytes().to_vec();
            Ok(GeneratedKeyPair {
                key_type,
                private_key: Zeroizing::new(seed.to_vec()),
                public_key,
            })
        }
        KeyType::EcdsaP256 => {
            let signing_key = P256SigningKey::generate();
            let private_key = Zeroizing::new(signing_key.to_bytes().to_vec());
            let uncompressed = signing_key.verifying_key().to_sec1_point(false);
            Ok(GeneratedKeyPair {
                key_type,
                private_key,
                public_key: uncompressed.as_bytes().to_vec(),
            })
        }
    }
}

/// Sign `message` with the raw private key bytes `keyblob::open` (or an
/// equivalent decryption) produced. Ed25519 returns a raw 64-byte
/// signature; ECDSA P-256 returns a DER-encoded signature, matching the
/// WebAuthn/CTAP2 convention (spec §6) for `ES256` signatures.
pub fn sign(key_type: KeyType, private_key: &[u8], message: &[u8]) -> Result<Vec<u8>> {
    match key_type {
        KeyType::Ed25519 => {
            let seed: [u8; 32] = private_key
                .try_into()
                .map_err(|_| VaultError::KeyGen("ed25519 private key must be 32 bytes".into()))?;
            let signing_key = Ed25519SigningKey::from_bytes(&seed);
            Ok(signing_key.sign(message).to_bytes().to_vec())
        }
        KeyType::EcdsaP256 => {
            let signing_key = P256SigningKey::try_from(private_key)
                .map_err(|e| VaultError::KeyGen(format!("invalid p256 private key: {e}")))?;
            let signature: P256Signature = signing_key.sign(message);
            Ok(signature.to_der().as_bytes().to_vec())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ed25519_generates_32_byte_private_and_public() {
        let kp = generate(KeyType::Ed25519).unwrap();
        assert_eq!(kp.private_key.len(), 32);
        assert_eq!(kp.public_key.len(), 32);
    }

    #[test]
    fn ecdsa_p256_generates_32_byte_private_and_65_byte_uncompressed_public() {
        let kp = generate(KeyType::EcdsaP256).unwrap();
        assert_eq!(kp.private_key.len(), 32);
        assert_eq!(kp.public_key.len(), 65);
        assert_eq!(kp.public_key[0], 0x04, "uncompressed SEC1 points start with 0x04");
    }

    #[test]
    fn ed25519_sign_produces_64_byte_signature_verifiable_against_the_public_key() {
        let kp = generate(KeyType::Ed25519).unwrap();
        let sig_bytes = sign(KeyType::Ed25519, &kp.private_key, b"message").unwrap();
        assert_eq!(sig_bytes.len(), 64);

        let verifying_key = ed25519_dalek::VerifyingKey::from_bytes(&kp.public_key.clone().try_into().unwrap()).unwrap();
        let signature = ed25519_dalek::Signature::from_bytes(&sig_bytes.try_into().unwrap());
        use ed25519_dalek::Verifier;
        assert!(verifying_key.verify(b"message", &signature).is_ok());
    }

    #[test]
    fn ecdsa_p256_sign_produces_der_signature_verifiable_against_the_public_key() {
        let kp = generate(KeyType::EcdsaP256).unwrap();
        let sig_bytes = sign(KeyType::EcdsaP256, &kp.private_key, b"message").unwrap();

        let verifying_key = p256::ecdsa::VerifyingKey::from_sec1_bytes(&kp.public_key).unwrap();
        let signature = p256::ecdsa::Signature::from_der(&sig_bytes).unwrap();
        use p256::ecdsa::signature::Verifier;
        assert!(verifying_key.verify(b"message", &signature).is_ok());
    }

    #[test]
    fn signing_with_wrong_length_ed25519_key_errors_instead_of_panicking() {
        assert!(sign(KeyType::Ed25519, &[1, 2, 3], b"m").is_err());
    }

    #[test]
    fn successive_generations_are_distinct() {
        let a = generate(KeyType::Ed25519).unwrap();
        let b = generate(KeyType::Ed25519).unwrap();
        assert_ne!(*a.private_key, *b.private_key);
        assert_ne!(a.public_key, b.public_key);

        let a = generate(KeyType::EcdsaP256).unwrap();
        let b = generate(KeyType::EcdsaP256).unwrap();
        assert_ne!(*a.private_key, *b.private_key);
        assert_ne!(a.public_key, b.public_key);
    }
}
