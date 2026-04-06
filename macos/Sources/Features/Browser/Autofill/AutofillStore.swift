import Foundation

struct AutofillProcessResult {
    let output: String
    let stderr: String
    let exitCode: Int32
}

// MARK: - PassCredentialMeta

/// Metadata extracted from a single Proton Pass login item.
/// Passwords and TOTP secrets are NEVER stored here — only the
/// minimum needed for URL matching and display in the picker.
struct PassCredentialMeta: Identifiable {
    /// Globally unique item identifier within this vault.
    let itemId: String
    /// The vault share ID that owns this item.
    let shareId: String
    /// Human-readable title from the Proton Pass item.
    let title: String
    /// All URLs associated with this login item.
    let urls: [String]
    /// Email address (may be empty string).
    let email: String
    /// Username (may be empty string).
    let username: String
    /// True if the item has a non-empty totp_uri (TOTP secret is NOT stored).
    let hasTOTP: Bool

    var id: String { "\(shareId)/\(itemId)" }

    /// Returns the display label: email if non-empty, else username, else title.
    var displayLabel: String {
        if !email.isEmpty { return email }
        if !username.isEmpty { return username }
        return title
    }
}

// MARK: - VaultIndex

/// In-memory cache of Proton Pass login metadata.
/// Never holds passwords or TOTP secrets.
private struct VaultIndex {
    var items: [PassCredentialMeta] = []
    var shareIdToVaultName: [String: String] = [:]
    var loadedAt: Date?

    var isStale: Bool {
        guard let loadedAt else { return true }
        return Date().timeIntervalSince(loadedAt) > 300 // 5-minute TTL
    }
}

// MARK: - AutofillStore

/// Shared across all browser tabs. Owns the vault metadata cache and
/// all pass-cli subprocess calls. All subprocess calls run off the main
/// thread via async/await with a TaskGroup-style detached Task.
///
/// Analogy: think of this like a DNS cache — it keeps a fast in-memory
/// index of what's in the vault and only reaches out to the real store
/// when it needs to resolve a specific secret.
final class AutofillStore: ObservableObject {
    typealias ProcessRunner = (String, [String], String?) async -> AutofillProcessResult

    // MARK: - Published State

    /// True when pass-cli is not installed or session has expired.
    @MainActor @Published private(set) var isUnavailable: Bool = false
    /// Human-readable reason autofill is unavailable (for banner display).
    @MainActor @Published private(set) var unavailableReason: String = ""
    /// Vault names available for save operations.
    @MainActor @Published private(set) var availableVaultNames: [String]

    // MARK: - Private State

    @MainActor private var index = VaultIndex()
    @MainActor private var passCLIPath: String?
    /// Optional vault name to restrict lookups. Nil = all vaults.
    private let vaultName: String?
    private let processRunner: ProcessRunner

    // MARK: - Init

    /// Discover pass-cli and record the optional vault restriction.
    /// - Parameter vaultName: Vault to restrict to, or nil for all vaults.
    init(
        vaultName: String?,
        passCLIPath: String? = nil,
        autoDiscoverCLI: Bool = true,
        processRunner: @escaping ProcessRunner = AutofillStore.defaultRunProcess
    ) {
        self.vaultName = vaultName
        self.passCLIPath = passCLIPath
        self.availableVaultNames = vaultName.map { [$0] } ?? []
        self.processRunner = processRunner

        if autoDiscoverCLI {
            Task { @MainActor in
                await discoverCLI()
            }
        } else if passCLIPath != nil {
            isUnavailable = false
            unavailableReason = ""
        }
    }

    // MARK: - CLI Discovery

    @MainActor
    private func discoverCLI() async {
        // Finder-launched apps get a minimal PATH that excludes ~/.local/bin,
        // /opt/homebrew/bin, etc. Check well-known locations directly instead
        // of relying on `which`.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/pass-cli",
            "/opt/homebrew/bin/pass-cli",
            "/usr/local/bin/pass-cli",
            "\(home)/.cargo/bin/pass-cli"
        ]

        // Also try `which` via the user's login shell for non-standard locations
        let whichResult = await runProcess(
            executable: "/bin/zsh",
            arguments: ["-l", "-c", "which pass-cli"],
            input: nil
        )
        let whichPath = whichResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if whichResult.exitCode == 0, !whichPath.isEmpty {
            passCLIPath = whichPath
            print("[AutofillStore] pass-cli discovered via login shell at: \(whichPath)")
            await checkSession()
            return
        }

