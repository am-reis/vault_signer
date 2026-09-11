# Android — protocol integration

Android's real transport, discovery, and a working code example for the
custom local signing protocol described in
[`docs/protocol-integration/README.md`](../../../docs/protocol-integration/README.md)
(the friendly introduction — read that first) and formally specified in
[`docs/protocol-integration/PROTOCOL-SPEC.md`](../../../docs/protocol-integration/PROTOCOL-SPEC.md).
Spec §7 groups Android with desktop for transport (a persistent local
socket, not iOS's narrower on-demand App Intents model, §7.1) — this
document is about the one place that grouping needs a real caveat, plus
the concrete details an integrator needs.

## Transport

`VaultSignerService` (the foreground service, spec §8) listens on an
**abstract-namespace Unix domain socket** named `com.vaultsigner.app.agent`
(`android.net.LocalServerSocket`, `LocalSocketAddress.Namespace.ABSTRACT`).
Framing matches `PROTOCOL-SPEC.md` §3 exactly: newline-delimited,
UTF-8-encoded JSON, one object per line, a connection may carry more than
one request/response pair.

**Why abstract namespace, not a filesystem path (the macOS/Windows
model).** Desktop's socket/pipe lives at a fixed, discoverable path a
client just opens (`~/Library/Application Support/VaultSigner/agent.sock`
on macOS, `\\.\pipe\VaultSignerAgent` on Windows) because every process
on those platforms runs as the same OS user and can freely see that path.
Android has no equivalent shared, app-writable-and-externally-readable
location: every app's private storage (`filesDir`,
`getExternalFilesDir`) is sandboxed to that app's own UID, so a socket
file placed there isn't reachable by a different app at all. An abstract-
namespace socket has no filesystem path — a name any process on the
device can attempt to connect to by string alone — which is the only
mechanism that preserves spec §7's "no prior registration" requirement
(a calling app doesn't need a path handed to it, a broker, or anything
installed by VaultSigner ahead of time; it just needs the name above).

**The real, verified caveat this choice carries — read before assuming
parity with desktop.** Verified in this session using
`apps/android/uniffi-verify/agent_test_client.py` tunneled through
`adb forward tcp:<port> localabstract:com.vaultsigner.app.agent`: the
socket answers `vaultsigner.list_public_keys`/`vaultsigner.sign` correctly
with no prior relationship, and correctly rejects `internal.*` from a
non-owner peer (see §Authentication below). **What this does *not*
verify** is unmediated reachability from a second, independent, real
third-party app running on the same device with no special privilege —
`adb forward`'s tunnel is bridged by `adbd`, a privileged host-tooling
process, not a proof that Android's SELinux policy for two ordinary
`untrusted_app`-domain apps permits an abstract-socket connection between
them. Modern AOSP SELinux policy has, in some Android versions, refined
socket-connect mediation between arbitrary third-party apps beyond what
"any process on the device" implies at the Linux-syscall level — this
needs a real second installed APK (not this repo's own process, not an
adb-mediated connection) to settle definitively, and that test has not
been done yet. Treat third-party reachability as *believed* to work,
*not yet conclusively proven*, until that follow-up test exists — do not
build production-critical integration against this until it is.

## Discovery

There is no announcement mechanism beyond the fixed name above — same
posture as the desktop guides ("just check the socket exists / connects;
there's no directory service"). A calling app cannot launch VaultSigner
itself if it isn't already running; direct the user to open the
VaultSigner app once so its foreground service starts (see
`ManagementClient.ensureAgentRunning()` in this app's own source for how
the management UI does exactly that for itself).

## Authentication (the `internal.*` namespace)

Not for third-party use (see the shared README's note on this) —
documented here only because Android's answer is genuinely different
from, and simpler than, the desktop platforms':

Every connection's peer identity is read via
`LocalSocket.getPeerCredentials()`, which the OS populates from the
actual connecting process's credentials (never anything in the request
payload). Android additionally gives every app a distinct Linux UID that
no other app can share, so `internal.*` is authenticated with a single
check — **the peer's UID equals this app's own UID**
(`android.os.Process.myUid()`) — which is already a complete answer to
"is this really VaultSigner's own process," not merely a best differentiator
the way a Unix domain socket's owner-only file permissions are on
desktop (spec §8 flags that exact desktop limitation: same-user doesn't
mean same-app there). See `PeerAuthentication.kt`.

## Caller identity (the `vaultsigner.sign` consent prompt)

Resolved the same OS-level way spec §7 requires: the peer's UID is
mapped to a package name via `PackageManager.getPackagesForUid()`, then
to that package's display label via `PackageManager.getApplicationLabel()`
— never a self-reported name. Verified for real in this session: a
`vaultsigner.sign` request tunneled through `adb`'s peer process showed
the prompt "Shell wants to sign with key ..." — "Shell" being Android's
real label for the `adbd`-mediated caller's UID, not a hardcoded test
value.

## Working example

```python
import json, socket, base64

# Requires: adb forward tcp:9999 localabstract:com.vaultsigner.app.agent
with socket.create_connection(("127.0.0.1", 9999), timeout=10) as sock:
    request = {
        "method": "vaultsigner.sign",
        "params": {
            "key_id": "<uuid from list_public_keys>",
            "message_b64": base64.b64encode(b"hello world").decode(),
            "algorithm": "ed25519",
        },
        "id": 1,
    }
    sock.sendall((json.dumps(request) + "\n").encode())
    # Blocks until a human answers the passphrase prompt this triggers on
    # the device (spec §7) — there is no way to suppress or pre-fill it.
    response = json.loads(sock.recv(65536).decode())
    print(response)
```

A real Android client (rather than a host script tunneled through `adb`)
connects the same way directly on-device:

```kotlin
val socket = LocalSocket()
socket.connect(LocalSocketAddress("com.vaultsigner.app.agent", LocalSocketAddress.Namespace.ABSTRACT))
socket.outputStream.write((requestJson + "\n").toByteArray(Charsets.UTF_8))
val response = BufferedReader(InputStreamReader(socket.inputStream)).readLine()
```

## FIDO2/WebAuthn/passkeys

Not this protocol — see the shared README's note. Android participates
in passkey ceremonies via `androidx.credentials`' Credential Manager
(`VaultSignerCredentialProviderService`, spec §6.3), which any app
integrates against using Google's own Credential Manager APIs, not this
socket.

**Disclosed limitation (mirrors this project's convention of being exact
about what's actually verified, e.g. macOS's paid-account block on item
2.7, Windows's OS-build block on item 3.4):** `VaultSignerCredentialProviderService`
is real, registers with the OS (confirmed live — it appears correctly
labeled under system Settings → Passwords, accounts → Additional
providers), and performs a full CTAP2-native make-credential/get-assertion
round trip through `vaultcore`'s existing native facade. Its
WebAuthn response-JSON construction (`clientDataJSON` assembly, origin
derivation, base64url field encoding) has **not** been verified against
a real relying party in a real browser — that needs its own follow-up
session with actual interop testing, not something this session's scope
covered. Do not treat the FIDO2 path as production-verified yet.

## Errors

Same catalog as `PROTOCOL-SPEC.md` §6, plus one implementation-specific
extension per §6.1: `unauthorized_caller` (a non-owner peer attempting
`internal.*` — see Authentication above).
