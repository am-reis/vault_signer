using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace VaultSignerUI;

/// A page implements this to mark itself as needing spec §5.0's
/// screen-capture blocking: "applied to ... raw-key reveal screens,
/// passphrase entry fields, the import master-key-duality decision
/// screens, and any screen rendering a manifest in detail." Unlike
/// macOS, where each sensitive view is its own `NSWindow`
/// (`CaptureProtected`/`preventsScreenCapture()`), this app is one
/// `Window` with a `Frame` swapping `Page`s (see MainWindow.xaml's
/// `RootFrame`) — so protection is applied to the window itself,
/// toggled on/off as navigation lands on/leaves a marked page. See
/// `MainWindow.xaml.cs`'s `RootFrame.Navigated` handler.
internal interface ISensitiveScreen;

internal static class ScreenCaptureProtection
{
    // Same constants and fallback reasoning as
    // VaultSignerAgent/WinFormsPassphrasePrompter.cs's identical
    // P/Invoke — WDA_EXCLUDEFROMCAPTURE (0x11, Windows 10 2004+) falls
    // back to WDA_MONITOR (0x1, blacked-out-but-still-captured) on
    // older builds that refuse it; either way the content is never in
    // the clear in a captured frame.
    private const uint WDA_MONITOR = 0x00000001;
    private const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;
    private const uint WDA_NONE = 0x00000000;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);

    public static void Apply(Window window)
    {
        var hwnd = WindowNative.GetWindowHandle(window);
        if (!SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE))
        {
            SetWindowDisplayAffinity(hwnd, WDA_MONITOR);
        }
    }

    public static void Clear(Window window)
    {
        SetWindowDisplayAffinity(WindowNative.GetWindowHandle(window), WDA_NONE);
    }
}
