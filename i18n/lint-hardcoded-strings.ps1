# Spec §9: "Add a CI lint that fails the build on hardcoded UI literal
# strings outside the resource files." Windows counterpart to
# i18n/lint-hardcoded-strings.py -- written in PowerShell for the same
# reason generate-resx-strings.ps1 is: this Windows dev box has no
# working Python install. No CI service is configured for this
# repository yet, so this is a runnable local script, not a wired-up
# build step -- point a CI job at it once one exists.
#
# Scans WinUI3 .xaml files for a hardcoded Text=/Content=/
# PlaceholderText=/Header= literal on the specific control types that
# carry real user-facing text in this app (TextBlock, Button,
# HyperlinkButton, PasswordBox, TextBox, ComboBox) -- deliberately not
# every attribute on every element: a plain TextBox's own Text= is
# normally an editable default VALUE (e.g. a suggested file name), not
# label text, so it's excluded to avoid flagging things that were never
# meant to be localized. A regex, not a real XAML parser -- false
# positives/negatives are expected, same caveat the Python version
# documents for its own Swift-literal regex.
#
# Two modes:
#   -Report  (default) lists every hardcoded literal found, per file.
#   -Strict  fails (exit 1) only for files in $MigratedFiles below --
#            the files this project has actually migrated to resource
#            keys (spec §12 item 3.7). This is what a real CI job
#            should run.
#
# Usage: powershell -File i18n/lint-hardcoded-strings.ps1 [-Strict]
param([switch]$Strict)
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$PagesDir = Join-Path $RepoRoot "apps\windows\VaultSignerUI\VaultSignerUI"

# Files already migrated to i18n/source/en.json keys (spec §12 item
# 3.7) -- a hardcoded literal found in one of these is a real
# regression, mirroring lint-hardcoded-strings.py's MIGRATED_FILES.
$MigratedFiles = @(
    "WelcomePage.xaml",
    "ImportPacketPage.xaml",
    "MasterKeyDualityPage.xaml",
    "ManageVaultsPage.xaml"
)

# Each pattern pairs an attribute with only the control types where
# that attribute is real label/prompt text -- not, e.g., a plain
# TextBox's own Text=, which is normally an editable DEFAULT VALUE
# (see WelcomePage.xaml's "MyVault.vlt"/"Personal" or
# MasterKeyDualityPage.xaml's "Imported vault"), not label text; only
# its PlaceholderText is. Confirmed by a real false-positive run before
# this split existed, not assumed. Excludes any value starting with
# "{" (a XAML markup extension -- {x:Bind ...}, {ThemeResource ...} --
# never a literal).
$LiteralPatterns = @(
    '<TextBlock\b[^>]*\bText="((?!\{)[^"]*)"',
    '<(?:Button|HyperlinkButton)\b[^>]*\bContent="((?!\{)[^"]*)"',
    '<(?:PasswordBox|TextBox)\b[^>]*\bPlaceholderText="((?!\{)[^"]*)"',
    '<ComboBox\b[^>]*\bHeader="((?!\{)[^"]*)"'
)

# Product/brand names deliberately excluded from localization, per
# spec §9's standard i18n practice (mirrors generate-apple-strings.py's
# equivalent exemption on the macOS side via Text(verbatim:)).
$ExemptLiterals = @("VaultSigner")

$anyFindingsInMigrated = $false

Get-ChildItem -Path $PagesDir -Filter "*.xaml" | Sort-Object Name | ForEach-Object {
    $isMigrated = $MigratedFiles -contains $_.Name
    if ($Strict -and -not $isMigrated) { return }

    $lineNum = 0
    $findings = @()
    foreach ($line in Get-Content $_.FullName) {
        $lineNum++
        foreach ($pattern in $LiteralPatterns) {
            foreach ($m in [regex]::Matches($line, $pattern)) {
                $value = $m.Groups[1].Value
                if ($ExemptLiterals -contains $value) { continue }
                $findings += [PSCustomObject]@{ Line = $lineNum; Text = $value }
            }
        }
    }
    if ($findings.Count -eq 0) { return }

    foreach ($f in $findings) {
        $marker = if ($Strict -and $isMigrated) { "ERROR" } else { "note" }
        Write-Host "${marker}: apps\windows\VaultSignerUI\VaultSignerUI\$($_.Name):$($f.Line): hardcoded string '$($f.Text)'"
    }
    if ($isMigrated) { $anyFindingsInMigrated = $true }
}

if ($Strict -and $anyFindingsInMigrated) { exit 1 }
exit 0
