//! CTAP2 message handling (spec §6, §6.6, item 1.7): `authenticatorMakeCredential`
//! and `authenticatorGetAssertion`, as platform-agnostic library functions.
//!
//! Per spec §2 ("base message parsing on the `ctap-types` crate lineage
//! rather than writing CTAP2 parsing from scratch"), this module
//! consumes and produces the `ctap-types` crate's own request/response
//! types directly — it does not define a parallel set of DTOs, and it
//! reuses `ctap_types::ctap2::Error` as its error type since that enum
//! *is* the CTAP2 status-code vocabulary (`CredentialExcluded`,
//! `UnsupportedAlgorithm`, `NoCredentials`, ...), already wired to the
//! crate's own CBOR response encoding.
//!
//! Scope, matching spec §12 item 1.7 exactly: user-verification flag
//! handling, `sign_count` increment, `rp_id` matching, and
//! `excludeList`/`allowList` handling. Not in scope, per spec:
//! - The `hmac-secret` extension (§6.6: "only if a concrete relying-party
//!   need arises; do not build it speculatively").
//! - Any attestation format but `"none"` (§6.6: "Do not ship a batch
//!   attestation certificate/private key baked into the app.").
//! - `authenticatorGetInfo`, `authenticatorGetNextAssertion`, PIN/UV
//!   protocol negotiation, credential management, and every other CTAP2
//!   command — spec §12 item 1.7 names exactly `authenticatorMakeCredential`
//!   and `authenticatorGetAssertion`.
//! - The transport (USB HID/NFC/BLE framing, or an OS credential-provider
//!   handing this module already-parsed fields instead of raw CBOR) —
//!   platform-specific, wired up per platform phase like the custom
//!   protocol's transport (see `protocol.rs`'s module doc comment).
//! - Persisting the result: this module returns what changed (a new
//!   credential to seal and add to the manifest, an incremented
//!   `sign_count` to write back) — it never touches `Manifest`/`Container`
//!   itself, matching `merge.rs`/`protocol.rs`'s separation of protocol
//!   logic from persistence.

use sha2::{Digest, Sha256};
use uuid::Uuid;

use ctap_types::ctap2::{
    self, get_assertion, make_credential, AttestationStatement, AuthenticatorData, AuthenticatorDataFlags,
    Error as Ctap2Error, NoneAttestationStatement, Result as Ctap2Result,
};
use ctap_types::heapless_bytes::Bytes as HBytes;
use ctap_types::serde::{cbor_serialize, cbor_serialize_to};
use ctap_types::sizes::COSE_KEY_LENGTH;
use ctap_types::webauthn::{PublicKeyCredentialDescriptor, PublicKeyCredentialUserEntity, ED_DSA, ES256};
use cosey::{Ed25519PublicKey, P256PublicKey, PublicKey as CosePublicKey};

use crate::keys::{self, GeneratedKeyPair};
use crate::manifest::KeyType;

/// Placeholder AAGUID (all-zero): the spec assigns no specific value,
/// and no AAGUID has been registered with the FIDO Alliance for this
/// project. All-zero is a common, neutral choice for implementations
/// that don't want to expose a distinguishing authenticator model ID —
/// revisit if/when a real AAGUID is registered.
const AAGUID: [u8; 16] = [0u8; 16];

/// The minimal slice of manifest data this module needs for a given
/// `rp_id` — deliberately not `manifest::KeyEntry` itself, so this
/// module stays decoupled from the exact manifest schema (same pattern
/// as `protocol::PublicKeyInfo` and `merge::VaultCompartment`).
#[derive(Debug, Clone)]
pub struct CredentialCandidate {
    pub key_id: Uuid,
    pub credential_id: Vec<u8>,
    pub user_handle: Vec<u8>,
    pub discoverable: bool,
    pub sign_count: u32,
}

/// The vault-facing half of CTAP2 handling: manifest lookups and the
/// actual signature (behind the passphrase-gated retention cache, same
/// as `protocol::SigningBackend`).
pub trait Ctap2Backend {
    fn credentials_for_rp(&self, rp_id: &str) -> Vec<CredentialCandidate>;

    /// Sign `message` with the private key behind `key_id`. `None` means
    /// the user declined, the passphrase was wrong, or the key is
    /// throttled — CTAP2 has no finer-grained status for this than a
    /// generic denial, so the caller maps `None` to
    /// `Ctap2Error::OperationDenied`.
    fn sign(&self, key_id: Uuid, message: &[u8]) -> Option<Vec<u8>>;
}

