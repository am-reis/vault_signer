package com.vaultsigner.service

import android.content.Context
import android.content.Intent
import com.vaultsigner.credentialprovider.PassphrasePromptActivity
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.TimeUnit
import uniffi.vaultcore.PassphrasePrompter

/**
 * The real, native passphrase-prompt UI for `vaultsigner.sign` (spec §7)
 * and CTAP2 `authenticatorGetAssertion` (spec §6.6) — mirrors macOS's
 * `AlertPassphrasePrompter`/Windows's `WinFormsPassphrasePrompter`: shown
 * only when the target key isn't already warm in the retention cache.
 *
 * [prompt] is called synchronously, across the UniFFI/JNI boundary, on
 * whatever background thread is handling the request (never the main
 * thread — see [VaultSignerService]'s connection-handling threads) and
 * must block until the user answers. There is exactly one prompt in
 * flight at a time by construction (every caller serializes through
 * [VaultSignerService]'s single dispatch path), so a single blocking
 * handoff to [PassphrasePromptActivity] is sufficient — no request-id
 * multiplexing needed.
 */
class AndroidPassphrasePrompter(private val context: Context) : PassphrasePrompter {
    override fun prompt(callerIdentity: String, keyId: String): String? {
        val answerQueue = SynchronousQueue<String?>()
        pendingAnswerQueue = answerQueue

        val intent = Intent(context, PassphrasePromptActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(PassphrasePromptActivity.EXTRA_CALLER_IDENTITY, callerIdentity)
            putExtra(PassphrasePromptActivity.EXTRA_KEY_ID, keyId)
        }
        context.startActivity(intent)

        // No timeout shorter than the caller's own patience: a human is
        // being asked to type a passphrase, not to hit an SLA. The
        // throttling policy (spec §5.5) — not a prompt timeout — is what
        // bounds how long a caller can be kept waiting across repeated
        // wrong attempts.
        return try {
            answerQueue.poll(PROMPT_TIMEOUT_MINUTES, TimeUnit.MINUTES)
        } finally {
            pendingAnswerQueue = null
        }
    }

    companion object {
        private const val PROMPT_TIMEOUT_MINUTES = 5L

        @Volatile
        private var pendingAnswerQueue: SynchronousQueue<String?>? = null

        /** Called by [PassphrasePromptActivity] when the user answers (or cancels, with `null`). */
        fun deliverAnswer(answer: String?) {
            pendingAnswerQueue?.offer(answer)
        }
    }
}
