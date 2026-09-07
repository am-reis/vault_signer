import SwiftUI

/// Spec §5.3 steps 2-3: the unskippable master-key-duality screen, shown
/// only when the imported packet embeds a master key (spec §5.2.1).
/// Three distinct cards, no default pre-selected, option 3 styled
/// separately (warning color) from the neutral options 1-2, exactly as
/// spec §5.3 specifies. Screen-capture-blocked (§5.0).
struct MasterKeyDualityView: View {
    let info: ImportedPacketInfo
    let onCancel: () -> Void
    /// Called with the merge's duplicate warnings once one option has
    /// actually been applied.
    let onCompleted: ([DuplicateWarningInfo]) -> Void

    @EnvironmentObject private var state: AppState
    @State private var busy = false
    @State private var errorMessage: String?

    /// The exact phrase spec §5.3 option 3 requires — mirrors
    /// `vaultcore::merge::REPLACE_CONFIRMATION_PHRASE`, enforced again
    /// server-side regardless of what this view checks.
    private let replaceConfirmationPhrase = "REPLACE MY MASTER KEY"

    private var unlockedCompartments: [CompartmentInfo] {
        state.compartments.filter(\.unlocked)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("This import includes another vault's master key", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                Text("Before any keys are merged, choose what to do with the incoming master key. This choice cannot be skipped.")
                    .foregroundStyle(.secondary)

                option1Card
                option2Card
                option3Card

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }

                Button("Cancel Import") { onCancel() }
            }
            .padding(24)
        }
        .frame(width: 520, height: 560)
        .disabled(busy)
    }

    // MARK: Option 1

    @State private var option1TargetCompartmentId: String?

    private var option1Card: some View {
        DualityCard(title: "Re-encrypt & discard incoming master key", isRecommended: true) {
            Text("Your keys will only need your existing master password. The imported vault's master password will not be kept.")
                .font(.caption)
            if unlockedCompartments.isEmpty {
                Text("No compartment is currently unlocked to merge into.").font(.caption).foregroundStyle(.red)
            } else {
                Picker("Merge into", selection: $option1TargetCompartmentId) {
                    ForEach(unlockedCompartments, id: \.compartmentId) { c in
                        Text(c.label).tag(Optional(c.compartmentId))
                    }
                }
                Button("Use This Option") {
                    guard let target = option1TargetCompartmentId ?? unlockedCompartments.first?.compartmentId else { return }
                    runOption1(targetCompartmentId: target)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func runOption1(targetCompartmentId: String) {
        guard let vault = state.vault else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try vault.mergeReencryptDiscardIncoming(targetCompartmentId: targetCompartmentId, incomingManifestJson: info.manifestJson, incomingKeyBlobs: info.keyBlobs)
                }.value
                state.refreshKeys()
                onCompleted(outcome.warnings)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    // MARK: Option 2

    @State private var option2Label = "Imported vault"
    @State private var option2Passphrase = ""

    private var option2Card: some View {
        DualityCard(title: "Keep both master keys side by side", isRecommended: false) {
            Text("You'll keep two separate master passwords for this vault, one for each set of keys. Nothing is merged.")
                .font(.caption)
            TextField("Compartment label", text: $option2Label)
            SecureField("New master passphrase for this compartment", text: $option2Passphrase)
            Button("Use This Option") { runOption2() }
                .buttonStyle(.borderedProminent)
                .disabled(option2Passphrase.isEmpty)
        }
    }

    private func runOption2() {
        guard let vault = state.vault else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try vault.mergeSideBySide(
                        incomingManifestJson: info.manifestJson, incomingKeyBlobs: info.keyBlobs,
                        newCompartmentLabel: option2Label, newMasterPassphrase: option2Passphrase, profile: .desktop
                    )
                }.value
                state.refreshCompartments()
                onCompleted(outcome.warnings)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    // MARK: Option 3

    @State private var option3TargetCompartmentId: String?
    @State private var option3Passphrase = ""
    @State private var option3Confirmation = ""

    private var option3Card: some View {
        DualityCard(title: "Replace local master key with incoming master key", isRecommended: false, isDangerous: true) {
            Text("This will replace the password protecting ALL your existing keys, including ones you did not just import, with a different password. If you don't have both passwords available right now, stop.")
                .font(.caption)
            if !unlockedCompartments.isEmpty {
                Picker("Replace", selection: $option3TargetCompartmentId) {
                    ForEach(unlockedCompartments, id: \.compartmentId) { c in
                        Text(c.label).tag(Optional(c.compartmentId))
                    }
                }
                SecureField("Incoming vault's master passphrase", text: $option3Passphrase)
                TextField("Type \"\(replaceConfirmationPhrase)\" to confirm", text: $option3Confirmation)
                Button("Use This Option") {
                    guard let target = option3TargetCompartmentId ?? unlockedCompartments.first?.compartmentId else { return }
                    runOption3(targetCompartmentId: target)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(option3Passphrase.isEmpty || option3Confirmation != replaceConfirmationPhrase)
            }
        }
    }

    private func runOption3(targetCompartmentId: String) {
        guard let vault = state.vault, let kdfParamsJson = info.embeddedMasterKdfParamsJson else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try vault.mergeReplaceLocalWithIncoming(
                        targetCompartmentId: targetCompartmentId, incomingManifestJson: info.manifestJson, incomingKeyBlobs: info.keyBlobs,
                        incomingMasterPassphrase: option3Passphrase, incomingKdfParamsJson: kdfParamsJson, confirmationPhrase: option3Confirmation
                    )
                }.value
                state.refreshKeys()
                onCompleted(outcome.warnings)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }
}

private struct DualityCard<Content: View>: View {
    let title: String
    let isRecommended: Bool
    var isDangerous: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                if isRecommended {
                    Text("Recommended").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue.opacity(0.2), in: Capsule())
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDangerous ? Color.red.opacity(0.08) : Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isDangerous ? Color.red.opacity(0.4) : Color.gray.opacity(0.3)))
    }
}
