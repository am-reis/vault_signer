#!/bin/bash
# Packages the two macOS release artifacts described in CLAUDE.md's
# "Release artifacts" section, from an already-built Release
# configuration (Scripts/build-staging.sh's output). Does no signing or
# building of its own — run build-staging.sh first.
#
# Usage: ./Scripts/package-release.sh vX.Y.Z
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "$MACOS_APP_DIR/../.." && pwd)"
BUILT_APP="$MACOS_APP_DIR/.staging-build/Build/Products/Release/VaultSigner.app"
OUT_DIR="$MACOS_APP_DIR/.release-artifacts"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 vX.Y.Z" >&2
    exit 1
fi

if [[ ! -d "$BUILT_APP" ]]; then
    echo "package-release.sh: $BUILT_APP not found — run Scripts/build-staging.sh first." >&2
    exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "package-release.sh: packaging VaultSigner.app..."
APP_ZIP="$OUT_DIR/VaultSigner-macOS-$VERSION.zip"
ditto -c -k --keepParent "$BUILT_APP" "$APP_ZIP"

echo "package-release.sh: packaging the vaultcore library bundle..."
LIB_STAGE="$OUT_DIR/vaultcore-$VERSION-macos"
mkdir -p "$LIB_STAGE"
cp "$REPO_ROOT/target/release/libvaultcore.dylib" "$LIB_STAGE/"
cp "$REPO_ROOT/target/release/libvaultcore.a" "$LIB_STAGE/" 2>/dev/null || true
cp "$MACOS_APP_DIR/Generated/vaultcore.swift" "$LIB_STAGE/"
cp "$MACOS_APP_DIR/Generated/vaultcoreFFI.h" "$LIB_STAGE/"
cp "$MACOS_APP_DIR/Generated/vaultcoreFFI.modulemap" "$LIB_STAGE/"
LIB_ZIP="$OUT_DIR/vaultcore-$VERSION-macos.zip"
(cd "$OUT_DIR" && zip -qr "$(basename "$LIB_ZIP")" "$(basename "$LIB_STAGE")")
rm -rf "$LIB_STAGE"

cat <<EOF

Packaged:
  $APP_ZIP
  $LIB_ZIP

Publish these against the $VERSION tag on main — see CLAUDE.md's
"Release artifacts" section for the exact steps.
EOF