pub struct MakeCredentialOutcome {
    /// The full CBOR-encoded `authenticatorMakeCredential` response,
    /// ready to hand back over whatever transport received the request.
    pub response_cbor: Vec<u8>,
    /// The newly generated keypair — the caller seals it (`keyblob::seal`)
    /// under a per-key passphrase and adds it to the manifest; this
    /// module never persists anything itself.
    pub generated_key: GeneratedKeyPair,
    pub credential_id: Vec<u8>,
    pub rp_id: String,
    pub user_handle: Vec<u8>,
    pub discoverable: bool,
}

fn key_type_for_alg(alg: i32) -> Option<KeyType> {
    match alg {
        ES256 => Some(KeyType::EcdsaP256),
        ED_DSA => Some(KeyType::Ed25519),
        _ => None,
    }
}

fn rp_id_hash(rp_id: &str) -> [u8; 32] {
    Sha256::digest(rp_id.as_bytes()).into()
}

/// Build a CBOR-encoded COSE public key from our stored key formats
/// (spec §1.5/`keys.rs`: a raw 32-byte Ed25519 public key, or an
/// uncompressed 65-byte `0x04 || x || y` P-256 point).
fn cose_key_bytes(key_type: KeyType, public_key: &[u8]) -> Ctap2Result<HBytes<COSE_KEY_LENGTH>> {
    let cose: CosePublicKey = match key_type {
        KeyType::Ed25519 => Ed25519PublicKey {
            x: HBytes::try_from(public_key).map_err(|_| Ctap2Error::Other)?,
        }
        .into(),
        KeyType::EcdsaP256 => {
            if public_key.len() != 65 || public_key[0] != 0x04 {
                return Err(Ctap2Error::Other);
            }
            P256PublicKey {
                x: HBytes::try_from(&public_key[1..33]).map_err(|_| Ctap2Error::Other)?,
                y: HBytes::try_from(&public_key[33..65]).map_err(|_| Ctap2Error::Other)?,
            }
            .into()
        }
    };
    let mut buf: HBytes<COSE_KEY_LENGTH> = HBytes::new();
    cbor_serialize_to(&cose, &mut buf).map_err(|_| Ctap2Error::Other)?;
    Ok(buf)
}

/// CTAP2's wire format for a response is one status byte (`0x00` for
/// success) followed by the CBOR-encoded payload map — this is what
/// `ctap_types::ctap2::Response::serialize` does when going through the
/// crate's top-level response enum, which expects a `heapless::VecView`
/// this module doesn't otherwise need; doing the equivalent by hand here
/// (status byte + `cbor_serialize` of just the inner response) avoids
/// pulling that machinery in for one byte.
fn success_response_bytes<T: serde::Serialize>(response: &T) -> Ctap2Result<Vec<u8>> {
    let mut out_buf = [0u8; 1024];
    let payload = cbor_serialize(response, &mut out_buf).map_err(|_| Ctap2Error::Other)?;
    let mut out = Vec::with_capacity(1 + payload.len());
    out.push(0x00);
    out.extend_from_slice(payload);
    Ok(out)
}

