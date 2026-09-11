package com.vaultsigner.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * "Start VaultSigner at login/startup" (spec §8, default on) — Android's
 * equivalent of launchd's `RunAtLoad`/the Windows Service's autostart.
 * Runs in the default process (not `:agent`), so it reads
 * [AutostartPrefs] directly rather than asking an agent that may not be
 * alive yet.
 */
class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!AutostartPrefs.isEnabled(context)) return
        context.startForegroundService(Intent(context, VaultSignerService::class.java))
    }
}
