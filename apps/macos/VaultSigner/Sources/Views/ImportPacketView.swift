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
            Text("Import Packet").font(.title2.bold())
            Text("Choose a .vltkey or .vltpack file.").foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Button("Choose File…") { pickFile() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 380)
    }

    private func doneView(warnings: [DuplicateWarningInfo]) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            Text("Import Complete").font(.title2.bold())
            if !warnings.isEmpty {
                Text("\(warnings.count) key(s) collided with existing entries and were kept side-by-side, renamed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(width: 380)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Packet"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        tryImport(data, transferPassword: nil)
    }

    private func tryImport(_ packetBytes: Data, transferPassword: String?) {
        guard let vault = state.vault else { return }
        Task {
            do {
                let info = try await Task.detached(priority: .userInitiated) {
                    try vault.importPacket(packetBytes: packetBytes, transferPassword: transferPassword)
                }.value
                if info.embeddedMasterCompartmentId != nil {
                    step = .duality(info: info)
                } else {
                    await mergeWithoutDuality(info: info)
                }
            } catch {
                if transferPassword == nil {
                    // Most likely a transfer-encrypted packet — offer the password prompt
                    // rather than immediately surfacing a raw error.
                    step = .needsTransferPassword(packetBytes: packetBytes)
                } else {
                    errorMessage = "Import failed: \(error)"
                    step = .pickingFile
                }
            }
        }
    }

    /// No embedded master key to decide about — just merge the incoming
    /// keys into whichever compartment is currently unlocked (spec
    /// §5.3's duality screen only concerns an *included* master key).
    private func mergeWithoutDuality(info: ImportedPacketInfo) async {
        guard let vault = state.vault, let compartmentId = state.unlockedCompartmentId else { return }
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try vault.mergeReencryptDiscardIncoming(targetCompartmentId: compartmentId, incomingManifestJson: info.manifestJson, incomingKeyBlobs: info.keyBlobs)
            }.value
            state.refreshKeys()
            step = .done(warnings: outcome.warnings)
        } catch {
            errorMessage = "Import failed: \(error)"
            step = .pickingFile
        }
    }
}

private struct TransferPasswordView: View {
    let onCancel: () -> Void
    let onSubmit: (String) -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This packet is protected by a transfer password.").font(.headline)
            SecureField("Transfer passphrase", text: $password)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Continue") { onSubmit(password) }.buttonStyle(.borderedProminent).disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
