import Foundation
import Security

/// Spec §8's "Auto-unlock on startup" toggle: stores a compartment's
/// master passphrase in the macOS Keychain (never as a plaintext file —
/// see `VaultConfig`, which only ever holds the vault's file *path*) so
/// `VaultSignerAgent` can unlock it automatically at launch, without a
/// human typing the master passphrase after every boot/login.
///
/// **Disclosed caveat (spec §8: "must be disclosed as such"):** spec §8
/// specifically credits macOS Keychain with being able to "scope
/// decryption to the requesting app/process," which is real protection
/// against a malicious co-resident app — but that scoping is normally
/// enforced via a Keychain access group tied to a real Team ID
/// (`kSecAttrAccessGroup` + the `keychain-access-groups` entitlement),
/// which needs a paid Apple Developer Program enrollment to provision
/// (see the macOS README's note on item 2.7 — same underlying
/// constraint). Ad-hoc/local-development signing has no stable Team ID,
/// so this implementation stores the item without a restricted access
/// group: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` still requires
/// the Mac to be unlocked and keeps it out of iCloud sync, but does not
/// by itself stop another process running as the same OS user from
/// reading it — full parity with the spec's stated Keychain protection
/// needs the same developer-account step as item 2.7.
enum AutoUnlockStore {
    private static let service = "com.vaultsigner.auto-unlock"

    static func save(passphrase: String, forCompartment compartmentId: String) -> Bool {
        delete(forCompartment: compartmentId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compartmentId,
            kSecValueData as String: Data(passphrase.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(forCompartment compartmentId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compartmentId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(forCompartment compartmentId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compartmentId,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
