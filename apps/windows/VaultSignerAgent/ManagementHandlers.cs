using System.Text.Json;
using VaultSigner.Core;

namespace VaultSignerAgent;

/// The `internal.*` management surface VaultSignerUI calls instead of
/// ever opening a `Vault` itself (spec §8: the agent is "the sole writer
/// of the container file"). Mirrors
/// apps/macos/VaultSignerAgent/Sources/ManagementHandlers.swift's
/// method-for-method shape and wire encoding (manual JSON object,
/// `_b64`-suffixed byte fields) so `Shared/ManagementClient`-equivalent
/// code on the UI side needs no new convention.
///
/// **Ported from macOS this session: vault/compartment/key lifecycle and
/// auto-unlock (spec item 3.1's core, mirroring macOS 2.1).** **Not yet
/// ported: export/import/merge (`internal.export_packet` and friends,
/// mirroring macOS 2.3-2.5)** — left out to keep this session's surface
/// testable end-to-end rather than half-verified across a larger set;
/// `vaultcore::packet`/`merge` themselves are unchanged and already
/// exercised by 108+ passing vaultcore tests, so wiring them up here
/// later is mechanical, not exploratory.
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
                "internal.enable_auto_unlock" => EnableAutoUnlock(@params, id),
                "internal.disable_auto_unlock" => DisableAutoUnlock(@params, id),
                "internal.is_auto_unlock_enabled" => IsAutoUnlockEnabled(@params, id),
                _ => AgentServer.ErrorResponse(id, "method_not_found", $"unknown method: {method}"),
            };
        }
        catch (VaultException e)
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
            ["compartments"] = compartments.ConvertAll(EncodeCompartment),
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
            ["compartments"] = compartments.ConvertAll(EncodeCompartment),
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
            ["keys"] = keys.ConvertAll(EncodeKeyInfo),
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
        catch (VaultException)
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
        ["compartment_id"] = info.CompartmentId,
        ["label"] = info.Label,
        ["unlocked"] = info.Unlocked,
    };

    private static Dictionary<string, object?> EncodeKeyInfo(KeyInfo info) => new()
    {
        ["key_id"] = info.KeyId,
        ["compartment_id"] = info.CompartmentId,
        ["label"] = info.Label,
        ["description"] = info.Description,
        ["resource"] = info.Resource,
        ["key_type"] = EncodeKeyType(info.KeyType),
        ["purpose"] = EncodePurpose(info.Purpose),
        ["created_at"] = info.CreatedAt,
        ["last_used_at"] = info.LastUsedAt,
        ["tags"] = info.Tags,
        ["public_key_hex"] = info.PublicKeyHex,
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

    private static List<string> GetStringArray(JsonElement obj, string key)
    {
        var result = new List<string>();
        if (obj.ValueKind != JsonValueKind.Object) return result;
        if (!obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.Array) return result;
        foreach (var item in el.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String) result.Add(item.GetString()!);
        }
        return result;
    }
}
