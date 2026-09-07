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
/// **Known gap, verified by testing (not yet fixed):** when
/// `VaultSignerAgent` is launched as a bare, unbundled Mach-O executable
/// from a shell (exactly how it was smoke-tested for spec §12 item 2.8),
/// `NSAlert.runModal()` returns immediately with `.alertFirstButtonReturn`
/// and an empty field value instead of actually presenting a modal — no
/// window appears, nothing blocks, and the prompt silently behaves as "an
/// empty passphrase was submitted." This looks like a consequence of
/// running without a proper `.app` bundle/Info.plist (no confirmed
/// WindowServer connection for an unbundled binary launched by a plain
/// shell background job), not a logic bug in this class. Needs
/// re-verification once the agent is either (a) bundled as a tiny
/// `LSUIElement` `.app` and launched via `open`/`SMAppService`/`launchd`
/// (spec §8's actual deployment shape) rather than a bare shell job, or
/// (b) confirmed to need a different presentation API entirely for a
/// background agent. Do not treat this class as "done" until that
/// re-verification happens — the socket/vault/protocol wiring around it
/// (item 2.8) is independently verified and unaffected.
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
