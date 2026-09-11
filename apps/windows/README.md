---
title: Windows Developer Notes
---

# VaultSigner — Windows

Phase 3 target (spec §12, items 3.1–3.11). Core functionality is real
and verified: the management UI (`VaultSignerUI`, WinUI 3), the
background agent (`VaultSignerAgent`) hosting the named-pipe custom
protocol and retention cache, vault/compartment/key lifecycle,
export/import/merge/backup, screen-capture blocking, a Settings screen
(autostart + DPAPI auto-unlock, both agent-side and UI), and
reveal-raw-key/single-key-export UI are all built, built clean, and
exercised live against a real vault on a real Windows machine — see
`PROGRESS.md`'s Phase 3 session checkpoints for exactly what was
verified and how. Release packaging exists too: `Scripts/build-staging.ps1`
and `Scripts/package-release.ps1` (mirroring macOS's pair — see
CLAUDE.md's Release artifacts section for the artifact-naming
convention), both run live end-to-end, not just written. Still open:
FIDO2 plugin-authenticator registration (3.4, blocked on this VM's
Windows build being behind the Plugin Authenticator API's minimum —
see PROGRESS.md), i18n (3.7, no locale work started), and the Phase 10
test/fuzz suite (3.8). This file covers setup/architecture for someone
building this app from source; everything in it was actually run and
verified where stated, and anything not verified says so explicitly.

No Windows machine on hand? [`docs/qemu-vm-setup.md`](docs/qemu-vm-setup.md)
covers running one on Debian via QEMU/OVMF/swtpm (UEFI + Secure Boot +
a software TPM, so Windows Hello and the WebAuthn platform
authenticator actually work), driven from the CLI and reached over
SSH + VNC.

## Architecture (mirrors macOS's Phase 2 shape — see `apps/macos/README.md`)

Per spec §2, all cryptographic and protocol logic lives in `vaultcore`
(Rust) — nothing here reimplements the container format, KDF, AEAD,
CTAP2, or the custom-protocol message layer. This app is a thin native
shell around it:

- **Management UI** (spec §12 item 3.1) — WinUI 3 (or another native
  toolkit), mirroring `apps/macos/VaultSigner`'s screens.
- **Background service** (spec §12 item 3.3) — a real Windows Service
  hosting the custom-protocol listener (spec §7: a named pipe, not a
  Unix socket) and the retention cache, mirroring
  `apps/macos/VaultSignerAgent`. Per spec §8's architecture the service
  is the sole owner of vault state; the UI talks to it over an
  authenticated internal namespace, not by opening the container
  itself — see `CLAUDE.md`'s branch-model doc, which documents this
  exact requirement (added after macOS initially got this wrong and
  had to be redesigned).
- **FIDO2** (spec §6.2) — register as a Windows WebAuthn plugin
  authenticator so VaultSigner appears in the native Windows Hello UI.
  **Read spec §6.2 closely before starting this**: it explicitly calls
  out verifying "any driver-signing/developer-program requirements
  against current Microsoft documentation at implementation time," and
  mandates a browser-extension + native-messaging fallback if plugin
  registration isn't achievable in-budget — "do not ship Windows
  without a working FIDO2 path." macOS's equivalent (the
  `ASCredentialProviderExtension`) turned out to need a paid Apple
  Developer Program membership, confirmed only after real, empirical
  testing — budget time to verify Windows's actual requirement the same
  way, rather than assuming it'll be simpler.
- **Auto-unlock** (spec §8) — DPAPI-backed. Spec §8 is explicit that
  DPAPI's default (CurrentUser) scope is weaker than macOS
  Keychain/Android Keystore — decryptable by *any* process running as
  the same Windows user, not scoped to this app specifically. Use a
  CNG/TPM-backed key or Windows Hello–gated protection where feasible;
  if plain DPAPI is used, the in-app risk explanation must state this
  limitation explicitly, not imply parity with macOS.

## Prerequisites

- **Rust** with the `x86_64-pc-windows-msvc` target (`rustup target add x86_64-pc-windows-msvc`).
- **.NET 8 SDK or newer.** This is a hard requirement, not a
  recommendation — confirmed directly (see below), the generated C#
  bindings use C# 12 syntax that a .NET 7 or earlier SDK's compiler
  cannot parse at all.
- Visual Studio 2022 (for WinUI 3) or VS Code with the C# Dev Kit.

## Generating the C# bindings

`uniffi` (vaultcore's own dependency) does not generate C# bindings —
verified directly: `cargo run --bin uniffi-bindgen -- generate --help`
lists only `kotlin`, `swift`, `python`, `ruby`. C# needs the separate
community tool
[`uniffi-bindgen-cs`](https://github.com/NordSecurity/uniffi-bindgen-cs),
pinned to the exact uniffi-rs version vaultcore uses:

```
cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.10.0+v0.29.4
```

Then run `Scripts/generate-csharp-bindings.ps1` (from this directory).
That script's own header comment has the full detail on what was
actually verified: this tool does support library mode (reading
vaultcore's compiled `.dll` directly, the same proc-macro-only
approach every other platform uses — no `.udl` file), producing a real,
complete `vaultcore.cs`. It compiled clean under `dotnet build` **once
the syntax issue below is accounted for**:

**The one real blocker found, and the fix:** the generated bindings use
C# 12 collection-expression syntax (`return [];`) throughout. Building
that against a .NET 7 SDK fails with `error CS1525: Invalid expression
term '['` on every such line — this isn't a configuration flag to flip,
the older SDK's compiler genuinely cannot parse that syntax. It builds
correctly under .NET 8+.

## Getting started

1. `git clone` the repo, `git checkout platform/windows`.
2. Install the prerequisites above.
3. `powershell -File Scripts/generate-csharp-bindings.ps1` — builds
   vaultcore release and regenerates `Generated/vaultcore.cs` from it.
4. Build and run directly for iterative dev work: `dotnet build` each
   of `VaultSignerAgent/` and `VaultSignerUI/VaultSignerUI/`, then
   launch `VaultSignerAgent.exe` followed by `VaultSignerUI.exe` from
   their respective `bin\Debug\...\win-x64\` output folders (two
   separate processes — the UI doesn't launch the agent for you yet).
5. For a realistic, Release-configuration install instead:
   `powershell -File Scripts/build-staging.ps1` — builds vaultcore
   release, regenerates bindings, publishes both projects
   self-contained, and installs them to `%LOCALAPPDATA%\VaultSigner\`
   (`Agent\` and `UI\` subfolders — kept separate on purpose; see that
   script's own comments for a real, hit-live bug this avoids). Then
   `powershell -File Scripts/package-release.ps1 <vX.Y.Z> <vA.B.C>`
   zips that install into the two artifacts CLAUDE.md's Release
   artifacts section documents.

## What's genuinely unverified

Kept current as of the release-packaging-scripts checkpoint in
`PROGRESS.md` (Phase 3) — check there for anything newer than this
file, rather than trusting a summary here that will only go stale
again. Currently open: FIDO2 plugin-authenticator registration (3.4,
blocked on this VM's Windows build version), i18n (3.7, not started),
and the Phase 10 test/fuzz suite (3.8). One known tooling limitation,
not a product gap: `System.Windows.Automation` can't reliably drive a
`PasswordBox` inside a dynamically-created `ContentDialog` (WinUI3
doesn't expose a settable value to automation for password fields) —
confirmed by testing the same agent calls via a raw pipe instead, which
worked immediately, so this only affects UI-Automation-driven testing,
not the app itself.
