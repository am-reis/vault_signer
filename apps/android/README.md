# VaultSigner — Android

Phase 4 target (spec §12 item 4). Kotlin/Jetpack Compose app, binding to
`vaultcore` via generated UniFFI Kotlin bindings over JNA.

**For current status, read `PROGRESS.md` at the repo root** — that file,
not this one, is the kept-current status log for this project (per its
own convention: platform READMEs tend to go stale; `PROGRESS.md` is what
actually gets updated as work happens). See its Phase 4 section for what
is built, what is real-device-verified, and what is still open.

## Building

```
Scripts/build-vaultcore.sh   # cross-compiles vaultcore per ABI into jniLibs (needs the Android NDK)
./gradlew :app:assembleDebug # regenerates the UniFFI Kotlin bindings, then builds
```

`docs/protocol-integration.md` in this directory documents the real
custom-protocol transport this platform uses.
