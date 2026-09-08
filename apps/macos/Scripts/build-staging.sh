#!/bin/bash
# Builds VaultSigner.app (+ embedded VaultSignerAgent.app) in Release
# configuration with a real, stable Development certificate, and
# installs it to /Applications.
#
# Why this exists (spec §8's "start at login" login item): SMAppService
# validates that the embedded agent it's launching is trustworthy
# relative to its parent app, at a stable on-disk location. A Debug
# build run straight out of Xcode's DerivedData fails this — the path
# changes across rebuilds and Automatic signing mints a fresh ad-hoc
# identity each time — which is exactly what produced a permanently
# failing launchd job (exit 78/EX_CONFIG) on this machine. Building
# once with a real certificate and installing to a stable path is the
# actual fix, not a workaround.
#
# Requires: a free (or paid) Apple ID added in Xcode → Settings →
# Accounts, so a Development certificate exists. Find your Team ID with
# `security find-identity -v -p codesigning` or Xcode → Settings →
# Accounts → your team → Manage Certificates.
#
# Usage: VAULTSIGNER_TEAM_ID=XXXXXXXXXX ./Scripts/build-staging.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_APP_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$MACOS_APP_DIR/.staging-build"
INSTALL_PATH="/Applications/VaultSigner.app"

if [[ -z "${VAULTSIGNER_TEAM_ID:-}" ]]; then
    echo "build-staging.sh: set VAULTSIGNER_TEAM_ID to your Apple Development team ID." >&2
    echo "  Find it with: security find-identity -v -p codesigning" >&2
    exit 1
fi

echo "build-staging.sh: generating Xcode project..."
(cd "$MACOS_APP_DIR" && xcodegen generate)

echo "build-staging.sh: building VaultSigner (Release, team $VAULTSIGNER_TEAM_ID)..."
rm -rf "$BUILD_DIR"
xcodebuild \
    -project "$MACOS_APP_DIR/VaultSigner.xcodeproj" \
    -scheme VaultSigner \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    VAULTSIGNER_TEAM_ID="$VAULTSIGNER_TEAM_ID" \
    clean build

BUILT_APP="$BUILD_DIR/Build/Products/Release/VaultSigner.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "build-staging.sh: expected $BUILT_APP to exist after build" >&2
    exit 1
fi

echo "build-staging.sh: verifying the code signature..."
codesign --verify --deep --strict "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP/Contents/Library/LoginItems/VaultSignerAgent.app"

if [[ -d "$INSTALL_PATH" ]]; then
    echo "build-staging.sh: quitting any running VaultSigner/VaultSignerAgent first..."
    osascript -e 'tell application "VaultSigner" to quit' >/dev/null 2>&1 || true
    osascript -e 'tell application "VaultSignerAgent" to quit' >/dev/null 2>&1 || true
    sleep 1
    echo "build-staging.sh: removing previous install at $INSTALL_PATH..."
    rm -rf "$INSTALL_PATH"
fi

echo "build-staging.sh: installing to $INSTALL_PATH..."
ditto "$BUILT_APP" "$INSTALL_PATH"

cat <<EOF

Installed: $INSTALL_PATH

Next steps:
  1. open "$INSTALL_PATH"
  2. In VaultSigner's Settings, toggle "Start at Login" OFF then ON
     (this re-registers the login item against the new, stable
     install path — required if you'd enabled it before against a
     DerivedData build).
  3. If macOS prompts you, approve it in System Settings → General →
     Login Items & Extensions.
  4. Verify it's actually running:
     launchctl print gui/\$(id -u)/com.vaultsigner.agent | grep -E 'state|pid'
EOF
