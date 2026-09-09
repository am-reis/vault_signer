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
public sealed partial class KeyDetailPage : Page
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
