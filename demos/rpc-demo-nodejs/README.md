# VaultSigner RPC demo (Node.js)

The simplest possible proof that VaultSigner's custom local signing
protocol (spec §7) is a real, language-agnostic wire format: a single
Node.js file, zero dependencies, talking to your **real,
already-running** `VaultSignerAgent` over its documented local
transport (a Unix domain socket on macOS/Linux, a named pipe on
Windows — see `server.js`'s `TRANSPORT_PATH`). Nothing here is faked
or bypassed — no throwaway vault, no `internal.*` bootstrap namespace,
nothing a genuine third-party app couldn't do itself.

## Run it

```bash
node server.js
```

That's it — one command, identical on every platform. It starts a tiny
local web server, prints its URL, and opens it in your default browser
automatically (macOS and Windows; on Linux, open the printed URL
yourself). Everything else happens in that page.

No Node.js install needed if you don't already have one — grab the
"Windows Binary (.zip)" from nodejs.org, extract it, and run
`node.exe` directly from the extracted folder; the officially packaged
installer works too, of course, this is just a fallback if it's
misbehaving on your machine.

## What you need first

- `VaultSignerAgent` running — launch `VaultSigner.app` on macOS, or
  `VaultSignerAgent.exe` (or `VaultSignerUI.exe`, which starts it) on
  Windows.
- A compartment **unlocked the normal way**, in the real app's own UI
  (or via auto-unlock, if you've turned that on in Settings). If you
  skip this, the page will honestly tell you it found zero keys — that
  is correct, not a bug, and it's not this demo's job to unlock
  anything for you.

## What to watch for

Click **Request Signature** and a real password prompt should appear
from VaultSignerAgent — bring it to the front if it doesn't pop up
automatically. Look at its title: it names the caller by this demo's
own real OS process name (e.g. `"node wants to sign with a VaultSigner
key"` on macOS, `"node.exe wants to sign with a VaultSigner key"` on
Windows), resolved from OS-level process identity, never from anything
the page claims about itself. That's spec §7's anti-spoofing guarantee,
visible live. Enter the key's passphrase, click Allow, and the page
shows the returned signature plus an independent verification done
with Node's own `crypto` module (Ed25519 keys only — no dependency
needed for that either).

## Why this exists alongside `../rpc-demo-client/`

That earlier demo used a disposable vault and the agent's
internal-only bootstrap method to unlock it, to avoid needing your real
vault's passphrase — but that meant it never actually proved anything
against a real, normally-unlocked vault. This one only ever calls the
two public `vaultsigner.*` methods, against whatever vault you already
have open for real.
