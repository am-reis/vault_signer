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
            Label("backupmasterkey.title", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.orange)
            Text("backupmasterkey.warning_text")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("backupmasterkey.transfer_passphrase_field", text: $transferPassword)
            SecureField("backupmasterkey.confirm_field", text: $confirmPassword)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("common.cancel_button") { dismiss() }
                Button("backupmasterkey.backup_button") { chooseDestinationAndExport() }
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
        panel.title = String(localized: "backupmasterkey.panel_title")
        panel.nameFieldStringValue = "MasterKeyBackup.vltpack"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let password = transferPassword
        Task {
            guard let bytes = await state.exportPacket(keyIds: [], includeMasterKey: true, encryption: .oneTimeTransferPassword(password: password)) else {
                errorMessage = String(format: String(localized: "backupmasterkey.backup_failed_format"), state.errorMessage ?? "unknown error")
                state.clearError()
                return
            }
            do {
                try bytes.write(to: url, options: .atomic)
                dismiss()
            } catch {
                errorMessage = String(format: String(localized: "backupmasterkey.backup_failed_format"), "\(error)")
            }
        }
    }
}
