//! Custom local signing protocol (spec §7): JSON-RPC-style message
//! parsing and dispatch, as a platform-agnostic library function (spec
//! §12 item 1.8).
//!
//! **Scope note:** this module is the message layer only. The transport
//! itself — a Unix domain socket or named pipe on desktop, a loopback
//! TCP port, or the iOS App Intents adaptation (spec §7, §7.1) — is
//! platform-specific and deliberately not built here; each platform
//! phase (§12 items 2.8, 3.6, 4.6, 5.4, 6.5) wires a transport up to
//! [`handle_request`]. Likewise, determining the calling process's
//! identity via OS-level peer credentials (never the JSON payload
//! itself, per spec §7's explicit warning) is the transport's job — it
//! is passed into this module as `caller_identity`, already resolved.
//!
//! Rate limiting (spec §7, §5.5) is enforced here, once, via the
//! existing [`crate::throttle::ThrottleTracker`], rather than left for
//! each [`SigningBackend`] implementation to reimplement: a locked-out
//! key never reaches the backend's `sign` at all.

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::throttle::{SecretId, ThrottleTracker};

/// What a [`SigningBackend`] hands back for a `vaultsigner.sign` call.
/// Spec §7 names four possible error outcomes; three are the backend's
/// call (`key_not_found`, `user_declined`, `passphrase_incorrect`) and
/// are represented here. The fourth, `key_locked_retry_later`, is
/// decided entirely by [`handle_request`] consulting the shared
/// [`ThrottleTracker`] *before* the backend is invoked at all — by the
/// time a backend sees a `sign` call, the key is known not to be
/// throttled, so that outcome has no variant here. Any failure that
/// doesn't fit one of these three is a protocol-level error (bad JSON,
/// unknown method, malformed params) handled entirely within
/// [`handle_request`] before a backend is ever consulted.
pub enum SignOutcome {
    Signed { signature: Vec<u8>, public_key: Vec<u8> },
    KeyNotFound,
    UserDeclined,
    PassphraseIncorrect,
}

#[derive(Debug, Clone)]
pub struct PublicKeyInfo {
    pub key_id: Uuid,
    pub label: String,
    pub public_key: Vec<u8>,
    pub resource: String,
}

/// The vault-facing half of the protocol: everything that actually
/// touches key material, the passphrase prompt, and caller-consent UI.
/// A real implementation (Phase 2+) backs this with the retention
/// cache, `keyblob::open`, and the per-key passphrase prompt (with
/// screen-capture blocking per spec §5.0); tests here use an in-memory
/// fake.
pub trait SigningBackend {
    /// Never returns private material — spec §7 discovery: "returns
    /// only `key_id`, `label`, `public_key_b64`, `resource`."
    fn list_public_keys(&self) -> Vec<PublicKeyInfo>;

    /// Shows the same password-prompt UI as FIDO2 (spec §7), displaying
    /// `caller_identity` before the passphrase field, and performs the
    /// signature. Called only after this module confirms `key_id` isn't
    /// currently throttled.
    fn sign(&self, caller_identity: &str, key_id: Uuid, message: &[u8]) -> SignOutcome;
}

#[derive(Debug, Deserialize)]
struct RawRequest {
    method: String,
    #[serde(default)]
    params: Value,
    id: Value,
}

#[derive(Debug, Deserialize)]
struct SignParams {
    key_id: String,
    message_b64: String,
    #[serde(default)]
    algorithm: Option<String>,
}

fn error_response(id: Value, code: &str, message: impl Into<String>) -> Vec<u8> {
    let body = json!({
        "id": id,
        "error": { "code": code, "message": message.into() },
    });
    // serde_json::to_vec on a `Value` we built ourselves cannot fail.
    serde_json::to_vec(&body).expect("serializing a constructed json! Value cannot fail")
}

