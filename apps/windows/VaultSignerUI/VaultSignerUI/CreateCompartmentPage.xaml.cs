using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// A vault (spec §4.1) can hold multiple independently-passphrased
/// compartments — the "Keep both master keys side by side" import
/// option (spec §5.3 option 2) already created one this way, but there
/// was no standalone way to add one outside of importing something.
/// `internal.add_compartment`/`ManagementClient.AddCompartment` already
/// existed from an earlier session; this page is the first UI entry
/// point for it, added at the user's direct request ("the user may
/// have as many vaults [compartments] as they want"). Mirrors
/// WelcomePage's own Create Vault fields (label, passphrase, confirm,
/// device profile) since `AddCompartment`'s shape is `CreateVault`'s
/// minus the file path.
public sealed partial class CreateCompartmentPage : Page, ISensitiveScreen
{
    public CreateCompartmentPage()
    {
        InitializeComponent();
    }

    private void CreateButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            var label = LabelBox.Text.Trim();
            var passphrase = PassphraseBox.Password;
            if (label.Length == 0 || passphrase.Length == 0)
            {
                throw new FacadeException.Failed("A compartment name and master passphrase are required.");
            }
            if (passphrase != ConfirmPassphraseBox.Password)
            {
                throw new FacadeException.Failed("Passphrases don't match.");
            }
            ManagementClient.AddCompartment(label, passphrase, ProfilePicker.SelectedProfile);
            Frame.GoBack();
        });
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => Frame.GoBack();

    private void RunGuarded(Action action)
    {
        StatusBar.IsOpen = false;
        BusyRing.IsActive = true;
        CreateButton.IsEnabled = false;
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
            CreateButton.IsEnabled = true;
        }
    }
}
