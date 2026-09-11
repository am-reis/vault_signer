---
title: Protocol Specification
---

# VaultSigner Local Signing Protocol — Specification

**Protocol version: 1.0** (see Revision History at the end of this document)

## Status of this document

This is the normative, formal reference for the protocol summarized in
[`README.md`](README.md) in this same directory. Where the two disagree,
this document is authoritative; `README.md` stays as the friendly,
example-driven front door and should be read first by someone integrating
for the first time. Per-platform transport specifics (socket/pipe paths,
ACLs, working code) live in `apps/<platform>/docs/protocol-integration.md`
and are out of scope here — this document covers only what's identical
across every platform.

This protocol was originally described informally in
[`spec/VaultSigner-Spec.md`](../../spec/VaultSigner-Spec.md) §7, as part of
VaultSigner's own build process rather than as a document meant for outside
readers. This specification supersedes that section as the authoritative
description of the protocol itself; §7 remains as historical record of the
original design decision.

**Versioning linkage:** per `CLAUDE.md`'s Versioning section, `vaultcore`
versions independently by reasoning about its own changes. For changes to
the protocol surface specifically, *this document* is that reasoning made
concrete: a change here that removes or redefines an existing method,
field, or error code is a breaking (MAJOR) change for `vaultcore`; a
backward-compatible addition is MINOR. See §9.

## 1. Conformance language

"MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" are used with the
meanings conventionally associated with those terms (as in RFC 2119).
"The server" means whatever process on the local machine is answering
requests (`VaultSignerAgent`, `VaultSignerService`, or equivalent per
platform); "a client" or "the caller" means the third-party application
sending requests.

## 2. Scope and non-goals

This protocol exists for a third-party application that needs a raw
cryptographic signature over data it controls, using a key the user keeps
in VaultSigner, outside of a WebAuthn/passkey ceremony. It is not the
mechanism VaultSigner uses to participate in passkey flows — that happens
through the operating system's own credential-provider APIs, and a client
of this protocol never mediates that path. See §10 for the full boundary.

## 3. Transport contract

This protocol is transport-agnostic in its message layer (§4), but every
transport a platform provides MUST satisfy the following, regardless of
the underlying OS mechanism:

- **Local-only.** MUST NOT be reachable over a network. A TCP-based
  transport MUST bind loopback only (`127.0.0.1`), never a
  wildcard/non-loopback address.
- **Owner-restricted.** MUST restrict connectivity to processes running as
  the same OS user account, at minimum (e.g. `0600` permissions on a Unix
  domain socket, an owner-only ACL on a Windows named pipe).
- **Caller identity resolved out-of-band.** The server MUST resolve the
  calling process's identity via an OS-level mechanism (peer credentials,
  named-pipe client process lookup, or equivalent) for display in the
  consent prompt (§7). It MUST NOT accept or trust any self-reported name
  or identity carried in the request payload for that purpose — there is
  no field in this protocol for a caller to name itself, by design.
