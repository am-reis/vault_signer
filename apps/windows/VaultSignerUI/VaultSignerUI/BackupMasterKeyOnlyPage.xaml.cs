using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Spec §5.4's "back up master key only" shortcut: header + master key
/// blob only, no per-key blobs at all — `ExportPacket` with no key ids
/// and `includeMasterKey: true`, always protected with a one-time
/// transfer password (there's no key list here to justify the other two
/// §5.2.2 encryption options, and the explicit warning that this alone
/// protects nothing is the whole point of this screen). Deliberately a
/// separate, much smaller page than ExportKeysPage rather than a mode
/// flag on it, mirroring
/// apps/macos/VaultSigner/Sources/Views/BackupMasterKeyOnlyView.swift.
public sealed partial class BackupMasterKeyOnlyPage : Page, ISensitiveScreen
{
    private string _compartmentId = "";

    public BackupMasterKeyOnlyPage()
    {
        InitializeComponent();
        BackButtonElement.Content = Strings.Get("nav.back_button");
        TitleText.Text = Strings.Get("backupmasterkey.title");
        WarningText.Text = Strings.Get("backupmasterkey.warning_text");
        TransferPasswordBox.PlaceholderText = Strings.Get("backupmasterkey.transfer_passphrase_field");
        ConfirmTransferPasswordBox.PlaceholderText = Strings.Get("backupmasterkey.confirm_field");
        BackUpButton.Content = Strings.Get("backupmasterkey.backup_button");
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _compartmentId = (string)e.Parameter;
    }

    private async void BackUpButton_Click(object sender, RoutedEventArgs e)
    {
        var password = TransferPasswordBox.Password;
        if (password.Length == 0)
        {
            ShowError("Enter a transfer passphrase.");
            return;
        }
        if (password != ConfirmTransferPasswordBox.Password)
        {
            ShowError("Transfer passphrases don't match.");
            return;
        }

        var destination = await FilePickers.PickSaveDestinationAsync(App.MainWindow, "MasterKeyBackup.vltpack");
        if (destination is null) return;

        BusyRing.IsActive = true;
        BackUpButton.IsEnabled = false;
        try
        {
            var bytes = ManagementClient.ExportPacket(_compartmentId, [], includeMasterKey: true, new FacadeExportEncryption.OneTimeTransferPassword(password));
            File.WriteAllBytes(destination, bytes);
            Frame.GoBack();
        }
        catch (FacadeException ex)
        {
            ShowError(ex.Message);
        }
        catch (IOException ex)
        {
            ShowError($"Couldn't write the backup file: {ex.Message}");
        }
        finally
        {
            BusyRing.IsActive = false;
            BackUpButton.IsEnabled = true;
        }
    }

    private void ShowError(string message)
    {
        StatusBar.Message = message;
        StatusBar.IsOpen = true;
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => Frame.GoBack();
}
