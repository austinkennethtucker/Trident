#!/usr/bin/env nu

# Unified Trident release script: build, sign, upload, and update Homebrew cask.
#
# Usage:
#   macos/release.nu --channel stable --version v1.4.0    # Full stable release
#   macos/release.nu --channel dev                         # Dev (tip) release
#   macos/release.nu --channel dev --skip-build            # Reuse existing dev DMG
#   macos/release.nu --channel stable --version v1.4.0 --skip-build

def main [
    --channel: string    # "stable" or "dev" (required)
    --version: string    # Tag name, e.g. "v1.4.0" (required for stable)
    --skip-build         # Reuse existing DMG instead of rebuilding
    --tap-path: string   # Path to homebrew-trident checkout (default ~/projects/homebrew-trident)
    --identity: string   # Codesign identity override
] {
    let repo_root = ($env.FILE_PWD | path dirname)
    let macos_dir = $env.FILE_PWD
    let tap = if $tap_path != null { $tap_path } else { $"($env.HOME)/projects/homebrew-trident" }
    let release_repo = "subdepthtech/Trident"

    if $channel == null {
        print $"(ansi red)Error: --channel is required \(stable or dev)(ansi reset)"
        exit 1
    }
    if $channel not-in ["stable" "dev"] {
        print $"(ansi red)Error: --channel must be 'stable' or 'dev', got '($channel)'(ansi reset)"
        exit 1
    }
    if $channel == "stable" and $version == null {
        print $"(ansi red)Error: --version is required for stable releases(ansi reset)"
        exit 1
    }

    # Verify tap checkout exists
    if not ($tap | path exists) {
        print $"(ansi red)Error: Homebrew tap not found at ($tap)(ansi reset)"
        print $"Clone it: gh repo clone subdepthtech/homebrew-trident ($tap)"
        exit 1
    }

    if $channel == "stable" {
        release-stable $repo_root $macos_dir $release_repo $tap $version $skip_build $identity
    } else {
        release-dev $repo_root $macos_dir $release_repo $tap $skip_build $identity
    }
}

# --- Stable release ---
def release-stable [
    repo_root: string,
    macos_dir: string,
    release_repo: string,
    tap: string,
    version: string,
    skip_build: bool,
    identity: string
] {
    let dmg_name = "Trident.dmg"
    let dmg_path = ($repo_root | path join $dmg_name)
    let cask_file = ($tap | path join "Casks" "trident.rb")

    # Step 1: Build DMG
    if not $skip_build {
        print $"(ansi cyan)Step 1/5: Building stable DMG...(ansi reset)"
        let build_args = ["--dmg"]
        let build_args = if $identity != null { $build_args | append ["--identity" $identity] } else { $build_args }
        cd $macos_dir
        nu ($macos_dir | path join "install.nu") ...$build_args
    } else {
        print $"(ansi cyan)Step 1/5: Skipping build, using existing DMG(ansi reset)"
    }

    if not ($dmg_path | path exists) {
        print $"(ansi red)Error: ($dmg_path) not found(ansi reset)"
        exit 1
    }

    # Step 2: Create GitHub release
    print $"(ansi cyan)Step 2/5: Creating GitHub release ($version)...(ansi reset)"
    cd $repo_root
    gh release create $version $dmg_name --repo $release_repo --title $"Trident ($version)"
    print $"(ansi green)Release ($version) created.(ansi reset)"

    # Step 3: Get asset ID
    print $"(ansi cyan)Step 3/5: Fetching asset ID...(ansi reset)"
    let asset_id = (gh api $"repos/($release_repo)/releases/tags/($version)"
        | from json
        | get assets
        | where name == $dmg_name
        | get id.0)
    print $"(ansi green)Asset ID: ($asset_id)(ansi reset)"

    # Step 4: Compute SHA-256
    print $"(ansi cyan)Step 4/5: Computing SHA-256...(ansi reset)"
    let sha = (shasum -a 256 $dmg_path | split row " " | first)
    print $"(ansi green)SHA-256: ($sha)(ansi reset)"

    # Step 5: Update Homebrew cask
    print $"(ansi cyan)Step 5/5: Updating Homebrew cask...(ansi reset)"
    update-cask $cask_file $version $asset_id $sha $release_repo
    commit-and-push-tap $tap $"Update trident cask to ($version)"

    print ""
    print $"(ansi green)Stable release ($version) complete!(ansi reset)"
    print $"  Release: https://github.com/($release_repo)/releases/tag/($version)"
    print $"  Cask updated and pushed to homebrew-trident"
}

