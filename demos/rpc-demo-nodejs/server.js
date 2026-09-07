#!/usr/bin/env node
'use strict';
/**
 * Minimal, zero-dependency demo of VaultSigner's custom local signing
 * protocol (spec §7) — a plain Node.js app, deliberately not Swift,
 * talking to the REAL, already-running VaultSignerAgent over its
 * documented Unix domain socket. Nothing here is faked or bypassed:
 * no throwaway vault, no `internal.*` bootstrap namespace, nothing
 * that a genuine third-party app couldn't do itself. If you see no
 * keys, that's correct and expected until you unlock a compartment
 * the normal way, in VaultSigner.app's own UI.
 *
 * Run: node server.js
 * Then open the URL it prints (it also tries to open your browser
 * automatically). Everything else happens in that one page.
 */

const http = require('http');
const net = require('net');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { exec } = require('child_process');

const SOCKET_PATH = path.join(os.homedir(), 'Library', 'Application Support', 'VaultSigner', 'agent.sock');
const PORT = 8934;
let nextId = 1;

/** One newline-delimited JSON-RPC request/response over a fresh
 * connection to the real agent socket — the exact wire format
 * `vaultcore::protocol` and `AgentServer.swift` define. */
function rpcCall(method, params) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(SOCKET_PATH);
    let buffer = '';
    socket.on('connect', () => {
      socket.write(JSON.stringify({ method, params, id: nextId++ }) + '\n');
    });
    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      const newline = buffer.indexOf('\n');
      if (newline !== -1) {
        socket.end();
        resolve(JSON.parse(buffer.slice(0, newline)));
      }
    });
    socket.on('error', reject);
  });
}

/** Independent, client-side-equivalent proof that a returned signature
 * is real: wraps a raw 32-byte Ed25519 public key in the fixed SPKI DER
 * prefix Node's crypto module needs, then verifies with it — no
 * dependency beyond Node's own `crypto`. VaultSigner's other supported
 * key type (ECDSA P-256) isn't handled, to keep this at zero deps. */
