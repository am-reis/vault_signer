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
            Text("VaultSigner")
                .font(.largeTitle.bold())
            Text("Create a new vault, or open one you already have.")
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("Create New Vault…") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
                Button("Open Existing Vault…") { openExistingVault() }
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
        panel.message = "Choose a .vlt vault file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.openVault(path: url.path) }
    }
}
