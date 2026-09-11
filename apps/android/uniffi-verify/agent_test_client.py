#!/usr/bin/env python3
"""Verifies VaultSignerService's custom-protocol socket end-to-end (spec
§7, item 4.6), mirroring apps/macos/uniffi-verify/agent_test_client.py's
shape for Android. Runs against a real running app on a real device/
emulator — not a mock.

Android's socket is a device-local abstract Unix domain socket
(`com.vaultsigner.app.agent`, see VaultSignerService.SOCKET_NAME) rather
than a filesystem path, so this script talks to it over a plain TCP
connection tunneled by `adb forward` rather than connecting directly —
that tunnel is host-tooling (adb), not a network exposure of the socket
itself (spec §7's "never accept non-loopback connections" is still true
of the actual on-device listener; adb forward is a debugging bridge, the
same one Android Studio itself uses, not a general network path).

Usage (from apps/android/, with the app already running on a
connected device/emulator, ADB_PORT matching what you forwarded):

    adb forward tcp:9999 localabstract:com.vaultsigner.app.agent
    python3 uniffi-verify/agent_test_client.py
"""
import json
import socket
import sys

HOST = "127.0.0.1"
PORT = 9999


def call(sock: socket.socket, method: str, params: dict, request_id: int) -> dict:
    request = json.dumps({"method": method, "params": params, "id": request_id}) + "\n"
    sock.sendall(request.encode("utf-8"))
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return json.loads(buf.decode("utf-8"))


def main() -> None:
    failures = []

    # 1. vaultsigner.list_public_keys — third-party namespace, must work
    # with no prior registration (spec §7) even before any internal.*
    # call. Also confirms the socket answers at all.
    with socket.create_connection((HOST, PORT), timeout=5) as sock:
        response = call(sock, "vaultsigner.list_public_keys", {}, 1)
        print("list_public_keys ->", response)
        if "result" not in response or "keys" not in response["result"]:
            failures.append("list_public_keys did not return a keys array")

    # 2. internal.* from this script (an unsigned, unrelated process) MUST
    # be rejected — spec §8's authentication requirement, verified the
    # same way apps/macos's client verifies an unauthorized caller is
    # rejected (there: no code signature; here: a different UID entirely
    # — this script runs as this host's adb-forwarded TCP client, which
    # the app's LocalSocket sees as a different peer UID than its own).
    with socket.create_connection((HOST, PORT), timeout=5) as sock:
        response = call(sock, "internal.status", {}, 2)
        print("internal.status (should be unauthorized_caller) ->", response)
        error = response.get("error", {})
        if error.get("code") != "unauthorized_caller":
            failures.append(f"expected unauthorized_caller, got {response}")

    # 3. An unknown vaultsigner.* method name.
    with socket.create_connection((HOST, PORT), timeout=5) as sock:
        response = call(sock, "vaultsigner.nonexistent", {}, 3)
        print("unknown method ->", response)
        if response.get("error", {}).get("code") != "method_not_found":
            failures.append(f"expected method_not_found, got {response}")

    if failures:
        print("FAIL:", failures)
        sys.exit(1)
    print("PASS: Android custom-protocol socket verified (list_public_keys, "
          "internal.* rejection for a non-owner caller, unknown-method handling)")


if __name__ == "__main__":
    main()
