import AppKit

private final class NotificationBundleToken {}

private func appBundleIdentifierForIconNotifications() -> String {
    let hostingBundle = Bundle(for: NotificationBundleToken.self)

    if hostingBundle.bundleURL.pathExtension.compare("app", options: .caseInsensitive) == .orderedSame {
        return hostingBundle.bundleIdentifier ?? "com.subdepthtech.trident"
    }

    var url = hostingBundle.bundleURL
    while true {
        if url.pathExtension.compare("app", options: .caseInsensitive) == .orderedSame {
            return Bundle(url: url)?.bundleIdentifier ?? "com.subdepthtech.trident"
        }

        let parent = url.deletingLastPathComponent()
        if parent.path == url.path {
            return "com.subdepthtech.trident"
        }

        url = parent
    }
}

extension Notification.Name {
    static let ghosttyIconDidChange = Notification.Name("\(appBundleIdentifierForIconNotifications()).iconDidChange")
}
