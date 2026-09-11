# Packages the two Windows release artifacts described in CLAUDE.md's
# "Release artifacts" section (once Windows is added there -- see the
# note at the end of this file's output), from an already-built Release
# install (Scripts/build-staging.ps1's output). Does no building of its
# own -- run build-staging.ps1 first. Mirrors
# apps/macos/Scripts/package-release.sh's shape and naming convention.
#
# Two separate version arguments, not one: the platform and vaultcore
# version independently, per CLAUDE.md's Versioning section -- they
# will often differ, since vaultcore is versioned by its own changes,
# not by whatever the app's own version is.
#
# Pass BARE versions (e.g. v0.1.0), not full tag names -- the
# "Windows-"/"vaultcore-...-windows" parts of the output filenames
# below are added by this script already, matching CLAUDE.md's actual
# documented artifact names (VaultSigner-macOS-vX.Y.Z.zip, not
# VaultSigner-macOS-macos-vX.Y.Z.zip). Confirmed by hitting this
# exact double-prefix mistake in testing, not assumed.
#
# Usage: powershell -File Scripts/package-release.ps1 <vX.Y.Z> <vA.B.C>
param(
    [Parameter(Mandatory = $true)][string]$PlatformVersion,
    [Parameter(Mandatory = $true)][string]$VaultcoreVersion
)
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsAppDir = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent (Split-Path -Parent $WindowsAppDir)
$InstallPath = Join-Path $env:LOCALAPPDATA "VaultSigner"
$OutDir = Join-Path $WindowsAppDir ".release-artifacts"

if (-not (Test-Path (Join-Path $InstallPath "Agent\VaultSignerAgent.exe"))) {
    Write-Error "package-release.ps1: $InstallPath doesn't contain a built app -- run Scripts/build-staging.ps1 first."
    exit 1
}

Remove-Item -Recurse -Force $OutDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $OutDir | Out-Null

Write-Host "package-release.ps1: packaging the installed app..."
$AppZip = Join-Path $OutDir "VaultSigner-Windows-$PlatformVersion.zip"
# Compress-Archive zips the *contents* of a trailing '\*' source, i.e.
# the zip's top-level entries are the Agent\ and UI\ subfolders
# themselves (see build-staging.ps1 for why they're kept as separate
# self-contained publishes rather than one merged folder).
Compress-Archive -Path "$InstallPath\*" -DestinationPath $AppZip -CompressionLevel Optimal

Write-Host "package-release.ps1: packaging the vaultcore library bundle..."
$LibStage = Join-Path $OutDir "vaultcore-$VaultcoreVersion-windows"
New-Item -ItemType Directory -Path $LibStage | Out-Null
Copy-Item (Join-Path $RepoRoot "target\release\vaultcore.dll") $LibStage
Copy-Item (Join-Path $RepoRoot "target\release\vaultcore.dll.lib") $LibStage -ErrorAction SilentlyContinue
Copy-Item (Join-Path $WindowsAppDir "Generated\vaultcore.cs") $LibStage
$LibZip = Join-Path $OutDir "vaultcore-$VaultcoreVersion-windows.zip"
Compress-Archive -Path "$LibStage\*" -DestinationPath $LibZip -CompressionLevel Optimal
Remove-Item -Recurse -Force $LibStage

@"

Packaged:
  $AppZip
  $LibZip

These are unsigned (no Authenticode certificate set up for this
project yet) -- end users launching the .exe files will see
SmartScreen's "Windows protected your PC" warning; "More info" ->
"Run anyway" bypasses it. Note this in the release notes the same way
CLAUDE.md documents Gatekeeper's warning for the macOS build.

Publish the app zip against the $PlatformVersion tag on main, and note
in that release's notes that it bundles vaultcore $VaultcoreVersion --
see CLAUDE.md's "Release artifacts" section for the exact steps (it
documents this two-file, two-version pattern for macOS today; extend it
with the Windows equivalent above when this is used for a real release).
"@ | Write-Host
