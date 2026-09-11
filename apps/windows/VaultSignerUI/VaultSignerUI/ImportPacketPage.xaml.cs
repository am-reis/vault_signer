using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Spec §5.3's import flow. Step 1 (decrypt the transfer layer, if
/// present) and the "no embedded master key" merge path are both here;
/// when the packet *does* embed a master key, this hands off to
/// MasterKeyDualityPage for spec §5.3 steps 2-3's unskippable decision
/// screen — that page finishes the flow itself (back to VaultHomePage)
/// rather than returning here, since `Frame.GoBack()` would otherwise
/// recreate this page from scratch and lose the in-flight state.
/// Screen-capture-blocked throughout (§5.0: passphrase entry, and
/// import decision screens are explicitly named in spec §5.0's list).
/// Mirrors apps/macos/VaultSigner/Sources/Views/ImportPacketView.swift.
public sealed partial class ImportPacketPage : Page, ISensitiveScreen
{
    private string _compartmentId = "";
    private byte[]? _pendingPacketBytes;

    public ImportPacketPage()
    {
        InitializeComponent();
        BackButtonElement.Content = Strings.Get("nav.back_button");
        TitleText.Text = Strings.Get("import.title");
        SubtitleText.Text = Strings.Get("import.subtitle_detailed");
        ChooseFileButton.Content = Strings.Get("import.choose_file_button");
        TransferPasswordPromptText.Text = Strings.Get("import.transfer_password_prompt");
        TransferPasswordBox.PlaceholderText = Strings.Get("import.transfer_password_field");
        ContinueButton.Content = Strings.Get("import.continue_button");
        CompleteTitleText.Text = Strings.Get("import.complete_title");
        DoneButtonElement.Content = Strings.Get("import.done_button");
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _compartmentId = (string)e.Parameter;
    }

    private async void ChooseFileButton_Click(object sender, RoutedEventArgs e)
    {
        var path = await FilePickers.PickExistingFileAsync(App.MainWindow);
        if (path is null) return;
        byte[] bytes;
        try
        {
            bytes = await File.ReadAllBytesAsync(path);
        }
        catch (IOException ex)
        {
            ShowError($"Couldn't read that file: {ex.Message}");
            return;
        }
        TryImport(bytes, transferPassword: null);
    }

    private void ContinueButton_Click(object sender, RoutedEventArgs e)
    {
        if (_pendingPacketBytes is not { } bytes) return;
        var password = TransferPasswordBox.Password;
        if (password.Length == 0)
        {
            ShowError("Enter the transfer passphrase.");
            return;
        }
        TryImport(bytes, password);
    }

    private void TryImport(byte[] packetBytes, string? transferPassword)
    {
        BusyRing.IsActive = true;
        IsHitTestVisible = false;
        try
        {
            var info = ManagementClient.ImportPacket(packetBytes, transferPassword);
            if (info.embeddedMasterCompartmentId is not null)
            {
                Frame.Navigate(typeof(MasterKeyDualityPage), new MasterKeyDualityArgs(info));
                return;
            }
            MergeWithoutDuality(info);
        }
        catch (FacadeException)
        {
            if (transferPassword is null)
            {
                // Most likely a transfer-encrypted packet — offer the
                // password prompt rather than immediately surfacing a
                // raw error (mirrors ImportPacketView.swift's tryImport).
                _pendingPacketBytes = packetBytes;
                PickingFileStep.Visibility = Visibility.Collapsed;
                TransferPasswordStep.Visibility = Visibility.Visible;
            }
            else
            {
                ShowError("Import failed — check the transfer passphrase and try again.");
            }
        }
        finally
        {
            BusyRing.IsActive = false;
            IsHitTestVisible = true;
        }
    }

    /// No embedded master key to decide about — just merge the incoming
    /// keys into the compartment this page was opened for (spec §5.3's
    /// duality screen only concerns an *included* master key).
    private void MergeWithoutDuality(ImportedPacketInfo info)
    {
        var outcome = ManagementClient.MergeReencryptDiscardIncoming(_compartmentId, info.manifestJson, info.keyBlobs);
        PickingFileStep.Visibility = Visibility.Collapsed;
        TransferPasswordStep.Visibility = Visibility.Collapsed;
        DoneStep.Visibility = Visibility.Visible;
        if (outcome.warnings.Length > 0)
        {
            DoneWarningsText.Text = $"{outcome.warnings.Length} key(s) collided with existing entries and were kept side-by-side, renamed.";
            DoneWarningsText.Visibility = Visibility.Visible;
        }
    }

    private void ShowError(string message)
    {
        StatusBar.Message = message;
        StatusBar.IsOpen = true;
    }

    private void DoneButton_Click(object sender, RoutedEventArgs e)
    {
        Frame.Navigate(typeof(VaultHomePage));
        Frame.BackStack.Clear();
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => Frame.GoBack();
}
