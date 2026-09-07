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

- [ ] 0.1 Confirm UniFFI binding generation setup for Swift/Kotlin/C#/C
      targets. **Not started.** No UniFFI dependency has been added to
      `vaultcore` yet — see the note under Phase 1 item 1.11 below.
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
- [ ] 1.7 CTAP2 message handling (`authenticatorMakeCredential`,
      `authenticatorGetAssertion`) as a platform-agnostic library
      function. **Not started.**
- [ ] 1.8 Custom protocol JSON-RPC handling (§7) as a platform-agnostic
      library function. **Not started.**
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
- [ ] 1.11 UniFFI bindings generated and verified callable from a
      minimal Swift, Kotlin, and C# test harness. **Not started.** No
      Swift/Kotlin/C# toolchain is available in the environment this
      work was done in, so no UniFFI dependency or `.udl`/proc-macro
      scaffolding has been added yet — adding it without a way to
      verify it compiles/binds for real would just be unverified
      guesswork. Do this once a macOS (Swift) or Android (Kotlin)
      toolchain is available, likely at the start of Phase 2.
- [x] 1.12 Full unit test suite green, including crash-safety
      (mid-write kill) tests. `cargo test --workspace` (64 tests) and
      `cargo test --workspace -- --ignored` (the real-benchmark KDF test
      and the crash-safety chaos test, both slow/deliberately excluded
      from the default run) all pass, clean under `cargo clippy
      --workspace --all-targets`, as of `a54643e`. Fuzz testing of
      the container parser and JSON-RPC parser (also called for by
      Phase 1 in spec §10) is deferred: the JSON-RPC parser doesn't
      exist yet (1.8), and container-parser fuzzing needs a fuzzing
      harness (e.g. `cargo-fuzz`) not yet wired up — tracked as
      outstanding, not silently skipped.

## Phase 2 — macOS (first fully shipped platform)

Not started. See spec §12 for the full item list (2.1–2.10).

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

Not started.

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