# --- Dev release ---
def release-dev [
    repo_root: string,
    macos_dir: string,
    release_repo: string,
    tap: string,
    skip_build: bool,
    identity: string
] {
    let dmg_name = "Trident-Dev.dmg"
    let dmg_path = ($repo_root | path join $dmg_name)
    let cask_file = ($tap | path join "Casks" "trident-dev.rb")

    # Step 1: Build dev DMG
    if not $skip_build {
        print $"(ansi cyan)Step 1/5: Building dev DMG...(ansi reset)"
        let build_args = []
        let build_args = if $identity != null { $build_args | append ["--identity" $identity] } else { $build_args }
        cd $macos_dir
        nu ($macos_dir | path join "release-dev.nu") ...$build_args
    } else {
        print $"(ansi cyan)Step 1/5: Skipping build, using existing DMG(ansi reset)"
    }

    if not ($dmg_path | path exists) {
        print $"(ansi red)Error: ($dmg_path) not found(ansi reset)"
        exit 1
    }

    # Step 2: Upload to tip release (clobber existing)
    print $"(ansi cyan)Step 2/5: Uploading to tip release...(ansi reset)"
    cd $repo_root
    gh release upload tip $dmg_name --clobber --repo $release_repo
    print $"(ansi green)Uploaded ($dmg_name) to tip release.(ansi reset)"

    # Step 3: Get asset ID
    print $"(ansi cyan)Step 3/5: Fetching asset ID...(ansi reset)"
    let asset_id = (gh api $"repos/($release_repo)/releases/tags/tip"
        | from json
        | get assets
        | where name == $dmg_name
        | get id.0)
    print $"(ansi green)Asset ID: ($asset_id)(ansi reset)"

    # Step 4: Compute SHA-256
    print $"(ansi cyan)Step 4/5: Computing SHA-256...(ansi reset)"
    let sha = (shasum -a 256 $dmg_path | split row " " | first)
    print $"(ansi green)SHA-256: ($sha)(ansi reset)"

    # Step 5: Update Homebrew cask
    print $"(ansi cyan)Step 5/5: Updating Homebrew cask...(ansi reset)"
    let commit_short = (git rev-parse --short HEAD | str trim)
    update-cask $cask_file $commit_short $asset_id $sha $release_repo
    commit-and-push-tap $tap $"Update trident-dev cask to ($commit_short)"

    print ""
    print $"(ansi green)Dev release complete!(ansi reset)"
    print $"  Tip release: https://github.com/($release_repo)/releases/tag/tip"
    print $"  Cask updated and pushed to homebrew-trident"
}

# --- Helpers ---

# Update a cask file with new version, asset ID, and SHA
def update-cask [cask_file: string, version: string, asset_id: int, sha: string, repo: string] {
    if not ($cask_file | path exists) {
        print $"(ansi red)Error: Cask file not found: ($cask_file)(ansi reset)"
        exit 1
    }

    let content = (open $cask_file)

    # Replace version line
    let content = ($content | str replace --regex 'version "[^"]+"' $'version "($version)"')

    # Replace asset ID in URL
    let content = ($content | str replace --regex 'releases/assets/\d+' $'releases/assets/($asset_id)')

    # Replace sha256 line (handle both :no_check and actual hashes)
    let content = ($content | str replace --regex 'sha256 .+' $'sha256 "($sha)"')

    $content | save -f $cask_file
    print $"(ansi green)Updated ($cask_file)(ansi reset)"
}

# Commit and push the tap
def commit-and-push-tap [tap: string, message: string] {
    cd $tap
    git add -A
    let status = (git status --porcelain | str trim)
    if ($status | is-empty) {
        print $"(ansi yellow)No changes to commit in tap(ansi reset)"
        return
    }
    git commit -m $message
    git push
    print $"(ansi green)Tap committed and pushed.(ansi reset)"
}
