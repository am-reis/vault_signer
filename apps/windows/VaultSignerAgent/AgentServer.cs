using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using VaultSigner.Core;

namespace VaultSignerAgent;

/// The background agent (spec §8): owns the single `Vault` instance —
/// no other process ever opens the container file — its retention
/// cache/throttle state, and the custom local signing protocol's
/// transport (spec §7: "a named pipe (Windows)"). Framing is
/// newline-delimited JSON, exactly matching
/// apps/macos/VaultSignerAgent/Sources/AgentServer.swift and the
/// `vaultcore::protocol` message shapes.
///
/// **Architecture note — why this is not a Windows *Service* despite
/// spec §12 item 3.3 saying "Windows Service":** a real Service-Control-
/// Manager-managed service runs in Session 0 with no desktop access
/// (Session 0 isolation, since Windows Vista) — it structurally cannot
/// show the interactive passphrase-prompt dialog spec §7/§8 require.
/// macOS's own "background service" is a **per-user `launchd` agent**,
/// not a system daemon — it runs inside the logged-in user's own
/// session precisely so `AlertPassphrasePrompter` can show a real
/// `NSAlert`. This process is the direct Windows equivalent of *that*:
/// a per-user background process, started at logon in the interactive
/// session (see `AutostartManager`), not an SCM service. DPAPI's
/// `CurrentUser` scope (`DpapiAutoUnlockStore`) only makes sense paired
/// with this model too — it's keyed to the logged-in user, not to a
/// SYSTEM-level service identity. Named the same as macOS's agent for
/// the same reason it plays the same role, not because it's registered
/// the same way at the OS level.
///
/// Method namespace: `vaultsigner.*` requests go straight to
/// `vault.HandleProtocolRequest`, unchanged from spec §7. `internal.*`
/// methods are this agent's own management namespace (spec §8) —
/// VaultSignerUI never opens a `Vault` of its own; every vault operation
/// it performs is one of these calls (see `ManagementHandlers`). Real
/// callers are authenticated via `PeerAuthentication` — see that file
/// for exactly how this differs from (and is weaker than) macOS's
/// code-signature-based check.
internal sealed class AgentServer
{
    private const string PipeName = "VaultSignerAgent";

    private readonly object _vaultLock = new();
    private Vault? _vault;
    public Vault? Vault
    {
        get { lock (_vaultLock) return _vault; }
        set { lock (_vaultLock) _vault = value; }
    }

    private readonly WinFormsPassphrasePrompter _prompter = new();
    private readonly ManagementHandlers _management;
    private volatile bool _running;

    public AgentServer(Vault? vault)
    {
        _vault = vault;
        _management = new ManagementHandlers(this);
    }

    public void Start()
    {
        _running = true;
        for (var i = 0; i < 4; i++)
        {
            _ = Task.Run(AcceptLoopAsync);
        }
    }

    private static PipeSecurity BuildPipeSecurity()
    {
        // Owner-only access (spec §7: "advertised via a well-known local
        // ... with owner-only permissions") — the named-pipe analogue of
        // a Unix socket's 0600 file mode. Only the current Windows user
        // (and, implicitly, processes running as that same user token)
        // can open this pipe at all.
        var security = new PipeSecurity();
        var currentUser = WindowsIdentity.GetCurrent().User!;
        security.AddAccessRule(new PipeAccessRule(currentUser, PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return security;
    }

    private async Task AcceptLoopAsync()
    {
        while (_running)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = NamedPipeServerStreamAcl.Create(
                    PipeName,
                    PipeDirection.InOut,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous,
                    inBufferSize: 4096,
                    outBufferSize: 4096,
                    pipeSecurity: BuildPipeSecurity());
            }
            catch (IOException)
            {
                await Task.Delay(50);
                continue;
            }

            try
            {
                await pipe.WaitForConnectionAsync();
            }
            catch
            {
                pipe.Dispose();
                continue;
            }

            _ = Task.Run(() => HandleConnectionAsync(pipe));
        }
    }

    private async Task HandleConnectionAsync(NamedPipeServerStream pipe)
    {
        using (pipe)
        {
            var buffer = new List<byte>();
            var readChunk = new byte[4096];
            try
            {
                while (pipe.IsConnected)
                {
                    var n = await pipe.ReadAsync(readChunk);
                    if (n <= 0) return;
                    buffer.AddRange(readChunk.AsSpan(0, n).ToArray());

                    int newlineIndex;
                    while ((newlineIndex = buffer.IndexOf((byte)'\n')) >= 0)
                    {
                        var lineBytes = buffer.GetRange(0, newlineIndex).ToArray();
                        buffer.RemoveRange(0, newlineIndex + 1);
                        if (lineBytes.Length == 0) continue;

                        var responseBytes = HandleLine(lineBytes, pipe);
                        var framed = new byte[responseBytes.Length + 1];
                        responseBytes.CopyTo(framed, 0);
                        framed[^1] = (byte)'\n';
                        await pipe.WriteAsync(framed);
                        await pipe.FlushAsync();
                    }
                }
            }
            catch (IOException)
            {
                // Peer disconnected mid-message — nothing to respond to.
            }
        }
    }

    // A well-formed "no id known yet" JSON `null`, used for the
    // parse_error response before any real `id` could be read — a
    // default `JsonElement` has `ValueKind.Undefined`, which
    // `JsonSerializer` refuses to serialize at all.
    private static readonly JsonElement NullId = JsonDocument.Parse("null").RootElement;

    private sealed class RawRequest
    {
        public string? Method { get; set; }
        public JsonElement Params { get; set; } = NullId;
        public JsonElement Id { get; set; } = NullId;
    }

    private byte[] HandleLine(byte[] lineBytes, NamedPipeServerStream pipe)
    {
        RawRequest request;
        try
        {
            request = JsonSerializer.Deserialize<RawRequest>(lineBytes)
                ?? throw new JsonException("empty request");
            if (string.IsNullOrEmpty(request.Method))
            {
                throw new JsonException("missing method");
            }
        }
        catch (JsonException e)
        {
            return ErrorResponse(NullId, "parse_error", e.Message);
        }

        var id = request.Id;

        if (request.Method.StartsWith("internal.", StringComparison.Ordinal))
        {
            if (!PeerAuthentication.CallerIsVaultSignerUi(pipe))
            {
                return ErrorResponse(id, "unauthorized_caller", "internal.* is restricted to VaultSignerUI");
            }
            return _management.Handle(request.Method, request.Params, id);
        }

        var vault = Vault;
        if (vault is null)
        {
            return ErrorResponse(id, "no_vault_open", "no vault is currently open");
        }
        var callerIdentity = PeerIdentity.CallerDisplayName(pipe);
        return vault.HandleProtocolRequest(callerIdentity, lineBytes, _prompter);
    }

    internal static byte[] ResultResponse(JsonElement id, object result)
    {
        return JsonSerializer.SerializeToUtf8Bytes(new { id, result });
    }

    internal static byte[] ErrorResponse(JsonElement id, string code, string message)
    {
        return JsonSerializer.SerializeToUtf8Bytes(new { id, error = new { code, message } });
    }
}
