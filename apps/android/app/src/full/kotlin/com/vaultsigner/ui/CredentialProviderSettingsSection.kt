package com.vaultsigner.ui

import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.credentials.CredentialManager
import com.vaultsigner.R

/**
 * "full"-flavor implementation (spec §6.3 item 4.5): deep link to the
 * system's Credential Manager settings so the user can enable VaultSigner
 * as a provider — `CredentialManager.createSettingsPendingIntent()` is
 * the real, current API for this (androidx.credentials 1.5.0+), verified
 * against Android's own developer docs rather than assumed from the
 * spec text's more generic wording. See `src/lite/`'s sibling file for
 * why this exists as a whole separate composable rather than an `if` in
 * the shared `SettingsScreen`.
 */
@Composable
fun CredentialProviderSettingsSection() {
    val context = LocalContext.current
    Button(onClick = {
        val credentialManager = CredentialManager.create(context)
        context.startIntentSender(credentialManager.createSettingsPendingIntent().intentSender, null, 0, 0, 0)
    }) {
        Text(stringResource(R.string.android_settings_enable_credential_provider_button))
    }
    Text(stringResource(R.string.android_settings_enable_credential_provider_footer))
}
