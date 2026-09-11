using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Standalone create-key screen, navigated to from VaultHomePage with
/// the target compartment's id as the nav parameter. Mirrors
/// apps/macos/VaultSigner/Sources/CreateKeyView.swift's role.
public sealed partial class CreateKeyPage : Page, ISensitiveScreen
{
    private string _compartmentId = "";

    public CreateKeyPage()
    {
        InitializeComponent();
        BackButtonElement.Content = Strings.Get("nav.back_button");
        TitleText.Text = Strings.Get("createkey.title");
        LabelFieldText.Text = Strings.Get("createkey.label_field");
        LabelBox.PlaceholderText = Strings.Get("createkey.label_placeholder");
        DescriptionFieldText.Text = Strings.Get("createkey.description_label");
        DescriptionBox.PlaceholderText = Strings.Get("createkey.description_placeholder");
        ResourceFieldText.Text = Strings.Get("createkey.resource_label");
        ResourceBox.PlaceholderText = Strings.Get("createkey.resource_placeholder");
        TagsFieldText.Text = Strings.Get("createkey.tags_label");
        TagsBox.PlaceholderText = Strings.Get("createkey.tags_placeholder");
        KeyTypeFieldText.Text = Strings.Get("createkey.key_type_label");
        Ed25519Item.Content = Strings.Get("common.key_type_ed25519");
        EcdsaP256Item.Content = Strings.Get("common.key_type_ecdsa_p256");
        Fido2ExplanationText.Text = Strings.Get("createkey.fido2_explanation");
        PassphraseFieldText.Text = Strings.Get("createkey.passphrase_field");
        PassphraseBox.PlaceholderText = Strings.Get("createkey.passphrase_placeholder");
        ConfirmPassphraseBox.PlaceholderText = Strings.Get("createkey.confirm_passphrase_field");
        CreateButton.Content = Strings.Get("createkey.create_button");
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
            if (passphrase != ConfirmPassphraseBox.Password)
            {
                throw new FacadeException.Failed("Passphrases don't match.");
            }
            var keyType = KeyTypeCombo.SelectedIndex == 1 ? FacadeKeyType.EcdsaP256 : FacadeKeyType.Ed25519;
            // FIDO2/Both are deliberately not offered here — a bindable
            // passkey needs a real relying-party ceremony (rp_id/user
            // handle), which Vault.HandleFido2MakeCredential supplies
            // from the live CTAP2 request. This manual flow only ever
            // creates CustomSigning keys, matching CreateKeyView.swift.
            var purpose = FacadePurpose.CustomSigning;
            var tags = TagsBox.Text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            ManagementClient.CreateKey(
                _compartmentId, keyType, purpose, label,
                DescriptionBox.Text.Trim(), ResourceBox.Text.Trim(), tags, passphrase);
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
