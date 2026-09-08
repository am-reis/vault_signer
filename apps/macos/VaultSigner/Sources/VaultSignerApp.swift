import SwiftUI

/// `--test-login-item <register|unregister|status>`: a headless
/// verification hook for `LoginItemManager`/`SMAppService`, used because
/// this development environment can't click the real Settings toggle
/// itself (no Accessibility permission for UI scripting). Not something
/// a real user would ever pass; exits immediately rather than showing
/// any UI.
func runLoginItemTestHookIfRequested() {
    let arguments = CommandLine.arguments
    guard let flagIndex = arguments.firstIndex(of: "--test-login-item"), arguments.count > flagIndex + 1 else { return }
    switch arguments[flagIndex + 1] {
    case "register":
        do {
            try LoginItemManager.setEnabled(true)
            print("register() succeeded; status = \(LoginItemManager.currentState)")
        } catch {
            print("register() threw: \(error)")
        }
    case "unregister":
        do {
            try LoginItemManager.setEnabled(false)
            print("unregister() succeeded; status = \(LoginItemManager.currentState)")
        } catch {
            print("unregister() threw: \(error)")
        }
    case "status":
        print("status = \(LoginItemManager.currentState)")
    default:
        print("usage: --test-login-item <register|unregister|status>")
    }
    exit(0)
}

/// `--test-auto-unlock <save|delete> <compartment_id> [passphrase]`: the
/// `AutoUnlockStore`/`VaultConfig` equivalent of the login-item test hook
/// above, for the same reason (no Accessibility permission to click the
/// real Settings toggle in this environment).
func runAutoUnlockTestHookIfRequested() {
    let arguments = CommandLine.arguments
    guard let flagIndex = arguments.firstIndex(of: "--test-auto-unlock"), arguments.count > flagIndex + 1 else { return }
    let action = arguments[flagIndex + 1]
    guard arguments.count > flagIndex + 2 else {
        print("usage: --test-auto-unlock <save|delete> <compartment_id> [passphrase]")
        exit(0)
    }
    let compartmentId = arguments[flagIndex + 2]
    switch action {
    case "save":
        guard arguments.count > flagIndex + 3 else {
            print("usage: --test-auto-unlock save <compartment_id> <passphrase>")
            exit(0)
        }
        let passphrase = arguments[flagIndex + 3]
        let saved = AutoUnlockStore.save(passphrase: passphrase, forCompartment: compartmentId)
        VaultConfig.saveAutoUnlockCompartmentId(compartmentId)
        print("save() -> \(saved)")
    case "delete":
        AutoUnlockStore.delete(forCompartment: compartmentId)
        VaultConfig.saveAutoUnlockCompartmentId(nil)
        print("deleted")
    default:
        print("usage: --test-auto-unlock <save|delete> <compartment_id> [passphrase]")
    }
    exit(0)
}

/// `--test-i18n <locale> <key>`: resolves `key` directly against the
/// named `.lproj` bundle (bypassing the system/app language entirely),
/// to verify a locale's Localizable.strings loads and resolves correctly
/// without needing to actually switch languages and read the screen.
func runI18nTestHookIfRequested() {
    let arguments = CommandLine.arguments
    guard let flagIndex = arguments.firstIndex(of: "--test-i18n"), arguments.count > flagIndex + 2 else { return }
    let locale = arguments[flagIndex + 1]
    let key = arguments[flagIndex + 2]
    guard let lprojPath = Bundle.main.path(forResource: locale, ofType: "lproj"), let localeBundle = Bundle(path: lprojPath) else {
        print("no .lproj bundle found for locale '\(locale)'")
        exit(1)
    }
    let resolved = localeBundle.localizedString(forKey: key, value: "<<MISSING>>", table: nil)
    print(resolved)
    exit(0)
}

/// `--test-create-vault <path> <label> <master_passphrase>`: exercises
/// `ManagementClient.createVault` (and therefore `internal.create_vault`
/// end-to-end, including `PeerAuthentication`, which specifically
/// requires the *real*, signed `VaultSigner.app` binary as the caller —
/// unlike the other test hooks here, this one cannot be replaced by a
/// plain script). Not something a real user would ever pass.
func runCreateVaultTestHookIfRequested() {
    let arguments = CommandLine.arguments
    guard let flagIndex = arguments.firstIndex(of: "--test-create-vault"), arguments.count > flagIndex + 3 else { return }
    let path = arguments[flagIndex + 1]
    let label = arguments[flagIndex + 2]
    let masterPassphrase = arguments[flagIndex + 3]
    ManagementClient.ensureAgentRunning()
    do {
        let compartments = try ManagementClient.createVault(path: path, compartmentLabel: label, masterPassphrase: masterPassphrase, profile: .desktop)
        print("createVault() succeeded; compartments = \(compartments)")
    } catch {
        print("createVault() threw: \(error)")
    }
    exit(0)
}

@main
struct VaultSignerApp: App {
    init() {
        runLoginItemTestHookIfRequested()
        runAutoUnlockTestHookIfRequested()
        runI18nTestHookIfRequested()
        runCreateVaultTestHookIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
