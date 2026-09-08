import SwiftUI
import AppKit

/// Spec §5.3's import flow. Step 1 (decrypt the transfer layer) and the
/// unskippable master-key-duality screen (step 2-3, shown only when the
/// packet actually embeds a master key) are both here; the merge
/// decision itself is `vaultcore::merge`'s job via `Vault.merge_*`.
/// Screen-capture-blocked throughout (§5.0: passphrase entry, import
/// decision screens are explicitly named in spec §5.0's list).
struct ImportPacketView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case pickingFile
        case needsTransferPassword(packetBytes: Data)
        case duality(info: ImportedPacketInfo)
        case done(warnings: [DuplicateWarningInfo])
    }

    @State private var step: Step = .pickingFile
    @State private var errorMessage: String?

    var body: some View {
        Group {
            switch step {
            case .pickingFile:
                pickingFileView
            case .needsTransferPassword(let packetBytes):
                TransferPasswordView(
                    onCancel: { dismiss() },
                    onSubmit: { password in tryImport(packetBytes, transferPassword: password) }
                )
            case .duality(let info):
                MasterKeyDualityView(info: info, onCancel: { dismiss() }, onCompleted: { warnings in step = .done(warnings: warnings) })
            case .done(let warnings):
                doneView(warnings: warnings)
            }
        }
        .preventsScreenCapture()
    }

    private var pickingFileView: some View {
        VStack(spacing: 16) {
            Text("import.title").font(.title2.bold())
            Text("import.subtitle").foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("import.cancel_button") { dismiss() }
                Button("import.choose_file_button") { pickFile() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 380)
    }

    private func doneView(warnings: [DuplicateWarningInfo]) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            Text("import.complete_title").font(.title2.bold())
            if !warnings.isEmpty {
                // Not yet migrated to the ICU plural-aware form (spec §9
                // scaffolding covers the static strings around it first
                // — see i18n/README.md).
                Text("\(warnings.count) key(s) collided with existing entries and were kept side-by-side, renamed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("import.done_button") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(width: 380)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "import.title")
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        tryImport(data, transferPassword: nil)
    }

    private func tryImport(_ packetBytes: Data, transferPassword: String?) {
        Task {
            guard let info = await state.importPacket(packetBytes: packetBytes, transferPassword: transferPassword) else {
                if transferPassword == nil {
                    // Most likely a transfer-encrypted packet — offer the password prompt
                    // rather than immediately surfacing a raw error.
                    state.clearError()
                    step = .needsTransferPassword(packetBytes: packetBytes)
                } else {
                    errorMessage = "Import failed: \(state.errorMessage ?? "unknown error")"
                    state.clearError()
                    step = .pickingFile
                }
                return
            }
            if info.embeddedMasterCompartmentId != nil {
                step = .duality(info: info)
            } else {
                await mergeWithoutDuality(info: info)
            }
        }
    }

    /// No embedded master key to decide about — just merge the incoming
    /// keys into whichever compartment is currently unlocked (spec
    /// §5.3's duality screen only concerns an *included* master key).
    private func mergeWithoutDuality(info: ImportedPacketInfo) async {
        guard let compartmentId = state.unlockedCompartmentId else { return }
        guard let outcome = await state.mergeReencryptDiscardIncoming(targetCompartmentId: compartmentId, incomingManifestJson: info.manifestJson, incomingKeyBlobs: info.keyBlobs)
        else {
            errorMessage = "Import failed: \(state.errorMessage ?? "unknown error")"
            state.clearError()
            step = .pickingFile
            return
        }
        state.refreshKeys()
        step = .done(warnings: outcome.warnings)
    }
}

private struct TransferPasswordView: View {
    let onCancel: () -> Void
    let onSubmit: (String) -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("import.transfer_password_prompt").font(.headline)
            SecureField("import.transfer_password_field", text: $password)
            HStack {
                Spacer()
                Button("import.cancel_button") { onCancel() }
                Button("import.continue_button") { onSubmit(password) }.buttonStyle(.borderedProminent).disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
