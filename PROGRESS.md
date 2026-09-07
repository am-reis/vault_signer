# VaultSigner — Progress

Mirrors the checklist IDs in `/spec/VaultSigner-Spec.md` §12. Read this
file first before starting work in any session. After finishing a
checklist item, update it here and commit — never mark an item done
without a passing build/test artifact referenced by commit hash.

Order is strictly platform-sequential per the spec: **macOS → Windows →
Android → iOS → Linux**, each preceded by the shared `vaultcore` work in
Phase 1.

---

## Phase 0 — Decisions

- [x] 0.1 Confirm UniFFI binding generation setup for Swift/Kotlin/C#/C
      targets. **Decision:** `uniffi` 0.29 (proc-macro-only, no `.udl`),
      gated behind an off-by-default `uniffi` Cargo feature on
      `vaultcore`; see Phase 1 item 1.11 for what's verified for each
      target language.
- [ ] 0.2 Confirm minimum supported OS version per platform. The spec's
      assumed floors (macOS 13+, Windows 10 2004+/11, Android 14+, iOS
      17+) are carried forward as working assumptions; **no fixed floor
      is set for Linux distributions** — this needs a product decision
      against target-user data before Phase 6, per spec §13 item 3. Not
      blocking for Phase 1/2 work.
- [x] 0.3 Confirm monorepo workspace tooling. **Decision:** a plain
      Cargo workspace (`/Cargo.toml`) with `vaultcore` as its only
      member for now. No cross-platform build orchestrator (Nx,
      Turborepo, Bazel, etc.) is introduced — each `/apps/<platform>`
      directory will use that platform's native toolchain (Xcode,
      MSBuild/Visual Studio, Gradle, GTK's own build) once that phase
      starts, and none of them may vendor or fork `vaultcore` logic
      (spec §2, §11). Revisit only if a concrete cross-platform
      orchestration need appears. (`eaa66fd`)

## Phase 1 — vaultcore (shared, built once, platform-agnostic)

- [x] 1.1 Container header read/write and versioning (§4.1), including
      atomic write-temp-then-rename semantics (§4.6).
      `vaultcore/src/container.rs`. (`eaa66fd`)
- [x] 1.2 Argon2id KDF wrapper with per-device benchmarking (§4.2).
      `vaultcore/src/kdf.rs`. (`eaa66fd`)
- [x] 1.3 AEAD encrypt/decrypt for manifest and key blobs, with tamper
      tests (§4.3). `vaultcore/src/aead.rs`. Uses the RustCrypto
      `chacha20poly1305` crate's `XChaCha20Poly1305` type — the spec's
      "xchacha20poly1305 crate" wording refers to this implementation;
      there is no separately published `xchacha20poly1305` crate on
      crates.io. (`eaa66fd`)
- [x] 1.4 Manifest schema (§4.4) with serde (de)serialization,
      restricted to v1's `key_type` values (rejecting `ecdsa-p384` /
      `rsa-2048` at parse time by construction, not just convention).
      `vaultcore/src/manifest.rs`. (`eaa66fd`)
- [x] 1.5 Key generation for Ed25519 and ECDSA P-256.
      `vaultcore/src/keys.rs`. Draws every byte of key material directly
      from the OS CSPRNG (`getrandom`), never through an intermediate
      userspace stream-cipher DRBG, per spec §4.3's "OS CSPRNG only ...
      never a userspace PRNG." (`eaa66fd`)
- [x] 1.6 In-memory retention cache with `zeroize` and configurable
      timer (§4.5). `vaultcore/src/retention.rs`. Background sweep
      thread proactively wipes expired entries rather than relying on
      next-access; zero-retention entries are single-use. **Known gap:**
      `mlock`/`VirtualLock`/`mlockall`-equivalent calls are not
      implemented — this needs real per-platform unsafe FFI against a
      non-relocating allocation and is deliberately left as a TODO
      rather than faked; see the module doc comment. (`eaa66fd`)