- **No prior registration.** A client MUST be able to call
  `vaultsigner.list_public_keys` and `vaultsigner.sign` without any prior
  registration, shared secret, or out-of-band configuration with
  VaultSigner beyond reaching the transport endpoint. (§3.1 documents the
  one platform where this doesn't hold.)
- **Framing.** Newline-delimited, UTF-8-encoded JSON text: exactly one
  JSON object per line (`\n`-terminated), on both the request and response
  side. A single connection MAY be reused for more than one
  request/response pair in sequence; a client is not required to
  reconnect between calls, and the server MUST NOT require it to.

### 3.1 iOS exception

iOS has no persistent background listener, so the transport contract above
does not apply there. Per spec §7.1, iOS instead exposes this protocol
through an App Intents / Shortcuts-based hand-off, which requires the
calling app to have pre-integrated the App Intent — a materially narrower
discovery model than "reach the socket, no prior relationship needed."
This is a scoped-down capability specific to iOS's platform constraints,
not a deviation this specification otherwise permits.

## 4. Message envelope

### 4.1 Request object

| Field | Type | Required | Notes |
|---|---|---|---|
| `method` | string | Yes | One of the method names in §5, or rejected per §6. |
| `params` | object | No | Defaults to an empty object for methods that define no required fields. Omitting it for a method that has required fields (`vaultsigner.sign`) yields `invalid_params`. |
| `id` | string \| number \| null | Yes | Echoed back verbatim in the response. See note below. |

A request that is not valid JSON, or that is valid JSON but is missing
`method` or `id` entirely, MUST be rejected with `parse_error` and
`id: null` — an id that was never successfully parsed cannot be echoed.
Fields not listed above (at either the request's top level or within
`params`) MUST be ignored by the server, not rejected: this is what lets a
future, backward-compatible field be added without breaking existing
clients (§9).

`id` accepts any JSON value in the reference implementation and is echoed
back exactly as received, but a client SHOULD restrict itself to a string,
number, or `null` — that is the conventional JSON-RPC-style usage this
protocol follows, and the only shape future versions of this document are
committed to keeping well-defined.

### 4.2 Response object

Exactly one of `result` or `error` is present, never both, alongside `id`:

```json
{ "id": 1, "result": { /* method-specific, see §5 */ } }
```
```json
{ "id": 1, "error": { "code": "user_declined", "message": "user declined the signing request" } }
```

### 4.3 Error object

`{ "code": string, "message": string }`. `code` is one of the fixed values
in §6, or a documented implementation-specific extension (§6.1) — a client
MUST treat any `code` it doesn't recognize as non-retryable unless the
platform-specific guide it's integrating against documents otherwise.
`message` is for humans and logs; its exact wording MAY change between
releases without that being a breaking change, and a client MUST NOT
pattern-match on it.

## 5. Methods

### 5.1 `vaultsigner.list_public_keys`

Discovery: every key VaultSigner is currently willing to disclose.

- `params`: no fields defined; any value (including absent) is accepted
  and ignored.
- `result`: `{ "keys": PublicKeyInfo[] }`, where each `PublicKeyInfo` is
  exactly:

  | Field | Type |
  |---|---|
  | `key_id` | string (UUID) |
  | `label` | string |
  | `public_key_b64` | string (base64, see §5.2) |
  | `resource` | string |

  No other field is ever present — in particular, never private key
  material, and never anything about a key whose compartment isn't
  currently unlocked.

- An empty `keys` array is a normal result, not an error: it means no
  compartment is currently unlocked, not that VaultSigner has no keys at
  all. A client MUST NOT treat it as a failure.

### 5.2 `vaultsigner.sign`

- `params`:

  | Field | Type | Required | Notes |
  |---|---|---|---|
  | `key_id` | string | Yes | MUST be a syntactically valid UUID, as returned by `list_public_keys`. Any UUID version is accepted. |
  | `message_b64` | string | Yes | Standard-alphabet, padded base64 (RFC 4648 §4) of the exact bytes to sign. The server signs these bytes as given — it does not hash or otherwise transform them first. |
  | `algorithm` | string | No | Informational only. The server signs with the key's actual stored type regardless of this value; it exists so a request is self-describing, not to select a signing mode. |

- `result`: `{ "signature_b64": string, "public_key_b64": string }`. The
  signature's format matches the key's type: a raw 64-byte Ed25519
  signature, or a DER-encoded ECDSA P-256 signature. `public_key_b64` is
  included so a client can verify the signature immediately without a
  second round trip.

- A request whose `key_id` isn't a valid UUID, or whose `message_b64`
  isn't valid base64, MUST be rejected with `invalid_params` before the
  key lookup, consent prompt, or throttle check (§8) are ever reached.

## 6. Errors

| Code | Meaning | Retryable? |
|---|---|---|
| `parse_error` | The request wasn't valid JSON, or was missing a required top-level field (`method`, `id`). | Fix the request and retry. |
| `method_not_found` | Unknown method name. Only `vaultsigner.list_public_keys` and `vaultsigner.sign` exist in this namespace. | No — check the method name. |
| `invalid_params` | `params` was missing a required field for that method, or a field had the wrong type/format. | Fix the request and retry. |
| `key_not_found` | No key with that `key_id` exists in the currently unlocked state the server is willing to disclose. | Only after re-checking `list_public_keys`. |
| `user_declined` | The person shown the consent prompt clicked Deny. | Only if the user initiates a new attempt themselves — never retry automatically. |
| `passphrase_incorrect` | The passphrase entered at the prompt was wrong for this key. | Yes, subject to §8. |
| `key_locked_retry_later` | Rate-limited — see §8. | After the backoff period elapses. |
| `no_vault_open` | The server is running but has no vault open at all (e.g. a fresh install, before the user has created or opened one). | Only after the user opens a vault in VaultSigner's own UI. |

`no_vault_open` was, until this document, described in each platform's own
integration guide as an "agent-specific" addition beyond a smaller core
list. It is promoted to this core table because both platforms that
currently implement this protocol (macOS, Windows) already define it
identically — a future platform reinventing its own name for "no vault is
open" is exactly the kind of drift a shared, formal spec exists to
prevent. Implementations MUST use this code, not a platform-specific
synonym, for this condition.

### 6.1 Implementation-specific extensions

A server MAY define additional error codes for conditions genuinely
outside this document's scope. Any such code MUST be documented in that
platform's own integration guide, and MUST NOT reuse or redefine the
meaning of a code listed in §6.

## 7. Authorization and consent

Every `vaultsigner.sign` call MUST result in a prompt shown to a human
before any signature is produced or any error other than `parse_error`,
`method_not_found`, `invalid_params`, `key_not_found`, or
`key_locked_retry_later` is returned. That prompt MUST display the
caller identity resolved per §3, naming it before the passphrase field
(for example: "`your-app` wants to sign with key 'Deploy signing key'").

There is no field or method in this protocol that suppresses, pre-fills,
or renames this prompt. A client cannot make it claim to be a different
application than the one the OS actually resolved. Screen-capture blocking
(spec §5.0) applies to this prompt on every platform.

## 8. Rate limiting

Enforced once per `key_id`, before the server ever invokes its signing
backend for that key — a throttled key's backend is not consulted at all,
even if the request would otherwise have succeeded.

State per key: a consecutive-failure counter and an optional
lock-expiry timestamp. On each attempt:

1. **Before verification:** if the key is currently locked (see below),
   the server MUST return `key_locked_retry_later` without attempting to
   verify the passphrase.
2. **On a wrong passphrase:** the failure counter increments. Once it
   reaches the threshold (default 5), the key becomes locked for:

   ```
   delay = min(max_delay, base_delay * 2^(consecutive_failures - threshold))
   ```

   with reference defaults `threshold = 5`, `base_delay = 1s`,
   `max_delay = 300s` — i.e. the 5th consecutive wrong attempt locks the
   key for 1 second, the 6th for 2 seconds, doubling each further failure
   up to a 5-minute cap.
3. **On a correct passphrase:** the counter and any lock are cleared
   entirely. This, or the backoff period elapsing on its own, are the
   *only* two ways a lock ends — there is no request shape a client can
   send to reset its own lockout.
4. **`key_not_found` and `user_declined` do not affect this state at
   all** — only a wrong passphrase counts as a failure. A client
   probing for valid `key_id`s, or a user who declines the prompt, cannot
   accidentally (or deliberately) lock a key out.

Scope: throttling is per `key_id`, shared machine-wide across every
calling application — a lockout is a property of the key, not of any one
client relationship, and is visible to (and imposed on) every caller
equally. A lockout on one key never affects any other key, even one
sharing the same UUID as a different kind of secret internally (master
password, transfer password) — those are namespaced independently.

The default constants above are the reference implementation's. A
conforming implementation MAY use different values but MUST document them
if they differ, since a client may reasonably build retry/backoff UI
around these numbers.

## 9. Versioning of this protocol

This document carries its own version number (top of file, and the
Revision History below), independent of any platform application's own
version and independent of `vaultcore`'s crate version. Per `CLAUDE.md`:

- Removing or redefining an existing method, field, error code, or
  documented behavior in this document is a **breaking (MAJOR)** change
  for `vaultcore`.
- A backward-compatible addition — a new method, a new optional field, a
  new error code that doesn't repurpose an existing one — is a **MINOR**
  change.
- An edit that documents existing behavior more precisely, without
  changing what a conforming server actually does, is not itself a
  version-triggering change.

There is currently no version-negotiation field in the wire format itself
(no `protocol_version` in the request/response envelope). This is a known
gap, not an oversight: solving it speculatively, before a real breaking
change exists to design around, would likely guess wrong about what that
change needs. The first breaking change to this document is also
responsible for introducing whatever negotiation mechanism it needs.

## 10. What this protocol does not cover

- **`internal.*` methods** may exist on the same transport on some
  platforms, but are a separate, authenticated namespace reserved
  exclusively for VaultSigner's own management application (spec §8) —
  not a stable or supported surface for third-party integration.
- **FIDO2/WebAuthn/passkeys.** VaultSigner participates in those flows as
  a standard OS credential provider; a client never mediates that through
  this protocol.
- **Container mutation** — creating keys, importing/exporting, changing
  passphrases. This protocol is read-and-sign only; those operations
  happen in VaultSigner's own UI.

## Revision history

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-09-10 | Initial formal specification, describing the protocol as implemented at this date (`vaultcore` pre-1.0, in active development). Promotes `no_vault_open` from a platform-specific addition to the core error catalog (§6). |
