package com.vaultsigner.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.vaultsigner.R

@Composable
fun KeyDetailScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState, keyId: String) {
    val key = state.keys.firstOrNull { it.id == keyId }
    var showChangePassphrase by remember { mutableStateOf(false) }
    var showReveal by remember { mutableStateOf(false) }
    var showDiscard by remember { mutableStateOf(false) }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (key == null) {
                Text(stringResource(R.string.keydetail_details_section))
                return@Column
            }
            Text(stringResource(R.string.keydetail_details_section))
            Text("${stringResource(R.string.keydetail_label_field)}: ${key.label}")
            Text("${stringResource(R.string.keydetail_description_field)}: ${key.description.ifBlank { stringResource(R.string.keydetail_no_description) }}")
            Text("${stringResource(R.string.keydetail_resource_field)}: ${key.resource}")
            Text("${stringResource(R.string.keydetail_type_purpose_field)}: ${key.keyType} / ${key.purpose}")
            Text("${stringResource(R.string.keydetail_public_key_field)}: ${key.publicKeyHex.take(16)}…")
            Text("${stringResource(R.string.keydetail_tags_field)}: ${key.tags.joinToString(", ")}")

            Text(stringResource(R.string.keydetail_actions_section))
            Button(onClick = { showChangePassphrase = true }) { Text(stringResource(R.string.keydetail_change_passphrase_button)) }
            Button(onClick = { showReveal = true }) { Text(stringResource(R.string.keydetail_reveal_raw_key_button)) }
            Button(onClick = { viewModel.exportSingleKey(key.compartmentId, key.id) }) { Text(stringResource(R.string.keydetail_export_button)) }

            Text(stringResource(R.string.keydetail_danger_zone_label))
            Button(onClick = { showDiscard = true }) { Text(stringResource(R.string.keydetail_discard_button)) }

            if (state.lastExportedPacketB64 != null) {
                Text(state.lastExportedPacketB64.take(40) + "…")
                TextButton(onClick = { viewModel.clearExportedPacket() }) { Text(stringResource(R.string.common_ok_button)) }
            }

            if (showChangePassphrase) {
                ChangePassphraseDialog(
                    onDismiss = { showChangePassphrase = false },
                    onConfirm = { old, new -> viewModel.changeKeyPassphrase(key.compartmentId, key.id, old, new) { showChangePassphrase = false } },
                )
            }
            if (showReveal) {
                RevealRawKeyDialog(
                    revealedHex = state.lastRevealedHex,
                    onDismiss = { showReveal = false; viewModel.clearRevealedKey() },
                    onSubmit = { passphrase -> viewModel.revealRawKey(key.compartmentId, key.id, passphrase) },
                )
            }
            if (showDiscard) {
                DiscardKeyDialog(
                    expectedText = key.resource.ifBlank { key.label },
                    onDismiss = { showDiscard = false },
                    onConfirm = { text -> viewModel.discardKey(key.compartmentId, key.id, text) { navController.popBackStack() } },
                )
            }
        }
    }
}

@Composable
private fun ChangePassphraseDialog(onDismiss: () -> Unit, onConfirm: (old: String, new: String) -> Unit) {
    var old by remember { mutableStateOf("") }
    var new by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.changepassphrase_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(old, { old = it }, label = { Text(stringResource(R.string.changepassphrase_current_field)) }, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(new, { new = it }, label = { Text(stringResource(R.string.changepassphrase_new_field)) }, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(confirm, { confirm = it }, label = { Text(stringResource(R.string.changepassphrase_confirm_field)) }, visualTransformation = PasswordVisualTransformation())
                if (new != confirm) Text(stringResource(R.string.common_passphrases_dont_match))
            }
        },
        confirmButton = { TextButton(onClick = { if (new == confirm) onConfirm(old, new) }) { Text(stringResource(R.string.changepassphrase_change_button)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_cancel_button)) } },
    )
}

@Composable
private fun RevealRawKeyDialog(revealedHex: String?, onDismiss: () -> Unit, onSubmit: (String) -> Unit) {
    var passphrase by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.revealkey_danger_zone_label)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.revealkey_warning_text))
                if (revealedHex != null) {
                    androidx.compose.foundation.text.selection.SelectionContainer { Text(revealedHex) }
                } else {
                    OutlinedTextField(passphrase, { passphrase = it }, label = { Text(stringResource(R.string.revealkey_passphrase_field)) }, visualTransformation = PasswordVisualTransformation())
                }
            }
        },
        confirmButton = {
            if (revealedHex == null) {
                TextButton(onClick = { onSubmit(passphrase) }) { Text(stringResource(R.string.revealkey_reveal_button)) }
            } else {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_done_button)) }
            }
        },
        dismissButton = { if (revealedHex == null) TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_cancel_button)) } },
    )
}

@Composable
private fun DiscardKeyDialog(expectedText: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.discardkey_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.discardkey_warning_text))
                Text(stringResourceFormat(R.string.discardkey_confirm_prompt_format, expectedText))
                OutlinedTextField(text, { text = it })
            }
        },
        confirmButton = { TextButton(onClick = { onConfirm(text) }, enabled = text == expectedText) { Text(stringResource(R.string.discardkey_discard_button)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_cancel_button)) } },
    )
}

@Composable
private fun stringResourceFormat(resId: Int, vararg args: Any): String = androidx.compose.ui.res.stringResource(resId, *args)
