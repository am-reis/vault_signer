# Shared — cross-platform developer journal

Cherry-picked facts from platform-specific work that are worth knowing
about *outside* that one platform — architectural decisions, gotchas,
or lessons a later session on a different platform could otherwise
re-discover the hard way. Each platform keeps its own detailed journal
(e.g. `apps/android/docs/android-dev-journal.md`) for narrative that's
only relevant to that platform; this file is for the subset that isn't.
Committed on `shared` only, per the usual path-ownership rules.
`PROGRESS.md` itself stays a checklist with short exception notes —
this file, like the per-platform journals, is where the longer "why"
and "here's what we learned" material belongs instead.

## 2026-09-11 — FIDO2 credential-provider process architecture (from Android)

Android's `CredentialProviderService` (`VaultSignerCredentialProviderService`)
and its companion `PasskeyCompletionActivity` were deliberately built to
run in the *same* `:agent` process as the main `VaultSignerService`,
sharing `AgentState.vault` directly — a single already-open `Vault`
instance, no second one. This was a conscious choice to avoid the
split-brain gap already flagged in macOS's own item 2.7: macOS's
FIDO2 extension runs as a genuinely separate OS process, forced to open
its *own* separate `Vault` handle on the same container file, which is
a standing known issue there. Android's single-APK, multi-component-
but-one-process model sidesteps this by construction rather than by
discipline.

Worth checking when iOS's own FIDO2/AutoFill credential-provider
extension design comes up (Phase 5): iOS App Extensions are *always* a
separate process from the host app (unlike Android's Binder-based
same-process components), so iOS will land in macOS's situation, not
Android's, by platform constraint rather than choice. Don't assume
Android's approach transfers — the point of recording this is so iOS's
session goes in with eyes open about which gap it's actually facing,
rather than rediscovering it independently.

## 2026-09-11 — don't trust "no exception" as proof a UI test action landed

While debugging Android's first instrumented UI test, a click on a
button that was scrolled outside a small test-viewport's visible bounds
had degenerate `(0,0)` layout bounds; the test framework's `performClick()`
dispatched a synthetic touch at that computed (wrong) coordinate and
returned normally — no exception, click just silently missed. The test
timed out several steps later waiting for the click's expected effect,
which read initially like a totally unrelated failure elsewhere.

General lesson likely to recur on any platform's UI test suite,
regardless of framework (Espresso, XCTest, WinAppDriver, etc.): a
"click"/"tap" helper returning without throwing is not proof the target
element was actually hit, especially on anything scrollable or on a
small/cropped test viewport. When a UI test times out waiting for an
action's *effect*, check whether the *triggering* interaction actually
landed (real device/window state, not just "did the call throw")
before assuming the bug is downstream of the click.
