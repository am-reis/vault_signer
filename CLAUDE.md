# Repository guide

This file is loaded automatically at the start of every Claude Code session in this repository. It documents the branching model, release process, and where to find things in history.

## Branch model

| Branch | Purpose | Commit here directly? |
|---|---|---|
| `main` | Permanent, tagged release history. Every commit on `main` corresponds to exactly one version tag. | No — only merged from `release`, then tagged immediately. |
| `release` | Freeze for the next release: packaging, signing, changelog, release-blocking fixes only. | Release-blocking fixes only. |
| `staging` | Integration and realistic, production-like testing of a batch before it ships. | No — receives merges from `shared` and `platform/*` only. |
| `shared` | Source of truth for cross-platform code: `vaultcore/`, `spec/`, `docs/`, `i18n/`, `platform/` (the browser-extension-fallback strategy doc — an existing top-level directory, unrelated to the `platform/*` branch prefix below), and repo-level files (`Cargo.toml`, `Cargo.lock`, `.gitignore`, `LICENSE`, `README.md`, `CLAUDE.md`, `CHANGELOG.md`). | Yes — directly, or via a short-lived `shared/<topic>` branch merged back in. |
| `platform/macos` (and, once they exist, `platform/ios`, `platform/android`, `platform/windows`, `platform/linux`) | One branch per platform app. | Yes — platform-only paths (`apps/<name>/`, and currently `demos/`), directly or via a short-lived `platform/<name>/<topic>` branch merged back in. |

Path ownership is a convention, not a physical split — `shared`'s tree is not scrubbed of platform directories. Deleting them there would make every future `shared → platform/*` merge conflict permanently on those paths. Commit shared-scope changes only on `shared`; commit platform-scope changes only on the relevant `platform/*` branch.

`PROGRESS.md` is a single cross-cutting project journal, edited from whichever branch the work happened on.

## Flow

```
shared, platform/*  ->  staging  ->  release  ->  main (tag here)
   (+ short-lived <branch>/<topic> branches merged back into their parent)
```

- Merge `shared` into active `platform/*` branches often — small, frequent merges, not one big merge at release time.
- If a shared-scope bug surfaces while working on a platform branch, commit the platform-side fix if immediate unblocking is needed, but also cherry-pick that same commit onto `shared` and merge it back down. A shared-path fix must never exist on only one platform branch.
- `staging` only receives merges — nothing is committed there directly.
- `release` is a freeze: no new feature work lands there. Only release-blocking fixes, each of which also gets merged into `staging` (and `shared`/`platform/*` if it touches those paths) so it isn't lost or reintroduced later.

### Starting a new release cycle

1. Merge the current `staging` tip into `release` (fast-forward if `release` picked up no freeze-only fixes since the last release; a real merge if it did).
2. Freeze: package, sign, update `CHANGELOG.md`, bump `vaultcore/Cargo.toml`'s `version` to match.
3. Merge `release` into `main`, tag `main`'s new commit `vMAJOR.MINOR.PATCH`.
4. Build release artifacts (see below) and publish them against that tag.
5. Merge `release`'s final state back into `staging` (picks up anything fixed during the freeze).

### Hotfixing an already-shipped version

If a shipped tag needs an urgent fix while `staging`/`release` have since moved on:

1. Branch `hotfix/<name>` directly from the affected tag on `main`.
2. Fix, merge into `main`, tag the new PATCH version.
3. Merge the same fix into `release`, `staging`, and whichever `shared`/`platform/*` branch owns the affected files, so the next regular release doesn't reintroduce it.

## Versioning

SemVer: `vMAJOR.MINOR.PATCH`, e.g. `v0.1.0`. Pre-1.0 (per SemVer §4): MINOR for anything meaningfully new or breaking, PATCH for fixes-only batches. Switch to strict SemVer (MAJOR = breaking change) at `v1.0.0`.

One global tag covers the whole monorepo for now, not one per platform — revisit once a second platform ships for real, so a change to one platform alone doesn't force a version bump implying every platform changed.

`vaultcore/Cargo.toml`'s `version` field is kept in lockstep with the git tag as part of the release freeze, unless/until vaultcore is published standalone (e.g. to crates.io) with its own independent version.

## Commit signing

Commits will be required to carry a verified PGP signature once the corresponding key is added to this repository's configuration. Not yet in effect.

## Release artifacts

Built artifacts are published as GitHub Releases attached to the corresponding tag on `main` — not committed into git history. Each macOS release publishes two files, built via `apps/macos/Scripts/package-release.sh` from a validated `release`-branch checkout:

- `VaultSigner-macOS-vX.Y.Z.zip` — the signed application, for end users.
- `vaultcore-vX.Y.Z-macos.zip` — the compiled library, headers, and generated Swift bindings, for developers who want to use vaultcore without building it themselves.

Opening a downloaded copy on another Mac triggers Gatekeeper's "unidentified developer" warning (right-click → Open bypasses it). Developers can avoid this by building from source with their own Apple ID instead. Wide, public-facing distribution — Developer ID signing and notarization — isn't part of this project's current stage.

Publish via the GitHub web UI (Releases → Draft a new release → select the tag → upload the files → paste the corresponding `CHANGELOG.md` section as the release notes), or with the `gh` CLI once installed: `gh release create vX.Y.Z <files> --notes-file <changelog-section>`.

## Finding things in history

- Shared-code history: `git log shared`
- macOS history: `git log platform/macos`
- What shipped and when: `git log main --oneline` and `git tag --list`
- A specific release's exact source: check out its tag directly, e.g. `git checkout v0.1.0`
