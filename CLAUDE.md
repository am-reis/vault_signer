# Repository guide

This file is loaded automatically at the start of every Claude Code session in this repository. It documents the branching model, release process, and where to find things in history.

## Branch model

| Branch | Purpose | Commit here directly? |
|---|---|---|
| `main` | Permanent, tagged release history. Every tagged commit on `main` corresponds to at least one platform (or `vaultcore`) release — see Versioning below for why "one version tag" isn't a single shared number. | No — only merged from `release`, then tagged immediately. |
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
2. Freeze: package, sign, update `CHANGELOG.md`. If this cycle bumps `vaultcore` (see Versioning below), update `vaultcore/Cargo.toml`'s `version` too — independently of whatever platform version is also being cut.
3. Merge `release` into `main`, and tag `main`'s new commit with **the tag(s) for whatever actually changed** — `macos-vX.Y.Z` and/or `windows-vX.Y.Z` (one commit can carry more than one tag if multiple platforms happened to be ready at once), plus `vaultcore-vA.B.C` if this cycle bumped it.
4. Build release artifacts (see below) and publish them against each platform tag just cut.
5. Merge `release`'s final state back into `staging` (picks up anything fixed during the freeze).

### Hotfixing an already-shipped version

If a shipped platform version needs an urgent fix while `staging`/`release` have since moved on:

1. Branch `hotfix/<name>` directly from the affected platform's tag on `main` (e.g. `macos-v0.2.0`).
2. Fix, merge into `main`, tag the new PATCH version for that same platform.
3. Merge the same fix into `release`, `staging`, and whichever `shared`/`platform/*` branch owns the affected files, so the next regular release doesn't reintroduce it.

## Versioning

SemVer: `vMAJOR.MINOR.PATCH`, e.g. `v0.1.0`. Pre-1.0 (per SemVer §4): MINOR for anything meaningfully new or breaking, PATCH for fixes-only batches. Switch to strict SemVer (MAJOR = breaking change) at `v1.0.0`.

**Tags are per platform, not one shared number for the monorepo**: `macos-vX.Y.Z`, `windows-vX.Y.Z`, and so on as each platform ships. Each is its own independent SemVer line, cut whenever that platform's own release cycle completes — a Windows-only release does not bump macOS's number, and vice versa. This replaced an earlier one-global-tag scheme once a second platform (Windows) got close enough to release that the old scheme's real cost showed up: a shared tag like `v1.0.0` reads to an outside developer as "every platform this project claims to support," and a platform-only change under a shared tag silently re-publishes every *other* platform's artifacts as if they'd changed too, when they hadn't.

**`vaultcore` is versioned independently of every platform, but is never released on its own**: it has no independent release process (it's never published to crates.io — `publish = false` in `vaultcore/Cargo.toml` — and ships only bundled inside a platform's own release artifacts, below). Its `Cargo.toml` version is instead reasoned about purely by *its own* changes — a container-format or protocol-breaking change is MAJOR, a new capability is MINOR, a fixes-only batch is PATCH — completely decoupled from whatever number any platform's app happens to carry. When it moves, tag that exact commit on `shared` as `vaultcore-vA.B.C`: a plain, lightweight tag with **no GitHub Release and no artifacts attached to the tag itself** — it exists purely as a precise, referenceable marker in history (e.g. for someone tracking exactly what protocol/format version a given platform release actually shipped), not as a distribution event.

## Commit signing

Commits will be required to carry a verified PGP signature once the corresponding key is added to this repository's configuration. Not yet in effect.

## Release artifacts

Built artifacts are published as GitHub Releases attached to the corresponding platform tag on `main` — not committed into git history. Each macOS release publishes two files, built via `apps/macos/Scripts/package-release.sh` from a validated `release`-branch checkout, taking both the platform version and vaultcore's own current version as separate arguments:

- `VaultSigner-macOS-vX.Y.Z.zip` — the signed application, matching that release's `macos-vX.Y.Z` tag, for end users.
- `vaultcore-vA.B.C-macos.zip` — the compiled library, headers, and generated Swift bindings, named for **vaultcore's own version** (`vaultcore-vA.B.C`), not the platform's — for developers who want to use vaultcore without building it themselves. `A.B.C` and the platform's own `X.Y.Z` will often differ; that's expected, not a bug — see Versioning above.

Opening a downloaded copy on another Mac triggers Gatekeeper's "unidentified developer" warning (right-click → Open bypasses it). Developers can avoid this by building from source with their own Apple ID instead. Wide, public-facing distribution — Developer ID signing and notarization — isn't part of this project's current stage.

Publish via the GitHub web UI (Releases → Draft a new release → select the platform tag → upload its files → paste the corresponding `CHANGELOG.md` entries as the release notes), or with the `gh` CLI once installed: `gh release create macos-vX.Y.Z <files> --notes-file <changelog-section>`. `vaultcore-vA.B.C` tags never get a GitHub Release of their own — they're plain tags, not distribution events.

## Finding things in history

- Shared-code history: `git log shared`
- macOS history: `git log platform/macos`
- What shipped and when, per platform: `git log main --oneline` and `git tag --list "macos-*"` / `git tag --list "windows-*"` (or `git tag --list` for everything, `vaultcore-*` included)
- A specific release's exact source: check out its tag directly, e.g. `git checkout macos-v0.1.0`
