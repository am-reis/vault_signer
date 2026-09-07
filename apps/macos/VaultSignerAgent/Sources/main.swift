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

// `--vault` is for direct/manual testing (see uniffi-verify/). The real
// launchd-launched agent has no CLI arguments to receive — its
// LaunchAgents plist's `ProgramArguments` are static, baked in at embed
// time — so it reads `VaultConfig` instead, which `VaultSigner.app`
// writes whenever the user creates/opens a vault.
let arguments = CommandLine.arguments
let vaultPath: String
if let vaultFlagIndex = arguments.firstIndex(of: "--vault"), arguments.count > vaultFlagIndex + 1 {
    vaultPath = arguments[vaultFlagIndex + 1]
} else if let configured = VaultConfig.loadVaultPath() {
    vaultPath = configured
} else {
    // No vault configured yet (e.g. first login before the user has ever
    // created one). Exit quietly rather than error-looping under
    // launchd's KeepAlive — it will retry on its own schedule, and
    // succeed once VaultSigner.app has written a config.
    exit(0)
}

let vault: Vault
do {
    vault = try Vault.open(path: vaultPath)
} catch {
    FileHandle.standardError.write(Data("VaultSignerAgent: failed to open vault at \(vaultPath): \(error)\n".utf8))
    exit(1)
}

if let compartmentId = VaultConfig.loadAutoUnlockCompartmentId(), let passphrase = AutoUnlockStore.load(forCompartment: compartmentId) {
    do {
        try vault.unlockCompartment(compartmentId: compartmentId, passphrase: passphrase)
        print("VaultSignerAgent: auto-unlocked compartment \(compartmentId)")
    } catch {
        FileHandle.standardError.write(Data("VaultSignerAgent: auto-unlock failed for \(compartmentId): \(error)\n".utf8))
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
