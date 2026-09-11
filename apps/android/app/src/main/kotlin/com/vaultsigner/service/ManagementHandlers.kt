package com.vaultsigner.service

import android.content.Context
import com.vaultsigner.ipc.InternalErrorCodes
import com.vaultsigner.ipc.InternalMethods
import com.vaultsigner.ipc.buildRpcError
import com.vaultsigner.ipc.buildRpcSuccess
import com.vaultsigner.ipc.toStringList
import org.json.JSONArray
import org.json.JSONObject
import uniffi.vaultcore.CompartmentInfo
import uniffi.vaultcore.FacadeDeviceProfile
import uniffi.vaultcore.FacadeExportEncryption
import uniffi.vaultcore.FacadeKeyType
import uniffi.vaultcore.FacadePurpose
import uniffi.vaultcore.IncomingKeyBlob
import uniffi.vaultcore.KeyInfo
import uniffi.vaultcore.MergeOutcomeInfo
import uniffi.vaultcore.Vault
import android.util.Base64

/**
 * Implements the `internal.*` namespace (spec §8) against [AgentState.vault]
 * — mirrors `ManagementHandlers.swift`/`ManagementHandlers.cs`: the *only*
 * code path in this app allowed to call the mutating `Vault` facade
 * methods. Every request reaching here has already passed
 * [PeerAuthentication.isSelf] in [VaultSignerService].
 */
class ManagementHandlers(private val context: Context) {
    private val autoUnlockStore = AutoUnlockStore(context)

    /** Dispatches one already-authenticated `internal.*` request; never throws. */
    fun handle(method: String, id: Any?, params: JSONObject): String {
        return try {
            val result = dispatch(method, params)
                ?: return buildRpcError(id, "method_not_found", "unknown internal method: $method")
            android.util.Log.i("ManagementHandlers", "OK $method -> $result")
            buildRpcSuccess(id, result)
        } catch (e: NoVaultOpenException) {
            buildRpcError(id, InternalErrorCodes.NO_VAULT_OPEN, e.message ?: "no vault is open")
        } catch (e: Exception) {
            android.util.Log.e("ManagementHandlers", "FAILED $method params=$params", e)
            buildRpcError(id, "invalid_params", e.message ?: e.toString())
        }
    }

    private fun dispatch(method: String, params: JSONObject): JSONObject? = when (method) {
        InternalMethods.STATUS -> status()
        InternalMethods.CREATE_VAULT -> createVault(params)
        InternalMethods.OPEN_VAULT -> openVault(params)
        InternalMethods.CLOSE_VAULT -> closeVault()
        InternalMethods.LIST_COMPARTMENTS -> listCompartments()
        InternalMethods.UNLOCK_COMPARTMENT -> unlockCompartment(params)
        InternalMethods.LOCK_COMPARTMENT -> lockCompartment(params)
        InternalMethods.LOCK_ALL -> lockAll()
        InternalMethods.ADD_COMPARTMENT -> addCompartment(params)
        InternalMethods.LIST_KEYS -> listKeys(params)
        InternalMethods.CREATE_KEY -> createKey(params)
        InternalMethods.DISCARD_KEY -> discardKey(params)
        InternalMethods.CHANGE_KEY_PASSPHRASE -> changeKeyPassphrase(params)
        InternalMethods.REVEAL_RAW_KEY_HEX -> revealRawKeyHex(params)
        InternalMethods.UNLOCK_KEY -> unlockKey(params)
        InternalMethods.EXPORT_PACKET -> exportPacket(params)
        InternalMethods.EXPORT_SINGLE_KEY -> exportSingleKey(params)
        InternalMethods.IMPORT_PACKET -> importPacket(params)
        InternalMethods.MERGE_REENCRYPT_DISCARD_INCOMING -> mergeReencryptDiscardIncoming(params)
        InternalMethods.MERGE_SIDE_BY_SIDE -> mergeSideBySide(params)
        InternalMethods.MERGE_REPLACE_LOCAL_WITH_INCOMING -> mergeReplaceLocalWithIncoming(params)
        InternalMethods.SET_AUTOSTART -> setAutostart(params)
        InternalMethods.IS_AUTOSTART_ENABLED -> isAutostartEnabled()
        InternalMethods.ENABLE_AUTO_UNLOCK -> enableAutoUnlock(params)
        InternalMethods.DISABLE_AUTO_UNLOCK -> disableAutoUnlock(params)
        InternalMethods.IS_AUTO_UNLOCK_ENABLED -> isAutoUnlockEnabled(params)
        else -> null
    }

