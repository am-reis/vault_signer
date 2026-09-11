package com.vaultsigner.ipc

import org.json.JSONArray
import org.json.JSONObject

/**
 * The `internal.*` method namespace (spec §8): VaultSigner's own
 * management UI process talking to [com.vaultsigner.service.VaultSignerService],
 * over the same local-IPC mechanism (§7's socket) the `vaultsigner.*`
 * namespace uses for third-party apps — never a stable or supported
 * surface for outside callers (see `docs/protocol-integration/README.md`).
 *
 * Message envelope mirrors the custom protocol exactly (spec §7,
 * `PROTOCOL-SPEC.md` §4): one newline-terminated JSON object per line,
 * `{method, params, id}` requests and `{id, result|error}` responses.
 * `vaultsigner.*` requests are answered by `vaultcore::Vault::handle_protocol_request`
 * directly; `internal.*` requests are answered by
 * [com.vaultsigner.service.ManagementHandlers], which is the only thing
 * on this device allowed to call the mutating `Vault` facade methods.
 */
object InternalMethods {
    const val STATUS = "internal.status"
    const val CREATE_VAULT = "internal.create_vault"
    const val OPEN_VAULT = "internal.open_vault"
    const val CLOSE_VAULT = "internal.close_vault"
    const val LIST_COMPARTMENTS = "internal.list_compartments"
    const val UNLOCK_COMPARTMENT = "internal.unlock_compartment"
    const val LOCK_COMPARTMENT = "internal.lock_compartment"
    const val LOCK_ALL = "internal.lock_all"
    const val ADD_COMPARTMENT = "internal.add_compartment"
    const val LIST_KEYS = "internal.list_keys"
    const val CREATE_KEY = "internal.create_key"
    const val DISCARD_KEY = "internal.discard_key"
    const val CHANGE_KEY_PASSPHRASE = "internal.change_key_passphrase"
    const val REVEAL_RAW_KEY_HEX = "internal.reveal_raw_key_hex"
    const val UNLOCK_KEY = "internal.unlock_key"
    const val EXPORT_PACKET = "internal.export_packet"
    const val EXPORT_SINGLE_KEY = "internal.export_single_key"
    const val IMPORT_PACKET = "internal.import_packet"
    const val MERGE_REENCRYPT_DISCARD_INCOMING = "internal.merge_reencrypt_discard_incoming"
    const val MERGE_SIDE_BY_SIDE = "internal.merge_side_by_side"
    const val MERGE_REPLACE_LOCAL_WITH_INCOMING = "internal.merge_replace_local_with_incoming"
    // Autostart is server-side RPC (matching Windows's design, not macOS's
    // client-side-only `SMAppService` call) since Android's "start at
    // boot" toggle must be readable by `BootCompletedReceiver` before the
    // agent process necessarily exists yet — the agent persists the flag
    // to a location that receiver reads directly (see `AutostartPrefs`).
    const val SET_AUTOSTART = "internal.set_autostart"
    const val IS_AUTOSTART_ENABLED = "internal.is_autostart_enabled"
    const val ENABLE_AUTO_UNLOCK = "internal.enable_auto_unlock"
    const val DISABLE_AUTO_UNLOCK = "internal.disable_auto_unlock"
    const val IS_AUTO_UNLOCK_ENABLED = "internal.is_auto_unlock_enabled"
}

/** Error codes specific to this device's `internal.*`/`vaultsigner.*` server, layered on top of
 * `PROTOCOL-SPEC.md` §6's core catalog per §6.1 ("implementation-specific extensions"). */
object InternalErrorCodes {
    const val UNAUTHORIZED_CALLER = "unauthorized_caller"
    const val NO_VAULT_OPEN = "no_vault_open"
}

sealed class RpcOutcome {
    data class Success(val id: Any?, val result: JSONObject) : RpcOutcome()
    data class Failure(val id: Any?, val code: String, val message: String) : RpcOutcome()
}

fun buildRpcRequest(method: String, params: JSONObject, id: Int): String {
    val obj = JSONObject()
    obj.put("method", method)
    obj.put("params", params)
    obj.put("id", id)
    return obj.toString()
}

fun buildRpcSuccess(id: Any?, result: JSONObject): String {
    val obj = JSONObject()
    obj.put("id", id)
    obj.put("result", result)
    return obj.toString()
}

fun buildRpcError(id: Any?, code: String, message: String): String {
    val obj = JSONObject()
    obj.put("id", id)
    val err = JSONObject()
    err.put("code", code)
    err.put("message", message)
    obj.put("error", err)
    return obj.toString()
}

fun parseRpcResponse(line: String): RpcOutcome {
    val obj = JSONObject(line)
    val id = if (obj.has("id") && !obj.isNull("id")) obj.get("id") else null
    val error = obj.optJSONObject("error")
    return if (error != null) {
        RpcOutcome.Failure(id, error.optString("code", "unknown"), error.optString("message", ""))
    } else {
        RpcOutcome.Success(id, obj.optJSONObject("result") ?: JSONObject())
    }
}

fun jsonArrayOfStrings(items: List<String>): JSONArray {
    val arr = JSONArray()
    for (item in items) arr.put(item)
    return arr
}

fun JSONArray.toStringList(): List<String> = List(length()) { i -> getString(i) }

/** Thrown by [ManagementClient] when the server answers with a JSON-RPC `error`. */
class RpcException(val code: String, message: String) : Exception(message)