function verifyEd25519(publicKeyB64, messageB64, signatureB64) {
  const publicKey = Buffer.from(publicKeyB64, 'base64');
  if (publicKey.length !== 32) return { verified: null, reason: 'not a 32-byte Ed25519 key (likely ECDSA P-256) — not verified here' };
  try {
    const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
    const keyObject = crypto.createPublicKey({ key: Buffer.concat([spkiPrefix, publicKey]), format: 'der', type: 'spki' });
    const ok = crypto.verify(null, Buffer.from(messageB64, 'base64'), keyObject, Buffer.from(signatureB64, 'base64'));
    return { verified: ok, reason: ok ? 'independently verified with Node\'s crypto module' : 'signature does NOT match' };
  } catch (e) {
    return { verified: null, reason: `verification error: ${e.message}` };
  }
}

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>VaultSigner RPC Demo (Node.js)</title>
<style>
  :root { color-scheme: dark; }
  body { background: #111; color: #ddd; font: 14px -apple-system, sans-serif; max-width: 720px; margin: 32px auto; padding: 0 16px; }
  h1 { font-size: 18px; }
  p.lead { color: #aaa; line-height: 1.5; }
  code { background: #222; padding: 1px 5px; border-radius: 3px; }
  select, textarea, button { font: inherit; background: #222; color: #eee; border: 1px solid #444; border-radius: 6px; padding: 6px 10px; }
  select { width: 100%; }
  textarea { width: 100%; box-sizing: border-box; resize: vertical; }
  button { background: #2d6cdf; border-color: #2d6cdf; cursor: pointer; }
  button:disabled { background: #333; border-color: #444; color: #888; cursor: default; }
  button.secondary { background: #222; border-color: #444; }
  label { display: block; margin: 18px 0 6px; font-weight: 600; }
  #log { background: #000; border: 1px solid #333; border-radius: 6px; padding: 10px; height: 220px; overflow-y: auto; white-space: pre-wrap; font: 12px ui-monospace, monospace; margin-top: 18px; }
  .row { display: flex; gap: 8px; align-items: center; }
</style>
</head>
<body>
<h1>VaultSigner RPC Demo — Node.js</h1>
<p class="lead">
  This page is served by a plain Node.js script with zero dependencies.
  It never imports vaultcore or any VaultSigner code — it only speaks
  the documented local JSON-RPC protocol (spec §7) to your real,
  already-running <code>VaultSignerAgent</code>, over its Unix socket.
  If the list below is empty, that's correct until you unlock a
  compartment the normal way in VaultSigner.app.
</p>

<label>Key to sign with</label>
<div class="row">
  <select id="keySelect"></select>
  <button class="secondary" id="refreshBtn">Refresh</button>
</div>

<label>Message to sign</label>
<textarea id="message" rows="3">Hello from a Node.js demo app!</textarea>

<div class="row" style="margin-top: 14px;">
  <button id="signBtn">Request Signature</button>
</div>

<div id="log"></div>

<script>
let keys = [];

function log(text) {
  const el = document.getElementById('log');
  el.textContent += text + "\\n";
  el.scrollTop = el.scrollHeight;
}

async function rpc(method, params) {
  const res = await fetch('/rpc', { method: 'POST', body: JSON.stringify({ method, params }) });
  return res.json();
}

async function refreshKeys() {
  log('Connecting to the real VaultSignerAgent...');
  const resp = await rpc('vaultsigner.list_public_keys', {});
  if (resp.error) {
    log('Could not list keys: ' + resp.error.code + ' — ' + resp.error.message);
    if (resp.error.code === 'connection_error') {
      log('Is VaultSignerAgent running? Launch VaultSigner.app first.');
    }
    return;
  }
  keys = resp.result.keys;
  const select = document.getElementById('keySelect');
  select.innerHTML = '';
  if (keys.length === 0) {
    log('Connected, but no keys are visible. This means no compartment is unlocked in the agent yet.');
    log('Open your vault in VaultSigner.app (or enable auto-unlock in Settings), then click Refresh.');
    return;
  }
  for (const k of keys) {
    const opt = document.createElement('option');
    opt.value = k.key_id;
    opt.textContent = k.label + '  (' + k.resource + ')  ' + k.key_id.slice(0, 8) + '…';
    select.appendChild(opt);
  }
  log('Found ' + keys.length + ' key(s) in the currently unlocked compartment(s).');
}

document.getElementById('refreshBtn').addEventListener('click', refreshKeys);

document.getElementById('signBtn').addEventListener('click', async () => {
  const select = document.getElementById('keySelect');
  if (!select.value) { log('No key selected — click Refresh first.'); return; }
  const message = document.getElementById('message').value;
  const messageB64 = btoa(unescape(encodeURIComponent(message)));
  const signBtn = document.getElementById('signBtn');
  signBtn.disabled = true;
  log('');
  log("Sending vaultsigner.sign for key " + select.value + " ...");
  log('VaultSigner names the caller itself, from OS socket peer credentials');
  log('(never from anything this page claims) — watch its prompt name this');
  log('process by its real executable name, e.g. "node".');
  log('Waiting for approval in VaultSigner — a password prompt should appear now...');
  try {
    const resp = await rpc('vaultsigner.sign', { key_id: select.value, message_b64: messageB64 });
    if (resp.error) {
      log('Signing declined: ' + resp.error.code + ' — ' + resp.error.message);
    } else {
      log('Signature received!');
      log('  signature (b64): ' + resp.result.signature_b64);
      log('  public key (b64): ' + resp.result.public_key_b64);
      const verifyResp = await fetch('/verify', {
        method: 'POST',
        body: JSON.stringify({ public_key_b64: resp.result.public_key_b64, message_b64: messageB64, signature_b64: resp.result.signature_b64 }),
      }).then((r) => r.json());
      log('  ' + (verifyResp.verified === true ? '✓ ' : verifyResp.verified === false ? '✗ ' : '') + verifyResp.reason);
    }
  } catch (e) {
    log('Connection problem: ' + e.message);
  }
  signBtn.disabled = false;
});

refreshKeys();
</script>
</body>
</html>
`;

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(PAGE);
    return;
  }

  if (req.method === 'POST' && (req.url === '/rpc' || req.url === '/verify')) {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', async () => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      try {
        const payload = JSON.parse(body);
        if (req.url === '/verify') {
          res.end(JSON.stringify(verifyEd25519(payload.public_key_b64, payload.message_b64, payload.signature_b64)));
        } else {
          const result = await rpcCall(payload.method, payload.params || {});
          res.end(JSON.stringify(result));
        }
      } catch (err) {
        const code = err.code === 'ENOENT' ? 'connection_error' : 'internal_error';
        res.end(JSON.stringify({ error: { code, message: err.message } }));
      }
    });
    return;
  }

  res.writeHead(404);
  res.end();
});

server.listen(PORT, () => {
  const url = `http://localhost:${PORT}`;
  console.log(`VaultSigner RPC demo (Node.js) running at ${url}`);
  console.log(`Talking to the real VaultSignerAgent at ${SOCKET_PATH}`);
  if (process.platform === 'darwin') exec(`open ${url}`);
});
