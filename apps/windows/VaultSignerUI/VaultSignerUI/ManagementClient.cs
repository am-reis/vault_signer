using System.IO.Pipes;
using System.Text.Json;
using uniffi.vaultcore;

namespace VaultSignerUI;

/// VaultSignerUI's sole means of touching vault state (spec §8: the UI
/// "requests container mutations from the service rather than writing
/// the file itself"). This app never opens a `Vault` directly — every
/// operation is one `internal.*` call to VaultSignerAgent over the same
/// named pipe the `AgentServer` listens on. Mirrors
/// apps/macos/Shared/ManagementClient.swift's shape and wire encoding
/// exactly (method names, `_id`-suffixed field names, error format), so
/// this needed no new protocol design.
///
/// Ported from macOS's core surface only, matching what
/// VaultSignerAgent/ManagementHandlers.cs actually implements this
/// session: vault/compartment/key lifecycle and auto-unlock.
/// Export/import/merge (macOS's ManagementClient has these) are not
/// ported because the agent side doesn't handle them yet either — see
/// PROGRESS.md.
internal static class ManagementClient
{
    private const string PipeName = "VaultSignerAgent";

    // MARK: - Vault lifecycle

    public static CompartmentInfo[] CreateVault(string path, string compartmentLabel, string masterPassphrase, FacadeDeviceProfile profile)
    {
        var result = Call("internal.create_vault", new Dictionary<string, object?>
        {
            ["path"] = path,
            ["compartment_label"] = compartmentLabel,
            ["master_passphrase"] = masterPassphrase,
            ["profile"] = EncodeProfile(profile),
        });
        return DecodeArray(result, "compartments", DecodeCompartment);
    }

    public static void OpenVault(string path)
    {
        Call("internal.open_vault", new Dictionary<string, object?> { ["path"] = path });
    }

    public static CompartmentInfo[] ListCompartments()
    {
        var result = Call("internal.list_compartments", new Dictionary<string, object?>());
        return DecodeArray(result, "compartments", DecodeCompartment);
    }

    public static void UnlockCompartment(string compartmentId, string passphrase)
    {
        Call("internal.unlock_compartment", new Dictionary<string, object?> { ["compartment_id"] = compartmentId, ["passphrase"] = passphrase });
    }

    public static void LockAll()
    {
        try { Call("internal.lock_all", new Dictionary<string, object?>()); } catch { /* best-effort, mirrors macOS's try? */ }
    }

    public static CompartmentInfo AddCompartment(string label, string masterPassphrase, FacadeDeviceProfile profile)
    {
        var result = Call("internal.add_compartment", new Dictionary<string, object?>
        {
            ["label"] = label,
            ["master_passphrase"] = masterPassphrase,
            ["profile"] = EncodeProfile(profile),
        });
        return DecodeCompartment(result);
    }

    // MARK: - Keys

    public static KeyInfo[] ListKeys(string compartmentId)
    {
        var result = Call("internal.list_keys", new Dictionary<string, object?> { ["compartment_id"] = compartmentId });
        return DecodeArray(result, "keys", DecodeKeyInfo);
    }

    public static KeyInfo CreateKey(
        string compartmentId, FacadeKeyType keyType, FacadePurpose purpose, string label, string description, string resource,
        string[] tags, string keyPassphrase)
    {
        var result = Call("internal.create_key", new Dictionary<string, object?>
        {
            ["compartment_id"] = compartmentId,
            ["key_type"] = EncodeKeyType(keyType),
            ["purpose"] = EncodePurpose(purpose),
            ["label"] = label,
            ["description"] = description,
            ["resource"] = resource,
            ["tags"] = tags,
            ["key_passphrase"] = keyPassphrase,
        });
        return DecodeKeyInfo(result);
    }

    public static void DiscardKey(string compartmentId, string keyId, string confirmText)
    {
        Call("internal.discard_key", new Dictionary<string, object?>
        {
            ["compartment_id"] = compartmentId, ["key_id"] = keyId, ["confirm_text"] = confirmText,
        });
    }

