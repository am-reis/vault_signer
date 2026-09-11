using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Nav parameter for ExportKeysPage. `BackupMode` mirrors
/// ExportPacketView.swift's `lockSelectionToAllKeys`/`forceIncludeMasterKey`
/// flags collapsed into one — spec §5.4's "back up everything" is just
/// this same screen with every key pre-selected and the master key
/// forced in, not a separate implementation.
internal sealed record ExportPageArgs(string CompartmentId, bool BackupMode);

/// Spec §5.2's packet export flow (also §5.4's "back up everything," via
/// `BackupMode` — see `ExportPageArgs`): pick keys, decide whether to
/// include the master key (§5.2.1), then choose one of the three
/// §5.2.2 encryption options — three distinct, uncollapsed choices with
/// no default pre-selected. Screen-capture-blocked (§5.0). Mirrors
/// apps/macos/VaultSigner/Sources/Views/ExportPacketView.swift.
public sealed partial class ExportKeysPage : Page, ISensitiveScreen
{
    private string _compartmentId = "";
    private bool _backupMode;

    public ExportKeysPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var args = (ExportPageArgs)e.Parameter;
        _compartmentId = args.CompartmentId;
        _backupMode = args.BackupMode;

        TitleText.Text = _backupMode ? "Back Up Everything" : "Export Keys";
        KeySelectionSection.Visibility = _backupMode ? Visibility.Collapsed : Visibility.Visible;
        IncludeMasterKeySection.Visibility = _backupMode ? Visibility.Collapsed : Visibility.Visible;

        RunGuarded(() =>
        {
            var keys = ManagementClient.ListKeys(_compartmentId);
            var rows = keys.Select(k => new KeyRow(k)).ToArray();
            KeysList.ItemsSource = rows;
            if (_backupMode)
            {
                foreach (var row in rows) KeysList.SelectedItems.Add(row);
            }
        });
    }

    private void EncryptionOption_Checked(object sender, RoutedEventArgs e)
    {
        DestinationPasswordBox.Visibility = DestinationPasswordRadio.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        TransferPasswordFields.Visibility = TransferPasswordRadio.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void ExportButton_Click(object sender, RoutedEventArgs e)
    {
        FacadeExportEncryption encryption;
        if (AsIsRadio.IsChecked == true)
        {
            encryption = new FacadeExportEncryption.AsIs();
        }
        else if (DestinationPasswordRadio.IsChecked == true)
        {
            if (DestinationPasswordBox.Password.Length == 0)
            {
                ShowError("Enter the destination vault's master passphrase.");
                return;
            }
            encryption = new FacadeExportEncryption.DestinationMasterPassword(DestinationPasswordBox.Password);
        }
        else if (TransferPasswordRadio.IsChecked == true)
        {
            if (TransferPasswordBox.Password.Length == 0)
            {
                ShowError("Enter a transfer passphrase.");
                return;
            }
            if (TransferPasswordBox.Password != ConfirmTransferPasswordBox.Password)
            {
                ShowError("Transfer passphrases don't match.");
                return;
            }
            encryption = new FacadeExportEncryption.OneTimeTransferPassword(TransferPasswordBox.Password);
        }
        else
        {
            ShowError("Choose how to protect this export first.");
            return;
        }

        var keyIds = KeysList.SelectedItems.Cast<KeyRow>().Select(r => r.Info.keyId).ToArray();
        var includeMasterKey = _backupMode || IncludeMasterKeyCheck.IsChecked == true;
        if (keyIds.Length == 0 && !includeMasterKey)
        {
            ShowError("Select at least one key, or include the master key.");
            return;
        }

        var suggestedName = _backupMode ? "Backup.vltpack" : "Export.vltpack";
        var destination = await FilePickers.PickSaveDestinationAsync(App.MainWindow, suggestedName);
        if (destination is null) return;

        RunGuarded(() =>
        {
            var bytes = ManagementClient.ExportPacket(_compartmentId, keyIds, includeMasterKey, encryption);
            File.WriteAllBytes(destination, bytes);
            Frame.GoBack();
        });
    }

    private void ShowError(string message)
    {
        StatusBar.Message = message;
        StatusBar.IsOpen = true;
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => Frame.GoBack();

    private void RunGuarded(Action action)
    {
        StatusBar.IsOpen = false;
        BusyRing.IsActive = true;
        ExportButton.IsEnabled = false;
        try
        {
            action();
        }
        catch (FacadeException ex)
        {
            ShowError(ex.Message);
        }
        catch (IOException ex)
        {
            ShowError($"Couldn't write the export file: {ex.Message}");
        }
        finally
        {
            BusyRing.IsActive = false;
            ExportButton.IsEnabled = true;
        }
    }
}
