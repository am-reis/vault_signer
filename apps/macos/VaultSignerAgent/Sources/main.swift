import AppKit
import Foundation

/// VaultSignerAgent (spec §8 background service): a `LSUIElement`-style
/// process (no Dock icon, `NSApplicationActivationPolicy.accessory`) that
/// owns the vault and the custom-protocol listener. Runs a real
/// `NSApplication` event loop (not a bare command-line tool) because
/// `AlertPassphrasePrompter` needs one to show its passphrase dialog.
///
/// Usage: `VaultSignerAgent --vault /path/to/file.vlt`
///
/// `SMAppService`-based login-item registration (spec §8) is done in
/// `VaultSigner.app`'s `LoginItemManager`, not here — this process has no
/// idea how it was launched. Auto-unlock *is* wired up here: if
/// `VaultConfig` names a compartment, this looks up its passphrase in
/// `AutoUnlockStore` (Keychain) and unlocks it before the socket even
/// starts accepting connections, so a `vaultsigner.list_public_keys`
/// call works immediately after boot with no human present.
///
/// This process must stay running and keep serving `internal.*` even
/// when no vault is configured yet (a fresh install, before the user has
/// ever created one) — `VaultSigner.app` no longer opens a `Vault`
/// itself (spec §8), so `internal.create_vault` is now the *only* way a
/// vault ever comes into being, and that call has to reach a live agent.

// `--vault` is for direct/manual testing (see uniffi-verify/). The real
// launchd-launched agent has no CLI arguments to receive — its
// LaunchAgents plist's `ProgramArguments` are static, baked in at embed
// time — so it reads `VaultConfig` instead, which the agent itself now
// writes whenever `internal.create_vault`/`internal.open_vault` succeeds.
let arguments = CommandLine.arguments
let vaultPath: String?
if let vaultFlagIndex = arguments.firstIndex(of: "--vault"), arguments.count > vaultFlagIndex + 1 {
    vaultPath = arguments[vaultFlagIndex + 1]
} else {
    vaultPath = VaultConfig.loadVaultPath()
}

var vault: Vault?
if let vaultPath {
    do {
        let opened = try Vault.open(path: vaultPath)
        vault = opened
        if let compartmentId = VaultConfig.loadAutoUnlockCompartmentId(), let passphrase = AutoUnlockStore.load(forCompartment: compartmentId) {
            do {
                try opened.unlockCompartment(compartmentId: compartmentId, passphrase: passphrase)
                print("VaultSignerAgent: auto-unlocked compartment \(compartmentId)")
            } catch {
                FileHandle.standardError.write(Data("VaultSignerAgent: auto-unlock failed for \(compartmentId): \(error)\n".utf8))
            }
        }
    } catch {
        // Stay alive regardless — `internal.open_vault`/`internal.create_vault`
        // can still recover from a missing/corrupt configured path.
        FileHandle.standardError.write(Data("VaultSignerAgent: failed to open configured vault at \(vaultPath): \(error)\n".utf8))
    }
}

let socketPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/VaultSigner/agent.sock")
let server = AgentServer(vault: vault, socketPath: socketPath)
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("VaultSignerAgent: failed to start socket server: \(error)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
