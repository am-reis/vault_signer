import SwiftUI
import AppKit

/// §5.1's implicit first step: create the vault file and its first
/// compartment. Screen-capture-blocked (§5.0: passphrase entry field).
struct CreateVaultView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var label = "Personal"
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var profile: FacadeDeviceProfile = .desktop
    @State private var destinationURL: URL?

    private var canCreate: Bool {
        destinationURL != nil && !passphrase.isEmpty && passphrase == confirmPassphrase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create New Vault").font(.title2.bold())

            LabeledContent("Compartment label") {
                TextField("Personal", text: $label)
            }

            HStack {
                Text(destinationURL?.lastPathComponent ?? "No location chosen")
                    .foregroundStyle(destinationURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose Location…") { chooseDestination() }
            }

            SecureField("Master passphrase", text: $passphrase)
            SecureField("Confirm passphrase", text: $confirmPassphrase)
            if !confirmPassphrase.isEmpty && confirmPassphrase != passphrase {
                Text("Passphrases don't match").font(.caption).foregroundStyle(.red)
            }

            Picker("Device profile", selection: $profile) {
                Text("Desktop").tag(FacadeDeviceProfile.desktop)
                Text("Mobile").tag(FacadeDeviceProfile.mobile)
            }
            .pickerStyle(.segmented)

            Text("The master passphrase protects your key list and labels, but not the keys themselves — each key gets its own independent passphrase when you create it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Vault") {
                    guard let url = destinationURL else { return }
                    Task {
                        await state.createVault(path: url.path, label: label, masterPassphrase: passphrase, profile: profile)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 420)
        .preventsScreenCapture()
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Create Vault"
        panel.nameFieldStringValue = "MyVault.vlt"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        destinationURL = panel.url
    }
}
