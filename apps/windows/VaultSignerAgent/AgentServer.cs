using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading;
using uniffi.vaultcore;

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

    // Windows only lets the *first-ever* instance of a named pipe carry an
    // ACL (`CreateNamedPipe`'s security descriptor is fixed by that call
    // for the pipe name as a whole); every instance created after it must
    // omit the security descriptor entirely, or `NamedPipeServerStreamAcl
    // .Create` throws `UnauthorizedAccessException` ("Access to the path
    // is denied") — not `IOException`, so the original code's `catch
    // (IOException)` never caught it. Since `AcceptLoopAsync` is launched
    // fire-and-forget via a discarded `Task.Run`, that exception silently
    // ended whichever of the 4 loops hit it, with zero trace — this is the
    // real mechanism behind PROGRESS.md's "VaultSignerAgent dies
    // unpredictably" bug: every one of the 4 loops' *first* iteration
    // raced to create the pipe and (at most) one could ever win; the
    // other 3 died on their very first `Create` call, and the winner died
    // too the moment it looped back to replace the instance a client had
    // just connected to. The pipe would only ever go fully dark once all
    // 4 original instances had each been consumed exactly once — which is
    // why it looked idle-stable but died under real, repeated use.
    private int _firstPipeInstanceCreated;

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

    private NamedPipeServerStream CreatePipeInstance()
    {
        // Whichever call (from any of the 4 loops, or any later
        // replacement instance) actually wins this race is "the first
        // instance" from Windows' perspective and must be the one that
        // supplies the ACL — see the comment on `_firstPipeInstanceCreated`.
        if (Interlocked.CompareExchange(ref _firstPipeInstanceCreated, 1, 0) == 0)
        {
            return NamedPipeServerStreamAcl.Create(
                PipeName,
                PipeDirection.InOut,
                NamedPipeServerStream.MaxAllowedServerInstances,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous,
                inBufferSize: 4096,
                outBufferSize: 4096,
                pipeSecurity: BuildPipeSecurity());
        }

        return new NamedPipeServerStream(
            PipeName,
            PipeDirection.InOut,
            NamedPipeServerStream.MaxAllowedServerInstances,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous,
            inBufferSize: 4096,
            outBufferSize: 4096);
    }

    private async Task AcceptLoopAsync()
    {
        while (_running)
        {
            try
            {
                NamedPipeServerStream pipe;
                try
                {
                    pipe = CreatePipeInstance();
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
            catch (Exception e)
            {
                // Belt-and-suspenders: `AcceptLoopAsync` is launched
                // fire-and-forget via a discarded `Task.Run`, so anything
                // that escapes this loop dies silently with zero trace —
                // exactly how the `UnauthorizedAccessException` above went
                // unnoticed for so long. Log whatever it is and keep the
                // loop alive rather than let a future, still-unknown edge
                // case take a listener down permanently again.
                Console.Error.WriteLine($"VaultSignerAgent: AcceptLoopAsync caught unexpected {e.GetType().FullName}: {e}");
                await Task.Delay(50);
            }
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
            catch (Exception e)
            {
                // DIAGNOSTIC (temporary, this session): see the matching
                // note in AcceptLoopAsync — this task is also launched via
                // a discarded `Task.Run`, so anything else escaping here
                // would otherwise vanish with zero trace.
                Console.Error.WriteLine($"VaultSignerAgent: HandleConnectionAsync caught unexpected {e.GetType().FullName}: {e}");
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

    // Every real client (ManagementClient.cs, the macOS Swift client, the
    // documented wire protocol in docs/protocol-integration/README.md)
    // sends lowercase JSON keys ("method"/"params"/"id"). Deserializing
    // into these PascalCase properties without case-insensitive matching
    // silently left Method null on every single request -- a real,
    // previously-undiscovered bug, found only once a real client reached
    // this code through a working pipe connection for the first time.
    private static readonly JsonSerializerOptions RequestJsonOptions = new() { PropertyNameCaseInsensitive = true };

    private byte[] HandleLine(byte[] lineBytes, NamedPipeServerStream pipe)
    {
        RawRequest request;
        try
        {
            request = JsonSerializer.Deserialize<RawRequest>(lineBytes, RequestJsonOptions)
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
