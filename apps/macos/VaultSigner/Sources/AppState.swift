import Foundation

/// Central app state (spec §12 item 2.1): owns the current `Vault` and
/// mirrors just enough of its state into `@Published` properties for
/// SwiftUI to observe. Every vaultcore call is real work (Argon2id is
/// deliberately slow — spec §4.2 targets 500ms-1s) so each one runs off
/// the main thread via `Task.detached` and hops back to `MainActor` only
/// to publish the result; nothing here re-implements vault logic; it is
/// exclusively a thin, observable wrapper around the `Vault` facade.
@MainActor
final class AppState: ObservableObject {
    @Published var vault: Vault?
    @Published var vaultPath: String?
    @Published var compartments: [CompartmentInfo] = []
    @Published var unlockedCompartmentId: String?
    @Published var keys: [KeyInfo] = []
    @Published var isBusy = false
    @Published var errorMessage: String?

    func clearError() {
        errorMessage = nil
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

    func createVault(path: String, label: String, masterPassphrase: String, profile: FacadeDeviceProfile) async {
        guard let created = await run({ try Vault.create(path: path, compartmentLabel: label, masterPassphrase: masterPassphrase, profile: profile) }) else { return }
        vault = created
        vaultPath = path
        VaultConfig.save(vaultPath: path)
        refreshCompartments()
        if let first = compartments.first {
            unlockedCompartmentId = first.compartmentId
            refreshKeys()
        }
    }

    func openVault(path: String) async {
        guard let opened = await run({ try Vault.open(path: path) }) else { return }
        vault = opened
        vaultPath = path
        VaultConfig.save(vaultPath: path)
        unlockedCompartmentId = nil
        keys = []
        refreshCompartments()
    }

    func refreshCompartments() {
        guard let vault else { return }
        compartments = vault.listCompartments()
    }

    func unlock(compartmentId: String, passphrase: String) async {
        guard let vault else { return }
        guard await run({ try vault.unlockCompartment(compartmentId: compartmentId, passphrase: passphrase) }) != nil else { return }
        unlockedCompartmentId = compartmentId
        refreshCompartments()
        refreshKeys()
    }

    func lockAll() {
        vault?.lockAll()
        unlockedCompartmentId = nil
        keys = []
        refreshCompartments()
    }

    func refreshKeys() {
        guard let vault, let compartmentId = unlockedCompartmentId else { return }
        Task {
            keys = await run({ try vault.listKeys(compartmentId: compartmentId) }) ?? keys
        }
    }

    @discardableResult
    func createKey(
        keyType: FacadeKeyType, purpose: FacadePurpose, label: String, description: String,
        resource: String, tags: [String], keyPassphrase: String
    ) async -> KeyInfo? {
        guard let vault, let compartmentId = unlockedCompartmentId else { return nil }
        let created = await run({
            try vault.createKey(
                compartmentId: compartmentId, keyType: keyType, purpose: purpose, label: label,
                description: description, resource: resource, tags: tags, keyPassphrase: keyPassphrase,
                fido2RpId: nil, fido2UserHandleB64: nil
            )
        })
        if created != nil { refreshKeys() }
        return created
    }

    func discardKey(keyId: String, confirmText: String) async -> Bool {
        guard let vault, let compartmentId = unlockedCompartmentId else { return false }
        let ok = await run({ try vault.discardKey(compartmentId: compartmentId, keyId: keyId, confirmText: confirmText) }) != nil
        if ok { refreshKeys() }
        return ok
    }

    func changeKeyPassphrase(keyId: String, oldPassphrase: String, newPassphrase: String) async -> Bool {
        guard let vault, let compartmentId = unlockedCompartmentId else { return false }
        return await run({
            try vault.changeKeyPassphrase(compartmentId: compartmentId, keyId: keyId, oldPassphrase: oldPassphrase, newPassphrase: newPassphrase)
        }) != nil
    }

    func revealRawKeyHex(keyId: String, passphrase: String) async -> String? {
        guard let vault, let compartmentId = unlockedCompartmentId else { return nil }
        return await run({ try vault.revealRawKeyHex(compartmentId: compartmentId, keyId: keyId, passphrase: passphrase) })
    }
}
