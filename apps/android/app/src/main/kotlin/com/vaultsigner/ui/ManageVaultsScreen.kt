package com.vaultsigner.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ListItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.vaultsigner.R
import java.io.File

/** Spec §5.6's dedicated management surface, reachable from both Welcome
 * and Settings — mirrors macOS's `ManageVaultsView`. */
@Composable
fun ManageVaultsScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    val context = LocalContext.current
    val addLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        // "Add a known vault without opening it" (spec §5.6) still needs a
        // local, stable path for the record to mean anything later — same
        // SAF-to-local-copy bridge as WelcomeScreen's Open flow.
        val destDir = context.getExternalFilesDir(null) ?: context.filesDir
        val name = queryDisplayNameOrDefault(context, uri)
        val destFile = File(destDir, name)
        context.contentResolver.openInputStream(uri)?.use { input -> destFile.outputStream().use { input.copyTo(it) } }
        viewModel.addKnownVaultWithoutOpening(destFile.absolutePath)
    }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
            Text(stringResource(R.string.manage_vaults_title))
            Text(stringResource(R.string.manage_vaults_subtitle))
            Button(onClick = { addLauncher.launch(arrayOf("*/*")) }) { Text(stringResource(R.string.manage_vaults_add_button)) }

            if (state.knownVaults.isEmpty()) {
                Text(stringResource(R.string.manage_vaults_no_vaults))
            } else {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(state.knownVaults) { vault ->
                        ListItem(
                            headlineContent = { Text(File(vault.path).name) },
                            supportingContent = { Text(vault.path) },
                            trailingContent = { TextButton(onClick = { viewModel.forgetKnownVault(vault.path) }) { Text(stringResource(R.string.welcome_forget_button)) } },
                        )
                    }
                }
            }
        }
    }
}

private fun queryDisplayNameOrDefault(context: android.content.Context, uri: Uri): String {
    val cursor = context.contentResolver.query(uri, null, null, null, null)
    cursor?.use {
        val idx = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
        if (idx >= 0 && it.moveToFirst()) return it.getString(idx)
    }
    return "Vault.vlt"
}