    public static void ChangeKeyPassphrase(string compartmentId, string keyId, string oldPassphrase, string newPassphrase)
    {
        Call("internal.change_key_passphrase", new Dictionary<string, object?>
        {
            ["compartment_id"] = compartmentId, ["key_id"] = keyId, ["old_passphrase"] = oldPassphrase, ["new_passphrase"] = newPassphrase,
        });
    }

    public static string RevealRawKeyHex(string compartmentId, string keyId, string passphrase)
    {
        var result = Call("internal.reveal_raw_key_hex", new Dictionary<string, object?>
        {
            ["compartment_id"] = compartmentId, ["key_id"] = keyId, ["passphrase"] = passphrase,
        });
        if (result.TryGetProperty("raw_key_hex", out var hex) && hex.ValueKind == JsonValueKind.String)
        {
            return hex.GetString()!;
        }
        throw new FacadeException.Failed("malformed response");
    }

    // MARK: - Export / import / merge (spec §5.2-5.4)

    public static byte[] ExportPacket(string compartmentId, string[] keyIds, bool includeMasterKey, FacadeExportEncryption encryption)
    {
        var result = Call("internal.export_packet", new Dictionary<string, object?>
        {
            ["compartment_id"] = compartmentId, ["key_ids"] = keyIds, ["include_master_key"] = includeMasterKey,
            ["encryption"] = EncodeExportEncryption(encryption),
        });
        return DecodeBase64Field(result, "packet_b64");
    }

    public static byte[] ExportSingleKey(string compartmentId, string keyId)
    {
        var result = Call("internal.export_single_key", new Dictionary<string, object?> { ["compartment_id"] = compartmentId, ["key_id"] = keyId });
        return DecodeBase64Field(result, "packet_b64");
    }

    public static ImportedPacketInfo ImportPacket(byte[] packetBytes, string? transferPassword)
    {
        var @params = new Dictionary<string, object?> { ["packet_b64"] = Convert.ToBase64String(packetBytes) };
        if (transferPassword is not null) @params["transfer_password"] = transferPassword;
        var result = Call("internal.import_packet", @params);
        return DecodeImportedPacketInfo(result);
    }

    public static MergeOutcomeInfo MergeReencryptDiscardIncoming(string targetCompartmentId, string incomingManifestJson, IncomingKeyBlob[] incomingKeyBlobs)
    {
        var result = Call("internal.merge_reencrypt_discard_incoming", new Dictionary<string, object?>
        {
            ["target_compartment_id"] = targetCompartmentId, ["incoming_manifest_json"] = incomingManifestJson,
            ["incoming_key_blobs"] = EncodeIncomingKeyBlobs(incomingKeyBlobs),
        });
        return DecodeMergeOutcome(result);
    }

    public static MergeOutcomeInfo MergeSideBySide(
        string incomingManifestJson, IncomingKeyBlob[] incomingKeyBlobs, string newCompartmentLabel, string newMasterPassphrase, FacadeDeviceProfile profile)
    {
        var result = Call("internal.merge_side_by_side", new Dictionary<string, object?>
        {
            ["incoming_manifest_json"] = incomingManifestJson, ["incoming_key_blobs"] = EncodeIncomingKeyBlobs(incomingKeyBlobs),
            ["new_compartment_label"] = newCompartmentLabel, ["new_master_passphrase"] = newMasterPassphrase, ["profile"] = EncodeProfile(profile),
        });
        return DecodeMergeOutcome(result);
    }

    public static MergeOutcomeInfo MergeReplaceLocalWithIncoming(
        string targetCompartmentId, string incomingManifestJson, IncomingKeyBlob[] incomingKeyBlobs,
        string incomingMasterPassphrase, string incomingKdfParamsJson, string confirmationPhrase)
    {
        var result = Call("internal.merge_replace_local_with_incoming", new Dictionary<string, object?>
        {
            ["target_compartment_id"] = targetCompartmentId, ["incoming_manifest_json"] = incomingManifestJson,
            ["incoming_key_blobs"] = EncodeIncomingKeyBlobs(incomingKeyBlobs), ["incoming_master_passphrase"] = incomingMasterPassphrase,
            ["incoming_kdf_params_json"] = incomingKdfParamsJson, ["confirmation_phrase"] = confirmationPhrase,
        });
        return DecodeMergeOutcome(result);
    }

