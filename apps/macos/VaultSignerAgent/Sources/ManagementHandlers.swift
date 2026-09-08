import Foundation

/// The full `internal.*` management surface: every operation
/// `VaultSigner.app` needs, now that it holds no `Vault` of its own
/// (spec §8: the service is "the sole writer of the container file";
/// the UI "requests container mutations from the service rather than
/// writing the file itself"). Reachable only from `AgentServer.handleInternal`
/// after `PeerAuthentication` has already accepted the caller.
///
/// Wire encoding follows the same manual `[String: Any]` /
/// `_b64`-suffixed-bytes convention `vaultcore::protocol` and
/// `AgentServer`'s original three methods already use — no new
/// convention introduced, just extended in volume. `Shared/ManagementClient.swift`
/// is the matching client-side encode/decode.
extension AgentServer {
    func handleManagementInternal(method: String, params: [String: Any], id: Any) -> Data {
        switch method {
        case "internal.create_vault":
            return createVault(params: params, id: id)
        case "internal.open_vault":
            return openVault(params: params, id: id)
        case "internal.lock_all":
            vault?.lockAll()
            return resultResponse(id: id, result: [:])
        case "internal.add_compartment":
            return addCompartment(params: params, id: id)
        case "internal.list_keys":
            return listKeys(params: params, id: id)
        case "internal.create_key":
            return createKey(params: params, id: id)
        case "internal.discard_key":
            return discardKey(params: params, id: id)
        case "internal.change_key_passphrase":
            return changeKeyPassphrase(params: params, id: id)
        case "internal.reveal_raw_key_hex":
            return revealRawKeyHex(params: params, id: id)
        case "internal.export_packet":
            return exportPacket(params: params, id: id)
        case "internal.export_single_key":
            return exportSingleKey(params: params, id: id)
        case "internal.import_packet":
            return importPacket(params: params, id: id)
        case "internal.merge_reencrypt_discard_incoming":
            return mergeReencryptDiscardIncoming(params: params, id: id)
        case "internal.merge_side_by_side":
            return mergeSideBySide(params: params, id: id)
        case "internal.merge_replace_local_with_incoming":
            return mergeReplaceLocalWithIncoming(params: params, id: id)
        case "internal.enable_auto_unlock":
            return enableAutoUnlock(params: params, id: id)
        case "internal.disable_auto_unlock":
            return disableAutoUnlock(params: params, id: id)
        case "internal.is_auto_unlock_enabled":
            return isAutoUnlockEnabled(params: params, id: id)
        default:
            return errorResponse(id: id, code: "method_not_found", message: "unknown method: \(method)")
        }
    }

    // MARK: - Vault lifecycle

    private func createVault(params: [String: Any], id: Any) -> Data {
        guard let path = params["path"] as? String, let label = params["compartment_label"] as? String,
              let masterPassphrase = params["master_passphrase"] as? String
        else {
            return errorResponse(id: id, code: "invalid_params", message: "path, compartment_label and master_passphrase are required")
        }
        let profile = decodeProfile(params["profile"] as? String)
        do {
            let created = try Vault.create(path: path, compartmentLabel: label, masterPassphrase: masterPassphrase, profile: profile)
            self.vault = created
            VaultConfig.save(vaultPath: path)
            let compartments = created.listCompartments()
            return resultResponse(id: id, result: ["compartments": compartments.map(encodeCompartment)])
        } catch {
            return errorResponse(id: id, code: "create_failed", message: "\(error)")
        }
    }

    private func openVault(params: [String: Any], id: Any) -> Data {
        guard let path = params["path"] as? String else {
            return errorResponse(id: id, code: "invalid_params", message: "path is required")
        }
        do {
            let opened = try Vault.open(path: path)
            self.vault = opened
            VaultConfig.save(vaultPath: path)
            return resultResponse(id: id, result: [:])
        } catch {
            return errorResponse(id: id, code: "open_failed", message: "\(error)")
        }
    }

    private func addCompartment(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let label = params["label"] as? String, let masterPassphrase = params["master_passphrase"] as? String else {
            return errorResponse(id: id, code: "invalid_params", message: "label and master_passphrase are required")
        }
        let profile = decodeProfile(params["profile"] as? String)
        do {
            let info = try vault.addCompartment(label: label, masterPassphrase: masterPassphrase, profile: profile)
            return resultResponse(id: id, result: encodeCompartment(info))
        } catch {
            return errorResponse(id: id, code: "add_compartment_failed", message: "\(error)")
        }
    }

