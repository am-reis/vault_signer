#!/usr/bin/env bash
# Packages the two Android release artifacts described in
# docs/release-process.md and CLAUDE.md's "Release artifacts" section:
# one Android App Bundle per flavor, both from the exact same commit and
# the exact same version number (unlike macOS/vaultcore, there is no
# second, independent version argument here — see docs/release-process.md
# for why "full" and "lite" deliberately don't get one).
#
# Builds both release bundles itself (unlike macOS's package-release.sh,
# which packages an already-built app) since there's nothing analogous to
# Xcode's separate build-staging.sh step here — Gradle's bundleRelease
# tasks are already reproducible ("./gradlew :app:bundleFullRelease" from
# any clean checkout), so a separate build script would only duplicate
# what Gradle already does.
#
# Usage: ./Scripts/package-release.sh <android-vX.Y.Z>
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <android-vX.Y.Z>" >&2
    exit 1
fi
# Strip the "android-" tag prefix for the artifact filenames themselves
# (CLAUDE.md's tag is "android-vX.Y.Z"; the artifacts are named
# "...-vX.Y.Z", matching the vX.Y.Z part only, same convention as macOS's
# "macos-vX.Y.Z" tag producing "VaultSigner-macOS-vX.Y.Z.zip").
PLATFORM_VERSION="${VERSION#android-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_APP_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$ANDROID_APP_DIR/.release-artifacts"

echo "package-release.sh: cross-compiling vaultcore (if not already fresh)..."
"$SCRIPT_DIR/build-vaultcore.sh"

echo "package-release.sh: building both flavors' release bundles..."
(cd "$ANDROID_APP_DIR" && ./gradlew :app:bundleFullRelease :app:bundleLiteRelease)

FULL_AAB="$ANDROID_APP_DIR/app/build/outputs/bundle/fullRelease/app-full-release.aab"
LITE_AAB="$ANDROID_APP_DIR/app/build/outputs/bundle/liteRelease/app-lite-release.aab"
for aab in "$FULL_AAB" "$LITE_AAB"; do
    if [[ ! -f "$aab" ]]; then
        echo "package-release.sh: expected bundle not found: $aab" >&2
        exit 1
    fi
done

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$FULL_AAB" "$OUT_DIR/VaultSigner-Android-full-$PLATFORM_VERSION.aab"
cp "$LITE_AAB" "$OUT_DIR/VaultSigner-Android-lite-$PLATFORM_VERSION.aab"

cat <<EOF

Packaged:
  $OUT_DIR/VaultSigner-Android-full-$PLATFORM_VERSION.aab
  $OUT_DIR/VaultSigner-Android-lite-$PLATFORM_VERSION.aab

Both come from this exact commit and carry the identical version number
(spec: no independent versioning between flavors) — see
docs/release-process.md for the full reasoning, and CLAUDE.md's Release
artifacts section for how to publish them against the single
"$VERSION" tag on main.

NOT yet done by this script, and not yet set up in this project at all:
release signing. These .aab files are built with Gradle's default
(unsigned/debug-signed) release config — see docs/release-process.md's
"Known gaps" section before actually uploading either to Play Console.
EOF
