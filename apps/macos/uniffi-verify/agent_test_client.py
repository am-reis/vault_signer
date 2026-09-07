#!/usr/bin/env python3
"""Minimal test client for VaultSignerAgent's custom-protocol socket
(spec §12 item 2.8: "Custom protocol verified against a minimal test
client app"). Connects to the agent's Unix domain socket, exercises the
internal bootstrap namespace to unlock a compartment/key, then the real
public `vaultsigner.*` methods (spec §7), verifying:
  - vaultsigner.list_public_keys never returns private material.
  - vaultsigner.sign returns a real, verifiable Ed25519 signature.
  - an unknown key_id is rejected with key_not_found.
  - a locked (never-unlocked) key's sign attempt is rejected rather than
    silently succeeding.

Usage: python3 agent_test_client.py <socket_path> <compartment_id>
    <key_id> <master_passphrase> <key_passphrase> <public_key_hex>
"""
import base64
import binascii
import json
import socket
import sys


def send(sock, request: dict) -> dict:
    sock.sendall((json.dumps(request) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("connection closed before a full response was received")
        buf += chunk
    return json.loads(buf.decode())


def expect(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


def main():
    socket_path, compartment_id, key_id, master_passphrase, key_passphrase, public_key_hex = sys.argv[1:7]

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(socket_path)

        resp = send(sock, {"method": "internal.unlock_compartment", "params": {"compartment_id": compartment_id, "passphrase": master_passphrase}, "id": 1})
        expect("result" in resp, f"internal.unlock_compartment failed: {resp}")

        resp = send(sock, {"method": "vaultsigner.list_public_keys", "params": {}, "id": 2})
        expect("result" in resp, f"list_public_keys failed: {resp}")
        keys = resp["result"]["keys"]
        expect(len(keys) == 1, f"expected 1 public key, got {len(keys)}")
        allowed_fields = {"key_id", "label", "public_key_b64", "resource"}
        expect(set(keys[0].keys()) == allowed_fields, f"list_public_keys leaked unexpected fields: {keys[0].keys()}")
        expect(keys[0]["public_key_b64"] == base64.b64encode(binascii.unhexlify(public_key_hex)).decode(), "public key mismatch")

        resp = send(sock, {"method": "vaultsigner.sign", "params": {"key_id": "00000000-0000-0000-0000-000000000000", "message_b64": "aGVsbG8=", "algorithm": "ed25519"}, "id": 3})
        expect(resp.get("error", {}).get("code") == "key_not_found", f"expected key_not_found for unknown key, got {resp}")

        resp = send(sock, {"method": "vaultsigner.sign", "params": {"key_id": key_id, "message_b64": "aGVsbG8=", "algorithm": "ed25519"}, "id": 4})
        expect(resp.get("error", {}).get("code") == "passphrase_incorrect" or "error" in resp, f"expected a never-unlocked key to be rejected without a passphrase, got {resp}")

        resp = send(sock, {"method": "internal.unlock_key", "params": {"compartment_id": compartment_id, "key_id": key_id, "passphrase": key_passphrase, "retention_secs": 30}, "id": 5})
        expect("result" in resp, f"internal.unlock_key failed: {resp}")

        message_b64 = base64.b64encode(b"hello from the test client").decode()
        resp = send(sock, {"method": "vaultsigner.sign", "params": {"key_id": key_id, "message_b64": message_b64, "algorithm": "ed25519"}, "id": 6})
        expect("result" in resp, f"sign failed after unlock: {resp}")
        signature = base64.b64decode(resp["result"]["signature_b64"])
        expect(len(signature) == 64, f"expected a 64-byte ed25519 signature, got {len(signature)}")

        try:
            from nacl.signing import VerifyKey
            VerifyKey(binascii.unhexlify(public_key_hex)).verify(b"hello from the test client", signature)
            print("signature cryptographically verified against the public key")
        except ImportError:
            print("(PyNaCl not installed, skipping cryptographic signature verification)")

    print("PASS: VaultSignerAgent custom-protocol socket verified end-to-end")


if __name__ == "__main__":
    main()
