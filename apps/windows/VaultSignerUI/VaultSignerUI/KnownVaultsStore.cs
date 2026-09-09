using System.Text.Json;

namespace VaultSignerUI;

/// Spec §5.6: remembers where vault files live across launches, so the
/// user isn't re-browsing to the same file every time. Mirrors
/// apps/macos/Shared/KnownVaultsStore.swift field-for-field (same JSON
/// shape, same file name) even though nothing reads this file across
/// platforms — keeping the shape identical is just one less thing to
/// remember when working across both. This list is local device state
/// only — never written into any vault/packet file, never synced, and
/// never holds a passphrase or key material (only a path and a
/// timestamp). Lives in the UI process, not the agent: unlike vault
/// state itself (spec §8: the agent is the sole writer of the
/// container file), this is purely a UI convenience with no bearing on
/// vault correctness.
internal sealed record KnownVaultEntry(string Path, DateTimeOffset LastAccessedAt);

internal static class KnownVaultsStore
{
    private static string StorePath =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VaultSigner", "known_vaults.json");

    /// Most-recently-accessed first (spec §5.6: "most-recently-opened first").
    public static KnownVaultEntry[] Load()
    {
        try
        {
            if (!File.Exists(StorePath)) return [];
            var json = File.ReadAllText(StorePath);
            var entries = JsonSerializer.Deserialize<KnownVaultEntry[]>(json) ?? [];
            return entries.OrderByDescending(e => e.LastAccessedAt).ToArray();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static void Save(KnownVaultEntry[] entries)
    {
        try
        {
            var dir = System.IO.Path.GetDirectoryName(StorePath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(StorePath, JsonSerializer.Serialize(entries));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Best-effort, same as macOS's `try?` — a failed write here
            // only costs the user a re-browse next launch, never data.
        }
    }

    /// Call whenever a vault is successfully created or opened (spec
    /// §5.6: "Creating or opening a vault by any means ... adds or
    /// updates its entry in this list automatically").
    public static void RecordOpened(string path)
    {
        var entries = Load().Where(e => e.Path != path).ToList();
        entries.Add(new KnownVaultEntry(path, DateTimeOffset.UtcNow));
        Save(entries.ToArray());
    }

    /// Spec §5.6's management-screen "add a known vault by browsing to a
    /// file without opening it immediately."
    public static void AddWithoutOpening(string path)
    {
        if (Load().Any(e => e.Path == path)) return;
        RecordOpened(path);
    }

    /// Spec §5.6: "Forgetting an entry only removes it from this list —
    /// it must never delete, move, or modify the underlying vault file."
    public static void Forget(string path)
    {
        Save(Load().Where(e => e.Path != path).ToArray());
    }
}
