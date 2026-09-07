import SwiftUI

/// §5.1 "Create key". FIDO2/Both purposes are intentionally not offered
/// here — a bindable passkey needs a real relying-party ceremony
/// (rp_id/user_handle), which `Vault.handleFido2MakeCredential` supplies
/// from the live CTAP2 request; this manual flow only ever creates
/// `customSigning` keys. Screen-capture-blocked (§5.0: passphrase entry).
struct CreateKeyView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var description = ""
    @State private var resource = ""
    @State private var keyType: FacadeKeyType = .ed25519
    @State private var tagsText = ""
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""

    private var canCreate: Bool {
        !label.isEmpty && !passphrase.isEmpty && passphrase == confirmPassphrase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Key").font(.title2.bold())

            TextField("Label", text: $label)
            TextField("Description (optional)", text: $description)
            TextField("Resource, e.g. https://example.com", text: $resource)
            TextField("Tags, comma-separated", text: $tagsText)

            Picker("Key type", selection: $keyType) {
                Text("Ed25519 (default)").tag(FacadeKeyType.ed25519)
                Text("ECDSA P-256").tag(FacadeKeyType.ecdsaP256)
            }

            SecureField("Key passphrase", text: $passphrase)
            SecureField("Confirm key passphrase", text: $confirmPassphrase)
            if !confirmPassphrase.isEmpty && confirmPassphrase != passphrase {
                Text("Passphrases don't match").font(.caption).foregroundStyle(.red)
            }

            Text("This passphrase is independent of your vault's master passphrase — you'll need it again to sign or reveal this key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    Task {
                        if await state.createKey(
                            keyType: keyType, purpose: .customSigning, label: label, description: description,
                            resource: resource, tags: tags, keyPassphrase: passphrase
                        ) != nil {
                            dismiss()
                        }
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
}
