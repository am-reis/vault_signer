package com.vaultsigner

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import com.vaultsigner.ui.MainActivity
import com.vaultsigner.ui.TestTags
import org.junit.Before
import org.junit.Rule

/**
 * Common setup for this suite's tests. Each test class gets its own
 * `MainActivity` instance, but the real `:agent` process — and whatever
 * vault it has open — persists across test *classes* within one
 * instrumentation run: `am instrument` doesn't restart the app process
 * between test classes the way a fresh `adb uninstall`/reinstall would
 * between separate gradle invocations. Without this, a test that runs
 * after another one can find itself mid-way through the previous test's
 * still-open vault instead of at Welcome, and fail immediately looking
 * for a node ([TestTags.WELCOME_CREATE_VAULT_BUTTON]) that was never
 * going to be there — exactly what happened before this existed, running
 * this suite's tests together in one `connectedFullDebugAndroidTest`
 * invocation. [ensureCleanStart] makes every test order-independent by
 * closing any leftover open vault through the real UI first.
 */
abstract class BaseVaultInstrumentedTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    @Before
    fun ensureCleanStart() {
        // AppViewModel's initial internal.status check is async — right at
        // Activity launch, before it resolves, the screen can transiently
        // still show Welcome's default (no-vault-open) state even when a
        // previous test class left a real vault open. Wait for the
        // status check to actually land (either destination) before
        // deciding what to do, rather than trusting a single immediate
        // check that can race it.
        // A generous timeout: this fires at cold Activity start, right as
        // three tests' worth of cumulative native-library/process churn
        // can genuinely slow down the very first internal.status round
        // trip under load, not just when it's actually racing a prior
        // test's leftover vault.
        composeTestRule.waitUntil(timeoutMillis = 20_000) {
            composeTestRule.onAllNodesWithTag(TestTags.WELCOME_CREATE_VAULT_BUTTON).fetchSemanticsNodes().isNotEmpty() ||
                composeTestRule.onAllNodesWithTag(TestTags.KEY_LIST_SETTINGS_BUTTON).fetchSemanticsNodes().isNotEmpty()
        }
        if (composeTestRule.onAllNodesWithTag(TestTags.WELCOME_CREATE_VAULT_BUTTON).fetchSemanticsNodes().isNotEmpty()) return
        composeTestRule.onNodeWithTag(TestTags.KEY_LIST_SETTINGS_BUTTON).performClick()
        composeTestRule.onNodeWithTag(TestTags.SETTINGS_CLOSE_VAULT_BUTTON).performScrollTo().performClick()
        composeTestRule.waitUntil(timeoutMillis = 15_000) {
            composeTestRule.onAllNodesWithTag(TestTags.WELCOME_CREATE_VAULT_BUTTON).fetchSemanticsNodes().isNotEmpty()
        }
    }
}
