import Foundation

/// The one piece of state shared between `VaultSigner.app` (which knows
/// which vault the user opened) and `VaultSignerAgent` (which needs to
/// know which vault to open when launchd starts it at login, long before
/// any UI exists to tell it) — spec §8's login-item agent has no `--vault`
/// argument to hand it, since a `LaunchAgents` plist's `ProgramArguments`
/// are static and baked in at embed time, not per-user-configurable
/// after install. Neither side stores anything secret here — just the
/// file path, never a passphrase (see `AutoUnlockStore` for that).
enum VaultConfig {
    private static var configPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/VaultSigner/config.json")
    }

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func write(_ json: [String: Any]) {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try? JSONSerialization.data(withJSONObject: json)
        try? data?.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    static func save(vaultPath: String) {
        var json = load()
        json["vault_path"] = vaultPath
        write(json)
    }

    static func loadVaultPath() -> String? {
        load()["vault_path"] as? String
    }

    /// The one compartment, if any, the agent should unlock automatically
    /// at launch using `AutoUnlockStore` — never the passphrase itself.
    static func saveAutoUnlockCompartmentId(_ compartmentId: String?) {
        var json = load()
        if let compartmentId {
            json["auto_unlock_compartment_id"] = compartmentId
        } else {
            json.removeValue(forKey: "auto_unlock_compartment_id")
        }
        write(json)
    }

    static func loadAutoUnlockCompartmentId() -> String? {
        load()["auto_unlock_compartment_id"] as? String
    }
}
