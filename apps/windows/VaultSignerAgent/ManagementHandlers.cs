using System.Text.Json;
using uniffi.vaultcore;

namespace VaultSignerAgent;

/// The `internal.*` management surface VaultSignerUI calls instead of
/// ever opening a `Vault` itself (spec §8: the agent is "the sole writer
/// of the container file"). Mirrors
/// apps/macos/VaultSignerAgent/Sources/ManagementHandlers.swift's
/// method-for-method shape and wire encoding (manual JSON object,
/// `_b64`-suffixed byte fields) so `Shared/ManagementClient`-equivalent
/// code on the UI side needs no new convention.
///
/// **Ported from macOS: vault/compartment/key lifecycle, auto-unlock,
/// and export/import/merge (spec item 3.1, mirroring macOS 2.1 and
/// 2.3-2.5).** `vaultcore::packet`/`merge` themselves are unchanged and
/// already exercised by 108+ passing vaultcore tests — this file's
/// export/import/merge handlers are a mechanical port of
/// ManagementHandlers.swift's equivalents (same method names, same
/// wire field names), not new logic.
internal sealed class ManagementHandlers
{
    private readonly AgentServer _server;

    public ManagementHandlers(AgentServer server)
    {
        _server = server;
    }

    private Vault? Vault => _server.Vault;

    public byte[] Handle(string method, JsonElement @params, JsonElement id)
    {
        try
        {
            return method switch
            {
                "internal.create_vault" => CreateVault(@params, id),
                "internal.open_vault" => OpenVault(@params, id),
                "internal.list_compartments" => ListCompartments(id),
                "internal.unlock_compartment" => UnlockCompartment(@params, id),
                "internal.lock_all" => LockAll(id),
                "internal.add_compartment" => AddCompartment(@params, id),
                "internal.list_keys" => ListKeys(@params, id),
                "internal.create_key" => CreateKey(@params, id),
                "internal.discard_key" => DiscardKey(@params, id),
                "internal.change_key_passphrase" => ChangeKeyPassphrase(@params, id),
                "internal.reveal_raw_key_hex" => RevealRawKeyHex(@params, id),
                "internal.export_packet" => ExportPacket(@params, id),
                "internal.export_single_key" => ExportSingleKey(@params, id),
                "internal.import_packet" => ImportPacket(@params, id),
                "internal.merge_reencrypt_discard_incoming" => MergeReencryptDiscardIncoming(@params, id),
                "internal.merge_side_by_side" => MergeSideBySide(@params, id),
                "internal.merge_replace_local_with_incoming" => MergeReplaceLocalWithIncoming(@params, id),
                "internal.enable_auto_unlock" => EnableAutoUnlock(@params, id),
                "internal.disable_auto_unlock" => DisableAutoUnlock(@params, id),
                "internal.is_auto_unlock_enabled" => IsAutoUnlockEnabled(@params, id),
                _ => AgentServer.ErrorResponse(id, "method_not_found", $"unknown method: {method}"),
            };
        }
        catch (FacadeException e)
        {
            // Every vaultcore facade error surfaces through here uniformly
            // (mirrors Swift's `catch { "\(error)" }` — the underlying
            // FacadeError already carries a human-readable message).
            return AgentServer.ErrorResponse(id, "vault_error", e.Message);
        }
    }

    // MARK: Vault lifecycle

