using Microsoft.Win32;

namespace VaultSignerAgent;

/// Spec §8's "start at login" toggle. Mirrors macOS's `LoginItemManager`
/// (`SMAppService.agent`), but Windows has no per-user "login item"
/// registry distinct from general autostart — the standard, well-
/// documented mechanism for "run this program when I log in" is the
/// current user's `Run` registry key, which is exactly what every
/// ordinary consumer app (this is not a system-wide or elevated change:
/// `HKEY_CURRENT_USER`, not `HKEY_LOCAL_MACHINE`) uses for the same
/// toggle. Off by default; only written when the user explicitly enables
/// it in VaultSignerUI's settings screen, same as macOS.
internal static class AutostartManager
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "VaultSignerAgent";

    public static void Enable(string agentExecutablePath)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException($@"couldn't open HKCU\{RunKeyPath}");
        key.SetValue(ValueName, $"\"{agentExecutablePath}\"", RegistryValueKind.String);
    }

    public static void Disable()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        key?.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(ValueName) is not null;
    }
}