    // MARK: - Auto-unlock (spec §8) — the agent owns DPAPI + VaultConfig writes for this

    public static void EnableAutoUnlock(string compartmentId, string passphrase)
    {
        Call("internal.enable_auto_unlock", new Dictionary<string, object?> { ["compartment_id"] = compartmentId, ["passphrase"] = passphrase });
    }

    public static void DisableAutoUnlock(string compartmentId)
    {
        try { Call("internal.disable_auto_unlock", new Dictionary<string, object?> { ["compartment_id"] = compartmentId }); } catch { }
    }

    public static bool IsAutoUnlockEnabled(string compartmentId)
    {
        try
        {
            var result = Call("internal.is_auto_unlock_enabled", new Dictionary<string, object?> { ["compartment_id"] = compartmentId });
            return result.TryGetProperty("enabled", out var enabled) && enabled.ValueKind == JsonValueKind.True;
        }
        catch
        {
            return false;
        }
    }

    // MARK: - Autostart (spec §8's other independent toggle)

    public static void EnableAutostart()
    {
        Call("internal.enable_autostart", new Dictionary<string, object?>());
    }

    public static void DisableAutostart()
    {
        try { Call("internal.disable_autostart", new Dictionary<string, object?>()); } catch { }
    }

    public static bool IsAutostartEnabled()
    {
        try
        {
            var result = Call("internal.is_autostart_enabled", new Dictionary<string, object?>());
            return result.TryGetProperty("enabled", out var enabled) && enabled.ValueKind == JsonValueKind.True;
        }
        catch
        {
            return false;
        }
    }

    // MARK: - Transport

    private static JsonElement Call(string method, Dictionary<string, object?> @params)
    {
        using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut);
        try
        {
            pipe.Connect(3000);
        }
        catch (TimeoutException)
        {
            throw new FacadeException.Failed("VaultSignerAgent isn't running");
        }

        var request = new Dictionary<string, object?> { ["method"] = method, ["params"] = @params, ["id"] = 1 };
        var requestBytes = JsonSerializer.SerializeToUtf8Bytes(request);
        var framed = new byte[requestBytes.Length + 1];
        requestBytes.CopyTo(framed, 0);
        framed[^1] = (byte)'\n';
        pipe.Write(framed, 0, framed.Length);
        pipe.Flush();

        var buffer = new List<byte>();
        var chunk = new byte[4096];
        int newlineIndex;
        while ((newlineIndex = buffer.IndexOf((byte)'\n')) < 0)
        {
            var n = pipe.Read(chunk, 0, chunk.Length);
            if (n <= 0) throw new FacadeException.Failed("VaultSignerAgent closed the connection unexpectedly");
            buffer.AddRange(chunk.AsSpan(0, n).ToArray());
        }

