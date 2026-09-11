# Android — developer journal

Internal working notes for `platform/android`: debugging narratives,
investigation dead-ends, and detail that would otherwise bloat
`PROGRESS.md`. `PROGRESS.md` stays a checklist (`- [x]`/`- [ ]` plus a
short exception line justifying any deviation); this file is where the
"why it took three attempts" and "here's exactly what the logs showed"
material lives instead. Committed on `platform/android` only — not
meant to be polished or public-facing.

## 2026-09-11 — CoreVaultFlowTest: off-screen elements get degenerate click bounds

`CoreVaultFlowTest.createVault_thenCreateKey_reachesRealKeyList` failed
repeatedly with `ComposeTimeoutException` on the second `waitUntil`
(waiting for the created key to appear in `KeyListScreen`), across three
separate fix attempts before the real cause was found:

1. First hypothesis: a race in `AppViewModel.createVault()`, which left
   `selectedCompartmentId` null immediately after navigating to the key
   list (it relied on `KeyListScreen`'s own `LaunchedEffect ->
   selectCompartment()` round trip, async relative to navigation).
   `CreateKeyScreen`'s submit silently no-ops on a null compartment id
   instead of erroring, so this was a real, worth-fixing bug — fixed by
   selecting the compartment synchronously from `create_vault`'s own
   response. The test still failed identically afterward, proving this
   wasn't the (sole) cause.
2. Second hypothesis: `PasswordVisualTransformation` masks
   `EditableText` in the semantics tree too, not just visually, so a
   debug assertion (`assert(hasText("key-pass-123", substring = true))`)
   added to sanity-check password field content threw `AssertionError`
   even though the actual input was correct (`EditableText` always
   reads back as bullet characters matching the input's length). Not a
   test bug — removed the assertion, since there's nothing meaningful to
   check there short of length.
3. Confirmed via per-test logcat (`ManagementHandlers`'s own `OK
   internal.*`/`FAILED internal.*` logging) that `internal.create_key`
   was *never invoked* — not failing, just never called at all — even
   after the click. Added a temporary `Log.d` as the literal first
   statement of `CreateKeyScreen`'s submit `onClick` lambda to check
   whether the click handler was even entered: it never fired, even
   though `performClick()` itself never threw.
4. Root cause, found via a mid-run `uiautomator dump` (screenshots are
   blocked entirely by `FLAG_SECURE`, even for debugging, so this was
   the only way to see real on-screen state without violating that):
   the emulator's window is a very small **320×405px** viewport.
   `CreateKeyScreen`'s form (label/description/resource/tags/key-type/
   passphrase/confirm/submit, plus explanatory text) is much taller than
   that. Fields and the submit button scrolled below the visible area
   report **degenerate `[0,0]-[0,0]` bounds** until actually scrolled
   into view. Compose's `performClick()`/`performTextInput()` dispatch a
   synthetic touch at the target node's computed center — with
   degenerate bounds, that computed center is `(0,0)`, so the "click"
   silently lands on empty space at the top-left corner instead of the
   real button. No exception, because dispatching a touch at a
   coordinate that hits nothing clickable isn't an error from the test
   framework's point of view.
5. Fix: call `.performScrollTo()` immediately before interacting with
   any `CreateKeyScreen` field or the submit button, so the target node
   gets a real layout pass and valid bounds first. Verified stable
   across repeated runs on both `full`/`lite` flavors, on both the AVD
   emulator and the paired real Android 13 device.

Takeaway for future Compose instrumented tests in this app: don't trust
"`performClick()` didn't throw" as proof the click landed — on a
scrollable screen, always `.performScrollTo()` a target before acting on
it, especially on a small/cropped test viewport.

## 2026-09-11 — FIDO2 live-ceremony attempt against real demo relying parties

Tried to move item 4.4's interop gap forward using two real, independent
demo relying-party sites (chosen by request, not invented):
`fido.demo.gemalto.com` and `token2.com`'s FIDO2 demo tool.

- `fido.demo.gemalto.com/?user=tes`: TLS certificate is invalid
  (`NET::ERR_CERT_AUTHORITY_INVALID`) — the browser refuses the
  connection outright. Likely an abandoned/expired demo deployment, not
  anything on our end. Didn't attempt to bypass the browser's warning.
- `token2.com/tools/fido2-demo`: loaded correctly over valid HTTPS.
  Triggering "Register" from the page correctly invoked Android's
  Credential Manager, which correctly routed to VaultSigner's registered
  `CredentialProviderService` (confirmed via `dumpsys`/logcat: the
  provider was queried, `onBeginCreateCredentialRequest` ran) —
  confirming the registration wiring is genuinely correct end to end up
  to that point, on a real external site with no special setup on its
  side.
- The actual credential-creation ceremony did not complete in this
  session — Android's system passkey UI (provided by Google Play
  Services, sitting below the browser layer) has its own prerequisites
  that this test environment doesn't currently satisfy. This sits at the
  OS/Credential-Manager layer, below any specific browser — a custom
  WebView-based browser would hit the identical system dialog, not
  bypass it. There's no code-level workaround available from within the
  app; this needs a follow-up session with a suitably prepared test
  environment.

Net effect: the registration path is now verified correct against a
real, independent relying party (not just our own app's Settings
screen, as item 4.4's earlier verification was limited to) — one level
better than before, but the actual WebAuthn ceremony itself still isn't
exercised. The interop gap in `PROGRESS.md`'s 4.4 entry stands.

## 2026-09-11 — CreateCompartment/Export/Import/Duality click-through tests, and a suite-level flake

Added two more instrumented tests (item 4.1/4.8's remaining screens):

- `CreateCompartmentFlowTest`: create a vault, add a second compartment
  from `KeyListScreen`'s overflow menu, confirm success (navigation back
  to the key list — `addCompartment()` only calls `onDone` after the RPC
  actually succeeds).
- `ExportImportDualityFlowTest`: the automated form of the manual self-
  export/self-import round trip mentioned in this phase's `PROGRESS.md`
  4.1 entry (the one that caught the real `vaultcore` merge-persistence
  bug) — create vault A with a key, export it "as-is" with the master
  key included, close vault A, create vault B, import the packet, merge
  via duality Option 1, and confirm the key lands in vault B.
  `ExportPacketScreen`/`ImportPacketScreen` both hand off to a real
  system document picker (`CreateDocument`/`OpenDocument`); Espresso-
  Intents (`IntentsRule`) stubs that picker's result with a real local
  file so the round trip stays genuinely automated.

Both passed on their own immediately. Running all three test classes
together in one `connectedFullDebugAndroidTest` invocation, though,
intermittently failed a *different* test each time — always at a
`waitUntil` that should have resolved almost instantly. Root cause,
confirmed via full logcat correlation: `am instrument` keeps ONE app
process (and its `:agent` child process, with whatever vault it has
open) alive across every test *class* in one invocation — it only
restarts on an actual crash. A `@Before fun ensureCleanStart()` was
added first (`BaseVaultInstrumentedTest`, closes any vault left open by
a prior test class via the real Settings → Close Vault UI) to make
tests order-independent, and that fixed the *first* failure mode
(a test starting mid-way through a previous test's still-open vault).
But the flake persisted, now specifically as the third test in a row
timing out completely — RPC calls that had been near-instant for tests
1 and 2 stopped happening at all, with no error logged either.

That's resource/process accumulation across repeated Activity-recreation
cycles against the same never-restarted `:agent` process, not a real
app bug — each test passes reliably in isolation, every time. The real
fix is **Android Test Orchestrator**
(`androidx.test:orchestrator`, `testOptions { execution =
"ANDROIDX_TEST_ORCHESTRATOR" }`, `clearPackageData = "true"`), which
runs every test method in its own fresh process rather than trying to
reset state from the test side — this is exactly the problem it exists
to solve. Confirmed stable across two repeated full-suite runs after
enabling it. `ensureCleanStart()` was kept as a cheap defense-in-depth
(a no-op once Orchestrator guarantees a clean process per test), not
removed.

## 2026-09-11 — RTL verification, on-device

`ar.json`'s translations already existed and Android's `values-ar`
qualifier carries automatic RTL mirroring for free, but that had never
actually been checked rendering on a real device. A system-wide locale
change via `adb shell settings put system system_locales` didn't take
effect (writing that setting directly doesn't trigger the actual
locale-change path — that normally goes through a privileged
`LocaleManagerService` call the Settings app makes internally). Android
13's per-app language override did work directly from the shell:

```
adb shell cmd locale set-app-locales com.vaultsigner.app --user current --locales ar-SA
```

Verified via `uiautomator dump` (screenshots are blocked by
`FLAG_SECURE`, same as always): real Arabic text renders correctly on
`WelcomeScreen` and `ManageVaultsScreen`, and — more importantly —
element bounds actually mirror, not just the text. E.g. "Create New
Vault…" sits at `[40,114]-[164,134]` (hugging the left) in English;
its Arabic equivalent sits at `[176,114]-[280,134]` (hugging the right)
in the identical layout. Confirms `Alignment.Start`/`Column`'s default
alignment genuinely resolves against `LocalLayoutDirection` here, not
just that the strings are translated. Reverted the override back to
`en-US` afterward so the emulator's default state doesn't surprise a
later session.
