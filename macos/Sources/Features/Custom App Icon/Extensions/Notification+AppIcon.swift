import AppKit

extension Notification.Name {
    static let ghosttyIconDidChange = Notification.Name(
        "\(Bundle.main.bundleIdentifier ?? "com.subdepthtech.trident").iconDidChange"
    )
}
