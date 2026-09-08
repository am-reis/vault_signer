import SwiftUI
import AppKit

/// Spec §5.4's "back up master key only" shortcut: header + master key
/// blob only, no per-key blobs at all — `Vault.exportPacket` with no
/// `key_ids` and `includeMasterKey: true`. Deliberately a separate, much
/// smaller view than `ExportPacketView` rather than a mode flag on it:
/// there is no key list to show here, and the explicit warning that this
/// alone protects nothing is the whole point of this screen.
struct BackupMasterKeyOnlyView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var transferPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Back Up Master Key Only", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.orange)
            Text("This alone does NOT protect anything — your per-key blobs are also required to actually use any key. Store this only alongside a plan for recovering those separately (e.g. this vault file itself, backed up elsewhere).")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("One-time transfer passphrase", text: $transferPassword)
            SecureField("Confirm transfer passphrase", text: $confirmPassword)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Back Up…") { chooseDestinationAndExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(transferPassword.isEmpty || transferPassword != confirmPassword)
            }
        }
        .padding(24)
        .frame(width: 420)
        .preventsScreenCapture()
    }

    private func chooseDestinationAndExport() {
        guard state.unlockedCompartmentId != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up Master Key"
        panel.nameFieldStringValue = "MasterKeyBackup.vltpack"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let password = transferPassword
        Task {
            guard let bytes = await state.exportPacket(keyIds: [], includeMasterKey: true, encryption: .oneTimeTransferPassword(password: password)) else {
                errorMessage = "Backup failed: \(state.errorMessage ?? "unknown error")"
                state.clearError()
                return
            }
            do {
                try bytes.write(to: url, options: .atomic)
                dismiss()
            } catch {
                errorMessage = "Backup failed: \(error)"
            }
        }
    }
}
