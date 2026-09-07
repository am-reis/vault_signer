import AppKit
import AuthenticationServices
import Foundation

/// Spec §6.1: `ASCredentialProviderExtension` target with
/// `ProvidesPasskeys = YES`, linked against the same compiled vaultcore
/// library as `VaultSigner.app`/`VaultSignerAgent` (spec §6.1: "so
/// vault-opening logic is not duplicated") via `Vault`'s "native" FIDO2
/// methods (`handleFido2MakeCredentialNative`/`handleFido2GetAssertionNative`
/// — see `vaultcore::ctap2::build_make_credential_request_cbor`'s doc
/// comment for why those exist: this extension receives already-parsed
/// fields from `ASPasskeyCredentialRequest`, never raw CTAP2 bytes, and
/// encoding those into a CTAP2 request has to happen in vaultcore, not
/// here, per spec §2).
///
/// **Verification status (see PROGRESS.md item 2.7 for the full story):**
/// this file compiles against the real AuthenticationServices SDK, but
/// has never run as a live credential provider — the extension can't be
/// code-signed with its required entitlement on a free/Personal Team
/// (confirmed by Apple's own provisioning server, twice), so it has
/// never been enabled in System Settings or exercised by a real
/// WebAuthn ceremony in Safari/Chrome. Treat every claim below about
/// *runtime* behavior as "believed correct from reading the SDK,"
/// not "observed."
///
/// **Process model note:** this extension runs as its own OS process,
/// entirely separate from `VaultSignerAgent` — it does not share that
/// process's in-memory unlocked compartments or retention cache. Every
/// invocation opens the vault fresh (`VaultConfig.loadVaultPath()`) and
/// unlocks the relevant compartment itself, via `AutoUnlockStore` if
/// auto-unlock is configured for it (spec §8) or by prompting for the
/// master passphrase otherwise (not yet implemented — see
/// `unlockAnyAvailableCompartment` below), then prompts for the specific
/// key's own passphrase (spec §3's two-secret model) using the same
/// kind of native `NSAlert` prompt as `VaultSignerAgent`'s
/// `AlertPassphrasePrompter`, screen-capture-blocked per spec §5.0.
class CredentialProviderViewController: ASCredentialProviderViewController {
    // MARK: - Non-passkey discovery (not used; VaultSigner only offers passkeys)

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        // VaultSigner always requires the per-key passphrase (spec §3) —
        // "without user interaction" is never satisfiable.
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    // MARK: - Passkey registration

    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
        guard let passkeyRequest = registrationRequest as? ASPasskeyCredentialRequest,
              let identity = passkeyRequest.credentialIdentity as? ASPasskeyCredentialIdentity
        else {
            extensionContext.cancelRequest(withError: makeError(.failed))
            return
        }

        guard let vault = openVaultAndUnlockAnyCompartment() else {
            extensionContext.cancelRequest(withError: makeError(.failed))
            return
        }
        guard let compartmentId = vault.listCompartments().first(where: { $0.unlocked })?.compartmentId else {
            extensionContext.cancelRequest(withError: makeError(.failed))
            return
        }
        guard let keyPassphrase = ExtensionPassphrasePrompter().prompt(callerIdentity: identity.relyingPartyIdentifier, keyId: "new passkey") else {
            extensionContext.cancelRequest(withError: makeError(.userCanceled))
            return
        }

