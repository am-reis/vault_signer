# Integrating with VaultSigner's local signing protocol

This is the reference for third-party applications that want VaultSigner to sign data on their behalf, or to let a user pick a key for that purpose. It covers the protocol itself — message format, methods, authorization behavior, error codes — which is identical across every desktop platform. Platform-specific transport details (socket paths, discovery, launch behavior, and runnable code) live in a separate guide per platform, linked at the bottom.

If you're building a login or account-registration flow using passkeys/WebAuthn, **this document is not what you need.** VaultSigner participates in those flows as a standard OS credential provider (Apple's `AuthenticationServices`, Android's Credential Manager, Windows Hello, etc.) — you integrate with the OS's own passkey APIs exactly as you would for any other passkey provider, and never talk to the socket described here directly.

This document is for a different case: your app needs a raw cryptographic signature over some data it controls, using a key the user keeps in VaultSigner (deploy signing, artifact signing, commit signing, or similar), and it isn't going through a WebAuthn ceremony.

## What this is

A local, machine-only protocol. Every request and response is one JSON object. There is no network exposure and no authentication token — the security model is: the calling process must be running on the same machine as VaultSigner (enforced by the transport itself, never by anything in this document), and every signing request is shown to a human, who has to approve it by typing the key's passphrase. Your app cannot suppress that prompt, and it cannot make the prompt claim to be someone other than what it actually is (see **Authorization**, below).

## Message format

Each request:

```json
{ "method": "vaultsigner.sign", "params": { "key_id": "...", "message_b64": "...", "algorithm": "ed25519" }, "id": 1 }
```

Each response is either a result:

```json
{ "id": 1, "result": { "signature_b64": "...", "public_key_b64": "..." } }
```

or an error:

```json
{ "id": 1, "error": { "code": "user_declined", "message": "user declined the signing request" } }
```

`id` is echoed back unchanged — use it to match responses to requests if you ever pipeline more than one over a connection. Binary values (the message to sign, the returned signature, public keys) are always base64, never raw bytes in the JSON itself.

## Methods

### `vaultsigner.list_public_keys`

Discovery: returns every key VaultSigner is willing to disclose, so your app can let the user pick one without needing any prior relationship with VaultSigner or any out-of-band configuration.

Request: `{ "method": "vaultsigner.list_public_keys", "params": {}, "id": 1 }`

Result:

```json
{
  "keys": [
    { "key_id": "b3f1...", "label": "Deploy signing key", "public_key_b64": "...", "resource": "example.com" }
  ]
}
```

Only `key_id`, `label`, `public_key_b64`, and `resource` are ever returned — never private key material, and never anything about a key that hasn't been explicitly unlocked (see the platform guide for what "unlocked" depends on; it's outside your app's control).

### `vaultsigner.sign`

Request: `{ "method": "vaultsigner.sign", "params": { "key_id": "<uuid>", "message_b64": "<base64>", "algorithm": "ed25519" }, "id": 2 }`

- `key_id` — a UUID from `list_public_keys`.
- `message_b64` — the exact bytes to sign, base64-encoded. VaultSigner signs these bytes as given; it does not hash or transform them first.
- `algorithm` — informational only. VaultSigner signs with the key's actual type regardless of what's passed here; it exists so your request is self-describing, not to select a mode.

Result: `{ "id": 2, "result": { "signature_b64": "...", "public_key_b64": "..." } }`

The signature format matches the key's type: a raw 64-byte Ed25519 signature, or a DER-encoded ECDSA P-256 signature. `public_key_b64` is included so you can verify the signature immediately without a second round trip.

## Authorization

Every `sign` call shows the same passphrase prompt a human would see for any other key operation, naming the calling application before the passphrase field — for example, "`your-app` wants to sign with key 'Deploy signing key'." That name is resolved by VaultSigner from OS-level process identity (the connecting process's own executable, verified by the operating system), **never** from anything in your request. There's no field in this protocol for a caller to name itself, because that name would be meaningless as a security signal — the whole point is that the human sees who is *actually* asking, not who claims to be asking.

Practically: you cannot skip this prompt, you cannot pre-fill it, and you cannot make it show a different name than your app's own. Design your UI around a real pause here — the response won't come back until a human has answered.

## Rate limiting

After 5 consecutive wrong passphrase attempts for a given key, further attempts against that key are refused with `key_locked_retry_later` for a backoff period that starts at 1 second and doubles with each additional failure, capped at 5 minutes — independent of whichever application is asking. A successful attempt resets the count. This applies per key, so a lockout on one key never affects any other key or any other application.

## Errors

| Code | Meaning | Retryable? |
|---|---|---|
| `parse_error` | The request wasn't valid JSON, or didn't match the expected shape. | Fix the request and retry. |
| `method_not_found` | Unknown method name. Only `vaultsigner.list_public_keys` and `vaultsigner.sign` exist in this namespace. | No — check the method name. |
| `invalid_params` | `params` was missing a required field, or a field had the wrong type/format (e.g. `key_id` isn't a valid UUID, `message_b64` isn't valid base64). | Fix the request and retry. |
| `key_not_found` | No key with that `key_id` exists in the currently unlocked state VaultSigner is willing to disclose. | Only after re-checking `list_public_keys`. |
| `user_declined` | The person shown the prompt clicked Deny. | Only if the user initiates a new attempt themselves — never retry automatically. |
| `passphrase_incorrect` | The passphrase entered at the prompt was wrong for this key. | Yes, subject to rate limiting above. |
| `key_locked_retry_later` | Rate-limited — see above. | After the backoff period elapses. |

A real implementation may surface additional, implementation-specific error codes for conditions outside this core protocol's scope (for example, VaultSigner having no vault open at all) — see the platform-specific guide.

## What this protocol does not cover

- **`internal.*`** methods exist on the same transport on some platforms, but are a separate, authenticated namespace reserved exclusively for VaultSigner's own management application — not for third-party integration. A caller that isn't VaultSigner's own signed application is rejected. Don't build against it; it isn't a stable or supported surface for outside callers, and future versions may reject non-owner callers even more strictly than they do today.
- **FIDO2/WebAuthn/passkeys** — see the note at the top of this document.
- **Container mutation** (creating keys, importing/exporting, changing passphrases) — this protocol is read-and-sign only. Those operations happen in VaultSigner's own UI.

## Platform guides

- macOS: [`apps/macos/docs/protocol-integration.md`](../../apps/macos/docs/protocol-integration.md)
- Windows: [`apps/windows/docs/protocol-integration.md`](../../apps/windows/docs/protocol-integration.md)

Other platforms will be linked here as they ship (spec §7 covers the general transport shape per platform; §7.1 specifically calls out iOS as materially narrower than the socket/pipe model described above, since iOS has no persistent background listener). Writing this addendum is a required part of finishing that platform's phase, not an optional follow-up — see spec §14.
