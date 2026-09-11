using Microsoft.UI.Xaml.Controls;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// Shared by WelcomePage (create vault) and CreateCompartmentPage (add
/// compartment) — both call vaultcore with a `FacadeDeviceProfile`
/// (spec §4.2's per-device Argon2id benchmark target), so this exists
/// once rather than duplicating the same two-option picker and its
/// explanatory copy in both places.
public sealed partial class DeviceProfilePicker : UserControl
{
    public DeviceProfilePicker()
    {
        InitializeComponent();
        DeviceProfileLabelText.Text = Strings.Get("createvault.device_profile_label");
        DesktopRadio.Content = Strings.Get("createvault.profile_desktop");
        MobileRadio.Content = Strings.Get("createvault.profile_mobile");
        ExplanationText.Text = Strings.Get("createvault.device_profile_explanation");
    }

    internal FacadeDeviceProfile SelectedProfile =>
        ProfileRadios.SelectedIndex == 1 ? FacadeDeviceProfile.Mobile : FacadeDeviceProfile.Desktop;
}
