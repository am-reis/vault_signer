package com.vaultsigner.ui

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.credentials.CredentialManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Arrangement.SpaceBetween
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.vaultsigner.R

@Composable
fun SettingsScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    var showAutoUnlockConfirm by remember { mutableStateOf(false) }
    val compartmentId = state.selectedCompartmentId
    val context = LocalContext.current

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.settings_title))

            // Spec §6.3 item 4.5: deep link to the system's Credential
            // Manager settings so the user can enable VaultSigner as a
            // provider — `CredentialManager.createSettingsPendingIntent()`
            // is the real, current API for this (androidx.credentials
            // 1.5.0+), verified against Android's own developer docs
            // rather than assumed from the spec text's more generic
            // wording.
            Button(onClick = {
                val credentialManager = CredentialManager.create(context)
                context.startIntentSender(credentialManager.createSettingsPendingIntent().intentSender, null, 0, 0, 0)
            }) {
                Text(stringResource(R.string.android_settings_enable_credential_provider_button))
            }
            Text(stringResource(R.string.android_settings_enable_credential_provider_footer))

            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = SpaceBetween) {
                Text(stringResource(R.string.settings_start_at_login_toggle))
                Switch(checked = state.autostartEnabled, onCheckedChange = { viewModel.setAutostart(it) })
            }
            Text(stringResource(R.string.settings_start_at_login_footer))

            val autoUnlockEnabled = compartmentId != null && compartmentId in state.autoUnlockEnabledCompartmentIds
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = SpaceBetween) {
                Text(stringResource(R.string.settings_auto_unlock_toggle))
                Switch(checked = autoUnlockEnabled, onCheckedChange = { enabled -> if (enabled) showAutoUnlockConfirm = true else compartmentId?.let(viewModel::disableAutoUnlock) })
            }
            Text(stringResource(R.string.settings_auto_unlock_footer))

            Text(stringResource(R.string.settings_backup_header))
            Button(onClick = { navController.navigate(Routes.EXPORT_PACKET) }) { Text(stringResource(R.string.settings_backup_everything_button)) }
            Button(onClick = { navController.navigate(Routes.EXPORT_PACKET) }) { Text(stringResource(R.string.settings_backup_master_only_button)) }

            Text(stringResource(R.string.settings_vaults_header))
            Button(onClick = { navController.navigate(Routes.MANAGE_VAULTS) }) { Text(stringResource(R.string.settings_manage_vaults_button)) }
            Button(onClick = { viewModel.closeVault { navController.navigate(Routes.WELCOME) { popUpTo(0) } } }) { Text(stringResource(R.string.manage_vaults_close_vault_button)) }

            if (showAutoUnlockConfirm && compartmentId != null) {
                AutoUnlockConfirmDialog(
                    onDismiss = { showAutoUnlockConfirm = false },
                    onConfirm = { passphrase -> viewModel.enableAutoUnlock(compartmentId, passphrase) { showAutoUnlockConfirm = false } },
                )
            }
        }
    }
}

@Composable
private fun AutoUnlockConfirmDialog(onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var passphrase by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.settings_auto_unlock_confirm_title)) },
        text = {
            OutlinedTextField(
                passphrase, { passphrase = it },
                label = { Text(stringResource(R.string.settings_auto_unlock_confirm_passphrase_placeholder)) },
                visualTransformation = PasswordVisualTransformation(),
            )
        },
        confirmButton = { TextButton(onClick = { onConfirm(passphrase) }) { Text(stringResource(R.string.settings_auto_unlock_confirm_turn_on_button)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_cancel_button)) } },
    )
}
