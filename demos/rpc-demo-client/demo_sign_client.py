#!/usr/bin/env python3
"""Minimal GUI demo of VaultSigner's custom local signing protocol
(spec §7), written deliberately in something other than Swift/C# to
show the protocol is a real, language-agnostic wire format — any
process on the machine that can open the local transport can ask
VaultSigner to sign something, exactly like this app does.

This is a demo, not a test: `apps/macos/uniffi-verify/agent_test_client.py`
is the non-interactive automated check (it deliberately avoids the
passphrase prompt via the internal.unlock_key bootstrap method — see
its own docstring). This app does the opposite on purpose: every
"Request Signature" click is a *real* `vaultsigner.sign` call for a key
with no cached material, so it genuinely triggers VaultSignerAgent's
live passphrase prompt (an `NSAlert` on macOS, a WinForms dialog on
Windows), screen-capture-blocked per spec §5.0, running as a totally
separate OS process from this one.

Cross-platform on purpose, not just macOS: the JSON-RPC message shapes
(spec §7) are identical everywhere, and only the local transport
underneath them differs — a Unix domain socket on macOS/Linux, a named
pipe on Windows (`AgentServer.cs`'s `VaultSignerAgent` pipe). This file
proves that by branching on nothing but the transport open/read/write,
in `_connect()` below; every line above and below it — request
encoding, response parsing, error handling, the UI — is identical
across platforms.

Stdlib only (socket, json, tkinter on macOS/Linux; the same plus plain
file I/O against the named pipe on Windows) — nothing to install.
Optionally uses PyNaCl, if present, to independently verify an Ed25519
signature client-side, the same way `agent_test_client.py` does; skips
that step otherwise rather than failing.

Prerequisites:
  - VaultSignerAgent must already be running with a vault open and at
    least one compartment/key created — launch VaultSigner.app on
    macOS, or VaultSignerAgent.exe (or VaultSignerUI.exe, which starts
    it) on Windows.
  - That compartment does not need to be "unlocked" first — signing a
    cold key is exactly what makes the agent show its passphrase
    prompt, which is the point of this demo.

Usage:
    python3 demo_sign_client.py
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import socket
import threading
import tkinter as tk
from tkinter import ttk
from typing import Any

IS_WINDOWS = os.name == "nt"

if IS_WINDOWS:
    # Matches AgentServer.cs's `PipeName` — see apps/windows/VaultSignerAgent/AgentServer.cs.
    TRANSPORT_PATH = r"\\.\pipe\VaultSignerAgent"
else:
    TRANSPORT_PATH = os.path.expanduser("~/Library/Application Support/VaultSigner/agent.sock")


class _WindowsPipeConnection:
    """Wraps a Windows named-pipe client handle behind the same
    sendall/recv/close surface socket.socket exposes, so rpc_call()'s
    logic below needs exactly one code path regardless of platform.
    Plain `open()` on a `\\\\.\\pipe\\NAME` path is enough on Windows —
    the C runtime's CreateFile call underneath handles it like any
    other file handle once a server instance is listening; no pywin32
    or other dependency required. `buffering=0` keeps reads unbuffered
    (io.FileIO), so recv() behaves like socket.recv() — returns
    whatever's available rather than blocking for a full buffer."""

    def __init__(self, path: str = TRANSPORT_PATH) -> None:
        self._f = open(path, "r+b", buffering=0)

    def sendall(self, data: bytes) -> None:
        self._f.write(data)

    def recv(self, n: int) -> bytes:
        return self._f.read(n)

    def close(self) -> None:
        self._f.close()


def _connect() -> Any:
    if IS_WINDOWS:
        return _WindowsPipeConnection(TRANSPORT_PATH)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(TRANSPORT_PATH)
    return sock

ERROR_EXPLANATIONS = {
    "user_declined": "The person at VaultSigner's alert clicked Deny.",
    "passphrase_incorrect": "The passphrase entered at the prompt was wrong for this key.",
    "key_locked_retry_later": "Too many recent failed attempts for this key (spec §5.5 throttling) — wait and retry.",
    "key_not_found": "That key_id doesn't exist in the currently open vault.",
    "method_not_found": "Unexpected: the agent doesn't recognize this request's method.",
    "invalid_params": "Unexpected: this app sent a malformed request.",
}


