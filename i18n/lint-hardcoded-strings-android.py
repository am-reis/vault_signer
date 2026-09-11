#!/usr/bin/env python3
"""Spec §9's hardcoded-string CI lint (see i18n/lint-hardcoded-strings.py's
own docstring for the general rationale — this is that same tool's shape,
applied to Android/Compose instead of SwiftUI, kept as its own script
rather than folded into the Swift one, matching how Windows also got its
own lint-hardcoded-strings.ps1 rather than sharing the Python file across
UI toolkits it can't actually parse).

Scans Kotlin Compose source for `Text("...")`/`Text(text = "...")`-shaped
literals — the common Compose string-literal-as-content call shape. Two
modes:
  --report   (default) lists every hardcoded literal found, per file.
             Always exits 0.
  --strict   fails (exit 1) only for files listed in MIGRATED_FILES below.

Usage: python3 i18n/lint-hardcoded-strings-android.py [--report|--strict]
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "apps" / "android" / "app" / "src" / "main" / "kotlin"

# Files already migrated to i18n/source/en.json keys (via generated
# R.string.* resources) — a hardcoded string literal found in one of
# these is a real regression. As of Phase 4 (spec §12 item 4.7), every
# screen/view file is migrated — a materially different starting point
# than macOS/Windows had at their own item 2.9/3.7 checkpoints, since
# Android's screens were built i18n-first rather than migrated
# after the fact.
MIGRATED_FILES = {
    "PasskeyCompletionActivity.kt",
    "PassphrasePromptActivity.kt",
    "VaultSignerCredentialProviderService.kt",
    "CreateCompartmentScreen.kt",
    "CreateKeyScreen.kt",
    "CreateVaultScreen.kt",
    "ExportPacketScreen.kt",
    "ImportPacketScreen.kt",
    "KeyDetailScreen.kt",
    "KeyListScreen.kt",
    "ManageVaultsScreen.kt",
    "MasterKeyDualityScreen.kt",
    "SettingsScreen.kt",
    "UnlockScreen.kt",
    "WelcomeScreen.kt",
}

LITERAL_CALL = re.compile(r'\bText\(\s*(?:text\s*=\s*)?"((?:[^"\\]|\\.)*)"')

# A resource key looks like "welcome.create_button" — lowercase,
# dot-separated identifier segments. Real hardcoded UI text essentially
# never matches this shape.
RESOURCE_KEY_SHAPE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")


def is_flaggable_literal(literal: str) -> bool:
    if "$" in literal:  # Kotlin string templates can't be a resource key either way.
        return False
    return not RESOURCE_KEY_SHAPE.match(literal)


def find_literals(path: Path) -> list[tuple[int, str]]:
    findings = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        for match in LITERAL_CALL.finditer(line):
            literal = match.group(1)
            if is_flaggable_literal(literal):
                findings.append((lineno, literal))
    return findings


def main() -> None:
    strict = "--strict" in sys.argv
    any_findings_in_migrated = False

    for path in sorted(SOURCE_DIR.rglob("*.kt")):
        findings = find_literals(path)
        if not findings:
            continue
        is_migrated = path.name in MIGRATED_FILES
        if strict and not is_migrated:
            continue
        for lineno, literal in findings:
            marker = "ERROR" if (strict and is_migrated) else "note"
            print(f"{marker}: {path.relative_to(REPO_ROOT)}:{lineno}: hardcoded string {literal!r}")
        if is_migrated:
            any_findings_in_migrated = True

    if strict and any_findings_in_migrated:
        sys.exit(1)


if __name__ == "__main__":
    main()
