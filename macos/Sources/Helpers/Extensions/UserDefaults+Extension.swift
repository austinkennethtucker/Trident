import Foundation

extension UserDefaults {
    private static let migrationMarker = "TridentUserDefaultsMigratedToSharedSuiteV1"

    static var ghosttySuite: String? {
        ProcessInfo.processInfo.environment["GHOSTTY_USER_DEFAULTS_SUITE"] ?? Bundle.main.bundleIdentifier
    }

    static var ghostty: UserDefaults {
        ghosttySuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static func migrateGhosttyDefaultsIfNeeded() {
        guard
            let suite = ghosttySuite,
            let sharedDefaults = UserDefaults(suiteName: suite)
        else {
            return
        }

        guard !sharedDefaults.bool(forKey: migrationMarker) else {
            return
        }

        let sourceDomains: [String]
        if suite.hasSuffix(".dev") || suite.hasSuffix(".debug") {
            sourceDomains = [
                "com.mitchellh.ghostty.debug",
                "com.subdepthtech.trident.debug",
            ]
        } else {
            sourceDomains = [
                "com.mitchellh.ghostty",
            ]
        }

        for domainName in sourceDomains {
            guard let domain = UserDefaults.standard.persistentDomain(forName: domainName) else {
                continue
            }

            for (key, value) in domain where sharedDefaults.object(forKey: key) == nil {
                sharedDefaults.set(value, forKey: key)
            }
        }

        sharedDefaults.set(true, forKey: migrationMarker)
    }
}
