---
title: macOS Protocol Integration
---

# macOS integration guide

Platform-specific details for the protocol documented in [`docs/protocol-integration/README.md`](../../../docs/protocol-integration/README.md) — read that first for the message format, methods, authorization behavior, and error catalog. This page covers only what's specific to macOS: how to reach VaultSigner, and working code.

## Transport

A Unix domain socket at:

```
~/Library/Application Support/VaultSigner/agent.sock
```

Permissions are `0600`, owner-only — only processes running as the same user can connect at all. Framing is newline-delimited JSON: write one JSON object per line (`\n`-terminated), read one line back per request. You may send multiple requests over one connection, in order; you don't need to reconnect between them.

## Discovery and prerequisites

There's no announcement mechanism beyond the socket's presence. Before sending anything:

1. Check the socket file exists. If it doesn't, `VaultSignerAgent` isn't running — tell the user to open `VaultSigner.app`. Unlike VaultSigner's own management UI, a third-party app has no way to launch the agent itself (it isn't your bundle to launch); the correct behavior is prompting the user, not trying to work around it.
2. `vaultsigner.list_public_keys` returning an empty list is not an error — it means no compartment is currently unlocked. Discovering a key requires the user to have unlocked its compartment in VaultSigner.app first (or have auto-unlock configured for it); your app has no way to trigger that either. Prompt the user to open VaultSigner.app and unlock their vault, then retry.

An agent-specific error code you may see beyond the core catalog: `no_vault_open` — the agent is running but has no vault open at all yet (a fresh install before the user has created one). Same guidance: point the user at `VaultSigner.app`.

## Example: Python (stdlib only)

```python
import socket, json, os

SOCKET_PATH = os.path.expanduser("~/Library/Application Support/VaultSigner/agent.sock")

def call(method, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCKET_PATH)
    s.sendall((json.dumps({"method": method, "params": params, "id": 1}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        buf += s.recv(4096)
    s.close()
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

A complete, runnable version of this pattern — including independent signature verification — lives at [`demos/rpc-demo-client/`](../../../demos/rpc-demo-client/).

## Example: Node.js (stdlib only)

```js
const net = require("net");
const os = require("os");
const path = require("path");

const SOCKET_PATH = path.join(os.homedir(), "Library", "Application Support", "VaultSigner", "agent.sock");

function call(method, params) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(SOCKET_PATH);
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
  const { result } = await call("vaultsigner.list_public_keys", {});
  const keyId = result.keys[0].key_id;
  const messageB64 = Buffer.from("data to sign").toString("base64");
  const response = await call("vaultsigner.sign", { key_id: keyId, message_b64: messageB64 });
})();
```

A complete, runnable version — including a small UI — lives at [`demos/rpc-demo-nodejs/`](../../../demos/rpc-demo-nodejs/): run `node server.js` and it opens a page that exercises this exact flow against your real, running `VaultSignerAgent`.

## Example: Swift

```swift
import Darwin
import Foundation

func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
    let socketPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/VaultSigner/agent.sock")
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
        let buffer = rawPtr.bindMemory(to: Int8.self)
        for (i, byte) in pathBytes.enumerated() { buffer[i] = Int8(bitPattern: byte) }
    }
    _ = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }

    var requestData = try JSONSerialization.data(withJSONObject: ["method": method, "params": params, "id": 1])
    requestData.append(0x0A)
    requestData.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while !buffer.contains(0x0A) {
        let n = read(fd, &chunk, chunk.count)
        buffer.append(contentsOf: chunk[0..<n])
    }
    let line = buffer[buffer.startIndex..<buffer.firstIndex(of: 0x0A)!]
    return try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
}
```

This is the same pattern `Shared/ManagementClient.swift` uses internally (for a different, authenticated namespace — see below); a third-party app only ever needs the two `vaultsigner.*` methods shown here.

## `internal.*` is not for you

`VaultSignerAgent` also serves an `internal.*` namespace on this same socket, used exclusively by `VaultSigner.app` itself to manage the vault (create keys, unlock compartments, export/import, and similar). It authenticates callers by code signature — the connecting process must be signed and identified as `com.vaultsigner.app` with a matching Team Identifier — so a third-party app cannot call it successfully regardless of intent. Build only against `vaultsigner.*`.

## FIDO2 / passkeys on macOS

VaultSigner participates in passkey registration and sign-in as a standard `ASCredentialProviderExtension` (Apple's `AuthenticationServices` framework) once installed and enabled in System Settings → Passwords → Password Options — the same mechanism as any other third-party password/passkey manager. You integrate with `ASAuthorization`/WebAuthn APIs as usual and never talk to the socket described in this document for that flow. As of this writing, enabling that extension for real requires a paid Apple Developer Program membership (see `PROGRESS.md` item 2.7) — the implementation is complete but not independently verifiable end-to-end without one.
