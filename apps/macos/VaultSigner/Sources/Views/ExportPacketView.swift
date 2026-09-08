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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(forceIncludeMasterKey && lockSelectionToAllKeys ? "Back Up" : "Export Keys").font(.title2.bold())

            if !lockSelectionToAllKeys {
                List(state.keys, id: \.keyId, selection: $selectedKeyIds) { key in
                    Text(key.label)
                }
                .frame(height: 160)
            }

            if !forceIncludeMasterKey {
                Toggle("Include master key in export", isOn: $includeMasterKey)
                Text("Lets the recipient treat this as carrying its own master key (spec §5.2.1) instead of just independently-passphrased keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Protect this export with:").font(.headline)
            encryptionChoiceCards

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") { chooseDestinationAndExport() }
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
            encryptionCard(.asIs, title: "Just package the keys as-is") {
                Text("Keys stay encrypted with their own passphrases; no extra layer is added. **The label, description, and resource for each key travel in the clear inside this file.** Only use this if the recipient already knows each key's passphrase and the transport channel itself is trusted.")
            }
            encryptionCard(.destinationMasterPassword, title: "Re-encrypt for the destination vault's master password") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose this only if you know the master password of the vault you're importing into.")
                    if encryptionChoice == .destinationMasterPassword {
                        SecureField("Destination vault's master passphrase", text: $destinationPassword)
                    }
                }
            }
            encryptionCard(.oneTimeTransferPassword, title: "Protect with a one-time transfer password") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set a new passphrase for this export only. Deliver it to the recipient through a separate channel from the file itself.")
                    if encryptionChoice == .oneTimeTransferPassword {
                        SecureField("Transfer passphrase", text: $transferPassword)
                        SecureField("Confirm transfer passphrase", text: $confirmTransferPassword)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func encryptionCard(_ choice: EncryptionChoice, title: String, @ViewBuilder detail: () -> some View) -> some View {
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
        panel.title = "Export Packet"
        panel.nameFieldStringValue = "Export.vltpack"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let keyIds = Array(selectedKeyIds)
        Task {
            guard let bytes = await state.exportPacket(keyIds: keyIds, includeMasterKey: includeMasterKey, encryption: encryption) else {
                errorMessage = "Export failed: \(state.errorMessage ?? "unknown error")"
                state.clearError()
                return
            }
            do {
                try bytes.write(to: url, options: .atomic)
                dismiss()
            } catch {
                errorMessage = "Export failed: \(error)"
            }
        }
    }
}