    private byte[] CreateVault(JsonElement p, JsonElement id)
    {
        if (!TryGetString(p, "path", out var path) ||
            !TryGetString(p, "compartment_label", out var label) ||
            !TryGetString(p, "master_passphrase", out var masterPassphrase))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "path, compartment_label and master_passphrase are required");
        }
        var profile = DecodeProfile(GetStringOrNull(p, "profile"));
        var created = Vault.Create(path, label, masterPassphrase, profile);
        _server.Vault = created;
        VaultConfig.SaveVaultPath(path);
        var compartments = created.ListCompartments();
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>
        {
            ["compartments"] = Array.ConvertAll(compartments, EncodeCompartment),
        });
    }

    private byte[] OpenVault(JsonElement p, JsonElement id)
    {
        if (!TryGetString(p, "path", out var path))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "path is required");
        }
        var opened = Vault.Open(path);
        _server.Vault = opened;
        VaultConfig.SaveVaultPath(path);
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>());
    }

    private byte[] ListCompartments(JsonElement id)
    {
        var compartments = Vault?.ListCompartments() ?? [];
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>
        {
            ["compartments"] = Array.ConvertAll(compartments, EncodeCompartment),
        });
    }

    private byte[] UnlockCompartment(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId) || !TryGetString(p, "passphrase", out var passphrase))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id and passphrase are required");
        }
        vault.UnlockCompartment(compartmentId, passphrase);
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>());
    }

    private byte[] LockAll(JsonElement id)
    {
        Vault?.LockAll();
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>());
    }

    private byte[] AddCompartment(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "label", out var label) || !TryGetString(p, "master_passphrase", out var masterPassphrase))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "label and master_passphrase are required");
        }
        var profile = DecodeProfile(GetStringOrNull(p, "profile"));
        var info = vault.AddCompartment(label, masterPassphrase, profile);
        return AgentServer.ResultResponse(id, EncodeCompartment(info));
    }

    // MARK: Keys

    private byte[] ListKeys(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id is required");
        }
        var keys = vault.ListKeys(compartmentId);
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>
        {
            ["keys"] = Array.ConvertAll(keys, EncodeKeyInfo),
        });
    }

    private byte[] CreateKey(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId) ||
            DecodeKeyType(GetStringOrNull(p, "key_type")) is not { } keyType ||
            DecodePurpose(GetStringOrNull(p, "purpose")) is not { } purpose ||
            !TryGetString(p, "label", out var label) ||
            !TryGetString(p, "description", out var description) ||
            !TryGetString(p, "resource", out var resource) ||
            !TryGetString(p, "key_passphrase", out var keyPassphrase))
        {
            return AgentServer.ErrorResponse(id, "invalid_params",
                "compartment_id, key_type, purpose, label, description, resource and key_passphrase are required");
        }
        var tags = GetStringArray(p, "tags");
        var info = vault.CreateKey(
            compartmentId, keyType, purpose, label, description, resource, tags, keyPassphrase,
            fido2RpId: null, fido2UserHandleB64: null);
        return AgentServer.ResultResponse(id, EncodeKeyInfo(info));
    }

    private byte[] DiscardKey(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId) || !TryGetString(p, "key_id", out var keyId) ||
            !TryGetString(p, "confirm_text", out var confirmText))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id, key_id and confirm_text are required");
        }
        vault.DiscardKey(compartmentId, keyId, confirmText);
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>());
    }

    private byte[] ChangeKeyPassphrase(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId) || !TryGetString(p, "key_id", out var keyId) ||
            !TryGetString(p, "old_passphrase", out var oldPassphrase) || !TryGetString(p, "new_passphrase", out var newPassphrase))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id, key_id, old_passphrase and new_passphrase are required");
        }
        vault.ChangeKeyPassphrase(compartmentId, keyId, oldPassphrase, newPassphrase);
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>());
    }

    private byte[] RevealRawKeyHex(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId) || !TryGetString(p, "key_id", out var keyId) ||
            !TryGetString(p, "passphrase", out var passphrase))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id, key_id and passphrase are required");
        }
        var hex = vault.RevealRawKeyHex(compartmentId, keyId, passphrase);
        return AgentServer.ResultResponse(id, new Dictionary<string, object?> { ["raw_key_hex"] = hex });
    }

    // MARK: Export / import / merge (spec §5.2-5.4) — mirrors
    // ManagementHandlers.swift's equivalents field-for-field; the actual
    // export/import/merge logic lives once in vaultcore (spec §5.3.6:
    // "implemented once in vaultcore ... invoked identically by every
    // platform"), never reimplemented here.

    private byte[] ExportPacket(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId) ||
            !TryGetStringArray(p, "key_ids", out var keyIds) ||
            !TryGetBool(p, "include_master_key", out var includeMasterKey) ||
            DecodeExportEncryption(p, "encryption") is not { } encryption)
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id, key_ids, include_master_key and encryption are required");
        }
        try
        {
            var bytes = vault.ExportPacket(compartmentId, keyIds, includeMasterKey, encryption);
            return AgentServer.ResultResponse(id, new Dictionary<string, object?> { ["packet_b64"] = Convert.ToBase64String(bytes) });
        }
        catch (FacadeException e)
        {
            return AgentServer.ErrorResponse(id, "export_failed", e.Message);
        }
    }

    private byte[] ExportSingleKey(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId) || !TryGetString(p, "key_id", out var keyId))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id and key_id are required");
        }
        try
        {
            var bytes = vault.ExportSingleKey(compartmentId, keyId);
            return AgentServer.ResultResponse(id, new Dictionary<string, object?> { ["packet_b64"] = Convert.ToBase64String(bytes) });
        }
        catch (FacadeException e)
        {
            return AgentServer.ErrorResponse(id, "export_failed", e.Message);
        }
    }

    private byte[] ImportPacket(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "packet_b64", out var packetB64))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "packet_b64 is required and must be valid base64");
        }
        byte[] packetBytes;
        try
        {
            packetBytes = Convert.FromBase64String(packetB64);
        }
        catch (FormatException)
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "packet_b64 is required and must be valid base64");
        }
        var transferPassword = GetStringOrNull(p, "transfer_password");
        try
        {
            var info = vault.ImportPacket(packetBytes, transferPassword);
            return AgentServer.ResultResponse(id, EncodeImportedPacketInfo(info));
        }
        catch (FacadeException e)
        {
            return AgentServer.ErrorResponse(id, "import_failed", e.Message);
        }
    }

    private byte[] MergeReencryptDiscardIncoming(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "target_compartment_id", out var targetCompartmentId) ||
            !TryGetString(p, "incoming_manifest_json", out var manifestJson) ||
            DecodeIncomingKeyBlobs(p, "incoming_key_blobs") is not { } blobs)
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "target_compartment_id, incoming_manifest_json and incoming_key_blobs are required");
        }
        try
        {
            var outcome = vault.MergeReencryptDiscardIncoming(targetCompartmentId, manifestJson, blobs);
            return AgentServer.ResultResponse(id, EncodeMergeOutcome(outcome));
        }
        catch (FacadeException e)
        {
            return AgentServer.ErrorResponse(id, "merge_failed", e.Message);
        }
    }

    private byte[] MergeSideBySide(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "incoming_manifest_json", out var manifestJson) ||
            DecodeIncomingKeyBlobs(p, "incoming_key_blobs") is not { } blobs ||
            !TryGetString(p, "new_compartment_label", out var label) ||
            !TryGetString(p, "new_master_passphrase", out var masterPassphrase))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "incoming_manifest_json, incoming_key_blobs, new_compartment_label and new_master_passphrase are required");
        }
        var profile = DecodeProfile(GetStringOrNull(p, "profile"));
        try
        {
            var outcome = vault.MergeSideBySide(manifestJson, blobs, label, masterPassphrase, profile);
            return AgentServer.ResultResponse(id, EncodeMergeOutcome(outcome));
        }
        catch (FacadeException e)
        {
            return AgentServer.ErrorResponse(id, "merge_failed", e.Message);
        }
    }

    private byte[] MergeReplaceLocalWithIncoming(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "target_compartment_id", out var targetCompartmentId) ||
            !TryGetString(p, "incoming_manifest_json", out var manifestJson) ||
            DecodeIncomingKeyBlobs(p, "incoming_key_blobs") is not { } blobs ||
            !TryGetString(p, "incoming_master_passphrase", out var incomingMasterPassphrase) ||
            !TryGetString(p, "incoming_kdf_params_json", out var incomingKdfParamsJson) ||
            !TryGetString(p, "confirmation_phrase", out var confirmationPhrase))
        {
            return AgentServer.ErrorResponse(
                id, "invalid_params",
                "target_compartment_id, incoming_manifest_json, incoming_key_blobs, incoming_master_passphrase, incoming_kdf_params_json and confirmation_phrase are required");
        }
        try
        {
            var outcome = vault.MergeReplaceLocalWithIncoming(
                targetCompartmentId, manifestJson, blobs, incomingMasterPassphrase, incomingKdfParamsJson, confirmationPhrase);
            return AgentServer.ResultResponse(id, EncodeMergeOutcome(outcome));
        }
        catch (FacadeException e)
        {
            return AgentServer.ErrorResponse(id, "merge_failed", e.Message);
        }
    }

    // MARK: Auto-unlock (spec §8) — DpapiAutoUnlockStore + VaultConfig ownership lives here, not in the UI

    private byte[] EnableAutoUnlock(JsonElement p, JsonElement id)
    {
        if (Vault is not { } vault) return NoVaultOpen(id);
        if (!TryGetString(p, "compartment_id", out var compartmentId) || !TryGetString(p, "passphrase", out var passphrase))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id and passphrase are required");
        }
        try
        {
            vault.UnlockCompartment(compartmentId, passphrase);
        }
        catch (FacadeException)
        {
            return AgentServer.ErrorResponse(id, "passphrase_incorrect", "incorrect master passphrase; auto-unlock was not enabled");
        }
        if (!DpapiAutoUnlockStore.Save(passphrase, compartmentId))
        {
            return AgentServer.ErrorResponse(id, "dpapi_write_failed", "couldn't save the DPAPI-protected auto-unlock secret");
        }
        VaultConfig.SaveAutoUnlockCompartmentId(compartmentId);
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>());
    }

    private byte[] DisableAutoUnlock(JsonElement p, JsonElement id)
    {
        if (!TryGetString(p, "compartment_id", out var compartmentId))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id is required");
        }
        DpapiAutoUnlockStore.Delete(compartmentId);
        VaultConfig.SaveAutoUnlockCompartmentId(null);
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>());
    }

    private byte[] IsAutoUnlockEnabled(JsonElement p, JsonElement id)
    {
        if (!TryGetString(p, "compartment_id", out var compartmentId))
        {
            return AgentServer.ErrorResponse(id, "invalid_params", "compartment_id is required");
        }
        return AgentServer.ResultResponse(id, new Dictionary<string, object?>
        {
            ["enabled"] = DpapiAutoUnlockStore.Load(compartmentId) is not null,
        });
    }

    private byte[] NoVaultOpen(JsonElement id) => AgentServer.ErrorResponse(id, "no_vault_open", "no vault is currently open");

    // MARK: Encoding/decoding helpers (mirrored by the UI's own client code)

    private static Dictionary<string, object?> EncodeCompartment(CompartmentInfo info) => new()
    {
        ["compartment_id"] = info.compartmentId,
        ["label"] = info.label,
        ["unlocked"] = info.unlocked,
    };

    private static Dictionary<string, object?> EncodeKeyInfo(KeyInfo info) => new()
    {
        ["key_id"] = info.keyId,
        ["compartment_id"] = info.compartmentId,
        ["label"] = info.label,
        ["description"] = info.description,
        ["resource"] = info.resource,
        ["key_type"] = EncodeKeyType(info.keyType),
        ["purpose"] = EncodePurpose(info.purpose),
        ["created_at"] = info.createdAt,
        ["last_used_at"] = info.lastUsedAt,
        ["tags"] = info.tags,
        ["public_key_hex"] = info.publicKeyHex,
    };

    private static string EncodeKeyType(FacadeKeyType type) => type switch
    {
        FacadeKeyType.Ed25519 => "ed25519",
        FacadeKeyType.EcdsaP256 => "ecdsa_p256",
        _ => throw new ArgumentOutOfRangeException(nameof(type)),
    };

    private static FacadeKeyType? DecodeKeyType(string? raw) => raw switch
    {
        "ed25519" => FacadeKeyType.Ed25519,
        "ecdsa_p256" => FacadeKeyType.EcdsaP256,
        _ => null,
    };

    private static string EncodePurpose(FacadePurpose purpose) => purpose switch
    {
        FacadePurpose.Fido2 => "fido2",
        FacadePurpose.CustomSigning => "custom_signing",
        FacadePurpose.Both => "both",
        _ => throw new ArgumentOutOfRangeException(nameof(purpose)),
    };

    private static FacadePurpose? DecodePurpose(string? raw) => raw switch
    {
        "fido2" => FacadePurpose.Fido2,
        "custom_signing" => FacadePurpose.CustomSigning,
        "both" => FacadePurpose.Both,
        _ => null,
    };

    private static FacadeDeviceProfile DecodeProfile(string? raw) => raw == "mobile" ? FacadeDeviceProfile.Mobile : FacadeDeviceProfile.Desktop;

    private static bool TryGetString(JsonElement obj, string key, out string value)
    {
        value = "";
        if (obj.ValueKind != JsonValueKind.Object) return false;
        if (!obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.String) return false;
        value = el.GetString()!;
        return true;
    }

    private static string? GetStringOrNull(JsonElement obj, string key)
    {
        if (obj.ValueKind != JsonValueKind.Object) return null;
        return obj.TryGetProperty(key, out var el) && el.ValueKind == JsonValueKind.String ? el.GetString() : null;
    }

    private static string[] GetStringArray(JsonElement obj, string key)
    {
        var result = new List<string>();
        if (obj.ValueKind != JsonValueKind.Object) return result.ToArray();
        if (!obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.Array) return result.ToArray();
        foreach (var item in el.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String) result.Add(item.GetString()!);
        }
        return result.ToArray();
    }

    private static bool TryGetStringArray(JsonElement obj, string key, out string[] value)
    {
        value = [];
        if (obj.ValueKind != JsonValueKind.Object) return false;
        if (!obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.Array) return false;
        var result = new List<string>();
        foreach (var item in el.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String) return false;
            result.Add(item.GetString()!);
        }
        value = result.ToArray();
        return true;
    }

    private static bool TryGetBool(JsonElement obj, string key, out bool value)
    {
        value = false;
        if (obj.ValueKind != JsonValueKind.Object) return false;
        if (!obj.TryGetProperty(key, out var el) || (el.ValueKind != JsonValueKind.True && el.ValueKind != JsonValueKind.False)) return false;
        value = el.ValueKind == JsonValueKind.True;
        return true;
    }

    // MARK: Export/import/merge encoding — field names mirror
    // ManagementHandlers.swift's encodeExportEncryption/encodeImportedPacketInfo/
    // encodeMergeOutcome/decodeIncomingKeyBlobs exactly, so ManagementClient.cs
    // (this app's UI side) needs no new wire convention.

    private static FacadeExportEncryption? DecodeExportEncryption(JsonElement obj, string key)
    {
        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.Object) return null;
        if (!el.TryGetProperty("type", out var typeEl) || typeEl.ValueKind != JsonValueKind.String) return null;
        return typeEl.GetString() switch
        {
            "as_is" => new FacadeExportEncryption.AsIs(),
            "destination_master_password" when TryGetString(el, "password", out var p1) => new FacadeExportEncryption.DestinationMasterPassword(p1),
            "one_time_transfer_password" when TryGetString(el, "password", out var p2) => new FacadeExportEncryption.OneTimeTransferPassword(p2),
            _ => null,
        };
    }

    private static IncomingKeyBlob[]? DecodeIncomingKeyBlobs(JsonElement obj, string key)
    {
        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.Array) return null;
        var result = new List<IncomingKeyBlob>();
        foreach (var item in el.EnumerateArray())
        {
            if (!TryGetString(item, "key_id", out var keyId) || !TryGetString(item, "blob_bytes_b64", out var blobB64)) return null;
            byte[] blobBytes;
            try { blobBytes = Convert.FromBase64String(blobB64); }
            catch (FormatException) { return null; }
            result.Add(new IncomingKeyBlob(keyId, blobBytes));
        }
        return result.ToArray();
    }

    private static Dictionary<string, object?> EncodeImportedPacketInfo(ImportedPacketInfo info) => new()
    {
        ["manifest_json"] = info.manifestJson,
        ["key_blobs"] = info.keyBlobs.Select(EncodeIncomingKeyBlob).ToArray(),
        ["embedded_master_compartment_id"] = info.embeddedMasterCompartmentId,
        ["embedded_master_kdf_params_json"] = info.embeddedMasterKdfParamsJson,
    };

    private static Dictionary<string, object?> EncodeIncomingKeyBlob(IncomingKeyBlob blob) => new()
    {
        ["key_id"] = blob.keyId,
        ["blob_bytes_b64"] = Convert.ToBase64String(blob.blobBytes),
    };

    private static Dictionary<string, object?> EncodeMergeOutcome(MergeOutcomeInfo outcome) => new()
    {
        ["warnings"] = outcome.warnings.Select(w => new Dictionary<string, object?>
        {
            ["incoming_key_id"] = w.incomingKeyId,
            ["matched_local_key_id"] = w.matchedLocalKeyId,
            ["matched_in_compartment"] = w.matchedInCompartment,
            ["reason"] = w.reason,
        }).ToArray(),
        ["id_remap"] = outcome.idRemap.Select(r => new Dictionary<string, object?>
        {
            ["old_key_id"] = r.oldKeyId,
            ["new_key_id"] = r.newKeyId,
        }).ToArray(),
    };
}
