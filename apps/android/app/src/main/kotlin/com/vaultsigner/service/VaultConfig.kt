package com.vaultsigner.service

import android.content.Context

/**
 * The last vault path the agent had open — read once at agent cold-start
 * (mirrors macOS's `VaultConfig.loadVaultPath()`/Windows's equivalent) so
 * a reboot with "start at login" on reopens the same vault (and, from
 * there, [ManagementHandlers.autoUnlockCompartments] applies "auto-unlock
 * on startup" per spec §8) without the user having to browse to the file
 * again — same reasoning as spec §5.6's known-vaults list, just for the
 * one vault the agent itself needs to remember across restarts.
 */
object VaultConfig {
    private const val PREFS_NAME = "vault_config"
    private const val KEY_PATH = "current_vault_path"

    fun loadVaultPath(context: Context): String? =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString(KEY_PATH, null)

    fun saveVaultPath(context: Context, path: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().putString(KEY_PATH, path).apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().remove(KEY_PATH).apply()
    }
}
