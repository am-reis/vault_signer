import AppKit

/// The agent's real implementation of vaultcore's `PassphrasePrompter`
/// foreign trait (spec §7: "every `sign` call triggers the same
/// password-prompt UI as FIDO2 ... displaying the calling process's
/// identity before the passphrase field"). Runs as a background
/// (`LSUIElement`) process, so this is the *only* UI it ever shows.
/// Invoked from a socket-handling background thread; blocks that thread
/// (via `DispatchQueue.main.sync`) while the alert is on screen, which is
/// correct here — the calling app's `vaultsigner.sign` request is
/// supposed to block until the user answers the prompt.
///
/// Verified interactively end-to-end (not just built): running as a
/// bundled `.app` launched via `open`, a real `vaultsigner.sign` request
/// for a key with no cached material shows this alert, blocks until
/// answered, and — given the correct key passphrase — returns a
/// signature that independently verifies against the key's real public
/// key. (An earlier pass mistakenly concluded this path was broken,
/// having misread a fast automated-test response as "the alert never
/// appeared"; it was actually a human typing an answer — the vault's
/// master passphrase, not the key's own — into a real, working dialog.
/// The automated test in `uniffi-verify/agent_test_client.py` avoids
/// this alert entirely, by design, via `internal.unlock_key`.)
final class AlertPassphrasePrompter: PassphrasePrompter {
    func prompt(callerIdentity: String, keyId: String) -> String? {
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = "\(callerIdentity) wants to sign with a VaultSigner key"
            alert.informativeText = "Enter the passphrase for this key to allow it."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = field

            // Screen-capture blocking (spec §5.0) applies to this
            // passphrase-entry prompt like every other one.
            NSApp.activate(ignoringOtherApps: true)
            alert.window.sharingType = .none

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return nil }
            return field.stringValue
        }
    }
}
