package com.vaultsigner.ui

import androidx.compose.runtime.Composable

/**
 * "lite"-flavor stand-in: no `CredentialProviderService` exists in this
 * flavor (minSdk 23 — see `docs/release-process.md` for why the FIDO2
 * role specifically needs API 34 and couldn't just be shimmed down), so
 * there is nothing to deep-link to. Deliberately a real, separate
 * no-op file rather than an `if (isFullFlavor)` branch inside the shared
 * `SettingsScreen` composable — this is the one piece of that screen the
 * "flavor-specific source sets hold only the FIDO2 code path" design
 * actually touches, and it stays exactly that narrow: this function's
 * *body* differs by flavor, its *call site* in `SettingsScreen.kt` does
 * not.
 */
@Composable
fun CredentialProviderSettingsSection() {
}
