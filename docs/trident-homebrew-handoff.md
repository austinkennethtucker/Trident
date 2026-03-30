# Trident Homebrew + macOS Packaging Handoff

Last updated: 2026-03-30 (signing/CI fixes applied)

This note is for the next agent who works on Trident's private Homebrew install path, release packaging, and macOS app launch behavior.

## Summary

The private Homebrew path is mostly working:

- Private source repo: `subdepthtech/Trident`
- Private tap repo: `subdepthtech/homebrew-trident`
- Stable cask: `subdepthtech/trident/trident`
- Dev cask: `subdepthtech/trident/trident-dev`

The local shell helper in the dotfiles repo is now:

- command: `tha`
- supports: `install`, `upgrade`, `reinstall`, `auth`
- supports targets: `stable`, `dev`, `all`

Example:

```sh
tha install all
tha reinstall dev
tha auth
```

## What Is Working

- Both private casks can be installed through Homebrew using a GitHub token in `HOMEBREW_GITHUB_API_TOKEN`.
- The Proton Pass item used for the token is:
  - vault: `secrets`
  - item: `gh-token-homebrew-trident`
  - field: `Secret`
- The local helper `tha` can export the token, tap the private repo, and install or repair the apps into `/Applications`.
- The installed bundle names are:
  - `/Applications/Trident.app`
  - `/Applications/Trident Dev.app`
- Bundle identifiers are now distinct:
  - `com.subdepthtech.trident`
  - `com.subdepthtech.trident.dev`
- Launch Services and Spotlight now see the real `/Applications` bundles.
- Launching by bundle id works:

```sh
open -b com.subdepthtech.trident
open -b com.subdepthtech.trident.dev
```

## Issues We Hit

### 1. Homebrew said "already installed" but apps were not in `/Applications`

Cause:

- Earlier test installs were done into `/tmp/trident-apps`.
- Homebrew kept that install location in the cask state.
- Later `brew install` runs said "already installed" and did not repair the app location.

Fix/workaround:

- `tha install ...` now checks whether the app exists in `/Applications`.
- If the cask is installed but the app is missing from `/Applications`, it runs `brew reinstall --cask --appdir=/Applications ...`.

### 2. Spotlight and Raycast showed broken launch behavior

Symptoms:

- Spotlight and Raycast showed dialogs like:
  - `The application "Spotlight" does not have permission to open "(null)".`
  - `The application "Raycast" does not have permission to open "(null)".`

What we found:

- Launch Services still had stale registrations for older `Trident.app` copies, including one in `~/.Trash`.
- Re-registering the `/Applications` bundles helped:

```sh
'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister' -f /Applications/Trident.app '/Applications/Trident Dev.app'
mdimport /Applications/Trident.app '/Applications/Trident Dev.app'
```

- After that, `mdfind` returned the `/Applications` copies.
- Launching by bundle id worked.

Remaining note:

- Search providers may still be confused if stale Trident copies remain in Trash or elsewhere.
- It is worth cleaning up old copies and then retesting Spotlight/Raycast.

### 3. macOS signing / trust problem — ROOT CAUSE FOUND

**Status: Root cause identified and fixed (2026-03-30).**

Root cause:

- The release assets on GitHub were built locally, not by CI.
- `macos/build.nu` defaults to `--configuration Debug`, so the Zig library was compiled in Debug mode.
- The app was ad-hoc signed (no Developer ID certificate), causing `codesign --verify` and `spctl` failures.
- The app also showed a "You're running a debug build of Trident!" warning banner.

Why CI never ran:

- `ci.yml` failed because `zig` was not installed on GitHub-hosted runners (no `setup-zig` step).
- `release-tip.yml` had 8 `ghostty-org` owner guards that blocked all jobs on `austinkennethtucker/Trident`.
- `release-tag.yml` was never triggered.
- No signing/notarization secrets were configured in the repo.

Fix applied:

