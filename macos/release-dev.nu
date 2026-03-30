#!/usr/bin/env nu

# Build, sign, and create a distributable Trident Dev DMG.
#
# This script builds the app with Release configuration, then patches
# the bundle to become "Trident Dev" with a distinct bundle ID, signs
# it with your Developer ID, creates a DMG, and notarizes it.
#
# Usage:
#   macos/release-dev.nu                    # Full build + DMG
#   macos/release-dev.nu --skip-build       # Use existing build
#   macos/release-dev.nu --identity "Name"  # Override signing identity

def main [
    --identity: string # Codesign identity (auto-detected from keychain if omitted)
    --skip-build       # Skip the build step; use existing macos/build/Release/Trident.app
] {
    let repo_root = ($env.FILE_PWD | path dirname)
    let macos_dir = $env.FILE_PWD
    let build_dir = ($macos_dir | path join "build" "Release")
    let app_stable = ($build_dir | path join "Trident.app")
    let app_dev = ($build_dir | path join "Trident Dev.app")
    let entitlements = ($macos_dir | path join "Ghostty.entitlements")

    # --- Build ---
    if not $skip_build {
        print $"(ansi cyan)Building libghostty \(ReleaseFast)...(ansi reset)"
        cd $repo_root
        ^zig build -Demit-macos-app=false -Doptimize=ReleaseFast
        print $"(ansi cyan)Building Trident \(Release)...(ansi reset)"
        nu ($macos_dir | path join "build.nu") --configuration Release
        print $"(ansi green)Build complete.(ansi reset)"
    }

    if not ($app_stable | path exists) {
        print $"(ansi red)Error: ($app_stable) not found. Run without --skip-build first.(ansi reset)"
        exit 1
    }

    # --- Create dev copy ---
    print $"(ansi cyan)Creating Trident Dev bundle...(ansi reset)"
    if ($app_dev | path exists) {
        rm -rf $app_dev
    }
    cp -r $app_stable $app_dev

    # --- Patch Info.plist for dev channel ---
    let plist = ($app_dev | path join "Contents" "Info.plist")
    let commit = (git rev-parse --short HEAD | str trim)
    let build_num = (git rev-list --count HEAD | str trim)

    /usr/libexec/PlistBuddy -c $"Set :GhosttyCommit ($commit)" $plist
    /usr/libexec/PlistBuddy -c $"Set :CFBundleVersion ($build_num)" $plist
    /usr/libexec/PlistBuddy -c $"Set :CFBundleShortVersionString ($commit)" $plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'Trident Dev'" $plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleName 'Trident Dev'" $plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.subdepthtech.trident.dev" $plist
    /usr/libexec/PlistBuddy -c "Set :UTExportedTypeDeclarations:0:UTTypeIdentifier com.subdepthtech.trident.dev.surface-id" $plist

    # Remove auto-update check (dev uses tip channel)
    do { /usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" $plist } | complete | ignore

    print $"(ansi green)Patched Info.plist: bundle ID com.subdepthtech.trident.dev, version ($commit)(ansi reset)"

    # --- Resolve signing identity ---
    let sign_id = if $identity != null {
        $identity
    } else {
        let found = (security find-identity -v -p codesigning
            | lines
            | where ($it | str contains "Developer ID Application")
            | first)
        if ($found | is-empty) {
            print $"(ansi red)Error: No Developer ID Application identity found in keychain.(ansi reset)"
            exit 1
        }
        $found | parse --regex '"(.+)"' | get capture0.0
    }
    print $"(ansi cyan)Signing identity: ($sign_id)(ansi reset)"

    # --- Codesign ---
    codesign-app $app_dev $sign_id $entitlements

    # --- Create DMG ---
    create-distributable-dmg $app_dev $sign_id $repo_root

    print ""
    print $"(ansi green)Done! Upload with:(ansi reset)"
    print $"  gh release upload tip Trident-Dev.dmg --clobber --repo subdepthtech/Trident"
}

def codesign-app [app_path: string, identity: string, entitlements: string] {
    print $"(ansi cyan)Codesigning app bundle...(ansi reset)"

    let fw = ($app_path | path join "Contents" "Frameworks" "Sparkle.framework" "Versions" "B")

    let sparkle_targets = [
        ($fw | path join "XPCServices" "Downloader.xpc")
        ($fw | path join "XPCServices" "Installer.xpc")
        ($fw | path join "Autoupdate")
        ($fw | path join "Updater.app")
    ]
    for target in $sparkle_targets {
        if ($target | path exists) {
            ^/usr/bin/codesign --verbose -f -s $identity -o runtime $target
        }
    }

    let sparkle_fw = ($app_path | path join "Contents" "Frameworks" "Sparkle.framework")
    if ($sparkle_fw | path exists) {
        ^/usr/bin/codesign --verbose -f -s $identity -o runtime $sparkle_fw
    }

    let dock_plugin = ($app_path | path join "Contents" "PlugIns" "DockTilePlugin.plugin")
    if ($dock_plugin | path exists) {
        ^/usr/bin/codesign --verbose -f -s $identity -o runtime $dock_plugin
    }

    ^/usr/bin/codesign --verbose -f -s $identity -o runtime --entitlements $entitlements $app_path
    print $"(ansi green)Codesigning complete.(ansi reset)"
}

def create-distributable-dmg [app_path: string, identity: string, repo_root: string] {
    print $"(ansi cyan)Creating DMG...(ansi reset)"

    let dmg_name = "Trident-Dev.dmg"
    let dmg_path = ($repo_root | path join $dmg_name)

    if ($dmg_path | path exists) {
        rm $dmg_path
    }

    cd $repo_root
    npx create-dmg --identity $identity $app_path ./
    let generated = (glob "Trident Dev*.dmg" | first)
    if $generated != $dmg_name {
        mv $generated $dmg_name
    }
    print $"(ansi green)DMG created: ($dmg_path)(ansi reset)"

    # --- Notarize ---
    print $"(ansi cyan)Notarizing DMG...(ansi reset)"

    let profile = "notarytool-profile"
    let check = (do { xcrun notarytool history --keychain-profile $profile } | complete)
    if $check.exit_code != 0 {
        print $"(ansi red)Error: notarytool keychain profile '($profile)' not found.(ansi reset)"
        print ""
        print "Set it up once with:"
        print "  xcrun notarytool store-credentials notarytool-profile --key <key.p8> --key-id <id> --issuer <issuer>"
        exit 1
    }

    xcrun notarytool submit $dmg_name --keychain-profile $profile --wait
    print $"(ansi cyan)Stapling notarization ticket...(ansi reset)"
    xcrun stapler staple $dmg_name
    xcrun stapler staple $app_path

    print $"(ansi green)Done! Distributable DMG: ($dmg_path)(ansi reset)"
}
