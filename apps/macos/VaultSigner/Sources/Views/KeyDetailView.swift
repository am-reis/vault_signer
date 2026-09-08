import SwiftUI
import AppKit

/// §5.1 key detail: change-passphrase action, reveal-raw-key danger
/// zone, discard (two-step confirmation), and single-key export (§5.2's
/// `.vltkey`). Screen-capture-blocked (§5.0: manifest detail + raw-key
/// reveal + passphrase entry).
struct KeyDetailView: View {
    let key: KeyInfo
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showingChangePassphrase = false
    @State private var showingReveal = false
    @State private var showingDiscardConfirm = false
    @State private var exportErrorMessage: String?

    var body: some View {
        Form {
            Section("Details") {
                LabeledContent("Label", value: key.label)
                if !key.description.isEmpty { LabeledContent("Description", value: key.description) }
                if !key.resource.isEmpty { LabeledContent("Resource", value: key.resource) }
                LabeledContent("Public key", value: String(key.publicKeyHex.prefix(16)) + "…")
                LabeledContent("Created", value: key.createdAt)
                if !key.tags.isEmpty { LabeledContent("Tags", value: key.tags.joined(separator: ", ")) }
            }

            Section("Actions") {
                Button("Change Passphrase…") { showingChangePassphrase = true }
                Button("Reveal Raw Key…", role: .destructive) { showingReveal = true }
                Button("Export This Key…") { exportSingleKey() }
                if let exportErrorMessage {
                    Text(exportErrorMessage).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Button("Discard Key…", role: .destructive) { showingDiscardConfirm = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(key.label)
        .preventsScreenCapture()
        .sheet(isPresented: $showingChangePassphrase) {
            ChangePassphraseView(keyId: key.keyId).environmentObject(state)
        }
        .sheet(isPresented: $showingReveal) {
            RevealRawKeyView(keyId: key.keyId).environmentObject(state)
        }
        .sheet(isPresented: $showingDiscardConfirm) {
            DiscardKeyView(key: key) { dismiss() }.environmentObject(state)
        }
    }

    private func exportSingleKey() {
        guard state.unlockedCompartmentId != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Key"
        panel.nameFieldStringValue = "\(key.label).vltkey"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let bytes = await state.exportSingleKey(keyId: key.keyId) else {
                exportErrorMessage = "Export failed: \(state.errorMessage ?? "unknown error")"
                state.clearError()
                return
            }
            do {
                try bytes.write(to: url, options: .atomic)
                exportErrorMessage = nil
            } catch {
                exportErrorMessage = "Export failed: \(error)"
            }
        }
    }
}

private struct ChangePassphraseView: View {
    let keyId: String
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var oldPassphrase = ""
    @State private var newPassphrase = ""
    @State private var confirmPassphrase = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Key Passphrase").font(.title2.bold())
            SecureField("Current passphrase", text: $oldPassphrase)
            SecureField("New passphrase", text: $newPassphrase)
            SecureField("Confirm new passphrase", text: $confirmPassphrase)
            if failed { Text("Incorrect current passphrase").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Change") {
                    Task {
                        if await state.changeKeyPassphrase(keyId: keyId, oldPassphrase: oldPassphrase, newPassphrase: newPassphrase) {
                            dismiss()
                        } else {
                            failed = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(oldPassphrase.isEmpty || newPassphrase.isEmpty || newPassphrase != confirmPassphrase)
            }
        }
        .padding(24)
        .frame(width: 380)
        .preventsScreenCapture()
    }
}

private struct RevealRawKeyView: View {
    let keyId: String
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var revealed: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Danger Zone", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)
            Text("This reveals the raw private key. Anyone who sees it can act as this key. It will not be copied to the clipboard automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let revealed {
                Text(revealed)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                SecureField("Key passphrase", text: $passphrase)
                if failed { Text("Incorrect passphrase").font(.caption).foregroundStyle(.red) }
            }

            HStack {
                Spacer()
                Button(revealed == nil ? "Cancel" : "Done") { dismiss() }
                if revealed == nil {
                    Button("Reveal") {
                        Task {
                            if let hex = await state.revealRawKeyHex(keyId: keyId, passphrase: passphrase) {
                                revealed = hex
                            } else {
                                failed = true
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .preventsScreenCapture()
    }
}

private struct DiscardKeyView: View {
    let key: KeyInfo
    let onDiscarded: () -> Void
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmText = ""

    private var expected: String {
        key.resource.isEmpty ? key.label : key.resource
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Discard Key", systemImage: "trash.fill").foregroundStyle(.red).font(.headline)
            Text("This permanently deletes \"\(key.label)\". Type \"\(expected)\" to confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(expected, text: $confirmText)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Discard", role: .destructive) {
                    Task {
                        if await state.discardKey(keyId: key.keyId, confirmText: confirmText) {
                            dismiss()
                            onDiscarded()
                        }
                    }
                }
                .disabled(confirmText != expected)
            }
        }
        .padding(24)
        .frame(width: 380)
        .preventsScreenCapture()
    }
}
