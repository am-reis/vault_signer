package com.vaultsigner.credentialprovider

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.vaultsigner.R
import com.vaultsigner.service.AndroidPassphrasePrompter

/**
 * The one on-demand passphrase surface a `vaultsigner.sign` request or a
 * CTAP2 `authenticatorGetAssertion` (spec §6.6/§7) shows when the target
 * key isn't already warm in the retention cache — mirrors macOS's
 * `NSAlert`-based `AlertPassphrasePrompter`/Windows's WinForms dialog.
 * Launched by [AndroidPassphrasePrompter] from the `:agent` process; its
 * answer is handed back via [AndroidPassphrasePrompter.deliverAnswer]
 * rather than a normal activity result, since the Rust caller is blocked
 * synchronously waiting on it (see that class's doc comment).
 *
 * Spec §5.0: screen-capture blocking applies to every passphrase-entry
 * surface, this one included — `FLAG_SECURE` set before any content is
 * shown.
 */
class PassphrasePromptActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)

        val callerIdentity = intent.getStringExtra(EXTRA_CALLER_IDENTITY) ?: getString(R.string.android_prompt_unknown_caller)
        val keyId = intent.getStringExtra(EXTRA_KEY_ID) ?: ""

        setContent {
            MaterialTheme {
                PassphrasePromptDialog(
                    callerIdentity = callerIdentity,
                    keyId = keyId,
                    onAllow = { passphrase ->
                        AndroidPassphrasePrompter.deliverAnswer(passphrase)
                        finish()
                    },
                    onDeny = {
                        AndroidPassphrasePrompter.deliverAnswer(null)
                        finish()
                    },
                )
            }
        }
    }

    override fun onDestroy() {
        // A user backing out of Recents/the task without tapping either
        // button must still unblock the waiting Rust caller, per spec
        // §7's `user_declined` outcome — never leave it hanging.
        AndroidPassphrasePrompter.deliverAnswer(null)
        super.onDestroy()
    }

    companion object {
        const val EXTRA_CALLER_IDENTITY = "caller_identity"
        const val EXTRA_KEY_ID = "key_id"
    }
}

@Composable
private fun PassphrasePromptDialog(
    callerIdentity: String,
    keyId: String,
    onAllow: (String) -> Unit,
    onDeny: () -> Unit,
) {
    var passphrase by remember { mutableStateOf("") }
    var answered by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = { if (!answered) { answered = true; onDeny() } },
        title = { Text(stringResourceCompat(R.string.android_prompt_title_format, callerIdentity)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResourceCompat(R.string.android_prompt_body_format, keyId.take(8)))
                OutlinedTextField(
                    value = passphrase,
                    onValueChange = { passphrase = it },
                    label = { Text(stringResourceCompat(R.string.android_prompt_passphrase_label)) },
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { if (!answered) { answered = true; onAllow(passphrase) } }) {
                Text(stringResourceCompat(R.string.android_prompt_allow))
            }
        },
        dismissButton = {
            TextButton(onClick = { if (!answered) { answered = true; onDeny() } }) {
                Text(stringResourceCompat(R.string.android_prompt_deny))
            }
        },
    )
}

@Composable
private fun stringResourceCompat(resId: Int, vararg formatArgs: Any): String =
    androidx.compose.ui.res.stringResource(resId, *formatArgs)