    // MARK: - Keys

    private func listKeys(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let compartmentId = params["compartment_id"] as? String else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id is required")
        }
        do {
            let keys = try vault.listKeys(compartmentId: compartmentId)
            return resultResponse(id: id, result: ["keys": keys.map(encodeKeyInfo)])
        } catch {
            return errorResponse(id: id, code: "list_keys_failed", message: "\(error)")
        }
    }

    private func createKey(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let compartmentId = params["compartment_id"] as? String,
              let keyType = decodeKeyType(params["key_type"] as? String),
              let purpose = decodePurpose(params["purpose"] as? String),
              let label = params["label"] as? String,
              let description = params["description"] as? String,
              let resource = params["resource"] as? String,
              let keyPassphrase = params["key_passphrase"] as? String
        else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id, key_type, purpose, label, description, resource and key_passphrase are required")
        }
        let tags = params["tags"] as? [String] ?? []
        do {
            let info = try vault.createKey(
                compartmentId: compartmentId, keyType: keyType, purpose: purpose, label: label, description: description,
                resource: resource, tags: tags, keyPassphrase: keyPassphrase, fido2RpId: nil, fido2UserHandleB64: nil
            )
            return resultResponse(id: id, result: encodeKeyInfo(info))
        } catch {
            return errorResponse(id: id, code: "create_key_failed", message: "\(error)")
        }
    }

    private func discardKey(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let compartmentId = params["compartment_id"] as? String, let keyId = params["key_id"] as? String,
              let confirmText = params["confirm_text"] as? String
        else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id, key_id and confirm_text are required")
        }
        do {
            try vault.discardKey(compartmentId: compartmentId, keyId: keyId, confirmText: confirmText)
            return resultResponse(id: id, result: [:])
        } catch {
            return errorResponse(id: id, code: "discard_key_failed", message: "\(error)")
        }
    }

    private func changeKeyPassphrase(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let compartmentId = params["compartment_id"] as? String, let keyId = params["key_id"] as? String,
              let oldPassphrase = params["old_passphrase"] as? String, let newPassphrase = params["new_passphrase"] as? String
        else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id, key_id, old_passphrase and new_passphrase are required")
        }
        do {
            try vault.changeKeyPassphrase(compartmentId: compartmentId, keyId: keyId, oldPassphrase: oldPassphrase, newPassphrase: newPassphrase)
            return resultResponse(id: id, result: [:])
        } catch {
            return errorResponse(id: id, code: "change_passphrase_failed", message: "\(error)")
        }
    }

    private func revealRawKeyHex(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let compartmentId = params["compartment_id"] as? String, let keyId = params["key_id"] as? String,
              let passphrase = params["passphrase"] as? String
        else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id, key_id and passphrase are required")
        }
        do {
            let hex = try vault.revealRawKeyHex(compartmentId: compartmentId, keyId: keyId, passphrase: passphrase)
            return resultResponse(id: id, result: ["raw_key_hex": hex])
        } catch {
            return errorResponse(id: id, code: "reveal_failed", message: "\(error)")
        }
    }

    // MARK: - Export / import / merge

    private func exportPacket(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let compartmentId = params["compartment_id"] as? String, let keyIds = params["key_ids"] as? [String],
              let includeMasterKey = params["include_master_key"] as? Bool, let encryption = decodeExportEncryption(params["encryption"])
        else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id, key_ids, include_master_key and encryption are required")
        }
        do {
            let bytes = try vault.exportPacket(compartmentId: compartmentId, keyIds: keyIds, includeMasterKey: includeMasterKey, encryption: encryption)
            return resultResponse(id: id, result: ["packet_b64": bytes.base64EncodedString()])
        } catch {
            return errorResponse(id: id, code: "export_failed", message: "\(error)")
        }
    }

    private func exportSingleKey(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let compartmentId = params["compartment_id"] as? String, let keyId = params["key_id"] as? String else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id and key_id are required")
        }
        do {
            let bytes = try vault.exportSingleKey(compartmentId: compartmentId, keyId: keyId)
            return resultResponse(id: id, result: ["packet_b64": bytes.base64EncodedString()])
        } catch {
            return errorResponse(id: id, code: "export_failed", message: "\(error)")
        }
    }

    private func importPacket(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let packetB64 = params["packet_b64"] as? String, let packetBytes = Data(base64Encoded: packetB64) else {
            return errorResponse(id: id, code: "invalid_params", message: "packet_b64 is required and must be valid base64")
        }
        let transferPassword = params["transfer_password"] as? String
        do {
            let info = try vault.importPacket(packetBytes: packetBytes, transferPassword: transferPassword)
            return resultResponse(id: id, result: encodeImportedPacketInfo(info))
        } catch {
            return errorResponse(id: id, code: "import_failed", message: "\(error)")
        }
    }

    private func mergeReencryptDiscardIncoming(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let targetCompartmentId = params["target_compartment_id"] as? String, let manifestJson = params["incoming_manifest_json"] as? String,
              let blobs = decodeIncomingKeyBlobs(params["incoming_key_blobs"])
        else {
            return errorResponse(id: id, code: "invalid_params", message: "target_compartment_id, incoming_manifest_json and incoming_key_blobs are required")
        }
        do {
            let outcome = try vault.mergeReencryptDiscardIncoming(targetCompartmentId: targetCompartmentId, incomingManifestJson: manifestJson, incomingKeyBlobs: blobs)
            return resultResponse(id: id, result: encodeMergeOutcome(outcome))
        } catch {
            return errorResponse(id: id, code: "merge_failed", message: "\(error)")
        }
    }

    private func mergeSideBySide(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let manifestJson = params["incoming_manifest_json"] as? String, let blobs = decodeIncomingKeyBlobs(params["incoming_key_blobs"]),
              let label = params["new_compartment_label"] as? String, let masterPassphrase = params["new_master_passphrase"] as? String
        else {
            return errorResponse(id: id, code: "invalid_params", message: "incoming_manifest_json, incoming_key_blobs, new_compartment_label and new_master_passphrase are required")
        }
        let profile = decodeProfile(params["profile"] as? String)
        do {
            let outcome = try vault.mergeSideBySide(
                incomingManifestJson: manifestJson, incomingKeyBlobs: blobs, newCompartmentLabel: label, newMasterPassphrase: masterPassphrase, profile: profile
            )
            return resultResponse(id: id, result: encodeMergeOutcome(outcome))
        } catch {
            return errorResponse(id: id, code: "merge_failed", message: "\(error)")
        }
    }

    private func mergeReplaceLocalWithIncoming(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let targetCompartmentId = params["target_compartment_id"] as? String, let manifestJson = params["incoming_manifest_json"] as? String,
              let blobs = decodeIncomingKeyBlobs(params["incoming_key_blobs"]), let masterPassphrase = params["incoming_master_passphrase"] as? String,
              let kdfParamsJson = params["incoming_kdf_params_json"] as? String, let confirmationPhrase = params["confirmation_phrase"] as? String
        else {
            return errorResponse(
                id: id, code: "invalid_params",
                message: "target_compartment_id, incoming_manifest_json, incoming_key_blobs, incoming_master_passphrase, incoming_kdf_params_json and confirmation_phrase are required"
            )
        }
        do {
            let outcome = try vault.mergeReplaceLocalWithIncoming(
                targetCompartmentId: targetCompartmentId, incomingManifestJson: manifestJson, incomingKeyBlobs: blobs,
                incomingMasterPassphrase: masterPassphrase, incomingKdfParamsJson: kdfParamsJson, confirmationPhrase: confirmationPhrase
            )
            return resultResponse(id: id, result: encodeMergeOutcome(outcome))
        } catch {
            return errorResponse(id: id, code: "merge_failed", message: "\(error)")
        }
    }

    // MARK: - Auto-unlock (spec §8) — Keychain + VaultConfig ownership lives here, not in the UI

    private func enableAutoUnlock(params: [String: Any], id: Any) -> Data {
        guard let vault else { return errorResponse(id: id, code: "no_vault_open", message: "no vault is currently open") }
        guard let compartmentId = params["compartment_id"] as? String, let passphrase = params["passphrase"] as? String else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id and passphrase are required")
        }
        do {
            try vault.unlockCompartment(compartmentId: compartmentId, passphrase: passphrase)
        } catch {
            return errorResponse(id: id, code: "passphrase_incorrect", message: "incorrect master passphrase; auto-unlock was not enabled")
        }
        guard AutoUnlockStore.save(passphrase: passphrase, forCompartment: compartmentId) else {
            return errorResponse(id: id, code: "keychain_write_failed", message: "couldn't save to Keychain")
        }
        VaultConfig.saveAutoUnlockCompartmentId(compartmentId)
        return resultResponse(id: id, result: [:])
    }

    private func disableAutoUnlock(params: [String: Any], id: Any) -> Data {
        guard let compartmentId = params["compartment_id"] as? String else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id is required")
        }
        AutoUnlockStore.delete(forCompartment: compartmentId)
        VaultConfig.saveAutoUnlockCompartmentId(nil)
        return resultResponse(id: id, result: [:])
    }

    private func isAutoUnlockEnabled(params: [String: Any], id: Any) -> Data {
        guard let compartmentId = params["compartment_id"] as? String else {
            return errorResponse(id: id, code: "invalid_params", message: "compartment_id is required")
        }
        return resultResponse(id: id, result: ["enabled": AutoUnlockStore.load(forCompartment: compartmentId) != nil])
    }
}

