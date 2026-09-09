using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// A small display wrapper around the real generated `KeyInfo`, so the
/// XAML `ListView` can `x:Bind` to plain string properties without
/// fighting `KeyInfo`'s uniffi-generated (camelCase, non-observable)
/// record shape directly.
internal sealed class KeyRow(KeyInfo info)
{
    public KeyInfo Info { get; } = info;
    public string Label => Info.label;
    public string TypeAndPurpose => $"{Info.keyType} / {Info.purpose}";
}

/// The whole app in one page rather than macOS's four separate screens
/// (Welcome/create-open, key list, create key, key detail) — a
/// deliberate scoping choice for this first real build, not a design
/// decision: every flow is here and functional, just laid out as
/// sections on one scrollable page instead of navigated between. Splitting
/// into real pages later is a refactor, not new functionality.
///
/// Every state-changing action goes through `ManagementClient`, never
/// touches a `Vault` directly (spec §8) — mirrors
/// apps/macos/VaultSigner/Sources/AppState.swift's role, collapsed into
/// this page's code-behind rather than a separate observable state
/// object, since WinUI's `x:Bind`/event model doesn't need SwiftUI's
/// `@Published` pattern to stay responsive.
public sealed partial class MainPage : Page
{
    private CompartmentInfo[] _compartments = [];
    private CompartmentInfo? SelectedCompartment =>
        CompartmentCombo.SelectedItem as CompartmentInfo;

    public MainPage()
    {
        InitializeComponent();
        Loaded += MainPage_Loaded;
    }

    private void MainPage_Loaded(object sender, RoutedEventArgs e)
    {
        // VaultSignerAgent may already have a vault open (it loads
        // VaultConfig's saved path at its own startup) — check rather
        // than assuming NoVaultPanel is always the right start state.
        try
        {
            _compartments = ManagementClient.ListCompartments();
            ShowVaultOpen();
            RefreshCompartmentCombo();
        }
        catch (FacadeException)
        {
            ShowNoVault();
        }
    }

    // MARK: - Vault lifecycle