- [x] 1.7 CTAP2 message handling (`authenticatorMakeCredential`,
      `authenticatorGetAssertion`) as a platform-agnostic library
      function. `vaultcore/src/ctap2.rs`, built directly on the
      `ctap-types` crate's own Request/Response types and its `Error`
      enum as the CTAP2 status-code vocabulary — per spec §2's
      directive, no parallel parsing/error model was invented.
      `handle_make_credential` covers excludeList checking (against
      every locally-known credential for the rp_id, not just a caller-
      chosen subset), algorithm selection from the caller's preference
      order (`ctap-types` itself filters this to exactly this project's
      v1 pair, ES256/EdDSA), and "none"-only attestation.
      `handle_get_assertion` covers allowList / discoverable-credential
      matching, user-verification gating, and `sign_count` increment.
      Both take a minimal `Ctap2Backend` trait (credential lookup +
      passphrase-gated signing) and persist nothing themselves, same
      separation of protocol logic from persistence as `merge.rs` and
      `protocol.rs`. Needed two additions to `keys.rs` first: `sign()`
      for both key types, and switching P-256 public key storage from
      SEC1-compressed to uncompressed `x||y` so COSE key encoding needs
      no decompression step. Out of scope, matching spec §6.6 exactly:
      `hmac-secret`, any attestation format but "none", every other
      CTAP2 command, and the transport (USB HID/NFC/BLE framing, or an
      OS credential-provider integration) — each platform phase wires
      up its own transport onto these two functions. (`d86c412`)
- [x] 1.8 Custom protocol JSON-RPC handling (§7) as a platform-agnostic
      library function. `vaultcore/src/protocol.rs`: parses/dispatches
      `vaultsigner.sign` and `vaultsigner.list_public_keys`, backed by a
      `SigningBackend` trait a real vault implementation plugs into.
      Transport (Unix socket/named pipe/loopback TCP, or the iOS App
      Intents adaptation) is explicitly **not** built here — spec §12
      assigns that to each platform phase (items 2.8, 3.6, 4.6, 5.4,
      6.5), not Phase 1. Rate limiting reuses `ThrottleTracker` (1.9)
      directly: a throttled key never reaches the backend at all.
      (`68b4b53`)
- [x] 1.9 Passphrase-attempt throttling (§5.5) implemented once in
      vaultcore and invoked by every entry point.
      `vaultcore/src/throttle.rs`. Tracks failures per `SecretId` (per
      key, or per master-key compartment); only a successful unlock or
      elapsed backoff clears a lockout — there is intentionally no
      caller-facing reset. (`eaa66fd`)
- [x] 1.10 Three-way merge logic (§5.3) implemented and unit-tested
      against synthetic multi-compartment vaults.
      `vaultcore/src/merge.rs`, on top of two new supporting codecs:
      `vaultcore/src/keyblob.rs` (the `.kblob` format — AEAD-seals a
      private key under a passphrase-derived key, with a fingerprint
      binding it to `key_id`/`key_type`/`label` so a manifest/blob
      desync fails closed) and `vaultcore/src/master_blob.rs`
      (encrypt/decrypt a compartment's manifest + key_index, kept in
      sync by construction). `merge.rs` implements all three options
      (re-encrypt & discard incoming, keep-both side-by-side, replace
      local with incoming) as pure manifest/compartment logic — no
      passphrase or ciphertext handling, so it has no platform-specific
      surface for a UI to accidentally fork. Duplicate detection (by
      `key_id`, or FIDO2 `rp_id`+`credential_id_b64`) defaults to
      keep-both-rename-incoming, covers collisions against *any* local
      compartment (not just the import target), and option 3 hard-fails
      without the spec's exact confirmation phrase. (`a54643e`)
