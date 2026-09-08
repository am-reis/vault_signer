import SwiftUI
import AppKit

/// Spec §5.2's packet export flow: pick keys, decide whether to include
/// the master key (§5.2.1), then choose one of the three §5.2.2
/// transfer-encryption options — presented as three distinct cards, no
/// default pre-selected, matching spec §5.3's later duality screen in
/// spirit (a security-relevant choice like this shouldn't have a
/// pre-picked default). Screen-capture-blocked (§5.0: passphrase entry,
/// and the key list itself is manifest detail).
///
/// Also spec §5.4's backup flows: "back up everything" and "back up
/// master key only" are just this view pre-configured (see
/// `SettingsView`'s two backup buttons) — no separate implementation.
struct ExportPacketView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Pre-select every key and disable the per-key picker for a backup
    /// ("back up everything"/"back up master key only" always act on the
    /// whole compartment, not a hand-picked subset).
    var lockSelectionToAllKeys = false
    var forceIncludeMasterKey = false

    @State private var selectedKeyIds: Set<String> = []
    @State private var includeMasterKey = false
    @State private var encryptionChoice: EncryptionChoice?
    @State private var destinationPassword = ""
    @State private var transferPassword = ""
    @State private var confirmTransferPassword = ""
    @State private var errorMessage: String?

    private enum EncryptionChoice: Hashable {
        case asIs
        case destinationMasterPassword
        case oneTimeTransferPassword
    }

    private var titleKey: LocalizedStringKey {
        (forceIncludeMasterKey && lockSelectionToAllKeys) ? "exportpacket.title_backup" : "exportpacket.title_export"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleKey).font(.title2.bold())

            if !lockSelectionToAllKeys {
                List(state.keys, id: \.keyId, selection: $selectedKeyIds) { key in
                    Text(key.label)
                }
                .frame(height: 160)
            }

            if !forceIncludeMasterKey {
                Toggle("exportpacket.include_master_toggle", isOn: $includeMasterKey)
                Text("exportpacket.include_master_explanation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("exportpacket.protect_with_label").font(.headline)
            encryptionChoiceCards

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("common.cancel_button") { dismiss() }
                Button("exportpacket.export_button") { chooseDestinationAndExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport)
            }
        }
        .padding(24)
        .frame(width: 480)
        .preventsScreenCapture()
        .onAppear {
            if lockSelectionToAllKeys {
                selectedKeyIds = Set(state.keys.map(\.keyId))
                includeMasterKey = true
            }
        }
    }

    private var canExport: Bool {
        guard !(selectedKeyIds.isEmpty && !includeMasterKey) else { return false }
        switch encryptionChoice {
        case .none: return false
        case .asIs: return true
        case .destinationMasterPassword: return !destinationPassword.isEmpty
        case .oneTimeTransferPassword: return !transferPassword.isEmpty && transferPassword == confirmTransferPassword
        }
    }

    @ViewBuilder
    private var encryptionChoiceCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            encryptionCard(.asIs, title: "exportpacket.option_asis_title") {
                Text("exportpacket.option_asis_detail")
            }
            encryptionCard(.destinationMasterPassword, title: "exportpacket.option_destination_title") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("exportpacket.option_destination_detail")
                    if encryptionChoice == .destinationMasterPassword {
                        SecureField("exportpacket.option_destination_field", text: $destinationPassword)
                    }
                }
            }
            encryptionCard(.oneTimeTransferPassword, title: "exportpacket.option_transfer_title") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("exportpacket.option_transfer_detail")
                    if encryptionChoice == .oneTimeTransferPassword {
                        SecureField("exportpacket.transfer_passphrase_field", text: $transferPassword)
                        SecureField("exportpacket.confirm_transfer_field", text: $confirmTransferPassword)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func encryptionCard(_ choice: EncryptionChoice, title: LocalizedStringKey, @ViewBuilder detail: () -> some View) -> some View {
        Button { encryptionChoice = choice } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: encryptionChoice == choice ? "largecircle.fill.circle" : "circle")
                    Text(title).font(.subheadline.bold())
                }
                detail().font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func chooseDestinationAndExport() {
        guard state.unlockedCompartmentId != nil else { return }
        let encryption: FacadeExportEncryption
        switch encryptionChoice {
        case .asIs: encryption = .asIs
        case .destinationMasterPassword: encryption = .destinationMasterPassword(password: destinationPassword)
        case .oneTimeTransferPassword: encryption = .oneTimeTransferPassword(password: transferPassword)
        case .none: return
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "exportpacket.panel_title")
        panel.nameFieldStringValue = "Export.vltpack"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let keyIds = Array(selectedKeyIds)
        Task {
            guard let bytes = await state.exportPacket(keyIds: keyIds, includeMasterKey: includeMasterKey, encryption: encryption) else {
                errorMessage = String(format: String(localized: "exportpacket.export_failed_format"), state.errorMessage ?? "unknown error")
                state.clearError()
                return
            }
            do {
                try bytes.write(to: url, options: .atomic)
                dismiss()
            } catch {
                errorMessage = String(format: String(localized: "exportpacket.export_failed_format"), "\(error)")
            }
        }
    }
}
