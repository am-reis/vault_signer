using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Spec §8's two independent toggles, plus the second entry point to
/// known-vaults management spec §5.6 requires ("reachable both from the
/// entry screen and from the app's settings"). Mirrors
/// apps/macos/VaultSigner/Sources/Views/SettingsView.swift's role — this
/// app has no i18n scaffolding yet (spec item 3.7, still open), so the
/// copy here is plain literal text rather than resource keys, but the
/// two toggles' behavior and defaults, and the DPAPI risk disclosure
/// text, match spec §8 and `DpapiAutoUnlockStore.cs`'s own doc comment
/// on what this screen is required to state.
public sealed partial class SettingsPage : Page, ISensitiveScreen
{
    private string _compartmentId = "";
    private string _compartmentLabel = "";
    private bool _loading;

    public SettingsPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var args = (SettingsPageArgs)e.Parameter;
        _compartmentId = args.CompartmentId;
        _compartmentLabel = args.CompartmentLabel;
        AutoUnlockCompartmentText.Text =
            $"Unlocks \"{_compartmentLabel}\" automatically when VaultSignerAgent starts, without you typing its passphrase. " +
            "This does not expose individual keys — those still need their own passphrases regardless of this setting. " +
            "Windows note: the passphrase is protected with DPAPI tied to your Windows account, not to this app specifically — " +
            "any other process running as you (not just VaultSignerAgent) could in principle decrypt it too. This is weaker " +
            "than macOS's Keychain, which can scope access to VaultSigner alone.";

        _loading = true;
        BusyRing.IsActive = true;
        try
        {
            AutostartToggle.IsOn = ManagementClient.IsAutostartEnabled();
            AutoUnlockToggle.IsOn = ManagementClient.IsAutoUnlockEnabled(_compartmentId);
        }
        finally
        {
            BusyRing.IsActive = false;
            _loading = false;
        }
    }

    private void AutostartToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        StatusBar.IsOpen = false;
        try
        {
            if (AutostartToggle.IsOn) ManagementClient.EnableAutostart();
            else ManagementClient.DisableAutostart();
        }
        catch (FacadeException ex)
        {
            StatusBar.Message = ex.Message;
            StatusBar.IsOpen = true;
            _loading = true;
            AutostartToggle.IsOn = !AutostartToggle.IsOn;
            _loading = false;
        }
    }

    private async void AutoUnlockToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        StatusBar.IsOpen = false;

        if (!AutoUnlockToggle.IsOn)
        {
            ManagementClient.DisableAutoUnlock(_compartmentId);
            return;
        }

        // Require explicit confirmation with the risk explanation before
        // doing anything (spec §8: "requires explicit opt-in with an
        // in-app risk explanation") — never enable from the toggle flip
        // alone.
        var passphraseBox = new PasswordBox { PlaceholderText = "This compartment's master passphrase" };
        var dialog = new ContentDialog
        {
            Title = "Turn on auto-unlock?",
            Content = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new TextBlock
                    {
                        TextWrapping = TextWrapping.Wrap,
                        Text = AutoUnlockCompartmentText.Text,
                    },
                    passphraseBox,
                },
            },
            PrimaryButtonText = "Turn On",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };

        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary || passphraseBox.Password.Length == 0)
        {
            _loading = true;
            AutoUnlockToggle.IsOn = false;
            _loading = false;
            return;
        }

        BusyRing.IsActive = true;
        try
        {
            // The agent verifies the passphrase against the real vault
            // before ever writing it via DPAPI — a typo here fails
            // loudly instead of silently, permanently breaking
            // auto-unlock with no feedback.
            ManagementClient.EnableAutoUnlock(_compartmentId, passphraseBox.Password);
        }
        catch (FacadeException ex)
        {
            StatusBar.Message = ex.Message;
            StatusBar.IsOpen = true;
            _loading = true;
            AutoUnlockToggle.IsOn = false;
            _loading = false;
        }
        finally
        {
            BusyRing.IsActive = false;
        }
    }

    private void ManageVaultsLink_Click(object sender, RoutedEventArgs e) => Frame.Navigate(typeof(ManageVaultsPage));

    private void BackButton_Click(object sender, RoutedEventArgs e) => Frame.GoBack();
}

internal sealed record SettingsPageArgs(string CompartmentId, string CompartmentLabel);
