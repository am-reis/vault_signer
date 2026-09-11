package com.vaultsigner.credentialprovider

import android.content.Intent
import android.os.Bundle
import android.util.Base64
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.GetCredentialResponse
import androidx.credentials.PublicKeyCredential
import androidx.credentials.provider.PendingIntentHandler
import com.vaultsigner.service.AgentState
import com.vaultsigner.service.AndroidPassphrasePrompter
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import kotlin.concurrent.thread

/**
 * Completes one FIDO2 ceremony (spec §6.3/§6.6), launched by the
 * `PendingIntent` a [VaultSignerCredentialProviderService] entry carries.
 * A real Activity (not a headless service), and `FLAG_SECURE`d (spec
 * §5.0) since the make-credential branch collects a new key passphrase
 * directly.
 *
 * See [VaultSignerCredentialProviderService]'s class doc for the
 * disclosed, real limit on this class: the WebAuthn response-JSON shape
 * below is unverified against a live relying party.
 */
class PasskeyCompletionActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)

        when (intent.action) {
            VaultSignerCredentialProviderService.ACTION_GET_ASSERTION -> handleGetAssertion()
            VaultSignerCredentialProviderService.ACTION_MAKE_CREDENTIAL -> handleMakeCredential()
            else -> finish()
        }
    }

    private fun handleGetAssertion() {
        val providerRequest = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        val option = providerRequest?.credentialOptions?.firstOrNull()
        val requestJson = (option as? androidx.credentials.GetPublicKeyCredentialOption)?.requestJson
        if (requestJson == null) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        val vault = AgentState.vault
        if (vault == null) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val json = JSONObject(requestJson)
        val rpId = json.getString("rpId")
        val challengeB64Url = json.getString("challenge")
        val allowCredentials = json.optJSONArray("allowCredentials")
        val allowCredentialIds = if (allowCredentials != null) {
            List(allowCredentials.length()) { i -> base64UrlDecode(allowCredentials.getJSONObject(i).getString("id")) }
        } else emptyList()
        val userVerificationRequested = json.optString("userVerification", "preferred") != "discouraged"

        val origin = "android:apk-key-hash:$packageName" // best-effort; see class doc's disclosed caveat
        val clientDataJson = buildClientDataJson("webauthn.get", challengeB64Url, origin)
        val clientDataHash = sha256(clientDataJson.toByteArray(Charsets.UTF_8))

        thread {
            try {
                val result = vault.handleFido2GetAssertionNative(
                    rpId, clientDataHash, allowCredentialIds, userVerificationRequested,
                    true, userVerificationRequested, AndroidPassphrasePrompter(applicationContext),
                )
                val responseJson = JSONObject().apply {
                    put("id", base64UrlEncode(result.credentialId))
                    put("rawId", base64UrlEncode(result.credentialId))
                    put("type", "public-key")
                    put("response", JSONObject().apply {
                        put("clientDataJSON", base64UrlEncode(clientDataJson.toByteArray(Charsets.UTF_8)))
                        put("authenticatorData", base64UrlEncode(result.authenticatorData))
                        put("signature", base64UrlEncode(result.signature))
                        put("userHandle", base64UrlEncode(result.userHandle))
                    })
                }.toString()

                val resultIntent = Intent()
                PendingIntentHandler.setGetCredentialResponse(resultIntent, GetCredentialResponse(PublicKeyCredential(responseJson)))
                setResult(RESULT_OK, resultIntent)
            } catch (e: Exception) {
                setResult(RESULT_CANCELED)
            } finally {
                finish()
            }
        }
    }

    private fun handleMakeCredential() {
        val providerRequest = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
        val createRequest = providerRequest?.callingRequest as? CreatePublicKeyCredentialRequest
        val compartmentId = intent.getStringExtra(EXTRA_ID)
        val vault = AgentState.vault
        if (createRequest == null || compartmentId == null || vault == null) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val json = JSONObject(createRequest.requestJson)
        val rp = json.getJSONObject("rp")
        val rpId = rp.getString("id")
        val user = json.getJSONObject("user")
        val userId = base64UrlDecode(user.getString("id"))
        val userName = user.optString("name", rpId)
        val challengeB64Url = json.getString("challenge")
        val discoverable = json.optJSONObject("authenticatorSelection")?.optString("residentKey") != "discouraged"
        val userVerificationRequested = json.optJSONObject("authenticatorSelection")?.optString("userVerification", "preferred") != "discouraged"
        val excludeCredentials = json.optJSONArray("excludeCredentials")
        val excludeCredentialIds = if (excludeCredentials != null) {
            List(excludeCredentials.length()) { i -> base64UrlDecode(excludeCredentials.getJSONObject(i).getString("id")) }
        } else emptyList()
        val pubKeyCredParams = json.getJSONArray("pubKeyCredParams")
        val algorithms = List(pubKeyCredParams.length()) { i -> pubKeyCredParams.getJSONObject(i).getInt("alg") }

        val origin = "android:apk-key-hash:$packageName" // best-effort; see class doc's disclosed caveat
        val clientDataJson = buildClientDataJson("webauthn.create", challengeB64Url, origin)
        val clientDataHash = sha256(clientDataJson.toByteArray(Charsets.UTF_8))

        setContent {
            MaterialTheme {
                NewPasskeyPassphraseDialog(
                    rpId = rpId,
                    onSubmit = { passphrase ->
                        thread {
                            try {
                                val result = vault.handleFido2MakeCredentialNative(
                                    compartmentId, rpId, userId, clientDataHash, algorithms, excludeCredentialIds,
                                    discoverable, userVerificationRequested, true, userVerificationRequested,
                                    passphrase, userName, "", rpId,
                                )
                                val responseJson = JSONObject().apply {
                                    put("id", base64UrlEncode(result.credentialId))
                                    put("rawId", base64UrlEncode(result.credentialId))
                                    put("type", "public-key")
                                    put("response", JSONObject().apply {
                                        put("clientDataJSON", base64UrlEncode(clientDataJson.toByteArray(Charsets.UTF_8)))
                                        put("attestationObject", base64UrlEncode(result.attestationObject))
                                        put("transports", JSONArray(listOf("internal")))
                                    })
                                }.toString()
                                val resultIntent = Intent()
                                PendingIntentHandler.setCreateCredentialResponse(resultIntent, CreatePublicKeyCredentialResponse(responseJson))
                                setResult(RESULT_OK, resultIntent)
                            } catch (e: Exception) {
                                setResult(RESULT_CANCELED)
                            } finally {
                                finish()
                            }
                        }
                    },
                    onCancel = { setResult(RESULT_CANCELED); finish() },
                )
            }
        }
    }

    private fun buildClientDataJson(type: String, challengeB64Url: String, origin: String): String =
        JSONObject().put("type", type).put("challenge", challengeB64Url).put("origin", origin).toString()

    companion object {
        const val EXTRA_ID = "id"
    }
}

@androidx.compose.runtime.Composable
private fun NewPasskeyPassphraseDialog(rpId: String, onSubmit: (String) -> Unit, onCancel: () -> Unit) {
    var passphrase by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("New passkey for $rpId") },
        text = {
            OutlinedTextField(passphrase, { passphrase = it }, label = { Text("Key passphrase") }, visualTransformation = PasswordVisualTransformation())
        },
        confirmButton = { TextButton(onClick = { onSubmit(passphrase) }) { Text("Create") } },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
private fun base64UrlEncode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
private fun base64UrlDecode(s: String): ByteArray = Base64.decode(s, Base64.URL_SAFE or Base64.NO_WRAP)