    private fun vault(): Vault = AgentState.vault ?: throw NoVaultOpenException()

    private fun status(): JSONObject {
        val obj = JSONObject()
        obj.put("vault_open", AgentState.vault != null)
        obj.put("vault_path", AgentState.vaultPath ?: JSONObject.NULL)
        return obj
    }

    private fun createVault(params: JSONObject): JSONObject {
        val path = params.getString("path")
        val label = params.getString("compartment_label")
        val passphrase = params.getString("master_passphrase")
        // Android is always the "mobile" KDF target (spec §4.2) — there is
        // no device-profile choice to surface in this app's UI, unlike the
        // desktop platforms.
        val vault = Vault.create(path, label, passphrase, FacadeDeviceProfile.MOBILE)
        AgentState.vault = vault
        AgentState.vaultPath = path
        VaultConfig.saveVaultPath(context, path)
        return compartmentsResult(vault)
    }

    private fun openVault(params: JSONObject): JSONObject {
        val path = params.getString("path")
        AgentState.vault?.close()
        val vault = Vault.open(path)
        AgentState.vault = vault
        AgentState.vaultPath = path
        VaultConfig.saveVaultPath(context, path)
        autoUnlockCompartments(vault)
        return compartmentsResult(vault)
    }

    private fun closeVault(): JSONObject {
        AgentState.vault?.lockAll()
        AgentState.vault?.close()
        AgentState.vault = null
        AgentState.vaultPath = null
        VaultConfig.clear(context)
        return JSONObject()
    }

    private fun listCompartments(): JSONObject = compartmentsResult(vault())

    private fun compartmentsResult(vault: Vault): JSONObject {
        val obj = JSONObject()
        obj.put("compartments", JSONArray(vault.listCompartments().map { compartmentJson(it) }))
        return obj
    }

    private fun compartmentJson(c: CompartmentInfo): JSONObject {
        val obj = JSONObject()
        obj.put("compartment_id", c.compartmentId)
        obj.put("label", c.label)
        obj.put("unlocked", c.unlocked)
        return obj
    }

    private fun unlockCompartment(params: JSONObject): JSONObject {
        vault().unlockCompartment(params.getString("compartment_id"), params.getString("passphrase"))
        return JSONObject()
    }

    private fun lockCompartment(params: JSONObject): JSONObject {
        vault().lockCompartment(params.getString("compartment_id"))
        return JSONObject()
    }

    private fun lockAll(): JSONObject {
        vault().lockAll()
        return JSONObject()
    }

    private fun addCompartment(params: JSONObject): JSONObject {
        val info = vault().addCompartment(params.getString("label"), params.getString("master_passphrase"), FacadeDeviceProfile.MOBILE)
        return compartmentJson(info)
    }

    private fun listKeys(params: JSONObject): JSONObject {
        val obj = JSONObject()
        obj.put("keys", JSONArray(vault().listKeys(params.getString("compartment_id")).map { keyJson(it) }))
        return obj
    }

    private fun keyJson(k: KeyInfo): JSONObject {
        val obj = JSONObject()
        obj.put("key_id", k.keyId)
        obj.put("compartment_id", k.compartmentId)
        obj.put("label", k.label)
        obj.put("description", k.description)
        obj.put("resource", k.resource)
        obj.put("key_type", keyTypeToWire(k.keyType))
        obj.put("purpose", purposeToWire(k.purpose))
        obj.put("created_at", k.createdAt)
        obj.put("last_used_at", k.lastUsedAt ?: JSONObject.NULL)
        obj.put("tags", JSONArray(k.tags))
        obj.put("public_key_hex", k.publicKeyHex)
        val fido2 = k.fido2
        if (fido2 != null) {
            val fido2Obj = JSONObject()
            fido2Obj.put("rp_id", fido2.rpId)
            fido2Obj.put("credential_id_b64", fido2.credentialIdB64)
            fido2Obj.put("sign_count", fido2.signCount)
            fido2Obj.put("discoverable", fido2.discoverable)
            obj.put("fido2", fido2Obj)
        }
        return obj
    }

    private fun createKey(params: JSONObject): JSONObject {
        val key = vault().createKey(
            params.getString("compartment_id"),
            keyTypeFromWire(params.getString("key_type")),
            purposeFromWire(params.getString("purpose")),
            params.getString("label"),
            params.optString("description", ""),
            params.optString("resource", ""),
            params.optJSONArray("tags")?.toStringList() ?: emptyList(),
            params.getString("key_passphrase"),
            params.optString("fido2_rp_id", null),
            params.optString("fido2_user_handle_b64", null),
        )
        return keyJson(key)
    }

