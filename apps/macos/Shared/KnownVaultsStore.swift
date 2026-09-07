import Foundation

/// Spec §5.6: remembers where vault files live across launches, so the
/// user isn't re-browsing to the same file every time. This list is
/// local device state only — never written into any vault/packet file,
/// never synced, and never holds a passphrase or key material (only a
/// path and a timestamp).
///
/// Uses plain file paths, not security-scoped bookmarks: this app does
/// not currently request the App Sandbox entitlement (see
/// `apps/macos/project.yml`), so a stable path is sufficient. If App
/// Sandbox is adopted later (e.g. for Mac App Store distribution — see
/// spec §5.6's own note on this), switch to bookmarks so entries survive
/// the file moving within the user's already-granted access scope.
struct KnownVaultEntry: Codable, Identifiable, Equatable {
    var id: String { path }
    var path: String
    /// Set whenever the entry is added or successfully opened — used
    /// both for "most-recently-opened first" ordering and, loosely, to
    /// distinguish "added but never opened" entries (see
    /// `KnownVaultsStore.addWithoutOpening`).
    var lastAccessedAt: Date
}

enum KnownVaultsStore {
    private static var storePath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/VaultSigner/known_vaults.json")
    }

    /// Most-recently-accessed first (spec §5.6: "most-recently-opened
    /// first").
    static func load() -> [KnownVaultEntry] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
              let entries = try? JSONDecoder().decode([KnownVaultEntry].self, from: data)
        else { return [] }
        return entries.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private static func save(_ entries: [KnownVaultEntry]) {
        let dir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }

    /// Call whenever a vault is successfully created or opened (spec
    /// §5.6: "Creating or opening a vault by any means ... adds or
    /// updates its entry in this list automatically").
    static func recordOpened(path: String) {
        var entries = load().filter { $0.path != path }
        entries.append(KnownVaultEntry(path: path, lastAccessedAt: Date()))
        save(entries)
    }

    /// Spec §5.6's management-screen "add a known vault by browsing to a
    /// file without opening it immediately."
    static func addWithoutOpening(path: String) {
        guard !load().contains(where: { $0.path == path }) else { return }
        recordOpened(path: path)
    }

    /// Spec §5.6: "Forgetting an entry only removes it from this list —
    /// it must never delete, move, or modify the underlying vault file."
    static func forget(path: String) {
        save(load().filter { $0.path != path })
    }
}
