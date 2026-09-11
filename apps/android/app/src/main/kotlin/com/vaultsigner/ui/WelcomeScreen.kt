package com.vaultsigner.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.vaultsigner.R
import java.io.File

@Composable
fun WelcomeScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    val context = LocalContext.current

    val openDocumentLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val localPath = copyVaultLocally(context, uri)
        if (localPath != null) {
            viewModel.openVault(localPath) { navController.navigate(routeAfterOpen(viewModel)) }
        }
    }

    if (state.vaultOpen) {
        // Reaching Welcome with a vault already open (e.g. process restart
        // while the agent kept it open) — route straight past this screen.
        LaunchedEffect(Unit) { navController.navigate(routeAfterOpen(viewModel)) }
    }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.welcome_subtitle))

            Button(onClick = { navController.navigate(Routes.CREATE_VAULT) }) {
                Text(stringResource(R.string.welcome_create_button))
            }
            OutlinedButton(onClick = { openDocumentLauncher.launch(arrayOf("*/*")) }) {
                Text(stringResource(R.string.welcome_open_button))
            }

            Text(stringResource(R.string.welcome_recent_vaults_header))
            if (state.knownVaults.isEmpty()) {
                Text(stringResource(R.string.welcome_no_recent_vaults))
            } else {
                LazyColumn {
                    items(state.knownVaults) { vault ->
                        ListItem(
                            headlineContent = { Text(File(vault.path).name) },
                            supportingContent = { Text(vault.path) },
                            leadingContent = {
                                if (!vault.available) {
                                    Icon(Icons.Filled.Warning, contentDescription = stringResource(R.string.welcome_vault_unavailable_tooltip))
                                }
                            },
                            trailingContent = {
                                TextButton(onClick = { viewModel.forgetKnownVault(vault.path) }) {
                                    Text(stringResource(R.string.welcome_forget_button))
                                }
                            },
                            modifier = if (vault.available) {
                                Modifier.clickable {
                                    viewModel.openVault(vault.path) { navController.navigate(routeAfterOpen(viewModel)) }
                                }
                            } else Modifier,
                        )
                    }
                }
            }

            TextButton(onClick = { navController.navigate(Routes.MANAGE_VAULTS) }) {
                Text(stringResource(R.string.welcome_manage_vaults_button))
            }
        }
    }
}

/** Reads the freshest state directly rather than a composable's captured
 * snapshot, since this runs inside an `onDone` callback fired after an
 * async RPC round trip updates the ViewModel's state. */
private fun routeAfterOpen(viewModel: AppViewModel): String =
    if (viewModel.state.value.compartments.size == 1) Routes.KEY_LIST else Routes.UNLOCK

private fun copyVaultLocally(context: android.content.Context, uri: Uri): String? {
    val resolver = context.contentResolver
    val fileName = queryDisplayName(context, uri) ?: "Imported.vlt"
    val destDir = context.getExternalFilesDir(null) ?: context.filesDir
    val destFile = File(destDir, fileName)
    return try {
        resolver.openInputStream(uri)?.use { input ->
            destFile.outputStream().use { output -> input.copyTo(output) }
        }
        destFile.absolutePath
    } catch (e: Exception) {
        null
    }
}

private fun queryDisplayName(context: android.content.Context, uri: Uri): String? {
    val cursor = context.contentResolver.query(uri, null, null, null, null) ?: return null
    cursor.use {
        val nameIndex = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
        if (nameIndex >= 0 && it.moveToFirst()) return it.getString(nameIndex)
    }
    return null
}
