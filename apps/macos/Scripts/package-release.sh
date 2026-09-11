#!/bin/bash
# Packages the two macOS release artifacts described in CLAUDE.md's
# "Release artifacts" section, from an already-built Release
# configuration (Scripts/build-staging.sh's output). Does no signing or
# building of its own — run build-staging.sh first.
#
# Two separate version arguments, not one: the platform (macos-vX.Y.Z)
# and vaultcore (vaultcore-vA.B.C) version independently, per CLAUDE.md's
# Versioning section — they will often differ, since vaultcore is
# versioned by its own changes, not by whatever the app's own version is.
#
# Usage: ./Scripts/package-release.sh <macos-vX.Y.Z> <vaultcore-vA.B.C>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "$MACOS_APP_DIR/../.." && pwd)"
BUILT_APP="$MACOS_APP_DIR/.staging-build/Build/Products/Release/VaultSigner.app"
OUT_DIR="$MACOS_APP_DIR/.release-artifacts"

PLATFORM_VERSION="${1:-}"
VAULTCORE_VERSION="${2:-}"
if [[ -z "$PLATFORM_VERSION" || -z "$VAULTCORE_VERSION" ]]; then
    echo "usage: $0 <macos-vX.Y.Z> <vaultcore-vA.B.C>" >&2
    exit 1
fi

if [[ ! -d "$BUILT_APP" ]]; then
    echo "package-release.sh: $BUILT_APP not found — run Scripts/build-staging.sh first." >&2
    exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "package-release.sh: packaging VaultSigner.app..."
APP_ZIP="$OUT_DIR/VaultSigner-macOS-$PLATFORM_VERSION.zip"
ditto -c -k --keepParent "$BUILT_APP" "$APP_ZIP"

echo "package-release.sh: packaging the vaultcore library bundle..."
LIB_STAGE="$OUT_DIR/vaultcore-$VAULTCORE_VERSION-macos"
mkdir -p "$LIB_STAGE"
cp "$REPO_ROOT/target/release/libvaultcore.dylib" "$LIB_STAGE/"
cp "$REPO_ROOT/target/release/libvaultcore.a" "$LIB_STAGE/" 2>/dev/null || true
cp "$MACOS_APP_DIR/Generated/vaultcore.swift" "$LIB_STAGE/"
cp "$MACOS_APP_DIR/Generated/vaultcoreFFI.h" "$LIB_STAGE/"
cp "$MACOS_APP_DIR/Generated/vaultcoreFFI.modulemap" "$LIB_STAGE/"
LIB_ZIP="$OUT_DIR/vaultcore-$VAULTCORE_VERSION-macos.zip"
(cd "$OUT_DIR" && zip -qr "$(basename "$LIB_ZIP")" "$(basename "$LIB_STAGE")")
rm -rf "$LIB_STAGE"

cat <<EOF

Packaged:
  $APP_ZIP
  $LIB_ZIP

Publish the app zip against the $PLATFORM_VERSION tag on main, and note
in that release's notes that it bundles vaultcore $VAULTCORE_VERSION —
see CLAUDE.md's "Release artifacts" section for the exact steps.
EOF
