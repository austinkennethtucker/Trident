# Trident Homebrew + macOS Packaging Handoff

Last updated: 2026-03-30

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

### 3. macOS still reports a signing / trust problem

This is the biggest remaining packaging issue.

Observed behavior:

- The apps are installed in `/Applications`.
- `open /Applications/Trident.app` and `open /Applications/Trident\ Dev.app` can succeed.
- `open -b com.subdepthtech.trident` and `open -b com.subdepthtech.trident.dev` can succeed.
- But trust checks still complain:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/Trident.app
codesign --verify --deep --strict --verbose=2 /Applications/Trident\ Dev.app
spctl -a -vv /Applications/Trident.app
spctl -a -vv /Applications/Trident\ Dev.app
```

Typical result:

- `invalid Info.plist (plist or signature have been modified)`

Important detail:

- `plutil -lint` says both `Info.plist` files are valid plist files.
- The `Info.plist` in `/Applications` matches the one in the Caskroom.
- That suggests the problem is not simple plist corruption.

Likely conclusion:

- Something about the release packaging/signing flow is producing app bundles that macOS does not fully trust after install.
- This needs to be fixed in the release pipeline, not just patched locally after install.

### 4. Dev cask update model is still awkward

Current behavior:

- The private dev cask points to a GitHub release asset API URL.
- Because the asset URL uses a specific private asset id, the dev cask is effectively pinned to that uploaded `tip` asset.

Consequence:

- `trident-dev` may still need a tap bump when a new private `tip` asset is published.
- This is less smooth than a normal public latest-download cask.

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

## Important Repos

- App source and private releases:
  - `subdepthtech/Trident`
- Private Homebrew tap:
  - `subdepthtech/homebrew-trident`
- Dotfiles helper:
  - `/Users/tucker/projects/dotfiles/zsh/functions/tha`
  - completion: `/Users/tucker/projects/dotfiles/zsh/functions/_tha`

## Recommended Next Work

### Highest priority

1. Fix the macOS release packaging/signing flow so installed app bundles pass `codesign --verify` and `spctl`.
2. Retest Spotlight and Raycast after the packaging/signing fix.
3. Remove stale local app registrations and old app copies during testing so results are clean.

### Good follow-up work

1. Make the dev private cask less asset-id dependent if possible.
2. Add better checks in the release flow so a broken macOS bundle is caught before publishing.
3. Consider adding a verification step that installs the private casks into a clean `/Applications` target and checks launch behavior.
4. Consider teaching `tha` a dedicated `launch` or `doctor` command if this workflow stays private/internal for a while.

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

If you want, the next small cleanup would be renaming a few remaining Ghostty-labeled release/job names in the workflow so the fork branding is fully consistent.
