# Builds VaultSignerAgent.exe and VaultSignerUI.exe in Release
# configuration, self-contained (bundles the .NET 8 runtime and, for
# the UI, the Windows App SDK runtime -- see VaultSignerUI.csproj's
# WindowsAppSDKSelfContained comment for why that specifically matters
# on this project), and installs both to a stable path.
#
# Why a stable install path (mirrors apps/macos/Scripts/build-staging.sh's
# own reasoning for installing to /Applications rather than running out
# of DerivedData): `internal.enable_autostart`
# (apps/windows/VaultSignerAgent/ManagementHandlers.cs) captures
# `Environment.ProcessPath` at the moment the user turns autostart on
# and writes that exact path into the HKCU Run key. A path that moves
# across every rebuild (a bin\Release\... folder, changing per publish)
# would leave a stale, broken Run-key entry the next time this script
# runs. Installing to %LOCALAPPDATA%\VaultSigner every time -- same
# path, contents replaced -- keeps that entry valid across rebuilds.
#
# No code-signing step here, unlike macOS's codesign verification: no
# Authenticode certificate exists for this project yet (there's no
# Windows equivalent of VAULTSIGNER_TEAM_ID wired up). Both .exe files
# are shipped unsigned. Launching an unsigned .exe downloaded from the
# internet trips SmartScreen's "Windows protected your PC" warning --
# "More info" -> "Run anyway" bypasses it, the same category of warning
# CLAUDE.md's Release artifacts section already documents for macOS's
# Gatekeeper "unidentified developer" prompt. A signing step can be
# added here later without changing anything else in this script.
#
# Usage: powershell -File Scripts/build-staging.ps1
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsAppDir = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent (Split-Path -Parent $WindowsAppDir)
$VaultcoreDir = Join-Path $RepoRoot "vaultcore"
$InstallPath = Join-Path $env:LOCALAPPDATA "VaultSigner"

Write-Host "build-staging.ps1: building vaultcore (release, uniffi feature)..."
cargo build --release --manifest-path "$VaultcoreDir\Cargo.toml" --features uniffi

Write-Host "build-staging.ps1: regenerating C# bindings from the release build..."
& (Join-Path $ScriptDir "generate-csharp-bindings.ps1")

$AgentPublish = Join-Path $WindowsAppDir "VaultSignerAgent\.staging-build"
$UiPublish = Join-Path $WindowsAppDir "VaultSignerUI\VaultSignerUI\.staging-build"

Write-Host "build-staging.ps1: publishing VaultSignerAgent (Release, self-contained, win-x64)..."
Remove-Item -Recurse -Force $AgentPublish -ErrorAction SilentlyContinue
dotnet publish (Join-Path $WindowsAppDir "VaultSignerAgent\VaultSignerAgent.csproj") `
    -c Release -r win-x64 --self-contained true `
    -o $AgentPublish
if ($LASTEXITCODE -ne 0) { Write-Error "build-staging.ps1: VaultSignerAgent publish failed"; exit 1 }

Write-Host "build-staging.ps1: publishing VaultSignerUI (Release, self-contained, win-x64)..."
Remove-Item -Recurse -Force $UiPublish -ErrorAction SilentlyContinue
# PublishTrimmed=false override: VaultSignerUI.csproj enables IL
# trimming for Release by default, and the build even flags exactly
# which reflection-based code paths are at risk (IL2026 warnings on
# KnownVaultsStore's/ManagementClient's System.Text.Json calls) -- but
# the actual failure this hit live was more fundamental: a trimmed
# publish crashed on launch with exception code 0xc000027b inside
# Microsoft.UI.Xaml.dll itself (confirmed via a real launch + Windows
# Event Log check, from the correct interactive session -- not a
# session-mismatch artifact like some earlier crashes in this project's
# history). WinUI3's XAML runtime leans on reflection-based type
# activation that the trimmer can't statically see through, a known
# fragile combination. Re-publishing with trimming off (confirmed live:
# process stays up, main window renders) fixed it. Revisit only with a
# real trimmer-descriptor investment (rd.xml / DynamicDependency
# attributes), not by re-enabling this blind.
dotnet publish (Join-Path $WindowsAppDir "VaultSignerUI\VaultSignerUI\VaultSignerUI.csproj") `
    -c Release -r win-x64 --self-contained true -p:PublishTrimmed=false `
    -o $UiPublish
if ($LASTEXITCODE -ne 0) { Write-Error "build-staging.ps1: VaultSignerUI publish failed"; exit 1 }

if (Test-Path $InstallPath) {
    Write-Host "build-staging.ps1: stopping any running VaultSignerAgent/VaultSignerUI first..."
    Stop-Process -Name "VaultSignerAgent", "VaultSignerUI" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Write-Host "build-staging.ps1: removing previous install at $InstallPath..."
    Remove-Item -Recurse -Force $InstallPath
}

Write-Host "build-staging.ps1: installing to $InstallPath..."
New-Item -ItemType Directory -Path $InstallPath | Out-Null
# Agent and UI each get their OWN subfolder -- confirmed for real (not
# assumed) that they can't share one flat directory the way a single
# macOS .app bundle holds both: each is an independent self-contained
# .NET publish, meaning each carries its own private copy of the whole
# runtime (System.Console.dll, System.Private.CoreLib.dll, etc). Copying
# both into one folder with -Force lets whichever one copies second
# silently overwrite the first's runtime files with its own (possibly
# different-patch-version, and in the UI's case PublishTrimmed) copies.
# Hit this live: a flattened install produced a VaultSignerAgent.exe
# that launched and immediately crashed with
# `MissingMethodException: Method not found: 'System.IO.TextWriter
# System.Console.get_Error()'` -- the UI's trimmed System.Console.dll
# had overwritten the Agent's own untrimmed copy.
$AgentInstall = Join-Path $InstallPath "Agent"
$UiInstall = Join-Path $InstallPath "UI"
Copy-Item -Path $AgentPublish -Destination $AgentInstall -Recurse -Force
Copy-Item -Path $UiPublish -Destination $UiInstall -Recurse -Force

@"

Installed: $InstallPath

Next steps:
  1. Launch `"$AgentInstall\VaultSignerAgent.exe`"
  2. Launch `"$UiInstall\VaultSignerUI.exe`" (they're two separate
     processes -- the UI doesn't launch the agent for you yet; see
     PROGRESS.md's Phase 3 notes)
  3. In Settings, toggle autostart off then on if you'd enabled it
     against a previous build -- this re-writes the Run-key entry
     against this install's path.
  4. Verify autostart actually points here:
     Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name VaultSignerAgent
"@ | Write-Host
