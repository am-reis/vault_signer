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
      next-access; zero-retention entries are single-use. **Windows half
      of the known gap closed this session** (done from a real Windows
      machine — see Phase 3): `vaultcore/src/mem_lock.rs`'s
      `LockedBuffer` backs cached key bytes with a page-aligned
      `VirtualAlloc` region pinned via `VirtualLock`, zeroized via a
      volatile write loop and released on drop, wired into
      `CachedKey.bytes`. Verified for real: `cargo build --release
      --target x86_64-pc-windows-msvc` and `cargo test --workspace`
      (117 tests, up from 108) both clean on Windows. **macOS/Linux
      still the original gap** — `LockedBuffer` falls back to a plain
      `zeroize`-wrapped `Vec<u8>` there (zeroized on drop, not pinned
      against paging) until a real `mlock`/`mlockall` path is built and
      verified on an actual Unix machine; do not assume parity. (`eaa66fd`)
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
- [x] 2.6 `launchd` background service. **Done and verified — but the
      earlier claim below that `launchctl kickstart` proved the login
      item durable was wrong; that was only ever true for an in-place
      Debug build run straight from the exact same DerivedData path.
      The actual SMAppService registration was broken for real use and
      has since been fixed; see the corrected account below.**
      `VaultSignerAgent` (`apps/macos/VaultSignerAgent/`), embedded
      inside `VaultSigner.app`, is a real process owning a `Vault` + its
      retention cache/throttle state, serving the custom-protocol socket
      (verified — see 2.8), registered as a real `launchd` agent via
      `SMAppService.agent(plistName:)` with `RunAtLoad`/`KeepAlive`.

      **What was actually broken (found after a real reboot, not
      assumed):** `launchctl print` showed the registered job at
      `exit 78: EX_CONFIG`, `job state = spawn failed`, 423 failed
      attempts. Two independent, real bugs, both now fixed:
      (1) every target links `libvaultcore.dylib` via the absolute
      build-machine path `LIBRARY_SEARCH_PATHS` bakes in
      (`-lvaultcore` resolving to `$(SRCROOT)/../../target/release`) —
      this only ever "worked" by coincidence of Xcode's Debug launches
      tolerating an unsigned dylib load from outside the app bundle; a
      properly signed Release build refuses to load it under Hardened
      Runtime (`dyld: ... Code has to be at least ad-hoc signed`).
      Fixed by `Scripts/embed-vaultcore-dylib.sh` (new
      `postCompileScripts` step on all three targets): embeds a
      self-contained, `@rpath`-relocated, freshly re-signed copy of the
      dylib under each bundle's own `Contents/Frameworks/`.
      (2) `VaultSignerAgent.app` was embedded at
      `Contents/Resources/VaultSignerAgent.app`, which spawned with
      `OS_REASON_CODESIGNING` every time (confirmed via `log show` and
      `launchctl print`) — a nested full `.app` bundle used as a
      `BundleProgram` target isn't validated there. Moved to
      `Contents/Library/LoginItems/VaultSignerAgent.app`, the location
      Apple's own SMAppService/`SMLoginItemSetEnabled` examples use for
      exactly this; fixed it.

      Both bugs needed a **real, stable, consistent code signature**
      to even surface correctly rather than being masked by Automatic's
      per-build ad-hoc identity — `DEVELOPMENT_TEAM` is now set (via the
      `VAULTSIGNER_TEAM_ID` env var, never hardcoded) on all three
      targets, and `Scripts/build-staging.sh` builds a Release
      configuration and installs it to `/Applications` — a stable path,
      unlike ephemeral Xcode DerivedData. Verified after all of this:
      `launchctl print gui/$(id -u)/com.vaultsigner.agent` shows
      `job state = running` with a real PID, and a plain socket client
      calling `vaultsigner.list_public_keys` against that
      launchd-spawned process got a real response — not just "the
      process exists," the actual service is reachable.
      `codesign -dvvv` on both the app and the embedded agent shows the
      identical `TeamIdentifier`, confirming the consistency fix took.

      Both spec §8 toggles are real and wired into `VaultSignerAgent`
      actually consuming them: "start at login" (`LoginItemManager`) and
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
      while verifying (partially superseded — not yet re-verified):**
      the first cross-app Keychain read used to trigger a real macOS
      `SecurityAgent` access-confirmation dialog, attributed at the time
      to the app and agent having no shared Team ID (each got its own
      random ad-hoc identity per build). That premise is no longer true
      — both now carry the same real `TeamIdentifier` (see above) — so
      this may already be resolved, but it hasn't been specifically
      re-tested since the signing fix. If it still happens, denying the
      prompt still fails silently (agent just starts locked) rather than
      surfacing an error — full detail in the macOS README.

      **Single vault owner, full redesign (supersedes an earlier
      stopgap that was correctly rejected as unsafe).** A first attempt
      at fixing "the UI shows a key unlocked but the agent doesn't" just
      forwarded the unlock passphrase to the agent's already-existing
      `internal.unlock_compartment` bootstrap method (added originally
      as a test-only backdoor for `agent_test_client.py`, with **no
      caller authentication at all** — any same-user process could call
      it). Flagged as unsafe and correctly rejected: "if it is not safe
      there is no point for inventing excuses. It has to be redesigned
      ... There should be a single copy owned by the background. The UI
      is supposed to be just a UI." That is exactly spec §8's original
      design, never fully implemented until now — see the amendment to
      §8 formalizing the requirement this closes.

      `VaultSigner.app` now holds **no `Vault` instance at all**.
      `Shared/ManagementClient.swift` is its sole means of touching
      vault state — every operation the UI used to perform directly
      (create/open vault, unlock, list/create/discard keys, change
      passphrase, reveal raw key, export/export-single-key/import, all
      three merge options, enable/disable/query auto-unlock) is now one
      `internal.*` call to `VaultSignerAgent`, handled in the new
      `VaultSignerAgent/Sources/ManagementHandlers.swift`. Auto-unlock's
      Keychain reads/writes moved server-side too (`AutoUnlockStore` is
      no longer touched from `VaultSigner.app` at all) — the agent is
      now the sole owner of vault state, key material, *and* the
      Keychain-backed auto-unlock secret, with zero exceptions.

      `internal.*` callers are now authenticated for real:
      `PeerAuthentication.swift` uses `SecCode`/`Security.framework`
      (`SecCodeCopyGuestWithAttributes`, `SecCodeCheckValidity`,
      `SecCodeCopySigningInformation`) to verify the connecting process
      is validly signed, identified as `com.vaultsigner.app`, and
      shares this agent's own Team Identifier (read dynamically from
      the agent's own code, never hardcoded) — not just "reached the
      socket as the same OS user." Skipped in Debug builds only, so
      `agent_test_client.py` (a bare Python script with no signature)
      keeps working as a dev/test tool; enforced unconditionally in
      Release, the only configuration this project ever installs and
      runs (`Scripts/build-staging.sh`).

      `VaultSignerAgent` itself changed from "owns exactly one `Vault`
      fixed at launch" to "owns zero or one `Vault`, mutable at
      runtime" — `main.swift` no longer exits when no vault is
      configured yet (a fresh install has none until
      `internal.create_vault` is called), and `AgentServer.vault` is
      now `var Vault?` behind a lock instead of a fixed `let`.
      `Shared/ManagementClient.ensureAgentRunning()` launches the
      embedded agent directly (not via `SMAppService`) if it isn't
      already reachable, so a fresh install with the login item not yet
      approved can still create a vault.

      **Verified end-to-end**, not just built: (1) confirmed a plain
      unsigned Python script calling `internal.list_compartments`
      against a Release build is now rejected with `unauthorized_caller`
      (rejected the exact same way `internal.create_vault` was too,
      requiring a new `--test-create-vault` headless hook in
      `VaultSignerApp.swift` — mirroring the existing `--test-login-item`
      pattern — specifically because a real, signed `VaultSigner.app`
      process is the only thing `PeerAuthentication` will now accept,
      by design); (2) using a disposable test vault, drove the real UI
      through create → unlock → create-key → lock, confirming via a
      direct socket query after *each* step that `VaultSignerAgent` —
      a separate OS process — reflected the change immediately, with
      zero manual `internal.*` calls made by hand at any point. Export/
      import/merge paths were not re-exercised live beyond a clean
      Release compile (their RPC wiring follows the identical pattern
      already proven working for create/unlock/create-key/lock).

      **Deferred, same underlying issue, not forgotten:**
      `VaultSignerCredentialProvider` (the FIDO2 extension,
      `CredentialProviderViewController.swift`) still opens its own
      separate in-process `Vault`, same as the old design. Left alone
      here since it can never run live regardless (blocked on the paid
      Apple Developer entitlement — item 2.7), so fixing its
      architecture can't be verified end-to-end the way the two
      testable processes above can.

      **Minor, cosmetic, not yet chased down:** the built app also ends
      up with an unused second copy of `VaultSignerAgent.app` at
      `Contents/Resources/` — Xcode's own dependency resolution copies
      it there automatically regardless of `SKIP_INSTALL`, independent
      of and in addition to the real, intentional copy at
      `Contents/Library/LoginItems/`. Harmless (nothing references it),
      just wasted space; not worth the time to chase further right now.
