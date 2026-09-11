using System.Security.Cryptography;
using System.Text;

namespace VaultSignerAgent;

/// Spec §8's "Auto-unlock on startup" toggle, Windows implementation:
/// DPAPI (`ProtectedData`, `DataProtectionScope.CurrentUser`) instead of
/// a plaintext file. Mirrors apps/macos/Shared/AutoUnlockStore.swift's
/// role exactly, but the underlying guarantee is materially weaker — see
/// the disclosure below, which spec §8 requires stating explicitly rather
/// than implying parity with macOS Keychain.
///
/// **Disclosed limitation (spec §8, real and unresolved as of this
/// session — see PROGRESS.md's open-questions item 5):** DPAPI's default
/// `CurrentUser` scope ties the encryption key to the Windows user
/// account, not to this specific application. *Any* process running as
/// the same signed-in user — not just VaultSignerAgent — can call
/// `ProtectedData.Unprotect` on this exact file and recover the
/// plaintext compartment passphrase. This is categorically weaker than
/// macOS Keychain's per-app access-group scoping (itself only fully
/// realized with a paid Apple Developer Program Team ID — see the macOS
/// README's item 2.7 note) and weaker than Android Keystore. A
/// CNG/TPM-backed key or Windows Hello–gated protection would close this
/// gap; **not implemented here** — this session shipped the spec's
/// documented fallback ("plain DPAPI plus a stronger in-app disclosure
/// for v1") rather than guess at a TPM-backed design unverified against
/// a real product decision. The in-app enable-auto-unlock confirmation
/// screen (VaultSignerUI) must show this exact limitation before writing
/// anything here, not a generic "your passphrase will be stored securely"
/// line.
internal static class DpapiAutoUnlockStore
{
    private static string DirectoryPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VaultSigner", "auto_unlock");

    private static string PathFor(string compartmentId) =>
        Path.Combine(DirectoryPath, compartmentId.Replace("/", "_").Replace("\\", "_") + ".dpapi");

    public static bool Save(string passphrase, string compartmentId)
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            var plaintext = Encoding.UTF8.GetBytes(passphrase);
            // No optional entropy: this file already lives under the
            // current user's own LocalApplicationData, ACL-protected by
            // the OS the same way the rest of %LOCALAPPDATA% is: entropy
            // would only help against another process running as this
            // same user, which DPAPI CurrentUser scope cannot stop
            // regardless (see the disclosure above) — it would add
            // complexity without closing the actual gap.
            var ciphertext = ProtectedData.Protect(plaintext, optionalEntropy: null, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(PathFor(compartmentId), ciphertext);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static string? Load(string compartmentId)
    {
        try
        {
            var ciphertext = File.ReadAllBytes(PathFor(compartmentId));
            var plaintext = ProtectedData.Unprotect(ciphertext, optionalEntropy: null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plaintext);
        }
        catch
        {
            return null;
        }
    }

    public static bool Delete(string compartmentId)
    {
        try
        {
            var path = PathFor(compartmentId);
            if (File.Exists(path)) File.Delete(path);
            return true;
        }
        catch
        {
            return false;
        }
    }
}
