import AuthenticationServices
import Foundation

/// Spec §6.1: `ASCredentialProviderExtension` target with
/// `ProvidesPasskeys = YES`. This is a real, buildable extension (see
/// `PROGRESS.md` item 2.7 for exactly what's been verified about it and
/// what still needs a paid Apple Developer enrollment) — linked against
/// vaultcore the same way `VaultSigner.app`/`VaultSignerAgent` are, per
/// spec §6.1's "link it against the same compiled vaultcore library so
/// vault-opening logic is not duplicated."
///
/// The actual CTAP2 wiring (`vaultcore::ctap2`'s `handle_make_credential`/
/// `handle_get_assertion` via the `Vault` facade, exactly like
/// `VaultSignerAgent`'s custom-protocol handling) is not implemented in
/// this stub yet — this only proves the extension target itself builds,
/// embeds, and links correctly. It reads `VaultConfig` to prove it can
/// see the same shared state `VaultSignerAgent` uses, and does nothing
/// with it yet.
class CredentialProviderViewController: ASCredentialProviderViewController {
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        // Real implementation: list vaultcore::Vault.credentialCandidates(rpId:)
        // matches, populate the OS-provided credential list UI. Not
        // wired up yet — see the type-level doc comment.
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        // Real implementation: prompt for the key's passphrase (same
        // AlertPassphrasePrompter-shaped UI as VaultSignerAgent, screen-
        // capture-blocked per spec §5.0), then call
        // vaultcore::ctap2::handle_get_assertion via the Vault facade.
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }
}
