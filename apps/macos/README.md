# VaultSigner — macOS

Phase 2 target (spec §12). See `/PROGRESS.md` at the repo root for the
authoritative per-item status; this file covers macOS-specific setup and
known architectural gaps not worth restating there.

## Project layout

- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec.
  Run `xcodegen generate` after editing it or after adding/removing
  source files (`VaultSigner.xcodeproj` itself is not checked in — see
  `.gitignore`).
- `Scripts/generate-bindings.sh` — builds `vaultcore` (release, `uniffi`
  feature) and regenerates `Generated/` (the UniFFI Swift bindings; also
  not checked in). Run this, then `xcodegen generate`, whenever
  `vaultcore`'s `#[uniffi::export]` surface changes.
- `VaultSigner/` — the SwiftUI management app (spec §12 item 2.1),
  including `LoginItemManager.swift` (spec §8's login-item toggle) and
  `Views/SettingsView.swift` (both of item 2.6's toggles).
- `VaultSignerAgent/` — the background service (spec §8, item 2.6): owns
  an unlocked `Vault` and the custom local signing protocol's Unix-socket
  transport (spec §7, item 2.8). Embedded inside `VaultSigner.app` at
  build time (see `project.yml`'s `postCompileScripts`) so
  `SMAppService` can register it as a real login item.
- `Shared/` — `VaultConfig.swift` (the vault path + which compartment
  auto-unlocks) and `AutoUnlockStore.swift` (the Keychain wrapper), used
  by both targets above — the agent has no CLI/UI to receive these from
  directly, only what `VaultSigner.app` persisted for it.
- `uniffi-verify/agent_test_client.py` — the minimal test client spec
  §12 item 2.8 asks for; see its docstring for what it checks.

To build from scratch:

```bash
./Scripts/generate-bindings.sh
xcodegen generate
xcodebuild -project VaultSigner.xcodeproj -scheme VaultSigner -configuration Debug -destination 'platform=macOS' build
xcodebuild -project VaultSigner.xcodeproj -scheme VaultSignerAgent -configuration Debug -destination 'platform=macOS' build
```

## Status against spec §12 Phase 2

- **2.1 SwiftUI management UI** — real, `Vault`-backed screens exist:
  create/open a vault, the multi-compartment unlock selector, key list,
  create key, and key detail (change passphrase / reveal raw key /
  discard with two-step confirmation). Builds and launches cleanly (no
  crash). **Not yet visually verified**: this development environment's
  terminal (running under the Claude desktop app) has neither Screen
  Recording nor Accessibility permission granted in System Settings →
  Privacy & Security, so screenshots of the running app come back
  showing the desktop instead of window content, and AppleScript/System
  Events UI-driving is refused outright. Grant both to `Claude.app` to
  unblock real visual verification of every screen in this app.
- **2.2 Screen-capture blocking** — `CaptureProtected.swift` sets
  `NSWindow.sharingType = .none` (spec §5.0) and is applied to the main
  window plus every sheet (sheets are separate `NSWindow`s on macOS, so
  the main window's setting doesn't propagate to them). Same visual-
  verification caveat as 2.1 — the *mechanism* is exercised by every
  build, but "screenshots of this window come back blank" hasn't been
  independently confirmed the way it should be before calling this done.
- **2.3 Export flows, 2.4 Import flow, 2.5 Backup** — **not started.**
  These need the §5.2 export-packet transfer-encryption layer
  (`.vltpack`'s three wrapping options), which doesn't exist anywhere in
  `vaultcore` yet (see `PROGRESS.md` item 1.11's note on this same gap).
  Building UI on top of a format that doesn't exist would be the same
  kind of unverified guesswork this project has consistently avoided.
  `vaultcore::merge` (the §5.3 three-way merge logic) is already fully
  implemented and facade-wrapped (`Vault::merge_*`), so once a `packet`
  module exists in `vaultcore`, the UI layer here is the remaining piece.
- **2.6 `launchd` background service** — **done and verified**, with one
  disclosed caveat. `VaultSignerAgent` is a real process, embedded inside
  `VaultSigner.app` (`Contents/Resources/VaultSignerAgent.app`) and
  registered as a genuine `launchd` agent via `SMAppService.agent(plistName:)`
  (`LoginItemManager.swift`, toggled from the real Settings screen —
  `--test-login-item register/unregister/status` is the same call path
  used to verify it headlessly). `RunAtLoad`/`KeepAlive` in the embedded
  `com.vaultsigner.agent.plist` give real launchd-supervised
  restart-on-failure: verified directly with `launchctl print` (real job,
  `managed_by = com.apple.xpc.ServiceManagement`) and `launchctl kickstart`
  (killed and watched launchd revive it, `runs` incrementing each time).
  `AlertPassphrasePrompter`'s real `NSAlert` passphrase prompt was
  verified interactively end to end: a `vaultsigner.sign` request for a
  never-unlocked key showed the dialog, blocked until answered, and
  returned a signature that independently verifies against the key's real
  public key. "Auto-unlock on startup" (`AutoUnlockStore.swift`, Keychain-
  backed, off by default, gated behind an in-app risk-explanation
  confirmation screen that verifies the passphrase against the vault
  *before* ever writing it to the Keychain) is also verified end to end: a
  freshly-launched agent listed the real key over the socket with zero
  `internal.unlock_*` calls ever sent to it. **Caveat, observed while
  verifying, not just theorized:** the first time `VaultSignerAgent`
  tried to read the Keychain item `VaultSigner.app` wrote, macOS's
  `SecurityAgent` showed a real cross-app access-confirmation dialog
  (`VaultSigner.app` and `VaultSignerAgent.app` are two separately
  ad-hoc-signed binaries with no shared Team ID/keychain-access-group) —
  denying it silently breaks auto-unlock (the agent just starts locked,
  no error surfaced anywhere) until "Always Allow" is granted once. This
  is exactly the gap `AutoUnlockStore`'s doc comment already predicted:
  full parity with spec §8's "Keychain can scope decryption to the
  requesting app/process" claim needs a real Team ID (same underlying
  constraint as item 2.7's signing requirement) to set a proper
  `kSecAttrAccessGroup`; until then, the first-launch prompt is expected,
  and a denied prompt fails silently rather than with a visible error —
  surfacing that failure in the UI is a good small follow-up.
  **Known architectural gap:** `VaultSigner.app` (the management UI)
  currently holds its own in-process `Vault` rather than routing every
  mutation through the agent over IPC the way spec §8 describes ("the
  management UI process never writes the container directly ... requests
  mutations from the service"). `AgentServer`'s `internal.*` namespace
  only covers what item 2.8's own verification needed
  (`unlock_compartment`, `unlock_key`, `list_compartments`) — extending it
  to the full management surface and switching the UI app to talk to the
  agent instead of vaultcore directly is real follow-up work, not done.
- **2.7 `ASCredentialProviderExtension`** — **not started.** Needs real
  Apple Developer signing/provisioning and interactive verification
  against live relying parties in Safari and Chrome per the spec's own
  wording — this is not something to fake or partially build without
  that verification path available.
- **2.8 Custom protocol verified against a minimal test client** —
  **done and verified.** `uniffi-verify/agent_test_client.py` runs fully
  non-interactively (~0.7s) against the real running `VaultSignerAgent`
  over its Unix socket and checks: `vaultsigner.list_public_keys` never
  leaks anything beyond `key_id`/`label`/`public_key_b64`/`resource`; an
  unknown `key_id` returns `key_not_found`; and — after unlocking the key
  via the `internal.unlock_key` bootstrap method (deliberately avoiding
  the interactive `AlertPassphrasePrompter` path, which needs a human —
  see 2.6) — `vaultsigner.sign` returns a signature that independently
  verifies (via PyNaCl) against the key's real Ed25519 public key. Peer
  identity for the confirmation-text caller name is resolved via
  `LOCAL_PEERPID`/`proc_pidpath` (OS-level, per spec §7 — never a
  self-reported name from the request payload).
- **2.9 i18n, 2.10 full test/fuzz pass** — not started; depend on the
  above.
