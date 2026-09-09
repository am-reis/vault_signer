using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// First screen of the real, navigated flow (see MainWindow.xaml's
/// `RootFrame` — this replaces the old single-scrolling-page approach,
/// same functionality, real per-screen navigation). Mirrors
/// apps/macos/VaultSigner/Sources/WelcomeView.swift's role.
public sealed partial class WelcomePage : Page
{
    public WelcomePage()
    {
        InitializeComponent();
        Loaded += WelcomePage_Loaded;
    }

    private void WelcomePage_Loaded(object sender, RoutedEventArgs e)
    {
        // VaultSignerAgent may already have a vault open (it loads
        // VaultConfig's saved path at its own startup) — skip straight
        // to VaultHomePage rather than showing this screen at all, and
        // drop this page from the back stack so "back" from there
        // can't return to a stale Welcome screen.
        try
        {
            ManagementClient.ListCompartments();
            Frame.Navigate(typeof(VaultHomePage));
            Frame.BackStack.Clear();
        }
        catch (FacadeException)
        {
            // No vault open yet — this screen is the right one to show.
        }
    }

    private void CreateVaultButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            var path = VaultPathBox.Text.Trim();
            var label = CompartmentLabelBox.Text.Trim();
            var passphrase = MasterPassphraseBox.Password;
            if (path.Length == 0 || label.Length == 0 || passphrase.Length == 0)
            {
                throw new FacadeException.Failed("Vault file, compartment name and master passphrase are all required.");
            }
            ManagementClient.CreateVault(path, label, passphrase, FacadeDeviceProfile.Desktop);
            Frame.Navigate(typeof(VaultHomePage));
            Frame.BackStack.Clear();
        });
    }

    private void OpenVaultButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            var path = VaultPathBox.Text.Trim();
            if (path.Length == 0) throw new FacadeException.Failed("Vault file is required.");
            ManagementClient.OpenVault(path);
            Frame.Navigate(typeof(VaultHomePage));
            Frame.BackStack.Clear();
        });
    }

    private void RunGuarded(Action action)
    {
        StatusBar.IsOpen = false;
        BusyRing.IsActive = true;
        CreateVaultButton.IsEnabled = false;
        OpenVaultButton.IsEnabled = false;
        try
        {
            action();
        }
        catch (FacadeException ex)
        {
            StatusBar.Message = ex.Message;
            StatusBar.IsOpen = true;
        }
        finally
        {
            BusyRing.IsActive = false;
            CreateVaultButton.IsEnabled = true;
            OpenVaultButton.IsEnabled = true;
        }
    }
}
