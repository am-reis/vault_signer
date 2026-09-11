package com.vaultsigner.ui

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.vaultsigner.R
import java.io.File

@Composable
fun CreateVaultScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    val context = LocalContext.current
    var fileName by remember { mutableStateOf("Personal.vlt") }
    var compartmentLabel by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var confirmPassphrase by remember { mutableStateOf("") }
    var mismatch by remember { mutableStateOf(false) }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.createvault_title))
            OutlinedTextField(
                value = fileName, onValueChange = { fileName = it },
                label = { Text(stringResource(R.string.welcome_filename_placeholder)) },
                modifier = Modifier.testTag(TestTags.CREATE_VAULT_FILENAME),
            )
            OutlinedTextField(
                value = compartmentLabel, onValueChange = { compartmentLabel = it },
                label = { Text(stringResource(R.string.createvault_compartment_label_field)) },
                modifier = Modifier.testTag(TestTags.CREATE_VAULT_COMPARTMENT_LABEL),
            )
            OutlinedTextField(
                value = passphrase, onValueChange = { passphrase = it },
                label = { Text(stringResource(R.string.createvault_master_passphrase_field)) },
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.testTag(TestTags.CREATE_VAULT_MASTER_PASSPHRASE),
            )
            OutlinedTextField(
                value = confirmPassphrase, onValueChange = { confirmPassphrase = it },
                label = { Text(stringResource(R.string.createvault_confirm_passphrase_field)) },
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.testTag(TestTags.CREATE_VAULT_CONFIRM_PASSPHRASE),
            )
            if (mismatch) Text(stringResource(R.string.common_passphrases_dont_match))
            if (state.error != null) Text(state.error)

            Button(
                onClick = {
                    if (passphrase != confirmPassphrase) {
                        mismatch = true
                        return@Button
                    }
                    mismatch = false
                    val destDir = context.getExternalFilesDir(null) ?: context.filesDir
                    val path = File(destDir, fileName).absolutePath
                    viewModel.createVault(path, compartmentLabel.ifBlank { "Personal" }, passphrase) {
                        navController.navigate(Routes.KEY_LIST) { popUpTo(Routes.WELCOME) { inclusive = true } }
                    }
                },
                modifier = Modifier.testTag(TestTags.CREATE_VAULT_SUBMIT),
            ) {
                Text(stringResource(R.string.createvault_create_button))
            }
        }
    }
}
