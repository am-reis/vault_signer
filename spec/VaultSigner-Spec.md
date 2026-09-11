---
title: Specification
---

# VaultSigner — Product & Engineering Specification (v3)

**Document type:** Execution specification for a development team (human or AI). Contains only instructions to execute, plus the engineering rationale needed to execute them correctly. Every section ends in either a concrete deliverable or a checklist item. Treat unchecked items in Section 12 as the resume point if work is interrupted.

**Status file convention:** maintain `PROGRESS.md` at the repo root, mirroring the checklist IDs in Section 12. Before starting work in any session, read `PROGRESS.md` first. After finishing a checklist item, update it and commit. Never mark an item done without a passing build/test artifact referenced by commit hash.

---

## 0. One-paragraph description

VaultSigner is a cross-platform application that stores cryptographic key material (FIDO2/WebAuthn authenticator credentials, and arbitrary user-defined signing keys) in an encrypted, portable container file. It runs a background service that listens for signature requests (OS-level WebAuthn/FIDO2 credential-provider calls, and a custom local IPC protocol for other apps), unlocks the relevant key on demand after a per-key password prompt, performs the requested signature, zeroes the key material after a user-configurable timeout, and shows minimal UI only when a decision or password is required. It is a cold-storage-style, offline-first container with export/import portability, combined with the role of a software FIDO2 security key.

---

## 1. Scope

### 1.1 In scope
- Local, offline-first storage of key material. No mandatory cloud sync. Any user-driven export to storage the user picks (file share, USB, cloud drive folder) is fine; the app never talks to a vendor server.
- FIDO2/WebAuthn authenticator role via each OS's official third-party credential-provider mechanism (Section 6).
- A custom signing protocol for non-browser apps (Section 7).
- Two-tier encryption: per-key passphrase (Argon2id) + container-level master key (Argon2id), detailed in Section 4.
- Manifest-driven key management UI: create, view (metadata only, never raw secret unless the user explicitly asks to reveal), discard, import, export (single key and multi-key packets).
- Cross-device packet portability, including three master-key merge strategies (Section 5.3) and three export-encryption strategies (Section 5.4).
- Configurable in-memory key retention timer with secure zeroing.
- Mandatory screen-capture / screenshot blocking on all sensitive UI surfaces (Section 5.0).
- Uniform brute-force throttling across every passphrase-entry surface (Section 3, Section 5.5).
- Atomic, crash-safe container writes (Section 4.6).
- Internationalization from the first commit (Section 9).

### 1.2 Non-goals
- Not a certificate authority, not a PKI issuer, not a blockchain wallet with transaction broadcasting, not a password manager for website login passwords. Only asymmetric signing keys/passkeys are managed (the manifest may store a note about which website a key is for).
- No telemetry, no analytics, no remote key escrow. Any future cloud feature is a separate, clearly-labeled opt-in module and out of scope here.
- No proprietary hardware dependency. This is a software-only authenticator and signer.
- RSA-2048 and ECDSA P-384 are not implemented in v1 (see Section 4.3). They are reserved for a future release and must not be exposed anywhere in the v1 schema or UI.

---

## 2. Technology stack

**Repository structure: single monorepo.** `vaultcore` is the sole implementation of the container format, KDF, AEAD, manifest schema, merge logic, and CTAP2/JSON-RPC handling. Every platform binds to the same compiled core via UniFFI — no platform may reimplement, port, or hand-mirror any parsing, merge, or cryptographic logic, even temporarily or for prototyping. Manifest/container types are defined once in `vaultcore` and generated outward through UniFFI bindings rather than hand-written per platform. This is a hard architectural constraint, not a style preference: it is what makes the cross-device merge logic (Section 5.3) safe to validate against a single implementation regardless of which platforms are built first.

