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
  `source/*.json` file changes.
- `generate-resx-strings.ps1` — the Windows equivalent (spec §12 item
  3.7): converts each `source/<locale>.json` into a .NET satellite
  `.resx` under `apps/windows/VaultSignerUI/VaultSignerUI/Resources/`
  (`Strings.resx` for the neutral/`en` culture, `Strings.<locale>.resx`
  for every other one — a plain SDK-default embedded resource, picked
  up automatically on the next build, no `.csproj` edit needed).
  **Written in PowerShell, not Python**, unlike every other script
  here — this Windows dev box has no working Python install (confirmed
  directly: `python`/`python3` only resolve to the Microsoft Store
  app-execution-alias stub), and PowerShell is already this project's
  own native Windows tooling choice (every `apps/windows/Scripts/*.ps1`
  generator). A generator that can't actually be run and verified on
  its own target platform would contradict this project's core
  practice. Android/Linux generators (`strings.xml`, `.po`) still don't
  exist since neither phase has started.
- `lint-hardcoded-strings.py` (macOS) / `lint-hardcoded-strings.ps1`
  (Windows, same Python-availability reason as the generator above) —
  spec §9's "CI lint that fails the build on hardcoded UI literal
  strings outside the resource files." No CI service is configured for
  this repo yet, so these are runnable local scripts rather than a
  wired-up build step; see each one's own header comment for `--report`/
  `-Report` (default) vs `--strict`/`-Strict` mode.

**Why semantic keys instead of using the English text as the key**
(a common alternative i18n pattern): a key like `duality.option3.title`
survives the English wording changing later, and leaves room to add
ICU plural/gender variants under the same key without an unrelated
rename. The cost is that `Text("duality.option3.title")` in Swift looks
like a raw literal rather than obviously-localized text — there's no
getting around eyeballing `i18n/source/en.json` to know what a given
key actually says.

## What's actually migrated

**macOS** (spec §12 item 2.9), four screens: `WelcomeView`,
`ImportPacketView`, `MasterKeyDualityView`, and `ManageVaultsView`
(added later, item 2.11) — the first three chosen because spec §9
explicitly calls out verifying right-to-left layout "specifically on
the import/export decision screens, since they are dense, multi-choice,
and safety-critical."

**Windows** (spec §12 item 3.7), the same four screens' Windows
equivalents for parity: `WelcomePage`, `ImportPacketPage`,
`MasterKeyDualityPage`, `ManageVaultsPage`. Not always byte-identical
English wording to macOS's — where a Windows screen's copy already
differed (e.g. its own inline vault-creation section, which macOS
handles as a separate, unmigrated sheet), it kept its own wording under
new keys rather than being rewritten to match; where the concept and
wording already lined up, Windows adopted the exact shared string. See
`source/en.json`'s own top comment for the full reasoning and which
keys are Windows-only.

`source/ar.json` (Arabic, RTL) covers exactly the same key set as
`en.json`'s migrated screens on both platforms, not the whole app —
this is spec §9's RTL-verification set, not a launch-language decision.

**Not yet migrated (either platform):** every other screen — run
`python3 i18n/lint-hardcoded-strings.py --report` (macOS, 88 literals
as of item 2.9's writing) or `powershell -File
i18n/lint-hardcoded-strings.ps1` (Windows, 66 literals as of item 3.7's
writing) for the current list. Migrating a file means: add its strings
to `source/en.json` (and `source/ar.json`, or drop that file's coverage
from the RTL-verification set if Arabic isn't the priority for it),
regenerate, replace the literals with the matching keys, and add the
filename to the relevant lint script's migrated-files list so
`--strict`/`-Strict` actually protects it from regressing.

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

`App.xaml.cs`'s `--test-i18n <locale> <key>` hook is the Windows
equivalent: resolves a key via `Strings.cs`'s `ResourceManager` against
an explicit `CultureInfo`, prints it to a console it allocates itself
(this is a `WinExe` with no console by default), and exits — never
creating the normal UI window. Verified live, not just written: both
`en` and `ar` resolve correctly (the Arabic result was checked
byte-for-byte against `Resources/Strings.ar.resx`'s own UTF-8 bytes,
since a Windows console's default codepage mangles Arabic text on
display even when the underlying lookup is correct — `Console.OutputEncoding
= Encoding.UTF8` in the hook fixes the *display* half of that), a
missing key falls back to the raw key, and the one `{0}`-interpolated
key (`duality.option3.confirmation_field_format`) formats correctly via
`Strings.Format`. All four migrated Windows pages were additionally
verified rendering their real, correct text in a live running app (not
just the hook) via `System.Windows.Automation` — including
`MasterKeyDualityPage`, reached for real by creating two disposable
vaults and exporting/importing a packet with an embedded master key
between them, exactly the flow spec §9 calls out for RTL/safety
verification.