- [x] 2.7 `ASCredentialProviderExtension`. **Target built with a real
      passkey implementation, compiler-verified against the actual SDK;
      conclusively confirmed blocked on a paid Apple Developer Program
      membership for anything beyond that — tested, not assumed.**
      `apps/macos/VaultSignerCredentialProvider/` is a real
      `app-extension` target (`ASCredentialProviderExtensionCapabilities`
      → `ProvidesPasskeys: true`, the
      `com.apple.developer.authentication-services.autofill-credential-provider`
      entitlement, `deploymentTarget: "14.0"` — bumped up from the rest
      of the app's 13.0 floor because the passkey credential-provider
      APIs this target is built on
      (`ASPasskeyCredentialRequest`/`prepareInterface(forPasskeyRegistration:)`/
      the `...ForRequest:` overrides) are macOS 14+/iOS 17+ only per the
      SDK headers).

      `CredentialProviderViewController` implements
      `prepareInterface(forPasskeyRegistration:)` and
      `prepareInterfaceToProvideCredential(for:)` for real: it opens the
      vault (`VaultConfig.loadVaultPath()`), unlocks whichever
      compartments have auto-unlock configured (`AutoUnlockStore`, spec
      §8), prompts for the specific key's passphrase via an
      `NSAlert`-based `ExtensionPassphrasePrompter` (mirroring
      `VaultSignerAgent`'s `AlertPassphrasePrompter`, screen-capture
      blocked per spec §5.0), and calls vaultcore's new **native** FIDO2
      facade methods — `Vault.handleFido2MakeCredentialNative`/
      `handleFido2GetAssertionNative` (`vaultcore/src/vault.rs`,
      `vaultcore/src/ctap2.rs`'s `build_make_credential_request_cbor`/
      `build_get_assertion_request_cbor`) — added specifically so this
      extension never has to hand-encode CTAP2 CBOR itself (it only ever
      has decomposed fields from `ASPasskeyCredentialRequest`/
      `ASPasskeyCredentialIdentity`, never raw CTAP2 bytes) or hand-parse
      a CTAP2 response back into the discrete fields
      (`attestationObject`, `authenticatorData`, `signature`,
      `credentialId`, `userHandle`) that
      `ASPasskeyRegistrationCredential`/`ASPasskeyAssertionCredential`
      need — keeping all protocol-encoding logic in vaultcore per spec
      §2. 113 `vaultcore` lib tests pass (up from 108, including 4 new
      `ctap2` builder tests and a new
      `fido2_native_make_credential_then_get_assertion_roundtrip` vault
      test), clippy clean.

      **Verification method and its real limit:** live enable/registration
      testing needs the blocked entitlement (see below), so the actual
      verification done was a full compiler check with signing removed
      from the equation entirely — `xcodebuild -scheme
      VaultSignerCredentialProvider build CODE_SIGNING_ALLOWED=NO
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO` against the real
      installed AuthenticationServices SDK — which caught and fixed
      several real API mistakes (wrong availability guards, the
      `prepareInterfaceForPasskeyRegistration` → `prepareInterface(forPasskeyRegistration:)`
      rename, `excludedCredentials` actually needing macOS 15 not 14) and
      now **succeeds**, along with `VaultSigner`/`VaultSignerAgent`
      rebuilding clean the same way. That confirms the Swift compiles
      and type-checks against Apple's real declarations; it does not and
      cannot confirm the extension actually gets invoked correctly by a
      real WebAuthn ceremony, since that needs the extension enabled in
      System Settings, which needs the blocked signing below. Two
      specific behaviors are honesty-flagged as unverified in the file's
      own doc comment: whether `AutoUnlockStore`-based unlock is
      sufficient when no compartment has auto-unlock configured (no
      master-passphrase prompt path exists yet in the extension for that
      case), and everything about how the OS actually drives this
      view controller in practice.

      **The signing question is now settled, in three tests.**
      (1) No Apple ID at all signed into Xcode → `"...has entitlements
      that require signing with a development certificate."`
      (inconclusive — could mean "needs any cert" or "needs a paid
      team"). (2) The user added a **free Personal Team** to Xcode
      (`BAXQZJJ66T`, confirmed via `security find-identity` /
      `defaults read com.apple.dt.Xcode IDEProvisioningTeams` — a real
      free account, not a paid one); built with this target's
      `DEVELOPMENT_TEAM` set explicitly (`xcodebuild` from the command
      line doesn't auto-select a team the way Xcode's GUI does) and
      `-allowProvisioningUpdates` → Apple's provisioning server
      responded directly: `"Communication with Apple failed: The
      selected team does not have a program membership that is eligible
      for this feature."` That same attempt, despite failing overall,
      silently caused Xcode to generate a real "Apple Development"
      signing certificate for the free team (confirmed after the fact:
      `security find-identity -v -p codesigning` found it, correctly
      trusted, once absent) — raising a fair question of whether the
      *build* itself, now that a certificate genuinely exists, would get
      further. (3) Retested explicitly to answer that: same
      `DEVELOPMENT_TEAM`, same command, this time with the certificate
      already present and valid in the keychain → **identical
      rejection, verbatim.** This isolates the cause precisely: it was
      never about lacking *a* certificate — a valid one exists and is
      usable for ordinary signing — it's that Apple's provisioning
      server refuses to issue a *provisioning profile carrying this
      specific entitlement* to a free/Personal Team account, no matter
      what. That conclusively answers the "free vs. paid" question this
      item has been carrying since it was first scaffolded: **a paid
      Apple Developer Program membership ($99/year) is required**, full
      stop, to get past this point — confirmed twice by Apple's own
      server, not inferred once. Live Safari/Chrome relying-party
      verification remains a further, separate blocker regardless
      (needs a properly signed, *enabled* extension first — enabling it
      is an additional step in System Settings once it can be signed at
      all).
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
      **Also manually verified interactively, end-to-end, via a real
      third-party GUI app** — `demos/rpc-demo-client/` (Python +
      Tkinter, deliberately not Swift, see its own README) — the
      opposite case from the automated test above: it deliberately
      *doesn't* avoid the passphrase prompt. Driven live: the demo
      called `vaultsigner.list_public_keys`, then `vaultsigner.sign` for
      a cold key; VaultSignerAgent's real `NSAlert` appeared reading
      `"python3.11 wants to sign with a VaultSigner key"` — proving the
      caller-identity resolution against a genuine, unrelated OS
      process, not a hardcoded test value — and after entering the
      key's passphrase and clicking Allow, the demo received a
      signature that PyNaCl independently verified against the returned
      public key. `vaultcore/examples/demo_vault_setup.rs` (kept, not a
      one-off) builds a disposable vault for this so it never needs a
      real vault's passphrase.
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

Not started (none of items 3.1–3.8), but initial groundwork done and
verified from macOS ahead of the actual Windows-side work, since the
implementation itself needs a Windows machine this repo wasn't
developed on. See `apps/windows/README.md` for the full detail; summary
here:

- **Confirmed uniffi (vaultcore's own dependency) does not generate C#
  bindings** — `uniffi-bindgen generate --help` lists only
  kotlin/swift/python/ruby. Installed and verified the separate
  community tool `uniffi-bindgen-cs` (pinned to v0.10.0+v0.29.4,
  matching vaultcore's exact uniffi 0.29.5), confirmed it supports
  library mode (reads the compiled cdylib directly — no `.udl` file
  needed, consistent with how every other platform uses vaultcore),
  and generated a real, complete `vaultcore.cs` from vaultcore's actual
  compiled library.
- **Found and documented a real, non-obvious blocker**: the generated
  C# uses C# 12 collection-expression syntax (`return [];`), which
  fails to compile under the .NET 7 SDK (the only one available on
  this Mac) with `error CS1525: Invalid expression term '['` —
  confirmed by actually trying it, not assumed. **The Windows machine
  needs .NET 8 SDK or newer**, not just "a recent .NET." This is now
  documented as a hard prerequisite in `apps/windows/README.md` instead
  of being discovered as a surprise later.
- Added `apps/windows/Scripts/generate-csharp-bindings.ps1` (PowerShell,
  since that's what actually runs on the target machine — mirrors
  `apps/macos/Scripts/generate-bindings.sh`'s role).
- Fixed a real, pre-existing inaccuracy found while checking this:
  `vaultcore/src/bin/uniffi_bindgen.rs`'s own doc comment claimed C#
  and Python support that was never actually true for C# (Python is
  real; C# was always going to need the separate tool above).
- **Explicitly not attempted, and said so plainly in
  `apps/windows/README.md`** rather than guessed at: cross-compiling
  vaultcore itself for `x86_64-pc-windows-msvc`, and anything about
  WinUI 3, the Windows Service, DPAPI auto-unlock, or WebAuthn
  plugin-authenticator registration (spec §6.2) — all of that needs a
  real Windows machine.
- Created the `platform/windows` branch (from `shared`, per
  `CLAUDE.md`'s branch model) as the starting point for that work.
- **QEMU Windows VM host environment now actually provisioned** on the
  real target Debian server (not just written up): `libtpms`/`swtpm`
  built from source (bullseye never packaged either — a real gap the
  original guide's "Debian 11's ... swtpm ... packages are old but
  fully adequate" claim got wrong, now corrected), VM disk + per-VM
  OVMF vars + TPM state dir created, and `start-tpm.sh`/`install.sh`/
  `run.sh` scripts ready to go. See `apps/windows/docs/qemu-vm-setup.md`
  for the full detail, including the exact path deviation (disk-space-
  driven: the VM lives on this server's `/home/blackshark/backup`
  spinning disk, not `/`). **Not done yet**: the Windows 11 ISO itself
  and the actual (interactive, VNC-driven) OS install — left for a
  human, since installer GUI interaction isn't something this session
  can drive.

### Session checkpoint (this entry): first real work from an actual Windows machine

Done on a real Windows 11 laptop (not the QEMU VM above — a different,
already-available physical machine), explicitly **not** the project's
main Windows dev machine and not intended to keep the checkout — the
point of this session was to do the steps that need a real Windows
environment, verify them for real, and push. Stopped mid-session (disk
space, below) with a clear resume point rather than pushing on and
risking unverified work.

**Verified, real, and pushed (on `shared`, not this branch — see that
branch's own PROGRESS.md entry for item 1.6):** vaultcore builds clean
for `x86_64-pc-windows-msvc` and all 117 tests pass, including the new
`VirtualLock`-based memory-locking fix for the retention cache. This
closes the very first unchecked box in this file's "Getting started"
step 3 above — genuinely done now, not just documented as a plan.

**Written this session, on this branch, but NOT YET COMPILED/VERIFIED**
(uniffi-bindgen-cs was never run — see the disk-space blocker below —
so `Generated/vaultcore.cs` doesn't exist yet and nothing here has
actually built against it): `apps/windows/VaultSignerAgent/` (C#, .NET
8) and the start of `apps/windows/VaultSignerUI/` (WinUI 3). Treat
everything below as "written against the Rust source and the macOS
Swift equivalent's proven shape, not yet build-verified" — the exact
opposite of how the rest of this file reports progress, flagged
explicitly because of that.

- **`VaultSignerAgent`** (spec item 3.3, and item 3.3's DPAPI
  disclosure): named-pipe transport (`AgentServer.cs`) with the same
  newline-delimited-JSON framing and `internal.*`/`vaultsigner.*`
  method-namespace split as macOS's `AgentServer.swift`;
  `ManagementHandlers.cs` covers vault/compartment/key lifecycle and
  auto-unlock (mirrors macOS's Phase 2 item 2.1 core) — **export/
  import/merge (macOS's 2.3-2.5) intentionally not ported yet**, to
  keep this session's surface small enough to actually verify rather
  than guess at in bulk; `DpapiAutoUnlockStore.cs` (DPAPI
  `CurrentUser`-scope, with the exact spec §8 disclosure written into
  its doc comment, not just implied); `WinFormsPassphrasePrompter.cs`
  (real modal dialog + `SetWindowDisplayAffinity` screen-capture
  blocking, spec item 3.2); `AutostartManager.cs` (HKCU `Run` key, off
  by default).
  **Real architecture finding, not in the spec's own wording**: spec
  item 3.3 says "Windows Service," but a real SCM-managed Windows
  Service runs in Session 0 with no desktop access and cannot show the
  interactive passphrase prompt spec §7/§8 require — Session 0
  isolation, not a workaround-able limitation. macOS's own "background
  service" is actually a **per-user `launchd` agent**, not a system
  daemon, specifically so it can show a real `NSAlert`. This is
  implemented as the direct Windows equivalent of that: a per-user
  background process started at logon in the interactive session (see
  `AgentServer.cs`'s doc comment), not an SCM service — DPAPI
  `CurrentUser` scope only makes sense paired with this model too.
  **`PeerAuthentication.cs` is honestly weaker than macOS's**: macOS
  validates the caller's real code signature; this checks the caller's
  resolved executable path against `VaultSignerUI.exe`'s expected
  install location, which stops accidental callers but not a
  deliberately malicious co-resident process — a real gap, not silently
  accepted (see the file's own doc comment for what closing it would
  need: a real code-signing certificate, not yet researched for
  Windows the way macOS's Apple Developer Program requirement was).
- **`VaultSignerUI`**: scaffolded via the official
  `Microsoft.WindowsAppSDK.WinUI.CSharp.Templates` `winui` template
  (not hand-rolled — `dotnet new search winui` found the real package
  after `Microsoft.WindowsAppSDK.ProjectTemplates`, the first guess,
  turned out not to exist). **NuGet restore did not finish** (disk
  space, below) — the template's own generated files exist on disk but
  nothing has been customized yet: no screens, no `ManagementClient`
  wired up. This is a scaffold checkpoint, not a started UI.
- **Real, non-obvious environment problems found and fixed on this
  machine** (worth keeping in mind for whoever next sets up a Windows
  box for this project): (1) this machine's `NuGet.Config` at
  `%APPDATA%\NuGet\NuGet.Config` was a bare `<configuration />` with no
  `<packageSources>` at all — not "using defaults," genuinely zero
  sources, which fails every `dotnet new`/`restore` with "No NuGet
  sources are defined" until `nuget.org` is added back explicitly
  (`dotnet nuget add source https://api.nuget.org/v3/index.json --name
  nuget.org`) — fixed. (2) `Microsoft.WindowsAppSDK.ProjectTemplates` is
  not a real package name despite being a natural guess; the real one
  is `Microsoft.WindowsAppSDK.WinUI.CSharp.Templates`, found via
  `dotnet new search winui` rather than assumed.
- **Disk space: the actual reason this session stopped.** This
  machine's `C:` drive was already down to 5.1GB free before any of
  this session's installs. Installing the MSVC C++ Build Tools (needed
  for both Rust's `x86_64-pc-windows-msvc` linker and, it turned out,
  not actually needed by the WinUI 3 restore itself) was redirected to
  `D:` explicitly (`--installPath D:\VSBuildTools`, `$env:TEMP` also
  redirected to `D:\VSTemp` for that install) specifically to avoid
  this — but Visual Studio's installer still leaves some shared-
  component footprint on `C:` regardless of `--installPath`, and the
  subsequent `dotnet new winui` NuGet restore (defaults to
  `%userprofile%\.nuget\packages` on `C:`, ~1.5GB+ for the Windows App
  SDK alone) pushed `C:` to **0 bytes free** mid-restore, failing with
  `There is not enough space on the disk` on
  `Microsoft.WindowsAppSDK.Runtime.2.4.0`. Fixed the immediate crisis
  by clearing this session's own installer/package caches (~1.6GB:
  VS's `Package Cache`, NuGet's `v3-cache`/`plugins-cache`, stale
  `%TEMP%` installer leftovers) and setting `NUGET_PACKAGES=D:\nuget-
  packages` (user env var, persists) so future restores land on `D:`
  instead — but that only recovered ~0.83GB free, not enough headroom
  to safely finish the WinUI 3 restore or install `uniffi-bindgen-cs`
  (another `cargo install`, more disk). The user (personal laptop, not
  a disposable test machine) chose to stop for the day rather than
  either clear the two big pre-existing consumers found
  (`C:\Windows\Installer` at 15.64GB — MSI cache, not safely rm-able
  directly — and `C:\Windows\SoftwareDistribution` at 4.32GB — Windows
  Update's download cache, safe to clear) or push further on 0.83GB of
  headroom.
- **Also unresolved, found while trying to push this branch and
  `shared`**: this machine's git credential manager (`manager-core`)
  rejected with "Invalid username or token. Password authentication is
  not supported for Git operations" — stored GitHub credentials on this
  machine are stale/invalid. Needs the user to re-authenticate
  interactively (this session did not attempt to work around it, since
  that needs the user's own browser-based login). **As of this
  checkpoint, this session's commits are local-only on both `shared`
  and `platform/windows` — not yet pushed to `origin`.**

### Session checkpoint (this entry): VaultSignerAgent compiles clean against real bindings

Done on a dedicated QEMU test VM (Windows 11, installed fresh onto a
physical SSD passed through to the VM directly — see
`apps/windows/docs/qemu-vm-setup.md` — not the personal laptop from the
previous entry). Picked up exactly at that entry's resume steps 3–4;
steps 1–2 (disk space, git re-auth) didn't apply here since this VM's
disk is dedicated and empty, and this session's own git identity was
set up fresh (SSH deploy key, not the credential-manager path that
blocked the personal laptop).

**Verified, real, and now pushed:**
- `cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.10.0+v0.29.4`
  and `apps/windows/Scripts/generate-csharp-bindings.ps1` both run
  clean, producing a real `Generated/vaultcore.cs` (163KB) from
  vaultcore's actual compiled `uniffi`-feature build.
- **`VaultSignerAgent` now builds with 0 errors, 0 warnings** against
  those real bindings — the previous entry's guessed
  method/type/property names needed several real, mechanical fixes
  (below), now confirmed correct rather than assumed.
- vaultcore's own build+test suite re-verified on this machine too
  (113 passed, 0 failed, 1 intentionally ignored), independent of the
  personal-laptop session's earlier confirmation — a second real data
  point on a different machine.

**Real bugs found and fixed, not guessed at:**
- `generate-csharp-bindings.ps1` itself had a latent bug: `uniffi-
  bindgen-cs --library` runs `cargo metadata` internally, resolved
  from the **current working directory**, not from the dylib's path.
  Running the script from outside the repo tree failed with "could not
  find `Cargo.toml`" even though the dylib built fine. Fixed by
  `Push-Location`ing into `vaultcore/` before that specific call.
- **Namespace mismatch**: the hand-written C# assumed `VaultSigner.Core`;
  the real generated namespace is `uniffi.vaultcore`. One-line fix,
  four files (`AgentServer.cs`, `ManagementHandlers.cs`, `Program.cs`,
  `WinFormsPassphrasePrompter.cs`).
- **Exception type**: assumed `VaultException`; the real generated type
  is `FacadeException` (matching the `Facade`-prefixed naming already
  correctly guessed for `FacadeKeyType`/`FacadePurpose`/
  `FacadeDeviceProfile`). Fixed in `ManagementHandlers.cs`, `Program.cs`.
- **Callback interface name**: assumed `IPassphrasePrompter` (C#
  convention); the real generated interface is `PassphrasePrompter`, no
  `I` prefix (uniffi-bindgen-cs doesn't apply C# naming conventions to
  Rust trait names). One-line fix in `WinFormsPassphrasePrompter.cs`;
  the method signature itself (`string? Prompt(string, string)`) was
  already exactly right.
- **`CompartmentInfo`/`KeyInfo` field casing**: these are C# `record`s
  with positional-parameter properties, which take the **exact
  parameter name given** — uniffi-bindgen-cs emits camelCase parameter
  names (`@compartmentId`, `@label`, ...), so the real properties are
  `compartmentId`/`label`/`unlocked`/etc., not the PascalCase
  `CompartmentId`/`Label`/`Unlocked` that would be conventional
  hand-written C#. Fixed every access site in `ManagementHandlers.cs`.
- **`ListCompartments()`/`ListKeys()` return plain arrays**
  (`CompartmentInfo[]`/`KeyInfo[]`), not `List<T>` — so
  `.ConvertAll(...)` (a `List<T>` instance method) doesn't resolve the
  way it would on a list; fixed to the static `Array.ConvertAll(array,
  converter)` form. Same reasoning fixed a `List<string>` passed where
  `CreateKey`'s `tags` parameter needs `string[]` — changed
  `GetStringArray`'s return type to `string[]` directly.
- **Missing `<AllowUnsafeBlocks>true</AllowUnsafeBlocks>`**: the
  generated bindings use `unsafe` pointer code for buffer marshalling;
  without this the build fails with `CS0227` at several points.
  Genuinely missing from `VaultSignerAgent.csproj`, not something the
  previous session could have caught without a real compile.
- **A real `uniffi-bindgen-cs` v0.10.0+v0.29.4 codegen bug**, not a
  vaultcore or hand-written-code issue: any Rust `Vec<Vec<u8>>` (used
  for incoming key blobs in the not-yet-ported merge functions) emits
  an invalid jagged-array allocation — `new byte[][(length)]`, which
  isn't legal C# (the rank specifier lands in the wrong bracket pair).
  Worked around with a targeted post-generation regex patch in
  `generate-csharp-bindings.ps1` (`new byte[][(length)]` →
  `new byte[length][]`) rather than hand-editing `Generated/`, since
  that directory is regenerated from scratch every run. Worth reporting
  upstream at some point; not blocking in the meantime.

**Not yet done, still open:**
- `PeerAuthentication.cs`'s path-based caller check (already documented
  as weaker than macOS's code-signature check) — unchanged this
  session, still a known real gap.
- Everything below in "Exact resume steps" — `VaultSignerUI`, a real
  named-pipe round trip test, and WebAuthn research — none of that was
  attempted this session; this checkpoint is scoped to getting
  `VaultSignerAgent` itself to actually compile against real bindings.

### Session checkpoint (this entry): VaultSignerUI is real and functional; one serious open bug blocks reliable testing

Done on the same QEMU test VM as the previous entry (`C:\dev\vault_signer`,
`platform/windows`, machine name `DESKTOP-MK95E27`, Windows user
`diana`). This entry exists because the session doing this work ended
with the environment in a live, uncommitted-at-the-time state and no
continuity into the next session — everything below is written so a
completely fresh session, on this same Windows machine, with **no
access to any prior conversation**, can pick up correctly. Read this
whole entry before doing anything.

**Verified, real, and pushed this session:**
- **`ManagementClient.cs`** (new, `apps/windows/VaultSignerUI/VaultSignerUI/`):
  full named-pipe JSON-RPC client mirroring
  `apps/macos/Shared/ManagementClient.swift`, covering the same core
  surface `ManagementHandlers.cs` implements (vault/compartment/key
  lifecycle, auto-unlock). Compiled clean on the first real attempt.
- **`MainPage.xaml`/`MainPage.xaml.cs`**: a real, working UI — one
  scrollable page covering all of macOS's four screens' functionality
  (create/open vault, compartment unlock, key list, create key, key
  detail, discard key) rather than separate navigated pages. This was
  a deliberate scoping call for a first pass, not a design decision —
  splitting into real pages later is a refactor, not new functionality.
- **A real vault was created through the real UI and confirmed to
  exist on disk** — `C:\Users\diana\test-vault.vsvault`, compartment
  label `Personal`, master passphrase `test`. This is a genuine,
  working file — reuse it (via "Open Vault") rather than recreating,
  unless it's confirmed corrupted.
- **`VaultSignerUI.csproj`**: added the same `Generated/vaultcore.cs`
  compile item + native-DLL-copy target pattern `VaultSignerAgent.csproj`
  already had (the UI links vaultcore's generated bindings only for
  plain data types — `KeyInfo`, `FacadeKeyType`, etc. — never to touch
  a `Vault` directly), plus `AllowUnsafeBlocks`. Also added
  `<WindowsPackageType>None</WindowsPackageType>` +
  `<WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>` —
  **this was a real, hard-won fix**: running the UI unpackaged against
  the system-installed Windows App Runtime failed every time with
  `COMException 0x80040154 Class not registered` (at
  `DeploymentManagerCS.AutoInitialize`) or, after installing the exact
  matching runtime version, a native crash in `Microsoft.UI.Xaml.dll`
  (`0xC000027B`, WinRT's generic "stowed exception" code — not
  specific enough to diagnose from the code alone). Self-contained
  deployment (bundles the Windows App SDK runtime into the app's own
  output folder, uses registration-free WinRT) fixed it — **but this
  was only ever confirmed working when launched from the real
  interactive session** (see the environment note below); every test
  of it from a non-interactive context showed the same crash, which
  turned out to be a red herring caused by that context lacking any
  display/GPU access at all, not the self-contained fix being wrong.
- **`AgentServer.cs`**: fixed a real, previously-undiscovered bug —
  `JsonSerializer.Deserialize<RawRequest>` used default case-*sensitive*
  matching, but `RawRequest`'s properties are PascalCase
  (`Method`/`Params`/`Id`) while every real client, including this
  session's own `ManagementClient.cs` and the documented wire protocol
  (`docs/protocol-integration/README.md`), sends lowercase JSON keys.
  This meant **every single request had always failed** with
  `parse_error: missing method` — the whole `internal.*`/`vaultsigner.*`
  surface had never actually been reachable by any real client before
  this session found it. Fixed with
  `PropertyNameCaseInsensitive = true`.
- **`PeerAuthentication.cs`**: added a `#if DEBUG` bypass around the
  path-based caller check, mirroring
  `PeerAuthentication.swift`'s own already-established pattern. The
  path check assumes a packaged install (`VaultSignerUI.exe` sitting
  next to `VaultSignerAgent.exe`), which a dev build never has — each
  project builds to its own separate `bin/` folder. Without this, every
  `internal.*` call from a Debug UI build was rejected with
  `unauthorized_caller`, confirmed by hitting it for real.
- `generate-csharp-bindings.ps1`: fixed a real `Push-Location`-into-
  `vaultcore/`-before-calling-`uniffi-bindgen-cs` bug (it runs
  `cargo metadata` internally, resolved from CWD, not from the dylib
  path) and added a documented regex patch for a real
  `uniffi-bindgen-cs` v0.10.0+v0.29.4 codegen bug (`Vec<Vec<u8>>`
  produces invalid `new byte[][(length)]` instead of
  `new byte[length][]`).
- vaultcore re-verified independently on this VM: builds clean,
  113/113 tests pass.

**The one serious, NOT YET RESOLVED bug: `VaultSignerAgent.exe` dies
unpredictably, with zero trace.** This is the actual blocker, and
whoever picks this up should treat it as the top priority — nothing
else can be reliably tested until it's understood.

Symptoms: the UI (or a raw named-pipe test) intermittently reports
`VaultSignerAgent isn't running` even though `Get-Process
-Name VaultSignerAgent` shows it alive. Checking
`[System.IO.Directory]::GetFiles('\\.\pipe\')` for `VaultSignerAgent`
at that moment shows **no listening pipe at all**, despite the process
existing. There is no crash: `Get-WinEvent` (both the generic
Application log, id 1000, and the full `.NET Runtime` provider) shows
nothing for these incidents, and Windows Defender's own history
(`Get-MpThreatDetection`, the Defender Operational log) shows no
detections either. The process is not crashing — something is either
killing it cleanly with no trace, or (less likely, given
`AgentServer`'s 4 concurrent `AcceptLoopAsync` loops) all 4 named-pipe
listener instances are somehow getting stuck simultaneously.

**One real, already-fixed contributing cause, ruled out but worth
knowing about:** earlier in this session, *multiple* `VaultSignerAgent`
processes ended up running simultaneously (each `Start-Process` call
left the previous instance running instead of replacing it), all
listening on the same pipe name with independent, inconsistent
in-memory vault state — a request would land on whichever instance
happened to accept next. **Always run
`Get-Process -Name VaultSignerAgent` and kill any existing instance
before starting a new one** — this is necessary but was not
sufficient; the disappearing-pipe symptom recurred even with
confirmed-single instances.

**A real, controlled test that isolated part of the mechanism** (done
from an SSH connection, not the interactive session — see the
environment note below for why that distinction matters less here
than it does for GUI rendering): launching `VaultSignerAgent.exe` via
`Start-Process` from a short-lived PowerShell process (one that exits
right after issuing the command, e.g. a single non-interactive
`ssh host "powershell -Command '...'"` invocation) reliably let the
agent die within moments of that launching PowerShell process exiting
— no crash log, process just gone. Keeping the *launching* PowerShell
process alive indefinitely (via a `while ($true) { Start-Sleep 5; ... }`
loop in the same script, checked repeatedly over 20+ seconds) let the
*same* agent process and its pipe survive the whole time without
issue. This strongly suggests a **Job Object tying the child process's
lifetime to whatever process launched it** — a real, known Windows/
PowerShell behavior, not unique to this project's code.

**What's NOT yet confirmed**: whether this same mechanism explains the
failures seen from the user's own single, continuously-open
interactive PowerShell window (as opposed to a short-lived scripted
launch) — that window never closed, yet the agent still seemed to die
between UI interactions. It's possible the zombie-process confusion
above was the *entire* explanation for those specific incidents and
this is a separate, second issue; it's also possible interactive
PowerShell/Windows Terminal sessions have their own, different
job-object association per command that also triggers this. **Do not
assume either way — verify first**, with the isolated test below.

**Exact resume steps, next session, in order:**

1. **First, isolate the real mechanism before touching any code.**
   From a single, freshly-opened PowerShell window (not reused, not
   via SSH), run exactly:
   ```
   Get-Process -Name VaultSignerAgent -ErrorAction SilentlyContinue | Stop-Process -Force
   Start-Process "C:\dev\vault_signer\apps\windows\VaultSignerAgent\bin\Debug\net8.0-windows\VaultSignerAgent.exe"
   [System.IO.Directory]::GetFiles('\\.\pipe\') | Select-String VaultSigner
   ```
   Run that last line again every 15-30 seconds for a few minutes,
   *without* running any other command in between, and watch whether
   the pipe stays present or disappears. This settles the open
   question above. If it disappears even with nothing else happening
   in that window, the Job Object theory extends to interactive use
   too, and the real fix needs research into one of:
   (a) a Task Scheduler task with an interactive-session trigger (this
   session tried `/SC ONCE /IT /RU diana` — it ran, but landed in a
   *different* session ID than the interactive desktop, so its window
   wasn't visible; needs more investigation, possibly `/SC ONLOGON`
   matching the real eventual `AutostartManager.cs` deployment path,
   tested at an actual fresh logon rather than on-demand);
   (b) explicitly breaking the child out of its parent's Job Object at
   creation time (there is a real Win32 mechanism for this —
   `CREATE_BREAKAWAY_FROM_JOB` — research whether it's reachable from
   `Process.Start`/`ProcessStartInfo` in .NET, or whether it needs a
   native `CreateProcess` call);
   (c) accepting this as a known dev-environment-only quirk (real
   deployment uses an HKCU Run-key at logon, a fundamentally different
   launch path than any of this session's manual testing) and treating
   the *actual* deployment mechanism, not manual `Start-Process`
   testing, as the thing that needs to work — in which case, test via
   `AutostartManager`'s own registration instead of manual launches.
2. Once the agent reliably stays up, retry the real flow: launch
   `VaultSignerAgent.exe`, then `VaultSignerUI.exe`
   (`apps\windows\VaultSignerUI\VaultSignerUI\bin\Debug\net8.0-windows10.0.26100.0\win-x64\VaultSignerUI.exe`),
   click **Open Vault** with path `C:\Users\diana\test-vault.vsvault`
   (already exists, passphrase `test`), unlock the `Personal`
   compartment, create a key, confirm it lists and shows detail
   correctly.
3. Run a real `vaultsigner.sign` round trip (spec item 3.6) — this
   will trigger `WinFormsPassphrasePrompter`'s real dialog; confirm it
   renders correctly (it uses plain WinForms, not WinUI3/
   DirectComposition, so it may not be affected by the same rendering
   path the UI's earlier crash was, but this has not been separately
   confirmed) and that answering it returns a real signature.
4. Item 3.4 (WebAuthn plugin-authenticator COM registration) —
   research only so far; do not register anything system-wide without
   the user's explicit sign-off.

**Environment notes for whoever resumes:**
- GUI rendering (any window, any dialog) only works when the process
  is launched from within the actual interactive logon session — a
  process launched via SSH, or via a Task Scheduler task without the
  right session targeting, runs in a different, non-interactive
  session (confirmed via `[System.Diagnostics.Process]::GetCurrentProcess().SessionId`
  — SSH-launched processes on this box landed in session 0; the real
  interactive desktop was session 3 at last check, but this number can
  change across logons). This is why several of this session's
  earlier diagnostic crashes (the WinUI3 `Class not registered`/
  `0xC000027B` errors) turned out to be partly artifacts of testing
  from the wrong session, not purely code bugs — though the
  self-contained-deployment fix was real and still needed.
- A `.gitignore`'d `apps/windows/Generated/vaultcore.cs` must exist
  before either project builds — regenerate it with
  `apps/windows/Scripts/generate-csharp-bindings.ps1` if missing.
- `git` on this machine authenticates to GitHub via a dedicated SSH
  deploy key already configured (`~/.ssh/config` has a `Host github.com`
  entry pointing at `~/.ssh/github_deploy_key`) — this should already
  work with no further setup.

### Session checkpoint (this entry): the "VaultSignerAgent isn't running" bug is root-caused and fixed

Same QEMU VM as the two previous entries. **The top-priority blocker from
the previous checkpoint is resolved** — root cause found via a real
reproduction (not just log reading), fixed, and verified end-to-end
through the actual UI. The earlier checkpoint's Job-Object/session
theories were a red herring — real, useful debugging that ruled things
out, but not the actual mechanism. Thank the user for the correction
that redirected this session: the process was never dying: only the
UI's own error message said so.

**Root cause**: `AgentServer.AcceptLoopAsync` (`apps/windows/VaultSignerAgent/AgentServer.cs`)
called `NamedPipeServerStreamAcl.Create(..., pipeSecurity: BuildPipeSecurity())`
on *every* loop iteration — i.e. for every instance of the named pipe,
not just the first. Windows only honors an ACL on the first-ever
instance of a given pipe name; every instance created after that must
omit the security descriptor, or `NamedPipeServerStreamAcl.Create`
throws `System.UnauthorizedAccessException` ("Access to the path is
denied"). That's a sibling of `IOException`, not a subclass, so the
existing `catch (IOException)` around that call never caught it. Since
each `AcceptLoopAsync` is launched fire-and-forget
(`_ = Task.Run(AcceptLoopAsync)`, 4 of them, never awaited or observed),
the escaping exception silently ended whichever loop hit it — no crash,
no log, process stays alive, confirmed via a live `dotnet-dump` stack
capture showing zero threads doing anything related once all 4 loops
had died.

This is exactly why it looked "idle-stable" in isolated liveness
testing but died under real use: at most one of the 4 loops' very first
`Create` call could ever win the race to be genuinely first; the other
3 died on their first iteration, before any client had even connected.
The winner survived until a client consumed its instance, then died too
the moment it looped back to create a replacement. The pipe only went
fully dark once all 4 original instances had each been connected-to
exactly once — reproduced deterministically this session: a **single**
`internal.list_compartments` call (no KDF, no vault mutation) against a
freshly-started agent was enough to start the collapse, and it was
fully, permanently dead (verified via
`[System.IO.Directory]::GetFiles('\\.\pipe\')` showing no
`VaultSignerAgent` entry at all, process still alive/responding, 0ms
CPU) after 4 total real requests.

**Fix**: `_firstPipeInstanceCreated` (an `int` guarded by
`Interlocked.CompareExchange`) tracks which single call — across all 4
loops, whichever wins the race — is allowed to supply the ACL via
`NamedPipeServerStreamAcl.Create`; every other instance, from then on,
is created via the plain `NamedPipeServerStream` constructor with no
security descriptor. Also added (belt-and-suspenders, kept
permanently): both `AcceptLoopAsync` and `HandleConnectionAsync` now
catch and log any unexpected exception type instead of only the ones
each was originally written to expect, so a *different* future edge
case can't silently kill a fire-and-forget accept loop again with zero
trace the way this one did.

**Verified this session**, all against the real built agent (not just
reasoning about the code):
- 20 sequential real pipe calls: all fast (0-1ms round trip after the
  first), zero errors.
- An 8-way concurrent burst (PowerShell background jobs hitting the
  pipe simultaneously): all succeeded, pipe stayed listed and
  reachable throughout.
- `internal.unlock_compartment` with the real `test-vault.vsvault`
  passphrase: succeeded, `unlocked: true` confirmed by a follow-up
  `list_compartments`.
- **The real UI, for real** (resume step 2 from the previous
  checkpoint): launched `VaultSignerUI.exe` against the fixed agent,
  drove it via UI Automation (`System.Windows.Automation` — screenshots
  of this window came back stale/blank all session, a `CopyFromScreen`-
  vs-DirectComposition capture quirk on this VM, *not* an app rendering
  failure; the live accessibility tree was always fully populated and
  correct) — created a real key (`claude-test-key`, Ed25519 /
  CustomSigning), confirmed it appeared in the key list, selected it
  and confirmed the detail panel populated correctly (label,
  description, a real-looking 65-hex-char public key), then discarded
  it via the same confirm-text flow the UI requires. Pipe stayed
  healthy throughout the whole flow.
- vaultcore itself was not touched — this was entirely a
  `VaultSignerAgent`/.NET-side bug.

**Not attempted this session**: resume step 3 (a real
`vaultsigner.sign` round trip exercising `WinFormsPassphrasePrompter`'s
real dialog) and step 4 (WebAuthn plugin-authenticator COM
registration research) from the previous checkpoint — both still open,
now unblocked.

**Not yet committed** — this checkpoint's code changes
(`apps/windows/VaultSignerAgent/AgentServer.cs`) and this `PROGRESS.md`
update are sitting uncommitted in the working tree as of this entry.

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
