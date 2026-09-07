//! Key generation (spec §1.5, §4.3): Ed25519 (default) and ECDSA P-256
//! (mandatory for FIDO2 `ES256`) are the only key types v1 generates.
//!
//! Randomness is drawn directly from the OS CSPRNG (`getrandom`) for
//! every byte of key material, never through an intermediate userspace
//! stream-cipher DRBG (spec §4.3: "OS CSPRNG only ... never a userspace
//! PRNG"). Ed25519 seeds need no rejection sampling (any 32 bytes is a
//! valid seed under RFC 8032's clamping); P-256 uses `elliptic_curve`'s
//! `Generate` trait, which draws directly from `getrandom::SysRng` and
//! internally rejection-samples to stay within the field/group order.

use ed25519_dalek::SigningKey as Ed25519SigningKey;
use p256::ecdsa::SigningKey as P256SigningKey;
use p256::elliptic_curve::Generate;
use p256::CompressedPoint;
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
            let compressed: CompressedPoint = signing_key.verifying_key().into();
            Ok(GeneratedKeyPair {
                key_type,
                private_key,
                public_key: compressed.to_vec(),
            })
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
    fn ecdsa_p256_generates_32_byte_private_and_33_byte_compressed_public() {
        let kp = generate(KeyType::EcdsaP256).unwrap();
        assert_eq!(kp.private_key.len(), 32);
        assert_eq!(kp.public_key.len(), 33);
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
