import SwiftUI
import AppKit

/// The entry screen (spec §5.6): shown whenever no vault is open. Leads
/// with the known-vaults list (most-recently-accessed first) so opening
/// a vault you've used before is one click, not a file browse every
/// time — the gap this screen exists to close.
struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingCreate = false
    @State private var showingManageVaults = false
    @State private var unavailablePath: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            // The product name is deliberately not localized (spec §9's
            // exception, standard i18n practice for brand names).
            Text(verbatim: "VaultSigner")
                .font(.largeTitle.bold())
            Text("welcome.subtitle")
                .foregroundStyle(.secondary)

            knownVaultsList

            HStack(spacing: 16) {
                Button("welcome.create_button") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
                Button("welcome.open_button") { openExistingVault() }
                    .buttonStyle(.bordered)
            }
            Button("welcome.manage_vaults_button") { showingManageVaults = true }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(32)
        .frame(minWidth: 460)
        .onAppear { state.refreshKnownVaults() }
        .sheet(isPresented: $showingCreate) {
            CreateVaultView()
                .environmentObject(state)
        }
        .sheet(isPresented: $showingManageVaults) {
            ManageVaultsView()
                .environmentObject(state)
        }
        .alert(
            "welcome.vault_unavailable_title",
            isPresented: Binding(get: { unavailablePath != nil }, set: { if !$0 { unavailablePath = nil } })
        ) {
            Button("import.done_button") { unavailablePath = nil }
        } message: {
            Text("welcome.vault_unavailable_message")
        }
    }

    @ViewBuilder
    private var knownVaultsList: some View {
        if state.knownVaults.isEmpty {
            Text("welcome.no_recent_vaults")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("welcome.recent_vaults_header")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                List(state.knownVaults) { entry in
                    knownVaultRow(entry)
                }
                .frame(height: 160)
                .listStyle(.bordered)
            }
            .frame(maxWidth: 380)
        }
    }

    private func knownVaultRow(_ entry: KnownVaultEntry) -> some View {
        let available = FileManager.default.fileExists(atPath: entry.path)
        return HStack {
            Button {
                if available { openKnownVault(entry) } else { unavailablePath = entry.path }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text((entry.path as NSString).lastPathComponent)
                        .foregroundStyle(available ? .primary : .secondary)
                    Text(entry.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if !available {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Button {
                state.forgetKnownVault(path: entry.path)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("welcome.forget_button"))
        }
        .contextMenu {
            Button("welcome.forget_button") { state.forgetKnownVault(path: entry.path) }
        }
    }

    private func openKnownVault(_ entry: KnownVaultEntry) {
        Task { await state.openVault(path: entry.path) }
    }

    private func openExistingVault() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "welcome.open_panel_message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.openVault(path: url.path) }
    }
}
