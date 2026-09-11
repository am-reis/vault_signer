package com.vaultsigner.ui

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.vaultsigner.ui.theme.VaultSignerTheme

/**
 * The single Activity/window this whole app uses (Compose Navigation
 * swaps composables within it, never opens a second window) — spec §5.0
 * screen-capture blocking is therefore one `FLAG_SECURE` call covering
 * every screen by construction, unlike macOS's per-`NSWindow`-sheet or
 * Windows's per-`Page`-navigation-event approach (both workarounds for
 * their own platforms' multi-window realities — see
 * `apps/android/docs/protocol-integration.md`'s sibling note in
 * PROGRESS.md for the full comparison). [PassphrasePromptActivity] is the
 * one other window this app ever opens, and sets its own `FLAG_SECURE`
 * independently since it's a genuinely separate Activity/task.
 */
class MainActivity : ComponentActivity() {
    private val viewModel: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)

        setContent {
            VaultSignerTheme {
                val navController = rememberNavController()
                val state by viewModel.state.collectAsState()
                VaultSignerNavHost(navController, viewModel, state)
            }
        }
    }
}

@androidx.compose.runtime.Composable
private fun VaultSignerNavHost(navController: NavHostController, viewModel: AppViewModel, state: UiState) {
    NavHost(navController = navController, startDestination = Routes.WELCOME) {
        composable(Routes.WELCOME) { WelcomeScreen(navController, viewModel, state) }
        composable(Routes.CREATE_VAULT) { CreateVaultScreen(navController, viewModel, state) }
        composable(Routes.UNLOCK) { UnlockScreen(navController, viewModel, state) }
        composable(Routes.KEY_LIST) { KeyListScreen(navController, viewModel, state) }
        composable(Routes.CREATE_KEY) { CreateKeyScreen(navController, viewModel, state) }
        composable(Routes.CREATE_COMPARTMENT) { CreateCompartmentScreen(navController, viewModel, state) }
        composable("${Routes.KEY_DETAIL}/{keyId}") { backStackEntry ->
            val keyId = backStackEntry.arguments?.getString("keyId") ?: return@composable
            KeyDetailScreen(navController, viewModel, state, keyId)
        }
        composable(Routes.SETTINGS) { SettingsScreen(navController, viewModel, state) }
        composable(Routes.MANAGE_VAULTS) { ManageVaultsScreen(navController, viewModel, state) }
        composable(Routes.EXPORT_PACKET) { ExportPacketScreen(navController, viewModel, state) }
        composable(Routes.IMPORT_PACKET) { ImportPacketScreen(navController, viewModel, state) }
        composable(Routes.MASTER_KEY_DUALITY) { MasterKeyDualityScreen(navController, viewModel, state) }
    }
}

object Routes {
    const val WELCOME = "welcome"
    const val CREATE_VAULT = "createVault"
    const val UNLOCK = "unlock"
    const val KEY_LIST = "keyList"
    const val CREATE_KEY = "createKey"
    const val CREATE_COMPARTMENT = "createCompartment"
    const val KEY_DETAIL = "keyDetail"
    const val SETTINGS = "settings"
    const val MANAGE_VAULTS = "manageVaults"
    const val EXPORT_PACKET = "exportPacket"
    const val IMPORT_PACKET = "importPacket"
    const val MASTER_KEY_DUALITY = "masterKeyDuality"
}
