import Foundation

extension UserDefaults {
    static var ghosttySuite: String? {
        ProcessInfo.processInfo.environment["GHOSTTY_USER_DEFAULTS_SUITE"] ?? Bundle.main.bundleIdentifier
    }

    static var ghostty: UserDefaults {
        ghosttySuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
