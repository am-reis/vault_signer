import AppKit
import Darwin
import Foundation

/// `VaultSigner.app`'s sole means of touching vault state (spec §8: the
/// UI "requests container mutations from the service rather than
/// writing the file itself"). This app never opens a `Vault`, never
/// links against vaultcore for anything beyond the plain value types
/// below (`KeyInfo`, `FacadeKeyType`, etc. — inert data shapes, not
/// cryptographic behavior) — every operation is one `internal.*` call
/// to `VaultSignerAgent` over the same Unix socket the public
/// `vaultsigner.*` protocol (spec §7) uses, authenticated on the
/// agent's side via `PeerAuthentication` (code signature, not just
/// "same OS user").
///
/// Every throwing call surfaces failures as `FacadeError.Failed`, the
/// same error `Vault`'s own (now-removed) direct calls used to throw —
/// so `AppState`'s existing `catch let error as FacadeError` handling
/// needed no changes.
enum ManagementClient {
    private static var socketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/VaultSigner/agent.sock")
    }

    private static var agentAppURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/VaultSignerAgent.app")
    }

    /// Without this, a fresh install with the login item not yet
    /// approved in System Settings would leave the app unable to do
    /// anything at all — call this before the first RPC of a session.
    static func ensureAgentRunning() {
        if canConnect() { return }
        NSWorkspace.shared.openApplication(at: agentAppURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            if canConnect() { return }
        }
    }

    private static func canConnect() -> Bool {
        guard let fd = try? connectSocket() else { return false }
        close(fd)
        return true
    }

    // MARK: - Vault lifecycle

    static func createVault(path: String, compartmentLabel: String, masterPassphrase: String, profile: FacadeDeviceProfile) throws -> [CompartmentInfo] {
        let result = try call(
            "internal.create_vault",
            params: ["path": path, "compartment_label": compartmentLabel, "master_passphrase": masterPassphrase, "profile": encodeProfile(profile)]
        )
        return try decodeArray(result["compartments"], decodeCompartment)
    }

    static func openVault(path: String) throws {
        _ = try call("internal.open_vault", params: ["path": path])
    }

    static func listCompartments() throws -> [CompartmentInfo] {
        let result = try call("internal.list_compartments", params: [:])
        return try decodeArray(result["compartments"], decodeCompartment)
    }

    static func unlockCompartment(compartmentId: String, passphrase: String) throws {
        _ = try call("internal.unlock_compartment", params: ["compartment_id": compartmentId, "passphrase": passphrase])
    }

    static func lockAll() {
        _ = try? call("internal.lock_all", params: [:])
    }

    static func addCompartment(label: String, masterPassphrase: String, profile: FacadeDeviceProfile) throws -> CompartmentInfo {
        let result = try call("internal.add_compartment", params: ["label": label, "master_passphrase": masterPassphrase, "profile": encodeProfile(profile)])
        return try decodeCompartment(result)
    }

    // MARK: - Keys

    static func listKeys(compartmentId: String) throws -> [KeyInfo] {
        let result = try call("internal.list_keys", params: ["compartment_id": compartmentId])
        return try decodeArray(result["keys"], decodeKeyInfo)
    }

    static func createKey(
        compartmentId: String, keyType: FacadeKeyType, purpose: FacadePurpose, label: String, description: String, resource: String,
        tags: [String], keyPassphrase: String
    ) throws -> KeyInfo {
        let result = try call(
            "internal.create_key",
            params: [
                "compartment_id": compartmentId, "key_type": encodeKeyType(keyType), "purpose": encodePurpose(purpose), "label": label,
                "description": description, "resource": resource, "tags": tags, "key_passphrase": keyPassphrase,
            ]
        )
        return try decodeKeyInfo(result)
    }

    static func discardKey(compartmentId: String, keyId: String, confirmText: String) throws {
        _ = try call("internal.discard_key", params: ["compartment_id": compartmentId, "key_id": keyId, "confirm_text": confirmText])
    }

    static func changeKeyPassphrase(compartmentId: String, keyId: String, oldPassphrase: String, newPassphrase: String) throws {
        _ = try call(
            "internal.change_key_passphrase",
            params: ["compartment_id": compartmentId, "key_id": keyId, "old_passphrase": oldPassphrase, "new_passphrase": newPassphrase]
        )
    }

    static func revealRawKeyHex(compartmentId: String, keyId: String, passphrase: String) throws -> String {
        let result = try call("internal.reveal_raw_key_hex", params: ["compartment_id": compartmentId, "key_id": keyId, "passphrase": passphrase])
        guard let hex = result["raw_key_hex"] as? String else { throw FacadeError.Failed(message: "malformed response") }
        return hex
    }

    // MARK: - Export / import / merge

    static func exportPacket(compartmentId: String, keyIds: [String], includeMasterKey: Bool, encryption: FacadeExportEncryption) throws -> Data {
        let result = try call(
            "internal.export_packet",
            params: ["compartment_id": compartmentId, "key_ids": keyIds, "include_master_key": includeMasterKey, "encryption": encodeExportEncryption(encryption)]
        )
        return try decodeBase64(result["packet_b64"])
    }

    static func exportSingleKey(compartmentId: String, keyId: String) throws -> Data {
        let result = try call("internal.export_single_key", params: ["compartment_id": compartmentId, "key_id": keyId])
        return try decodeBase64(result["packet_b64"])
    }

    static func importPacket(packetBytes: Data, transferPassword: String?) throws -> ImportedPacketInfo {
        var params: [String: Any] = ["packet_b64": packetBytes.base64EncodedString()]
        if let transferPassword { params["transfer_password"] = transferPassword }
        let result = try call("internal.import_packet", params: params)
        return try decodeImportedPacketInfo(result)
    }

    static func mergeReencryptDiscardIncoming(targetCompartmentId: String, incomingManifestJson: String, incomingKeyBlobs: [IncomingKeyBlob]) throws -> MergeOutcomeInfo {
        let result = try call(
            "internal.merge_reencrypt_discard_incoming",
            params: ["target_compartment_id": targetCompartmentId, "incoming_manifest_json": incomingManifestJson, "incoming_key_blobs": encodeIncomingKeyBlobs(incomingKeyBlobs)]
        )
        return try decodeMergeOutcome(result)
    }

    static func mergeSideBySide(
        incomingManifestJson: String, incomingKeyBlobs: [IncomingKeyBlob], newCompartmentLabel: String, newMasterPassphrase: String, profile: FacadeDeviceProfile
    ) throws -> MergeOutcomeInfo {
        let result = try call(
            "internal.merge_side_by_side",
            params: [
                "incoming_manifest_json": incomingManifestJson, "incoming_key_blobs": encodeIncomingKeyBlobs(incomingKeyBlobs),
                "new_compartment_label": newCompartmentLabel, "new_master_passphrase": newMasterPassphrase, "profile": encodeProfile(profile),
            ]
        )
        return try decodeMergeOutcome(result)
    }

    static func mergeReplaceLocalWithIncoming(
        targetCompartmentId: String, incomingManifestJson: String, incomingKeyBlobs: [IncomingKeyBlob], incomingMasterPassphrase: String,
        incomingKdfParamsJson: String, confirmationPhrase: String
    ) throws -> MergeOutcomeInfo {
        let result = try call(
            "internal.merge_replace_local_with_incoming",
            params: [
                "target_compartment_id": targetCompartmentId, "incoming_manifest_json": incomingManifestJson,
                "incoming_key_blobs": encodeIncomingKeyBlobs(incomingKeyBlobs), "incoming_master_passphrase": incomingMasterPassphrase,
                "incoming_kdf_params_json": incomingKdfParamsJson, "confirmation_phrase": confirmationPhrase,
            ]
        )
        return try decodeMergeOutcome(result)
    }

    // MARK: - Auto-unlock (spec §8) — the agent owns Keychain + VaultConfig writes for this

    static func enableAutoUnlock(compartmentId: String, passphrase: String) throws {
        _ = try call("internal.enable_auto_unlock", params: ["compartment_id": compartmentId, "passphrase": passphrase])
    }

    static func disableAutoUnlock(compartmentId: String) {
        _ = try? call("internal.disable_auto_unlock", params: ["compartment_id": compartmentId])
    }

    static func isAutoUnlockEnabled(compartmentId: String) -> Bool {
        (try? call("internal.is_auto_unlock_enabled", params: ["compartment_id": compartmentId]))?["enabled"] as? Bool ?? false
    }

    // MARK: - Transport

    private static func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FacadeError.Failed(message: "socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw FacadeError.Failed(message: "socket path too long")
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
        guard connectResult == 0 else {
            close(fd)
            throw FacadeError.Failed(message: "VaultSignerAgent isn't running")
        }
        return fd
    }

    @discardableResult
    private static func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let fd = try connectSocket()
        defer { close(fd) }

        var requestData = try JSONSerialization.data(withJSONObject: ["method": method, "params": params, "id": 1])
        requestData.append(0x0A)
        let written = requestData.withUnsafeBytes { rawBuf in write(fd, rawBuf.baseAddress, rawBuf.count) }
        guard written == requestData.count else { throw FacadeError.Failed(message: "write() to VaultSignerAgent failed") }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw FacadeError.Failed(message: "VaultSignerAgent closed the connection unexpectedly") }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let line = buffer[buffer.startIndex..<buffer.firstIndex(of: 0x0A)!]
        guard let response = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            throw FacadeError.Failed(message: "malformed response from VaultSignerAgent")
        }
        if let error = response["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "unknown_error"
            let message = error["message"] as? String ?? "unknown error"
            throw FacadeError.Failed(message: "\(code): \(message)")
        }
        return response["result"] as? [String: Any] ?? [:]
    }
}

