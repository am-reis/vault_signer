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
            Section("keydetail.details_section") {
                LabeledContent("keydetail.label_field", value: key.label)
                if !key.description.isEmpty { LabeledContent("keydetail.description_field", value: key.description) }
                if !key.resource.isEmpty { LabeledContent("keydetail.resource_field", value: key.resource) }
                LabeledContent("keydetail.public_key_field", value: String(key.publicKeyHex.prefix(16)) + "…")
                LabeledContent("keydetail.created_field", value: key.createdAt)
                if !key.tags.isEmpty { LabeledContent("keydetail.tags_field", value: key.tags.joined(separator: ", ")) }
            }

            Section("keydetail.actions_section") {
                Button("keydetail.change_passphrase_button") { showingChangePassphrase = true }
                Button("keydetail.reveal_raw_key_button", role: .destructive) { showingReveal = true }
                Button("keydetail.export_button") { exportSingleKey() }
                if let exportErrorMessage {
                    Text(exportErrorMessage).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Button("keydetail.discard_button", role: .destructive) { showingDiscardConfirm = true }
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
        panel.title = String(localized: "keydetail.panel_title")
        panel.nameFieldStringValue = "\(key.label).vltkey"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let bytes = await state.exportSingleKey(keyId: key.keyId) else {
                exportErrorMessage = String(format: String(localized: "keydetail.export_failed_format"), state.errorMessage ?? "unknown error")
                state.clearError()
                return
            }
            do {
                try bytes.write(to: url, options: .atomic)
                exportErrorMessage = nil
            } catch {
                exportErrorMessage = String(format: String(localized: "keydetail.export_failed_format"), "\(error)")
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
            Text("changepassphrase.title").font(.title2.bold())
            SecureField("changepassphrase.current_field", text: $oldPassphrase)
            SecureField("changepassphrase.new_field", text: $newPassphrase)
            SecureField("changepassphrase.confirm_field", text: $confirmPassphrase)
            if failed { Text("changepassphrase.incorrect_current").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("common.cancel_button") { dismiss() }
                Button("changepassphrase.change_button") {
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

    private var dismissButtonKey: LocalizedStringKey {
        revealed == nil ? "common.cancel_button" : "common.done_button"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("revealkey.danger_zone_label", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)
            Text("revealkey.warning_text")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let revealed {
                Text(revealed)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                SecureField("revealkey.passphrase_field", text: $passphrase)
                if failed { Text("revealkey.incorrect_passphrase").font(.caption).foregroundStyle(.red) }
            }

            HStack {
                Spacer()
                Button(dismissButtonKey) { dismiss() }
                if revealed == nil {
                    Button("revealkey.reveal_button") {
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
            Label("discardkey.title", systemImage: "trash.fill").foregroundStyle(.red).font(.headline)
            Text(String(format: String(localized: "discardkey.confirm_format"), key.label, expected))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(expected, text: $confirmText)
            HStack {
                Spacer()
                Button("common.cancel_button") { dismiss() }
                Button("discardkey.discard_button", role: .destructive) {
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
