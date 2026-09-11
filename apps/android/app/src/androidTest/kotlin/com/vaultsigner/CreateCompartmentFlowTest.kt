package com.vaultsigner

import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vaultsigner.ui.TestTags
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Real, on-device click-through coverage for `CreateCompartmentScreen`
 * (spec §5.3 option 2's standalone `add_compartment` UI) — one of the
 * screens item 4.1/4.8 flagged as built and facade-proven but never
 * driven through this app's own UI. Reached via `KeyListScreen`'s
 * overflow menu, same as export/import.
 */
@RunWith(AndroidJUnit4::class)
class CreateCompartmentFlowTest : BaseVaultInstrumentedTest() {

    @Test
    fun createCompartment_fromKeyListMenu_succeeds() {
        val vaultFileName = "CompartmentTest_${System.currentTimeMillis()}.vlt"

        composeTestRule.onNodeWithTag(TestTags.WELCOME_CREATE_VAULT_BUTTON).performClick()
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_FILENAME).performTextClearance()
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_FILENAME).performTextInput(vaultFileName)
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_COMPARTMENT_LABEL).performTextInput("Personal")
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_MASTER_PASSPHRASE).performTextInput("instrumented-test-pass")
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_CONFIRM_PASSPHRASE).performTextInput("instrumented-test-pass")
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_SUBMIT).performClick()

        composeTestRule.waitUntil(timeoutMillis = 15_000) {
            composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_TITLE).fetchSemanticsNodes().isNotEmpty()
        }

        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_MENU_BUTTON).performClick()
        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_NEW_COMPARTMENT_MENU_ITEM).performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag(TestTags.CREATE_COMPARTMENT_LABEL).performScrollTo().performTextInput("Backup")
        composeTestRule.onNodeWithTag(TestTags.CREATE_COMPARTMENT_PASSPHRASE).performScrollTo().performTextInput("backup-compartment-pass")
        composeTestRule.onNodeWithTag(TestTags.CREATE_COMPARTMENT_CONFIRM_PASSPHRASE).performScrollTo().performTextInput("backup-compartment-pass")
        composeTestRule.onNodeWithTag(TestTags.CREATE_COMPARTMENT_SUBMIT).performScrollTo().performClick()

        // A real add_compartment round trip to the :agent process. Success
        // is "we're navigated back to the key list" — addCompartment()
        // only calls its onDone (which pops back) after the RPC succeeds;
        // a failure leaves state.error set and the screen in place.
        composeTestRule.waitUntil(timeoutMillis = 15_000) {
            composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_TITLE).fetchSemanticsNodes().isNotEmpty()
        }
    }
}
