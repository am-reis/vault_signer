---
title: VaultSigner
---

# vault_signer
A portable, compact, multi-platform cryptographic signer.

Monorepo layout, spec, and execution plan: [`spec/VaultSigner-Spec.md`](spec/VaultSigner-Spec.md).
Current implementation status: [`PROGRESS.md`](PROGRESS.md).

## Downloads

Built, ready-to-use releases are published on the [Releases page](https://github.com/am-reis/vault_signer/releases). Each platform ships and versions independently — a macOS release is tagged `macos-vX.Y.Z`, and includes the signed application (for end users) plus a standalone build of the `vaultcore` library with its Swift bindings, versioned separately as `vaultcore-vA.B.C` (for developers who want the library without building from source). Other platforms follow the same pattern under their own tag as they ship.

Opening a downloaded copy on another Mac will trigger Gatekeeper's "unidentified developer" warning — right-click the app and choose Open to bypass it.

Developers can avoid this entirely by building from source with their own Apple ID — see `apps/macos/README.md`. Wide, public-facing distribution isn't part of this project's current stage.

## Branching and releases

This repository uses a strict shared/platform branch separation with a staged release process. See [`CLAUDE.md`](CLAUDE.md) for the full branch model, release cycle, versioning scheme, and where to find things in history.
