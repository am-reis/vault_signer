# Android release process: two flavors, one version, one tag

Android ships as **two Gradle product flavors of the same app, from the
same commit, carrying the identical version number** — not two products,
not two points in history, not two things to keep in sync by hand. This
document is the "why" and "how"; `CLAUDE.md`'s "Release artifacts"
section has the exact publishing steps once artifacts are built.

## Why two flavors at all

Spec §12/§6.3 originally scoped this platform at API 34+, because
`CredentialProviderService` (the FIDO2/passkey role, spec §6.3) genuinely
requires it — that part hasn't changed. But API 34 alone is a real,
measurable minority of active Android devices: **54.5% cumulative
distribution** as of the April 2026 figures on
[apilevels.com](https://apilevels.com/) (Statcounter-sourced). Shipping
only the API-34+ build would mean the app simply isn't installable on
nearly half of all active Android phones — "the largest user base of
smartphones on the planet," as this decision was originally framed, is
not optional to address.

**`full`** keeps the original API 34+ scope, FIDO2 included.
**`lite`** drops only `CredentialProviderService` and reaches down to
API 23 — chosen, not guessed:

| API level | Cumulative distribution (Apr 2026, Statcounter) |
|---|---|
| 21 | 99.8% |
| 23 | 98.0% |
| 24 | 96.6% |
| 26 | 96.1% |
| 29 | 91.1% |
| 30 | 86.9% |
| 33 | 68.9% |
| 34 | 54.5% |

23, not lower, because **AndroidX itself has required minSdk 23+ since
June 2025** — this app is built on Compose and AndroidX throughout, so
23 is the actual practical floor this dependency stack can reach at all,
not a stopping point chosen for its own sake. The gap between 23 (98.0%)
and 24 (96.6%) is 1.4 points; the gap between 23 and 34 is 43.5 points.
There is no meaningful coverage left on the table by not going lower than
23, and there is no way to go lower anyway.

## What's actually flavor-specific

Deliberately almost nothing. Per the original design brief for this
change: *"Flavor-specific source sets hold only the FIDO2 code path;
everything else — UI, vaultcore bindings, protocol, i18n — stays shared
and gets built twice, not maintained twice."* Concretely:

| Path | Scope |
|---|---|
| `src/main/` | Everything: UI screens, `VaultSignerService`, the custom protocol, `AutoUnlockStore`, `BootCompletedReceiver`, i18n, vaultcore/UniFFI bindings. Compiled into **both** flavors, unchanged. |
| `src/full/kotlin/.../credentialprovider/VaultSignerCredentialProviderService.kt` | The FIDO2 `CredentialProviderService` (spec §6.3). `full` only. |
| `src/full/kotlin/.../credentialprovider/PasskeyCompletionActivity.kt` | Completes one FIDO2 ceremony. `full` only. |
| `src/full/res/xml/provider.xml` | The Credential Manager capabilities declaration. `full` only. |
| `src/full/AndroidManifest.xml` | Manifest fragment declaring the two components above — merged into the shared manifest only for `full` builds. |
| `src/full/.../ui/CredentialProviderSettingsSection.kt` | The real "Enable in system settings" button + footer (Settings screen). |
| `src/lite/.../ui/CredentialProviderSettingsSection.kt` | The same composable's signature, empty body — `SettingsScreen.kt` (shared) calls it unconditionally and never needs to know which flavor it's running in. |
| `fullImplementation("androidx.credentials:...")` | The one Gradle dependency the FIDO2 code path needs that nothing else does — `lite` never links it, not just "doesn't call it." |

`PassphrasePromptActivity` (the passphrase-entry dialog `vaultsigner.sign`
and FIDO2 assertions both use) stays in `src/main/` — it's the custom
protocol's own UI, not FIDO2-specific, even though it happens to sit in
the `credentialprovider` package alongside the two files that did move.

**`vaultcore` itself is entirely unaffected.** It isn't flavored, has no
concept of flavors, and is cross-compiled exactly once per ABI
(`Scripts/build-vaultcore.sh`) regardless of which flavor consumes the
resulting `.so` — matching the brief's "vaultcore bindings ... stays
shared" exactly.

## The one place shared code had to become SDK-aware (not flavor-aware)

`VaultSignerService` (fully shared) declares itself as a foreground
service (spec §8) — but the specific *type* the spec designed around,
`android:foregroundServiceType="specialUse"`, is an API-34-only concept.
Foreground service types don't exist at all before API 29, and
`"specialUse"` specifically doesn't exist before 34. A `lite` build
running on an API 23-33 device — the entire reason `lite` exists — needed
this to work without crashing at exactly the code path the app's
always-on background daemon depends on. This is **not** a flavor split:
it's one method, `foregroundServiceTypeForThisDevice()` in
`VaultSignerService.kt`, branching on `Build.VERSION.SDK_INT` at runtime:

- **API 34+**: `ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE` (spec's
  original choice).
- **API 29-33**: `ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC` — one of
  the original set of types introduced alongside the whole mechanism in
  API 29, a reasonable stand-in, and NOT gated behind a per-type runtime
  permission on these OS versions (that enforcement itself only started
  in API 34, regardless of which type is requested).
- **Below API 29**: `0` — `androidx.core.app.ServiceCompat.startForeground()`
  safely degrades to the plain 2-argument `startForeground()` call there.

The manifest declares both types the service might actually request
(`android:foregroundServiceType="specialUse|dataSync"`) and both
corresponding permissions (`FOREGROUND_SERVICE_SPECIAL_USE`,
`FOREGROUND_SERVICE_DATA_SYNC`) unconditionally — declaring an unused
permission is harmless on every OS version below the one that would
enforce it.

**Verified for real, not assumed**: installed the actual `lite` debug
build on a real physical device (`Samsung SM-A326B`, genuinely Android
13 / API 33 — confirmed via `getprop`, not an emulator) and confirmed via
`dumpsys activity services` that `VaultSignerService` starts as a
genuine, running foreground service with a real notification
(`isForeground=true`, real `NotificationChannel`), with no
`IllegalArgumentException` and no crash — the exact failure mode an
unverified assumption here would have produced, on exactly the device
class `lite` exists for.

## Versioning: one number, not two

Unlike `vaultcore` (versioned independently of every platform per
`CLAUDE.md`), `full` and `lite` **share one version number** —
`versionName`/`versionCode` are set once in `defaultConfig`, and neither
flavor overrides them (deliberately no `versionNameSuffix`/
`applicationIdSuffix` on either). There is no scenario where they're
built from different points in history — both flavors are two build
outputs of one `./gradlew :app:bundleFullRelease :app:bundleLiteRelease`
invocation against the exact same commit — so there is nothing for a
second version number to track that the shared one doesn't already say.

## Tag and artifacts

One tag, `android-vX.Y.Z`, on `main` (same pattern as `macos-vX.Y.Z`/
`windows-vX.Y.Z` — see `CLAUDE.md`'s Versioning section), carrying **two**
named artifacts instead of macOS's app-zip + vaultcore-zip pair:

- `VaultSigner-Android-full-vX.Y.Z.aab`
- `VaultSigner-Android-lite-vX.Y.Z.aab`

Both `.aab` (Android App Bundle, Play Console's required upload format),
both from the identical tagged commit, both carrying the identical
in-app version number — the filename suffix is the only thing that
distinguishes them, exactly mirroring how the tag itself carries no
per-flavor distinction (there is only one `android-vX.Y.Z`, not a
`android-full-vX.Y.Z`/`android-lite-vX.Y.Z` pair). `Scripts/package-release.sh
<android-vX.Y.Z>` builds and names both; see `CLAUDE.md`'s Release
artifacts section for the actual publishing steps.

## Building locally

```bash
apps/android/Scripts/build-vaultcore.sh          # once, or after any vaultcore change
./gradlew :app:assembleFullDebug                 # or assembleLiteDebug
./gradlew :app:bundleFullRelease :app:bundleLiteRelease   # release AABs, both flavors
```

`generateUniffiBindings` (in `app/build.gradle.kts`) runs identically for
both flavors — it doesn't know or care which one triggered it, since the
UniFFI-generated API surface is the same regardless of flavor.

## Known gaps (disclosed, not silently deferred)

- **Release signing is not set up.** `Scripts/package-release.sh`
  produces real `.aab` files, but with Gradle's default (unsigned)
  release config — there is no keystore, no `signingConfigs` block, and
  no equivalent yet of macOS's `VAULTSIGNER_TEAM_ID`-driven signing
  identity. Do not upload either artifact to Play Console before this
  exists.
- **`settings_start_at_login_footer`'s shared string** ("...answers
  signing requests and FIDO2 prompts...") is technically inaccurate on
  `lite`, which has no FIDO2 path at all. Left as-is deliberately per the
  "i18n stays shared, built twice, not maintained twice" design — making
  even one string flavor-aware would be the first crack in that
  boundary. A future pass could add a `lite`-specific override if this
  turns out to actually confuse users; not done here.
- **`full` was not re-verified end-to-end after this change** beyond a
  clean `assembleFullDebug`/`bundleFullRelease` build — its own code
  didn't change (only moved files, no logic edits), and the shared code
  it depends on (`VaultSignerService`, etc.) was verified via `lite` on
  real hardware covering the *new* code path; `full`'s own prior
  real-device/emulator verification (PROGRESS.md's Phase 4 entries)
  still stands unchanged.
- **No automated CI builds both flavors** — this project has no CI
  service configured at all yet (same standing gap noted elsewhere in
  `PROGRESS.md`), so "both flavors build" is only verified by whoever
  runs the commands above locally before a release.
