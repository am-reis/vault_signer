using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Navigation parameter for KeyDetailPage — a key on its own isn't
/// enough to call `internal.discard_key` (that also needs the owning
/// compartment's id), so VaultHomePage passes both together.
internal sealed record KeyDetailNavArgs(string CompartmentId, KeyInfo Key);

/// Standalone key-detail screen, navigated to from VaultHomePage by
/// clicking a key in its list. Mirrors
/// apps/macos/VaultSigner/Sources/KeyDetailView.swift's role, including
/// its danger-zone framing for Discard (spec's "reveal-raw-key's
/// danger-zone framing" convention, applied here to the destructive
/// discard action instead).
public sealed partial class KeyDetailPage : Page, ISensitiveScreen
{
    private KeyDetailNavArgs? _args;

    public KeyDetailPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _args = (KeyDetailNavArgs)e.Parameter;
        var info = _args.Key;

        TitleText.Text = info.label;
        DescriptionText.Text = info.description.Length > 0 ? info.description : "(none)";
        ResourceText.Text = info.resource;
        TypeText.Text = $"{info.keyType} / {info.purpose}";
        CreatedText.Text = info.createdAt;
        if (info.lastUsedAt is { } lastUsed)
        {
            LastUsedRow.Visibility = Visibility.Visible;
            LastUsedText.Text = lastUsed;
        }
        else
        {
            LastUsedRow.Visibility = Visibility.Collapsed;
        }
        PublicKeyText.Text = info.publicKeyHex;
        ConfirmPrompt.Text = $"Type \"{info.label}\" to confirm:";
        DiscardConfirmBox.Text = "";
    }

    private async void ExportKeyButton_Click(object sender, RoutedEventArgs e)
    {
        if (_args is not { } args) return;
        var destination = await FilePickers.PickSaveDestinationAsync(App.MainWindow, $"{args.Key.label}.vltkey");
        if (destination is null) return;
        RunGuarded(() =>
        {
            var bytes = ManagementClient.ExportSingleKey(args.CompartmentId, args.Key.keyId);
            File.WriteAllBytes(destination, bytes);
        });
    }

    /// Spec §5.1: "off by default, gated behind a 'danger zone' warning
    /// dialog and the per-key passphrase, shown once with no clipboard
    /// auto-copy." The hex is selectable (so the user can manually copy
    /// it if they choose) but nothing copies it for them. Deliberately
    /// not using ContentDialog's PrimaryButton for the Reveal action —
    /// clicking Primary always closes the dialog, and this needs to stay
    /// open afterward to show the result — so Reveal is a plain button
    /// inside Content and Close is the dialog's only native button,
    /// relabeled "Done" once something has been revealed.
    private async void RevealRawKeyButton_Click(object sender, RoutedEventArgs e)
    {
        if (_args is not { } args) return;

        var warningText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = "Anyone who sees this can act as this key, anywhere, without needing this device or your passphrase again. " +
                   "Only continue if you specifically need to move this key's raw material somewhere yourself.",
        };
        var passphraseBox = new PasswordBox { PlaceholderText = "This key's passphrase" };
        var errorText = new TextBlock { Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"], Visibility = Visibility.Collapsed };
        var revealedBox = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"), Visibility = Visibility.Collapsed };
        var revealButton = new Button { Content = "Reveal" };
        var entryPanel = new StackPanel { Spacing = 10, Children = { passphraseBox, errorText, revealButton } };

        var dialog = new ContentDialog
        {
            Title = "Reveal Raw Key — Danger Zone",
            Content = new StackPanel { Spacing = 14, Children = { warningText, entryPanel, revealedBox } },
            CloseButtonText = "Cancel",
            XamlRoot = XamlRoot,
        };

        revealButton.Click += (_, _) =>
        {
            errorText.Visibility = Visibility.Collapsed;
            if (passphraseBox.Password.Length == 0) return;
            revealButton.IsEnabled = false;
            try
            {
                var hex = ManagementClient.RevealRawKeyHex(args.CompartmentId, args.Key.keyId, passphraseBox.Password);
                revealedBox.Text = hex;
                revealedBox.Visibility = Visibility.Visible;
                entryPanel.Visibility = Visibility.Collapsed;
                dialog.CloseButtonText = "Done";
            }
            catch (FacadeException ex)
            {
                errorText.Text = ex.Message;
                errorText.Visibility = Visibility.Visible;
            }
            finally
            {
                revealButton.IsEnabled = true;
            }
        };

        await dialog.ShowAsync();
    }

    private void DiscardKeyButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            if (_args is not { } args) return;
            ManagementClient.DiscardKey(args.CompartmentId, args.Key.keyId, DiscardConfirmBox.Text.Trim());
            Frame.GoBack();
        });
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => Frame.GoBack();

    private void RunGuarded(Action action)
    {
        StatusBar.IsOpen = false;
        BusyRing.IsActive = true;
        DiscardKeyButton.IsEnabled = false;
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
            DiscardKeyButton.IsEnabled = true;
        }
    }
}
