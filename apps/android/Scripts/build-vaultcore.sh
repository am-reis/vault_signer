#!/usr/bin/env bash
# Cross-compiles vaultcore's cdylib for every Android ABI via cargo-ndk and
# copies the result into app/src/main/jniLibs/<abi>/libvaultcore.so — spec
# §12 item 4's "new work for you" (cross-compiling per ABI, packaging into
# jniLibs), not re-proving UniFFI-Kotlin works at all (already verified on
# the desktop JVM, see PROGRESS.md Phase 1 item 1.11; what's new here is
# doing it on Android's actual runtime/linker).
#
# Requires: rustup targets aarch64-linux-android, armv7-linux-androideabi,
# x86_64-linux-android, i686-linux-android; cargo-ndk; ANDROID_NDK_HOME (or
# ANDROID_HOME with an `ndk/<version>` side-by-side install) pointed at a
# real NDK install.
set -euo pipefail

: "${ANDROID_HOME:=$HOME/Android/Sdk}"
: "${ANDROID_NDK_HOME:=$ANDROID_HOME/ndk/28.2.13676358}"
export ANDROID_NDK_HOME

if [ ! -d "$ANDROID_NDK_HOME" ]; then
  echo "error: ANDROID_NDK_HOME ($ANDROID_NDK_HOME) does not exist" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ANDROID_APP_DIR/../.." && pwd)"
VAULTCORE_DIR="$REPO_ROOT/vaultcore"
JNILIBS_DIR="$ANDROID_APP_DIR/app/src/main/jniLibs"

# API 34 floor (spec §6.3/§12 item 0.2) — cargo-ndk's --platform sets the
# min-SDK the compiled .so targets, independent of the app's own minSdk
# declaration, so both stay in lock-step deliberately.
PLATFORM=34

echo "==> Cross-compiling vaultcore (release, uniffi feature) for all 4 Android ABIs"
cd "$VAULTCORE_DIR"
cargo ndk \
  -t arm64-v8a \
  -t armeabi-v7a \
  -t x86_64 \
  -t x86 \
  --platform "$PLATFORM" \
  -o "$JNILIBS_DIR" \
  build --release --features uniffi

echo "==> jniLibs populated:"
find "$JNILIBS_DIR" -name '*.so' -exec ls -lh {} \;

# `cargo ndk` builds into the *workspace* root's target/ dir (this is a
# Cargo workspace — vaultcore/Cargo.toml's own `target/` is never used),
# i.e. $REPO_ROOT/target/<triple>/release/libvaultcore.so — already
# exactly where app/build.gradle.kts's `generateUniffiBindings` task
# looks for a library to introspect. Nothing left to copy.
echo "==> Done. UniFFI bindgen will read: $REPO_ROOT/target/x86_64-linux-android/release/libvaultcore.so"