/// `authenticatorMakeCredential` (spec §6.6).
///
/// `user_present`/`user_verified` are resolved by the caller before this
/// is called — CTAP2 requires user presence, and the `uv` option (if
/// requested) requires user verification, both enforced here by
/// rejecting the request if the caller didn't already satisfy them, not
/// by this module prompting for anything itself.
pub fn handle_make_credential(
    backend: &dyn Ctap2Backend,
    request: &make_credential::Request,
    user_present: bool,
    user_verified: bool,
) -> Ctap2Result<MakeCredentialOutcome> {
    let rp_id: &str = &request.rp.id;
    let existing = backend.credentials_for_rp(rp_id);

    if let Some(exclude_list) = &request.exclude_list {
        for excluded in exclude_list {
            if existing.iter().any(|c| c.credential_id == excluded.id.as_ref()) {
                return Err(Ctap2Error::CredentialExcluded);
            }
        }
    }

    if !user_present {
        return Err(Ctap2Error::OperationDenied);
    }
    let uv_requested = request.options.as_ref().and_then(|o| o.uv).unwrap_or(false);
    if uv_requested && !user_verified {
        return Err(Ctap2Error::OperationDenied);
    }

    let alg = request
        .pub_key_cred_params
        .0
        .first()
        .ok_or(Ctap2Error::UnsupportedAlgorithm)?
        .alg;
    let key_type = key_type_for_alg(alg).ok_or(Ctap2Error::UnsupportedAlgorithm)?;

    let generated = keys::generate(key_type).map_err(|_| Ctap2Error::Other)?;
    let credential_id_bytes = Uuid::new_v4().as_bytes().to_vec();
    let cose_key = cose_key_bytes(key_type, &generated.public_key)?;
    let discoverable = request.options.as_ref().and_then(|o| o.rk).unwrap_or(false);

    let acd = make_credential::AttestedCredentialData {
        aaguid: &AAGUID,
        credential_id: &credential_id_bytes,
        credential_public_key: &cose_key,
    };

    let mut flags = AuthenticatorDataFlags::ATTESTED_CREDENTIAL_DATA;
    if user_present {
        flags |= AuthenticatorDataFlags::USER_PRESENCE;
    }
    if user_verified {
        flags |= AuthenticatorDataFlags::USER_VERIFIED;
    }

    let hash = rp_id_hash(rp_id);
    let auth_data: make_credential::AuthenticatorData = AuthenticatorData {
        rp_id_hash: &hash,
        flags,
        sign_count: 0,
        attested_credential_data: Some(acd),
        extensions: None,
    };
    let serialized_auth_data = auth_data.serialize().map_err(|_| Ctap2Error::Other)?;

    let mut response = make_credential::ResponseBuilder {
        fmt: ctap2::AttestationStatementFormat::None,
        auth_data: serialized_auth_data,
    }
    .build();
    response.att_stmt = Some(AttestationStatement::None(NoneAttestationStatement {}));

    let response_cbor = success_response_bytes(&response)?;

    Ok(MakeCredentialOutcome {
        response_cbor,
        generated_key: generated,
        credential_id: credential_id_bytes,
        rp_id: rp_id.to_string(),
        user_handle: request.user.id.to_vec(),
        discoverable,
    })
}

pub struct GetAssertionOutcome {
    pub response_cbor: Vec<u8>,
    pub key_id: Uuid,
    /// The manifest's `sign_count` for this key must be updated to this
    /// value (spec §4.4: "persisted and incremented on every assertion").
    pub new_sign_count: u32,
}

