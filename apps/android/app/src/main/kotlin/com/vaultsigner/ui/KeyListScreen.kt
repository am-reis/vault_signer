package com.vaultsigner.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.navigation.NavHostController
import com.vaultsigner.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KeyListScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    var menuExpanded by remember { mutableStateOf(false) }
    val currentCompartmentId = state.selectedCompartmentId ?: state.compartments.firstOrNull { it.unlocked }?.id

    // The compartment isn't selected yet the first time this screen is
    // reached straight after unlock/create (single-compartment vaults).
    androidx.compose.runtime.LaunchedEffect(currentCompartmentId) {
        if (state.selectedCompartmentId == null && currentCompartmentId != null) viewModel.selectCompartment(currentCompartmentId)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.keylist_default_title)) },
                actions = {
                    IconButton(onClick = { navController.navigate(Routes.CREATE_KEY) }) {
                        Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.keylist_new_key_button))
                    }
                    IconButton(onClick = { navController.navigate(Routes.SETTINGS) }) {
                        Icon(Icons.Filled.Settings, contentDescription = stringResource(R.string.keylist_settings_button))
                    }
                    IconButton(onClick = { viewModel.lockAll { navController.navigate(Routes.WELCOME) { popUpTo(0) } } }) {
                        Icon(Icons.Filled.Lock, contentDescription = stringResource(R.string.keylist_lock_button))
                    }
                    IconButton(onClick = { menuExpanded = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.keylist_import_export_menu))
                    }
                    DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.keylist_export_packet_button)) }, onClick = { menuExpanded = false; navController.navigate(Routes.EXPORT_PACKET) })
                        DropdownMenuItem(text = { Text(stringResource(R.string.keylist_import_packet_button)) }, onClick = { menuExpanded = false; navController.navigate(Routes.IMPORT_PACKET) })
                        DropdownMenuItem(text = { Text(stringResource(R.string.keylist_new_compartment_link)) }, onClick = { menuExpanded = false; navController.navigate(Routes.CREATE_COMPARTMENT) })
                    }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize()) {
            if (state.keys.isEmpty()) {
                Text(stringResource(R.string.keylist_no_keys_combined), modifier = Modifier.fillMaxSize())
            } else {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(state.keys) { key ->
                        val subtitle = "${key.resource.ifBlank { stringResource(R.string.keylist_no_resource) }} · ${key.keyType} · ${key.purpose}"
                        ListItem(
                            headlineContent = { Text(key.label) },
                            supportingContent = { Text(subtitle) },
                            modifier = Modifier.clickable { navController.navigate("${Routes.KEY_DETAIL}/${key.id}") },
                        )
                    }
                }
            }
        }
    }
}