- Rebuilt stable app locally with `macos/install.nu` (defaults to Release + ReleaseFast + Developer ID signing).
- `codesign --verify --deep --strict` now passes.
- `spctl` reports "Unnotarized Developer ID" (signing correct, notarization pending).
- Added `mlugg/setup-zig@v2` to `ci.yml`.
- Simplified `release-tip.yml` (removed owner guards, removed upstream-only jobs).
- Simplified `release-tag.yml` (removed source-tarball, Sentry, appcast, R2 jobs).
- Both release workflows now upload to `subdepthtech/Trident` via cross-repo `gh release upload`.

Remaining:

- **GitHub-hosted runners cannot build the macOS app.** The app requires Xcode 26 (macOS 26 SDK) for `NSGlassEffectView` and other new APIs. GitHub's `macos-latest` currently provides Xcode 16.4. The release workflows are ready but will fail at the Xcode build step until GitHub ships Xcode 26 runners.
- macOS VMs cannot run in Proxmox (Apple license requires Apple hardware), so a self-hosted runner would need dedicated Mac hardware.
- **Current release path is local builds** using `macos/install.nu --dmg` + `gh release upload`. See "Local Release Process" below.
- Repo secrets are configured and ready for when CI runners catch up.

### 4. Stable app showed debug build warning

**Status: Fixed (2026-03-30).**

The stable `/Applications/Trident.app` displayed "You're running a debug build of Trident! Performance will be degraded." because the Zig library was compiled in Debug mode.

The warning triggers when `builtin.mode` is `.Debug` or `.ReleaseSafe` (see `src/main_c.zig:131-141`, displayed in `macos/Sources/Features/Terminal/TerminalView.swift:100-102`).

Fix: Rebuilt with `macos/install.nu` which uses `-Doptimize=ReleaseFast`.

### 5. Dev cask update model is still awkward

Current behavior:

- The private dev cask points to a GitHub release asset API URL.
- Because the asset URL uses a specific private asset id, the dev cask is effectively pinned to that uploaded `tip` asset.

Consequence:

- `trident-dev` may still need a tap bump when a new private `tip` asset is published.
- This is less smooth than a normal public latest-download cask.

## Local Release Process

Until GitHub-hosted runners ship Xcode 26, releases are built locally.

### Stable release

```sh
# 1. Build, sign, install locally
macos/install.nu

# 2. Create signed + notarized DMG
macos/install.nu --dmg

# 3. Upload to distribution repo
gh release upload v1.3.2 Trident.dmg --clobber --repo subdepthtech/Trident
```

### Dev release

```sh
# 1. Build the stable app first (reuses same build)
macos/install.nu --dmg

# 2. Build dev variant using the release-dev script
macos/release-dev.nu

# 3. Upload to distribution repo
gh release upload tip Trident-Dev.dmg --clobber --repo subdepthtech/Trident
```

### Prerequisites

- Zig 0.15.2+ on PATH (Homebrew: `brew install zig`)
- Xcode 26 with macOS 26 SDK
- Nushell (`nu`) — available via `nix develop` or `brew install nushell`
- Developer ID certificate in keychain (auto-detected by `install.nu`)
- `notarytool-profile` in keychain (one-time setup, see secrets vault item `trident-ci-secrets`)
- `npx create-dmg` (installed automatically by the script)

## Current Private Install Contract

Homebrew access currently depends on two things:

1. Tap access over Git SSH
2. Asset download access through `HOMEBREW_GITHUB_API_TOKEN`

Example install flow:

```sh
tha install all
```

Or manually:

```sh
export HOMEBREW_GITHUB_API_TOKEN="..."
brew tap subdepthtech/trident git@github.com:subdepthtech/homebrew-trident.git
brew install --cask --appdir=/Applications subdepthtech/trident/trident
brew install --cask --appdir=/Applications subdepthtech/trident/trident-dev
```

## Repo Topology

Two GitHub repos serve different roles:

