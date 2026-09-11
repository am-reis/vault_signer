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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.vaultsigner.R

/** Spec §5.3 option 2's `add_compartment` facility, standalone (mirrors
 * Windows's `CreateCompartmentPage` — macOS never built UI for this). */
@Composable
fun CreateCompartmentScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    var label by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var confirmPassphrase by remember { mutableStateOf("") }
    var mismatch by remember { mutableStateOf(false) }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.createcompartment_title))
            Text(stringResource(R.string.createcompartment_subtitle))
            OutlinedTextField(
                value = label, onValueChange = { label = it },
                label = { Text(stringResource(R.string.createcompartment_label_placeholder)) },
                modifier = Modifier.testTag(TestTags.CREATE_COMPARTMENT_LABEL),
            )
            OutlinedTextField(
                value = passphrase, onValueChange = { passphrase = it },
                label = { Text(stringResource(R.string.createcompartment_master_passphrase_placeholder)) },
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.testTag(TestTags.CREATE_COMPARTMENT_PASSPHRASE),
            )
            OutlinedTextField(
                value = confirmPassphrase, onValueChange = { confirmPassphrase = it },
                label = { Text(stringResource(R.string.createcompartment_confirm_passphrase_placeholder)) },
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.testTag(TestTags.CREATE_COMPARTMENT_CONFIRM_PASSPHRASE),
            )
            if (mismatch) Text(stringResource(R.string.common_passphrases_dont_match))
            if (state.error != null) Text(state.error)

            Button(
                onClick = {
                    if (passphrase != confirmPassphrase) { mismatch = true; return@Button }
                    mismatch = false
                    viewModel.addCompartment(label, passphrase) { navController.popBackStack() }
                },
                modifier = Modifier.testTag(TestTags.CREATE_COMPARTMENT_SUBMIT),
            ) {
                Text(stringResource(R.string.createcompartment_create_button))
            }
        }
    }
}