    private fun discardKey(params: JSONObject): JSONObject {
        vault().discardKey(params.getString("compartment_id"), params.getString("key_id"), params.getString("confirm_text"))
        return JSONObject()
    }

    private fun changeKeyPassphrase(params: JSONObject): JSONObject {
        vault().changeKeyPassphrase(
            params.getString("compartment_id"), params.getString("key_id"),
            params.getString("old_passphrase"), params.getString("new_passphrase"),
        )
        return JSONObject()
    }

    private fun revealRawKeyHex(params: JSONObject): JSONObject {
        val hex = vault().revealRawKeyHex(params.getString("compartment_id"), params.getString("key_id"), params.getString("passphrase"))
        val obj = JSONObject()
        obj.put("raw_key_hex", hex)
        return obj
    }

    private fun unlockKey(params: JSONObject): JSONObject {
        vault().unlockKey(
            params.getString("compartment_id"), params.getString("key_id"),
            params.getString("passphrase"), params.optInt("retention_secs", 30).toUInt(),
        )
        return JSONObject()
    }

    private fun exportPacket(params: JSONObject): JSONObject {
        val bytes = vault().exportPacket(
            params.getString("compartment_id"),
            params.getJSONArray("key_ids").toStringList(),
            params.optBoolean("include_master_key", false),
            exportEncryptionFromWire(params.getJSONObject("encryption")),
        )
        val obj = JSONObject()
        obj.put("packet_b64", Base64.encodeToString(bytes, Base64.NO_WRAP))
        return obj
    }

    private fun exportSingleKey(params: JSONObject): JSONObject {
        val bytes = vault().exportSingleKey(params.getString("compartment_id"), params.getString("key_id"))
        val obj = JSONObject()
        obj.put("packet_b64", Base64.encodeToString(bytes, Base64.NO_WRAP))
        return obj
    }

    private fun importPacket(params: JSONObject): JSONObject {
        val bytes = Base64.decode(params.getString("packet_b64"), Base64.NO_WRAP)
        val info = vault().importPacket(bytes, params.optString("transfer_password", null))
        val obj = JSONObject()
        obj.put("manifest_json", info.manifestJson)
        obj.put("key_blobs", JSONArray(info.keyBlobs.map { incomingKeyBlobJson(it) }))
        obj.put("embedded_master_compartment_id", info.embeddedMasterCompartmentId ?: JSONObject.NULL)
        obj.put("embedded_master_kdf_params_json", info.embeddedMasterKdfParamsJson ?: JSONObject.NULL)
        return obj
    }

    private fun incomingKeyBlobJson(b: IncomingKeyBlob): JSONObject {
        val obj = JSONObject()
        obj.put("key_id", b.keyId)
        obj.put("blob_bytes_b64", Base64.encodeToString(b.blobBytes, Base64.NO_WRAP))
        return obj
    }

    private fun incomingKeyBlobsFromWire(arr: JSONArray): List<IncomingKeyBlob> =
        List(arr.length()) { i ->
            val o = arr.getJSONObject(i)
            IncomingKeyBlob(o.getString("key_id"), Base64.decode(o.getString("blob_bytes_b64"), Base64.NO_WRAP))
        }

    private fun mergeOutcomeJson(outcome: MergeOutcomeInfo): JSONObject {
        val obj = JSONObject()
        val warnings = JSONArray(outcome.warnings.map {
            val w = JSONObject()
            w.put("incoming_key_id", it.incomingKeyId)
            w.put("matched_local_key_id", it.matchedLocalKeyId)
            w.put("matched_in_compartment", it.matchedInCompartment)
            w.put("reason", it.reason)
            w
        })
        obj.put("warnings", warnings)
        val idRemap = JSONArray(outcome.idRemap.map {
            val r = JSONObject()
            r.put("old_key_id", it.oldKeyId)
            r.put("new_key_id", it.newKeyId)
            r
        })
        obj.put("id_remap", idRemap)
        return obj
    }

    private fun mergeReencryptDiscardIncoming(params: JSONObject): JSONObject {
        val outcome = vault().mergeReencryptDiscardIncoming(
            params.getString("target_compartment_id"),
            params.getString("incoming_manifest_json"),
            incomingKeyBlobsFromWire(params.getJSONArray("incoming_key_blobs")),
        )
        return mergeOutcomeJson(outcome)
    }

