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
/// Not yet wired up here (tracked in the macOS README as known gaps):
/// `SMAppService`-based login-item registration and the two autostart/
/// auto-unlock toggles (spec §8) — this only covers the service's core
/// job (owning the vault + serving the socket) so it can be verified
/// against a real client (spec §12 item 2.8) before adding OS-level
/// lifecycle wiring on top.

let arguments = CommandLine.arguments
guard let vaultFlagIndex = arguments.firstIndex(of: "--vault"), arguments.count > vaultFlagIndex + 1 else {
    FileHandle.standardError.write(Data("usage: VaultSignerAgent --vault /path/to/file.vlt\n".utf8))
    exit(64)
}
let vaultPath = arguments[vaultFlagIndex + 1]

let vault: Vault
do {
    vault = try Vault.open(path: vaultPath)
} catch {
    FileHandle.standardError.write(Data("VaultSignerAgent: failed to open vault at \(vaultPath): \(error)\n".utf8))
    exit(1)
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
