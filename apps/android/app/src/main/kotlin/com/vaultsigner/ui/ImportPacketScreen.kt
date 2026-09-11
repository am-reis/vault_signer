package com.vaultsigner.ui

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import android.net.Uri
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.vaultsigner.R

/** Spec §5.3 import flow: unwrap the transfer-encryption layer (if any),
 * then either merge straight in (no embedded master key) or hand off to
 * [MasterKeyDualityScreen] — mirrors macOS's `ImportPacketView`. */
@Composable
fun ImportPacketScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    val context = LocalContext.current
    var packetB64 by remember { mutableStateOf<String?>(null) }
    var needsTransferPassword by remember { mutableStateOf(false) }
    var transferPassword by remember { mutableStateOf("") }

    val pickLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@rememberLauncherForActivityResult
        packetB64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
        needsTransferPassword = false
    }

    fun attemptImport(password: String?) {
        val b64 = packetB64 ?: return
        viewModel.importPacket(
            b64, password,
            onNeedsDuality = { navController.navigate(Routes.MASTER_KEY_DUALITY) },
            onMerged = { navController.popBackStack() },
        )
    }

    LaunchedEffect(packetB64) { if (packetB64 != null) attemptImport(null) }
    LaunchedEffect(state.error) { if (state.error != null && packetB64 != null) needsTransferPassword = true }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.import_title))
            Text(stringResource(R.string.import_subtitle_detailed))
            Button(onClick = { pickLauncher.launch(arrayOf("*/*")) }) { Text(stringResource(R.string.import_choose_file_button)) }

            if (needsTransferPassword) {
                Text(stringResource(R.string.import_transfer_password_prompt))
                OutlinedTextField(
                    transferPassword, { transferPassword = it },
                    label = { Text(stringResource(R.string.import_transfer_password_field)) },
                    visualTransformation = PasswordVisualTransformation(),
                )
                Button(onClick = { viewModel.clearError(); attemptImport(transferPassword) }) { Text(stringResource(R.string.import_continue_button)) }
            }
        }
    }
}
