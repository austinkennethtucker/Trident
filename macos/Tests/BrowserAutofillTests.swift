import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite("Browser Autofill")
struct BrowserAutofillTests {
    @Test("runProcess drains large stdout and stderr before returning")
    func runProcessDrainsLargeOutput() async throws {
        let stdoutChunk = String(repeating: "o", count: 80_000)
        let stderrChunk = String(repeating: "e", count: 80_000)
        let script = "import sys; sys.stdout.write('\(stdoutChunk)'); sys.stderr.write('\(stderrChunk)')"

        let result = await AutofillStore.runProcessForTesting(
            executable: "/usr/bin/python3",
            arguments: ["-c", script],
            input: nil
        )

        #expect(result.exitCode == 0)
        #expect(result.output == stdoutChunk)
        #expect(result.stderr == stderrChunk)
    }

    @MainActor
    @Test("store refresh loads vault names, matches normalized hosts, and resolves share IDs back to vault names")
    func storeRefreshTracksVaultNamesAndShareIds() async throws {
        var invocations: [[String]] = []
        let store = AutofillStore(
            vaultName: nil,
            passCLIPath: "/usr/bin/pass-cli",
            autoDiscoverCLI: false,
            processRunner: { _, arguments, _ in
                invocations.append(arguments)

                switch arguments {
                case ["vault", "list", "--output", "json"]:
                    return AutofillProcessResult(
                        output: #"{"vaults":[{"name":"Personal"},{"name":"Work"}]}"#,
                        stderr: "",
                        exitCode: 0
                    )
                case ["item", "list", "Personal", "--filter-type", "login", "--output", "json"]:
                    return AutofillProcessResult(
                        output: #"""
                        {"items":[{"id":"item-1","share_id":"share-personal","state":"Active","content":{"title":"Example","content":{"Login":{"email":"alice@example.com","username":"","password":"secret","urls":["https://www.example.com/login"],"totp_uri":""}}}}]}
                        """#,
                        stderr: "",
                        exitCode: 0
                    )
                case ["item", "list", "Work", "--filter-type", "login", "--output", "json"]:
                    return AutofillProcessResult(
                        output: #"{"items":[]}"#,
                        stderr: "",
                        exitCode: 0
                    )
                case ["item", "view", "--item-id", "item-1", "--output", "json", "--vault-name", "Personal"]:
                    return AutofillProcessResult(
                        output: #"""
                        {"content":{"content":{"Login":{"username":"alice","email":"alice@example.com","password":"secret"}}}}
                        """#,
                        stderr: "",
                        exitCode: 0
                    )
                default:
                    Issue.record("Unexpected process invocation: \(arguments)")
                    return AutofillProcessResult(output: "", stderr: "unexpected", exitCode: 1)
                }
            }
        )

        let matches = await store.findMatches(for: try #require(URL(string: "https://example.com/account")))

        #expect(matches.count == 1)
        #expect(matches.first?.shareId == "share-personal")
        #expect(store.availableVaultNames == ["Personal", "Work"])

        _ = await store.fetchCredential(shareId: "share-personal", itemId: "item-1")

        #expect(invocations.contains(["item", "view", "--item-id", "item-1", "--output", "json", "--vault-name", "Personal"]))
    }

    @MainActor
    @Test("submit suppression resets on navigation instead of leaking into later saves")
    func submitSuppressionResetsOnNavigation() async throws {
        let controller = BrowserAutofillController(store: AutofillStore(
            vaultName: "Personal",
            passCLIPath: "/usr/bin/pass-cli",
            autoDiscoverCLI: false,
            processRunner: { _, _, _ in
                AutofillProcessResult(output: "", stderr: "", exitCode: 0)
            }
        ))

        controller.autofillDidFill = true
        controller.consumeSubmitDetected(isNewPassword: true, username: "alice", password: "secret", domain: "example.com")

        #expect(controller.showSave == false)
        #expect(controller.autofillDidFill == false)

        controller.autofillDidFill = true
        controller.handleNavigation(to: URL(string: "https://example.com/other"))
        controller.consumeSubmitDetected(isNewPassword: true, username: "alice", password: "secret", domain: "example.com")

        #expect(controller.autofillDidFill == false)
        #expect(controller.showSave == true)
        #expect(controller.pendingSavePassword == "secret")
    }

    @Test("TOTP cleanup only clears clipboard when the same code is still present")
    func totpCleanupChecksClipboardContents() async throws {
        #expect(BrowserAutofillController.shouldClearTOTPPasteboard(
            currentString: "123456",
            expectedTOTP: "123456"
        ) == true)
        #expect(BrowserAutofillController.shouldClearTOTPPasteboard(
            currentString: "different",
            expectedTOTP: "123456"
        ) == false)
        #expect(BrowserAutofillController.shouldClearTOTPPasteboard(
            currentString: nil,
            expectedTOTP: "123456"
        ) == false)
    }
}
