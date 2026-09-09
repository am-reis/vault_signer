using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Standalone create-key screen, navigated to from VaultHomePage with
/// the target compartment's id as the nav parameter. Mirrors
/// apps/macos/VaultSigner/Sources/CreateKeyView.swift's role.
public sealed partial class CreateKeyPage : Page
{
    private string _compartmentId = "";

    public CreateKeyPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _compartmentId = (string)e.Parameter;
    }

    private void CreateButton_Click(object sender, RoutedEventArgs e)
    {
        RunGuarded(() =>
        {
            var label = LabelBox.Text.Trim();
            var passphrase = PassphraseBox.Password;
            if (label.Length == 0 || passphrase.Length == 0)
            {
                throw new FacadeException.Failed("Label and key passphrase are required.");
            }
            var keyType = KeyTypeCombo.SelectedIndex == 1 ? FacadeKeyType.EcdsaP256 : FacadeKeyType.Ed25519;
            var purpose = PurposeCombo.SelectedIndex switch
            {
                0 => FacadePurpose.Fido2,
                2 => FacadePurpose.Both,
                _ => FacadePurpose.CustomSigning,
            };
            ManagementClient.CreateKey(
                _compartmentId, keyType, purpose, label,
                DescriptionBox.Text.Trim(), ResourceBox.Text.Trim(), [], passphrase);
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
