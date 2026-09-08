#!/bin/bash
# Shared postCompileScripts step for every target that links vaultcore
# (VaultSigner, VaultSignerAgent, VaultSignerCredentialProvider):
# embeds a self-contained copy of libvaultcore.dylib in the target's own
# bundle and repoints its load command at @rpath, instead of the
# absolute build-machine path that LIBRARY_SEARCH_PATHS + `-lvaultcore`
# bakes in by default.
#
# Without this, the built app only runs by coincidence of the checkout
# staying at the exact same absolute path forever (Xcode's Debug
# launches tolerate an unsigned dylib load from outside the bundle) —
# a real Release build, run outside Xcode with Hardened Runtime and
# strict library validation actually enforced, fails outright: dyld
# refuses to load a dylib with no valid code signature from a path
# that isn't part of the signed app bundle. This is exactly what broke
# the first VaultSigner.app install to /Applications (see PROGRESS.md).
set -euo pipefail

DYLIB_SRC="$SRCROOT/../../target/release/libvaultcore.dylib"
FRAMEWORKS_DIR="$CODESIGNING_FOLDER_PATH/Contents/Frameworks"
DYLIB_DEST="$FRAMEWORKS_DIR/libvaultcore.dylib"
EXECUTABLE="$CODESIGNING_FOLDER_PATH/Contents/MacOS/$EXECUTABLE_NAME"

mkdir -p "$FRAMEWORKS_DIR"
cp "$DYLIB_SRC" "$DYLIB_DEST"
install_name_tool -id @rpath/libvaultcore.dylib "$DYLIB_DEST"

OLD_REF="$(otool -L "$EXECUTABLE" | awk '/libvaultcore\.dylib/ {print $1; exit}')"
if [[ -n "$OLD_REF" && "$OLD_REF" != "@rpath/libvaultcore.dylib" ]]; then
    install_name_tool -change "$OLD_REF" @rpath/libvaultcore.dylib "$EXECUTABLE"
fi

# Xcode's own CodeSign phase runs after postCompileScripts and will
# sign $EXECUTABLE fresh (covering the load-command change above), but
# it won't sign this just-copied dylib on its own — do that here.
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DYLIB_DEST"
