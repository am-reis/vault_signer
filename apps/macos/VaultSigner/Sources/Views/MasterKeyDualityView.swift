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
                Label("duality.header", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                Text("duality.subtitle")
                    .foregroundStyle(.secondary)

                option1Card
                option2Card
                option3Card

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }

                Button("duality.cancel_button") { onCancel() }
            }
            .padding(24)
        }
        .frame(width: 520, height: 560)
        .disabled(busy)
    }

    // MARK: Option 1

    @State private var option1TargetCompartmentId: String?

    private var option1Card: some View {
        DualityCard(titleKey: "duality.option1.title", isRecommended: true) {
            Text("duality.option1.description")
                .font(.caption)
            if unlockedCompartments.isEmpty {
                Text("duality.option1.no_unlocked_compartment").font(.caption).foregroundStyle(.red)
            } else {
                Picker("duality.option1.merge_into_picker", selection: $option1TargetCompartmentId) {
                    ForEach(unlockedCompartments, id: \.compartmentId) { c in
                        Text(c.label).tag(Optional(c.compartmentId))
                    }
                }
                Button("duality.use_this_option_button") {
                    guard let target = option1TargetCompartmentId ?? unlockedCompartments.first?.compartmentId else { return }
                    runOption1(targetCompartmentId: target)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func runOption1(targetCompartmentId: String) {
        busy = true
        Task {
            defer { busy = false }
            guard let outcome = await state.mergeReencryptDiscardIncoming(targetCompartmentId: targetCompartmentId, incomingManifestJson: info.manifestJson, incomingKeyBlobs: info.keyBlobs)
            else {
                errorMessage = state.errorMessage ?? "unknown error"
                state.clearError()
                return
            }
            state.refreshKeys()
            onCompleted(outcome.warnings)
        }
    }

    // MARK: Option 2

    @State private var option2Label = "Imported vault"
    @State private var option2Passphrase = ""

    private var option2Card: some View {
        DualityCard(titleKey: "duality.option2.title", isRecommended: false) {
            Text("duality.option2.description")
                .font(.caption)
            TextField("duality.option2.label_field", text: $option2Label)
            SecureField("duality.option2.passphrase_field", text: $option2Passphrase)
            Button("duality.use_this_option_button") { runOption2() }
                .buttonStyle(.borderedProminent)
                .disabled(option2Passphrase.isEmpty)
        }
    }

    private func runOption2() {
        busy = true
        Task {
            defer { busy = false }
            guard let outcome = await state.mergeSideBySide(
                incomingManifestJson: info.manifestJson, incomingKeyBlobs: info.keyBlobs,
                newCompartmentLabel: option2Label, newMasterPassphrase: option2Passphrase, profile: .desktop
            ) else {
                errorMessage = state.errorMessage ?? "unknown error"
                state.clearError()
                return
            }
            await state.refreshCompartments()
            onCompleted(outcome.warnings)
        }
    }

    // MARK: Option 3

    @State private var option3TargetCompartmentId: String?
    @State private var option3Passphrase = ""
    @State private var option3Confirmation = ""

    private var option3ConfirmationFieldLabel: String {
        String(format: String(localized: "duality.option3.confirmation_field_format"), replaceConfirmationPhrase)
    }

    private var option3Card: some View {
        DualityCard(titleKey: "duality.option3.title", isRecommended: false, isDangerous: true) {
            Text("duality.option3.description")
                .font(.caption)
            if !unlockedCompartments.isEmpty {
                Picker("duality.option3.replace_picker", selection: $option3TargetCompartmentId) {
                    ForEach(unlockedCompartments, id: \.compartmentId) { c in
                        Text(c.label).tag(Optional(c.compartmentId))
                    }
                }
                SecureField("duality.option3.passphrase_field", text: $option3Passphrase)
                TextField(option3ConfirmationFieldLabel, text: $option3Confirmation)
                Button("duality.use_this_option_button") {
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
        guard let kdfParamsJson = info.embeddedMasterKdfParamsJson else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let outcome = await state.mergeReplaceLocalWithIncoming(
                targetCompartmentId: targetCompartmentId, incomingManifestJson: info.manifestJson, incomingKeyBlobs: info.keyBlobs,
                incomingMasterPassphrase: option3Passphrase, incomingKdfParamsJson: kdfParamsJson, confirmationPhrase: option3Confirmation
            ) else {
                errorMessage = state.errorMessage ?? "unknown error"
                state.clearError()
                return
            }
            state.refreshKeys()
            onCompleted(outcome.warnings)
        }
    }
}

private struct DualityCard<Content: View>: View {
    let titleKey: LocalizedStringKey
    let isRecommended: Bool
    var isDangerous: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(titleKey).font(.headline)
                if isRecommended {
                    Text("duality.recommended_badge").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
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