        // Fall back to well-known paths
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                passCLIPath = path
                print("[AutofillStore] pass-cli discovered at: \(path)")
                await checkSession()
                return
            }
        }

        print("[AutofillStore] pass-cli not found — autofill disabled")
        isUnavailable = true
        unavailableReason = "pass-cli not found — install it or add it to PATH"
    }

    // MARK: - Session Check

    /// Runs `pass-cli test` to verify the session is active.
    /// Sets isUnavailable if the session is expired.
    @MainActor
    func checkSession() async {
        guard let cli = passCLIPath else { return }
        let result = await runProcess(executable: cli, arguments: ["test"], input: nil)
        if result.exitCode != 0 {
            print("[AutofillStore] pass-cli session expired")
            isUnavailable = true
            unavailableReason = "Proton Pass session expired — run `pass-cli login` in a terminal"
        } else {
            isUnavailable = false
            unavailableReason = ""
        }
    }

    // MARK: - URL Matching

    /// Find all cached credentials that match the given URL.
    /// Performs exact-host matching with www-prefix stripping.
    /// Returns empty array if autofill is unavailable or URL is not HTTPS.
    @MainActor
    func findMatches(for pageURL: URL) async -> [PassCredentialMeta] {
        guard !isUnavailable else { return [] }

        // HTTPS enforcement — never autofill on plain HTTP
        guard pageURL.scheme?.lowercased() == "https" else {
            print("[AutofillStore] Skipping autofill on non-HTTPS URL: \(pageURL)")
            return []
        }

        // Refresh index if stale
        if index.isStale {
            await refreshIndex()
        }

        guard let pageHost = Self.normalizeHost(pageURL.host) else { return [] }

        return index.items.filter { item in
            item.urls.contains { urlStr in
                // Try the URL as-is first
                if let url = URL(string: urlStr),
                   let itemHost = Self.normalizeHost(url.host) {
                    return itemHost == pageHost
                }
                // If host is nil and URL has no scheme, try prepending https://
                if !urlStr.contains("://"),
                   let url = URL(string: "https://\(urlStr)"),
                   let itemHost = Self.normalizeHost(url.host) {
                    return itemHost == pageHost
                }
                return false
            }
        }
    }

    // MARK: - Index Refresh

    /// Re-loads the vault index from pass-cli. Called when index is stale.
    @MainActor
    private func refreshIndex() async {
        guard let cli = passCLIPath else { return }

        print("[AutofillStore] Refreshing vault index...")

        // Determine which vault(s) to load
        var vaultNames: [String] = []
        if let name = vaultName {
            vaultNames = [name]
        } else {
            // Enumerate all vaults
            let result = await runProcess(
                executable: cli,
                arguments: ["vault", "list", "--output", "json"],
                input: nil
            )
            if result.exitCode != 0 {
                print("[AutofillStore] vault list failed: \(result.stderr)")
                await checkSession()
                return
            }
            guard let data = result.output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let vaults = json["vaults"] as? [[String: Any]] else {
                print("[AutofillStore] Failed to parse vault list JSON")
                return
            }
            vaultNames = vaults.compactMap { $0["name"] as? String }
        }
        availableVaultNames = vaultNames

        // Load items from each vault and merge
        var allItems: [PassCredentialMeta] = []
        var shareIdToVaultName: [String: String] = [:]
        for name in vaultNames {
            let result = await runProcess(
                executable: cli,
                arguments: ["item", "list", name, "--filter-type", "login", "--output", "json"],
                input: nil
            )
            if result.exitCode != 0 {
                print("[AutofillStore] item list for vault '\(name)' failed: \(result.stderr)")
                continue
            }
            let parsed = parseItemList(result.output)
            allItems.append(contentsOf: parsed)
            for item in parsed {
                shareIdToVaultName[item.shareId] = name
            }
        }

        index.items = allItems
        index.shareIdToVaultName = shareIdToVaultName
        index.loadedAt = Date()
        print("[AutofillStore] Index loaded: \(allItems.count) login item(s)")
    }

    // MARK: - JSON Parsing

    /// Parse the JSON returned by `pass-cli item list`.
    /// Handles both `{"items": [...]}` (current CLI) and bare `[...]` (legacy).
    /// Extracts metadata only — passwords and totp_uri are discarded after
    /// the hasTOTP boolean is derived.
    private func parseItemList(_ jsonString: String) -> [PassCredentialMeta] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let array: [[String: Any]]
        if let dict = json as? [String: Any],
           let items = dict["items"] as? [[String: Any]] {
            array = items
        } else if let items = json as? [[String: Any]] {
            array = items
        } else {
            return []
        }

        return array.compactMap { item -> PassCredentialMeta? in
            guard let itemId = item["id"] as? String,
                  let shareId = item["share_id"] as? String,
                  let content = item["content"] as? [String: Any],
                  let title = content["title"] as? String,
                  let innerContent = content["content"] as? [String: Any],
                  let login = innerContent["Login"] as? [String: Any] else {
                return nil
            }

            let email = login["email"] as? String ?? ""
            let username = login["username"] as? String ?? ""
            let urls = login["urls"] as? [String] ?? []
            let totpURI = login["totp_uri"] as? String ?? ""
            let hasTOTP = !totpURI.isEmpty

            // State filter — only Active items
            let state = item["state"] as? String ?? "Active"
            guard state == "Active" else { return nil }

            return PassCredentialMeta(
                itemId: itemId,
                shareId: shareId,
                title: title,
                urls: urls,
                email: email,
                username: username,
                hasTOTP: hasTOTP
            )
        }
    }

    // MARK: - Lazy Secret Fetch

    /// Fetch the full credential (username + password) for a given item.
    /// Secrets are fetched on demand and should be used immediately, not stored.
    /// Returns nil if the fetch fails.
    @MainActor
    func fetchCredential(shareId: String, itemId: String) async -> (username: String, email: String, password: String)? {
        guard let cli = passCLIPath else { return nil }

        let vaultArg = vaultNameForShareId(shareId)

        var args = ["item", "view", "--item-id", itemId, "--output", "json"]
        if let vault = vaultArg {
            args += ["--vault-name", vault]
        }

        let result = await runProcess(executable: cli, arguments: args, input: nil)
        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any],
              let innerContent = content["content"] as? [String: Any],
              let login = innerContent["Login"] as? [String: Any] else {
            print("[AutofillStore] fetchCredential failed: \(result.stderr)")
            return nil
        }

        let username = login["username"] as? String ?? ""
        let email = login["email"] as? String ?? ""
        let password = login["password"] as? String ?? ""

        return (username: username, email: email, password: password)
    }

    // MARK: - TOTP Fetch

    /// Fetch a TOTP code for an item with hasTOTP = true.
    /// Returns nil if the item has no TOTP or the fetch fails.
    @MainActor
    func fetchTOTP(shareId: String, itemId: String) async -> String? {
        guard let cli = passCLIPath else { return nil }

        let vaultArg = vaultNameForShareId(shareId)

        var args = ["item", "totp", "--item-id", itemId, "--output", "json"]
        if let vault = vaultArg {
            args += ["--vault-name", vault]
        }

        let result = await runProcess(executable: cli, arguments: args, input: nil)
        guard result.exitCode == 0 else {
            print("[AutofillStore] fetchTOTP failed: \(result.stderr)")
            return nil
        }

        // pass-cli totp output may be plain text or JSON — handle both
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? String {
            return code
        }
        // Fall back to raw output if not JSON
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Save Credential

    /// Save a new login item to the vault via `pass-cli item create login --from-template -`.
    /// The template JSON is piped via stdin — password never appears in argv.
    @MainActor
    func saveCredential(
        title: String,
        username: String,
        email: String,
        password: String,
        url: String,
        vaultName targetVault: String
    ) async -> Bool {
        guard let cli = passCLIPath else { return false }

        let template: [String: Any?] = [
            "title": title,
            "username": username.isEmpty ? nil : username,
            "email": email.isEmpty ? nil : email,
            "password": password,
            "urls": [url]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: template),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[AutofillStore] saveCredential: failed to serialize template")
            return false
        }

        let result = await runProcess(
            executable: cli,
            arguments: ["item", "create", "login", "--vault-name", targetVault, "--from-template", "-"],
            input: jsonString
        )

        if result.exitCode != 0 {
            print("[AutofillStore] saveCredential failed: \(result.stderr)")
            return false
        }

        // Invalidate the index so the next lookup picks up the new item
        index.loadedAt = nil
        print("[AutofillStore] Credential saved: \(title)")
        return true
    }

    // MARK: - Vault Name Lookup

    /// Returns the vault name for a given shareId by searching the index.
    /// Falls back to the configured vaultName, then nil.
    @MainActor
    private func vaultNameForShareId(_ shareId: String) -> String? {
        if let name = vaultName { return name }
        return index.shareIdToVaultName[shareId]
    }

    // MARK: - Subprocess Helper

    /// Run an external process off the main thread, optionally piping `input` to stdin.
    private func runProcess(
        executable: String,
        arguments: [String],
        input: String?
    ) async -> AutofillProcessResult {
        await processRunner(executable, arguments, input)
    }

    static func runProcessForTesting(
        executable: String,
        arguments: [String],
        input: String?
    ) async -> AutofillProcessResult {
        await defaultRunProcess(executable, arguments, input)
    }

    private static func defaultRunProcess(
        executable: String,
        arguments: [String],
        input: String?
    ) async -> AutofillProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if let input {
                    let stdinPipe = Pipe()
                    process.standardInput = stdinPipe
                    if let data = input.data(using: .utf8) {
                        stdinPipe.fileHandleForWriting.write(data)
                    }
                    stdinPipe.fileHandleForWriting.closeFile()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: AutofillProcessResult(output: "", stderr: error.localizedDescription, exitCode: -1))
                    return
                }

                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                process.waitUntilExit()
                group.wait()

                let output = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                continuation.resume(returning: AutofillProcessResult(
                    output: output,
                    stderr: stderr,
                    exitCode: process.terminationStatus
                ))
            }
        }
    }

    // MARK: - Host Normalization

    /// Strip www. prefix and lowercase the host.
    static func normalizeHost(_ host: String?) -> String? {
        guard var h = host, !h.isEmpty else { return nil }
        if h.lowercased().hasPrefix("www.") {
            h = String(h.dropFirst(4))
        }
        return h.lowercased()
    }
}
