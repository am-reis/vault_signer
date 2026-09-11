using System.Runtime.InteropServices;
using uniffi.vaultcore;

namespace VaultSignerAgent;

/// The agent's real implementation of vaultcore's `PassphrasePrompter`
/// foreign trait (spec §7: "every `sign` call triggers the same
/// password-prompt UI ... displaying the calling process's identity
/// before the passphrase field"). Mirrors
/// apps/macos/VaultSignerAgent/Sources/AlertPassphrasePrompter.swift's
/// role and screen-capture-blocking requirement (spec §5.0), using
/// `SetWindowDisplayAffinity` instead of `NSWindow.sharingType`.
///
/// Called from a named-pipe connection-handling thread, which is a
/// thread-pool (MTA) thread — WinForms dialogs need an STA thread with
/// their own modal message loop, so each call spins up a dedicated STA
/// thread, shows the dialog there, and blocks the caller until it
/// closes. This is correct here for the same reason the macOS version's
/// `DispatchQueue.main.sync` blocks: the calling app's `vaultsigner.sign`
/// request is supposed to block until the user answers the prompt.
internal sealed class WinFormsPassphrasePrompter : PassphrasePrompter
{
    // WDA_EXCLUDEFROMCAPTURE (0x11) — Windows 10 2004+. Falls back to
    // WDA_MONITOR (0x1, blacked-out-but-still-captured) on older builds
    // the OS itself refuses EXCLUDEFROMCAPTURE on; either way the
    // content is never in the clear in a captured frame.
    private const uint WDA_MONITOR = 0x00000001;
    private const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);

    public string? Prompt(string callerIdentity, string keyId)
    {
        string? result = null;
        var thread = new Thread(() =>
        {
            using var form = new PassphrasePromptForm(callerIdentity);
            form.Shown += (_, _) =>
            {
                if (!SetWindowDisplayAffinity(form.Handle, WDA_EXCLUDEFROMCAPTURE))
                {
                    SetWindowDisplayAffinity(form.Handle, WDA_MONITOR);
                }
            };
            result = form.ShowDialog() == DialogResult.OK ? form.Passphrase : null;
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        return result;
    }
}

/// The actual modal dialog: caller identity, a masked passphrase field,
/// Allow/Deny. Kept intentionally minimal — this is a security prompt,
/// not a place for extra chrome.
internal sealed class PassphrasePromptForm : Form
{
    private readonly TextBox _passphraseBox;

    public string Passphrase => _passphraseBox.Text;

    public PassphrasePromptForm(string callerIdentity)
    {
        Text = "VaultSigner";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;
        MaximizeBox = false;
        TopMost = true;
        ClientSize = new Size(360, 140);

        var messageLabel = new Label
        {
            Text = $"{callerIdentity} wants to sign with a VaultSigner key",
            AutoSize = false,
            Size = new Size(320, 40),
            Location = new Point(20, 15),
        };

        var hintLabel = new Label
        {
            Text = "Enter the passphrase for this key to allow it.",
            AutoSize = false,
            Size = new Size(320, 20),
            Location = new Point(20, 55),
        };

        _passphraseBox = new TextBox
        {
            UseSystemPasswordChar = true,
            Size = new Size(320, 24),
            Location = new Point(20, 78),
        };

        var allowButton = new Button
        {
            Text = "Allow",
            DialogResult = DialogResult.OK,
            Location = new Point(180, 110),
        };
        var denyButton = new Button
        {
            Text = "Deny",
            DialogResult = DialogResult.Cancel,
            Location = new Point(265, 110),
        };

        Controls.AddRange([messageLabel, hintLabel, _passphraseBox, allowButton, denyButton]);
        AcceptButton = allowButton;
        CancelButton = denyButton;
        ActiveControl = _passphraseBox;
    }
}
