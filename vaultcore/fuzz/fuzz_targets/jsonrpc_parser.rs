//! Fuzz target for the custom-protocol JSON-RPC message handler (spec
//! §10: "Fuzz-test ... the custom-protocol JSON parser. Malformed or
//! truncated inputs must fail closed, never crash the background
//! service").
//!
//! Feeds arbitrary bytes straight to `protocol::handle_request`, backed
//! by a no-op `SigningBackend` (a real backend has already been ruled
//! out as the concern here — this target is specifically about the
//! request parsing/dispatch layer never panicking on hostile input, not
//! about the signing logic).

#![no_main]

use libfuzzer_sys::fuzz_target;
use uuid::Uuid;
use vaultcore::protocol::{handle_request, PublicKeyInfo, SignOutcome, SigningBackend};
use vaultcore::throttle::ThrottleTracker;

struct NoopBackend;

impl SigningBackend for NoopBackend {
    fn list_public_keys(&self) -> Vec<PublicKeyInfo> {
        Vec::new()
    }

    fn sign(&self, _caller_identity: &str, _key_id: Uuid, _message: &[u8]) -> SignOutcome {
        SignOutcome::KeyNotFound
    }
}

fuzz_target!(|data: &[u8]| {
    let backend = NoopBackend;
    let throttle = ThrottleTracker::new();
    let _ = handle_request(&backend, &throttle, "fuzz-caller", data);
});
