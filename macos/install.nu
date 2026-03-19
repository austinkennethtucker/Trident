#!/usr/bin/env nu

# Build, sign, and install the Trident macOS app, or create a distributable DMG.
#
# Usage:
#   macos/install.nu                    # Build + install to /Applications/Trident.app
#   macos/install.nu --skip-build       # Install existing build without rebuilding
#   macos/install.nu --dmg              # Build + create signed/notarized Trident.dmg
#   macos/install.nu --identity "Name"  # Override auto-detected signing identity

def main [
    --dmg              # Create a signed/notarized DMG instead of installing locally
    --identity: string # Codesign identity (auto-detected from keychain if omitted)
    --skip-build       # Skip the build step; use existing macos/build/Release/Ghostty.app
    --configuration: string = "Release" # Build configuration (Debug, Release, ReleaseLocal)
] {
    let repo_root = ($env.FILE_PWD | path dirname)
    let macos_dir = $env.FILE_PWD
    let build_dir = ($macos_dir | path join "build" $configuration)
    let app_src = ($build_dir | path join "Ghostty.app")
    let entitlements = ($macos_dir | path join "Ghostty.entitlements")

    # --- Build ---
    if not $skip_build {
        print $"(ansi cyan)Building Trident \(($configuration))...(ansi reset)"
        nu ($macos_dir | path join "build.nu") --configuration $configuration
        print $"(ansi green)Build complete.(ansi reset)"
    }

    if not ($app_src | path exists) {
        print $"(ansi red)Error: ($app_src) not found. Run without --skip-build first.(ansi reset)"
        exit 1
    }

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
            print "Install your Developer ID certificate or pass --identity explicitly."
            exit 1
        }
        $found | parse --regex '"(.+)"' | get capture0.0
    }
    print $"(ansi cyan)Signing identity: ($sign_id)(ansi reset)"

    # --- Codesign the app bundle ---
    codesign-app $app_src $sign_id $entitlements

    if $dmg {
        create-distributable-dmg $app_src $sign_id $repo_root
    } else {
        install-locally $app_src
    }
}

# Codesign the full app bundle in the correct order (Sparkle internals first,
# then plugins, then the main bundle). Matches the CI release pipeline.
def codesign-app [app_path: string, identity: string, entitlements: string] {
    print $"(ansi cyan)Codesigning app bundle...(ansi reset)"

    let fw = ($app_path | path join "Contents" "Frameworks" "Sparkle.framework" "Versions" "B")

    # Sparkle XPC services and binaries (must be signed before the framework)
    let sparkle_targets = [
        ($fw | path join "XPCServices" "Downloader.xpc")
        ($fw | path join "XPCServices" "Installer.xpc")
        ($fw | path join "Autoupdate")
        ($fw | path join "Updater.app")
    ]
    for target in $sparkle_targets {
        if ($target | path exists) {
            run-codesign $identity $target
        }
    }

    # Sparkle framework itself
    let sparkle_fw = ($app_path | path join "Contents" "Frameworks" "Sparkle.framework")
    if ($sparkle_fw | path exists) {
        run-codesign $identity $sparkle_fw
    }

    # DockTilePlugin
    let dock_plugin = ($app_path | path join "Contents" "PlugIns" "DockTilePlugin.plugin")
    if ($dock_plugin | path exists) {
        run-codesign $identity $dock_plugin
    }

    # Main app bundle (with entitlements)
    ^/usr/bin/codesign --verbose -f -s $identity -o runtime --entitlements $entitlements $app_path
    print $"(ansi green)Codesigning complete.(ansi reset)"
}

def run-codesign [identity: string, target: string] {
    ^/usr/bin/codesign --verbose -f -s $identity -o runtime $target
}

# Install the app to /Applications/Trident.app
def install-locally [app_path: string] {
    let dest = "/Applications/Trident.app"

    # Quit running instance gracefully
    print $"(ansi cyan)Quitting Trident if running...(ansi reset)"
    do { osascript -e 'tell application "Trident" to quit' } | complete | ignore
    sleep 1sec

    # Replace the installed app
    if ($dest | path exists) {
        rm -rf $dest
    }
    cp -r $app_path $dest
    print $"(ansi green)Installed to ($dest)(ansi reset)"
    print "Verifying codesign..."
    ^codesign --verify --deep --strict $dest
    print $"(ansi green)Codesign verification passed.(ansi reset)"
}

# Create a signed, notarized DMG for distribution
def create-distributable-dmg [app_path: string, identity: string, repo_root: string] {
    print $"(ansi cyan)Creating DMG...(ansi reset)"

    # create-dmg (npm) generates the DMG
    let dmg_name = "Trident.dmg"
    let dmg_path = ($repo_root | path join $dmg_name)

    # Remove old DMG if present
    if ($dmg_path | path exists) {
        rm $dmg_path
    }

    # create-dmg outputs to cwd with a name derived from the app
    cd $repo_root
    npx create-dmg --identity $identity $app_path ./
    # Rename from auto-generated name (Ghostty *.dmg) to Trident.dmg
    let generated = (glob "Ghostty*.dmg" | first)
    mv $generated $dmg_name
    print $"(ansi green)DMG created: ($dmg_path)(ansi reset)"

    # --- Notarize ---
    print $"(ansi cyan)Notarizing DMG...(ansi reset)"

    # Check for stored credentials
    let profile = "notarytool-profile"
    let check = (do { xcrun notarytool history --keychain-profile $profile } | complete)
    if $check.exit_code != 0 {
        print $"(ansi red)Error: notarytool keychain profile '($profile)' not found.(ansi reset)"
        print ""
        print "Set it up once with:"
        print "  xcrun notarytool store-credentials notarytool-profile --apple-id <email> --team-id <team> --password <app-specific-password>"
        print ""
        print "Or using API key:"
        print "  xcrun notarytool store-credentials notarytool-profile --key <key.p8> --key-id <id> --issuer <issuer>"
        exit 1
    }

    xcrun notarytool submit $dmg_name --keychain-profile $profile --wait
    print $"(ansi cyan)Stapling notarization ticket...(ansi reset)"
    xcrun stapler staple $dmg_name
    xcrun stapler staple $app_path

    print $"(ansi green)Done! Distributable DMG: ($dmg_path)(ansi reset)"
}
