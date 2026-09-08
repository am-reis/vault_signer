# Builds vaultcore's release cdylib and generates its C# UniFFI
# bindings into apps/windows/Generated/.
#
# uniffi (the vaultcore dependency itself) does not generate C#
# bindings — confirmed directly: `uniffi-bindgen generate --help` only
# lists kotlin/swift/python/ruby. C# needs the separate community tool
# uniffi-bindgen-cs (https://github.com/NordSecurity/uniffi-bindgen-cs),
# pinned to the exact uniffi-rs version vaultcore uses (0.29 — check
# vaultcore/Cargo.toml if this drifts):
#
#   cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.10.0+v0.29.4
#
# Verified from a real generate-and-compile pass: it does support
# library mode (reading the compiled cdylib directly, matching how
# vaultcore is used everywhere else — no .udl file, proc-macro
# `#[uniffi::export]` only). The generated code uses C# 12 syntax
# (collection expressions, e.g. `return [];`) — this REQUIRES the
# .NET 8 SDK or newer to compile. A .NET 7 SDK will fail with
# "error CS1525: Invalid expression term '['" on every such line —
# confirmed by trying it, not assumed.
#
# Run this manually whenever vaultcore's `#[uniffi::export]` surface
# changes, mirroring apps/macos/Scripts/generate-bindings.sh's role for
# the Swift bindings.
#
# Usage: powershell -File Scripts/generate-csharp-bindings.ps1
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsAppDir = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent (Split-Path -Parent $WindowsAppDir)
$VaultcoreDir = Join-Path $RepoRoot "vaultcore"
$OutDir = Join-Path $WindowsAppDir "Generated"

Write-Host "generate-csharp-bindings.ps1: building vaultcore (release, uniffi feature)..."
cargo build --release --manifest-path "$VaultcoreDir\Cargo.toml" --features uniffi

$Dylib = Join-Path $RepoRoot "target\release\vaultcore.dll"
if (-not (Test-Path $Dylib)) {
    Write-Error "generate-csharp-bindings.ps1: expected $Dylib to exist after build"
    exit 1
}

Write-Host "generate-csharp-bindings.ps1: generating C# bindings into $OutDir..."
Remove-Item -Recurse -Force $OutDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $OutDir | Out-Null
uniffi-bindgen-cs --library $Dylib --out-dir $OutDir

Write-Host "generate-csharp-bindings.ps1: done."
