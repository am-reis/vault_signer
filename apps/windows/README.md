# VaultSigner — Windows

Phase 3 target (spec §12, items 3.1–3.8). Not started — this is the
initial groundwork prepared before any Windows-side implementation
work, since that work happens on a Windows machine this repository
wasn't developed on. Everything in this file was actually run and
verified where stated; anything not verified says so explicitly.

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
3. `cargo build --release --manifest-path vaultcore/Cargo.toml --target x86_64-pc-windows-msvc` — confirm vaultcore itself builds for Windows before touching any C#/UI code. **Done, for real, on a real Windows machine — see PROGRESS.md's Phase 3 session-checkpoint entry.** Builds clean; `cargo test --workspace` is 117/117 green, including the new Windows `VirtualLock` memory-locking fix (`vaultcore/src/mem_lock.rs`, on the `shared` branch).
4. Run `Scripts/generate-csharp-bindings.ps1`, confirm `Generated/vaultcore.cs` compiles in a throwaway class library project before building anything on top of it. **Not yet done from this repo** — the session that did step 3 ran out of safe disk headroom before installing `uniffi-bindgen-cs`; see PROGRESS.md's exact resume steps.
5. Start on spec §12 items 3.1–3.8 in order — `PROGRESS.md` tracks status the same way it does for macOS's Phase 2. **`VaultSignerAgent/` (3.3-ish scope) and the start of `VaultSignerUI/` (3.1) exist**, written against the Rust source and macOS's proven Swift shape, but **not yet compiled** (blocked on step 4) — treat as a checkpoint, not verified progress, until they've actually built once real bindings exist.

## What's genuinely unverified

Cross-compiling vaultcore itself for `x86_64-pc-windows-msvc` **is now
verified** (see step 3 above) — that line from the previous version of
this file was wrong as of this session's real test. Still genuinely
unverified: whether `Generated/vaultcore.cs` actually compiles against
`VaultSignerAgent`/`VaultSignerUI`'s C# (method/type PascalCasing was
inferred, not confirmed against real `uniffi-bindgen-cs` output), and
everything about WinUI 3 actually running, the Windows background-agent
process actually serving real requests, DPAPI round-tripping for real,
and WebAuthn plugin-authenticator registration — none of that has been
run yet, only written. See PROGRESS.md for the exact next steps and why
this session stopped short of them (disk space, then a git-credentials
problem on the way to pushing).