- [x] 1.11 (Swift and Kotlin verified; C# not attempted) UniFFI
      bindings generated and verified callable, plus
      the `Vault` facade (spec's own gap: vaultcore was a set of
      composable primitives with nothing tying them into one API a
      platform app actually calls) they're generated from.
      `vaultcore/src/vault.rs`: create/open a vault, unlock/lock
      compartments (spec §4.1's multi-compartment model), the §5.1 core
      key operations (list/create/discard/change-passphrase/reveal), a
      retention-cache-backed signing primitive, the custom-protocol
      (§7) and CTAP2 (§6.6) request handlers wired to real vault state
      (not the test-only fakes in `protocol.rs`/`ctap2.rs`), and the
      §5.3 three-way import merge against an already-decrypted incoming
      manifest. At the time this item was completed, the §5.2
      export-packet transfer-encryption layer (`.vltpack`'s three
      wrapping options) was deliberately left out of scope — no packet
      format existed yet, so a facade method on top of it would have been
      unverified guesswork; `merge_*` was built to take the incoming
      manifest/key-blob bytes already in hand specifically so a future
      `packet` module could slot in ahead of it unchanged. That module
      now exists: see `vaultcore/src/packet.rs` and
      `Vault::export_packet`/`export_single_key`/`import_packet` below,
      under Phase 2's item 2.3 entry (where the macOS UI consuming it
      lives) rather than renumbering this already-closed item. Added two
      small supporting fixes discovered while
      building the facade: `manifest.rs`'s `KeyEntry` gained a
      `public_key_hex` field (spec §4.4's JSON tree doesn't list one,
      but §7's `list_public_keys` cannot return a key's public key
      without it, and a public key is non-secret metadata under §4.1's
      "vault-unlock reveals metadata only" invariant — defaulted empty
      for backward compatibility); `master_blob.rs` gained
      `encrypt_with_key`/`decrypt_with_key` (take an already-derived
      Argon2id key instead of a passphrase) so an unlocked compartment
      can cache its *derived master key* for the session and persist a
      mutation immediately (spec §4.6) without re-prompting for the
      master password on every single key create/discard/rename, while
      never caching the raw passphrase itself.

      Passphrase prompting is inherently native UI (a window, screen-
      capture-blocked per spec §5.0) and cannot live in this crate;
      rather than reimplementing it once per platform, a
      `PassphrasePrompter` UniFFI foreign-implemented trait lets a
      platform supply just the native dialog, invoked only when a key
      isn't already warm in the retention cache — every byte of crypto,
      parsing, and protocol dispatch still stays in this crate either
      way. 12 new unit tests in `vault.rs` (98 total for the crate)
      cover create/reopen, wrong-passphrase throttling, key lifecycle,
      protocol signing (including the prompt-once-then-cache path and
      wrong-passphrase-returns-`passphrase_incorrect`), CTAP2
      make-credential + get-assertion, and merge option 1.

      UniFFI wiring: `uniffi = { version = "0.29", optional = true,
      features = ["cli"] }`, gated behind a `uniffi` Cargo feature (off
      by default, so `vaultcore` still builds/tests/lints exactly as
      before with no new dependency for anyone not consuming the
      bindings yet) — `cargo build -p vaultcore --features uniffi` and
      `cargo clippy -p vaultcore --all-targets --features uniffi` are
      both clean. `src/bin/uniffi_bindgen.rs` is the bindgen binary
      (`cargo run --release --features uniffi --bin uniffi-bindgen --
      generate --library <path-to-libvaultcore.dylib> --language swift
      --out-dir <dir>`). **Swift is verified, not just generated:**
      `vaultcore/uniffi-verify/swift/main.swift` is a real standalone
      Swift program (see the exact build/run commands in its header
      comment) compiled with `swiftc` against the generated
      `vaultcore.swift` and linked against the real release `cdylib` on
      this machine (macOS 15.7.4, Xcode 16.4, Swift 6.1.2) — it creates
      a vault, creates a key, signs directly, signs again through
      `handle_protocol_request` with a real Swift class implementing
      `PassphrasePrompter` (proving the foreign-trait callback actually
      crosses the FFI boundary both ways), and runs a §5.3 option-1
      import merge, all successfully. **Kotlin is verified the same
      way**: `vaultcore/uniffi-verify/kotlin/Main.kt` (see its header
      comment for the exact commands) is a real Kotlin program, compiled
      with `kotlinc` against the generated bindings plus JNA (fetched
      directly from Maven Central — `net.java.dev.jna:jna:5.14.0`, the
      generated Kotlin bindings call into it directly) and run with
      `java -Djna.library.path=...` against the same release `cdylib` —
      it passes the identical five-step scenario as the Swift harness
      (`kotlinc 2.4.20`, JRE 26.0.2.1). Getting `kotlinc` itself working
      on this host took two rounds: Homebrew's `kotlinc` install first
      failed because the Xcode Command Line Tools were older than its
      `json-c` dependency needed (fixed by the user updating CLT to
      16.4), then Homebrew refused to install *anything* because of an
      unrelated tap-trust gate on two pre-existing taps on this machine
      (`dart-lang/dart`, `leoafarias/fvm`, from prior Flutter/Dart work)
      — resolved by the user running `brew trust` themselves, since
      changing Homebrew's tap-trust policy is a security-relevant
      decision this session declined to make unilaterally. **C# was
      not attempted**: the `uniffi` crate's own `uniffi-bindgen`
      only supports `kotlin`/`swift`/`python`/`ruby` as of the pinned
      0.29.5; C# needs the separate, third-party `uniffi-bindgen-cs`
      crate, whose compatibility with this exact `uniffi` version has
      not been checked — do this as its own follow-up rather than
      guessing at version compatibility.
- [x] 1.12 Full unit test suite green, including crash-safety
      (mid-write kill) tests. `cargo test --workspace` (108 tests, after
      `vault.rs` (item 1.11) and `packet.rs` (item 2.3) were added) and
      `cargo test --workspace -- --ignored` (the real-benchmark KDF test
      and the crash-safety chaos test, both slow/deliberately excluded
      from the default run) all pass, clean under `cargo clippy
      --workspace --all-targets`, as of `d86c412`. Fuzz testing of the
      container parser and JSON-RPC parser (spec §10) is also done:
      `vaultcore/fuzz/` (a `cargo-fuzz` harness, excluded from the main
      workspace per the standard cargo-fuzz convention) has two targets,
      `container-parser` and `jsonrpc-parser`, each run for 200k
      iterations under AddressSanitizer with zero crashes as of
      `68b4b53`. Run them yourself with (requires a nightly toolchain —
      `rustup toolchain install nightly`, then `cargo install
      cargo-fuzz` once):
      ```
      cd vaultcore && cargo +nightly fuzz run container-parser
      cd vaultcore && cargo +nightly fuzz run jsonrpc-parser
      ```
      Fuzzing the container parser directly caught a real bug, now
      fixed: a zip entry's declared uncompressed size is
      attacker/corruption-controlled and was used to pre-reserve a
      `Vec`'s capacity with no bound, so a malformed archive could force
      an arbitrarily large allocation before any real bytes were read
      (`container.rs`'s `MAX_PREALLOCATED_ENTRY_SIZE` cap fixes this).
      What's *not* done: this was a bounded, one-off fuzzing session,
      not continuous fuzzing — there's no CI job re-running these
      targets or a curated seed corpus checked in (corpus/artifacts are
      gitignored, per cargo-fuzz's own default), so regressions between
      now and whenever this is next run wouldn't be caught
      automatically. Worth revisiting once CI exists (Phase 7-ish).

## Phase 2 — macOS (first fully shipped platform)

In progress. See spec §12 for the full item list (2.1–2.10) and
`apps/macos/README.md` for the detailed per-item status this section
summarizes — that file is the one to keep current as this phase
continues, since it also covers macOS-specific setup that doesn't belong
here.

- [x] 2.1 SwiftUI management UI. **Done, interactively verified for the
      core flow.** Real `Vault`-backed screens (create/open vault,
      multi-compartment unlock, key list, create key, key detail with
      change-passphrase/reveal-raw-key/discard) in
      `apps/macos/VaultSigner/`. Screenshots of this app are expected to
      come back blank (spec §5.0's own screen-capture blocking, see
      2.2 — not a permissions gap); verified instead via the
      Accessibility API (`osascript`/System Events, a different OS
      subsystem unaffected by `sharingType`), driving the real running
      app through create-vault (real `NSSavePanel`, real ~1s Argon2id
      derivation with the busy-indicator overlay visible mid-flow) →
      empty key list → create-key → populated key list → key detail →
      reveal-raw-key (real decrypt, correct 64-hex-char private key
      returned) → lock → unlock, confirming every screen's structure and
      content against source. See the macOS README's new "Verifying the
      UI without screenshots" section for the two real gotchas found
      doing this (toolbar accessibility order differs from source
      order; `SecureField` needs `set focused` + `keystroke`, not
      `set value`). Not yet driven this way: change-passphrase,
      discard-key, and the export/import/settings screens (2.3-2.5).
      **Gap found while writing `docs/user-guide.md` (spec §14):**
      spec §4.5 specifies the retention timer as user-configurable
      (0-300s); `vaultcore`'s `Vault::unlock_key` already takes a
      `retention_secs` parameter, but no Settings control exists yet to
      let a user actually choose it — every call site hardcodes a
      default. Not fixed yet.
- [x] 2.2 Screen-capture blocking. `CaptureProtected.swift` sets
      `NSWindow.sharingType = .none` per spec §5.0, applied to the main
      window and every sheet. This session's own screenshot attempts
      against this exact app came back blank throughout, consistent
      with it working — but that was incidental, not a deliberate
      isolated test; worth doing once explicitly.
- [x] 2.3 Export flows. **Done, interactively verified.**
      `vaultcore/src/packet.rs` implements `.vltkey`/`.vltpack` (both
      "the same archive format as `.vlt`") and all three §5.2.2
      transfer-encryption choices, exposed via
      `Vault::export_packet`/`export_single_key` — 108 vaultcore tests,
      clippy-clean. On top of it, `ExportPacketView.swift` was driven
      through the real running app via the Accessibility API (see the
      macOS README): selected a key, chose "as-is," saved via a real
      `NSSavePanel`, and the resulting file was confirmed on disk as a
      real zip archive (`packet.json` + the key's `.kblob`) — not just a
      successful button press.
- [x] 2.4 Import flow. **Done, interactively verified.**
      `Vault::import_packet` unwraps the transfer-encryption layer (if
      any) and returns a ready-to-merge set; `vaultcore::merge` and
      `Vault::merge_*` take it from there. `ImportPacketView.swift` and
      `MasterKeyDualityView.swift` (spec §5.3's unskippable three-card
      duality screen) implement this. Verified end-to-end via the real
      app: created a second, entirely separate vault, imported the
      packet from 2.3 into it through the real file picker, confirmed
      the key appeared with correct label/resource/public key, and
      revealed its raw private key using its *original* passphrase —
      full cross-vault round trip through the actual UI, not just the
      underlying facade. The no-embedded-master-key path (skips straight
      to a merge) was exercised; the duality screen itself (embedded
      master key present) was not yet driven this way, only via its
      underlying `Vault::merge_*` calls directly (`vault.rs`'s own tests
      plus the Swift harness).
      **Two real findings from doing this:**
      (1) once a vault is opened there is no way back to `WelcomeView`
      to open or create a *different* vault without quitting and
      relaunching the app — a genuine missing feature, not by design;
      (2) the toolbar's Import/Export `Menu` is exposed to the
      Accessibility API as "Outbox" (inferred from its SF Symbol
      `tray.and.arrow.up`) rather than "Import/Export" — harmless for
      sighted mouse use but a real VoiceOver-facing naming gap, fixable
      with an explicit `.accessibilityLabel("Import/Export")`. Neither
      fixed yet.
- [x] 2.5 Backup. **Done at the `vaultcore` level** (both flows are just
      `Vault::export_packet` called a specific way — verified by its own
      test, `backup_master_key_only_shortcut_has_no_keys` — no new
      vaultcore work needed). The macOS UI
      (`BackupMasterKeyOnlyView.swift` + the two buttons in
      `SettingsView`) reuses the same `ExportPacketView` machinery just
      verified under 2.3, but the two backup-specific entry points
      themselves have not yet been individually clicked through.
- [x] 2.6 `launchd` background service. **Done and verified, one caveat
      disclosed.** `VaultSignerAgent` (`apps/macos/VaultSignerAgent/`),
      embedded inside `VaultSigner.app`, is a real process owning a
      `Vault` + its retention cache/throttle state, serving the
      custom-protocol socket (verified — see 2.8), registered as a real
      `launchd` agent via `SMAppService.agent(plistName:)` with
      `RunAtLoad`/`KeepAlive` — confirmed with `launchctl print` (a real
      job managed by `com.apple.xpc.ServiceManagement`) and
      `launchctl kickstart` (killed it, watched launchd revive it). Both
      spec §8 toggles are real and wired into `VaultSignerAgent` actually
      consuming them: "start at login" (`LoginItemManager`) and
      "auto-unlock on startup" (`AutoUnlockStore`, Keychain-backed, off by
      default, gated behind a confirmation screen that verifies the
      passphrase against the vault before ever writing it to the
      Keychain) — a freshly-launched agent listed a real key over the
      socket with zero unlock calls ever sent to it, confirming auto-
      unlock end-to-end. `AlertPassphrasePrompter` (the real `NSAlert`
      passphrase prompt) was separately verified interactively: a
      `vaultsigner.sign` call for a never-unlocked key showed the dialog,
      blocked until answered, and returned a signature that verified
      against the key's real public key. **Disclosed caveat, observed
      while verifying:** the first cross-app Keychain read triggers a
      real macOS `SecurityAgent` access-confirmation dialog (no shared
      Team ID between the two ad-hoc-signed binaries yet), and denying it
      fails silently (agent just starts locked) rather than surfacing an
      error — full detail in the macOS README, same underlying
      constraint as item 2.7's signing requirement. The known UI-vs-agent
      architecture gap (management UI should route mutations through the
      agent, not hold its own `Vault`) is also in the macOS README.
- [ ] 2.7 `ASCredentialProviderExtension`. **Target scaffolded, blocked
      on signing — a real, specific finding, not a guess.**
      `apps/macos/VaultSignerCredentialProvider/` is a real
      `app-extension` target (`ASCredentialProviderExtensionCapabilities`
      → `ProvidesPasskeys: true`, the
      `com.apple.developer.authentication-services.autofill-credential-provider`
      entitlement, embedded in `VaultSigner.app`'s `PlugIns/`) with a
      minimal `CredentialProviderViewController` stub (the real CTAP2
      wiring via `vaultcore::ctap2`/`Vault` is not implemented yet — this
      only proves the target itself builds and embeds). It compiles, but
      fails at the code-signing step: `"...has entitlements that require
      signing with a development certificate."` No Apple ID at all is
      signed into Xcode on this machine, so this doesn't yet distinguish
      "needs any development certificate (even a free Personal Team)"
      from "needs a paid Developer Program team specifically" — that
      distinction needs someone to actually add an Apple ID in Xcode →
      Settings → Accounts and retry, which is account/credential entry
      this session doesn't perform itself. Live Safari/Chrome relying-
      party verification is a separate, further blocker regardless
      (needs a properly signed, enabled extension first).
      **Also found and fixed:** embedding it in `VaultSigner.app` via
      xcodegen's `embed: true` dependency initially broke that app's own
      build entirely — an embedded dependency's signing failure fails
      the whole build, not just the extension's scheme. Decoupled: the
      extension target exists and builds independently, but is not
      currently embedded in `VaultSigner.app` (see the comment in
      `project.yml`), so the rest of the app stays buildable while this
      is unresolved. Re-embed once signing works.
- [x] 2.8 Custom protocol verified against a minimal test client.
      `apps/macos/uniffi-verify/agent_test_client.py` runs fully
      non-interactively (~0.7s) against a real running `VaultSignerAgent`
      over its Unix socket and verifies: `list_public_keys` leaks nothing
      beyond the spec-allowed fields; an unknown key returns
      `key_not_found`; and a real `vaultsigner.sign` call (after unlocking
      via the agent's `internal.unlock_key` bootstrap method, deliberately
      avoiding the interactive passphrase-prompt path — see 2.6) returns a
      signature that independently verifies via PyNaCl against the key's
      actual Ed25519 public key. Caller identity for the confirmation
      text is resolved via `LOCAL_PEERPID`/`proc_pidpath` (OS-level peer
      credentials, per spec §7 — never the self-reported JSON payload).
- [x] 2.9 i18n resource-file scaffolding, at least one locale populated.
      **Done for the scaffolding itself; most of the app's strings are
      not yet migrated (see `i18n/README.md`).** `i18n/source/en.json`
      and `i18n/source/ar.json` (Arabic — chosen specifically because
      spec §9 requires RTL verification "specifically on the
      import/export decision screens") are the ICU-MessageFormat-shaped
      sources of truth; `i18n/generate-apple-strings.py` generates real
      `.lproj/Localizable.strings` from them (wired into
      `apps/macos/project.yml`, `CFBundleLocalizations: [en, ar]`).
      Three screens actually migrated — `WelcomeView`,
      `ImportPacketView`, `MasterKeyDualityView` (the import/export
      decision screens spec §9 calls out) — verified via a headless
      `--test-i18n <locale> <key>` hook that resolves a key directly
      against a named `.lproj` bundle: confirmed both locales resolve
      real translated text (not the raw key) and a missing key falls
      back cleanly instead of crashing. `i18n/lint-hardcoded-strings.py`
      is spec §9's "CI lint that fails the build on hardcoded UI literal
      strings" — runnable locally now (`--strict` is clean for the 3
      migrated files; `--report` lists the 88 remaining hardcoded
      literals across the rest of the app), not yet wired to an actual
      CI service since none exists in this repo. Both app targets build
      clean with the localization changes.
- [x] 2.10 Full Phase 10 test/fuzz suite pass, except interop. Spec §10's
      unit tests (KDF/AEAD/merge/sign_count), crash-safety test, fuzz
      tests (container parser, JSON-RPC parser), and throttling test are
      all `vaultcore`-level work already done in Phase 1 (item 1.12) and
      still passing (108 `vaultcore` tests as of this commit) — since
      every platform links the same `vaultcore` binary, none of that
      needs redoing per-platform. What item 2.10 adds on top —
      "including self-import/export exercising the shared merge logic" —
      is now done and verified: driving `ExportPacketView`/
      `ImportPacketView` through a real self-export-then-reimport
      between two separate real vaults in the running app (see item 2.3's
      entry for the exact steps), confirmed via the Accessibility API.
      §10's interop tests (2-3 real relying parties per platform in an
      actual browser) remain blocked on item 2.7's Apple Developer
      signing, same as 2.7 itself.
- [x] 2.11 Known vaults (spec §5.6, added this session — see the spec
      amendment note below). `Shared/KnownVaultsStore.swift` persists a
      `path` + `lastAccessedAt` list to
      `~/Library/Application Support/VaultSigner/known_vaults.json`
      (plain paths, not security-scoped bookmarks, since this app
      doesn't request App Sandbox yet — see the file's own doc comment
      for what changes if that's adopted later). `WelcomeView` now shows
      this list (most-recently-accessed first) with one-click reopen, a
      "Forget" action per entry, and an unavailable-file indicator
      (missing/moved files show a warning icon rather than silently
      vanishing, per spec). `ManageVaultsView` is the dedicated
      management screen (spec's explicit ask), reachable from both
      `WelcomeView` and a new "Vaults" section in `SettingsView`, with
      "Add Existing Vault…" (add without opening) and per-entry forget.
      `AppState.closeVault()` returns to the entry screen without
      quitting the app. All of this was interactively verified via the
      Accessibility API: created a vault (confirmed recorded), closed it
      from Settings (confirmed return to `WelcomeView` with the entry
      now showing), reopened it with one click (confirmed no file picker
      needed), forgot it (confirmed the entry disappeared but the actual
      `.vlt` file on disk was untouched), and added it back via "Add
      Existing Vault…" without opening it (confirmed it appeared in both
      `ManageVaultsView` and `WelcomeView`'s list, reactively, from the
      same underlying state). New i18n keys added to both `en.json` and
      `ar.json` for every new string, `WelcomeView` kept in
      `lint-hardcoded-strings.py`'s strict set, `ManageVaultsView` added
      to it (both fully migrated, not just partially).
      **Spec amendment, this session:** added §5.6 ("Known vaults")
      describing this as a Section 5.1-level core-UI requirement (not
      optional polish) for every platform, plus execution-plan item 2.11
      above — raised directly by the user after finding VaultSigner
      asked for the vault file location on every single launch.

## Phase 3 — Windows

Not started.

## Phase 4 — Android

Not started.

## Phase 5 — iOS/iPadOS

Not started.

## Phase 6 — Linux

Not started.

## Phase 7 — Cross-platform security hardening & review

Not started.

## Phase 8 — i18n completion & release polish

Not started, except a first draft of item 8.5's deliverable.

- [ ] 8.5 User-facing documentation (spec §14, added this session — see
      the spec amendment note below). **First draft written**,
      `docs/user-guide.md`: covers first vault/first key, day-to-day
      use, reveal-raw-key's danger-zone framing, export/import/backup
      (including the three §5.2.2 encryption choices and the §5.3
      duality screen) in plain consequence-first language, the two
      autostart/auto-unlock settings, forgotten-password behavior, and
      an iOS-specific note (§7.1). Written against the real macOS UI
      built and interactively verified this session (2.1/2.3-2.5), so
      it describes actual behavior, not aspirational behavior — except
      where it describes spec-mandated behavior not yet built (flagged
      inline above, e.g. the 2.1 note on retention-timer
      configurability). Not yet reconciled against Windows/Android/iOS/
      Linux, since none of those phases have started; per spec §14,
      update it alongside each platform phase rather than only at the
      end.

**Spec amendment, this session:** added spec §14 ("User-facing
documentation") describing this deliverable's audience, tone, and scope
at a bird's-eye level — requested directly by the user after this
session's macOS UI-testing made clear that a technically-correct app is
not the same thing as a usable one for someone with no cryptography/FIDO
background. Item 8.5 above is the corresponding execution-plan entry.

---

## Open questions carried from spec §13 (not resolved here — product decisions)

None of these block the current Phase 1 work; listed so they aren't
silently forgotten before the phase that needs them:

1. Timeline for a future release adding ECDSA P-384 / RSA-2048 support.
2. Virtual-CTAP2-HID vs. browser-extension approach for Linux (§6.5) —
   spec says decide during Phase 6, not earlier.
3. Minimum supported Linux distribution/version floor.
4. Localization launch-language list.
5. Whether Windows auto-unlock requires CNG/TPM-backed protection or
   Windows Hello gating as a hard requirement, vs. shipping plain DPAPI
   plus a stronger in-app disclosure for v1.