// MARK: - Encoding/decoding helpers (mirrored by VaultSignerAgent/Sources/ManagementHandlers.swift)

private func encodeProfile(_ profile: FacadeDeviceProfile) -> String {
    switch profile {
    case .desktop: return "desktop"
    case .mobile: return "mobile"
    }
}

private func encodeKeyType(_ type: FacadeKeyType) -> String {
    switch type {
    case .ed25519: return "ed25519"
    case .ecdsaP256: return "ecdsa_p256"
    }
}

private func decodeKeyType(_ raw: String) throws -> FacadeKeyType {
    switch raw {
    case "ed25519": return .ed25519
    case "ecdsa_p256": return .ecdsaP256
    default: throw FacadeError.Failed(message: "unknown key_type: \(raw)")
    }
}

private func encodePurpose(_ purpose: FacadePurpose) -> String {
    switch purpose {
    case .fido2: return "fido2"
    case .customSigning: return "custom_signing"
    case .both: return "both"
    }
}

private func decodePurpose(_ raw: String) throws -> FacadePurpose {
    switch raw {
    case "fido2": return .fido2
    case "custom_signing": return .customSigning
    case "both": return .both
    default: throw FacadeError.Failed(message: "unknown purpose: \(raw)")
    }
}

private func encodeExportEncryption(_ encryption: FacadeExportEncryption) -> [String: Any] {
    switch encryption {
    case .asIs: return ["type": "as_is"]
    case .destinationMasterPassword(let password): return ["type": "destination_master_password", "password": password]
    case .oneTimeTransferPassword(let password): return ["type": "one_time_transfer_password", "password": password]
    }
}