// MARK: - Encoding/decoding helpers (mirrored by Shared/ManagementClient.swift)

private func encodeCompartment(_ info: CompartmentInfo) -> [String: Any] {
    ["compartment_id": info.compartmentId, "label": info.label, "unlocked": info.unlocked]
}

private func encodeKeyInfo(_ info: KeyInfo) -> [String: Any] {
    [
        "key_id": info.keyId, "compartment_id": info.compartmentId, "label": info.label, "description": info.description,
        "resource": info.resource, "key_type": encodeKeyType(info.keyType), "purpose": encodePurpose(info.purpose),
        "created_at": info.createdAt, "last_used_at": info.lastUsedAt as Any, "tags": info.tags, "public_key_hex": info.publicKeyHex,
    ]
}

private func encodeImportedPacketInfo(_ info: ImportedPacketInfo) -> [String: Any] {
    [
        "manifest_json": info.manifestJson,
        "key_blobs": info.keyBlobs.map { ["key_id": $0.keyId, "blob_bytes_b64": $0.blobBytes.base64EncodedString()] },
        "embedded_master_compartment_id": info.embeddedMasterCompartmentId as Any,
        "embedded_master_kdf_params_json": info.embeddedMasterKdfParamsJson as Any,
    ]
}

private func encodeMergeOutcome(_ outcome: MergeOutcomeInfo) -> [String: Any] {
    [
        "warnings": outcome.warnings.map {
            ["incoming_key_id": $0.incomingKeyId, "matched_local_key_id": $0.matchedLocalKeyId, "matched_in_compartment": $0.matchedInCompartment, "reason": $0.reason]
        },
        "id_remap": outcome.idRemap.map { ["old_key_id": $0.oldKeyId, "new_key_id": $0.newKeyId] },
    ]
}

