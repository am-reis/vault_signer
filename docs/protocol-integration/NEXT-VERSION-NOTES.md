# Notes for the next protocol version

This is a running, informal backlog — not a specification, and nothing
here is decided. It exists so an idea or a gap found during real use
doesn't get lost between now and whenever the next protocol version
actually gets planned. An entry here is a starting point for that future
planning conversation, not a commitment to build it a specific way.

When an entry is actually designed and implemented, it moves into
[`PROTOCOL-SPEC.md`](PROTOCOL-SPEC.md) as a real, versioned change (see
that document's §9) and gets removed from here.

---

## 1. Multiple open vaults should all be visible to `list_public_keys`/`sign`

**Issue:** `vaultsigner.list_public_keys` and `vaultsigner.sign` only ever
see the single vault currently open in the agent process. On both
platforms today, the agent holds at most one `Vault` instance at a time
(macOS's `AgentServer.vault: Vault?`, Windows's equivalent) — opening a
different vault replaces it, it doesn't add to it.

**Why this is worth revisiting:** the reason VaultSigner has two separate
locks — a vault/compartment passphrase that only reveals key *metadata*,
and each key's own passphrase required to actually sign with it — is
specifically so a vault or compartment can be left open without that
alone being a signing risk (real signing capability still requires the
key's own passphrase, still subject to throttling). That reasoning
doesn't stop at "one vault." If leaving a compartment open is safe, there's
no clear reason leaving several *vaults* open at once should be treated
differently — e.g. a "Personal" and a "Work" vault both open
simultaneously, with a caller able to see and sign with keys from either.

**Current behavior, confirmed by reading the code, not assumed:**
`vaultcore::Vault`'s protocol backend (`vaultcore/src/vault.rs`,
`VaultProtocolBackend::list_public_keys`/`sign`) already does exactly the
right thing *within* one open vault — it aggregates across every
currently-unlocked *compartment* in that vault (`state.unlocked.values()`),
not just one. That part already matches the intended model. The actual
limit is one level up: the agent itself can only ever hold one `Vault`
(one vault *file*) open at all, so multi-compartment aggregation never
gets the chance to span more than one file.

**Not decided — needs real design, not a quick patch:**
- What identifies a key across multiple open vaults for `list_public_keys`
  and `sign` — `key_id` today is only unique within one vault's manifest.
- Whether the response shape needs to say which vault a key came from
  (a new field third-party callers would need to start handling), or
  whether that can stay invisible to them.
- How this interacts with the "known vaults" UI concept (spec §5.6) and
  the recent single-vault-owner redesign on both platforms (`Vault?`) —
  this is a real change to the agent's core state model, not just to the
  wire format.
- Whether every platform needs to support this on day one, or whether it
  can land per-platform like everything else has so far.

**Likely versioning weight** (per `PROTOCOL-SPEC.md` §9, once actually
designed): MINOR if it lands as a backward-compatible addition (e.g. an
optional field existing callers can ignore), MAJOR if the response shape
itself has to change in a way existing callers can't ignore.
