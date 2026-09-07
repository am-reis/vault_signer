import SwiftUI
import AppKit

struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingCreate = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            // The product name is deliberately not localized (spec §9's
            // exception, standard i18n practice for brand names).
            Text(verbatim: "VaultSigner")
                .font(.largeTitle.bold())
            Text("welcome.subtitle")
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("welcome.create_button") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
                Button("welcome.open_button") { openExistingVault() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(40)
        .sheet(isPresented: $showingCreate) {
            CreateVaultView()
                .environmentObject(state)
        }
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
