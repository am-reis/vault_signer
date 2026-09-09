//! VaultSigner shared core (spec §2): the sole implementation of the
//! container format, KDF, AEAD, manifest schema, merge logic, and
//! CTAP2/JSON-RPC handling. Every platform binds to this compiled core —
//! no platform may reimplement, port, or hand-mirror any parsing,
//! merge, or cryptographic logic (spec §2, hard constraint).
//!
//! This crate never renders UI and never owns a window.
//!
//! ## Status
//! See `/PROGRESS.md` at the repo root for what is implemented versus
//! outstanding against the spec §12 execution plan. As of this writing,
//! every Phase 1 item is implemented and unit-tested: the container
//! format + atomic writes, the Argon2id KDF wrapper, AEAD, the manifest
//! schema, Ed25519/P-256 key generation and signing, the retention
//! cache, passphrase throttling, the per-key and per-compartment blob
//! codecs, the three-way master-key merge logic, the custom local
//! signing protocol's JSON-RPC message handling, CTAP2
//! `authenticatorMakeCredential`/`authenticatorGetAssertion` handling,
//! the [`vault`] facade tying all of the above into the one API a
//! platform app actually calls, and UniFFI bindings (1.11) generated
//! from that facade and verified callable from real compiled Swift
//! against the real Rust `cdylib` — see `vaultcore/uniffi-verify/`.
//! Kotlin is verified the same way, from real compiled Kotlin against
//! JNA. C# has no first-party UniFFI bindgen support as of the `uniffi`
//! version pinned here.

pub mod aead;
pub mod container;
pub mod ctap2;
pub mod error;
pub mod kdf;
pub mod keyblob;
pub mod keys;
pub mod manifest;
pub mod master_blob;
pub mod mem_lock;
pub mod merge;
pub mod packet;
pub mod protocol;
pub mod retention;
pub mod throttle;
pub mod vault;

pub use error::{Result, VaultError};

#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