    private fun mergeSideBySide(params: JSONObject): JSONObject {
        val outcome = vault().mergeSideBySide(
            params.getString("incoming_manifest_json"),
            incomingKeyBlobsFromWire(params.getJSONArray("incoming_key_blobs")),
            params.getString("new_compartment_label"),
            params.getString("new_master_passphrase"),
            FacadeDeviceProfile.MOBILE,
        )
        return mergeOutcomeJson(outcome)
    }

    private fun mergeReplaceLocalWithIncoming(params: JSONObject): JSONObject {
        val outcome = vault().mergeReplaceLocalWithIncoming(
            params.getString("target_compartment_id"),
            params.getString("incoming_manifest_json"),
            incomingKeyBlobsFromWire(params.getJSONArray("incoming_key_blobs")),
            params.getString("incoming_master_passphrase"),
            params.getString("incoming_kdf_params_json"),
            params.getString("confirmation_phrase"),
        )
        return mergeOutcomeJson(outcome)
    }

    private fun setAutostart(params: JSONObject): JSONObject {
        AutostartPrefs.setEnabled(context, params.getBoolean("enabled"))
        return JSONObject()
    }

    private fun isAutostartEnabled(): JSONObject {
        val obj = JSONObject()
        obj.put("enabled", AutostartPrefs.isEnabled(context))
        return obj
    }

    private fun enableAutoUnlock(params: JSONObject): JSONObject {
        val compartmentId = params.getString("compartment_id")
        val passphrase = params.getString("passphrase")
        // The UI is required to have already confirmed this passphrase
        // against the real vault before calling this — re-verify here
        // too, so a stale/incorrect secret is never persisted (spec §8).
        vault().unlockCompartment(compartmentId, passphrase)
        autoUnlockStore.store(compartmentId, passphrase)
        return JSONObject()
    }

    private fun disableAutoUnlock(params: JSONObject): JSONObject {
        autoUnlockStore.remove(params.getString("compartment_id"))
        return JSONObject()
    }

    private fun isAutoUnlockEnabled(params: JSONObject): JSONObject {
        val obj = JSONObject()
        obj.put("enabled", autoUnlockStore.isEnabled(params.getString("compartment_id")))
        return obj
    }

    /** Called right after [Vault.open] (spec §8's auto-unlock, both at
     * agent cold-start and whenever the UI explicitly opens a vault). */
    fun autoUnlockCompartments(vault: Vault) {
        for (compartmentId in autoUnlockStore.enabledCompartmentIds()) {
            val passphrase = autoUnlockStore.retrieve(compartmentId) ?: continue
            try {
                vault.unlockCompartment(compartmentId, passphrase)
            } catch (_: Exception) {
                // A stale/incorrect stored secret must never crash the
                // agent — the compartment just stays locked, same as if
                // auto-unlock were off.
            }
        }
    }

    private fun keyTypeToWire(t: FacadeKeyType): String = when (t) {
        FacadeKeyType.ED25519 -> "ed25519"
        FacadeKeyType.ECDSA_P256 -> "ecdsa-p256"
    }

    private fun keyTypeFromWire(s: String): FacadeKeyType = when (s) {
        "ed25519" -> FacadeKeyType.ED25519
        "ecdsa-p256" -> FacadeKeyType.ECDSA_P256
        else -> throw IllegalArgumentException("unknown key_type: $s")
    }

    private fun purposeToWire(p: FacadePurpose): String = when (p) {
        FacadePurpose.FIDO2 -> "fido2"
        FacadePurpose.CUSTOM_SIGNING -> "custom-signing"
        FacadePurpose.BOTH -> "both"
    }

    private fun purposeFromWire(s: String): FacadePurpose = when (s) {
        "fido2" -> FacadePurpose.FIDO2
        "custom-signing" -> FacadePurpose.CUSTOM_SIGNING
        "both" -> FacadePurpose.BOTH
        else -> throw IllegalArgumentException("unknown purpose: $s")
    }

    private fun exportEncryptionFromWire(obj: JSONObject): FacadeExportEncryption = when (obj.getString("type")) {
        "as_is" -> FacadeExportEncryption.AsIs
        "destination_master_password" -> FacadeExportEncryption.DestinationMasterPassword(obj.getString("password"))
        "one_time_transfer_password" -> FacadeExportEncryption.OneTimeTransferPassword(obj.getString("password"))
        else -> throw IllegalArgumentException("unknown export encryption type")
    }
}

private fun JSONObject.optString(name: String, fallback: String?): String? =
    if (has(name) && !isNull(name)) getString(name) else fallback

class NoVaultOpenException : Exception("no vault is open")
