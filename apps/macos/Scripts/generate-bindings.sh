#!/bin/bash
# Builds vaultcore's release staticlib (with the `uniffi` feature) and
# (re)generates its Swift UniFFI bindings into apps/macos/Generated/.
#
# Run this manually whenever vaultcore's `#[uniffi::export]` surface
# changes (new/changed Vault methods, records, enums), then run
# `xcodegen generate` in apps/macos/ to pick up the (re)generated
# Generated/vaultcore.swift as a normal source file, then build/open in
# Xcode as usual. Deliberately NOT wired up as an Xcode "Run Script"
# build phase: Xcode's classic folder-reference build phases don't
# recompile newly-appeared files the way a live "watch" would, and
# generating on every single build would also pay a real Argon2id-tuned
# Rust release-build cost (seconds, not free) on every keystroke-driven
# incremental build — a one-line manual regenerate step when the FFI
# surface actually changes is the better trade here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "$MACOS_APP_DIR/../.." && pwd)"
VAULTCORE_DIR="$REPO_ROOT/vaultcore"
OUT_DIR="$MACOS_APP_DIR/Generated"

echo "generate-bindings.sh: building vaultcore (release, uniffi feature)..."
cargo build --release --manifest-path "$VAULTCORE_DIR/Cargo.toml" --features uniffi

DYLIB="$REPO_ROOT/target/release/libvaultcore.dylib"
STATICLIB="$REPO_ROOT/target/release/libvaultcore.a"
if [[ ! -f "$STATICLIB" ]]; then
    echo "generate-bindings.sh: expected $STATICLIB to exist after build" >&2
    exit 1
fi

echo "generate-bindings.sh: generating Swift bindings into $OUT_DIR..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cargo run --release --manifest-path "$VAULTCORE_DIR/Cargo.toml" --features uniffi --bin uniffi-bindgen -- \
    generate --library "$DYLIB" --language swift --out-dir "$OUT_DIR"

echo "generate-bindings.sh: done."