- **`austinkennethtucker/Trident`** (origin) — source code, CI, PRs, where workflows run
- **`subdepthtech/Trident`** — distribution repo where GitHub Releases hold the DMG assets that Homebrew downloads

Release workflows on `austinkennethtucker/Trident` build the app and upload assets to both repos. The cross-repo upload to `subdepthtech/Trident` requires a `SUBDEPTH_RELEASE_TOKEN` secret (PAT with release write access).

## Important Repos

- App source and CI:
  - `austinkennethtucker/Trident`
- Distribution releases (Homebrew downloads from here):
  - `subdepthtech/Trident`
- Private Homebrew tap:
  - `subdepthtech/homebrew-trident`
- Dotfiles helper:
  - `/Users/tucker/projects/dotfiles/zsh/functions/tha`
  - completion: `/Users/tucker/projects/dotfiles/zsh/functions/_tha`

## Required CI Secrets

Set in `austinkennethtucker/Trident` > Settings > Secrets and variables > Actions:

| Secret | Purpose |
|--------|---------|
| `PROD_MACOS_CERTIFICATE` | Base64 of exported .p12 Developer ID certificate |
| `PROD_MACOS_CERTIFICATE_PWD` | Password used when exporting the .p12 |
| `PROD_MACOS_CERTIFICATE_NAME` | Signing identity string (e.g. `Developer ID Application: Austin Tucker (3364PH2HE3)`) |
| `PROD_MACOS_CI_KEYCHAIN_PWD` | Any random string (CI keychain password) |
| `APPLE_NOTARIZATION_ISSUER` | App Store Connect API issuer ID |
| `APPLE_NOTARIZATION_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARIZATION_KEY` | Contents of the .p8 API key file |
| `SUBDEPTH_RELEASE_TOKEN` | GitHub PAT with release write access to `subdepthtech/Trident` |

All secrets are stored in Proton Pass: vault `secrets`, item `trident-ci-secrets`.
All secrets are also configured in `austinkennethtucker/Trident` GitHub repo settings.

## Recommended Next Work

### Highest priority

1. Create `macos/release-dev.nu` script for building the dev DMG locally (PlistBuddy bundle ID/name changes).
2. Build and upload both stable and dev DMGs to `subdepthtech/Trident`.
3. Retest Spotlight and Raycast after the signing fix.
4. Test `tha install all` end-to-end with the new signed assets.

### Good follow-up work

1. Make the dev private cask less asset-id dependent if possible.
2. Re-test release workflows when GitHub ships Xcode 26 on `macos-latest`.
3. Automate Homebrew cask version bumps in the release workflows.
4. Consider teaching `tha` a dedicated `launch` or `doctor` command.

## Useful Checks For A Future Agent

```sh
ls -1 /Applications | rg 'Trident'
mdfind "kMDItemFSName == 'Trident.app' || kMDItemFSName == 'Trident Dev.app'"
'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister' -dump | rg 'com\\.subdepthtech\\.trident(\\.dev)?|Trident( Dev)?\\.app'
codesign --verify --deep --strict --verbose=2 /Applications/Trident.app
codesign --verify --deep --strict --verbose=2 /Applications/Trident\ Dev.app
spctl -a -vv /Applications/Trident.app
spctl -a -vv /Applications/Trident\ Dev.app
open -b com.subdepthtech.trident
open -b com.subdepthtech.trident.dev
```

## Notes For The Next Agent

- Do not assume Homebrew "already installed" means the app is in `/Applications`.
- Do not assume Spotlight or Raycast failures mean the app failed to install.
- Do check for stale copies in:
  - `~/.Trash`
  - old build folders
  - old test install directories like `/tmp/trident-apps`
- Do verify both bundle ids stay distinct for stable and dev.
- Do verify the final launch path from:
  - Finder
  - Spotlight
  - Raycast
  - `open -b ...`

The release workflows have been simplified and cleaned up. Most Ghostty-specific infrastructure (R2, Sentry, appcast, source tarballs) has been removed.
