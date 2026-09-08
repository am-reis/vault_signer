import SwiftUI

/// Spec §8's two independent toggles: "Start at login" (`LoginItemManager`,
/// backed by `SMAppService`) and "Auto-unlock on startup"
/// (`AutoUnlockStore`, backed by the Keychain) — both real, both wired to
/// `VaultSignerAgent` actually consuming them. Screen-capture-blocked
/// (spec §5.0): this screen can show whether auto-unlock is on, which is
/// itself sensitive (it tells an onlooker the vault will open unattended).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var startAtLoginEnabled = LoginItemManager.currentState == .enabled
    @State private var loginItemState = LoginItemManager.currentState
    @State private var autoUnlockEnabled = false
    @State private var showingAutoUnlockConfirmation = false
    @State private var showingBackupEverything = false
    @State private var showingBackupMasterKeyOnly = false
    @State private var showingManageVaults = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("settings.start_at_login_toggle", isOn: $startAtLoginEnabled)
                    .onChange(of: startAtLoginEnabled) { newValue in setLoginItem(newValue) }
                statusRow
            } footer: {
                Text("settings.start_at_login_footer")
                    .font(.caption)
            }

            Section {
                Toggle("settings.auto_unlock_toggle", isOn: $autoUnlockEnabled)
                    .disabled(state.unlockedCompartmentId == nil)
                    .onChange(of: autoUnlockEnabled) { newValue in
                        if newValue {
                            // Require explicit confirmation with the risk
                            // explanation before doing anything (spec §8:
                            // "requires explicit opt-in with an in-app
                            // risk explanation").
                            showingAutoUnlockConfirmation = true
                        } else {
                            disableAutoUnlock()
                        }
                    }
            } footer: {
                Text("settings.auto_unlock_footer")
                    .font(.caption)
            }

            Section {
                Button("settings.backup_everything_button") { showingBackupEverything = true }
                    .disabled(state.unlockedCompartmentId == nil)
                Button("settings.backup_master_only_button") { showingBackupMasterKeyOnly = true }
                    .disabled(state.unlockedCompartmentId == nil)
            } header: {
                Text("settings.backup_header")
            } footer: {
                Text("settings.backup_footer")
                    .font(.caption)
            }

            Section {
                Button("manage_vaults.open_button") { showingManageVaults = true }
                Button("manage_vaults.close_vault_button") {
                    dismiss()
                    state.closeVault()
                }
            } header: {
                Text("settings.vaults_header")
            } footer: {
                Text("manage_vaults.settings_footer")
                    .font(.caption)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.top, 8)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("common.done_button") { dismiss() }
            }
        }
        .preventsScreenCapture()
        .onAppear {
            if let compartmentId = state.unlockedCompartmentId {
                Task { autoUnlockEnabled = await state.isAutoUnlockEnabled(compartmentId: compartmentId) }
            }
        }
        .sheet(isPresented: $showingAutoUnlockConfirmation) {
            AutoUnlockConfirmationView(
                onCancel: {
                    autoUnlockEnabled = false
                    showingAutoUnlockConfirmation = false
                },
                onConfirm: { passphrase in
                    Task {
                        await enableAutoUnlock(passphrase: passphrase)
                        showingAutoUnlockConfirmation = false
                    }
                }
            )
        }
        .sheet(isPresented: $showingBackupEverything) {
            ExportPacketView(lockSelectionToAllKeys: true, forceIncludeMasterKey: true).environmentObject(state)
        }
        .sheet(isPresented: $showingBackupMasterKeyOnly) {
            BackupMasterKeyOnlyView().environmentObject(state)
        }
        .sheet(isPresented: $showingManageVaults) {
            ManageVaultsView().environmentObject(state)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch loginItemState {
        case .requiresApproval:
            Label("settings.approve_login_item_message", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .notFound:
            Label("settings.login_item_not_found_message", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .enabled, .disabled:
            EmptyView()
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = String(format: String(localized: "settings.login_item_change_failed_format"), error.localizedDescription)
            startAtLoginEnabled = LoginItemManager.currentState == .enabled
        }
        loginItemState = LoginItemManager.currentState
    }

    /// The agent verifies `passphrase` against its own vault before ever
    /// writing it to the Keychain — otherwise a typo here would silently
    /// and permanently break auto-unlock with no feedback to the user.
    /// This app never touches the Keychain or `VaultConfig` for this —
    /// see `ManagementClient.enableAutoUnlock`/`AgentServer`'s handler.
    private func enableAutoUnlock(passphrase: String) async {
        guard let compartmentId = state.unlockedCompartmentId else { return }
        guard await state.enableAutoUnlock(compartmentId: compartmentId, passphrase: passphrase) else {
            errorMessage = state.errorMessage ?? String(localized: "settings.auto_unlock_incorrect_passphrase")
            state.clearError()
            autoUnlockEnabled = false
            return
        }
        errorMessage = nil
    }

    private func disableAutoUnlock() {
        guard let compartmentId = state.unlockedCompartmentId else { return }
        state.disableAutoUnlock(compartmentId: compartmentId)
    }
}

private struct AutoUnlockConfirmationView: View {
    let onCancel: () -> Void
    let onConfirm: (String) -> Void
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("autounlockconfirm.title", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("autounlockconfirm.body_text")
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            SecureField("autounlockconfirm.confirm_passphrase_field", text: $passphrase)

            HStack {
                Spacer()
                Button("common.cancel_button") { onCancel() }
                Button("autounlockconfirm.enable_button") { onConfirm(passphrase) }
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .preventsScreenCapture()
    }
}
