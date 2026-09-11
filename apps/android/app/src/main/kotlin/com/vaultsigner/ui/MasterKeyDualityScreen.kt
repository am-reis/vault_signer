package com.vaultsigner.ui

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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

private const val REPLACE_CONFIRMATION_PHRASE = "REPLACE MY MASTER KEY"

/** Spec §5.3's unskippable, no-default three-card decision — mirrors
 * macOS's `MasterKeyDualityView`. Shown only when
 * [UiState.pendingImport] carries an embedded master key. */
@Composable
fun MasterKeyDualityScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.duality_header))
            Text(stringResource(R.string.duality_subtitle))

            Option1Card(navController, viewModel, state)
            Option2Card(navController, viewModel)
            Option3Card(navController, viewModel, state)

            Button(onClick = { navController.popBackStack() }) { Text(stringResource(R.string.duality_cancel_button)) }
        }
    }
}

@Composable
private fun Option1Card(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    var expanded by remember { mutableStateOf(false) }
    var target by remember { mutableStateOf(state.compartments.firstOrNull { it.unlocked }?.id) }
    Column(modifier = Modifier.padding(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.duality_option1_title) + " (" + stringResource(R.string.duality_recommended_badge) + ")")
        Text(stringResource(R.string.duality_option1_description))
        val unlockedCompartments = state.compartments.filter { it.unlocked }
        if (unlockedCompartments.isEmpty()) {
            Text(stringResource(R.string.duality_option1_no_unlocked_compartment))
        } else {
            OutlinedButton(onClick = { expanded = true }) { Text(unlockedCompartments.firstOrNull { it.id == target }?.label ?: stringResource(R.string.duality_option1_merge_into_picker)) }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                unlockedCompartments.forEach { c -> DropdownMenuItem(text = { Text(c.label) }, onClick = { target = c.id; expanded = false }) }
            }
            Button(onClick = { target?.let { viewModel.mergeReencryptDiscardIncoming(it); navController.popBackStack() } }) {
                Text(stringResource(R.string.duality_use_this_option_button))
            }
        }
    }
}

@Composable
private fun Option2Card(navController: NavHostController, viewModel: AppViewModel) {
    var label by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    Column(modifier = Modifier.padding(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.duality_option2_title))
        Text(stringResource(R.string.duality_option2_description))
        OutlinedTextField(label, { label = it }, label = { Text(stringResource(R.string.duality_option2_label_field)) })
        OutlinedTextField(passphrase, { passphrase = it }, label = { Text(stringResource(R.string.duality_option2_passphrase_field)) }, visualTransformation = PasswordVisualTransformation())
        Button(onClick = { viewModel.mergeSideBySide(label, passphrase); navController.popBackStack() }) {
            Text(stringResource(R.string.duality_use_this_option_button))
        }
    }
}

@Composable
private fun Option3Card(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    var expanded by remember { mutableStateOf(false) }
    var target by remember { mutableStateOf(state.compartments.firstOrNull { it.unlocked }?.id) }
    var incomingPassphrase by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    Column(modifier = Modifier.padding(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.duality_option3_title))
        Text(stringResource(R.string.duality_option3_description))
        val unlockedCompartments = state.compartments.filter { it.unlocked }
        if (unlockedCompartments.isEmpty()) {
            Text(stringResource(R.string.duality_option3_no_unlocked_compartment))
        } else {
            OutlinedButton(onClick = { expanded = true }) { Text(unlockedCompartments.firstOrNull { it.id == target }?.label ?: stringResource(R.string.duality_option3_replace_picker)) }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                unlockedCompartments.forEach { c -> DropdownMenuItem(text = { Text(c.label) }, onClick = { target = c.id; expanded = false }) }
            }
            OutlinedTextField(incomingPassphrase, { incomingPassphrase = it }, label = { Text(stringResource(R.string.duality_option3_passphrase_field)) }, visualTransformation = PasswordVisualTransformation())
            Text(stringResource(R.string.duality_option3_confirmation_field_format, REPLACE_CONFIRMATION_PHRASE))
            OutlinedTextField(confirmation, { confirmation = it })
            Button(
                enabled = confirmation == REPLACE_CONFIRMATION_PHRASE,
                onClick = { target?.let { viewModel.mergeReplaceLocalWithIncoming(it, incomingPassphrase, confirmation) }; navController.popBackStack() },
            ) {
                Text(stringResource(R.string.duality_use_this_option_button))
            }
        }
    }
}
