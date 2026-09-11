using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using uniffi.vaultcore;

namespace VaultSignerUI;

internal sealed record MasterKeyDualityArgs(ImportedPacketInfo Info);

/// Spec §5.3 steps 2-3: the unskippable master-key-duality screen, shown
/// only when the imported packet embeds a master key (spec §5.2.1).
/// Three distinct cards, no default pre-selected (each has its own
/// independent "Use This Option" action rather than a shared radio +
/// submit, so nothing is pre-selectable by construction), option 3
/// styled separately (warning color) from the neutral options 1-2,
/// exactly as spec §5.3 specifies. Screen-capture-blocked (§5.0).
/// Finishes the whole import flow itself (back to VaultHomePage) rather
/// than returning to ImportPacketPage — see that page's doc comment for
/// why. Mirrors apps/macos/VaultSigner/Sources/Views/MasterKeyDualityView.swift.
public sealed partial class MasterKeyDualityPage : Page, ISensitiveScreen
{
    /// The exact phrase spec §5.3 option 3 requires — enforced again
    /// server-side (vaultcore) regardless of what this page checks.
    private const string ReplaceConfirmationPhrase = "REPLACE MY MASTER KEY";

    private ImportedPacketInfo _info = null!;
    private CompartmentInfo[] _unlockedCompartments = [];

    public MasterKeyDualityPage()
    {
        InitializeComponent();
        HeaderText.Text = Strings.Get("duality.header");
        SubtitleText.Text = Strings.Get("duality.subtitle");
        Option1TitleText.Text = Strings.Get("duality.option1.title");
        RecommendedBadgeText.Text = Strings.Get("duality.recommended_badge");
        Option1DescriptionText.Text = Strings.Get("duality.option1.description");
        Option1NoCompartmentText.Text = Strings.Get("duality.option1.no_unlocked_compartment");
        Option1CompartmentCombo.Header = Strings.Get("duality.option1.merge_into_picker");
        Option1Button.Content = Strings.Get("duality.use_this_option_button");
        Option2TitleText.Text = Strings.Get("duality.option2.title");
        Option2DescriptionText.Text = Strings.Get("duality.option2.description");
        Option2LabelBox.PlaceholderText = Strings.Get("duality.option2.label_field");
        Option2PassphraseBox.PlaceholderText = Strings.Get("duality.option2.passphrase_field");
        Option2Button.Content = Strings.Get("duality.use_this_option_button");
        Option3TitleText.Text = Strings.Get("duality.option3.title");
        Option3DescriptionText.Text = Strings.Get("duality.option3.description");
        Option3NoCompartmentText.Text = Strings.Get("duality.option3.no_unlocked_compartment");
        Option3CompartmentCombo.Header = Strings.Get("duality.option3.replace_picker");
        Option3PassphraseBox.PlaceholderText = Strings.Get("duality.option3.passphrase_field");
        Option3ConfirmBox.PlaceholderText = Strings.Format("duality.option3.confirmation_field_format", ReplaceConfirmationPhrase);
        Option3Button.Content = Strings.Get("duality.use_this_option_button");
        CancelButtonElement.Content = Strings.Get("duality.cancel_button");
        CompleteTitleText.Text = Strings.Get("import.complete_title");
        DoneButtonElement.Content = Strings.Get("import.done_button");
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _info = ((MasterKeyDualityArgs)e.Parameter).Info;

        try
        {
            _unlockedCompartments = ManagementClient.ListCompartments().Where(c => c.unlocked).ToArray();
        }
        catch (FacadeException)
        {
            _unlockedCompartments = [];
        }

        var hasUnlocked = _unlockedCompartments.Length > 0;
        Option1Form.Visibility = hasUnlocked ? Visibility.Visible : Visibility.Collapsed;
        Option1NoCompartmentText.Visibility = hasUnlocked ? Visibility.Collapsed : Visibility.Visible;
        Option3Form.Visibility = hasUnlocked ? Visibility.Visible : Visibility.Collapsed;
        Option3NoCompartmentText.Visibility = hasUnlocked ? Visibility.Collapsed : Visibility.Visible;
        Option1CompartmentCombo.ItemsSource = _unlockedCompartments;
        Option1CompartmentCombo.SelectedIndex = hasUnlocked ? 0 : -1;
        Option3CompartmentCombo.ItemsSource = _unlockedCompartments;
        Option3CompartmentCombo.SelectedIndex = hasUnlocked ? 0 : -1;
    }

    private void Option1Button_Click(object sender, RoutedEventArgs e)
    {
        if (Option1CompartmentCombo.SelectedItem is not CompartmentInfo target) return;
        RunGuarded(() =>
        {
            var outcome = ManagementClient.MergeReencryptDiscardIncoming(target.compartmentId, _info.manifestJson, _info.keyBlobs);
            ShowDone(outcome.warnings.Length);
        });
    }

    private void Option2Button_Click(object sender, RoutedEventArgs e)
    {
        var label = Option2LabelBox.Text.Trim();
        var passphrase = Option2PassphraseBox.Password;
        if (label.Length == 0 || passphrase.Length == 0)
        {
            ShowError("A compartment name and passphrase are required.");
            return;
        }
        RunGuarded(() =>
        {
            var outcome = ManagementClient.MergeSideBySide(_info.manifestJson, _info.keyBlobs, label, passphrase, FacadeDeviceProfile.Desktop);
            ShowDone(outcome.warnings.Length);
        });
    }

    private void Option3ConfirmBox_TextChanged(object sender, Microsoft.UI.Xaml.Controls.TextChangedEventArgs e) => UpdateOption3ButtonEnabled();
    private void Option3PassphraseBox_PasswordChanged(object sender, RoutedEventArgs e) => UpdateOption3ButtonEnabled();

    private void UpdateOption3ButtonEnabled()
    {
        Option3Button.IsEnabled = Option3ConfirmBox.Text == ReplaceConfirmationPhrase && Option3PassphraseBox.Password.Length > 0;
    }

    private void Option3Button_Click(object sender, RoutedEventArgs e)
    {
        if (Option3CompartmentCombo.SelectedItem is not CompartmentInfo target) return;
        if (_info.embeddedMasterKdfParamsJson is not { } kdfParamsJson) return;
        var passphrase = Option3PassphraseBox.Password;
        if (passphrase.Length == 0 || Option3ConfirmBox.Text != ReplaceConfirmationPhrase) return;
        RunGuarded(() =>
        {
            var outcome = ManagementClient.MergeReplaceLocalWithIncoming(
                target.compartmentId, _info.manifestJson, _info.keyBlobs, passphrase, kdfParamsJson, Option3ConfirmBox.Text);
            ShowDone(outcome.warnings.Length);
        });
    }

    private void ShowDone(int warningCount)
    {
        DecisionScroll.Visibility = Visibility.Collapsed;
        DoneStep.Visibility = Visibility.Visible;
        if (warningCount > 0)
        {
            DoneWarningsText.Text = $"{warningCount} key(s) collided with existing entries and were kept side-by-side, renamed.";
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

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        Frame.Navigate(typeof(VaultHomePage));
        Frame.BackStack.Clear();
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
            ShowError(ex.Message);
        }
        finally
        {
            BusyRing.IsActive = false;
            IsHitTestVisible = true;
        }
    }
}