        let algorithms = passkeyRequest.supportedAlgorithms.map { Int32($0.rawValue) }
        // `excludedCredentials` needs macOS 15 (this target's deployment
        // floor is 14, to keep the rest of the passkey surface available)
        // — degrade to "nothing excluded" below that, rather than
        // bumping the whole target's floor for one optional field.
        let excludeCredentialIds: [Data]
        if #available(macOS 15.0, *) {
            excludeCredentialIds = passkeyRequest.excludedCredentials?.map(\.credentialID) ?? []
        } else {
            excludeCredentialIds = []
        }
        do {
            let result = try vault.handleFido2MakeCredentialNative(
                compartmentId: compartmentId,
                rpId: identity.relyingPartyIdentifier,
                userId: identity.userHandle,
                clientDataHash: passkeyRequest.clientDataHash,
                algorithms: algorithms,
                excludeCredentialIds: excludeCredentialIds,
                discoverable: true,
                userVerificationRequested: passkeyRequest.userVerificationPreference != .discouraged,
                userPresent: true,
                userVerified: passkeyRequest.userVerificationPreference != .discouraged,
                keyPassphrase: keyPassphrase,
                label: "\(identity.relyingPartyIdentifier) passkey",
                description: "",
                resource: identity.relyingPartyIdentifier
            )
            let credential = ASPasskeyRegistrationCredential(
                relyingParty: result.rpId,
                clientDataHash: passkeyRequest.clientDataHash,
                credentialID: result.credentialId,
                attestationObject: result.attestationObject
            )
            extensionContext.completeRegistrationRequest(using: credential)
        } catch {
            extensionContext.cancelRequest(withError: makeError(.failed))
        }
    }

    // MARK: - Passkey assertion

    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        guard let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest,
              let identity = passkeyRequest.credentialIdentity as? ASPasskeyCredentialIdentity
        else {
            extensionContext.cancelRequest(withError: makeError(.failed))
            return
        }

        guard let vault = openVaultAndUnlockAnyCompartment() else {
            extensionContext.cancelRequest(withError: makeError(.failed))
            return
        }
        let callerIdentity = identity.relyingPartyIdentifier
        let prompter = ExtensionPassphrasePrompter()

        do {
            let result = try vault.handleFido2GetAssertionNative(
                rpId: identity.relyingPartyIdentifier,
                clientDataHash: passkeyRequest.clientDataHash,
                allowCredentialIds: [identity.credentialID],
                userVerificationRequested: passkeyRequest.userVerificationPreference != .discouraged,
                userPresent: true,
                userVerified: passkeyRequest.userVerificationPreference != .discouraged,
                prompter: prompter
            )
            let credential = ASPasskeyAssertionCredential(
                userHandle: result.userHandle,
                relyingParty: result.rpId,
                signature: result.signature,
                clientDataHash: passkeyRequest.clientDataHash,
                authenticatorData: result.authenticatorData,
                credentialID: result.credentialId
            )
            extensionContext.completeAssertionRequest(using: credential)
        } catch {
            extensionContext.cancelRequest(withError: makeError(.failed))
        }
        _ = callerIdentity
    }

    // MARK: - Shared helpers

    /// Opens the vault named in `VaultConfig` and unlocks whichever
    /// compartment auto-unlock (spec §8) is configured for, if any.
    /// **Known gap:** if no compartment is auto-unlock-enabled, this
    /// currently has no way to prompt for the *master* passphrase (only
    /// per-key passphrases are prompted for today, via
    /// `ExtensionPassphrasePrompter`) — a real release needs a second
    /// prompt step here for that case. Not implemented, since it would
    /// be exercising a code path that can't be tested live regardless
    /// (see this file's top-level doc comment).
    private func openVaultAndUnlockAnyCompartment() -> Vault? {
        guard let vaultPath = VaultConfig.loadVaultPath(), let vault = try? Vault.open(path: vaultPath) else { return nil }
        for compartment in vault.listCompartments() {
            guard let compartmentId = Optional(compartment.compartmentId), let passphrase = AutoUnlockStore.load(forCompartment: compartmentId) else { continue }
            try? vault.unlockCompartment(compartmentId: compartmentId, passphrase: passphrase)
        }
        return vault
    }

    private func makeError(_ code: ASExtensionError.Code) -> NSError {
        NSError(domain: ASExtensionErrorDomain, code: code.rawValue)
    }
}

/// The extension's own `PassphrasePrompter` (spec §7/§6.6: "shows the
/// same password-prompt UI as FIDO2"). Mirrors
/// `VaultSignerAgent.AlertPassphrasePrompter` — kept as a separate,
/// duplicated small type rather than shared code, since the two targets
/// don't currently share a Swift module (see the macOS README's
/// known-gaps list for extracting a shared framework as real follow-up).
final class ExtensionPassphrasePrompter: PassphrasePrompter {
    func prompt(callerIdentity: String, keyId: String) -> String? {
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = "\(callerIdentity) wants to use a VaultSigner passkey"
            alert.informativeText = "Enter the passphrase for this key to allow it."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = field
            alert.window.sharingType = .none // spec §5.0

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return nil }
            return field.stringValue
        }
    }
}
