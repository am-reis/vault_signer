# VaultSigner RPC demo client

A minimal, demo-only GUI app — plain Python + Tkinter, deliberately
**not** Swift — that proves VaultSigner's custom local signing protocol
(spec §7) is a real, language-agnostic wire format: any process on the
machine that can open a Unix domain socket can ask VaultSigner to sign
something and get a real signature back, gated by VaultSignerAgent's
own live passphrase prompt.

This is different from `apps/macos/uniffi-verify/agent_test_client.py`,
which is a non-interactive *automated test* that deliberately avoids
the passphrase prompt. This app does the opposite on purpose: clicking
**Request Signature** always triggers a real `vaultsigner.sign` call for
a key with no cached material, so it genuinely pops VaultSignerAgent's
live `NSAlert`, running as a separate OS process from this demo, and
screen-capture-blocked per spec §5.0 (so screenshots of *that* prompt
come back blank by design — this demo app itself has no such
restriction).

**What to actually watch for:** the alert's title names the *caller* —
e.g. `python3.11 wants to sign with a VaultSigner key`. VaultSignerAgent
resolves that name itself from the OS socket's peer credentials
(`PeerIdentity.swift`, `LOCAL_PEERPID` → `proc_pidpath`), never from
anything this demo app claims in its JSON request. That's spec §7's
anti-spoofing guarantee, visible in a live prompt triggered by a real
third-party app.

## Quick start

1. **Create a disposable demo vault** (so you don't need your real
   vault's passphrase, and nothing here touches your real data):

   ```bash
   cargo run -p vaultcore --example demo_vault_setup -- /tmp/VaultSignerDemo.vlt
   ```

   This prints a `vault_path`, `compartment_id`, `key_id`, and the two
   passphrases it used (`demo-master-pw` for the compartment,
   `demo-key-pw` for the key).

2. **Point VaultSignerAgent at it.** The agent reads
   `~/Library/Application Support/VaultSigner/config.json`
   (`VaultConfig.swift`) to know which vault to open. If you already
   have a real vault configured, back that file up first:

   ```bash
   cp ~/Library/Application\ Support/VaultSigner/config.json /tmp/vaultsigner_config_backup.json
   echo '{"vault_path": "/tmp/VaultSignerDemo.vlt"}' > ~/Library/Application\ Support/VaultSigner/config.json
   rm -f ~/Library/Application\ Support/VaultSigner/agent.sock
   ```

   Restore it afterwards with
   `cp /tmp/vaultsigner_config_backup.json ~/Library/Application\ Support/VaultSigner/config.json`.

3. **Launch the built `VaultSignerAgent.app`** (build it from
   `apps/macos/` first if you haven't — see that directory's README).

4. **Unlock the demo compartment.** `vaultsigner.list_public_keys` only
   returns keys from compartments the agent has already unlocked
   (spec-consistent: normally this happens via auto-unlock at agent
   launch, or via the management UI once it talks to the agent — see
   `apps/macos/README.md`'s known gaps). For this demo, unlock it
   directly through the agent's own internal bootstrap namespace (this
   is *not* part of the public protocol — a real third-party app could
   never call it):

   ```bash
   python3 - <<'EOF'
   import socket, json
   s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
   s.connect("/Users/YOUR_USER/Library/Application Support/VaultSigner/agent.sock")
   req = {"method": "internal.unlock_compartment",
          "params": {"compartment_id": "PASTE_FROM_STEP_1", "passphrase": "demo-master-pw"},
          "id": 1}
   s.sendall((json.dumps(req) + "\n").encode())
   print(s.recv(4096).decode())
   EOF
   ```

5. **Run the demo:**

   ```bash
   python3 demo_sign_client.py
   ```

   It lists the demo key, then click **Request Signature** (or press
   Return). Watch for VaultSignerAgent's password prompt — bring it to
   the front if it doesn't appear automatically — enter `demo-key-pw`,
   and click **Allow**. The demo's log shows the returned signature and
   public key (hex), plus an independent PyNaCl verification if PyNaCl
   is installed (`pip install pynacl` — optional).

Stdlib-only otherwise (`socket`, `json`, `tkinter`) — nothing else to
install.

## A note on the UI

Some ttk widgets on macOS have a long-standing Tk/Aqua rendering bug
where a `ttk.Button`'s label fails to draw (a blank pill instead of
text). `demo_sign_client.py` uses plain `tk.Button` for its two
interactive buttons specifically to avoid this.
