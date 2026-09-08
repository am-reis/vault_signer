import Darwin
import Foundation

/// A minimal client for `VaultSignerAgent`'s own `internal.*` bootstrap
/// namespace (never the public `vaultsigner.*` protocol — this is
/// exclusively for `VaultSigner.app` to keep the agent's separate,
/// independent `Vault` instance in sync with unlock actions the user
/// performs in this app's own UI). `VaultSigner.app` and
/// `VaultSignerAgent` are two different processes, each holding its own
/// in-memory `Vault` — unlocking a compartment here does nothing to the
/// agent's copy on its own (see the macOS README's "known architectural
/// gap" note), so third-party apps talking only to the agent (spec §7's
/// custom protocol) would otherwise never see a compartment this app
/// just unlocked. This is the fix: forward the same unlock, once, to
/// the agent too.
///
/// Deliberately not persisted anywhere — unlike `AutoUnlockStore`
/// (Keychain-backed, opt-in, spec §8), this sends the passphrase the
/// user already typed into a real unlock screen over the socket exactly
/// once and never stores it. Best-effort throughout: if the agent isn't
/// running, or the call otherwise fails, this fails silently — the
/// app's own local unlock has already succeeded regardless, and the
/// only consequence is that agent-side (third-party) callers won't see
/// the compartment as unlocked until the agent independently learns
/// about it (this sync, or auto-unlock).
enum AgentClient {
    private static var socketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/VaultSigner/agent.sock")
    }

    static func syncUnlockCompartment(compartmentId: String, passphrase: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = try? call(method: "internal.unlock_compartment", params: ["compartment_id": compartmentId, "passphrase": passphrase])
        }
    }

    private enum ClientError: Error { case posix(String) }

    @discardableResult
    private static func call(method: String, params: [String: Any]) throws -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.posix("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ClientError.posix("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buffer = rawPtr.bindMemory(to: Int8.self)
            for (i, byte) in pathBytes.enumerated() { buffer[i] = Int8(bitPattern: byte) }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw ClientError.posix("connect() failed") }

        var requestData = try JSONSerialization.data(withJSONObject: ["method": method, "params": params, "id": 1])
        requestData.append(0x0A)
        let written = requestData.withUnsafeBytes { rawBuf in write(fd, rawBuf.baseAddress, rawBuf.count) }
        guard written == requestData.count else { throw ClientError.posix("write() failed") }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ClientError.posix("read() failed") }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let line = buffer[buffer.startIndex..<buffer.firstIndex(of: 0x0A)!]
        return try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }
}
