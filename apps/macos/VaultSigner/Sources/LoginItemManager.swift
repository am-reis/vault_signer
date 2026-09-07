import Foundation
import ServiceManagement

/// Spec §8's "Start VaultSigner at login/startup" toggle (default on,
/// disclosed clearly at first run): registers `VaultSignerAgent` as a
/// real `launchd` agent via `SMAppService`, using the `LaunchAgents`
/// plist embedded in this app's bundle at build time (see
/// `Resources/com.vaultsigner.agent.plist` and the Copy-Files/embed
/// wiring in `project.yml`) — `RunAtLoad`/`KeepAlive` in that plist are
/// what give the "restart on failure" behavior spec §8 asks for
/// (`launchd`'s own supervision, not anything this app re-implements).
enum LoginItemManager {
    private static let plistName = "com.vaultsigner.agent.plist"
    private static var service: SMAppService { .agent(plistName: plistName) }

    enum State: Equatable {
        case enabled
        case disabled
        /// The user must approve this in System Settings → General →
        /// Login Items & Extensions before it will actually run —
        /// `register()` succeeding does not guarantee the agent is
        /// live; this status is macOS's own signal that it isn't yet.
        case requiresApproval
        case notFound
    }

    static var currentState: State {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
