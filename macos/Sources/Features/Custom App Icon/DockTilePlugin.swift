import AppKit

class DockTilePlugin: NSObject, NSDockTilePlugIn {
    // WARNING: An instance of this class is alive as long as Trident's icon is
    // in the doc (running or not!), so keep any state and processing to a
    // minimum to respect resource usage.

    private let pluginBundle = Bundle(for: DockTilePlugin.self)

    private var iconChangeObserver: Any?

    /// The URL to the enclosing app bundle, determined from the plugin bundle path.
    var ghosttyAppURL: URL? {
        Self.appBundleURL(for: pluginBundle.bundleURL)
    }

    private var ghosttyUserDefaults: UserDefaults? {
        guard let appURL = ghosttyAppURL else {
            NSLog("Trident DockTilePlugin: failed to locate enclosing app bundle for %@", pluginBundle.bundleURL.path)
            return nil
        }

        guard let appBundle = Bundle(url: appURL) else {
            NSLog("Trident DockTilePlugin: failed to load enclosing app bundle at %@", appURL.path)
            return nil
        }

        guard let bundleIdentifier = appBundle.bundleIdentifier else {
            NSLog("Trident DockTilePlugin: missing bundle identifier for app at %@", appURL.path)
            return nil
        }

        guard let userDefaults = UserDefaults(suiteName: bundleIdentifier) else {
            NSLog("Trident DockTilePlugin: failed to open shared defaults suite %@", bundleIdentifier)
            return nil
        }

        return userDefaults
    }

    /// Determine the enclosing app bundle for the dock tile plugin bundle.
    ///
    /// We intentionally avoid matching a specific bundle name (such as
    /// "Ghostty.app") so renaming the app in Finder still works.
    static func appBundleURL(for pluginBundleURL: URL) -> URL? {
        var url = pluginBundleURL
        while true {
            if url.pathExtension.compare("app", options: .caseInsensitive) == .orderedSame {
                return url
            }

            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                // Safety stop: this should only happen at filesystem root.
                return nil
            }

            url = parent
        }
    }

    /// The primary NSDockTilePlugin function.
    func setDockTile(_ dockTile: NSDockTile?) {
        // If no dock tile or no access to Trident defaults, we can't do anything.
        guard let dockTile, let ghosttyUserDefaults else {
            if dockTile != nil {
                NSLog("Trident DockTilePlugin: disabling live icon updates because shared defaults are unavailable")
            }
            iconChangeObserver = nil
            return
        }

        // Try to restore the previous icon on launch.
        iconDidChange(ghosttyUserDefaults.appIcon, dockTile: dockTile)

        // Setup a new observer for when the icon changes so we can update. This message
        // is sent by the primary Trident app.
        iconChangeObserver = DistributedNotificationCenter
            .default()
            .publisher(for: .ghosttyIconDidChange)
            .map { [weak self] _ in self?.ghosttyUserDefaults?.appIcon }
            .receive(on: DispatchQueue.global())
            .sink { [weak self] newIcon in self?.iconDidChange(newIcon, dockTile: dockTile) }
    }

    private func iconDidChange(_ newIcon: AppIcon?, dockTile: NSDockTile) {
        guard let appIcon = newIcon?.image(in: pluginBundle) else {
            resetIcon(dockTile: dockTile)
            return
        }

        if let appBundleURL = self.ghosttyAppURL {
            let appBundlePath = appBundleURL.path
            NSWorkspace.shared.setIcon(appIcon, forFile: appBundlePath)
            NSWorkspace.shared.noteFileSystemChanged(appBundlePath)
        }

        dockTile.setIcon(appIcon)
    }

    /// Reset the application icon and dock tile icon to the default.
    private func resetIcon(dockTile: NSDockTile) {
        let appBundlePath = self.ghosttyAppURL?.path
        let appIcon: NSImage
        if #available(macOS 26.0, *) {
            // Reset to the default (glassy) icon.
            if let appBundlePath {
                NSWorkspace.shared.setIcon(nil, forFile: appBundlePath)
            }

            #if DEBUG
            // Use the `Blueprint` icon to distinguish Debug from Release builds.
            appIcon = pluginBundle.image(forResource: "BlueprintImage")!
            #else
            // Get the composed icon from the app bundle.
            if let appBundlePath,
                let iconRep = NSWorkspace.shared.icon(forFile: appBundlePath)
                .bestRepresentation(
                    for: CGRect(origin: .zero, size: dockTile.size),
                    context: nil,
                    hints: nil
            ) {
                appIcon = NSImage(size: dockTile.size)
                appIcon.addRepresentation(iconRep)
            } else {
                // If something unexpected happens on macOS 26,
                // fall back to a bundled icon.
                appIcon = pluginBundle.image(forResource: "AppIconImage")!
            }
            #endif
        } else {
            // Use the bundled icon to keep the corner radius consistent with pre-Tahoe apps.
            appIcon = pluginBundle.image(forResource: "AppIconImage")!
            if let appBundlePath {
                NSWorkspace.shared.setIcon(appIcon, forFile: appBundlePath)
            }
        }

        // Notify Finder/Dock so icon caches refresh immediately.
        if let appBundlePath {
            NSWorkspace.shared.noteFileSystemChanged(appBundlePath)
        }
        dockTile.setIcon(appIcon)
    }
}

private extension NSDockTile {
    func setIcon(_ newIcon: NSImage) {
        // Update the Dock tile on the main thread.
        DispatchQueue.main.async {
            let iconView = NSImageView(frame: CGRect(origin: .zero, size: self.size))
            iconView.wantsLayer = true
            iconView.image = newIcon
            self.contentView = iconView
            self.display()
        }
    }
}

// The dock tile update hands an NSImage across a DispatchQueue.main.async boundary.
// We treat that as safe here because the image is fully prepared before dispatch.
extension NSImage: @unchecked @retroactive Sendable {}

// This is required because of the DispatchQueue call above. This doesn't
// feel right but I don't know a better way to solve this.
extension NSDockTile: @unchecked @retroactive Sendable {}
