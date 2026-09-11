using System.Globalization;
using System.Resources;

namespace VaultSignerUI;

/// <summary>
/// Thin ResourceManager wrapper mirroring how SwiftUI's
/// Text(LocalizedStringKey) resolves a flat key against
/// Localizable.strings on macOS (see i18n/README.md): a flat,
/// dot-separated key like "welcome.subtitle" looked up directly,
/// not WinRT's x:Uid/"Uid.Property" convention -- so the exact same
/// key namespace in i18n/source/*.json works unchanged on both
/// platforms. Backed by classic .NET satellite .resx resources
/// (Resources/Strings.resx, Strings.ar.resx, ...), not WinRT's
/// ResourceLoader/MRT -- deliberately, since this app is unpackaged
/// (see VaultSignerUI.csproj's WindowsAppSDKSelfContained comment for
/// why), and MRT's resource indexing (.pri files) is designed around
/// package identity that this app doesn't have.
/// </summary>
public static class Strings
{
    private static readonly ResourceManager _rm =
        new("VaultSignerUI.Resources.Strings", typeof(Strings).Assembly);

    /// Falls back to the raw key if it's missing from every satellite
    /// and the neutral resource, mirroring NSLocalizedString's own
    /// "return the key itself" behavior for an unresolvable lookup --
    /// callers see a recognizable placeholder instead of a crash.
    public static string Get(string key) =>
        _rm.GetString(key, CultureInfo.CurrentUICulture) ?? key;

    public static string Format(string key, params object[] args) =>
        string.Format(CultureInfo.CurrentUICulture, Get(key), args);
}
