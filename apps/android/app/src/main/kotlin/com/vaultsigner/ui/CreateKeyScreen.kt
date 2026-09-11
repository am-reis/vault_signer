package com.vaultsigner.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
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

/**
 * Spec §5.1 "Create key" — like macOS's `CreateKeyView`, only
 * `custom-signing` purpose is offered here (FIDO2/Both need a live CTAP2
 * ceremony, via [com.vaultsigner.credentialprovider.VaultSignerCredentialProviderService]
 * instead — see `createkey.fido2_explanation`).
 */
@Composable
fun CreateKeyScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    var label by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var resource by remember { mutableStateOf("") }
    var tags by remember { mutableStateOf("") }
    var ed25519 by remember { mutableStateOf(true) }
    var passphrase by remember { mutableStateOf("") }
    var confirmPassphrase by remember { mutableStateOf("") }
    var mismatch by remember { mutableStateOf(false) }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.createkey_title))
            OutlinedTextField(value = label, onValueChange = { label = it }, label = { Text(stringResource(R.string.createkey_label_field)) })
            OutlinedTextField(value = description, onValueChange = { description = it }, label = { Text(stringResource(R.string.createkey_description_field)) })
            OutlinedTextField(value = resource, onValueChange = { resource = it }, label = { Text(stringResource(R.string.createkey_resource_field)) })
            OutlinedTextField(value = tags, onValueChange = { tags = it }, label = { Text(stringResource(R.string.createkey_tags_field)) })

            Text(stringResource(R.string.createkey_key_type_label))
            Row {
                RadioButton(selected = ed25519, onClick = { ed25519 = true })
                Text(stringResource(R.string.common_key_type_ed25519))
                RadioButton(selected = !ed25519, onClick = { ed25519 = false })
                Text(stringResource(R.string.common_key_type_ecdsa_p256))
            }
            Text(stringResource(R.string.createkey_fido2_explanation))

            OutlinedTextField(
                value = passphrase, onValueChange = { passphrase = it },
                label = { Text(stringResource(R.string.createkey_passphrase_field)) },
                visualTransformation = PasswordVisualTransformation(),
            )
            Text(stringResource(R.string.createkey_passphrase_explanation))
            OutlinedTextField(
                value = confirmPassphrase, onValueChange = { confirmPassphrase = it },
                label = { Text(stringResource(R.string.createkey_confirm_passphrase_field)) },
                visualTransformation = PasswordVisualTransformation(),
            )
            if (mismatch) Text(stringResource(R.string.common_passphrases_dont_match))
            if (state.error != null) Text(state.error)

            Button(onClick = {
                if (passphrase != confirmPassphrase) {
                    mismatch = true
                    return@Button
                }
                mismatch = false
                val compartmentId = state.selectedCompartmentId ?: return@Button
                viewModel.createKey(
                    compartmentId,
                    if (ed25519) "ed25519" else "ecdsa-p256",
                    label, description, resource,
                    tags.split(",").map { it.trim() }.filter { it.isNotEmpty() },
                    passphrase,
                ) { navController.popBackStack() }
            }) {
                Text(stringResource(R.string.createkey_create_button))
            }
        }
    }
}
