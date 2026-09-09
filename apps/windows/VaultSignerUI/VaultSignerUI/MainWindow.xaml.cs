using Microsoft.UI.Xaml;

// To learn more about WinUI, the WinUI project structure,
// and more about our project templates, see: http://aka.ms/winui-project-info.

namespace VaultSignerUI;

/// <summary>
/// The application window. This hosts a Frame that displays pages. Add your
/// UI and logic to MainPage.xaml / MainPage.xaml.cs instead of here so you
/// can use Page features such as navigation events and the Loaded lifecycle.
/// </summary>
public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);

        AppWindow.SetIcon("Assets/AppIcon.ico");

        // Spec §5.0's screen-capture blocking, applied per-page since
        // this app is one Window with a Frame swapping Pages (see
        // ScreenCaptureProtection.cs) — toggle it on the window itself
        // as navigation lands on/leaves a page that implements
        // ISensitiveScreen.
        RootFrame.Navigated += (_, e) =>
        {
            if (e.Content is ISensitiveScreen) ScreenCaptureProtection.Apply(this);
            else ScreenCaptureProtection.Clear(this);
        };

        // Navigate the root frame to the welcome page on startup; it
        // redirects straight to VaultHomePage itself if the agent
        // already has a vault open.
        RootFrame.Navigate(typeof(WelcomePage));
    }
}
