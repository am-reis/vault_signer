package com.vaultsigner.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class KnownVault(val path: String, val lastAccessedAt: Long, val available: Boolean)

/**
 * Spec §5.6 "Known vaults": local device state only — "never written into
 * any `.vlt`/`.vltpack`/`.vltkey` file, never synced, and contains no
 * passphrases or key material." Lives entirely in the UI (default)
 * process; mirrors macOS's `KnownVaultsStore.swift` (a plain path list,
 * not security-scoped bookmarks, since this app doesn't need App-Sandbox-
 * style bookmarks — Android's storage model doesn't force that the way
 * macOS's sandbox can).
 */
class KnownVaultsStore(context: Context) {
    private val file = File(context.filesDir, "known_vaults.json")

    fun list(): List<KnownVault> {
        if (!file.exists()) return emptyList()
        val arr = JSONArray(file.readText())
        val vaults = List(arr.length()) { i ->
            val o = arr.getJSONObject(i)
            val path = o.getString("path")
            KnownVault(path, o.getLong("last_accessed_at"), File(path).exists())
        }
        return vaults.sortedByDescending { it.lastAccessedAt }
    }

    fun recordAccess(path: String) {
        val existing = list().filterNot { it.path == path }
        val updated = existing + KnownVault(path, System.currentTimeMillis(), true)
        save(updated)
    }

    fun addWithoutOpening(path: String) {
        if (list().any { it.path == path }) return
        recordAccess(path)
    }

    fun forget(path: String) {
        save(list().filterNot { it.path == path })
    }

    private fun save(vaults: List<KnownVault>) {
        val arr = JSONArray()
        for (v in vaults) {
            val o = JSONObject()
            o.put("path", v.path)
            o.put("last_accessed_at", v.lastAccessedAt)
            arr.put(o)
        }
        file.writeText(arr.toString())
    }
}
