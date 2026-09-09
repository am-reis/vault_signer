using System.Text.Json;

namespace VaultSignerAgent;

/// The one piece of state shared between VaultSignerUI (which knows which
/// vault the user opened) and VaultSignerAgent (which needs to know which
/// vault to open when it's started at login, long before any UI exists to
/// tell it) — mirrors apps/macos/Shared/VaultConfig.swift exactly. Neither
/// side stores anything secret here, just the file path — see
/// DpapiAutoUnlockStore for the passphrase itself.
internal static class VaultConfig
{
    private static string ConfigPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VaultSigner", "config.json");

    private sealed record ConfigData(string? VaultPath, string? AutoUnlockCompartmentId);

    private static ConfigData Load()
    {
        try
        {
            var json = File.ReadAllText(ConfigPath);
            return JsonSerializer.Deserialize<ConfigData>(json) ?? new ConfigData(null, null);
        }
        catch
        {
            return new ConfigData(null, null);
        }
    }

    private static void Write(ConfigData data)
    {
        var dir = Path.GetDirectoryName(ConfigPath)!;
        Directory.CreateDirectory(dir);
        var tmp = ConfigPath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(data));
        File.Move(tmp, ConfigPath, overwrite: true);
    }

    public static void SaveVaultPath(string vaultPath)
    {
        var current = Load();
        Write(current with { VaultPath = vaultPath });
    }

    public static string? LoadVaultPath() => Load().VaultPath;

    public static void SaveAutoUnlockCompartmentId(string? compartmentId)
    {
        var current = Load();
        Write(current with { AutoUnlockCompartmentId = compartmentId });
    }

    public static string? LoadAutoUnlockCompartmentId() => Load().AutoUnlockCompartmentId;
}
