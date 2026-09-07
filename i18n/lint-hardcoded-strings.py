#!/usr/bin/env python3
"""Spec §9: "Add a CI lint that fails the build on hardcoded UI literal
strings outside the resource files." No CI service is configured for
this repository yet (that's separate infrastructure work), so this is a
runnable local script rather than a wired-up build step — point a CI job
at it once one exists.

Scans Swift view files for `Text("...")`/`Button("...")`/`Label("...",
systemImage:)`-shaped literals. Two modes:
  --report   (default) lists every hardcoded literal found, per file.
             Most of the app is still on this list — see PROGRESS.md item
             2.9 for what has and hasn't been migrated yet. Always exits 0.
  --strict   fails (exit 1) only for files listed in MIGRATED_FILES below
             — the files this project has actually migrated to resource
             keys. Add a file to that list only once its hardcoded
             strings have genuinely been replaced with i18n/source/*.json
             keys; this is what a real CI job should run.

Usage: python3 i18n/lint-hardcoded-strings.py [--report|--strict]
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VIEWS_DIR = REPO_ROOT / "apps" / "macos" / "VaultSigner" / "Sources"

# Files already migrated to i18n/source/en.json keys (spec §9 item 2.9) —
# a hardcoded string literal found in one of these is a real regression.
MIGRATED_FILES = {
    "WelcomeView.swift",
    "ImportPacketView.swift",
    "MasterKeyDualityView.swift",
}

# Matches Text("..."), Button("..."), Label("...", ...), SecureField("...", ...),
# TextField("...", ...), Picker("...", ...) — the common SwiftUI
# string-literal-as-title call shapes. Deliberately simple (a regex, not
# a real Swift parser); false positives/negatives are expected and this
# is a discovery aid, not a guarantee.
LITERAL_CALL = re.compile(r'\b(?:Text|Button|Label|SecureField|TextField|Picker)\(\s*"((?:[^"\\]|\\.)*)"')

# A resource key looks like "welcome.create_button" — lowercase,
# dot-separated identifier segments, no spaces or punctuation. Real
# hardcoded UI text essentially never matches this shape, so it's a
# reliable (if heuristic) way to tell "already migrated to a key" apart
# from "still a literal string."
RESOURCE_KEY_SHAPE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")


def is_flaggable_literal(literal: str) -> bool:
    # String interpolation (`"\(...)"`) can't be a resource key lookup
    # either way, but it's also not what this lint is looking for.
    if "\\(" in literal:
        return False
    return not RESOURCE_KEY_SHAPE.match(literal)


def find_literals(path: Path) -> list[tuple[int, str]]:
    findings = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if "Text(verbatim:" in line:
            continue
        for match in LITERAL_CALL.finditer(line):
            literal = match.group(1)
            if is_flaggable_literal(literal):
                findings.append((lineno, literal))
    return findings


def main() -> None:
    strict = "--strict" in sys.argv
    any_findings_in_migrated = False

    for path in sorted(VIEWS_DIR.rglob("*.swift")):
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
