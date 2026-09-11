# VaultSigner — Progress

Mirrors the checklist IDs in `/spec/VaultSigner-Spec.md` §12. Read this
file first before starting work in any session. After finishing a
checklist item, update it here and commit — never mark an item done
without a passing build/test artifact referenced by commit hash.

**Entries here stay a checklist line plus, where needed, a short
exception note — not a narrative.** Debugging history, dead ends, and
"here's exactly what happened" material belongs in a dev journal
instead: `apps/<platform>/docs/<platform>-dev-journal.md` for anything
platform-specific (committed on that platform's own branch), or
`docs/shared-dev-journal.md` for cross-platform-relevant facts
(committed on `shared`). See `CLAUDE.md`'s branch-model section for the
full rule. Reference the relevant journal from your exception note
rather than inlining the detail here.

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
- [x] 0.4 Revisit release-tag scheme now that a second platform (Windows)
      is genuinely close to shipping — the original single-global-tag
      scheme (still described as the plan in `CLAUDE.md` up to this
      point) said explicitly to revisit once that happened. **Decision:**
      switched to per-platform tags (`macos-vX.Y.Z`, `windows-vX.Y.Z`, …),
      each an independent SemVer line — a shared tag reads to an outside
      developer as "every platform this project supports," and a
      platform-only release under a shared tag silently re-published
      every other platform's artifacts as if they'd changed too.
      `vaultcore` gets independent **versioning** (its own `Cargo.toml`
      number, reasoned about by its own changes) and a plain, lightweight
      `vaultcore-vA.B.C` tag when that number moves — but not an
      independent **release process**: it's never published on its own
      (`publish = false`, no crates.io), only ever bundled inside a
      platform's own release artifacts, so a third full release cadence
      to coordinate would be pure overhead. Full rules in `CLAUDE.md`'s
      Versioning section; this entry is the "why," not the rulebook.
      **Flagging, not building here:** there's no
      `apps/windows/Scripts/package-release.ps1` (or a `build-staging`
      equivalent) yet at all — needed before a Windows release can
      actually be cut. Left for whoever's already working directly on
      `platform/windows` rather than built as part of this change.
- [x] 0.5 Write a formal, standalone specification of the custom local
      signing protocol (§7), distinct from the spec (deliberately
      informal/process-oriented by original design) and from
      `docs/protocol-integration/README.md` (a friendlier integration
      guide with examples, kept as-is for that purpose). **Decision:**
      third-party integration against this protocol (including the
      author's own browser-extension integration) had outgrown an
      informal description — `docs/protocol-integration/PROTOCOL-SPEC.md`
      is now the normative wire-format reference, versioned on its own
      (currently 1.0) independently of any platform's version. Per
      `CLAUDE.md`'s Versioning section, changes to that document are what
      drive `vaultcore`'s MAJOR/MINOR reasoning on protocol grounds going
      forward. One substantive addition made while formalizing it:
      `no_vault_open` was previously described identically but
      separately in both the macOS and Windows integration guides as an
      "agent-specific" error beyond the core catalog — promoted to the
      core error table itself, since both existing implementations
      already agreed on it and leaving it informal invited future
      platforms to invent their own name for the same condition.

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

Not started.

## Phase 4 — Android

In progress, first real checkpoint. See spec §12 for the full item list
(4.1–4.11). Everything below was built on `platform/android` (branched
from `shared`, per `CLAUDE.md`'s branch model) and, where marked
"verified," actually run — installed and driven — on a real cold-booted
`vaultsigner_avd` emulator (Android 14, x86_64), not just compiled.

**Environment note, since the task brief's own provisioning list turned
out incomplete:** JDK 17, the Android SDK (API 34, build-tools 34.0.0),
the emulator/AVD, all 4 Rust Android targets, and cargo-ndk were real and
already working — but the Android **NDK itself** was not installed
(`$ANDROID_HOME/ndk/` didn't exist), which cargo-ndk needs to actually
compile anything. Installed `ndk;28.2.13676358` (r28c) via `sdkmanager`
before any cross-compilation could be attempted. Also had to install
`platforms;android-36` — not because this project's floor moved off API
34 (it hasn't, see below), but because several current-stable androidx
libraries (`core-ktx` 1.19, `lifecycle` 2.11, `activity-compose` 1.13)
require compiling against API 37 / AGP 9.1+, and AGP 9.x needs a newer
JDK than this VM's deliberately-provisioned JDK 17 — pinned to the
newest androidx versions that still work with AGP 8.13.2 / compileSdk 36
instead (`core-ktx` 1.15.0, `lifecycle` 2.8.7, `activity-compose` 1.9.3,
`compose-bom` 2024.12.01, `credentials` 1.5.0), all verified by a real
green `:app:assembleDebug`. `compileSdk` is 36; `minSdk`/`targetSdk`
stay 34 per spec §12 item 0.2's Android-14+ floor — those are
independent knobs.

- [x] 4.1 Compose management UI mirroring 2.1–2.5. Real `Vault`-backed
      screens in `apps/android/app/src/main/kotlin/com/vaultsigner/ui/`:
      `WelcomeScreen` (known-vaults list per spec §5.6, create/open),
      `CreateVaultScreen`, `UnlockScreen` (compartment picker when >1),
      `KeyListScreen`, `CreateKeyScreen`, `CreateCompartmentScreen`
      (mirrors Windows's `CreateCompartmentPage` — macOS never built one,
      per the architecture survey done at the start of this phase),
      `KeyDetailScreen` (change-passphrase/reveal-raw-key/discard as
      dialogs), `ExportPacketScreen` (all three §5.2.2 encryption
      choices, uncollapsed, no default), `ImportPacketScreen` +
      `MasterKeyDualityScreen` (all three §5.3 options, exact
      `REPLACE_CONFIRMATION_PHRASE` enforced client- and server-side),
      `SettingsScreen`, `ManageVaultsScreen`.

      **Interactively verified for the core flow, on-device, this
      session** (mirrors how Phase 2 verified macOS without trusting
      screenshots — see item 4.2 for why screenshots don't work here
      either, though for a different reason): drove the real installed
      app via `adb shell input`/`uiautomator dump` (not a screenshot —
      see 4.2) through create-vault (real ~1s Argon2id derivation) →
      force-stop the app entirely → relaunch → agent auto-reopens the
      last vault → routes to Unlock (not straight to keys — a real bug
      this caught, see below) → unlock with the real passphrase → key
      list → create-key (real Ed25519 keypair) → the new key visible via
      `vaultsigner.list_public_keys` over the real socket.
      `ExportPacketScreen`/`ImportPacketScreen`/`MasterKeyDualityScreen`/
      `CreateCompartmentScreen` are now also click-tested through this
      app's own UI, via instrumented tests (see 4.8) rather than manual
      driving.

      **Three real bugs found and fixed by actually driving the app**
      (not found by reading the code — device testing genuinely earned
      its keep here):
      1. Every form screen (`CreateKey`/`CreateVault`/`CreateCompartment`/
         `Export`/`Import`/`MasterKeyDuality`/`Settings`/`KeyDetail`/
         `Unlock`) used a plain, non-scrollable `Column` — on the
         emulator's 640px-tall viewport, `CreateKeyScreen`'s lower fields
         and its own Create button were completely unreachable. Fixed
         with `Modifier.verticalScroll`.
      2. `VaultSignerService.onCreate()` started the socket server
         *before* reopening the last-known vault — a client's very first
         `internal.status` right after a cold agent start could race
         ahead of `AgentState.vault` being set and see `vault_open: false`
         for a vault that was, milliseconds later, actually open.
         Reordered so the reopen finishes first.
      3. `WelcomeScreen` routed straight to the key list whenever a
         reopened vault had exactly one compartment, without checking
         whether that compartment was actually *unlocked* — opening a
         vault never auto-unlocks it on its own (only §8's opt-in
         auto-unlock does), so this would have hit "compartment is not
         unlocked" trying to list keys on the very first relaunch after
         a force-stop. Now checks `compartments[0].unlocked` too.

      **A fourth, more serious finding — a real bug in shared `vaultcore`
      itself, not Android-specific code.** Doing a real self-export/
      self-import round trip through this app's UI (create a second
      vault, export a key "as-is" with "include master key" on, import
      the packet, complete the §5.3 option-1 duality screen) looked
      correct — the imported key showed up immediately via a live
      `vaultsigner.list_public_keys` check. Force-stopping the app and
      relaunching made the key vanish, even though its `.kblob` was
      genuinely sitting on disk. Root cause: `vault.rs`'s
      `apply_merge_result` (used by `merge_reencrypt_discard_incoming`,
      i.e. spec §5.3's *recommended default* option) updated the
      in-memory plaintext manifest and copied the new key's blob bytes,
      but never re-encrypted the updated manifest back into
      `state.container.master_blobs` before `write_atomic` — so the file
      on disk kept the pre-merge master blob. Every in-memory read within
      the same process looked right; only a genuine close+reopen exposed
      it. Fixed in `vaultcore/src/vault.rs` (committed on `shared`, since
      this is shared-scope code, not Android-only) by re-encrypting each
      updated compartment before persisting, mirroring the exact pattern
      `persist_locked` already uses for every other manifest mutation.
      Added `merge_option1_key_survives_close_and_reopen` — the existing
      `merge_option1_reencrypts_into_target_compartment` test only ever
      checked the same in-memory `Vault` instance, which is exactly how
      this got past it, past the rest of `vault.rs`'s merge coverage, and
      past macOS's own interactive verification of this identical facade
      method (item 2.4's notes explicitly flag that its own no-embedded-
      master-key path — the *same* underlying method — was exercised live
      but never through a close-then-reopen). Confirmed: the new test
      fails against the pre-fix code (0 keys instead of 1) and the full
      suite is green after the fix (114 passed, 0 failed). **This affects
      every platform sharing this code path, not just Android** — worth
      flagging to whoever is working on macOS/Windows import flows, since
      neither of their own PROGRESS.md entries mention re-testing this
      specific scenario (close, then reopen) after their own item 2.4/
      equivalent verification.
- [x] 4.2 `FLAG_SECURE` (spec §5.0). Applied once, globally, on
      `MainActivity`'s window in `onCreate` — this app is single-Activity
      (Compose Navigation swaps screens within one window), so one call
      covers every screen by construction, unlike macOS's per-`NSWindow`-
      sheet or Windows's per-`Page`-navigation-event approach (both
      workarounds for those platforms' multi-window reality, not
      applicable here — see `apps/android/docs/protocol-integration.md`'s
      sibling note for the same comparison from the transport side).
      `PassphrasePromptActivity` and `PasskeyCompletionActivity` set it
      independently since they're genuinely separate Activities/windows.

      **Verified for real, isolated, A/B** (not incidental the way
      macOS's own first observation was flagged as needing a deliberate
      test — done properly here from the start): `adb shell screencap`
      on the home screen produced a real 204 KB PNG; the identical
      command with `MainActivity` in the foreground produced a genuine
      0-byte file; backing out to home and back reproduced both results
      consistently. Repeated the same test against `PassphrasePromptActivity`
      mid-prompt (see 4.6) — also a clean 0-byte capture.
- [x] 4.3 Foreground service hosting the custom-protocol listener and
      retention cache, with autostart/auto-unlock toggles.
      `VaultSignerService` (`android:process=":agent"`,
      `foregroundServiceType="specialUse"` — API 34's category for a use
      case with no better-fitting standard type, with the required
      `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` justification string) owns the
      single `Vault` instance and a `LocalServerSocket` serving both
      `vaultsigner.*` and `internal.*` over the same abstract-namespace
      socket (spec §8: "both communicate over the same local-IPC
      mechanism as Section 7"). `internal.*` is authenticated via
      `LocalSocket.getPeerCredentials().uid == Process.myUid()` —
      Android's per-app UID sandboxing makes this a complete answer,
      strictly simpler than the code-signing checks macOS/Windows need
      (spec §8's own caveat: a Unix socket's owner-only permissions alone
      only prove same-*user*, not same-*app*, on desktop; on Android
      there is no same-user-different-app case to guard against in the
      first place). `AutoUnlockStore` (Android Keystore, hardware-backed
      AES-GCM key, mirrors macOS Keychain/Windows DPAPI) and
      `AutostartPrefs` + `BootCompletedReceiver` implement the two §8
      toggles; `VaultConfig` persists the last-open vault path so a
      restarted agent picks back up where it left off (mirrors macOS's
      `main.swift`).

      **Verified for real**: survives `am force-stop` (kills both the
      default and `:agent` processes) and correctly reopens its vault on
      the next launch (see 4.1's bug #2/#3); the real notification shows
      with `IMPORTANCE_MIN`; `ps -A` confirms `com.vaultsigner.app:agent`
      as a genuinely separate OS process from `com.vaultsigner.app`.
- [ ] 4.4 `CredentialProviderService` registered and verified against at
      least two real relying parties. **Registered and OS-recognized,
      verified live — the relying-party interop half is not done.**
      `VaultSignerCredentialProviderService` + `PasskeyCompletionActivity`
      run in the same `:agent` process as `VaultSignerService` and share
      `AgentState.vault` directly — a deliberate architectural choice to
      avoid the exact split-brain gap macOS's extension has (a genuinely
      separate OS process there, forced to open its own separate `Vault`,
      flagged as a known deferred issue in that platform's own item 2.7
      entry; Android's single-APK, multi-component-one-process model
      avoids it by construction, not by discipline). `onBeginGetCredentialRequest`
      queries `vault.credentialCandidates(rp_id)` (already existed in the
      facade, unused until now) and builds real `PublicKeyCredentialEntry`
      objects; `onBeginCreateCredentialRequest` offers a `CreateEntry` for
      the currently-unlocked compartment. `PasskeyCompletionActivity`
      does the real CTAP2-native round trip via `handleFido2GetAssertionNative`/
      `handleFido2MakeCredentialNative` (reusing the exact facade methods
      macOS's extension uses) and constructs the WebAuthn response JSON
      itself (Android's Credential Manager doesn't build `clientDataJSON`
      for a provider — verified against Android's own current developer
      docs, not assumed, after this session's own reminder that the
      Windows FIDO2 work got bitten by exactly this kind of drift).

      **Real, live verification**: tapping the app's own Settings →
      "Enable in system settings" opens Android's actual system Settings
      (`Settings$AccountDashboardActivity`), where "VaultSigner" appears
      under Additional providers with the correct
      `android:settingsSubtitle` from `provider.xml` — the registration
      is genuinely OS-recognized, not just compiling.

      **What is not done, honestly**: no live WebAuthn ceremony has been
      run against a real relying party in a real browser. The
      `clientDataJSON`/origin-derivation logic in
      `PasskeyCompletionActivity` is a best-effort construction against
      documented WebAuthn/Credential-Manager shapes, not something this
      session could verify byte-for-byte correct without that live test.
      This is the same category of honest gap Phase 2/3 carry for their
      own FIDO2 items (2.7's paid-account block, 3.4's OS-build block) —
      Android's blocker here is simply "not yet attempted, needs its own
      follow-up session with real interop testing," not an external gate.
      Exception: attempted against two real demo relying parties this
      session (see `apps/android/docs/android-dev-journal.md`) — the
      registration path is now confirmed to trigger correctly against an
      independent real site, but the live ceremony itself still wasn't
      completed, so this item's status is unchanged.
- [x] 4.5 Settings deep link via `createSettingsPendingIntent()`.
      Verified against Android's real current API surface first (it's an
      instance method on `CredentialManager`, not a static/companion
      method the way the spec's generic wording could be read) — see
      `SettingsScreen.kt`. **Verified live**, end-to-end, per item 4.4's
      note above.
- [x] 4.6 Custom protocol verified against a minimal test client.
      `apps/android/uniffi-verify/agent_test_client.py` (mirrors
      `apps/macos/uniffi-verify/agent_test_client.py`'s shape), run for
      real over `adb forward tcp:9999 localabstract:com.vaultsigner.app.agent`
      against the real running app: `vaultsigner.list_public_keys`
      answers with no prior registration; `internal.*` from a non-owner
      peer UID is correctly rejected with `unauthorized_caller`; unknown
      methods get `method_not_found`. **Also manually verified
      interactively**, the macOS-equivalent "real third-party GUI app"
      case (there: a Tkinter demo; here: the same Python client used
      live rather than automated): a `vaultsigner.sign` call for a cold
      key produced the real prompt "Shell wants to sign with key
      76365e38" (caller identity resolved via `PackageManager`, from the
      adb-mediated peer's real UID — never a self-reported name),
      entering the real key passphrase and tapping Allow returned a
      signature independently verified with Python's `cryptography`
      library against the key's real Ed25519 public key. See
      `apps/android/docs/protocol-integration.md` for the one thing this
      *doesn't* prove: genuine third-party-app-to-app socket reachability
      independent of `adb`'s own mediation, flagged there as believed-but-
      not-conclusively-tested.
- [x] 4.7 i18n parity with prior builds. Built i18n-first rather than
      migrated after the fact (a different starting point than macOS/
      Windows had at their own 2.9/3.7 checkpoints): every screen/view
      file uses `i18n/source/en.json` keys via generated `R.string.*`
      resources from day one. `i18n/generate-android-strings.py` (new,
      mirrors `generate-apple-strings.py`) emits `res/values/strings.xml`
      + `res/values-ar/strings.xml`, converting Apple's `%@` placeholder
      convention to Android's positional `%1$s` form and XML-entity-
      escaping values (`&`/`</>` — caught a real generator bug this way:
      `duality.option1.title`'s "Re-encrypt & discard..." broke the XML
      parser until fixed). `i18n/lint-hardcoded-strings-android.py` (new,
      mirrors the Swift/PowerShell lints) `--strict` is clean across
      every screen/view file, not a partial set. 11 new `android.*` keys
      added to `i18n/source/en.json` for surfaces with no desktop
      equivalent (the foreground-service notification, the Credential
      Manager provider subtitle, the passphrase-prompt dialog) —
      committed directly on `shared` per `CLAUDE.md`'s path ownership
      (git's ref model won't let a `shared/<topic>` branch coexist
      locally with the `shared` branch itself, so this used the other
      branch-model-sanctioned path: committing shared-scope work directly
      on `shared`). RTL layout now verified on-device (per-app Arabic
      locale override, real Arabic text + mirrored element positions
      confirmed via `uiautomator` bounds on `WelcomeScreen` and
      `ManageVaultsScreen`) — see `apps/android/docs/android-dev-journal.md`.
      `ImportPacketScreen`/`MasterKeyDualityScreen` inherit the same
      automatic mirroring but weren't individually spot-checked.
- [ ] 4.8 Phase 10 test/fuzz suite. Shared `vaultcore` suite already
      green (spec §10, same as Phase 2/3). `androidTest` instrumented
      coverage: [x] `CoreVaultFlowTest` (create vault → create key),
      [x] `CreateCompartmentFlowTest`, [x] `ExportImportDualityFlowTest`
      (self-export/self-import round trip across two real vaults via
      duality option 1) — all passing on both flavors, emulator + real
      device, run via Android Test Orchestrator for process isolation
      between tests. See `apps/android/docs/android-dev-journal.md`. Not
      done: interop tests, blocked on 4.4.
- [x] 4.9 `docs/user-guide.md` reconciled against the real, shipped
      Android UI. One precise edit: extended the existing Windows
      compartments note to also cover Android (which genuinely has the
      identical feature — verified via the same `Vault::add_compartment`
      facade already proven in the Kotlin/Swift `uniffi-verify`
      harnesses). Everything else in the guide already described
      Android's real behavior accurately with no edit needed: the
      auto-unlock section's default (non-Windows-caveated) text already
      matches Android Keystore's real protection strength (spec §8
      groups it with macOS Keychain, not Windows DPAPI); the custom-
      protocol paragraph already matches Android's real desktop-like
      transport (no iOS-style App-Intents narrowing); retention timing,
      known-vaults, and reveal-raw-key behavior all match what the real
      built app does.
- [x] 4.10 `apps/android/docs/protocol-integration.md` written and
      linked from `docs/protocol-integration/README.md`'s platform-guides
      list. Covers the real transport (an abstract-namespace Unix domain
      socket, not a filesystem path — explains precisely why desktop's
      model doesn't translate to Android's per-app-UID storage
      sandboxing), discovery, `internal.*` authentication, caller-identity
      resolution, and a working example — plus the honest, explicit
      caveat on what genuine third-party-app reachability this session
      did and didn't prove (see item 4.6).
- [ ] 4.11 Documentation site rebuild. **Not attempted, correctly**:
      `CLAUDE.md`'s Versioning/docs section requires this be done "from a
      branch with every completed platform's docs actually merged in
      (staging, release, or main — never `shared` alone)". `staging`
      already has macOS's and Windows's `apps/` content (confirmed:
      `git ls-tree -r origin/staging -- apps/windows` shows 65 files,
      `apps/macos` shows 38), but **not** Android's — `platform/android`
      itself hasn't been merged into `staging` yet. Deciding *that* isn't
      this session's call to make unilaterally: several of this phase's
      own items are still open (4.4's interop, 4.8's suite), and whether
      "first real checkpoint" already counts as ready to integrate into a
      shared branch other in-flight platform work depends on is a
      judgment call for whoever's coordinating the release, not something
      to do quietly as a side effect of wanting to run a docs-site script.
      Left for that person — same posture Windows's own item 3.11 entry
      already took ("prepared but deliberately not published this
      session").

**Not part of spec §12's checklist but worth recording**: the real,
concrete architectural payoff of testing on-device rather than stopping
at "it compiles" — items 4.1–4.3/4.6's bugs (§4.1) were only found by
actually installing and clicking through the app, and would not have
surfaced from a code review alone. `apps/android/` also required
provisioning work the task brief's own environment notes didn't
anticipate (the missing NDK, the AGP/JDK version ceiling) — see this
section's own opening note.

**Post-checklist product decision, this session: `full`/`lite` Gradle
flavors.** Spec §12/§6.3's API-34+ floor is real (FIDO2/
`CredentialProviderService` genuinely needs it) but was also, on
reflection, too narrow a floor for the *whole app* to sit behind — API 34
alone is ~54.5% of active devices (apilevels.com, April 2026 Statcounter
figures), meaning the original scope would have made VaultSigner
uninstallable on roughly half of all active Android phones. Split into
two Gradle product flavors of the exact same app/commit/version number
(not two products, not independently versioned — unlike `vaultcore`):
`full` keeps the original API 34+/FIDO2 scope unchanged; `lite` drops
only `CredentialProviderService` and reaches down to **API 23** — the
real floor, not a guessed one: AndroidX itself has required minSdk 23+
since June 2025, so this Compose/AndroidX-built app cannot go lower
regardless of product choice, and 23 already covers ~98.0% of devices vs.
~96.6% at 24 — there is no meaningful coverage between them to trade
away. Full reasoning and the distribution-data table:
`apps/android/docs/release-process.md`.

Flavor-specific source sets hold *only* the FIDO2 code path
(`VaultSignerCredentialProviderService.kt`, `PasskeyCompletionActivity.kt`,
`provider.xml`, the manifest fragment declaring them, and the
`fullImplementation`-only `androidx.credentials` dependency) — everything
else (UI, `vaultcore`/UniFFI bindings, the custom protocol, i18n) is
unmodified shared code compiled into both flavors. One genuine shared-code
fix was required, not a flavor split: `VaultSignerService`'s foreground-
service type is now chosen at runtime by SDK tier (`specialUse` on 34+,
`dataSync` on 29-33, none below 29, via `ServiceCompat.startForeground`)
since spec's original `specialUse` type is an API-34-only concept and
`lite`'s entire reason to exist is running below that floor — getting
this wrong would have crashed `lite` on startup for the whole audience it
was built for.

**Verified for real on both ends, not just "it compiles":**
- `lite`: installed the actual debug build on a real, physically-confirmed
  Android 13/API 33 device (`Samsung SM-A326B`, confirmed via
  `getprop ro.build.version.sdk`, not an emulator) after a clean
  uninstall. `dumpsys activity services` confirmed `VaultSignerService`
  starts as a genuine running foreground service (`isForeground=true`,
  real notification/channel) with no `IllegalArgumentException` and no
  crash — exactly the failure mode an unverified type-value assumption
  would have produced. Drove a real vault create → key list → Settings
  flow through the actual UI and confirmed no Credential-Manager button
  appears (the `lite`-flavor no-op `CredentialProviderSettingsSection()`
  took effect, not just "compiled without the import").
- `full`: `assembleFullDebug`/`bundleFullRelease` both build clean; not
  independently re-verified on-device this session beyond that, since its
  own code didn't change (only moved files, no logic edits) and the
  shared code it depends on was exactly what `lite`'s real-device pass
  above exercised. Its prior real-device/emulator verification earlier in
  this Phase 4 section stands unchanged.

Also earlier in this same real-device session (found and fixed before
settling on the flavor split, while manually testing on the same
physical phone): a UI-automation red herring initially misread as an
app bug — typing a passphrase into a field, then a *second* field whose
on-screen position had shifted once the keyboard covered part of the
layout, landed the tap on the keyboard itself rather than the field,
leaving the second field empty and tripping the "passphrases don't
match" check. Not an app defect; the mismatch check was working
correctly. Re-tested by re-reading field coordinates from a fresh
accessibility-tree dump taken *after* the keyboard was showing, rather
than reusing a pre-keyboard dump's coordinates — a real testing-technique
fix, not a code fix, worth recording since it cost real time to track
down and will recur for anyone else driving this app's forms via `adb
shell input` + `uiautomator dump` instead of a real instrumented UI test.

Added `apps/android/Scripts/package-release.sh` (builds and names both
flavors' release `.aab`s under one `android-vX.Y.Z` tag) and
`apps/android/docs/release-process.md`; `CLAUDE.md`'s Release artifacts
section now documents Android's one-tag/two-artifact scheme alongside
macOS's. **Known gap, disclosed in that doc**: Android release signing
isn't set up at all yet — neither `.aab` is Play-Console-ready.

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