private func encodeIncomingKeyBlobs(_ blobs: [IncomingKeyBlob]) -> [[String: Any]] {
    blobs.map { ["key_id": $0.keyId, "blob_bytes_b64": $0.blobBytes.base64EncodedString()] }
}

private func decodeCompartment(_ dict: [String: Any]) throws -> CompartmentInfo {
    guard let compartmentId = dict["compartment_id"] as? String, let label = dict["label"] as? String, let unlocked = dict["unlocked"] as? Bool else {
        throw FacadeError.Failed(message: "malformed compartment in response")
    }
    return CompartmentInfo(compartmentId: compartmentId, label: label, unlocked: unlocked)
}

private func decodeKeyInfo(_ dict: [String: Any]) throws -> KeyInfo {
    guard let keyId = dict["key_id"] as? String, let compartmentId = dict["compartment_id"] as? String, let label = dict["label"] as? String,
          let description = dict["description"] as? String, let resource = dict["resource"] as? String,
          let keyTypeRaw = dict["key_type"] as? String, let purposeRaw = dict["purpose"] as? String,
          let createdAt = dict["created_at"] as? String, let tags = dict["tags"] as? [String], let publicKeyHex = dict["public_key_hex"] as? String
    else {
        throw FacadeError.Failed(message: "malformed key in response")
    }
    return KeyInfo(
        keyId: keyId, compartmentId: compartmentId, label: label, description: description, resource: resource,
        keyType: try decodeKeyType(keyTypeRaw), purpose: try decodePurpose(purposeRaw), fido2: nil, createdAt: createdAt,
        lastUsedAt: dict["last_used_at"] as? String, tags: tags, publicKeyHex: publicKeyHex
    )
}

