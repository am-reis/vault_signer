using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace VaultSignerUI;

/// Spec §5.6's dedicated management screen: "reachable both from the
/// entry screen and from the app's settings, so it doesn't require
/// closing whatever vault is currently open." Reachable from both
/// WelcomePage and SettingsPage. Operates purely on
/// `KnownVaultsStore` — never touches whatever vault the agent
/// currently has open, which is what makes it safe to add a second
/// entry point later without new plumbing. Mirrors
/// apps/macos/VaultSigner/Sources/Views/ManageVaultsView.swift.
public sealed partial class ManageVaultsPage : Page
{
    public ManageVaultsPage()
    {
        InitializeComponent();
        BackButtonElement.Content = Strings.Get("nav.back_button");
        TitleText.Text = Strings.Get("manage_vaults.title");
        SubtitleText.Text = Strings.Get("manage_vaults.subtitle");
        NoVaultsText.Text = Strings.Get("manage_vaults.no_vaults");
        AddButton.Content = Strings.Get("manage_vaults.add_button");
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Refresh();
    }

    private void Refresh()
    {
        var rows = KnownVaultsStore.Load().Select(entry => new KnownVaultRow(entry)).ToArray();
        VaultsList.ItemsSource = rows;
        NoVaultsText.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        VaultsList.Visibility = rows.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ForgetButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string path }) return;
        KnownVaultsStore.Forget(path);
        Refresh();
    }

    private async void AddButton_Click(object sender, RoutedEventArgs e)
    {
        var path = await FilePickers.PickExistingFileAsync(App.MainWindow);
        if (path is null) return;
        KnownVaultsStore.AddWithoutOpening(path);
        Refresh();
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => Frame.GoBack();
}