private func encodeKeyType(_ type: FacadeKeyType) -> String {
    switch type {
    case .ed25519: return "ed25519"
    case .ecdsaP256: return "ecdsa_p256"
    }
}

private func decodeKeyType(_ raw: String?) -> FacadeKeyType? {
    switch raw {
    case "ed25519": return .ed25519
    case "ecdsa_p256": return .ecdsaP256
    default: return nil
    }
}

private func encodePurpose(_ purpose: FacadePurpose) -> String {
    switch purpose {
    case .fido2: return "fido2"
    case .customSigning: return "custom_signing"
    case .both: return "both"
    }
}

private func decodePurpose(_ raw: String?) -> FacadePurpose? {
    switch raw {
    case "fido2": return .fido2
    case "custom_signing": return .customSigning
    case "both": return .both
    default: return nil
    }
}

private func decodeProfile(_ raw: String?) -> FacadeDeviceProfile {
    raw == "mobile" ? .mobile : .desktop
}

private func decodeExportEncryption(_ raw: Any?) -> FacadeExportEncryption? {
    guard let dict = raw as? [String: Any], let type = dict["type"] as? String else { return nil }
    switch type {
    case "as_is": return .asIs
    case "destination_master_password":
        guard let password = dict["password"] as? String else { return nil }
        return .destinationMasterPassword(password: password)
    case "one_time_transfer_password":
        guard let password = dict["password"] as? String else { return nil }
        return .oneTimeTransferPassword(password: password)
    default: return nil
    }
}

private func decodeIncomingKeyBlobs(_ raw: Any?) -> [IncomingKeyBlob]? {
    guard let array = raw as? [[String: Any]] else { return nil }
    var blobs: [IncomingKeyBlob] = []
    for entry in array {
        guard let keyId = entry["key_id"] as? String, let blobB64 = entry["blob_bytes_b64"] as? String, let blobBytes = Data(base64Encoded: blobB64) else {
            return nil
        }
        blobs.append(IncomingKeyBlob(keyId: keyId, blobBytes: blobBytes))
    }
    return blobs
}
