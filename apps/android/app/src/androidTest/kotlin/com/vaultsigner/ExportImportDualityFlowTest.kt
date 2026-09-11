package com.vaultsigner

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.espresso.Espresso.pressBack
import androidx.test.espresso.intent.Intents
import androidx.test.espresso.intent.matcher.IntentMatchers.hasAction
import androidx.test.espresso.intent.rule.IntentsRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vaultsigner.ui.TestTags
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Real, on-device coverage for the spec §5.2/§5.3 export → import →
 * master-key-duality round trip, through this app's actual UI — the
 * automated form of the exact manual self-export/self-import test that
 * (per this phase's PROGRESS.md 4.1 entry) caught a real merge-
 * persistence bug in shared `vaultcore`. Two real, separate vault files
 * are used (not two compartments in one vault), matching how export/
 * import packets are actually meant to be used — moving a key between
 * vaults, not within one.
 *
 * `ExportPacketScreen`/`ImportPacketScreen` both hand off to a real
 * system document picker (`ActivityResultContracts.CreateDocument`/
 * `OpenDocument`); [IntentsRule] lets this test stub that picker's
 * result with a real local file, so both screens' own logic — not a
 * fake shortcut around them — still runs for real.
 */
@RunWith(AndroidJUnit4::class)
class ExportImportDualityFlowTest : BaseVaultInstrumentedTest() {

    @get:Rule
    val intentsRule = IntentsRule()

    @Test
    fun exportFromVaultA_importIntoVaultB_viaDualityOption1_keySurvives() {
        val ts = System.currentTimeMillis()
        val packetFile = File(composeTestRule.activity.getExternalFilesDir(null), "roundtrip_$ts.vltpack")

        createVault("VaultA_$ts.vlt", "vaultA-master-pass")
        createKey("ExportableKey", "key-pass-123")

        exportEverythingAsIs(packetFile)

        // Back to VaultA's key list, then close it — export/import move a
        // key BETWEEN vaults, so this proves a real cross-vault transfer,
        // not a same-vault no-op.
        pressBack()
        composeTestRule.waitUntil(timeoutMillis = 10_000) {
            composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_TITLE).fetchSemanticsNodes().isNotEmpty()
        }
        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_SETTINGS_BUTTON).performClick()
        composeTestRule.onNodeWithTag(TestTags.SETTINGS_CLOSE_VAULT_BUTTON).performScrollTo().performClick()
        composeTestRule.waitUntil(timeoutMillis = 10_000) {
            composeTestRule.onAllNodesWithTag(TestTags.WELCOME_CREATE_VAULT_BUTTON).fetchSemanticsNodes().isNotEmpty()
        }

        createVault("VaultB_$ts.vlt", "vaultB-master-pass")
        // Fresh vault, no keys yet.
        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_NO_KEYS_TEXT).assertExists()

        importAndMergeViaOption1(packetFile)

        // Duality's "Use this option" only pops back once (to
        // ImportPacketScreen) — one more back returns to the key list,
        // which finishMerge() has already refreshed with the target
        // compartment's (VaultB's only, and currently-selected)
        // now-imported key.
        pressBack()
        composeTestRule.waitUntil(timeoutMillis = 15_000) {
            composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_NO_KEYS_TEXT).fetchSemanticsNodes().isEmpty()
        }
    }

    private fun createVault(fileName: String, passphrase: String) {
        composeTestRule.onNodeWithTag(TestTags.WELCOME_CREATE_VAULT_BUTTON).performClick()
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_FILENAME).performTextClearance()
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_FILENAME).performTextInput(fileName)
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_COMPARTMENT_LABEL).performTextInput("Personal")
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_MASTER_PASSPHRASE).performTextInput(passphrase)
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_CONFIRM_PASSPHRASE).performTextInput(passphrase)
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_SUBMIT).performClick()
        composeTestRule.waitUntil(timeoutMillis = 15_000) {
            composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_TITLE).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun createKey(label: String, passphrase: String) {
        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_NEW_KEY_BUTTON).performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag(TestTags.CREATE_KEY_LABEL).performScrollTo().performTextInput(label)
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag(TestTags.CREATE_KEY_PASSPHRASE).performScrollTo().performTextInput(passphrase)
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag(TestTags.CREATE_KEY_CONFIRM_PASSPHRASE).performScrollTo().performTextInput(passphrase)
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag(TestTags.CREATE_KEY_SUBMIT).performScrollTo().performClick()
        composeTestRule.waitUntil(timeoutMillis = 25_000) {
            composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_TITLE).fetchSemanticsNodes().isNotEmpty() &&
                composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_NO_KEYS_TEXT).fetchSemanticsNodes().isEmpty()
        }
    }

    private fun exportEverythingAsIs(destination: File) {
        Intents.intending(hasAction(Intent.ACTION_CREATE_DOCUMENT)).respondWith(
            Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(Uri.fromFile(destination))),
        )

        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_MENU_BUTTON).performClick()
        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_EXPORT_MENU_ITEM).performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onAllNodesWithTag(TestTags.EXPORT_KEY_CHECKBOX)[0].performScrollTo().performClick()
        composeTestRule.onNodeWithTag(TestTags.EXPORT_INCLUDE_MASTER_CHECKBOX).performScrollTo().performClick()
        composeTestRule.onNodeWithTag(TestTags.EXPORT_OPTION_ASIS).performScrollTo().performClick()
        composeTestRule.onNodeWithTag(TestTags.EXPORT_SUBMIT).performScrollTo().performClick()

        // Real AEAD packet serialization + the stubbed "save" round trip —
        // wait for the actual bytes to land on disk rather than assuming
        // a fixed delay is enough.
        composeTestRule.waitUntil(timeoutMillis = 15_000) { destination.exists() && destination.length() > 0 }
    }

    private fun importAndMergeViaOption1(source: File) {
        Intents.intending(hasAction(Intent.ACTION_OPEN_DOCUMENT)).respondWith(
            Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(Uri.fromFile(source))),
        )

        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_MENU_BUTTON).performClick()
        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_IMPORT_MENU_ITEM).performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag(TestTags.IMPORT_CHOOSE_FILE_BUTTON).performClick()

        // The packet carries an embedded master key (include-master-key
        // was on for the export), so import_packet routes to the duality
        // screen rather than merging automatically.
        composeTestRule.waitUntil(timeoutMillis = 15_000) {
            composeTestRule.onAllNodesWithTag(TestTags.DUALITY_OPTION1_USE_BUTTON).fetchSemanticsNodes().isNotEmpty()
        }
        // Option 1 defaults its target to the first unlocked compartment —
        // VaultB has exactly one, already selected, so no picker
        // interaction is needed to pick the right target.
        composeTestRule.onNodeWithTag(TestTags.DUALITY_OPTION1_USE_BUTTON).performScrollTo().performClick()
    }
}