        var responseBytes = buffer.GetRange(0, newlineIndex).ToArray();
        using var doc = JsonDocument.Parse(responseBytes);
        var root = doc.RootElement;
        if (root.TryGetProperty("error", out var error))
        {
            var code = error.TryGetProperty("code", out var c) ? c.GetString() : "unknown_error";
            var message = error.TryGetProperty("message", out var m) ? m.GetString() : "unknown error";
            throw new FacadeException.Failed($"{code}: {message}");
        }
        return root.TryGetProperty("result", out var result) ? result.Clone() : default;
    }

    // MARK: - Encoding/decoding helpers (mirrored by VaultSignerAgent's ManagementHandlers.cs)

    private static string EncodeProfile(FacadeDeviceProfile profile) => profile switch
    {
        FacadeDeviceProfile.Desktop => "desktop",
        FacadeDeviceProfile.Mobile => "mobile",
        _ => throw new ArgumentOutOfRangeException(nameof(profile)),
    };

    private static string EncodeKeyType(FacadeKeyType type) => type switch
    {
        FacadeKeyType.Ed25519 => "ed25519",
        FacadeKeyType.EcdsaP256 => "ecdsa_p256",
        _ => throw new ArgumentOutOfRangeException(nameof(type)),
    };

    private static FacadeKeyType DecodeKeyType(string raw) => raw switch
    {
        "ed25519" => FacadeKeyType.Ed25519,
        "ecdsa_p256" => FacadeKeyType.EcdsaP256,
        _ => throw new FacadeException.Failed($"unknown key_type: {raw}"),
    };

    private static string EncodePurpose(FacadePurpose purpose) => purpose switch
    {
        FacadePurpose.Fido2 => "fido2",
        FacadePurpose.CustomSigning => "custom_signing",
        FacadePurpose.Both => "both",
        _ => throw new ArgumentOutOfRangeException(nameof(purpose)),
    };

    private static FacadePurpose DecodePurpose(string raw) => raw switch
    {
        "fido2" => FacadePurpose.Fido2,
        "custom_signing" => FacadePurpose.CustomSigning,
        "both" => FacadePurpose.Both,
        _ => throw new FacadeException.Failed($"unknown purpose: {raw}"),
    };

    private static CompartmentInfo DecodeCompartment(JsonElement obj)
    {
        if (!obj.TryGetProperty("compartment_id", out var id) || id.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("label", out var label) || label.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("unlocked", out var unlocked))
        {
            throw new FacadeException.Failed("malformed compartment in response");
        }
        return new CompartmentInfo(id.GetString()!, label.GetString()!, unlocked.ValueKind == JsonValueKind.True);
    }

    private static KeyInfo DecodeKeyInfo(JsonElement obj)
    {
        if (!obj.TryGetProperty("key_id", out var keyId) || keyId.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("compartment_id", out var compartmentId) || compartmentId.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("label", out var label) || label.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("description", out var description) || description.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("resource", out var resource) || resource.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("key_type", out var keyTypeRaw) || keyTypeRaw.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("purpose", out var purposeRaw) || purposeRaw.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("created_at", out var createdAt) || createdAt.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("public_key_hex", out var publicKeyHex) || publicKeyHex.ValueKind != JsonValueKind.String)
        {
            throw new FacadeException.Failed("malformed key in response");
        }
        var tags = obj.TryGetProperty("tags", out var tagsEl) && tagsEl.ValueKind == JsonValueKind.Array
            ? tagsEl.EnumerateArray().Select(e => e.GetString() ?? "").ToArray()
            : [];
        var lastUsedAt = obj.TryGetProperty("last_used_at", out var lastUsedEl) && lastUsedEl.ValueKind == JsonValueKind.String
            ? lastUsedEl.GetString()
            : null;
        return new KeyInfo(
            keyId.GetString()!, compartmentId.GetString()!, label.GetString()!, description.GetString()!, resource.GetString()!,
            DecodeKeyType(keyTypeRaw.GetString()!), DecodePurpose(purposeRaw.GetString()!), null, createdAt.GetString()!,
            lastUsedAt, tags, publicKeyHex.GetString()!);
    }

    private static T[] DecodeArray<T>(JsonElement result, string key, Func<JsonElement, T> decode)
    {
        if (!result.TryGetProperty(key, out var array) || array.ValueKind != JsonValueKind.Array)
        {
            throw new FacadeException.Failed("malformed list in response");
        }
        return array.EnumerateArray().Select(decode).ToArray();
    }

    // MARK: - Export/import/merge encoding (mirrored by VaultSignerAgent's
    // ManagementHandlers.cs — same field names, same "type" discriminator
    // shape for FacadeExportEncryption)

    private static Dictionary<string, object?> EncodeExportEncryption(FacadeExportEncryption encryption) => encryption switch
    {
        FacadeExportEncryption.AsIs => new Dictionary<string, object?> { ["type"] = "as_is" },
        FacadeExportEncryption.DestinationMasterPassword p => new Dictionary<string, object?> { ["type"] = "destination_master_password", ["password"] = p.password },
        FacadeExportEncryption.OneTimeTransferPassword p => new Dictionary<string, object?> { ["type"] = "one_time_transfer_password", ["password"] = p.password },
        _ => throw new ArgumentOutOfRangeException(nameof(encryption)),
    };

    private static object[] EncodeIncomingKeyBlobs(IncomingKeyBlob[] blobs) =>
        blobs.Select(b => new Dictionary<string, object?> { ["key_id"] = b.keyId, ["blob_bytes_b64"] = Convert.ToBase64String(b.blobBytes) }).ToArray<object>();

    private static byte[] DecodeBase64Field(JsonElement result, string key)
    {
        if (result.TryGetProperty(key, out var el) && el.ValueKind == JsonValueKind.String)
        {
            return Convert.FromBase64String(el.GetString()!);
        }
        throw new FacadeException.Failed("malformed response");
    }

    private static ImportedPacketInfo DecodeImportedPacketInfo(JsonElement obj)
    {
        if (!obj.TryGetProperty("manifest_json", out var manifestJson) || manifestJson.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("key_blobs", out var blobsEl) || blobsEl.ValueKind != JsonValueKind.Array)
        {
            throw new FacadeException.Failed("malformed import result");
        }
        var keyBlobs = blobsEl.EnumerateArray().Select(DecodeIncomingKeyBlob).ToArray();
        var embeddedMasterCompartmentId = obj.TryGetProperty("embedded_master_compartment_id", out var c) && c.ValueKind == JsonValueKind.String ? c.GetString() : null;
        var embeddedMasterKdfParamsJson = obj.TryGetProperty("embedded_master_kdf_params_json", out var k) && k.ValueKind == JsonValueKind.String ? k.GetString() : null;
        return new ImportedPacketInfo(manifestJson.GetString()!, keyBlobs, embeddedMasterCompartmentId, embeddedMasterKdfParamsJson);
    }

    private static IncomingKeyBlob DecodeIncomingKeyBlob(JsonElement obj)
    {
        if (!obj.TryGetProperty("key_id", out var keyId) || keyId.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("blob_bytes_b64", out var blobB64) || blobB64.ValueKind != JsonValueKind.String)
        {
            throw new FacadeException.Failed("malformed key blob in import result");
        }
        return new IncomingKeyBlob(keyId.GetString()!, Convert.FromBase64String(blobB64.GetString()!));
    }

    private static MergeOutcomeInfo DecodeMergeOutcome(JsonElement obj)
    {
        if (!obj.TryGetProperty("warnings", out var warningsEl) || warningsEl.ValueKind != JsonValueKind.Array ||
            !obj.TryGetProperty("id_remap", out var remapEl) || remapEl.ValueKind != JsonValueKind.Array)
        {
            throw new FacadeException.Failed("malformed merge result");
        }
        var warnings = warningsEl.EnumerateArray().Select(DecodeDuplicateWarning).ToArray();
        var idRemap = remapEl.EnumerateArray().Select(DecodeIdRemapEntry).ToArray();
        return new MergeOutcomeInfo(warnings, idRemap);
    }

    private static DuplicateWarningInfo DecodeDuplicateWarning(JsonElement obj)
    {
        if (!obj.TryGetProperty("incoming_key_id", out var incomingKeyId) || incomingKeyId.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("matched_local_key_id", out var matchedLocalKeyId) || matchedLocalKeyId.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("matched_in_compartment", out var matchedInCompartment) || matchedInCompartment.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("reason", out var reason) || reason.ValueKind != JsonValueKind.String)
        {
            throw new FacadeException.Failed("malformed merge warning");
        }
        return new DuplicateWarningInfo(incomingKeyId.GetString()!, matchedLocalKeyId.GetString()!, matchedInCompartment.GetString()!, reason.GetString()!);
    }

    private static IdRemapEntry DecodeIdRemapEntry(JsonElement obj)
    {
        if (!obj.TryGetProperty("old_key_id", out var oldKeyId) || oldKeyId.ValueKind != JsonValueKind.String ||
            !obj.TryGetProperty("new_key_id", out var newKeyId) || newKeyId.ValueKind != JsonValueKind.String)
        {
            throw new FacadeException.Failed("malformed id_remap entry");
        }
        return new IdRemapEntry(oldKeyId.GetString()!, newKeyId.GetString()!);
    }
}
