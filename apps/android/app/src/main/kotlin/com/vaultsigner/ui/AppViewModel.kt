package com.vaultsigner.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.vaultsigner.data.KnownVault
import com.vaultsigner.data.KnownVaultsStore
import com.vaultsigner.ipc.InternalMethods
import com.vaultsigner.ipc.ManagementClient
import com.vaultsigner.ipc.RpcException
import com.vaultsigner.ipc.jsonArrayOfStrings
import com.vaultsigner.ipc.toStringList
import com.vaultsigner.service.AutostartPrefs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

data class CompartmentUi(val id: String, val label: String, val unlocked: Boolean, val autoUnlockEnabled: Boolean = false)
data class KeyUi(
    val id: String,
    val compartmentId: String,
    val label: String,
    val description: String,
    val resource: String,
    val keyType: String,
    val purpose: String,
    val publicKeyHex: String,
    val tags: List<String>,
)
data class ImportedPacketUi(
    val manifestJson: String,
    val keyBlobsJson: JSONArray,
    val embeddedMasterCompartmentId: String?,
    val embeddedMasterKdfParamsJson: String?,
)
data class MergeOutcomeUi(val warningCount: Int)

data class UiState(
    val loading: Boolean = false,
    val error: String? = null,
    val vaultOpen: Boolean = false,
    val vaultPath: String? = null,
    val knownVaults: List<KnownVault> = emptyList(),
    val compartments: List<CompartmentUi> = emptyList(),
    val selectedCompartmentId: String? = null,
    val keys: List<KeyUi> = emptyList(),
    val selectedKeyId: String? = null,
    val autostartEnabled: Boolean = true,
    val autoUnlockEnabledCompartmentIds: Set<String> = emptySet(),
    val pendingImport: ImportedPacketUi? = null,
    val lastMergeOutcome: MergeOutcomeUi? = null,
    val lastRevealedHex: String? = null,
    val lastExportedPacketB64: String? = null,
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val knownVaultsStore = KnownVaultsStore(application)
    private val _state = MutableStateFlow(UiState(knownVaults = knownVaultsStore.list()))
    val state: StateFlow<UiState> = _state

    init {
        ManagementClient.ensureAgentRunning(application)
        refreshStatusAndSettings()
    }

    private fun launchCall(block: suspend () -> Unit) {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            try {
                block()
            } catch (e: RpcException) {
                _state.update { it.copy(error = "${e.code}: ${e.message}") }
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: e.toString()) }
            } finally {
                _state.update { it.copy(loading = false) }
            }
        }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    private fun refreshStatusAndSettings() = launchCall {
        val status = ManagementClient.call(InternalMethods.STATUS)
        val vaultOpen = status.getBoolean("vault_open")
        val vaultPath = status.optString("vault_path", null)
        _state.update { it.copy(vaultOpen = vaultOpen, vaultPath = vaultPath) }
        if (vaultOpen) refreshCompartments()
        val autostart = ManagementClient.call(InternalMethods.IS_AUTOSTART_ENABLED)
        _state.update { it.copy(autostartEnabled = autostart.getBoolean("enabled")) }
    }

    fun refreshKnownVaults() {
        _state.update { it.copy(knownVaults = knownVaultsStore.list()) }
    }

    fun createVault(path: String, compartmentLabel: String, masterPassphrase: String, onDone: () -> Unit) = launchCall {
        val params = JSONObject()
            .put("path", path).put("compartment_label", compartmentLabel).put("master_passphrase", masterPassphrase)
        ManagementClient.call(InternalMethods.CREATE_VAULT, params)
        knownVaultsStore.recordAccess(path)
        _state.update { it.copy(vaultOpen = true, vaultPath = path, knownVaults = knownVaultsStore.list()) }
        refreshCompartments()
        onDone()
    }

    fun openVault(path: String, onDone: () -> Unit) = launchCall {
        val params = JSONObject().put("path", path)
        ManagementClient.call(InternalMethods.OPEN_VAULT, params)
        knownVaultsStore.recordAccess(path)
        _state.update { it.copy(vaultOpen = true, vaultPath = path, knownVaults = knownVaultsStore.list()) }
        refreshCompartments()
        onDone()
    }

    fun closeVault(onDone: () -> Unit) = launchCall {
        ManagementClient.call(InternalMethods.CLOSE_VAULT)
        _state.update {
            it.copy(vaultOpen = false, vaultPath = null, compartments = emptyList(), keys = emptyList(), selectedCompartmentId = null)
        }
        onDone()
    }

    fun forgetKnownVault(path: String) {
        knownVaultsStore.forget(path)
        refreshKnownVaults()
    }

    fun addKnownVaultWithoutOpening(path: String) {
        knownVaultsStore.addWithoutOpening(path)
        refreshKnownVaults()
    }

    private suspend fun refreshCompartments() {
        val result = ManagementClient.call(InternalMethods.LIST_COMPARTMENTS)
        val arr = result.getJSONArray("compartments")
        val compartments = List(arr.length()) { i ->
            val o = arr.getJSONObject(i)
            CompartmentUi(o.getString("compartment_id"), o.getString("label"), o.getBoolean("unlocked"))
        }
        _state.update { it.copy(compartments = compartments) }
    }

    fun unlockCompartment(compartmentId: String, passphrase: String, onDone: () -> Unit) = launchCall {
        val params = JSONObject().put("compartment_id", compartmentId).put("passphrase", passphrase)
        ManagementClient.call(InternalMethods.UNLOCK_COMPARTMENT, params)
        refreshCompartments()
        selectCompartment(compartmentId)
        onDone()
    }

    fun selectCompartment(compartmentId: String) = launchCall {
        _state.update { it.copy(selectedCompartmentId = compartmentId) }
        refreshKeys(compartmentId)
        refreshAutoUnlockStatus(compartmentId)
    }

    private suspend fun refreshAutoUnlockStatus(compartmentId: String) {
        val params = JSONObject().put("compartment_id", compartmentId)
        val result = ManagementClient.call(InternalMethods.IS_AUTO_UNLOCK_ENABLED, params)
        _state.update {
            val ids = it.autoUnlockEnabledCompartmentIds.toMutableSet()
            if (result.getBoolean("enabled")) ids.add(compartmentId) else ids.remove(compartmentId)
            it.copy(autoUnlockEnabledCompartmentIds = ids)
        }
    }

    private suspend fun refreshKeys(compartmentId: String) {
        val params = JSONObject().put("compartment_id", compartmentId)
        val result = ManagementClient.call(InternalMethods.LIST_KEYS, params)
        val arr = result.getJSONArray("keys")
        val keys = List(arr.length()) { i ->
            val o = arr.getJSONObject(i)
            KeyUi(
                o.getString("key_id"), o.getString("compartment_id"), o.getString("label"),
                o.optString("description", ""), o.optString("resource", ""),
                o.getString("key_type"), o.getString("purpose"), o.getString("public_key_hex"),
                (o.optJSONArray("tags") ?: JSONArray()).toStringList(),
            )
        }
        _state.update { it.copy(keys = keys) }
    }

    fun lockAll(onDone: () -> Unit) = launchCall {
        ManagementClient.call(InternalMethods.LOCK_ALL)
        _state.update { it.copy(compartments = it.compartments.map { c -> c.copy(unlocked = false) }, keys = emptyList()) }
        onDone()
    }

    fun addCompartment(label: String, masterPassphrase: String, onDone: () -> Unit) = launchCall {
        val params = JSONObject().put("label", label).put("master_passphrase", masterPassphrase)
        ManagementClient.call(InternalMethods.ADD_COMPARTMENT, params)
        refreshCompartments()
        onDone()
    }

    fun createKey(
        compartmentId: String, keyType: String, label: String, description: String,
        resource: String, tags: List<String>, passphrase: String, onDone: () -> Unit,
    ) = launchCall {
        val params = JSONObject()
            .put("compartment_id", compartmentId).put("key_type", keyType).put("purpose", "custom-signing")
            .put("label", label).put("description", description).put("resource", resource)
            .put("tags", jsonArrayOfStrings(tags)).put("key_passphrase", passphrase)
        ManagementClient.call(InternalMethods.CREATE_KEY, params)
        refreshKeys(compartmentId)
        onDone()
    }

    fun discardKey(compartmentId: String, keyId: String, confirmText: String, onDone: () -> Unit) = launchCall {
        val params = JSONObject().put("compartment_id", compartmentId).put("key_id", keyId).put("confirm_text", confirmText)
        ManagementClient.call(InternalMethods.DISCARD_KEY, params)
        refreshKeys(compartmentId)
        onDone()
    }

    fun changeKeyPassphrase(compartmentId: String, keyId: String, oldPassphrase: String, newPassphrase: String, onDone: () -> Unit) = launchCall {
        val params = JSONObject().put("compartment_id", compartmentId).put("key_id", keyId)
            .put("old_passphrase", oldPassphrase).put("new_passphrase", newPassphrase)
        ManagementClient.call(InternalMethods.CHANGE_KEY_PASSPHRASE, params)
        onDone()
    }

    fun revealRawKey(compartmentId: String, keyId: String, passphrase: String) = launchCall {
        val params = JSONObject().put("compartment_id", compartmentId).put("key_id", keyId).put("passphrase", passphrase)
        val result = ManagementClient.call(InternalMethods.REVEAL_RAW_KEY_HEX, params)
        _state.update { it.copy(lastRevealedHex = result.getString("raw_key_hex")) }
    }

    fun clearRevealedKey() = _state.update { it.copy(lastRevealedHex = null) }

    fun exportPacket(compartmentId: String, keyIds: List<String>, includeMasterKey: Boolean, encryption: JSONObject) = launchCall {
        val params = JSONObject()
            .put("compartment_id", compartmentId).put("key_ids", jsonArrayOfStrings(keyIds))
            .put("include_master_key", includeMasterKey).put("encryption", encryption)
        val result = ManagementClient.call(InternalMethods.EXPORT_PACKET, params)
        _state.update { it.copy(lastExportedPacketB64 = result.getString("packet_b64")) }
    }

    fun exportSingleKey(compartmentId: String, keyId: String) = launchCall {
        val params = JSONObject().put("compartment_id", compartmentId).put("key_id", keyId)
        val result = ManagementClient.call(InternalMethods.EXPORT_SINGLE_KEY, params)
        _state.update { it.copy(lastExportedPacketB64 = result.getString("packet_b64")) }
    }

    fun clearExportedPacket() = _state.update { it.copy(lastExportedPacketB64 = null) }

    fun importPacket(packetB64: String, transferPassword: String?, onNeedsDuality: () -> Unit, onMerged: () -> Unit) = launchCall {
        val params = JSONObject().put("packet_b64", packetB64)
        if (transferPassword != null) params.put("transfer_password", transferPassword)
        val result = ManagementClient.call(InternalMethods.IMPORT_PACKET, params)
        val embeddedCompartmentId = result.optString("embedded_master_compartment_id", null)
        val info = ImportedPacketUi(
            result.getString("manifest_json"), result.getJSONArray("key_blobs"),
            embeddedCompartmentId, result.optString("embedded_master_kdf_params_json", null),
        )
        _state.update { it.copy(pendingImport = info) }
        if (embeddedCompartmentId != null) onNeedsDuality() else {
            // No embedded master key: merge straight into the currently
            // selected compartment (spec §5.3's only path when there is
            // no duality decision to make).
            val targetCompartment = _state.value.selectedCompartmentId
            if (targetCompartment != null) {
                mergeReencryptDiscardIncoming(targetCompartment, info)
            }
            onMerged()
        }
    }

    fun mergeReencryptDiscardIncoming(targetCompartmentId: String, info: ImportedPacketUi = requireNotNull(_state.value.pendingImport)) = launchCall {
        val params = JSONObject()
            .put("target_compartment_id", targetCompartmentId)
            .put("incoming_manifest_json", info.manifestJson)
            .put("incoming_key_blobs", info.keyBlobsJson)
        val result = ManagementClient.call(InternalMethods.MERGE_REENCRYPT_DISCARD_INCOMING, params)
        finishMerge(result, targetCompartmentId)
    }

    fun mergeSideBySide(newLabel: String, newPassphrase: String) = launchCall {
        val info = requireNotNull(_state.value.pendingImport)
        val params = JSONObject()
            .put("incoming_manifest_json", info.manifestJson).put("incoming_key_blobs", info.keyBlobsJson)
            .put("new_compartment_label", newLabel).put("new_master_passphrase", newPassphrase)
        val result = ManagementClient.call(InternalMethods.MERGE_SIDE_BY_SIDE, params)
        refreshCompartments()
        finishMerge(result, null)
    }

    fun mergeReplaceLocalWithIncoming(targetCompartmentId: String, incomingMasterPassphrase: String, confirmationPhrase: String) = launchCall {
        val info = requireNotNull(_state.value.pendingImport)
        val params = JSONObject()
            .put("target_compartment_id", targetCompartmentId)
            .put("incoming_manifest_json", info.manifestJson).put("incoming_key_blobs", info.keyBlobsJson)
            .put("incoming_master_passphrase", incomingMasterPassphrase)
            .put("incoming_kdf_params_json", info.embeddedMasterKdfParamsJson)
            .put("confirmation_phrase", confirmationPhrase)
        val result = ManagementClient.call(InternalMethods.MERGE_REPLACE_LOCAL_WITH_INCOMING, params)
        finishMerge(result, targetCompartmentId)
    }

    private suspend fun finishMerge(result: JSONObject, refreshCompartmentId: String?) {
        val warnings = result.getJSONArray("warnings")
        _state.update { it.copy(pendingImport = null, lastMergeOutcome = MergeOutcomeUi(warnings.length())) }
        if (refreshCompartmentId != null) refreshKeys(refreshCompartmentId)
    }

    fun clearMergeOutcome() = _state.update { it.copy(lastMergeOutcome = null) }

    fun setAutostart(enabled: Boolean) = launchCall {
        val params = JSONObject().put("enabled", enabled)
        ManagementClient.call(InternalMethods.SET_AUTOSTART, params)
        _state.update { it.copy(autostartEnabled = enabled) }
    }

    fun enableAutoUnlock(compartmentId: String, passphrase: String, onDone: () -> Unit) = launchCall {
        val params = JSONObject().put("compartment_id", compartmentId).put("passphrase", passphrase)
        ManagementClient.call(InternalMethods.ENABLE_AUTO_UNLOCK, params)
        refreshAutoUnlockStatus(compartmentId)
        onDone()
    }

    fun disableAutoUnlock(compartmentId: String) = launchCall {
        val params = JSONObject().put("compartment_id", compartmentId)
        ManagementClient.call(InternalMethods.DISABLE_AUTO_UNLOCK, params)
        refreshAutoUnlockStatus(compartmentId)
    }
}
