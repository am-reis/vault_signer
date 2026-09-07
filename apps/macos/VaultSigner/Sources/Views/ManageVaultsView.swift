import SwiftUI
import AppKit

/// Spec §5.6's dedicated management screen: reachable from both the
/// entry screen (`WelcomeView`) and Settings, so managing known vaults
/// never requires closing whatever vault is currently open. Operates
/// purely on `AppState.knownVaults`/`KnownVaultsStore` — never touches
/// `state.vault` — which is what makes it safe to open from either
/// context.
struct ManageVaultsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("manage_vaults.title").font(.title2.bold())
            Text("manage_vaults.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.knownVaults.isEmpty {
                Text("welcome.no_recent_vaults")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                List(state.knownVaults) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((entry.path as NSString).lastPathComponent)
                            Text(entry.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if !FileManager.default.fileExists(atPath: entry.path) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("welcome.forget_button", role: .destructive) {
                            state.forgetKnownVault(path: entry.path)
                        }
                    }
                }
                .frame(minHeight: 200)
            }

            HStack {
                Button("manage_vaults.add_button") { addExistingVault() }
                Spacer()
                Button("import.done_button") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .preventsScreenCapture()
        .onAppear { state.refreshKnownVaults() }
    }

    private func addExistingVault() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "manage_vaults.add_panel_message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.addKnownVaultWithoutOpening(path: url.path)
    }
}
