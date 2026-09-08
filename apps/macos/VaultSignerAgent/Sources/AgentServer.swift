import Darwin
import Foundation

/// The background service (spec §8): owns the single `Vault` instance —
/// there is no other copy anywhere else in the system, per spec §8 ("the
/// service ... is the sole writer of the container file") — its
/// retention cache/throttle state, and the custom local signing
/// protocol's transport (spec §7): a Unix domain socket at a well-known,
/// owner-only-permission path, never accepting non-loopback connections
/// (a Unix socket is loopback-only by construction). Framing is
/// newline-delimited JSON: each request is one line, each response is
/// one line, matching the message shapes `vaultcore::protocol` already
/// defines.
///
/// Method namespace: `vaultsigner.*` requests are passed straight to
/// `vault.handleProtocolRequest`, unchanged from spec §7. `internal.*`
/// methods are this agent's own management namespace (spec §8: "using an
/// internal-only method namespace") — `VaultSigner.app` never opens a
/// `Vault` of its own; every vault operation it performs, including
/// creating/opening the vault file itself, is one of these calls (see
/// `ManagementHandlers.swift`). Real callers are authenticated via
/// `PeerAuthentication` (Release builds only — see that file).
///
/// `vault` is `var`/optional rather than a fixed `let`, because a fresh
/// install has no vault yet: the agent still needs to be running (to
/// serve `internal.create_vault`) before one exists. Reads/writes of the
/// property itself are guarded by `vaultLock`; `Vault`'s own methods are
/// already internally synchronized (a Rust `Mutex` guards its mutable
/// state), so no additional locking is needed once a reference is read.
final class AgentServer {
    private var _vault: Vault?
    private let vaultLock = NSLock()
    var vault: Vault? {
        get { vaultLock.lock(); defer { vaultLock.unlock() }; return _vault }
        set { vaultLock.lock(); defer { vaultLock.unlock() }; _vault = newValue }
    }

    private let socketPath: String
    private var listenFD: Int32 = -1
    private let prompter = AlertPassphrasePrompter()

    init(vault: Vault?, socketPath: String) {
        self._vault = vault
        self.socketPath = socketPath
    }

    func start() throws {
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(socketPath) // remove a stale socket from a previous run

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw AgentError.posix("socket() failed: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AgentError.posix("socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buffer = rawPtr.bindMemory(to: Int8.self)
            for (i, byte) in pathBytes.enumerated() { buffer[i] = Int8(bitPattern: byte) }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw AgentError.posix("bind() failed: \(String(cString: strerror(errno)))") }

        // Owner-only permissions (spec §7: "advertised via a well-known
        // local file with owner-only permissions").
        chmod(socketPath, 0o600)

        guard listen(listenFD, 16) == 0 else { throw AgentError.posix("listen() failed: \(String(cString: strerror(errno)))") }

        print("VaultSignerAgent: listening on \(socketPath)")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            acceptLoop()
        }
    }

    private func acceptLoop() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                handleConnection(clientFD)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var readChunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = read(fd, &readChunk, readChunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: readChunk[0..<n])

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                guard !line.isEmpty else { continue }
                let response = handleLine(Data(line), socketFD: fd)
                var out = response
                out.append(0x0A)
                out.withUnsafeBytes { rawBuf in
                    _ = write(fd, rawBuf.baseAddress, rawBuf.count)
                }
            }
        }
    }

    private func handleLine(_ line: Data, socketFD: Int32) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = json["method"] as? String
        else {
            return errorResponse(id: NSNull(), code: "parse_error", message: "malformed JSON-RPC request")
        }
        let id = json["id"] ?? NSNull()

        if method.hasPrefix("internal.") {
            guard PeerAuthentication.callerIsVaultSignerApp(socketFD: socketFD) else {
                return errorResponse(id: id, code: "unauthorized_caller", message: "internal.* is restricted to VaultSigner.app")
            }
            return handleInternal(method: method, params: json["params"] as? [String: Any] ?? [:], id: id)
        }

        guard let vault else {
            return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open")
        }
        let callerIdentity = PeerIdentity.callerDisplayName(forSocket: socketFD)
        return vault.handleProtocolRequest(callerIdentity: callerIdentity, rawJson: line, prompter: prompter)
    }

    /// The original bootstrap namespace (unlock/list only — see
    /// `ManagementHandlers.swift` for the full surface added when
    /// `VaultSigner.app` stopped holding its own `Vault`). Kept here,
    /// not moved, since these three predate and are unrelated to that
    /// split — no reason to churn their location too.
    private func handleInternal(method: String, params: [String: Any], id: Any) -> Data {
        switch method {
        case "internal.unlock_compartment":
            guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
            guard let compartmentId = params["compartment_id"] as? String, let passphrase = params["passphrase"] as? String else {
                return errorResponse(id: id, code: "invalid_params", message: "compartment_id and passphrase are required")
            }
            do {
                try vault.unlockCompartment(compartmentId: compartmentId, passphrase: passphrase)
                return resultResponse(id: id, result: [:])
            } catch {
                return errorResponse(id: id, code: "unlock_failed", message: "\(error)")
            }
        case "internal.list_compartments":
            guard let vault else { return resultResponse(id: id, result: ["compartments": []]) }
            let compartments = vault.listCompartments().map { ["compartment_id": $0.compartmentId, "label": $0.label, "unlocked": $0.unlocked] }
            return resultResponse(id: id, result: ["compartments": compartments])
        case "internal.unlock_key":
            guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
            guard let compartmentId = params["compartment_id"] as? String, let keyId = params["key_id"] as? String,
                  let passphrase = params["passphrase"] as? String
            else {
                return errorResponse(id: id, code: "invalid_params", message: "compartment_id, key_id and passphrase are required")
            }
            let retentionSecs = UInt32(params["retention_secs"] as? Int ?? 30)
            do {
                try vault.unlockKey(compartmentId: compartmentId, keyId: keyId, passphrase: passphrase, retentionSecs: retentionSecs)
                return resultResponse(id: id, result: [:])
            } catch {
                return errorResponse(id: id, code: "unlock_failed", message: "\(error)")
            }
        default:
            return handleManagementInternal(method: method, params: params, id: id)
        }
    }

    func resultResponse(id: Any, result: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id, "result": result])) ?? Data("{}".utf8)
    }

    func errorResponse(id: Any, code: String, message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": code, "message": message]])) ?? Data("{}".utf8)
    }
}

enum AgentError: Error, CustomStringConvertible {
    case posix(String)
    var description: String {
        switch self {
        case .posix(let message): return message
        }
    }
}