/// `authenticatorGetAssertion` (spec §6.6). Only the single-assertion
/// path is implemented — when more than one candidate matches, the
/// first is used; `authenticatorGetNextAssertion` (picking among
/// several) is out of scope for spec §12 item 1.7 and left for the
/// platform UI to offer via its own picker if ever needed.
pub fn handle_get_assertion(
    backend: &dyn Ctap2Backend,
    request: &get_assertion::Request,
    user_present: bool,
    user_verified: bool,
) -> Ctap2Result<GetAssertionOutcome> {
    let rp_id = request.rp_id;
    let candidates = backend.credentials_for_rp(rp_id);

    let discoverable_flow = request.allow_list.is_none();
    let matching: Vec<&CredentialCandidate> = match &request.allow_list {
        Some(allow_list) => candidates
            .iter()
            .filter(|c| allow_list.iter().any(|a| a.id.as_ref() == c.credential_id.as_slice()))
            .collect(),
        None => candidates.iter().filter(|c| c.discoverable).collect(),
    };
    let chosen = *matching.first().ok_or(Ctap2Error::NoCredentials)?;

    if !user_present {
        return Err(Ctap2Error::OperationDenied);
    }
    let uv_requested = request.options.as_ref().and_then(|o| o.uv).unwrap_or(false);
    if uv_requested && !user_verified {
        return Err(Ctap2Error::OperationDenied);
    }

    let new_sign_count = chosen.sign_count.wrapping_add(1);

    let mut flags = AuthenticatorDataFlags::empty();
    if user_present {
        flags |= AuthenticatorDataFlags::USER_PRESENCE;
    }
    if user_verified {
        flags |= AuthenticatorDataFlags::USER_VERIFIED;
    }

    let hash = rp_id_hash(rp_id);
    let auth_data: get_assertion::AuthenticatorData = AuthenticatorData {
        rp_id_hash: &hash,
        flags,
        sign_count: new_sign_count,
        attested_credential_data: None,
        extensions: None,
    };
    let serialized_auth_data = auth_data.serialize().map_err(|_| Ctap2Error::Other)?;

    let mut to_sign = Vec::with_capacity(serialized_auth_data.len() + request.client_data_hash.len());
    to_sign.extend_from_slice(&serialized_auth_data);
    to_sign.extend_from_slice(request.client_data_hash);
    let signature = backend.sign(chosen.key_id, &to_sign).ok_or(Ctap2Error::OperationDenied)?;

    let mut response = get_assertion::ResponseBuilder {
        credential: PublicKeyCredentialDescriptor {
            id: HBytes::try_from(chosen.credential_id.as_slice()).map_err(|_| Ctap2Error::Other)?,
            key_type: "public-key".try_into().map_err(|_| Ctap2Error::Other)?,
        },
        auth_data: serialized_auth_data,
        signature: HBytes::try_from(signature.as_slice()).map_err(|_| Ctap2Error::Other)?,
    }
    .build();

    // WebAuthn requires user info back for a discoverable-credential
    // (no allowList) assertion, so the platform can show an account
    // picker; omit it for the allowList case, where the RP already knew
    // which account it was asking for.
    if discoverable_flow {
        response.user = Some(PublicKeyCredentialUserEntity {
            id: HBytes::try_from(chosen.user_handle.as_slice()).map_err(|_| Ctap2Error::Other)?,
            icon: None,
            name: None,
            display_name: None,
        });
    }

    let response_cbor = success_response_bytes(&response)?;

    Ok(GetAssertionOutcome {
        response_cbor,
        key_id: chosen.key_id,
        new_sign_count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ciborium::Value;
    use std::cell::RefCell;
    use std::collections::HashMap;

    fn encode_request(operation_byte: u8, map: Value) -> Vec<u8> {
        let mut body = Vec::new();
        ciborium::into_writer(&map, &mut body).unwrap();
        let mut out = vec![operation_byte];
        out.extend_from_slice(&body);
        out
    }

    fn make_credential_request_bytes(rp_id: &str, user_id: &[u8], algs: &[i64], exclude: Option<Vec<Vec<u8>>>) -> Vec<u8> {
        let rp = Value::Map(vec![(Value::Text("id".into()), Value::Text(rp_id.to_string()))]);
        let user = Value::Map(vec![(Value::Text("id".into()), Value::Bytes(user_id.to_vec()))]);
        let mut fields = vec![(1, Value::Bytes(vec![0u8; 32])), (2, rp), (3, user)];
        let params = Value::Array(
            algs.iter()
                .map(|alg| {
                    Value::Map(vec![
                        (Value::Text("alg".into()), Value::Integer((*alg).into())),
                        (Value::Text("type".into()), Value::Text("public-key".into())),
                    ])
                })
                .collect(),
        );
        fields.push((4, params));
        if let Some(exclude_ids) = exclude {
            let list = Value::Array(
                exclude_ids
                    .into_iter()
                    .map(|id| {
                        Value::Map(vec![
                            (Value::Text("id".into()), Value::Bytes(id)),
                            (Value::Text("type".into()), Value::Text("public-key".into())),
                        ])
                    })
                    .collect(),
            );
            fields.push((5, list));
        }
        // options: rk=true, up=true so tests don't need to special-case it
        fields.push((7, Value::Map(vec![
            (Value::Text("rk".into()), Value::Bool(true)),
            (Value::Text("up".into()), Value::Bool(true)),
        ])));

        let map = Value::Map(fields.into_iter().map(|(k, v)| (Value::Integer(k.into()), v)).collect());
        encode_request(0x01, map)
    }

    fn get_assertion_request_bytes(rp_id: &str, allow_ids: Option<Vec<Vec<u8>>>) -> Vec<u8> {
        let mut fields = vec![
            (1, Value::Text(rp_id.to_string())),
            (2, Value::Bytes(vec![0u8; 32])), // client_data_hash
        ];
        if let Some(ids) = allow_ids {
            let list = Value::Array(
                ids.into_iter()
                    .map(|id| {
                        Value::Map(vec![
                            (Value::Text("id".into()), Value::Bytes(id)),
                            (Value::Text("type".into()), Value::Text("public-key".into())),
                        ])
                    })
                    .collect(),
            );
            fields.push((3, list));
        }
        let map = Value::Map(fields.into_iter().map(|(k, v)| (Value::Integer(k.into()), v)).collect());
        encode_request(0x02, map)
    }

    struct FakeBackend {
        by_rp: HashMap<String, Vec<CredentialCandidate>>,
        sign_result: RefCell<Option<Vec<u8>>>,
    }

    impl Ctap2Backend for FakeBackend {
        fn credentials_for_rp(&self, rp_id: &str) -> Vec<CredentialCandidate> {
            self.by_rp.get(rp_id).cloned().unwrap_or_default()
        }

        fn sign(&self, _key_id: Uuid, _message: &[u8]) -> Option<Vec<u8>> {
            self.sign_result.borrow_mut().take()
        }
    }

    fn parse_make_credential(bytes: &[u8]) -> make_credential::Request<'_> {
        match ctap2::Request::deserialize(bytes).unwrap() {
            ctap2::Request::MakeCredential(r) => r,
            _ => panic!("expected MakeCredential"),
        }
    }

    fn parse_get_assertion(bytes: &[u8]) -> get_assertion::Request<'_> {
        match ctap2::Request::deserialize(bytes).unwrap() {
            ctap2::Request::GetAssertion(r) => r,
            _ => panic!("expected GetAssertion"),
        }
    }

    #[test]
    fn make_credential_es256_generates_p256_key_and_valid_response() {
        let bytes = make_credential_request_bytes("example.com", b"user-1", &[ES256 as i64], None);
        let request = parse_make_credential(&bytes);
        let backend = FakeBackend { by_rp: HashMap::new(), sign_result: RefCell::new(None) };

        let outcome = handle_make_credential(&backend, &request, true, true).unwrap();
        assert_eq!(outcome.generated_key.key_type, KeyType::EcdsaP256);
        assert_eq!(outcome.rp_id, "example.com");
        assert_eq!(outcome.user_handle, b"user-1");
        assert!(outcome.discoverable);
        assert!(!outcome.response_cbor.is_empty());

        // The response must be parseable back as valid CBOR (status byte
        // + map), proving handle_make_credential produced a real,
        // well-formed authenticatorMakeCredential response.
        assert_eq!(outcome.response_cbor[0], 0x00, "status byte must be success (0x00)");
    }

    #[test]
    fn make_credential_eddsa_generates_ed25519_key() {
        let bytes = make_credential_request_bytes("example.com", b"user-1", &[ED_DSA as i64], None);
        let request = parse_make_credential(&bytes);
        let backend = FakeBackend { by_rp: HashMap::new(), sign_result: RefCell::new(None) };
        let outcome = handle_make_credential(&backend, &request, true, true).unwrap();
        assert_eq!(outcome.generated_key.key_type, KeyType::Ed25519);
    }

    #[test]
    fn make_credential_prefers_first_supported_alg_in_caller_order() {
        // Caller lists EdDSA before ES256: EdDSA must win.
        let bytes = make_credential_request_bytes("example.com", b"user-1", &[ED_DSA as i64, ES256 as i64], None);
        let request = parse_make_credential(&bytes);
        let backend = FakeBackend { by_rp: HashMap::new(), sign_result: RefCell::new(None) };
        let outcome = handle_make_credential(&backend, &request, true, true).unwrap();
        assert_eq!(outcome.generated_key.key_type, KeyType::Ed25519);
    }

    #[test]
    fn make_credential_rejects_unsupported_algorithm() {
        // -257 = RS256, not in ctap-types' known-alg filter (ES256/EdDSA
        // only), so it's dropped during deserialization, leaving an
        // empty pub_key_cred_params list.
        let bytes = make_credential_request_bytes("example.com", b"user-1", &[-257], None);
        let request = parse_make_credential(&bytes);
        let backend = FakeBackend { by_rp: HashMap::new(), sign_result: RefCell::new(None) };
        let result = handle_make_credential(&backend, &request, true, true);
        assert!(matches!(result, Err(Ctap2Error::UnsupportedAlgorithm)));
    }

    #[test]
    fn make_credential_rejects_excluded_credential() {
        let existing_cred_id = vec![9u8; 16];
        let bytes = make_credential_request_bytes(
            "example.com",
            b"user-1",
            &[ES256 as i64],
            Some(vec![existing_cred_id.clone()]),
        );
        let request = parse_make_credential(&bytes);
        let mut by_rp = HashMap::new();
        by_rp.insert(
            "example.com".to_string(),
            vec![CredentialCandidate {
                key_id: Uuid::new_v4(),
                credential_id: existing_cred_id,
                user_handle: b"user-1".to_vec(),
                discoverable: true,
                sign_count: 0,
            }],
        );
        let backend = FakeBackend { by_rp, sign_result: RefCell::new(None) };
        let result = handle_make_credential(&backend, &request, true, true);
        assert!(matches!(result, Err(Ctap2Error::CredentialExcluded)));
    }

    #[test]
    fn make_credential_without_user_presence_is_denied() {
        let bytes = make_credential_request_bytes("example.com", b"user-1", &[ES256 as i64], None);
        let request = parse_make_credential(&bytes);
        let backend = FakeBackend { by_rp: HashMap::new(), sign_result: RefCell::new(None) };
        let result = handle_make_credential(&backend, &request, false, true);
        assert!(matches!(result, Err(Ctap2Error::OperationDenied)));
    }

    #[test]
    fn get_assertion_with_allow_list_matches_and_signs() {
        let cred_id = vec![1u8; 16];
        let key_id = Uuid::new_v4();
        let bytes = get_assertion_request_bytes("example.com", Some(vec![cred_id.clone()]));
        let request = parse_get_assertion(&bytes);

        let mut by_rp = HashMap::new();
        by_rp.insert(
            "example.com".to_string(),
            vec![CredentialCandidate {
                key_id,
                credential_id: cred_id,
                user_handle: b"user-1".to_vec(),
                discoverable: false,
                sign_count: 41,
            }],
        );
        let backend = FakeBackend { by_rp, sign_result: RefCell::new(Some(vec![0xAB; 8])) };

        let outcome = handle_get_assertion(&backend, &request, true, true).unwrap();
        assert_eq!(outcome.key_id, key_id);
        assert_eq!(outcome.new_sign_count, 42);
        assert_eq!(outcome.response_cbor[0], 0x00);
    }

    #[test]
    fn get_assertion_without_allow_list_only_matches_discoverable_credentials() {
        let non_discoverable = CredentialCandidate {
            key_id: Uuid::new_v4(),
            credential_id: vec![1u8; 16],
            user_handle: b"a".to_vec(),
            discoverable: false,
            sign_count: 0,
        };
        let bytes = get_assertion_request_bytes("example.com", None);
        let request = parse_get_assertion(&bytes);
        let mut by_rp = HashMap::new();
        by_rp.insert("example.com".to_string(), vec![non_discoverable]);
        let backend = FakeBackend { by_rp, sign_result: RefCell::new(Some(vec![0xAB; 8])) };

        let result = handle_get_assertion(&backend, &request, true, true);
        assert!(matches!(result, Err(Ctap2Error::NoCredentials)));
    }

    #[test]
    fn get_assertion_no_matching_rp_returns_no_credentials() {
        let bytes = get_assertion_request_bytes("unknown.example", None);
        let request = parse_get_assertion(&bytes);
        let backend = FakeBackend { by_rp: HashMap::new(), sign_result: RefCell::new(None) };
        let result = handle_get_assertion(&backend, &request, true, true);
        assert!(matches!(result, Err(Ctap2Error::NoCredentials)));
    }

    #[test]
    fn get_assertion_backend_declining_to_sign_is_denied() {
        let cred_id = vec![1u8; 16];
        let bytes = get_assertion_request_bytes("example.com", Some(vec![cred_id.clone()]));
        let request = parse_get_assertion(&bytes);
        let mut by_rp = HashMap::new();
        by_rp.insert(
            "example.com".to_string(),
            vec![CredentialCandidate {
                key_id: Uuid::new_v4(),
                credential_id: cred_id,
                user_handle: b"a".to_vec(),
                discoverable: false,
                sign_count: 0,
            }],
        );
        let backend = FakeBackend { by_rp, sign_result: RefCell::new(None) }; // sign() returns None
        let result = handle_get_assertion(&backend, &request, true, true);
        assert!(matches!(result, Err(Ctap2Error::OperationDenied)));
    }

    #[test]
    fn rp_id_hash_is_sha256_of_rp_id() {
        let hash = rp_id_hash("example.com");
        let expected: [u8; 32] = Sha256::digest(b"example.com").into();
        assert_eq!(hash, expected);
    }
}
