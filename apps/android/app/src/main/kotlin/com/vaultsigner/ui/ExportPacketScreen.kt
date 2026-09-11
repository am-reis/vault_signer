package com.vaultsigner.ui

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import android.net.Uri
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
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
import org.json.JSONObject

private enum class EncryptionChoice { AS_IS, DESTINATION_PASSWORD, ONE_TIME_PASSWORD }

/** Spec §5.2/§5.2.2 export flow: key selection, "include master key"
 * (§5.2.1), and all three transfer-encryption choices, uncollapsed with
 * no default selected — mirrors macOS's `ExportPacketView`. Also serves
 * as spec §5.4's "back up everything" (all keys pre-selected, master key
 * forced on) when reached from Settings. */
@Composable
fun ExportPacketScreen(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    val context = LocalContext.current
    var selectedKeyIds by remember { mutableStateOf(setOf<String>()) }
    var includeMasterKey by remember { mutableStateOf(false) }
    var choice by remember { mutableStateOf<EncryptionChoice?>(null) }
    var destinationPassword by remember { mutableStateOf("") }
    var transferPassword by remember { mutableStateOf("") }
    var confirmTransferPassword by remember { mutableStateOf("") }

    val saveLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri: Uri? ->
        val bytesB64 = state.lastExportedPacketB64
        if (uri != null && bytesB64 != null) {
            context.contentResolver.openOutputStream(uri)?.use { it.write(Base64.decode(bytesB64, Base64.NO_WRAP)) }
        }
        viewModel.clearExportedPacket()
    }

    LaunchedEffect(state.lastExportedPacketB64) {
        if (state.lastExportedPacketB64 != null) saveLauncher.launch("export.vltpack")
    }

    Scaffold { padding ->
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.exportpacket_keys_to_include_header))
            state.keys.forEach { key ->
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Checkbox(
                        checked = selectedKeyIds.contains(key.id),
                        onCheckedChange = { checked -> selectedKeyIds = if (checked) selectedKeyIds + key.id else selectedKeyIds - key.id },
                    )
                    Text(key.label)
                }
            }

            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Checkbox(checked = includeMasterKey, onCheckedChange = { includeMasterKey = it })
                Text(stringResource(R.string.exportpacket_include_master_toggle))
            }
            Text(stringResource(R.string.exportpacket_include_master_explanation))

            Text(stringResource(R.string.exportpacket_protect_with_label))
            EncryptionOptionCard(
                selected = choice == EncryptionChoice.AS_IS,
                onSelect = { choice = EncryptionChoice.AS_IS },
                title = stringResource(R.string.exportpacket_option_asis_title),
                detail = stringResource(R.string.exportpacket_option_asis_detail),
            )
            EncryptionOptionCard(
                selected = choice == EncryptionChoice.DESTINATION_PASSWORD,
                onSelect = { choice = EncryptionChoice.DESTINATION_PASSWORD },
                title = stringResource(R.string.exportpacket_option_destination_title),
                detail = stringResource(R.string.exportpacket_option_destination_detail),
            ) {
                OutlinedTextField(
                    destinationPassword, { destinationPassword = it },
                    label = { Text(stringResource(R.string.exportpacket_option_destination_field)) },
                    visualTransformation = PasswordVisualTransformation(),
                )
            }
            EncryptionOptionCard(
                selected = choice == EncryptionChoice.ONE_TIME_PASSWORD,
                onSelect = { choice = EncryptionChoice.ONE_TIME_PASSWORD },
                title = stringResource(R.string.exportpacket_option_transfer_title),
                detail = stringResource(R.string.exportpacket_option_transfer_detail),
            ) {
                OutlinedTextField(transferPassword, { transferPassword = it }, label = { Text(stringResource(R.string.exportpacket_transfer_passphrase_field)) }, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(confirmTransferPassword, { confirmTransferPassword = it }, label = { Text(stringResource(R.string.exportpacket_confirm_transfer_field)) }, visualTransformation = PasswordVisualTransformation())
            }

            if (state.error != null) Text(state.error)

            Button(
                enabled = choice != null && (selectedKeyIds.isNotEmpty() || includeMasterKey),
                onClick = {
                    val compartmentId = state.selectedCompartmentId ?: return@Button
                    val encryption = when (choice) {
                        EncryptionChoice.AS_IS -> JSONObject().put("type", "as_is")
                        EncryptionChoice.DESTINATION_PASSWORD -> JSONObject().put("type", "destination_master_password").put("password", destinationPassword)
                        EncryptionChoice.ONE_TIME_PASSWORD -> JSONObject().put("type", "one_time_transfer_password").put("password", transferPassword)
                        null -> return@Button
                    }
                    viewModel.exportPacket(compartmentId, selectedKeyIds.toList(), includeMasterKey, encryption)
                },
            ) {
                Text(stringResource(R.string.exportpacket_export_button))
            }
        }
    }
}

@Composable
private fun EncryptionOptionCard(selected: Boolean, onSelect: () -> Unit, title: String, detail: String, extra: (@Composable () -> Unit)? = null) {
    Column(modifier = Modifier.selectable(selected = selected, onClick = onSelect).padding(8.dp)) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            RadioButton(selected = selected, onClick = onSelect)
            Text(title)
        }
        Text(detail)
        if (selected && extra != null) extra()
    }
}
