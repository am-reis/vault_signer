import Foundation

/// Central app state (spec §12 item 2.1): mirrors just enough of
/// `VaultSignerAgent`'s vault state into `@Published` properties for
/// SwiftUI to observe. This app holds **no `Vault` of its own** — spec
/// §8: the service "is the sole writer of the container file," and the
/// UI "requests container mutations from the service rather than
/// writing the file itself." Every operation here is a call to
/// `ManagementClient`, which speaks the agent's `internal.*` namespace
/// over the same local socket the public `vaultsigner.*` protocol uses.
/// Nothing here re-implements vault logic; it is exclusively a thin,
/// observable wrapper around that RPC surface.
@MainActor
final class AppState: ObservableObject {
    @Published var vaultPath: String?
    @Published var compartments: [CompartmentInfo] = []
    @Published var unlockedCompartmentId: String?
    @Published var keys: [KeyInfo] = []
    @Published var isBusy = false
    @Published var errorMessage: String?
    /// Spec §5.6: remembered vault locations, most-recently-accessed
    /// first. Populated at launch and refreshed after every add/forget.
    @Published var knownVaults: [KnownVaultEntry] = []

    init() {
        refreshKnownVaults()
    }

    func clearError() {
        errorMessage = nil
    }

    func refreshKnownVaults() {
        knownVaults = KnownVaultsStore.load()
    }

    /// Spec §5.6: add a vault to the known-vaults list without opening
    /// it (the management screen's "add a known vault by browsing to a
    /// file without opening it immediately").
    func addKnownVaultWithoutOpening(path: String) {
        KnownVaultsStore.addWithoutOpening(path: path)
        refreshKnownVaults()
    }

    /// Spec §5.6: "Forgetting an entry only removes it from this list —
    /// it must never delete, move, or modify the underlying vault file."
    func forgetKnownVault(path: String) {
        KnownVaultsStore.forget(path: path)
        refreshKnownVaults()
    }

    /// Spec §5.6: "a way to close the currently-open vault and return to
    /// the entry screen without quitting the app." Never touches the
    /// known-vaults list — closing isn't forgetting. Does not lock the
    /// agent's vault (a separate action — see `lockAll()`); this only
    /// resets what *this* window is looking at.
    func closeVault() {
        vaultPath = nil
        compartments = []
        unlockedCompartmentId = nil
        keys = []
    }

