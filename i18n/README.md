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

**Both platforms are now fully migrated — every view/page, zero
hardcoded UI literals remaining, per each platform's own lint script in
`--strict`/`-Strict` mode.** `source/en.json` is 219 keys.

**macOS** (spec §12 item 2.9): all 13 view files — `WelcomeView`,
`ImportPacketView`, `MasterKeyDualityView`, `ManageVaultsView`,
`ContentView`, `BackupMasterKeyOnlyView`, `CreateKeyView`,
`CreateVaultView`, `ExportPacketView`, `KeyDetailView`, `KeyListView`,
`SettingsView`, `UnlockView`.

**Windows** (spec §12 item 3.7): all 12 pages — the original four
(`WelcomePage`, `ImportPacketPage`, `MasterKeyDualityPage`,
`ManageVaultsPage`) plus `BackupMasterKeyOnlyPage`,
`CreateCompartmentPage`, `CreateKeyPage`, `DeviceProfilePicker`,
`ExportKeysPage`, `KeyDetailPage`, `SettingsPage`, `VaultHomePage`.
Windows has no separate `CreateVaultPage` (that flow lives inline in
`WelcomePage`) and has one screen macOS doesn't
(`CreateCompartmentPage`, standalone compartment creation) — both
platforms' key sets reflect their own real UI shape, not a forced 1:1
screen mapping.

**A real gap existed here, found by a reviewer and worth recording**:
an earlier pass through this file claimed Windows had reached "parity
with macOS," but had actually only migrated the original four RTL-set
screens, matching an *earlier* macOS milestone, not macOS's actual
current state — macOS's own full 13-view migration (~100 more keys)
had been committed directly on `platform/macos` and never made it into
this shared file at all, so the gap wasn't even visible without
checking `platform/macos`'s own `PROGRESS.md` directly. Reconciled by
merging macOS's real key set into `source/en.json`, then migrating
every remaining Windows file against it — see `PROGRESS.md`'s Phase 3
entry for the full remediation, and the note now added to `CLAUDE.md`
about where completion is actually tracked.

Not always byte-identical English wording between platforms — where a
screen's copy already differed (e.g. Windows's own inline
vault-creation section, or `CreateCompartmentPage`, which macOS doesn't
have at all), each platform kept its own wording under its own keys
rather than being forced to match; where the concept and wording
already lined up, one adopted the other's exact shared string. See
`source/en.json`'s own top comment for which keys are platform-only.

`source/ar.json` (Arabic, RTL) deliberately stays scoped to the
original four-screen RTL-verification set on both platforms — spec
§9's actual requirement ("verify right-to-left layout specifically on
the import/export decision screens"), not a whole-app localization
decision. A key outside that set falls back to English on both
platforms' resource-lookup mechanisms, by design.

**Two known simplifications, on both platforms, not yet addressed:**
- Interpolated/dynamic strings shown after a failed operation (raw
  `ex.Message`/`"\(error)"` passthroughs) were left as-is — real
  per-error-code resource keys are a separate, larger effort than this
  pass's scope.
- Timestamps: spec §9 says store ISO-8601 internally, format for
  display only, using locale-aware formatting. Both `KeyDetailView` and
  `KeyDetailPage` currently display the raw RFC3339 `createdAt` string
  verbatim rather than through a locale-aware formatter — not fixed on
  either platform yet.

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
missing key falls back to the raw key, and every `{0}`-interpolated key
(`duality.option3.confirmation_field_format`,
`settings.auto_unlock_explanation_format`,
`discardkey.confirm_prompt_format`) formats correctly via
`Strings.Format`. Every migrated Windows page was additionally verified
rendering its real, correct text in a live running app (not just the
hook) via `System.Windows.Automation` — including
`MasterKeyDualityPage`, reached for real by creating two disposable
vaults and exporting/importing a packet with an embedded master key
between them (once seeded via raw agent calls, once through the real
UI end to end — see `PROGRESS.md`'s item 3.8 entry), exactly the flow
spec §9 calls out for RTL/safety verification.
