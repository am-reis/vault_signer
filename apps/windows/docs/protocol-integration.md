# Windows integration guide

Platform-specific details for the protocol documented in [`docs/protocol-integration/README.md`](../../../docs/protocol-integration/README.md) — read that first for the message format, methods, authorization behavior, and error catalog. This page covers only what's specific to Windows: how to reach VaultSigner, and working code.

## Transport

A named pipe at:

```
\\.\pipe\VaultSignerAgent
```

Created with an owner-only ACL (`AgentServer.cs`'s `BuildPipeSecurity`) — only processes running as the same Windows user can connect at all; the Windows analogue of the Unix socket's `0600` permissions on other platforms. Framing is newline-delimited JSON, identical to every other platform: write one JSON object per line (`\n`-terminated), read one line back per request. You may send multiple requests over one connection, in order; you don't need to reconnect between them.

A client just opens the pipe like any other file handle — no special client-side setup, and (as the examples below show) no extra dependency in any of the three languages demonstrated here.

## Discovery and prerequisites

There's no announcement mechanism beyond the pipe's presence. Before sending anything:

1. Try to connect. If it fails because the pipe doesn't exist, `VaultSignerAgent` isn't running — tell the user to launch `VaultSignerAgent.exe` (or `VaultSignerUI.exe`, which starts it). Unlike VaultSigner's own management UI, a third-party app has no way to launch the agent itself; the correct behavior is prompting the user, not trying to work around it.
2. `vaultsigner.list_public_keys` returning an empty list is not an error — it means no compartment is currently unlocked. Discovering a key requires the user to have unlocked its compartment in `VaultSignerUI.exe` first (or have auto-unlock configured for it, once that's available on Windows — see `PROGRESS.md`); your app has no way to trigger that either. Prompt the user to open `VaultSignerUI.exe` and unlock their vault, then retry.

An agent-specific error you may see beyond the core catalog: `no_vault_open` — the agent is running but has no vault open at all yet (a fresh install before the user has created one). Same guidance: point the user at `VaultSignerUI.exe`.

## Example: PowerShell (no dependency)

```powershell
function Invoke-VaultSignerRpc {
    param([string]$Method, [hashtable]$Params, [int]$Id = 1)
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "VaultSignerAgent", [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(3000)
    $request = @{ method = $Method; params = $Params; id = $Id } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($request + "`n")
    $pipe.Write($bytes, 0, $bytes.Length)
    $pipe.Flush()
    $buf = New-Object byte[] 4096
    $sb = New-Object System.Text.StringBuilder
    while (-not $sb.ToString().Contains("`n")) {
        $n = $pipe.Read($buf, 0, $buf.Length)
        if ($n -le 0) { throw "VaultSignerAgent closed the connection unexpectedly" }
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $n))
    }
    $pipe.Dispose()
    return $sb.ToString().Trim() | ConvertFrom-Json
}

$keys = (Invoke-VaultSignerRpc -Method "vaultsigner.list_public_keys" -Params @{}).result.keys
$keyId = $keys[0].key_id

$messageB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("data to sign"))
$response = Invoke-VaultSignerRpc -Method "vaultsigner.sign" -Params @{ key_id = $keyId; message_b64 = $messageB64 }
if ($response.error) {
    Write-Output "signing failed: $($response.error.code) $($response.error.message)"
} else {
    Write-Output "signature (b64): $($response.result.signature_b64)"
}
```

## Example: Python (stdlib only)

Windows has no `AF_UNIX`-style socket for named pipes, but a pipe client is just a file handle — plain `open()` in binary read/write mode, once a server instance is listening, is enough:

```python
import json

PIPE_PATH = r"\\.\pipe\VaultSignerAgent"

def call(method, params):
    with open(PIPE_PATH, "r+b", buffering=0) as pipe:
        pipe.write((json.dumps({"method": method, "params": params, "id": 1}) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = pipe.read(4096)
            if not chunk:
                raise ConnectionError("VaultSignerAgent closed the connection unexpectedly")
            buf += chunk
    return json.loads(buf.split(b"\n", 1)[0])

keys = call("vaultsigner.list_public_keys", {})["result"]["keys"]
key_id = keys[0]["key_id"]

import base64
message_b64 = base64.b64encode(b"data to sign").decode()
response = call("vaultsigner.sign", {"key_id": key_id, "message_b64": message_b64})
if "error" in response:
    print("signing failed:", response["error"]["code"], response["error"]["message"])
else:
    print("signature (b64):", response["result"]["signature_b64"])
```

A complete, runnable version of this pattern — including independent signature verification — lives at [`demos/rpc-demo-client/`](../../../demos/rpc-demo-client/) (`_WindowsPipeConnection` there is exactly this technique, factored out so the same script also runs unmodified on macOS/Linux over a Unix socket).

## Example: Node.js (zero dependencies)

Node's `net` module already treats a `\\.\pipe\` path as a named pipe natively — `net.createConnection(path)` needs no special-casing at all:

```js
const net = require("net");

const PIPE_PATH = "\\\\.\\pipe\\VaultSignerAgent";

function call(method, params) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(PIPE_PATH);
    let buffer = "";
    socket.on("connect", () => socket.write(JSON.stringify({ method, params, id: 1 }) + "\n"));
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline !== -1) {
        socket.end();
        resolve(JSON.parse(buffer.slice(0, newline)));
      }
    });
    socket.on("error", reject);
  });
}

(async () => {
  const keys = (await call("vaultsigner.list_public_keys", {})).result.keys;
  const keyId = keys[0].key_id;
  const messageB64 = Buffer.from("data to sign").toString("base64");
  const response = await call("vaultsigner.sign", { key_id: keyId, message_b64: messageB64 });
  if (response.error) {
    console.log("signing failed:", response.error.code, response.error.message);
  } else {
    console.log("signature (b64):", response.result.signature_b64);
  }
})();
```

A complete, runnable, browser-based version of this pattern — including independent signature verification with Node's own `crypto` module — lives at [`demos/rpc-demo-nodejs/`](../../../demos/rpc-demo-nodejs/) (`TRANSPORT_PATH` there is the one platform-specific line; everything else is identical to the Unix-socket version).

## `internal.*` is not for you

`VaultSignerAgent` also serves an `internal.*` namespace on this same pipe, used exclusively by `VaultSignerUI.exe` itself to manage the vault (create keys, unlock compartments, export/import, and similar). In a Release build it authenticates callers by checking the connecting process's on-disk path against `VaultSignerUI.exe`'s expected install location next to the agent — a real but, by its own documentation (`PeerAuthentication.cs`), materially weaker check than macOS's code-signature verification, since it doesn't stop a malicious co-resident process that can write to the same directory or copy itself to that exact path. A future release may close that gap with Authenticode signature verification. Either way: don't build against `internal.*`. It isn't a stable or supported surface for outside callers, and it's rejected by design in Release builds regardless of your process's path — this document's `vaultsigner.*` methods are the only supported integration surface.

## FIDO2 / passkeys on Windows

Not yet available. Spec item 3.4 (plugin-authenticator COM registration via the Windows WebAuthn platform APIs) is still open — see `PROGRESS.md` for current status. Until it ships, VaultSigner does not appear in the native Windows Hello/WebAuthn picker shown by browsers, and there is no fallback path enabled yet either.