    private func run<T>(_ work: @escaping () throws -> T) async -> T? {
        isBusy = true
        defer { isBusy = false }
        do {
            return try await Task.detached(priority: .userInitiated) { try work() }.value
        } catch let error as FacadeError {
            switch error {
            case .Failed(let message):
                errorMessage = message
            }
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Vault lifecycle

    func createVault(path: String, label: String, masterPassphrase: String, profile: FacadeDeviceProfile) async {
        ManagementClient.ensureAgentRunning()
        guard let created = await run({ try ManagementClient.createVault(path: path, compartmentLabel: label, masterPassphrase: masterPassphrase, profile: profile) })
        else { return }
        vaultPath = path
        KnownVaultsStore.recordOpened(path: path)
        refreshKnownVaults()
        compartments = created
        // `Vault::create` unlocks its first compartment as part of
        // creating it (server-side), so this just mirrors that — no
        // separate unlock call needed, unlike the old two-Vault-copies
        // design this replaces.
        if let first = compartments.first {
            unlockedCompartmentId = first.compartmentId
            refreshKeys()
        }
    }

    func openVault(path: String) async {
        ManagementClient.ensureAgentRunning()
        guard await run({ try ManagementClient.openVault(path: path) }) != nil else { return }
        vaultPath = path
        KnownVaultsStore.recordOpened(path: path)
        refreshKnownVaults()
        unlockedCompartmentId = nil
        keys = []
        await refreshCompartments()
    }

    func refreshCompartments() async {
        if let result = await run({ try ManagementClient.listCompartments() }) {
            compartments = result
        }
    }

    func unlock(compartmentId: String, passphrase: String) async {
        guard await run({ try ManagementClient.unlockCompartment(compartmentId: compartmentId, passphrase: passphrase) }) != nil else { return }
        unlockedCompartmentId = compartmentId
        await refreshCompartments()
        refreshKeys()
    }

    func lockAll() {
        ManagementClient.lockAll()
        unlockedCompartmentId = nil
        keys = []
        Task { await refreshCompartments() }
    }

    // MARK: - Keys

    func refreshKeys() {
        guard let compartmentId = unlockedCompartmentId else { return }
        Task {
            keys = await run({ try ManagementClient.listKeys(compartmentId: compartmentId) }) ?? keys
        }
    }

    @discardableResult
    func createKey(
        keyType: FacadeKeyType, purpose: FacadePurpose, label: String, description: String,
        resource: String, tags: [String], keyPassphrase: String
    ) async -> KeyInfo? {
        guard let compartmentId = unlockedCompartmentId else { return nil }
        let created = await run({
            try ManagementClient.createKey(
                compartmentId: compartmentId, keyType: keyType, purpose: purpose, label: label,
                description: description, resource: resource, tags: tags, keyPassphrase: keyPassphrase
            )
        })
        if created != nil { refreshKeys() }
        return created
    }

    func discardKey(keyId: String, confirmText: String) async -> Bool {
        guard let compartmentId = unlockedCompartmentId else { return false }
        let ok = await run({ try ManagementClient.discardKey(compartmentId: compartmentId, keyId: keyId, confirmText: confirmText) }) != nil
        if ok { refreshKeys() }
        return ok
    }

    func changeKeyPassphrase(keyId: String, oldPassphrase: String, newPassphrase: String) async -> Bool {
        guard let compartmentId = unlockedCompartmentId else { return false }
        return await run({
            try ManagementClient.changeKeyPassphrase(compartmentId: compartmentId, keyId: keyId, oldPassphrase: oldPassphrase, newPassphrase: newPassphrase)
        }) != nil
    }

    func revealRawKeyHex(keyId: String, passphrase: String) async -> String? {
        guard let compartmentId = unlockedCompartmentId else { return nil }
        return await run({ try ManagementClient.revealRawKeyHex(compartmentId: compartmentId, keyId: keyId, passphrase: passphrase) })
    }

    // MARK: - Export / import / merge

    func exportSingleKey(keyId: String) async -> Data? {
        guard let compartmentId = unlockedCompartmentId else { return nil }
        return await run({ try ManagementClient.exportSingleKey(compartmentId: compartmentId, keyId: keyId) })
    }

    func exportPacket(keyIds: [String], includeMasterKey: Bool, encryption: FacadeExportEncryption) async -> Data? {
        guard let compartmentId = unlockedCompartmentId else { return nil }
        return await run({ try ManagementClient.exportPacket(compartmentId: compartmentId, keyIds: keyIds, includeMasterKey: includeMasterKey, encryption: encryption) })
    }

    func importPacket(packetBytes: Data, transferPassword: String?) async -> ImportedPacketInfo? {
        await run({ try ManagementClient.importPacket(packetBytes: packetBytes, transferPassword: transferPassword) })
    }

    func mergeReencryptDiscardIncoming(targetCompartmentId: String, incomingManifestJson: String, incomingKeyBlobs: [IncomingKeyBlob]) async -> MergeOutcomeInfo? {
        await run({
            try ManagementClient.mergeReencryptDiscardIncoming(targetCompartmentId: targetCompartmentId, incomingManifestJson: incomingManifestJson, incomingKeyBlobs: incomingKeyBlobs)
        })
    }

    func mergeSideBySide(
        incomingManifestJson: String, incomingKeyBlobs: [IncomingKeyBlob], newCompartmentLabel: String, newMasterPassphrase: String, profile: FacadeDeviceProfile
    ) async -> MergeOutcomeInfo? {
        await run({
            try ManagementClient.mergeSideBySide(
                incomingManifestJson: incomingManifestJson, incomingKeyBlobs: incomingKeyBlobs, newCompartmentLabel: newCompartmentLabel,
                newMasterPassphrase: newMasterPassphrase, profile: profile
            )
        })
    }

    func mergeReplaceLocalWithIncoming(
        targetCompartmentId: String, incomingManifestJson: String, incomingKeyBlobs: [IncomingKeyBlob], incomingMasterPassphrase: String,
        incomingKdfParamsJson: String, confirmationPhrase: String
    ) async -> MergeOutcomeInfo? {
        await run({
            try ManagementClient.mergeReplaceLocalWithIncoming(
                targetCompartmentId: targetCompartmentId, incomingManifestJson: incomingManifestJson, incomingKeyBlobs: incomingKeyBlobs,
                incomingMasterPassphrase: incomingMasterPassphrase, incomingKdfParamsJson: incomingKdfParamsJson, confirmationPhrase: confirmationPhrase
            )
        })
    }

    // MARK: - Auto-unlock (spec §8) — the agent owns Keychain + VaultConfig writes for this now

    func enableAutoUnlock(compartmentId: String, passphrase: String) async -> Bool {
        await run({ try ManagementClient.enableAutoUnlock(compartmentId: compartmentId, passphrase: passphrase) }) != nil
    }

    func disableAutoUnlock(compartmentId: String) {
        ManagementClient.disableAutoUnlock(compartmentId: compartmentId)
    }

    func isAutoUnlockEnabled(compartmentId: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { ManagementClient.isAutoUnlockEnabled(compartmentId: compartmentId) }.value
    }
}