fn result_response(id: Value, result: Value) -> Vec<u8> {
    let body = json!({ "id": id, "result": result });
    serde_json::to_vec(&body).expect("serializing a constructed json! Value cannot fail")
}

/// Parse, dispatch, and answer one request. Never panics on malformed
/// or hostile input — a JSON-RPC parse failure or an unknown method
/// yields an error response with `id: null`, exactly like a truncated
/// container must fail closed rather than crash the background service
/// (spec §10).
pub fn handle_request(
    backend: &dyn SigningBackend,
    throttle: &ThrottleTracker,
    caller_identity: &str,
    raw_json: &[u8],
) -> Vec<u8> {
    let request: RawRequest = match serde_json::from_slice(raw_json) {
        Ok(r) => r,
        Err(e) => return error_response(Value::Null, "parse_error", e.to_string()),
    };

    match request.method.as_str() {
        "vaultsigner.list_public_keys" => {
            let keys: Vec<Value> = backend
                .list_public_keys()
                .into_iter()
                .map(|k| {
                    json!({
                        "key_id": k.key_id,
                        "label": k.label,
                        "public_key_b64": BASE64.encode(&k.public_key),
                        "resource": k.resource,
                    })
                })
                .collect();
            result_response(request.id, json!({ "keys": keys }))
        }
        "vaultsigner.sign" => handle_sign(backend, throttle, caller_identity, request.id, request.params),
        other => error_response(request.id, "method_not_found", format!("unknown method: {other}")),
    }
}