    private void CreateVaultButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            var path = VaultPathBox.Text.Trim();
            var label = CompartmentLabelBox.Text.Trim();
            var passphrase = MasterPassphraseBox.Password;
            if (path.Length == 0 || label.Length == 0 || passphrase.Length == 0)
            {
                throw new FacadeException.Failed("vault path, compartment label and master passphrase are all required");
            }
            _compartments = ManagementClient.CreateVault(path, label, passphrase, FacadeDeviceProfile.Desktop);
            ShowVaultOpen();
            RefreshCompartmentCombo();
        });
    }

    private void OpenVaultButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            var path = VaultPathBox.Text.Trim();
            if (path.Length == 0) throw new FacadeException.Failed("vault path is required");
            ManagementClient.OpenVault(path);
            _compartments = ManagementClient.ListCompartments();
            ShowVaultOpen();
            RefreshCompartmentCombo();
        });
    }

    private void LockAllButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            ManagementClient.LockAll();
            _compartments = ManagementClient.ListCompartments();
            RefreshCompartmentCombo();
            KeysList.ItemsSource = null;
            HideKeyDetail();
        });
    }

    // MARK: - Compartments

    private void RefreshCompartmentCombo()
    {
        var previouslySelectedId = SelectedCompartment?.compartmentId;
        CompartmentCombo.ItemsSource = _compartments;
        var toReselect = _compartments.FirstOrDefault(c => c.compartmentId == previouslySelectedId) ?? _compartments.FirstOrDefault();
        CompartmentCombo.SelectedItem = toReselect;
    }

    private void CompartmentCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        HideKeyDetail();
        if (SelectedCompartment is not { } compartment)
        {
            KeysList.ItemsSource = null;
            UnlockPanel.Visibility = Visibility.Collapsed;
            return;
        }
        if (!compartment.unlocked)
        {
            UnlockPanel.Visibility = Visibility.Visible;
            KeysList.ItemsSource = null;
            return;
        }
        UnlockPanel.Visibility = Visibility.Collapsed;
        RefreshKeys(compartment.compartmentId);
    }

    private void UnlockButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            if (SelectedCompartment is not { } compartment) return;
            var passphrase = UnlockPassphraseBox.Password;
            ManagementClient.UnlockCompartment(compartment.compartmentId, passphrase);
            UnlockPassphraseBox.Password = "";
            _compartments = ManagementClient.ListCompartments();
            RefreshCompartmentCombo();
        });
    }

    // MARK: - Keys

    private void RefreshKeys(string compartmentId)
    {
        var keys = ManagementClient.ListKeys(compartmentId);
        KeysList.ItemsSource = keys.Select(k => new KeyRow(k)).ToArray();
    }

    private void KeysList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (KeysList.SelectedItem is not KeyRow row)
        {
            HideKeyDetail();
            return;
        }
        var info = row.Info;
        DetailLabel.Text = info.label;
        DetailDescription.Text = info.description;
        DetailResource.Text = $"Resource: {info.resource}";
        DetailCreatedAt.Text = $"Created: {info.createdAt}" + (info.lastUsedAt is { } last ? $" · Last used: {last}" : "");
        DetailPublicKeyHex.Text = info.publicKeyHex;
        DiscardConfirmBox.Text = "";
        KeyDetailPanel.Visibility = Visibility.Visible;
    }

    private void HideKeyDetail()
    {
        KeyDetailPanel.Visibility = Visibility.Collapsed;
        KeysList.SelectedItem = null;
    }

    private void CreateKeyButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            if (SelectedCompartment is not { unlocked: true } compartment)
            {
                throw new FacadeException.Failed("unlock a compartment first");
            }
            var label = NewKeyLabelBox.Text.Trim();
            var passphrase = NewKeyPassphraseBox.Password;
            if (label.Length == 0 || passphrase.Length == 0)
            {
                throw new FacadeException.Failed("key label and passphrase are required");
            }
            var keyType = NewKeyTypeCombo.SelectedIndex == 1 ? FacadeKeyType.EcdsaP256 : FacadeKeyType.Ed25519;
            var purpose = NewKeyPurposeCombo.SelectedIndex switch
            {
                0 => FacadePurpose.Fido2,
                2 => FacadePurpose.Both,
                _ => FacadePurpose.CustomSigning,
            };
            ManagementClient.CreateKey(
                compartment.compartmentId, keyType, purpose, label,
                NewKeyDescriptionBox.Text.Trim(), NewKeyResourceBox.Text.Trim(), [], passphrase);
            NewKeyLabelBox.Text = "";
            NewKeyDescriptionBox.Text = "";
            NewKeyResourceBox.Text = "";
            NewKeyPassphraseBox.Password = "";
            RefreshKeys(compartment.compartmentId);
        });
    }

    private void DiscardKeyButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            if (SelectedCompartment is not { } compartment || KeysList.SelectedItem is not KeyRow row) return;
            ManagementClient.DiscardKey(compartment.compartmentId, row.Info.keyId, DiscardConfirmBox.Text.Trim());
            HideKeyDetail();
            RefreshKeys(compartment.compartmentId);
        });
    }

    // MARK: - Panel visibility / error surfacing

    private void ShowNoVault()
    {
        NoVaultPanel.Visibility = Visibility.Visible;
        VaultOpenPanel.Visibility = Visibility.Collapsed;
    }

    private void ShowVaultOpen()
    {
        NoVaultPanel.Visibility = Visibility.Collapsed;
        VaultOpenPanel.Visibility = Visibility.Visible;
    }

    private void RunGuarded(Action action)
    {
        try
        {
            action();
            StatusText.Visibility = Visibility.Collapsed;
        }
        catch (FacadeException ex)
        {
            StatusText.Text = ex.Message;
            StatusText.Visibility = Visibility.Visible;
        }
    }
}
