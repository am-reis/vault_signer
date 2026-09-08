import Darwin
import Foundation
import Security

/// Verifies an `internal.*` caller's identity via macOS code signing,
/// not merely "some process running as this Mac's user" — spec §8
/// mandates "an internal-only method namespace" for the management UI
/// to drive vault operations, but never specified who else must be kept
/// out of it. Before this, `AgentServer` dispatched any `internal.*`
/// call from any same-user process with zero verification.
///
/// Checks, in order: the peer process is validly code-signed at all,
/// its signing identifier is exactly `com.vaultsigner.app`, and its
/// Team Identifier matches this agent's own (read dynamically from the
/// agent's own running code via `SecCodeCopySelf`, never hardcoded —
/// works the same under a personal or a paid Apple Developer team).
///
/// Skipped (always passes) in Debug builds, so
/// `uniffi-verify/agent_test_client.py` — a bare Python script with no
/// code signature at all — keeps working as the dev/test bootstrap it
/// was built as (see PROGRESS.md item 2.8). Enforced for real in
/// Release, the only configuration this project ever actually installs
/// and runs day to day (`Scripts/build-staging.sh`).
enum PeerAuthentication {
    static func callerIsVaultSignerApp(socketFD: Int32) -> Bool {
        #if DEBUG
        return true
        #else
        guard let pid = PeerIdentity.peerPid(forSocket: socketFD) else { return false }

        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess, let guestCode else {
            return false
        }
        guard SecCodeCheckValidity(guestCode, [], nil) == errSecSuccess else { return false }

        guard let guestInfo = signingInformation(for: guestCode), let ownInfo = ownSigningInformation() else { return false }
        guard let guestIdentifier = guestInfo[kSecCodeInfoIdentifier as String] as? String, guestIdentifier == "com.vaultsigner.app" else {
            return false
        }
        guard let guestTeam = guestInfo[kSecCodeInfoTeamIdentifier as String] as? String,
              let ownTeam = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String,
              guestTeam == ownTeam
        else {
            return false
        }
        return true
        #endif
    }

    #if !DEBUG
    private static func signingInformation(for code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess, let info = info as? [String: Any] else {
            return nil
        }
        return info
    }

    private static func ownSigningInformation() -> [String: Any]? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        return signingInformation(for: selfCode)
    }
    #endif
}
