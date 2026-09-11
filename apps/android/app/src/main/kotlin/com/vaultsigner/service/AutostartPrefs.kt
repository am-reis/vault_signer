package com.vaultsigner.service

import android.content.Context

/**
 * "Start VaultSigner at login/startup" (spec §8), default on. A plain
 * `SharedPreferences` flag rather than an `internal.*`-only concept,
 * because [BootCompletedReceiver] must read it in a cold process, before
 * [VaultSignerService] (and therefore any `Vault`) necessarily exists —
 * unlike every other setting, this one can't be "ask the agent."
 * [com.vaultsigner.service.ManagementHandlers] still owns writing it (spec
 * follows Windows's server-side-RPC shape for this toggle, not macOS's
 * client-side-only one — see `ManagementProtocol.kt`'s doc comment), it
 * just persists somewhere any process of this app can read directly.
 */
object AutostartPrefs {
    private const val PREFS_NAME = "autostart_prefs"
    private const val KEY_ENABLED = "enabled"

    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, true) // default on, per spec §8

    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_ENABLED, enabled).apply()
    }
}
