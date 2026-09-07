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
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Start VaultSigner at login", isOn: $startAtLoginEnabled)
                    .onChange(of: startAtLoginEnabled) { newValue in setLoginItem(newValue) }
                statusRow
            } footer: {
                Text("Runs the background service that answers signing requests and FIDO2 prompts even when the VaultSigner window isn't open.")
                    .font(.caption)
            }

            Section {
                Toggle("Auto-unlock on startup", isOn: $autoUnlockEnabled)
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
                Text("Off by default. When on, this compartment's master passphrase is stored in the Keychain so it unlocks automatically at login, without you typing anything. This is weaker than the vault's normal design — see the confirmation dialog for what that means before turning it on.")
                    .font(.caption)
            }

            Section {
                Button("Back Up Everything…") { showingBackupEverything = true }
                    .disabled(state.unlockedCompartmentId == nil)
                Button("Back Up Master Key Only…") { showingBackupMasterKeyOnly = true }
                    .disabled(state.unlockedCompartmentId == nil)
            } header: {
                Text("Backup")
            } footer: {
                Text("\"Back up everything\" protects all keys + the master key together (spec §5.4 recommends the one-time transfer password option for backups stored anywhere other than an already-encrypted local disk). \"Master key only\" is a shortcut for people who store key recovery material separately — on its own it does NOT protect anything, since the per-key blobs are also required.")
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
                Button("Done") { dismiss() }
            }
        }
        .preventsScreenCapture()
        .onAppear {
            if let compartmentId = state.unlockedCompartmentId {
                autoUnlockEnabled = AutoUnlockStore.load(forCompartment: compartmentId) != nil
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
    }

    @ViewBuilder
    private var statusRow: some View {
        switch loginItemState {
        case .requiresApproval:
            Label("Approve VaultSigner in System Settings → General → Login Items & Extensions", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .notFound:
            Label("Login item not found in this build (development build outside /Applications?)", systemImage: "exclamationmark.circle")
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
            errorMessage = "Couldn't change login item: \(error.localizedDescription)"
            startAtLoginEnabled = LoginItemManager.currentState == .enabled
        }
        loginItemState = LoginItemManager.currentState
    }

    /// Verifies `passphrase` against the vault before ever writing it to
    /// the Keychain — otherwise a typo here would silently and
    /// permanently break auto-unlock with no feedback to the user.
    private func enableAutoUnlock(passphrase: String) async {
        guard let compartmentId = state.unlockedCompartmentId, let vault = state.vault else { return }
        let verified: Bool? = try? await Task.detached(priority: .userInitiated) {
            try vault.unlockCompartment(compartmentId: compartmentId, passphrase: passphrase)
            return true
        }.value
        guard verified == true else {
            errorMessage = "Incorrect master passphrase; auto-unlock was not enabled."
            autoUnlockEnabled = false
            return
        }
        guard AutoUnlockStore.save(passphrase: passphrase, forCompartment: compartmentId) else {
            errorMessage = "Couldn't save to Keychain."
            autoUnlockEnabled = false
            return
        }
        VaultConfig.saveAutoUnlockCompartmentId(compartmentId)
        errorMessage = nil
    }

    private func disableAutoUnlock() {
        guard let compartmentId = state.unlockedCompartmentId else { return }
        AutoUnlockStore.delete(forCompartment: compartmentId)
        VaultConfig.saveAutoUnlockCompartmentId(nil)
    }
}

private struct AutoUnlockConfirmationView: View {
    let onCancel: () -> Void
    let onConfirm: (String) -> Void
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Enable Auto-Unlock?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("""
            Your master passphrase will be stored in the macOS Keychain so this compartment unlocks automatically every time you log in or restart — no one needs to type anything.

            This means a decryption path to your key list and labels now persists across a reboot without your input. It does not expose your keys themselves — each key still needs its own separate passphrase to sign or reveal. But anyone who can run code as you on this Mac may be able to read this stored passphrase too, similar to other Keychain-backed secrets.
            """)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            SecureField("Confirm master passphrase", text: $passphrase)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Enable Auto-Unlock") { onConfirm(passphrase) }
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .preventsScreenCapture()
    }
}
