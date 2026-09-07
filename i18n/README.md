# VaultSigner — i18n

Spec §12 item 2.9 / spec §9. Single source-of-truth ICU-MessageFormat-
shaped resource files, plus per-platform generation scripts.

## Architecture

- `source/<locale>.json` — the source of truth. Flat `"semantic.key":
  "message"` maps (not raw English text as the key — see below for why).
  Values may use ICU MessageFormat features as those are actually needed
  (plurals, gender, etc.); none of the current keys need them yet.
- `generate-apple-strings.py` — converts each `source/<locale>.json` into
  `apps/macos/VaultSigner/Resources/<locale>.lproj/Localizable.strings`.
  Run it, then `xcodegen generate` in `apps/macos/`, whenever a
  `source/*.json` file changes. Future platforms get their own generator
  here (`strings.xml` for Android, `.resx` for Windows, `.po` for Linux)
  reading the same `source/` files — none exist yet since no other
  platform phase has started.
- `lint-hardcoded-strings.py` — spec §9's "CI lint that fails the build
  on hardcoded UI literal strings outside the resource files." No CI
  service is configured for this repo yet, so this is a runnable local
  script rather than a wired-up build step; see its own docstring for
  `--report` vs `--strict` mode.

**Why semantic keys instead of using the English text as the key**
(a common alternative i18n pattern): a key like `duality.option3.title`
survives the English wording changing later, and leaves room to add
ICU plural/gender variants under the same key without an unrelated
rename. The cost is that `Text("duality.option3.title")` in Swift looks
like a raw literal rather than obviously-localized text — there's no
getting around eyeballing `i18n/source/en.json` to know what a given
key actually says.

## What's actually migrated (as of spec §12 item 2.9)

Only three screens: `WelcomeView`, `ImportPacketView`, and
`MasterKeyDualityView` — chosen because spec §9 explicitly calls out
verifying right-to-left layout "specifically on the import/export
decision screens, since they are dense, multi-choice, and safety-
critical." `source/ar.json` (Arabic, RTL) covers exactly the same key
set as `en.json` for this reason, not the whole app.

**Not yet migrated:** every other screen (`CreateVaultView`,
`UnlockView`, `KeyListView`, `CreateKeyView`, `KeyDetailView`,
`SettingsView`, `ExportPacketView`, `BackupMasterKeyOnlyView`, and the
sheets inside them) still has hardcoded English string literals — run
`python3 i18n/lint-hardcoded-strings.py --report` for the full current
list (88 as of this writing). Migrating a file means: add its strings to
`source/en.json` (and `source/ar.json`, or drop that file's coverage
from the RTL-verification set if Arabic isn't the priority for it),
regenerate, replace the Swift literals with the matching keys, and add
the filename to `lint-hardcoded-strings.py`'s `MIGRATED_FILES` set so
`--strict` actually protects it from regressing.

Two known simplifications, not yet addressed:
- Interpolated/dynamic strings (e.g. `ImportPacketView`'s "N key(s)
  collided..." pluralization, and every raw `"\(error)"` message shown
  after a failed operation) were left as English literals even in
  migrated files — ICU MessageFormat plural support is real work beyond
  what "scaffolding" needs to prove out, and doing it for one string
  without a real plan for all of them would be premature.
- Timestamps: spec §9 says store ISO-8601 internally, format for display
  only, using locale-aware formatting. `KeyDetailView` currently displays
  `KeyInfo.createdAt` (already an RFC3339 string from `vaultcore`)
  verbatim rather than through a locale-aware formatter — not fixed yet.

## Verifying without a screen

`VaultSignerApp.swift`'s `--test-i18n <locale> <key>` hook resolves a key
directly against a named `.lproj` bundle (bypassing the system/app
language entirely) — used to confirm both `en` and `ar` resolve
correctly, and that a missing key falls back rather than crashing,
without needing to actually switch the app's language and read the
screen (this environment currently can't screenshot the running app —
see the main macOS README).