class RpcError(Exception):
    def __init__(self, code: str, message: str):
        self.code = code
        self.message = message
        super().__init__(f"{code}: {message}")


def rpc_call(method: str, params: dict, req_id: int) -> Any:
    """Opens a fresh connection, sends one newline-delimited JSON-RPC
    request, and blocks for the one-line response. A fresh connection
    per call keeps this demo simple; the wire format itself (matching
    `vaultcore::protocol`, `AgentServer.swift`, and `AgentServer.cs`)
    supports pipelining several requests over one connection too."""
    sock = _connect()
    try:
        sock.sendall((json.dumps({"method": method, "params": params, "id": req_id}) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("VaultSignerAgent closed the connection without a response")
            buf += chunk
        line = buf.split(b"\n", 1)[0]
    finally:
        sock.close()

    response = json.loads(line)
    if "error" in response:
        raise RpcError(response["error"]["code"], response["error"]["message"])
    return response["result"]


def try_verify_ed25519(public_key_b64: str, message: bytes, signature_b64: str) -> str:
    """Best-effort client-side proof that the returned signature is
    real, independent of vaultcore/VaultSigner entirely — mirrors
    `agent_test_client.py`'s own verification step. Ed25519 public keys
    are exactly 32 bytes; VaultSigner's other supported key type
    (ECDSA P-256) isn't verified here, to keep this demo's dependency
    footprint at "PyNaCl or nothing."""
    public_key = base64.b64decode(public_key_b64)
    if len(public_key) != 32:
        return "not verified client-side (not a 32-byte Ed25519 key — likely ECDSA P-256)"
    try:
        from nacl.signing import VerifyKey
    except ImportError:
        return "not verified client-side (PyNaCl not installed — pip install pynacl to enable this)"
    try:
        VerifyKey(public_key).verify(message, base64.b64decode(signature_b64))
        return "✓ independently verified against the returned public key (PyNaCl)"
    except Exception as e:
        return f"✗ verification FAILED: {e}"


class DemoApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("VaultSigner RPC Demo Client (Python, not Swift/C#)")
        self.geometry("640x520")
        self.keys: list[dict] = []
        self._next_id = 1
        self._build_ui()
        self.refresh_keys()
        # Return-to-submit, except inside the message box itself (where
        # Return should just insert a newline, as expected).
        self.bind("<Return>", self._on_return_key)

    def _on_return_key(self, _event: object) -> None:
        if self.focus_get() is self.message_entry:
            return
        self.on_sign_clicked()

    def _next_request_id(self) -> int:
        self._next_id += 1
        return self._next_id

    def _build_ui(self) -> None:
        pad = {"padx": 10, "pady": 6}

        header = ttk.Label(
            self,
            text="This app is plain Python + Tkinter, not VaultSigner code.\n"
            "It talks to VaultSignerAgent purely over its documented local\n"
            "transport protocol (spec §7) — the same way any third-party app would.",
            justify="left",
        )
        header.pack(anchor="w", **pad)

        key_frame = ttk.Frame(self)
        key_frame.pack(fill="x", **pad)
        ttk.Label(key_frame, text="Key to sign with:").pack(side="left")
        self.key_combo = ttk.Combobox(key_frame, state="readonly", width=60)
        self.key_combo.pack(side="left", padx=8)
        # Plain tk.Button, not ttk.Button: ttk's Aqua button theme has a
        # long-standing macOS bug where the label sometimes fails to
        # draw at all (renders as a blank pill) — tk.Button with an
        # explicit fg/bg always renders correctly.
        tk.Button(key_frame, text="Refresh Keys", command=self.refresh_keys, highlightbackground="#222").pack(side="left")

        ttk.Label(self, text="Message to sign:").pack(anchor="w", padx=10)
        self.message_entry = tk.Text(self, height=3)
        self.message_entry.insert("1.0", "Hello from a non-Swift demo app!")
        self.message_entry.pack(fill="x", padx=10, pady=(0, 6))

        self.sign_button = tk.Button(
            self, text="Request Signature", command=self.on_sign_clicked, fg="#000", bg="#e0e0e0", highlightbackground="#222"
        )
        self.sign_button.pack(padx=10, pady=4, anchor="w")

        ttk.Label(self, text="What's happening:").pack(anchor="w", padx=10, pady=(10, 0))
        self.log = tk.Text(self, height=16, state="disabled", bg="#111", fg="#ddd")
        self.log.pack(fill="both", expand=True, padx=10, pady=(0, 10))

    def log_line(self, text: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    # -- key listing -------------------------------------------------

    def refresh_keys(self) -> None:
        self.log_line(f"Connecting to {TRANSPORT_PATH} ...")
        try:
            result = rpc_call("vaultsigner.list_public_keys", {}, self._next_request_id())
        except FileNotFoundError:
            launch_hint = "VaultSignerAgent.exe (or VaultSignerUI.exe)" if IS_WINDOWS else "VaultSigner.app"
            self.log_line(f"VaultSignerAgent isn't running (transport not found). Launch {launch_hint}, open a vault, then Refresh Keys.")
            return
        except (RpcError, ConnectionError, OSError) as e:
            self.log_line(f"Couldn't list keys: {e}")
            return

        self.keys = result["keys"]
        if not self.keys:
            self.log_line("Connected, but the open vault has no keys yet. Create one in VaultSigner.app, then Refresh Keys.")
            self.key_combo["values"] = []
            return

        labels = [f"{k['label']}  ({k['resource']})  {k['key_id'][:8]}…" for k in self.keys]
        self.key_combo["values"] = labels
        self.key_combo.current(0)
        self.key_combo.update_idletasks()  # macOS Tk sometimes needs a nudge to paint a value set before first display
        self.log_line(f"Found {len(self.keys)} key(s) in the open vault.")

    # -- signing -------------------------------------------------------

    def on_sign_clicked(self) -> None:
        if not self.keys:
            self.log_line("No key selected — Refresh Keys first.")
            return
        index = self.key_combo.current()
        if index < 0:
            self.log_line("Pick a key from the dropdown first.")
            return
        key = self.keys[index]
        message = self.message_entry.get("1.0", "end-1c").encode("utf-8")

        self.sign_button.configure(state="disabled")
        self.log_line("")
        self.log_line(f"Sending vaultsigner.sign for key '{key['label']}' ({key['key_id']})...")
        self.log_line(
            "VaultSigner identifies the caller itself, from OS-level process identity\n"
            "(never from anything this app claims) — watch for its prompt to name this\n"
            "process by its real executable name, e.g. \"python.exe\" / \"python3\"."
        )
        self.log_line("Waiting for approval in VaultSigner — a password prompt should appear now (bring VaultSigner to the front if you don't see it)...")

        threading.Thread(target=self._do_sign, args=(key, message), daemon=True).start()

    def _do_sign(self, key: dict, message: bytes) -> None:
        params = {
            "key_id": key["key_id"],
            "message_b64": base64.b64encode(message).decode("ascii"),
        }
        try:
            result = rpc_call("vaultsigner.sign", params, self._next_request_id())
        except RpcError as e:
            self.after(0, self._on_sign_error, e)
        except (ConnectionError, OSError) as e:
            self.after(0, self.log_line, f"Connection problem: {e}")
            self.after(0, lambda: self.sign_button.configure(state="normal"))
        else:
            self.after(0, self._on_sign_success, result, message)

    def _on_sign_error(self, e: RpcError) -> None:
        explanation = ERROR_EXPLANATIONS.get(e.code, e.message)
        self.log_line(f"Signing declined: {e.code} — {explanation}")
        self.sign_button.configure(state="normal")

    def _on_sign_success(self, result: dict, message: bytes) -> None:
        signature_b64 = result["signature_b64"]
        public_key_b64 = result["public_key_b64"]
        self.log_line("Signature received!")
        self.log_line(f"  signature (hex): {binascii.hexlify(base64.b64decode(signature_b64)).decode()}")
        self.log_line(f"  public key (hex): {binascii.hexlify(base64.b64decode(public_key_b64)).decode()}")
        self.log_line(f"  {try_verify_ed25519(public_key_b64, message, signature_b64)}")
        self.sign_button.configure(state="normal")


if __name__ == "__main__":
    DemoApp().mainloop()