private func decodeImportedPacketInfo(_ dict: [String: Any]) throws -> ImportedPacketInfo {
    guard let manifestJson = dict["manifest_json"] as? String, let blobDicts = dict["key_blobs"] as? [[String: Any]] else {
        throw FacadeError.Failed(message: "malformed import result")
    }
    var keyBlobs: [IncomingKeyBlob] = []
    for entry in blobDicts {
        guard let keyId = entry["key_id"] as? String, let blobB64 = entry["blob_bytes_b64"] as? String, let blobBytes = Data(base64Encoded: blobB64) else {
            throw FacadeError.Failed(message: "malformed key blob in import result")
        }
        keyBlobs.append(IncomingKeyBlob(keyId: keyId, blobBytes: blobBytes))
    }
    return ImportedPacketInfo(
        manifestJson: manifestJson, keyBlobs: keyBlobs,
        embeddedMasterCompartmentId: dict["embedded_master_compartment_id"] as? String,
        embeddedMasterKdfParamsJson: dict["embedded_master_kdf_params_json"] as? String
    )
}

private func decodeMergeOutcome(_ dict: [String: Any]) throws -> MergeOutcomeInfo {
    guard let warningDicts = dict["warnings"] as? [[String: Any]], let remapDicts = dict["id_remap"] as? [[String: Any]] else {
        throw FacadeError.Failed(message: "malformed merge result")
    }
    let warnings = try warningDicts.map { entry -> DuplicateWarningInfo in
        guard let incomingKeyId = entry["incoming_key_id"] as? String, let matchedLocalKeyId = entry["matched_local_key_id"] as? String,
              let matchedInCompartment = entry["matched_in_compartment"] as? String, let reason = entry["reason"] as? String
        else {
            throw FacadeError.Failed(message: "malformed merge warning")
        }
        return DuplicateWarningInfo(incomingKeyId: incomingKeyId, matchedLocalKeyId: matchedLocalKeyId, matchedInCompartment: matchedInCompartment, reason: reason)
    }
    let idRemap = try remapDicts.map { entry -> IdRemapEntry in
        guard let oldKeyId = entry["old_key_id"] as? String, let newKeyId = entry["new_key_id"] as? String else {
            throw FacadeError.Failed(message: "malformed id remap entry")
        }
        return IdRemapEntry(oldKeyId: oldKeyId, newKeyId: newKeyId)
    }
    return MergeOutcomeInfo(warnings: warnings, idRemap: idRemap)
}

private func decodeArray<T>(_ raw: Any?, _ decode: ([String: Any]) throws -> T) throws -> [T] {
    guard let array = raw as? [[String: Any]] else { throw FacadeError.Failed(message: "malformed list in response") }
    return try array.map(decode)
}

private func decodeBase64(_ raw: Any?) throws -> Data {
    guard let b64 = raw as? String, let data = Data(base64Encoded: b64) else { throw FacadeError.Failed(message: "malformed base64 in response") }
    return data
}
