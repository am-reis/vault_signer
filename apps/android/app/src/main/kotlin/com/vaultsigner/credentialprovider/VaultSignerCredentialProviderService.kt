package com.vaultsigner.credentialprovider

import android.app.PendingIntent
import android.content.Intent
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import com.vaultsigner.R
import com.vaultsigner.service.AgentState
import org.json.JSONObject

/**
 * Spec §6.3: `CredentialProviderService` (androidx.credentials, API 34+).
 * Runs in the `:agent` process (`AndroidManifest.xml`), sharing
 * [AgentState] directly with [com.vaultsigner.service.VaultSignerService] —
 * deliberately never opens its own separate `Vault`, unlike macOS's
 * `CredentialProviderViewController` (a known, documented gap there,
 * forced by that platform's genuinely separate-process extension model;
 * Android's single-APK, multi-component-one-process model avoids it by
 * construction). See `AgentState`'s own doc comment for the full
 * reasoning.
 *
 * **Honesty note (mirrors this project's convention of disclosing real
 * platform verification limits, e.g. macOS's paid-developer-account block
 * on item 2.7, Windows's OS-build block on item 3.4):** the WebAuthn
 * response-JSON construction below (`clientDataJSON` assembly,
 * base64url field encoding) follows the W3C WebAuthn `PublicKeyCredential.
 * toJSON()` shape as documented, but has NOT been verified end-to-end
 * against a real relying party in a real browser (spec item 4.4's
 * interop requirement) — that needs a follow-up session with actual
 * device/browser testing, not something reasoned about from source
 * alone. Treat this class as structurally real but functionally
 * unverified until that happens.
 */
class VaultSignerCredentialProviderService : CredentialProviderService() {

    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        val vault = AgentState.vault
        if (vault == null) {
            callback.onResult(BeginGetCredentialResponse())
            return
        }

        val entries = mutableListOf<PublicKeyCredentialEntry>()
        for (option in request.beginGetCredentialOptions) {
            if (option !is BeginGetPublicKeyCredentialOption) continue
            val rpId = try {
                JSONObject(option.requestJson).optString("rpId")
            } catch (e: Exception) {
                continue
            }
            if (rpId.isEmpty()) continue

            for (candidate in vault.credentialCandidates(rpId)) {
                val pendingIntent = createResultPendingIntent(ACTION_GET_ASSERTION, candidate.keyId)
                entries.add(
                    PublicKeyCredentialEntry(
                        context = applicationContext,
                        // CredentialCandidateInfo carries no label of its
                        // own (just key_id/credential_id_b64/discoverable)
                        // — look it up from the owning compartment's key
                        // list, same resolution AndroidPassphrasePrompter
                        // does for its own display text.
                        username = labelForKey(vault, candidate.keyId) ?: candidate.keyId,
                        pendingIntent = pendingIntent,
                        beginGetPublicKeyCredentialOption = option,
                    )
                )
            }
        }
        callback.onResult(BeginGetCredentialResponse(credentialEntries = entries))
    }

    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        if (request !is BeginCreatePublicKeyCredentialRequest || AgentState.vault == null) {
            callback.onResult(BeginCreateCredentialResponse())
            return
        }
        // Spec §5.1's note (also on macOS/Windows): registering a *new*
        // passkey needs a target compartment + a fresh key passphrase —
        // there is exactly one `CreateEntry` today (the currently
        // unlocked compartment, if there is one), rather than a picker
        // across multiple unlocked compartments; a real gap if a user
        // keeps several compartments unlocked at once, not yet handled.
        val compartmentId = AgentState.vault?.listCompartments()?.firstOrNull { it.unlocked }?.compartmentId
        val entries = if (compartmentId != null) {
            listOf(CreateEntry(compartmentId, createResultPendingIntent(ACTION_MAKE_CREDENTIAL, compartmentId)))
        } else {
            emptyList()
        }
        callback.onResult(BeginCreateCredentialResponse(createEntries = entries))
    }

    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<Void?, androidx.credentials.exceptions.ClearCredentialException>,
    ) {
        callback.onResult(null)
    }

    private fun createResultPendingIntent(action: String, extraId: String): PendingIntent {
        val intent = Intent(action).setPackage(packageName).apply {
            setClass(applicationContext, PasskeyCompletionActivity::class.java)
            putExtra(PasskeyCompletionActivity.EXTRA_ID, extraId)
        }
        return PendingIntent.getActivity(
            applicationContext, extraId.hashCode(), intent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    companion object {
        const val ACTION_GET_ASSERTION = "com.vaultsigner.app.GET_ASSERTION"
        const val ACTION_MAKE_CREDENTIAL = "com.vaultsigner.app.MAKE_CREDENTIAL"

        fun labelForKey(vault: uniffi.vaultcore.Vault, keyId: String): String? =
            vault.listCompartments()
                .filter { it.unlocked }
                .flatMap { vault.listKeys(it.compartmentId) }
                .firstOrNull { it.keyId == keyId }
                ?.label
    }
}
