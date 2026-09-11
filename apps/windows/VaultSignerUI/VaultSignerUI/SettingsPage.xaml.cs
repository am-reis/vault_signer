using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Spec §8's two independent toggles, plus the second entry point to
/// known-vaults management spec §5.6 requires ("reachable both from the
/// entry screen and from the app's settings"). Mirrors
/// apps/macos/VaultSigner/Sources/Views/SettingsView.swift's role. The
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
        BackButtonElement.Content = Strings.Get("nav.back_button");
        TitleText.Text = Strings.Get("settings.title");
        AutostartToggle.Header = Strings.Get("settings.start_at_login_toggle");
        AutostartToggle.OnContent = Strings.Get("common.on_state");
        AutostartToggle.OffContent = Strings.Get("common.off_state");
        AutostartFooterText.Text = Strings.Get("settings.start_at_login_footer");
        AutoUnlockToggle.Header = Strings.Get("settings.auto_unlock_toggle");
        AutoUnlockToggle.OnContent = Strings.Get("common.on_state");
        AutoUnlockToggle.OffContent = Strings.Get("common.off_state");
        ManageVaultsLinkButton.Content = Strings.Get("settings.manage_vaults_button");
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var args = (SettingsPageArgs)e.Parameter;
        _compartmentId = args.CompartmentId;
        _compartmentLabel = args.CompartmentLabel;
        AutoUnlockCompartmentText.Text = Strings.Format("settings.auto_unlock_explanation_format", _compartmentLabel);

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
        var passphraseBox = new PasswordBox { PlaceholderText = Strings.Get("settings.auto_unlock_confirm_passphrase_placeholder") };
        var dialog = new ContentDialog
        {
            Title = Strings.Get("settings.auto_unlock_confirm_title"),
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
            PrimaryButtonText = Strings.Get("settings.auto_unlock_confirm_turn_on_button"),
            CloseButtonText = Strings.Get("common.cancel_button"),
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
