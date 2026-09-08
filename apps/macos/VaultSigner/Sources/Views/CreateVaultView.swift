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
            Text("createvault.title").font(.title2.bold())

            LabeledContent("createvault.compartment_label_field") {
                TextField("createvault.compartment_label_placeholder", text: $label)
            }

            HStack {
                Text(destinationURL?.lastPathComponent ?? String(localized: "createvault.no_location_chosen"))
                    .foregroundStyle(destinationURL == nil ? .secondary : .primary)
                Spacer()
                Button("createvault.choose_location_button") { chooseDestination() }
            }

            SecureField("createvault.master_passphrase_field", text: $passphrase)
            SecureField("createvault.confirm_passphrase_field", text: $confirmPassphrase)
            if !confirmPassphrase.isEmpty && confirmPassphrase != passphrase {
                Text("common.passphrases_dont_match").font(.caption).foregroundStyle(.red)
            }

            Picker("createvault.device_profile_label", selection: $profile) {
                Text("createvault.profile_desktop").tag(FacadeDeviceProfile.desktop)
                Text("createvault.profile_mobile").tag(FacadeDeviceProfile.mobile)
            }
            .pickerStyle(.segmented)

            Text("createvault.master_passphrase_explanation")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("common.cancel_button") { dismiss() }
                Button("createvault.create_button") {
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
        panel.title = String(localized: "createvault.panel_title")
        panel.nameFieldStringValue = "MyVault.vlt"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        destinationURL = panel.url
    }
}
