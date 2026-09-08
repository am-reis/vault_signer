# vault_signer
A portable, compact, multi-platform cryptographic signer.

Monorepo layout, spec, and execution plan: [`spec/VaultSigner-Spec.md`](spec/VaultSigner-Spec.md).
Current implementation status: [`PROGRESS.md`](PROGRESS.md).

## Downloads

Built, ready-to-use releases are published on the [Releases page](https://github.com/am-reis/vault_signer/releases), attached to their version tag. Each macOS release includes the signed application (for end users) and a standalone build of the `vaultcore` library with its Swift bindings (for developers who want to use it without building from source).

These builds are signed with an Apple Development certificate, not a Developer ID. Opening a downloaded copy on another Mac will trigger Gatekeeper's "unidentified developer" warning — right-click the app and choose Open to bypass it. Publishing without that warning requires Developer ID signing and notarization, which needs a paid Apple Developer Program membership; this project does not currently have one.

Developers who prefer to avoid the Gatekeeper warning entirely, or who want a build signed with their own certificate, can build from source instead — see `apps/macos/README.md`.

## Branching and releases

This repository uses a strict shared/platform branch separation with a staged release process. See [`CLAUDE.md`](CLAUDE.md) for the full branch model, release cycle, versioning scheme, and where to find things in history.
