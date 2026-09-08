import SwiftUI

/// Vault-unlock screen (spec §4.1/§5.3): lets the user pick which
/// compartment to unlock when there is more than one (the multi-
/// compartment selector spec §5.3 option 2 requires). Screen-capture-
/// blocked (§5.0: passphrase entry field).
struct UnlockView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedCompartmentId: String?
    @State private var passphrase = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("unlock.title").font(.title2.bold())
            Text(state.vaultPath ?? "").font(.caption).foregroundStyle(.secondary)

            if state.compartments.count > 1 {
                Picker("unlock.compartment_picker", selection: $selectedCompartmentId) {
                    ForEach(state.compartments, id: \.compartmentId) { compartment in
                        Text(compartment.label).tag(Optional(compartment.compartmentId))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            SecureField("unlock.master_passphrase_field", text: $passphrase)
                .frame(width: 260)
                .onSubmit(unlock)

            Button("unlock.unlock_button") { unlock() }
                .buttonStyle(.borderedProminent)
                .disabled(passphrase.isEmpty || currentCompartmentId == nil)
        }
        .padding(40)
        .preventsScreenCapture()
        .onAppear {
            if selectedCompartmentId == nil {
                selectedCompartmentId = state.compartments.first?.compartmentId
            }
        }
    }

    private var currentCompartmentId: String? {
        selectedCompartmentId ?? state.compartments.first?.compartmentId
    }

    private func unlock() {
        guard let compartmentId = currentCompartmentId else { return }
        Task {
            await state.unlock(compartmentId: compartmentId, passphrase: passphrase)
            passphrase = ""
        }
    }
}