**vaultcore**: a single Rust library implementing the container format, Argon2id KDF, AEAD encryption, the manifest, the custom signing protocol server, and CTAP2/WebAuthn message handling. Expose it to every platform through [UniFFI](https://github.com/mozilla/uniffi-rs) bindings (Swift, Kotlin, C#, C). vaultcore never renders UI and never owns a window; it is a pure logic/crypto/protocol library linked into each platform's native app and native background service.

**UI layer: fully native per platform**, not a shared cross-platform UI toolkit:
- macOS: SwiftUI + AppKit where native APIs are required (window capture exclusion, extension hosting).
- Windows: WinUI 3 (C#/.NET) or native Win32/C++ where COM-level plugin-authenticator registration requires it.
- Android: Kotlin + Jetpack Compose.
- iOS/iPadOS: SwiftUI, sharing Swift code with the macOS target where the underlying logic is identical (both call vaultcore through the same Swift bindings).
- Linux: GTK4 (via `gtk4-rs`, calling vaultcore directly with no FFI boundary needed since both are Rust-reachable).

Rationale: the FIDO2 credential-provider integrations (Section 6), the background service (Section 8), and screen-capture blocking (Section 5.0) all require direct native platform API access that a cross-platform UI toolkit would only wrap indirectly, if at all. Building each platform's UI natively against vaultcore keeps every platform's implementation independently shippable and testable, which matches the phased delivery order in Section 12 — the shared-core monorepo constraint above is what keeps "independently shippable" from turning into "independently reimplemented."

**Libraries (do not reimplement primitives):**
- Argon2id: the `argon2` Rust crate (RustCrypto). Use this implementation everywhere; do not mix KDF libraries across platforms.
- AEAD: `xchacha20poly1305` crate (RustCrypto), 256-bit keys, 24-byte random nonces.
- Signing algorithms: Ed25519 (`ed25519-dalek`) and ECDSA P-256 (`p256` crate) for v1. Ed25519 is the default for the custom protocol; P-256 is mandatory for FIDO2 compatibility (`ES256` is the baseline algorithm relying parties expect). ECDSA P-384 and RSA-2048 support is deferred; do not add crates for them until a future release scopes the work.
- FIDO2/CTAP2 protocol layer: base message parsing on the `ctap-types` crate lineage rather than writing CTAP2 parsing from scratch.
- Secure memory: `zeroize` crate for every buffer holding decrypted key material or passwords. `secrecy` crate to wrap sensitive types so they cannot be `Debug`-printed or accidentally logged.

---

## 3. Threat model (read before implementing any of Sections 4–8)

**Assets protected:** private key material, per-key and master passphrases, the manifest (contains resource names/URLs).

**In-scope adversaries:**
1. Attacker with read access to the exported packet file or the device's disk at rest (lost/stolen device, compromised backup location).
2. Malicious or compromised application on the same device attempting to trigger a signature without user consent, or attempting to read VaultSigner's process memory.
3. Network attacker — irrelevant to most flows since there are no outbound network calls; relevant to the custom protocol's local listener, which must never accept non-loopback connections.
4. Shoulder-surfing / clipboard-snooping during password entry, and screen capture of key material or passphrases (Section 5.0).

**Out of scope:** a fully compromised OS kernel, a malicious OS vendor, physical hardware attacks (cold-boot, chip-off). State this explicitly to users in the app's security page.

**Invariants that must hold in every code path (verified in Phase 7 review):**
- Decrypted private key bytes exist in memory only as long as strictly necessary, in `zeroize`-wrapped buffers, and are explicitly wiped (a) when the retention timer elapses, (b) immediately after use if retention is set to zero, (c) on app suspend/lock, (d) on process exit including crash handlers where feasible.
- The master key never touches disk in plaintext under any export option.
- No key material or manifest content is logged, including in crash reports. Diagnostic logs redact key IDs to opaque tokens.
- Every signature operation requires the per-key password (or a short per-key cached-unlock window bounded by the same retention timer). A valid master-key unlock alone is never sufficient to sign.
- Every passphrase-entry surface — master password, per-key passphrase, whether reached via FIDO2 (Section 6), the custom protocol (Section 7), or the reveal-raw-key action (Section 5.1) — enforces the same incremental-backoff throttling policy (Section 5.5). No entry point is exempt.
- Any write that mutates the container file (key creation/discard, manifest edits, `sign_count` increments) is atomic and crash-safe (Section 4.6). The vault must never be left in a partially-written or unreadable state by an interrupted write.
- Auto-unlock protection (Section 8) is documented per platform, not assumed equivalent across platforms: the strength of the OS secure-storage mechanism protecting the persisted unlock material varies by platform and must be disclosed accordingly.

---

## 4. Cryptographic design

### 4.1 Container structure

The `.vlt` file is a single portable archive (zip or tar+zstd — pick one and apply it consistently to `.vlt`, `.vltkey`, and `.vltpack`), internally structured as follows. The tree below describes the archive's internal layout, not a bare filesystem directory — implementations must never expose or rely on this structure as loose files on disk outside the archive.

```
Vault container (.vlt file, single archive, portable)
├── header (unencrypted, versioned)
│   ├── format_version
│   ├── kdf_params_master[]      -- one entry per master-key compartment, see 5.3 option 2
│   └── aead_alg ("xchacha20poly1305")
├── encrypted_master_blob[]      -- one per compartment
│   decrypts to:
│   ├── manifest.json  (see 4.4)
│   └── key_index (list of key_ids owned by this compartment)
└── key_blobs/
    └── <key_id>.kblob
        ├── kdf_params_key (Argon2id params + unique salt for this key)
        ├── aead_alg
        └── ciphertext = AEAD(key_passphrase_derived_key, raw_private_key || key_metadata_fingerprint)
```

Opening the vault (master password) reveals metadata only — never raw key material. A second, independent secret (the per-key passphrase) is required to decrypt any individual key. A leaked master password does not by itself grant signing capability.

### 4.2 Argon2id parameters

Do not hardcode a single fixed cost. Benchmark on first run per device and store the chosen parameters in the header so the same file remains openable later (verification uses the stored parameters).

- Minimum floor (never go below, even on low-power mobile): memory = 64 MiB, iterations = 3, parallelism = 1.
- Desktop target: memory = 256 MiB, iterations = 3, parallelism = 4 (benchmark to land at ~500ms–1s derivation time).
- Mobile target: memory = 64–128 MiB, iterations = 3, parallelism = 1–2 (benchmark to land at ~500ms–1s; cap allocation to avoid background-process termination by the OS, and document the cap in-app).
- Salts: 16 bytes, CSPRNG-generated, unique per KDF invocation — never reuse a salt across the master key and any key blob, or across key blobs.
- Store the benchmark result and chosen parameters in the header. Implement a "re-harden this vault" migration action that re-benchmarks on a new device and offers to upgrade parameters; never silently downgrade security when a vault is opened on a weaker device.

### 4.3 AEAD & signing algorithms

- Container/manifest encryption: XChaCha20-Poly1305 project-wide.
- Signing key types, v1: Ed25519 (default) and ECDSA P-256 (mandatory for FIDO2 `ES256`). These are the only key types the v1 schema (Section 4.4) may accept.
- Signing key types, future release (not v1): ECDSA P-384 and RSA-2048, to be added only if a specific relying party or user need requires them, and only once explicitly scoped as its own follow-on spec.
- Random number generation: OS CSPRNG only (`getrandom`/`SecRandomCopyBytes`/`BCryptGenRandom`) for salts, nonces, and key generation — never a userspace PRNG.

### 4.4 Manifest schema (JSON, inside the encrypted master blob)

```json
{
  "manifest_version": 1,
  "vault_id": "uuid-v4",
  "created_at": "ISO-8601",
  "keys": [
    {
      "key_id": "uuid-v4",
      "label": "user-provided name",
      "description": "free text, user-provided",
      "resource": "https://example.com",
      "key_type": "ed25519 | ecdsa-p256",
      "purpose": "fido2 | custom-signing | both",
      "fido2": {
        "rp_id": "example.com",
        "credential_id_b64": "...",
        "user_handle_b64": "...",
        "sign_count": 0,
        "discoverable": true
      },
      "created_at": "ISO-8601",
      "last_used_at": "ISO-8601 | null",
      "tags": ["work", "email"],
      "blob_file": "key_blobs/<key_id>.kblob",
      "blob_sha256": "hex digest for integrity check"
    }
  ]
}
```

`key_type` accepts only `ed25519` and `ecdsa-p256` in v1. Reject any other value at parse time; do not add `ecdsa-p384` or `rsa-2048` to this enum until a future manifest version explicitly scopes and versions that addition. The `fido2` block is present only if `purpose` includes `fido2`. `sign_count` is persisted and incremented on every assertion (CTAP2 requires this for relying-party clone detection). `blob_sha256` allows detecting a corrupted/truncated blob before an expensive Argon2id derivation and failed decrypt.

### 4.5 Memory-retention timer

- Configurable, in seconds, bounded range: minimum 0 (immediate wipe after single use), default 30, maximum 300 (five minutes). Do not implement an unbounded/"never" option. Surface this cap in the UI copy.
- Decrypted key material lives in a `zeroize`-wrapped struct owned by an in-process cache keyed by `key_id`, with an associated timer. On expiry, overwrite the buffer then drop it. On explicit lock, app suspend, or an OS screen-lock event (subscribe where the platform exposes one), wipe immediately regardless of the timer.
- Never persist this cache to disk. Use `mlock`/`VirtualLock`/`mlockall`-equivalent calls where the platform provides them to reduce the chance of plaintext key material being paged out.

### 4.6 Atomic, crash-safe writes

Every mutation to the container file (key creation, key discard, manifest edits, `sign_count` increments, master-key re-wrap during import) must be atomic:
- Write the new container state to a temporary file in the same directory, `fsync` it, then rename it over the original (`rename`/`ReplaceFile` as the platform's atomic-replace primitive). Never mutate the live container file in place.
- The background service is the single writer for the container file. The management UI process never writes the container directly; it requests mutations from the service over the same local-IPC mechanism used for signing (Section 8), and the service serializes writes. This removes the need for cross-process file locking.
- If a write is interrupted (crash, power loss), the vault must open successfully from either the pre-write or fully-completed post-write state — never a partial one. Include a fuzz/chaos test that kills the process mid-write and verifies the vault still opens (Section 10).

---

## 5. Key & vault management UI

### 5.0 Screen-capture prevention (mandatory, every platform, applies to any screen displaying key material, passphrases, manifest detail, or import/export decision screens)

This is a hard requirement, not a nice-to-have. Implement per platform as follows:

- **macOS:** set `sharingType = .none` on any `NSWindow` showing sensitive content; this excludes the window from screenshots, screen recording, and screen sharing.
- **Windows:** call `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` on the relevant window handle.
- **Android:** set `WindowManager.LayoutParams.FLAG_SECURE` on any Activity/Compose surface showing sensitive content; this also excludes the app from the Recents thumbnail and from screen recording.
- **iOS/iPadOS:** Apple provides no public API to block screenshots outright. Implement the standard mitigation used by finance apps: overlay the sensitive view with a `UITextField` configured `isSecureTextEntry = true` (its underlying secure layer is excluded from the capture pipeline), applied to the specific views rendering key material or passphrases. Additionally subscribe to `UIApplication.userDidTakeScreenshotNotification` and react by immediately blurring/hiding the screen and, where the sensitive content was a just-revealed raw key, treating it as compromised (prompt the user to consider rotating that key). Document this as a partial mitigation, not full prevention — this is a genuine iOS platform limitation, not an implementation gap.
- **Linux:** no standardized OS-level API exists across compositors. Implement best-effort: where the running compositor is Wayland and exposes a relevant protocol/portal for content protection, use it; on X11, there is no reliable mechanism. Document this as best-effort/unsupported in the Linux release notes.

This must be applied to: raw-key reveal screens, passphrase entry fields, the import master-key-duality decision screens, and any screen rendering a manifest in detail.

### 5.1 Core operations (manifest-level, no per-key password required)
- **View list**: label, resource, key type, purpose, last used. Never shows raw key material.
- **Create key**: choose type (Ed25519/P-256), purpose (fido2/custom/both), label, description, resource; set a per-key passphrase (Argon2id-hardened immediately, never held in plaintext beyond the moment of creation); generate the keypair in memory, encrypt, write the blob, update the manifest, zero the generation buffer.
- **Discard (delete) key**: two-step confirmation (type the label or resource to confirm), then securely delete the blob file (overwrite before unlink where the filesystem makes this meaningful; disclose in help text that this is best-effort on SSDs/copy-on-write filesystems) and remove the manifest entry.
- **Change key passphrase**: standalone action reachable from the key detail screen, independent of import/export. Required for every imported key to be re-secured with a locally-known passphrase.
- **Reveal raw key**: off by default, gated behind a "danger zone" warning dialog and the per-key passphrase, shown once with no clipboard auto-copy. Screen-capture blocking (5.0) applies to this screen. Subject to the same throttling policy as every other passphrase surface (5.5).

### 5.2 Export flows

Two export shapes:
1. **Single key export** — one `.vltkey` file: the same key-blob format used inside the container, self-contained, plus a small manifest fragment for that one key.
2. **Packet export** — a compressed archive (`.vltpack`, same archive format as `.vlt`) containing selected key blobs, the relevant manifest slice, and optionally the encrypted master key blob (5.2.1).

**5.2.1 "Include master key in export" toggle.** When enabled, the exported packet also contains the sender vault's `encrypted_master_blob` and its header/KDF parameters, so the receiving side can treat the imported packet as carrying its own master key (Section 5.3 defines how the destination handles this).

**5.2.2 Export encryption choice.** Present exactly these three options before finalizing any packet export:

| Option | UI label | Behavior |
|---|---|---|
| 1 | "Just package the keys as-is" | Keys remain encrypted only with their own existing per-key passphrases; no extra encryption layer is added. Packet is compressed but not additionally encrypted. **The accompanying manifest slice (labels, descriptions, resource/rp_id values) is not encrypted by this option and travels in the clear inside the packet.** Use only when the recipient already knows each key's passphrase and the transport channel itself is trusted; the UI must state plainly that metadata (which sites/services these keys are for) is not protected by this choice, only the key material is. |
| 2 | "Re-encrypt for the destination vault's master password" | Prompt the exporting user for the destination vault's master password. Derive a one-time wrapping key from that password and a fresh salt using the same Argon2id parameters, and wrap the packet — including the manifest slice — in an additional AEAD layer keyed off it. On import, the destination vault's own master password unlocks the packet directly. |
| 3 | "Protect with a one-time transfer password" | Prompt the exporter to set a new, packet-specific passphrase (shown once, with a copy action and a warning to deliver it to the recipient through a separate channel). Wrap the packet — including the manifest slice — in an additional AEAD layer keyed off this Argon2id-derived passphrase. |

Option 2 requires the exporting user to already know the destination's master password. State this plainly in the UI ("choose this only if you know the master password of the vault you're importing into").

### 5.3 Import flow and the master-key duality decision

When importing a `.vltpack`:
1. Decrypt the transfer/wrapping layer if present (prompt for the option-2/3 password; skip if option 1 was used).
2. Inspect the packet's manifest fragment. If it contains an embedded master-key blob (5.2.1), show an unskippable screen, before merging any keys, explaining in plain language that this import includes another vault's master key and that the user must choose what to do with it.
3. Present exactly three choices as three distinct large cards (not a dropdown), with no default pre-selected:

   - **Option 1 — Re-encrypt & discard incoming master key (default emphasis in UI styling).**
     Prompt for the incoming master key's password to unlock the incoming manifest fragment. Re-wrap the incoming manifest entries under the local vault's existing master key. Per-key blobs and their individual passphrases are unchanged (the per-key layer is independent of which master key wraps the manifest). Discard the incoming master-key blob entirely — do not retain it in memory or on disk past this operation. UI copy: "Your keys will only need your existing master password. The imported vault's master password will not be kept."

   - **Option 2 — Keep both master keys side by side.**
     Extend the local vault's `kdf_params_master`/`encrypted_master_blob` to a second compartment entry, each with its own KDF parameters, wrapping its own manifest sub-tree and referencing its own subset of `key_id`s (matches the multi-compartment header structure in 4.1). The vault-unlock screen must let the user select which compartment they are unlocking (label compartments, e.g. "Personal" / "Imported from Alice's laptop"). UI copy: "You'll keep two separate master passwords for this vault, one for each set of keys. Nothing is merged."

   - **Option 3 — Replace local master key with incoming master key.**
     Style this option distinctly (warning color, separate from the neutral styling of options 1–2). Copy: "This will replace the password protecting ALL your existing keys, including ones you did not just import, with a different password. If you don't have both passwords available right now, stop." Require the user to type a confirmation phrase (e.g., "REPLACE MY MASTER KEY") before the action becomes enabled. On confirm: unlock the local vault's existing manifest with the current local master password, re-encrypt the combined manifest (local + imported keys' metadata) under the incoming master key's Argon2id parameters and passphrase, and discard the old local master-key blob. Per-key blobs are untouched.

4. In all three options, incoming per-key blobs are copied into the local vault's `key_blobs/` directory unchanged (their own Argon2id-derived encryption is independent of any master key). The recipient can subsequently use the "change key passphrase" action (5.1) to re-secure any imported key with a locally-known passphrase.
5. After any import, run duplicate detection (matching `key_id`, or for FIDO2 keys matching `rp_id` + `credential_id`) and warn before overwriting an existing key with an imported one sharing the same ID. Default to "keep both, rename incoming" rather than silent overwrite.
6. Every import/merge code path above is implemented once in `vaultcore` (Section 2) and invoked identically by every platform's UI. No platform-specific merge logic is permitted.

### 5.4 Backup

- "Back up everything" is a full packet export of the entire local vault (all keys + manifest + master key blob) protected by one of the 5.2.2 options. Recommend option 3 in UI copy for backups going to general-purpose cloud storage; warn that option 1 is unsafe for a backup stored anywhere other than an already-encrypted local disk.
- Provide a "back up master key only" shortcut (header + master key blob, still Argon2id-protected) for users who store master-key recovery material separately (e.g., printed/QR-coded). Show an explicit warning that this alone does not protect anything, since the per-key blobs are also required.

### 5.5 Passphrase attempt throttling

- Applies uniformly to every passphrase-entry surface: master-password unlock, per-key passphrase entry (via FIDO2 assertion, the custom protocol, or the reveal-raw-key action), and export/import transfer-password entry.
- After N consecutive wrong attempts against a given secret (default 5), impose an increasing backoff delay before that same secret can be attempted again. Track attempt counts per secret (per key_id, or for the master key, per compartment), not globally, so a lockout on one key does not block unrelated operations.
- Backoff state is held in memory by the background service (Section 8) and is not required to survive a service restart, but must not be resettable by the calling application in the custom-protocol case — only by the elapsed backoff period.

### 5.6 Known vaults (remembering where a vault's file lives)

A vault file can live anywhere the user put it — there is no fixed, app-owned storage location (Section 4.1 deliberately describes the `.vlt` file as a portable archive, not a database the app manages internally). Without this section, that portability comes at a real usability cost: the app would have to ask the user to browse to the file's location on every single launch, which is the kind of friction that trains users to leave a vault unlocked longer than they should, or to stop using the app. This is not optional polish; treat it as part of the core management UI (Section 5.1), not a later enhancement.

- On every platform, the management UI maintains a **known-vaults list**: for each vault the user has created or opened, remember its file path (or platform-equivalent stable reference — e.g. a security-scoped bookmark where the OS sandbox requires one, rather than a bare path that can silently go stale) and the last time it was opened. This list is local device state, not vault content — it is never written into any `.vlt`/`.vltpack`/`.vltkey` file, never synced, and contains no passphrases or key material.
- The app's entry screen (shown when no vault is currently open) presents this list first, most-recently-opened first, each entry openable with one action rather than a file browse. Creating or opening a vault by any means (including a fresh browse, or opening a file handed to the app externally) adds or updates its entry in this list automatically.
- Provide a dedicated **management surface** (reachable both from the entry screen and from the app's settings, so it doesn't require closing whatever vault is currently open) where the user can: add a known vault by browsing to a file without opening it immediately, and remove ("forget") an entry. Forgetting an entry only removes it from this list — it must never delete, move, or modify the underlying vault file.
- Provide a way to close the currently-open vault and return to the entry screen without quitting the app, so switching between known vaults doesn't require relaunching. This does not require re-entering any credentials beyond what opening that vault normally requires.
- If a remembered path no longer resolves to a valid vault file (moved, deleted, or — on a sandboxed platform — a stale bookmark), show that entry as unavailable rather than silently dropping it or erroring the whole list; let the user re-locate or forget it.

---

## 6. FIDO2 / WebAuthn OS integration

"Automatic" response to a FIDO2 prompt means: no manual app-switching or copy-pasting by the user, and VaultSigner is offered as a first-class choice in the OS's native picker. It does not mean zero user interaction — CTAP2/WebAuthn requires user presence, and usually user verification, enforced by the relying party and, on most platforms, by the OS. Document this distinction in user-facing help content.

### 6.1 macOS
- Implement an `ASCredentialProviderExtension` target with `Info.plist` capability `ProvidesPasskeys = YES` (macOS 13+; treat earlier versions as unsupported).
- The extension is a separate process from the main app; link it against the same compiled vaultcore library so vault-opening logic is not duplicated.
- The main app must deep-link the user to System Settings → General → AutoFill & Passwords / Extensions, where the user enables VaultSigner as a credential provider.
- Apply screen-capture blocking (5.0) to every extension-hosted view showing passphrase entry or key detail.

### 6.2 Windows
- Register as a plugin authenticator via the Windows WebAuthn platform APIs (`WebAuthNGetPlatformCredentialList` / plugin-authenticator COM registration), so VaultSigner appears inside the native Windows Hello/WebAuthn UI shown by browsers and Windows sign-in surfaces.
- Implement this as a native Windows component (C++/C# COM server) run by the background service (Section 8), independent of whether the management UI process is running.
- Verify the exact current registration APIs and any driver-signing/developer-program requirements against current Microsoft documentation at implementation time.
- If plugin-authenticator registration is not achievable within the Phase 3 timebox, implement the browser-extension + native-messaging fallback (WebExtension talking to the local background service over the custom protocol, Section 7) and ship that instead. Do not ship Windows without a working FIDO2 path.

### 6.3 Android
- Implement `CredentialProviderService` (androidx.credentials, Android 14+/API 34+; treat earlier API levels as unsupported for the FIDO2 provider role).
- Respond to `beginGetCredentialRequest`/`beginCreateCredentialRequest` for `PublicKeyCredential` request types; surface entries in the system credential picker using the manifest's label/resource fields.
- On selection, launch a minimal passphrase-entry surface (Activity or inline auth flow) with `FLAG_SECURE` set, decrypt via vaultcore, sign the CTAP2/WebAuthn assertion structure, return via `PendingIntent`/`CreateCredentialResponse`.
- The app must include a button that opens Settings → Passwords & accounts via `createSettingsPendingIntent()` so the user can enable the provider.

### 6.4 iOS/iPadOS
- Reuse the `ASCredentialProviderExtension` target and capability from 6.1 (iOS 17+; treat earlier versions as unsupported), linked against the iOS build of vaultcore.
- iOS does not allow a persistent background daemon of the kind used on desktop/Android. The extension is invoked on demand by the OS; there is no always-running custom-protocol listener (Section 7 must be adapted — see 7.1).
- The main app must direct the user to Settings → Passwords/AutoFill & Passwords to enable VaultSigner as a provider.
- Apply the iOS screen-capture mitigation from 5.0 to every sensitive view in the extension and the main app.
- Cross-device/"hybrid" CTAP2 flows (using a phone to authenticate a session on a separate computer) may be reserved for iCloud Keychain on Apple platforms; verify current third-party participation support against Apple's documentation before committing to this flow in release notes.

### 6.5 Linux
- No standard OS-level third-party platform-authenticator API exists. Implement one of the following, chosen during Phase 6 (prototype both before committing if time allows):
  1. **Virtual CTAP2 HID device**: a Linux `uhid` virtual USB device presented to the kernel and browsers as a real roaming FIDO2 key, with a udev rule granting the background service the needed device-node permissions (avoid running the whole app as root).
  2. **Browser-extension + native-messaging fallback** (same shared component built for 6.2's fallback path).
- Document the chosen approach's install-time requirements clearly (e.g., a one-time udev rule installation prompting for elevated privileges).

### 6.6 Cross-cutting CTAP2 requirements (apply to every platform above)
- Implement full `authenticatorMakeCredential` and `authenticatorGetAssertion` semantics: user-verification flag handling, `sign_count` increment and persistence, `rp_id` matching, `excludeList`/`allowList` handling.
- Support the `hmac-secret` extension only if a concrete relying-party need arises; do not build it speculatively.
- Default to "none" attestation. Do not ship a batch attestation certificate/private key baked into the app.

---

## 7. Custom local signing protocol (for non-browser apps)

- **Transport (desktop and Android):** a Unix domain socket (macOS/Linux) or named pipe (Windows) or a loopback-only (`127.0.0.1`, never `0.0.0.0`) TCP port on a per-install random high port advertised via a well-known local file with owner-only permissions. Never accept non-loopback connections.
- **7.1 Transport (iOS):** since iOS does not support a persistent background listener, expose the custom protocol instead through an App Intents / Shortcuts-based interface and an App Group-shared request queue: a calling app that also implements the App Intents integration can hand off a signing request, which triggers the VaultSigner extension/app on demand for the passphrase prompt, then returns the signature. **This is a materially narrower discovery model than the desktop/Android socket:** on desktop/Android, a calling app needs no prior relationship with VaultSigner beyond opening the socket, whereas on iOS the calling app must itself pre-integrate the App Intent before it can hand off a request. Document this as a scoped-down capability specific to iOS, not merely a mechanical transport difference.
- **Message format:** JSON-RPC-style requests over the transport, e.g.:
  ```json
  { "method": "vaultsigner.sign", "params": { "key_id": "...", "message_b64": "...", "algorithm": "ed25519" }, "id": 1 }
  ```
  Response is either an error (`key_not_found`, `user_declined`, `passphrase_incorrect`, `key_locked_retry_later`) or `{ "result": { "signature_b64": "...", "public_key_b64": "..." } }`.
- **Discovery:** expose `vaultsigner.list_public_keys` (returns only `key_id`, `label`, `public_key_b64`, `resource`, never private material) so a calling app on desktop/Android can let its user pick a key without VaultSigner needing prior knowledge of that app. On iOS this discovery step happens through the App Intents integration described in 7.1 instead.
- **Authorization:** every `sign` call triggers the same password-prompt UI as FIDO2 (Section 6), displaying the calling process's identity before the passphrase field appears (e.g., "App 'Foo' wants to sign with key 'Deploy signing key' — enter passphrase"). Determine the caller's identity via OS-level means (peer credentials on Unix sockets, named-pipe client process lookup on Windows) — never trust a self-reported name in the JSON payload for this confirmation text. Apply screen-capture blocking (5.0) to this prompt.
- **Rate limiting:** subject to the general passphrase-throttling policy (Section 5.5): after N consecutive wrong passphrase attempts for a given key (default 5), impose an increasing backoff delay before that key can be attempted again.

---

## 8. Background service & autostart

- Implement a genuine OS-level background service/daemon per platform: `launchd` agent (macOS), Windows Service or Scheduled-Task-launched process with a tray icon (Windows), `systemd --user` unit (Linux), a foreground/bound service (Android). iOS has no equivalent; its extension model (6.4) is on-demand-launched by the OS instead.
- The service owns: FIDO2 listener registration, the custom-protocol listener (Section 7, where applicable), the in-memory key cache/retention timer (4.5), and is the sole writer of the container file (4.6). The management UI is a separate process the service can launch for password prompts, and which the user can independently open for management tasks; both communicate over the same local-IPC mechanism as Section 7, using an internal-only method namespace. The UI process requests container mutations from the service rather than writing the file itself. **The service must never hold more than one instance of the vault's decrypted state at a time** — if the management UI process were to open its own separate copy alongside the service's, the two would diverge (e.g. a compartment unlocked in one is invisible to the other), and any third-party app using Section 7's protocol would observe stale or incorrect state. The service's copy is authoritative; the UI holds none of its own.
- **The internal-only method namespace must authenticate its caller, not merely require it to reach the local socket.** A Unix domain socket's owner-only file permissions (Section 7) restrict *reachability* to processes running as the same OS user — they do not by themselves distinguish the legitimate management UI from any other same-user process. Verify the connecting process's identity via an OS-level, code-identity mechanism (e.g. macOS: `SecCode`/code-signing checks against the management UI's known signing identity and bundle identifier; Windows/Linux: an equivalent process-identity or capability check), not a self-reported name or the mere fact of a successful connection. A narrower, explicitly-marked bootstrap exception for automated testing (never reachable in a release build) is acceptable, mirroring Section 10's testing requirements.
- Provide two independent settings toggles:
  - "Start VaultSigner at login/startup" (background listener) — default on, disclosed clearly at first run, since the FIDO2/signing availability depends on it.
  - "Auto-unlock on startup" — default off, requires explicit opt-in with an in-app risk explanation, since it means a decryption path to the master key persists across a boot without user input. When enabled, the unlock material itself must be protected by the platform's secure storage (Keychain/DPAPI/Keystore), never stored as a plaintext copy of the master password.
- **Auto-unlock protection strength differs meaningfully by platform and must be disclosed as such in the risk explanation:**
  - macOS Keychain and Android Keystore can scope decryption to the requesting app/process (Keystore additionally offers hardware-backing and optional biometric gating). These provide real protection against adversary #2 (a malicious co-resident app).
  - Windows DPAPI in its default (CurrentUser) scope is decryptable by any process running as the same OS user account — it does not by itself protect against a malicious co-resident app the way Keychain/Keystore can. Where feasible, use a CNG/TPM-backed key (or Windows Hello–gated protection) instead of plain DPAPI for the auto-unlock material; if plain DPAPI is used, the in-app risk explanation for Windows must state this limitation explicitly rather than implying parity with macOS/Android.
- Configure OS-level restart-on-failure for the background service (`Restart=on-failure` for systemd, `KeepAlive` for launchd, Windows Service recovery options). On restart, the vault is locked again unless auto-unlock is enabled.

---

## 9. Internationalization

- Maintain a single source-of-truth set of ICU MessageFormat resource files in the repository; generate each platform's native format from it (`.strings` for Apple targets, `strings.xml` for Android, `.resx`/equivalent for Windows, `.po`/gettext for Linux).
- Externalize every user-facing string from the first commit, including the import/export decision screens in 5.3. Add a CI lint that fails the build on hardcoded UI literal strings outside the resource files.
- Store timestamps as ISO-8601 internally; format for display only, using locale-aware formatting in the UI layer.
- Verify right-to-left layout specifically on the import/export decision screens, since they are dense, multi-choice, and safety-critical.
- Launch language set is a product decision made outside this document; the resource-file architecture must support adding locales without code changes.

---

## 10. Testing & security review requirements (gate before any release)

- Unit tests: KDF parameter roundtrip, AEAD encrypt/decrypt roundtrip including tamper detection (flip a ciphertext byte, expect decryption failure, not silent corruption), manifest merge logic for all three import options, `sign_count` monotonicity.
- Since every platform links the same `vaultcore` binary (Section 2), the three-way merge logic (5.3) and the container/packet format are exercised in full by this shared unit suite and by Phase 2's self-import/export tests — no platform-specific reimplementation of this logic exists to diverge.
- Crash-safety test: kill the background service process mid-write to the container file and verify the vault still opens correctly afterward (4.6).
- Memory-zeroing verification: since inspecting process memory in a portable unit test is impractical, verify via a code-review checklist plus `zeroize`'s compile-time guarantees, and at least one manual/instrumented test per release on at least one platform.
- Interop tests: register and authenticate against at least two to three real-world relying parties per platform, using an actual browser (not a mock relying party), before marking FIDO2 support complete on that platform.
- Fuzz-test the container-file parser and the custom-protocol JSON parser. Malformed or truncated inputs must fail closed, never crash the background service.
- Throttling test: verify the backoff policy (5.5) triggers correctly across all three entry points (master password, per-key passphrase, transfer password) and does not reset except by elapsed time.
- Independent security review of Sections 3, 4, and 6 before any public release.

---

## 11. Repository layout

Single monorepo (Section 2); no vaultcore logic is duplicated into any `/apps/*` directory.

```
/vaultcore/                                 Rust core: container format, KDF, AEAD, manifest, CTAP2 logic, protocol server
/apps/macos/                                SwiftUI app + ASCredentialProviderExtension + launchd service
/apps/windows/                              WinUI 3 / native app + plugin-authenticator COM component + Windows Service
/apps/android/                              Kotlin/Compose app + CredentialProviderService + foreground service
/apps/ios/                                  SwiftUI app + ASCredentialProviderExtension + App Intents integration
/apps/linux/                                GTK4 app + systemd user unit + virtual-CTAP2 or extension fallback
/platform/browser-extension-fallback/       Shared WebExtension + native-messaging host (Windows/Linux fallback path)
/i18n/                                      Shared ICU resource source-of-truth + per-platform generation scripts
/docs/security-review/                      Findings and sign-off records from Section 10
PROGRESS.md                                 Checklist state (mirrors Section 12)
```

---

## 12. Execution plan (phased, resumable, strictly platform-sequential)

Each platform phase must produce a complete, independently functional, demonstrable system on that platform — vaultcore integration, background service, FIDO2 provider registration, custom protocol, and management UI, including screen-capture blocking and the import/export/master-key-duality flows — before the next platform phase begins. Order: **macOS → Windows → Android → iOS → Linux.**

**Phase 0 — Decisions**
- [ ] 0.1 Confirm UniFFI binding generation setup for Swift/Kotlin/C#/C targets.
- [ ] 0.2 Confirm minimum supported OS version per platform (this spec assumes macOS 13+, Windows 10 2004+/11, Android 14+, iOS 17+; no fixed floor set yet for Linux distributions — confirm against target-user data before Phase 1 ends).
- [ ] 0.3 Confirm monorepo workspace tooling (Cargo workspace for `vaultcore` plus per-platform build orchestration) so no platform app can vendor or fork core logic.

**Phase 1 — vaultcore (shared, built once, platform-agnostic)**
- [ ] 1.1 Container header read/write and versioning (4.1), including atomic write-temp-then-rename semantics (4.6).
- [ ] 1.2 Argon2id KDF wrapper with per-device benchmarking (4.2).
- [ ] 1.3 AEAD encrypt/decrypt for manifest and key blobs, with tamper tests.
- [ ] 1.4 Manifest schema (4.4) with serde (de)serialization and JSON schema validation, restricted to v1's `key_type` values.
- [ ] 1.5 Key generation for Ed25519 and ECDSA P-256.
- [ ] 1.6 In-memory retention cache with `zeroize` and configurable timer (4.5).
- [ ] 1.7 CTAP2 message handling (`authenticatorMakeCredential`, `authenticatorGetAssertion`) as a platform-agnostic library function, to be invoked by each platform's extension/service.
- [ ] 1.8 Custom protocol JSON-RPC handling (Section 7) as a platform-agnostic library function.
- [ ] 1.9 Passphrase-attempt throttling (5.5) implemented once in vaultcore and invoked by every entry point.
- [ ] 1.10 Three-way merge logic (5.3) implemented and unit-tested against synthetic multi-compartment vaults.
- [ ] 1.11 UniFFI bindings generated and verified callable from a minimal Swift, Kotlin, and C# test harness.
- [ ] 1.12 Full unit test suite green, including crash-safety (mid-write kill) tests.

**Phase 2 — macOS (first fully shipped platform)**
- [ ] 2.1 SwiftUI management UI: open/create vault, list/create/discard keys, change-passphrase action, reveal-raw-key danger-zone flow.
- [ ] 2.2 Screen-capture blocking (5.0) applied to every sensitive view.
- [ ] 2.3 Export flows (5.2) with all three encryption-choice options, including the explicit metadata-exposure disclosure for option 1.
- [ ] 2.4 Import flow with all three master-key duality options and mandatory warning screens (5.3), including the multi-compartment unlock selector.
- [ ] 2.5 Backup flows (5.4).
- [ ] 2.6 `launchd` background service hosting the custom-protocol listener and retention cache (Section 8), with the two independent autostart/auto-unlock toggles and the Keychain-backed auto-unlock disclosure.
- [ ] 2.7 `ASCredentialProviderExtension` (6.1) registered and verified against at least two real relying parties in Safari and Chrome.
- [ ] 2.8 Custom protocol (Section 7) verified against a minimal test client app.
- [ ] 2.9 i18n resource-file scaffolding wired up, at least one locale populated.
- [ ] 2.10 macOS build passes the Phase 10 test/fuzz suite, including self-import/export exercising the shared merge logic.
- [ ] 2.11 Known-vaults list (5.6): entry screen shows remembered vaults most-recently-opened first, each openable in one action; a management screen (reachable from both the entry screen and Settings) to add a vault by browsing without opening it and to forget entries; a way to close the current vault and return to the entry screen without quitting.
- [ ] 2.12 `docs/user-guide.md` written (this is the first platform, so this is authoring it, not just reconciling it) and verified against the real, shipped macOS UI (Section 14).
- [ ] 2.13 `apps/macos/docs/protocol-integration.md` written: macOS's real transport/discovery details and a working code example, linked from `docs/protocol-integration/README.md`'s platform-guides list (Section 14).
- [ ] 2.14 Documentation site rebuilt and published (`Scripts/build-docs-site.sh`, from a branch with this phase's docs merged in) including this phase's new/changed docs (Section 14).

**Phase 3 — Windows**
- [ ] 3.1 WinUI 3 (or native) management UI, mirroring 2.1–2.5 functionality.
- [ ] 3.2 Screen-capture blocking via `SetWindowDisplayAffinity` (5.0) applied to every sensitive window.
- [ ] 3.3 Windows Service hosting the custom-protocol listener and retention cache, with autostart/auto-unlock toggles and the DPAPI-limitation disclosure (Section 8).
- [ ] 3.4 Plugin-authenticator COM registration (6.2) attempted; if infeasible within timebox, implement and ship the browser-extension fallback instead, documented as such.
- [ ] 3.5 FIDO2 path verified against at least two real relying parties.
- [ ] 3.6 Custom protocol verified against a minimal test client app.
- [ ] 3.7 i18n parity with macOS build.
- [ ] 3.8 Windows build passes the Phase 10 test/fuzz suite.
- [ ] 3.9 `docs/user-guide.md` reconciled against the real, shipped Windows UI — same content, verified accurate for Windows, with a per-platform addendum only where the flow genuinely differs from macOS (Section 14).
- [ ] 3.10 `apps/windows/docs/protocol-integration.md` written: Windows's real transport/discovery details and a working code example, linked from `docs/protocol-integration/README.md`'s platform-guides list (Section 14).
- [ ] 3.11 Documentation site rebuilt and published (`Scripts/build-docs-site.sh`, from a branch with this phase's docs merged in) including this phase's new/changed docs (Section 14).

**Phase 4 — Android**
- [ ] 4.1 Compose management UI mirroring 2.1–2.5 functionality.
- [ ] 4.2 `FLAG_SECURE` applied to every sensitive Activity/Compose surface (5.0).
- [ ] 4.3 Foreground service hosting the custom-protocol listener and retention cache, with autostart/auto-unlock toggles.
- [ ] 4.4 `CredentialProviderService` (6.3) registered and verified against at least two real relying parties in a mobile browser and at least one native app using Credential Manager.
- [ ] 4.5 Settings deep link via `createSettingsPendingIntent()`.
- [ ] 4.6 Custom protocol verified against a minimal test client app.
- [ ] 4.7 i18n parity with prior builds.
- [ ] 4.8 Android build passes the Phase 10 test/fuzz suite.
- [ ] 4.9 `docs/user-guide.md` reconciled against the real, shipped Android UI, with a per-platform addendum only where the flow genuinely differs (Section 14).
- [ ] 4.10 `apps/android/docs/protocol-integration.md` written: Android's real transport/discovery details and a working code example, linked from `docs/protocol-integration/README.md`'s platform-guides list (Section 14).
- [ ] 4.11 Documentation site rebuilt and published (`Scripts/build-docs-site.sh`, from a branch with this phase's docs merged in) including this phase's new/changed docs (Section 14).

**Phase 5 — iOS/iPadOS**
- [ ] 5.1 SwiftUI management UI, reusing macOS Swift code where the underlying logic is identical.
- [ ] 5.2 iOS screen-capture mitigation (secure-field overlay + screenshot-notification handling) applied to every sensitive view (5.0).
- [ ] 5.3 `ASCredentialProviderExtension` (6.4) registered and verified against at least two real relying parties in Safari.
- [ ] 5.4 App Intents / Shortcuts-based adaptation of the custom protocol (7.1) implemented and verified against a minimal test client app, with the narrower discovery model documented in-app.
- [ ] 5.5 Import/export/master-key-duality flows verified end-to-end on-device.
- [ ] 5.6 i18n parity with prior builds.
- [ ] 5.7 iOS build passes the Phase 10 test/fuzz suite.
- [ ] 5.8 `docs/user-guide.md` reconciled against the real, shipped iOS/iPadOS UI, including the App Intents-based custom-protocol handoff's own addendum paragraph (7.1) this section already calls out (Section 14).
- [ ] 5.9 `apps/ios/docs/protocol-integration.md` written: iOS's real (materially narrower, App Intents-based) discovery/integration model and a working example, linked from `docs/protocol-integration/README.md`'s platform-guides list (Section 14).
- [ ] 5.10 Documentation site rebuilt and published (`Scripts/build-docs-site.sh`, from a branch with this phase's docs merged in) including this phase's new/changed docs (Section 14).

**Phase 6 — Linux**
- [ ] 6.1 GTK4 management UI mirroring 2.1–2.5 functionality.
- [ ] 6.2 Best-effort screen-capture mitigation (5.0) applied and its limitations documented.
- [ ] 6.3 `systemd --user` unit hosting the custom-protocol listener and retention cache, with autostart/auto-unlock toggles.
- [ ] 6.4 FIDO2 path (6.5): prototype virtual-CTAP2-HID and browser-extension approaches, select one, implement, verify against at least two real relying parties.
- [ ] 6.5 Custom protocol verified against a minimal test client app.
- [ ] 6.6 i18n parity with prior builds.
- [ ] 6.7 Linux build passes the Phase 10 test/fuzz suite.
- [ ] 6.8 `docs/user-guide.md` reconciled against the real, shipped Linux UI, with a per-platform addendum only where the flow genuinely differs (Section 14).
- [ ] 6.9 `apps/linux/docs/protocol-integration.md` written: Linux's real transport/discovery details and a working code example, linked from `docs/protocol-integration/README.md`'s platform-guides list (Section 14).
- [ ] 6.10 Documentation site rebuilt and published (`Scripts/build-docs-site.sh`, from a branch with this phase's docs merged in) including this phase's new/changed docs (Section 14).

**Phase 7 — Cross-platform security hardening & review**
- [ ] 7.1 Memory-zeroing code-review pass across every FFI boundary on every platform (native code copying bytes out of Rust buffers is the highest-risk leak point).
- [ ] 7.2 Fuzz testing of the container parser and JSON-RPC parser (if not already integrated per-platform in Phases 2–6).
- [ ] 7.3 Independent security review of Sections 3/4/6, findings recorded in `/docs/security-review/`.
- [ ] 7.4 Clipboard/UI leak review across all five platforms: no unintended plaintext in logs, crash reports, or OS "recent apps" surfaces.
- [ ] 7.5 Verify the auto-unlock disclosure text on each platform accurately reflects that platform's actual secure-storage guarantee (Section 8).

**Phase 8 — i18n completion & release polish**
- [ ] 8.1 All UI strings externalized across all five platforms; CI lint enforced.
- [ ] 8.2 RTL verification of import/export screens on every platform.
- [ ] 8.3 Additional target locales translated.
- [ ] 8.4 First-run disclosure screens finalized on every platform (autostart default, no-telemetry statement, plain-language threat-model summary).
- [ ] 8.5 Final cross-platform documentation consistency sweep (Section 14) — not the first pass at any of this (each of Phases 2-6 already required its own user guide, protocol integration addendum, and docs-site publish as that platform shipped); this item catches drift *between* platforms' addenda that individual phases, done in sequence, couldn't have caught (e.g. two platforms' addenda describing the same underlying behavior inconsistently, or a wording fix made on one platform's addendum that should have propagated to the shared core text).

---

## 13. Open questions to resolve during Phase 0 (do not silently assume answers)

1. Timeline for a future release adding ECDSA P-384 / RSA-2048 support (out of scope for v1; see Sections 1.2, 4.3, 4.4).
2. Final choice between virtual-CTAP2-HID and browser-extension approaches for Linux (6.5) — decide during Phase 6, not earlier, once real-world testing data from Phases 2–5 is available.
3. Minimum supported Linux distribution/version floor.
4. Localization launch-language list.
5. Whether Windows auto-unlock should require CNG/TPM-backed protection or Windows Hello gating as a hard requirement, or ship with plain DPAPI plus a stronger in-app disclosure for v1 (Section 8).

---

## 14. User-facing documentation

Everything above this section specifies the product for the people building it. This section specifies a second, much shorter deliverable for the people *using* it — most of whom have never heard of FIDO2, don't know what a "master key" is, and never will need to. Building the software correctly does not by itself make it usable by that audience.

**Audience and tone.** Write for someone who wants to store a password-like secret or a signing key safely and has no interest in why the cryptography works. Never explain Argon2id, AEAD, CTAP2, key derivation, or the master-key/per-key distinction in cryptographic terms. Where the two-secret design (Section 3) has a practical consequence a user must act on — "this key needs its own passphrase, separate from your vault password" — state the consequence and the action, not the reason. If a sentence would only make sense to someone who has read Sections 3–8, delete it and replace it with the instruction the user actually needs.

**Scope: what this guide covers.** One short document (or a small set of them, if per-platform screenshots make that cleaner) walking through, task by task:
- Creating a vault for the first time, and what the vault/master password is *for* in one plain sentence ("this protects the list of your keys — not the keys themselves").
- Creating a key, and why it asks for a second passphrase.
- Using a key day to day: the FIDO2/passkey prompt, and the "an app wants to sign something" prompt (Sections 6–7) — what the user will see and what to click, not how the protocol underneath works.
- Revealing a raw key: why it's gated behind a warning, and that doing it carelessly is genuinely risky (say this plainly, without alarmism).
- Exporting/importing/backing up (Section 5.2–5.4): phrased as "sending a key to another device" and "making a copy in case something goes wrong," with the three encryption choices (5.2.2) described by their practical effect ("anyone with this file can read what it's for" / "only someone with the other vault's password" / "only someone you give this one-time password to"), not by name.
- The master-key-duality import screen (5.3): what the three cards mean for the user *doing the import*, phrased as consequences ("your imported keys will use your existing password" / "you'll have two separate passwords now" / "this replaces your current password everywhere"), not as a merge-logic explainer.
- The autostart and auto-unlock settings (Section 8): what turning each on actually changes for the user, in the same plain terms as the in-app disclosure copy those settings already require — this guide and that in-app copy should agree, not diverge.
- What happens if a password is forgotten: state plainly that it cannot be recovered by design, and what that means the user loses.

**Scope: what this guide does not cover.** Anything in Sections 2–4 and 6 (algorithms, wire formats, the threat model's adversary classes, protocol internals). If a reviewer needs that, Sections 2–4 and 6 are the reference, not this guide.

**Where it lives, and how it stays current.** One `docs/user-guide.md` at the repository root, written platform-generically (referring to actions like "the Settings screen" or "the Create Key button" rather than platform-specific chrome), with a short per-platform addendum only where the flow genuinely differs (e.g. iOS's App Intents-based custom-protocol handoff, Section 7.1, is a different enough experience to need its own paragraph). Treat it the same way as the in-app first-run disclosure screens (Phase 8 item 8.4): both are user-facing explanations of the same behavior, and a change to one that isn't reflected in the other is a bug. Update it as part of finishing each platform phase (Section 12's Phases 2–6), not as a single end-of-project task — a guide written once at the end tends to describe the UI as it was, not as it shipped.

**Two sibling deliverables travel with this guide, on the same per-phase cadence, for the same reason (written once at the end describes the UI as it was, not as it shipped):**
- **The developer-facing protocol integration guide** (`docs/protocol-integration/README.md`'s platform-agnostic core, plus one `apps/<platform>/docs/protocol-integration.md` addendum per platform covering that platform's real transport, discovery, and a working code example — see `apps/macos/docs/protocol-integration.md` for the shape). A platform phase whose custom-protocol item (2.8/3.6/4.6/5.4/6.5) is done but whose addendum isn't written is not actually done — a third-party developer on that platform has nothing to build against yet.
- **The published documentation site** (`Scripts/build-docs-site.sh`, publishing to the `gh-pages` branch): add that platform's new docs (README, protocol-integration addendum) to the script's file list, then run it and push `gh-pages`, from a branch with every completed platform's docs actually merged in (staging, release, or main — never `shared` alone, which never receives platform-only paths). Skipping this leaves the public site silently behind what's actually shipped.

Section 12's per-phase checklists carry the enforcement for all three of these (each of Phases 2-6 ends with a documentation trio: user guide, protocol integration addendum, docs site) — a phase is not complete while any of them is unchecked.
