using Microsoft.UI.Xaml;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace VaultSignerUI;

/// Native folder/file pickers for choosing a vault location, mirroring
/// macOS's `NSOpenPanel`/`NSSavePanel` usage in WelcomeView/CreateVaultView/
/// ImportPacketView/ExportPacketView/ManageVaultsView. This app is
/// unpackaged (see VaultSignerUI.csproj's `WindowsAppSDKSelfContained`
/// note), so every picker needs explicit HWND association via
/// `InitializeWithWindow` — WinRT's pickers otherwise fail to activate
/// at all outside a packaged app's identity.
internal static class FilePickers
{
    /// Vault files have no enforced/registered extension (spec §4.1
    /// describes `.vlt` as a convention, not a registered file type),
    /// so every picker below accepts any file — matching macOS's own
    /// `allowedContentTypes = []` / `allowsOtherFileTypes = true`.
    private static void AllowAnyFile(FileOpenPicker picker) => picker.FileTypeFilter.Add("*");

    /// FileSavePicker requires at least one choice; a single "." entry
    /// is the documented way to mean "no enforced extension" — the
    /// caller (e.g. `PickVaultCreationLocationAsync`) still supplies
    /// its own default extension via `SuggestedFileName`.
    private static void AllowAnyFile(FileSavePicker picker) => picker.FileTypeChoices.Add("All files", [".vlt"]);

    /// Create Vault: the user picks a *folder*, then types only a file
    /// name (per the user's own request — no full path typing). Returns
    /// the full path to the not-yet-existing vault file, or null if
    /// cancelled.
    public static async Task<string?> PickVaultCreationFolderAsync(Window window)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.Desktop };
        picker.FileTypeFilter.Add("*"); // required even for folder pickers, or activation throws.
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    /// Open Vault / "add a known vault without opening it" / Import:
    /// pick an existing file. Returns its full path, or null if cancelled.
    public static async Task<string?> PickExistingFileAsync(Window window)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Desktop };
        AllowAnyFile(picker);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        var file = await picker.PickSingleFileAsync();
        return file?.Path;
    }

    /// Export / Backup: pick a destination to save a new file. Returns
    /// the chosen full path, or null if cancelled. Does not write
    /// anything — the caller writes the packet bytes there itself.
    public static async Task<string?> PickSaveDestinationAsync(Window window, string suggestedName)
    {
        var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.Desktop, SuggestedFileName = suggestedName };
        AllowAnyFile(picker);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        var file = await picker.PickSaveFileAsync();
        return file?.Path;
    }
}
