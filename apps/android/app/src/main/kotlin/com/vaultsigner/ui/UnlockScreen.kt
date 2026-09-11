package com.vaultsigner.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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

@Composable
fun UnlockScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    var selectedCompartmentId by remember(state.compartments) { mutableStateOf(state.compartments.firstOrNull { !it.unlocked }?.id) }
    var passphrase by remember { mutableStateOf("") }
    var menuExpanded by remember { mutableStateOf(false) }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.unlock_title))

            if (state.compartments.size > 1) {
                val selectedLabel = state.compartments.firstOrNull { it.id == selectedCompartmentId }?.label ?: ""
                OutlinedButton(onClick = { menuExpanded = true }) { Text(selectedLabel.ifBlank { stringResource(R.string.unlock_compartment_picker) }) }
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                    state.compartments.forEach { c ->
                        DropdownMenuItem(text = { Text(c.label) }, onClick = { selectedCompartmentId = c.id; menuExpanded = false })
                    }
                }
            }

            OutlinedTextField(
                value = passphrase, onValueChange = { passphrase = it },
                label = { Text(stringResource(R.string.unlock_master_passphrase_field)) },
                visualTransformation = PasswordVisualTransformation(),
            )
            if (state.error != null) Text(state.error)

            Button(onClick = {
                val compartmentId = selectedCompartmentId ?: return@Button
                viewModel.unlockCompartment(compartmentId, passphrase) {
                    navController.navigate(Routes.KEY_LIST) { popUpTo(Routes.WELCOME) { inclusive = false } }
                }
            }) {
                Text(stringResource(R.string.unlock_unlock_button))
            }
        }
    }
}
