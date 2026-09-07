//! Generates Swift/Kotlin/C#/Python bindings from the `#[uniffi::export]`
//! scaffolding in `vault.rs` (spec §12 item 1.11). Build the cdylib first,
//! then run this against it, e.g.:
//!
//! ```text
//! cargo build --release --features uniffi
//! cargo run --release --features uniffi --bin uniffi-bindgen -- \
//!     generate --library ../target/release/libvaultcore.dylib \
//!     --language swift --out-dir bindings/swift
//! ```

fn main() {
    uniffi::uniffi_bindgen_main()
}
