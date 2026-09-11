using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
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

    /// Spec §5.1's "View list: label, resource, key type, purpose" —
    /// mirrors KeyListView.swift's "resource · type · purpose" row
    /// subtitle exactly, including its "no resource" fallback text
    /// (this was previously missing resource entirely).
    public string TypeAndPurpose =>
        $"{(Info.resource.Length > 0 ? Info.resource : Strings.Get("keylist.no_resource"))} · {KeyTypeLabel} · {PurposeLabel}";

    private string KeyTypeLabel => Info.keyType switch
    {
        FacadeKeyType.Ed25519 => Strings.Get("common.key_type_ed25519"),
        FacadeKeyType.EcdsaP256 => Strings.Get("common.key_type_ecdsa_p256"),
        _ => Info.keyType.ToString(),
    };

    private string PurposeLabel => Info.purpose switch
    {
        FacadePurpose.Fido2 => Strings.Get("common.purpose_fido2"),
        FacadePurpose.CustomSigning => Strings.Get("common.purpose_custom_signing"),
        FacadePurpose.Both => Strings.Get("common.purpose_both"),
        _ => Info.purpose.ToString(),
    };
}

/// Compartment picker + key list — the hub screen a user lands on and
/// returns to after creating or inspecting a key. Re-fetches
/// compartments/keys on every navigation *to* this page (`OnNavigatedTo`,
/// not just first load), including `Frame.GoBack()` returns from
/// CreateKeyPage/KeyDetailPage, so it never shows stale state after a
/// mutation on a subpage. Mirrors
/// apps/macos/VaultSigner/Sources/KeyListView.swift's role, merged with
/// the compartment-unlock step apps/macos keeps as its own UnlockView.
public sealed partial class VaultHomePage : Page, ISensitiveScreen
{
    private CompartmentInfo[] _compartments = [];
    private CompartmentInfo? SelectedCompartment =>
        CompartmentCombo.SelectedItem as CompartmentInfo;

    public VaultHomePage()
    {
        InitializeComponent();
        SwitchVaultLink.Content = Strings.Get("keylist.switch_vault_link");
        ToolTipService.SetToolTip(SettingsButton, Strings.Get("keylist.settings_button"));
        ToolTipService.SetToolTip(LockAllButton, Strings.Get("keylist.lock_all_tooltip"));
        LockAllText.Text = Strings.Get("keylist.lock_all_button");
        CompartmentLabelText.Text = Strings.Get("unlock.compartment_picker");
        NewCompartmentLinkButton.Content = Strings.Get("keylist.new_compartment_link");
        UnlockPassphraseBox.PlaceholderText = Strings.Get("unlock.master_passphrase_placeholder");
        UnlockButton.Content = Strings.Get("unlock.unlock_button");
        KeysHeaderText.Text = Strings.Get("keylist.default_title");
        NewKeyText.Text = Strings.Get("keylist.new_key_button");
        EmptyKeysText.Text = Strings.Get("keylist.no_keys_combined");
        ImportBackupHeaderText.Text = Strings.Get("keylist.import_backup_header");
        ImportButtonElement.Content = Strings.Get("keylist.import_button");
        ExportKeysButtonElement.Content = Strings.Get("keylist.export_keys_button");
        BackUpEverythingButtonElement.Content = Strings.Get("keylist.backup_everything_button");
        BackUpMasterKeyOnlyButtonElement.Content = Strings.Get("keylist.backup_master_only_button");
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        RunGuarded(() =>
        {
            _compartments = ManagementClient.ListCompartments();
            RefreshCompartmentCombo();
        });
    }

    private void RefreshCompartmentCombo()
    {
        var previouslySelectedId = SelectedCompartment?.compartmentId;
        CompartmentCombo.ItemsSource = _compartments;
        var toReselect = _compartments.FirstOrDefault(c => c.compartmentId == previouslySelectedId) ?? _compartments.FirstOrDefault();
        CompartmentCombo.SelectedItem = toReselect;
        // ComboBox only raises SelectionChanged on an actual change, so
        // force a refresh when reselecting the same compartment (e.g.
        // returning from CreateKeyPage) to pick up its new key list.
        if (toReselect is not null && toReselect.compartmentId == previouslySelectedId)
        {
            ShowCompartment(toReselect);
        }
    }

    private void CompartmentCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SelectedCompartment is { } compartment) ShowCompartment(compartment);
        else
        {
            UnlockPanel.Visibility = Visibility.Collapsed;
            KeysSection.Visibility = Visibility.Collapsed;
            VaultActionsSection.Visibility = Visibility.Collapsed;
        }
    }

    private void ShowCompartment(CompartmentInfo compartment)
    {
        if (!compartment.unlocked)
        {
            UnlockPanel.Visibility = Visibility.Visible;
            KeysSection.Visibility = Visibility.Collapsed;
            VaultActionsSection.Visibility = Visibility.Collapsed;
            return;
        }
        UnlockPanel.Visibility = Visibility.Collapsed;
        KeysSection.Visibility = Visibility.Visible;
        VaultActionsSection.Visibility = Visibility.Visible;
        RefreshKeys(compartment.compartmentId);
    }

    private void UnlockButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            if (SelectedCompartment is not { } compartment) return;
            var passphrase = UnlockPassphraseBox.Password;
            if (passphrase.Length == 0) throw new FacadeException.Failed("Enter the compartment's passphrase.");
            ManagementClient.UnlockCompartment(compartment.compartmentId, passphrase);
            UnlockPassphraseBox.Password = "";
            _compartments = ManagementClient.ListCompartments();
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
        });
    }

    private void RefreshKeys(string compartmentId)
    {
        var keys = ManagementClient.ListKeys(compartmentId);
        var rows = keys.Select(k => new KeyRow(k)).ToArray();
        KeysList.ItemsSource = rows;
        EmptyKeysText.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void NewKeyButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCompartment is not { } compartment) return;
        Frame.Navigate(typeof(CreateKeyPage), compartment.compartmentId);
    }

    private void KeysList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (SelectedCompartment is not { } compartment || e.ClickedItem is not KeyRow row) return;
        Frame.Navigate(typeof(KeyDetailPage), new KeyDetailNavArgs(compartment.compartmentId, row.Info));
    }

    private void NewCompartmentLink_Click(object sender, RoutedEventArgs e) => Frame.Navigate(typeof(CreateCompartmentPage));

    private void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCompartment is not { } compartment) return;
        Frame.Navigate(typeof(SettingsPage), new SettingsPageArgs(compartment.compartmentId, compartment.label));
    }

    private void SwitchVaultLink_Click(object sender, RoutedEventArgs e)
    {
        Frame.Navigate(typeof(WelcomePage));
        Frame.BackStack.Clear();
    }

    private void ImportButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCompartment is not { } compartment) return;
        Frame.Navigate(typeof(ImportPacketPage), compartment.compartmentId);
    }

    private void ExportKeysButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCompartment is not { } compartment) return;
        Frame.Navigate(typeof(ExportKeysPage), new ExportPageArgs(compartment.compartmentId, BackupMode: false));
    }

    private void BackUpEverythingButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCompartment is not { } compartment) return;
        Frame.Navigate(typeof(ExportKeysPage), new ExportPageArgs(compartment.compartmentId, BackupMode: true));
    }

    private void BackUpMasterKeyOnlyButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCompartment is not { } compartment) return;
        Frame.Navigate(typeof(BackupMasterKeyOnlyPage), compartment.compartmentId);
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
