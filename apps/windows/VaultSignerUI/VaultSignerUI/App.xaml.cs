using Windows.ApplicationModel;
using Windows.ApplicationModel.Activation;
using Windows.Foundation;
using Windows.Foundation.Collections;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;

// To learn more about WinUI, the WinUI project structure,
// and more about our project templates, see: http://aka.ms/winui-project-info.

namespace VaultSignerUI;

/// <summary>
/// Provides application-specific behavior to supplement the default Application class.
/// </summary>
public partial class App : Application
{
    private Window? _window;

    /// The app's single window — exposed so pages can pass it to
    /// FilePickers.cs's picker calls, which need an HWND to associate
    /// with (this is an unpackaged app; WinRT pickers otherwise fail to
    /// activate at all). Set once in OnLaunched, never null afterward.
    public static Window MainWindow { get; private set; } = null!;

    /// <summary>
    /// Initializes the singleton application object.  This is the first line of authored code
    /// executed, and as such is the logical equivalent of main() or WinMain().
    /// </summary>
    public App()
    {
        InitializeComponent();
    }

    /// <summary>
    /// Invoked when the application is launched.
    /// </summary>
    /// <param name="args">Details about the launch request and process.</param>
    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        if (TryHandleTestI18n()) return;

        _window = new MainWindow();
        MainWindow = _window;
        _window.Activate();
    }

    /// Headless resource-lookup check, mirroring macOS's own
    /// VaultSignerApp.swift `--test-i18n <locale> <key>` hook (see
    /// i18n/README.md): resolves a key directly against a named
    /// satellite resource, bypassing the OS/app display language
    /// entirely, without ever showing a window. `AllocConsole` is
    /// needed because this is a WinExe with no console attached by
    /// default. Returns true if it handled the args (caller should not
    /// proceed to create the normal UI).
    private static bool TryHandleTestI18n()
    {
        var cmdArgs = Environment.GetCommandLineArgs();
        var flagIndex = Array.IndexOf(cmdArgs, "--test-i18n");
        if (flagIndex < 0 || flagIndex + 2 >= cmdArgs.Length) return false;

        NativeMethods.AllocConsole();
        // AllocConsole's new console defaults to the OEM codepage, not
        // UTF-8 -- without this, a non-ASCII resolved value (e.g. the
        // Arabic satellite) prints as mangled '?' characters even
        // though the actual lookup succeeded. Confirmed live: this was
        // the console's own encoding, not a resource-resolution bug.
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        var locale = cmdArgs[flagIndex + 1];
        var key = cmdArgs[flagIndex + 2];
        var previousCulture = System.Globalization.CultureInfo.CurrentUICulture;
        try
        {
            System.Globalization.CultureInfo.CurrentUICulture = new System.Globalization.CultureInfo(locale);
            Console.WriteLine(Strings.Get(key));
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentUICulture = previousCulture;
        }
        Environment.Exit(0);
        return true;
    }

    private static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern bool AllocConsole();
    }
}
