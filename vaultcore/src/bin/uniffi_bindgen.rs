//! Generates Swift/Kotlin/Python/Ruby bindings from the
//! `#[uniffi::export]` scaffolding in `vault.rs` (spec §12 item 1.11).
//! Build the cdylib first, then run this against it, e.g.:
//!
//! ```text
//! cargo build --release --features uniffi
//! cargo run --release --features uniffi --bin uniffi-bindgen -- \
//!     generate --library ../target/release/libvaultcore.dylib \
//!     --language swift --out-dir bindings/swift
//! ```
//!
//! C# is **not** one of `uniffi`'s own supported languages (confirmed
//! via this binary's own `--help`: only kotlin/swift/python/ruby) —
//! Windows (spec §12 item 3.x) uses the separate community tool
//! `uniffi-bindgen-cs` instead; see
//! `apps/windows/Scripts/generate-csharp-bindings.sh`.

fn main() {
    uniffi::uniffi_bindgen_main()
}
