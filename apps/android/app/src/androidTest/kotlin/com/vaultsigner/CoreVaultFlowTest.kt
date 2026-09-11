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
 * Real, on-device instrumented coverage for spec item 4.8's Android-
 * specific gap (PROGRESS.md's Phase 4 entry: "no androidTest/instrumented
 * test files exist yet"). Drives the actual `MainActivity` through
 * Compose's semantics tree (`performTextInput`/`performClick` against
 * [TestTags], not raw pixel coordinates) — the exact class of problem
 * this project's own manual `adb shell input` testing lost real time to
 * (a field's on-screen position shifting once the keyboard covers part
 * of the layout, see this phase's PROGRESS.md entry) simply doesn't
 * apply here, since semantics actions don't go through the touchscreen
 * or the IME at all.
 *
 * Exercises the same real stack manual testing already proved works
 * (real Argon2id vault creation, real Ed25519 key generation, the real
 * `:agent` process + socket IPC, the real cross-compiled native
 * library) as a repeatable, CI-able test rather than a one-off manual
 * session. Runs identically against either flavor (`connectedFullDebugAndroidTest`/
 * `connectedLiteDebugAndroidTest`) since none of this touches the FIDO2
 * code path that's the only thing actually flavor-specific.
 */
@RunWith(AndroidJUnit4::class)
class CoreVaultFlowTest : BaseVaultInstrumentedTest() {

    @Test
    fun createVault_thenCreateKey_reachesRealKeyList() {
        // A fresh, unique filename per run — the app-external-files
        // directory a prior run's vault lives in isn't cleared between
        // test invocations on the same device.
        val vaultFileName = "InstrumentedTest_${System.currentTimeMillis()}.vlt"

        composeTestRule.onNodeWithTag(TestTags.WELCOME_CREATE_VAULT_BUTTON).performClick()

        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_FILENAME).performTextClearance()
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_FILENAME).performTextInput(vaultFileName)
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_COMPARTMENT_LABEL).performTextInput("Personal")
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_MASTER_PASSPHRASE).performTextInput("instrumented-test-pass")
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_CONFIRM_PASSPHRASE).performTextInput("instrumented-test-pass")
        composeTestRule.onNodeWithTag(TestTags.CREATE_VAULT_SUBMIT).performClick()

        // Real Argon2id benchmark + container write + IPC round trip to
        // the :agent process — genuinely takes real wall-clock time,
        // unlike a mocked ViewModel would.
        composeTestRule.waitUntil(timeoutMillis = 15_000) {
            composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_TITLE).fetchSemanticsNodes().isNotEmpty()
        }
        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_NO_KEYS_TEXT).assertExists()

        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_NEW_KEY_BUTTON).performClick()
        composeTestRule.waitForIdle()
        // This screen's form is taller than the test device's viewport, so
        // fields below the fold get laid out with degenerate (0,0) bounds
        // until scrolled into view — performClick()/performTextInput()
        // dispatch at a node's (possibly degenerate) center, so without
        // performScrollTo() first, a click on an off-screen node can
        // silently land on nothing instead of throwing.
        composeTestRule.onNodeWithTag(TestTags.CREATE_KEY_LABEL).performScrollTo().performTextInput("InstrumentedTestKey")
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag(TestTags.CREATE_KEY_PASSPHRASE).performScrollTo().performTextInput("key-pass-123")
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag(TestTags.CREATE_KEY_CONFIRM_PASSPHRASE).performScrollTo().performTextInput("key-pass-123")
        composeTestRule.waitForIdle()
        // (Deliberately no content assertion on these two fields:
        // PasswordVisualTransformation masks EditableText in the
        // semantics tree too, not just on screen, so it always reads back
        // as bullets — there is nothing meaningful to assert here short
        // of the field's reported length.)
        composeTestRule.onNodeWithTag(TestTags.CREATE_KEY_SUBMIT).performScrollTo().performClick()

        // Real Ed25519 keypair generation + key-blob sealing + manifest
        // persistence, then navigation back to a key list that must now
        // report a real key — not the empty-vault placeholder.
        composeTestRule.waitUntil(timeoutMillis = 25_000) {
            composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_TITLE).fetchSemanticsNodes().isNotEmpty() &&
                composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_NO_KEYS_TEXT).fetchSemanticsNodes().isEmpty()
        }
    }
}
