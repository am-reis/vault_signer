using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Display wrapper for one `KnownVaultEntry` row on the welcome screen
/// (spec §5.6: "most-recently-opened first ... each entry openable with
/// one action"). `x:Bind` needs concrete Brush/Visibility properties,
/// not raw booleans, hence computing them here rather than in XAML.
internal sealed class KnownVaultRow(KnownVaultEntry entry)
{
    public string Path => entry.Path;
    public string FileName => System.IO.Path.GetFileName(entry.Path);
    public bool Available { get; } = File.Exists(entry.Path);
    public Visibility UnavailableVisibility => Available ? Visibility.Collapsed : Visibility.Visible;
    public Brush ForegroundBrush => (Brush)Application.Current.Resources[
        Available ? "TextFillColorPrimaryBrush" : "TextFillColorDisabledBrush"];
    public string UnavailableTooltip => Strings.Get("welcome.vault_unavailable_tooltip");
    public string ForgetTooltip => Strings.Get("welcome.forget_tooltip");
    public string ForgetButtonLabel => Strings.Get("welcome.forget_button");
}

/// First screen of the real, navigated flow (see MainWindow.xaml's
/// `RootFrame` — this replaces the old single-scrolling-page approach,
/// same functionality, real per-screen navigation). Mirrors
/// apps/macos/VaultSigner/Sources/WelcomeView.swift's role, including
/// the known-vaults list (spec §5.6) merged in rather than kept as a
/// separate screen, and apps/macos/VaultSigner/Sources/Views/CreateVaultView.swift's
/// folder-then-filename picker flow (rather than a raw path text box)
/// per explicit user request this session.
public sealed partial class WelcomePage : Page, ISensitiveScreen
{
    private string? _createFolderPath;

    public WelcomePage()
    {
        InitializeComponent();
        SubtitleText.Text = Strings.Get("welcome.subtitle");
        RecentVaultsHeaderText.Text = Strings.Get("welcome.recent_vaults_header");
        ManageVaultsLinkButton.Content = Strings.Get("welcome.manage_vaults_button");
        NoRecentVaultsText.Text = Strings.Get("welcome.no_recent_vaults");
        CreateSectionHeaderText.Text = Strings.Get("welcome.create_section_header");
        CreateFolderText.Text = Strings.Get("welcome.no_folder_chosen");
        ChooseFolderButton.Content = Strings.Get("welcome.choose_folder_button");
        NewVaultFileNameBox.PlaceholderText = Strings.Get("welcome.filename_placeholder");
        CompartmentLabelBox.PlaceholderText = Strings.Get("welcome.compartment_name_placeholder");
        MasterPassphraseBox.PlaceholderText = Strings.Get("welcome.master_passphrase_placeholder");
        ConfirmPassphraseBox.PlaceholderText = Strings.Get("welcome.confirm_passphrase_placeholder");
        CreateVaultButton.Content = Strings.Get("welcome.create_vault_button");
        OpenSectionHeaderText.Text = Strings.Get("welcome.open_section_header");
        OpenVaultButton.Content = Strings.Get("welcome.open_button");
        Loaded += WelcomePage_Loaded;
    }

    private void WelcomePage_Loaded(object sender, RoutedEventArgs e)
    {
        RefreshKnownVaults();

        // VaultSignerAgent may already have a vault open (it loads
        // VaultConfig's saved path at its own startup) — skip straight
        // to VaultHomePage rather than showing this screen at all, and
        // drop this page from the back stack so "back" from there
        // can't return to a stale Welcome screen.
        //
        // Real bug found and fixed here (spec item 3.8's verification):
        // ManagementHandlers.ListCompartments does `Vault?.ListCompartments()
        // ?? []` agent-side, which never throws, even with no vault open
        // at all — it just returns an empty array. Checking only "did the
        // call throw" made this unconditionally true, so this page could
        // never actually be seen: a fresh install bounced straight to
        // VaultHomePage before a first vault could ever be created.
        // Checking the result is non-empty instead is a reliable proxy
        // for "a vault is genuinely open" — every vault has at least one
        // compartment by construction (CreateVault requires one), so a
        // real open vault can never legitimately report zero.
        try
        {
            var compartments = ManagementClient.ListCompartments();
            if (compartments.Length == 0) return;
            Frame.Navigate(typeof(VaultHomePage));
            Frame.BackStack.Clear();
        }
        catch (FacadeException)
        {
            // No vault open yet — this screen is the right one to show.
        }
    }

    private void RefreshKnownVaults()
    {
        var entries = KnownVaultsStore.Load();
        var rows = entries.Select(e => new KnownVaultRow(e)).ToArray();
        RecentVaultsList.ItemsSource = rows;
        NoRecentVaultsText.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        RecentVaultsList.Visibility = rows.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RecentVaultsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not KnownVaultRow row) return;
        if (!row.Available)
        {
            StatusBar.Message = $"\"{row.FileName}\" couldn't be found at its remembered location. Re-locate it via Browse, or forget it below.";
            StatusBar.IsOpen = true;
            return;
        }
        OpenVaultAtPath(row.Path);
    }

    private void ForgetButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string path }) return;
        KnownVaultsStore.Forget(path);
        RefreshKnownVaults();
    }

    private void ManageVaultsLink_Click(object sender, RoutedEventArgs e) => Frame.Navigate(typeof(ManageVaultsPage));

    private async void ChooseFolderButton_Click(object sender, RoutedEventArgs e)
    {
        var folder = await FilePickers.PickVaultCreationFolderAsync(App.MainWindow);
        if (folder is null) return;
        _createFolderPath = folder;
        CreateFolderText.Text = folder;
        CreateFolderText.Opacity = 1;
    }

    private void CreateVaultButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            if (_createFolderPath is null) throw new FacadeException.Failed("Choose a folder first.");
            var fileName = NewVaultFileNameBox.Text.Trim();
            var label = CompartmentLabelBox.Text.Trim();
            var passphrase = MasterPassphraseBox.Password;
            if (fileName.Length == 0 || label.Length == 0 || passphrase.Length == 0)
            {
                throw new FacadeException.Failed("A file name, compartment name and master passphrase are all required.");
            }
            if (passphrase != ConfirmPassphraseBox.Password)
            {
                throw new FacadeException.Failed("Passphrases don't match.");
            }
            var path = System.IO.Path.Combine(_createFolderPath, fileName);
            ManagementClient.CreateVault(path, label, passphrase, ProfilePicker.SelectedProfile);
            KnownVaultsStore.RecordOpened(path);
            Frame.Navigate(typeof(VaultHomePage));
            Frame.BackStack.Clear();
        });
    }

    private async void OpenVaultButton_Click(object sender, RoutedEventArgs e)
    {
        var path = await FilePickers.PickExistingFileAsync(App.MainWindow);
        if (path is null) return;
        OpenVaultAtPath(path);
    }

    private void OpenVaultAtPath(string path)
    {
        RunGuarded(() =>
        {
            ManagementClient.OpenVault(path);
            KnownVaultsStore.RecordOpened(path);
            Frame.Navigate(typeof(VaultHomePage));
            Frame.BackStack.Clear();
        });
    }

    private void RunGuarded(Action action)
    {
        StatusBar.IsOpen = false;
        BusyRing.IsActive = true;
        IsHitTestVisible = false;
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
            IsHitTestVisible = true;
        }
    }
}
