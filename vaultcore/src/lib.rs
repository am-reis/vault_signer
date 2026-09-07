//! VaultSigner shared core (spec §2): the sole implementation of the
//! container format, KDF, AEAD, manifest schema, merge logic, and
//! (eventually) CTAP2/JSON-RPC handling. Every platform binds to this
//! compiled core — no platform may reimplement, port, or hand-mirror any
//! parsing, merge, or cryptographic logic (spec §2, hard constraint).
//!
//! This crate never renders UI and never owns a window.
//!
//! ## Status
//! See `/PROGRESS.md` at the repo root for what is implemented versus
//! outstanding against the spec §12 execution plan. As of this writing:
//! container format + atomic writes, the Argon2id KDF wrapper, AEAD,
//! the manifest schema, Ed25519/P-256 key generation, the retention
//! cache, passphrase throttling, the per-key and per-compartment blob
//! codecs, and the three-way master-key merge logic are implemented and
//! unit-tested. CTAP2 handling, the custom-protocol JSON-RPC server, and
//! UniFFI bindings are not yet implemented.

pub mod aead;
pub mod container;
pub mod error;
pub mod kdf;
pub mod keyblob;
pub mod keys;
pub mod manifest;
pub mod master_blob;
pub mod merge;
pub mod retention;
pub mod throttle;

pub use error::{Result, VaultError};