fn handle_sign(backend: &dyn SigningBackend, throttle: &ThrottleTracker, caller_identity: &str, id: Value, params: Value) -> Vec<u8> {
    let params: SignParams = match serde_json::from_value(params) {
        Ok(p) => p,
        Err(e) => return error_response(id, "invalid_params", e.to_string()),
    };
    let key_id = match Uuid::parse_str(&params.key_id) {
        Ok(k) => k,
        Err(_) => return error_response(id, "invalid_params", "key_id is not a valid UUID"),
    };
    let message = match BASE64.decode(&params.message_b64) {
        Ok(m) => m,
        Err(_) => return error_response(id, "invalid_params", "message_b64 is not valid base64"),
    };
    let _ = params.algorithm; // informational only; the backend signs with the key's actual type

    let secret = SecretId::key(key_id);
    if throttle.check(&secret).is_err() {
        return error_response(id, "key_locked_retry_later", "too many recent failed attempts for this key");
    }

    match backend.sign(caller_identity, key_id, &message) {
        SignOutcome::Signed { signature, public_key } => {
            throttle.record_success(&secret);
            result_response(
                id,
                json!({
                    "signature_b64": BASE64.encode(&signature),
                    "public_key_b64": BASE64.encode(&public_key),
                }),
            )
        }
        SignOutcome::KeyNotFound => error_response(id, "key_not_found", "no such key"),
        SignOutcome::UserDeclined => error_response(id, "user_declined", "user declined the signing request"),
        SignOutcome::PassphraseIncorrect => {
            throttle.record_failure(&secret);
            error_response(id, "passphrase_incorrect", "incorrect passphrase")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::time::Duration;

    struct FakeBackend {
        keys: HashMap<Uuid, PublicKeyInfo>,
        /// Queue of scripted outcomes for successive `sign` calls, so a
        /// test can simulate "wrong passphrase three times, then
        /// right."
        script: RefCell<Vec<SignOutcome>>,
    }

    impl SigningBackend for FakeBackend {
        fn list_public_keys(&self) -> Vec<PublicKeyInfo> {
            self.keys.values().cloned().collect()
        }

        fn sign(&self, _caller_identity: &str, key_id: Uuid, _message: &[u8]) -> SignOutcome {
            if !self.keys.contains_key(&key_id) {
                return SignOutcome::KeyNotFound;
            }
            self.script.borrow_mut().pop().unwrap_or(SignOutcome::UserDeclined)
        }
    }

    fn backend_with(key_id: Uuid, script: Vec<SignOutcome>) -> FakeBackend {
        let mut keys = HashMap::new();
        keys.insert(
            key_id,
            PublicKeyInfo {
                key_id,
                label: "Deploy signing key".into(),
                public_key: vec![1, 2, 3],
                resource: "example.com".into(),
            },
        );
        // `script` is popped from the end, so callers write it in
        // call-order and we reverse once here.
        let mut script = script;
        script.reverse();
        FakeBackend { keys, script: RefCell::new(script) }
    }

    fn fast_throttle() -> ThrottleTracker {
        ThrottleTracker::with_params(3, Duration::from_millis(20), Duration::from_millis(200))
    }

    fn get_str<'a>(v: &'a Value, path: &[&str]) -> &'a str {
        let mut cur = v;
        for p in path {
            cur = &cur[*p];
        }
        cur.as_str().unwrap()
    }

    #[test]
    fn successful_sign_returns_signature_and_clears_throttle() {
        let key_id = Uuid::new_v4();
        let backend = backend_with(
            key_id,
            vec![SignOutcome::Signed { signature: vec![9, 9, 9], public_key: vec![1, 2, 3] }],
        );
        let throttle = fast_throttle();
        let req = json!({
            "method": "vaultsigner.sign",
            "params": { "key_id": key_id, "message_b64": BASE64.encode(b"hello"), "algorithm": "ed25519" },
            "id": 1,
        });
        let resp_bytes = handle_request(&backend, &throttle, "App 'Foo'", &serde_json::to_vec(&req).unwrap());
        let resp: Value = serde_json::from_slice(&resp_bytes).unwrap();
        assert_eq!(get_str(&resp, &["result", "signature_b64"]), BASE64.encode([9, 9, 9]));
        assert!(throttle.check(&SecretId::key(key_id)).is_ok());
    }

    #[test]
    fn unknown_key_returns_key_not_found() {
        let backend = backend_with(Uuid::new_v4(), vec![]);
        let throttle = fast_throttle();
        let req = json!({
            "method": "vaultsigner.sign",
            "params": { "key_id": Uuid::new_v4(), "message_b64": BASE64.encode(b"m"), "algorithm": "ed25519" },
            "id": "req-1",
        });
        let resp_bytes = handle_request(&backend, &throttle, "caller", &serde_json::to_vec(&req).unwrap());
        let resp: Value = serde_json::from_slice(&resp_bytes).unwrap();
        assert_eq!(get_str(&resp, &["error", "code"]), "key_not_found");
        assert_eq!(resp["id"], json!("req-1"));
    }

    #[test]
    fn wrong_passphrase_locks_out_after_threshold_and_backend_is_never_consulted_while_locked() {
        let key_id = Uuid::new_v4();
        // Three scripted wrong-passphrase outcomes, then a fourth that
        // would succeed — but the fourth call must never reach the
        // backend once throttled.
        let backend = backend_with(
            key_id,
            vec![
                SignOutcome::PassphraseIncorrect,
                SignOutcome::PassphraseIncorrect,
                SignOutcome::PassphraseIncorrect,
                SignOutcome::Signed { signature: vec![1], public_key: vec![2] },
            ],
        );
        let throttle = fast_throttle(); // threshold = 3
        let make_req = || {
            serde_json::to_vec(&json!({
                "method": "vaultsigner.sign",
                "params": { "key_id": key_id, "message_b64": BASE64.encode(b"m"), "algorithm": "ed25519" },
                "id": 1,
            }))
            .unwrap()
        };

        for _ in 0..3 {
            let resp: Value = serde_json::from_slice(&handle_request(&backend, &throttle, "c", &make_req())).unwrap();
            assert_eq!(get_str(&resp, &["error", "code"]), "passphrase_incorrect");
        }

        // Fourth call: throttled, so this must be key_locked_retry_later
        // even though the backend script has a "Signed" outcome queued.
        let resp: Value = serde_json::from_slice(&handle_request(&backend, &throttle, "c", &make_req())).unwrap();
        assert_eq!(get_str(&resp, &["error", "code"]), "key_locked_retry_later");
        assert_eq!(backend.script.borrow().len(), 1, "the queued Signed outcome must be untouched: backend was never called");
    }

    #[test]
    fn list_public_keys_never_includes_private_material() {
        let key_id = Uuid::new_v4();
        let backend = backend_with(key_id, vec![]);
        let throttle = fast_throttle();
        let req = json!({ "method": "vaultsigner.list_public_keys", "params": {}, "id": 1 });
        let resp_bytes = handle_request(&backend, &throttle, "c", &serde_json::to_vec(&req).unwrap());
        let resp: Value = serde_json::from_slice(&resp_bytes).unwrap();
        let keys = resp["result"]["keys"].as_array().unwrap();
        assert_eq!(keys.len(), 1);
        let allowed_fields: std::collections::HashSet<&str> =
            ["key_id", "label", "public_key_b64", "resource"].into_iter().collect();
        for field in keys[0].as_object().unwrap().keys() {
            assert!(allowed_fields.contains(field.as_str()), "unexpected field in list_public_keys result: {field}");
        }
    }

    #[test]
    fn malformed_json_fails_closed_without_panicking() {
        let throttle = fast_throttle();
        let backend = backend_with(Uuid::new_v4(), vec![]);
        let resp_bytes = handle_request(&backend, &throttle, "c", b"{not valid json at all");
        let resp: Value = serde_json::from_slice(&resp_bytes).unwrap();
        assert_eq!(get_str(&resp, &["error", "code"]), "parse_error");
        assert_eq!(resp["id"], Value::Null);
    }

    #[test]
    fn unknown_method_is_rejected() {
        let throttle = fast_throttle();
        let backend = backend_with(Uuid::new_v4(), vec![]);
        let req = json!({ "method": "vaultsigner.delete_everything", "params": {}, "id": 1 });
        let resp: Value = serde_json::from_slice(&handle_request(&backend, &throttle, "c", &serde_json::to_vec(&req).unwrap())).unwrap();
        assert_eq!(get_str(&resp, &["error", "code"]), "method_not_found");
    }

    #[test]
    fn invalid_base64_message_is_rejected_before_reaching_backend() {
        let key_id = Uuid::new_v4();
        let backend = backend_with(key_id, vec![SignOutcome::Signed { signature: vec![], public_key: vec![] }]);
        let throttle = fast_throttle();
        let req = json!({
            "method": "vaultsigner.sign",
            "params": { "key_id": key_id, "message_b64": "not-valid-base64!!!", "algorithm": "ed25519" },
            "id": 1,
        });
        let resp: Value = serde_json::from_slice(&handle_request(&backend, &throttle, "c", &serde_json::to_vec(&req).unwrap())).unwrap();
        assert_eq!(get_str(&resp, &["error", "code"]), "invalid_params");
        assert_eq!(backend.script.borrow().len(), 1, "backend must not be called for a request that fails to parse");
    }

    #[test]
    fn user_declined_does_not_affect_throttle() {
        let key_id = Uuid::new_v4();
        let backend = backend_with(key_id, vec![SignOutcome::UserDeclined]);
        let throttle = fast_throttle();
        let req = json!({
            "method": "vaultsigner.sign",
            "params": { "key_id": key_id, "message_b64": BASE64.encode(b"m"), "algorithm": "ed25519" },
            "id": 1,
        });
        let resp: Value = serde_json::from_slice(&handle_request(&backend, &throttle, "c", &serde_json::to_vec(&req).unwrap())).unwrap();
        assert_eq!(get_str(&resp, &["error", "code"]), "user_declined");
        assert_eq!(throttle.remaining_lockout(&SecretId::key(key_id)), None);
    }
}
