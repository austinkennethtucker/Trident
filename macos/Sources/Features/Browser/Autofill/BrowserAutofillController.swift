import Foundation
import WebKit
import AppKit

// MARK: - BrowserAutofillController

/// Per-tab autofill state machine. Receives WKScriptMessages dispatched
/// by BrowserPaneModel, validates their origin, resolves matching
/// credentials from the shared store, and drives the overlay UI state.
final class BrowserAutofillController: ObservableObject {

    // MARK: - Published UI State

    /// Credentials matching the current page URL, shown in the picker.
    @Published var matchingCredentials: [PassCredentialMeta] = []
    /// Show the credential picker overlay.
    @Published var showPrompt: Bool = false
    /// Show the save-new-password prompt.
    @Published var showSave: Bool = false
    /// Pending save state captured from the submit message.
    @Published var pendingSaveUsername: String = ""
    @Published var pendingSavePassword: String = ""
    @Published var pendingSaveTitle: String = ""
    /// TOTP toast: non-nil = show "TOTP copied" toast with this code hint.
    @Published var totpCode: String?
    /// True when AutofillStore reports session expired.
    @Published var sessionExpired: Bool = false

    // MARK: - Private State

    private let store: AutofillStore
    /// Weak reference to the WKWebView for JS injection.
    private weak var webView: WKWebView?

    /// Set to true after we fill a form, so submitDetected suppresses save.
    var autofillDidFill: Bool = false

    /// Active TOTP clear timer.
    private var totpClearTimer: DispatchWorkItem?

    // MARK: - Init

    init(store: AutofillStore) {
        self.store = store
    }

    /// Called by BrowserPaneModel once the WKWebView is created.
    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Message Dispatch

    /// Entry point for messages arriving on the "autofill" handler.
    /// All origin validation happens here before any action is taken.
    func handleMessage(_ message: WKScriptMessage) {
        // Only accept messages from the main frame
        guard message.frameInfo.isMainFrame else {
            print("[AutofillController] Ignored message from non-main frame")
            return
        }

        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else {
            print("[AutofillController] Malformed message body")
            return
        }

        // Validate that the message origin matches what WebKit reports
        // for the webView's current URL — never trust page-reported URLs.
        guard validateOrigin(message: message) else {
            print("[AutofillController] Origin validation failed — ignoring message")
            return
        }

        switch kind {
        case "formDetected":
            handleFormDetected(body: body)
        case "submitDetected":
            handleSubmitDetected(body: body)
        case "fieldFocused":
            break
        default:
            print("[AutofillController] Unknown message kind: \(kind)")
        }
    }

    // MARK: - Origin Validation

    private func validateOrigin(message: WKScriptMessage) -> Bool {
        guard let webView,
              let pageURL = webView.url else { return false }

        let msgHost = message.frameInfo.securityOrigin.host
        let pageHost = pageURL.host ?? ""

        guard !msgHost.isEmpty, !pageHost.isEmpty else { return false }
        return msgHost.lowercased() == pageHost.lowercased()
    }

    // MARK: - Form Detected Handler

    private func handleFormDetected(body: [String: Any]) {
        guard let webView,
              let pageURL = webView.url else { return }

        Task {
            // Re-check session if previously unavailable
            if store.isUnavailable {
                await store.checkSession()
                sessionExpired = store.isUnavailable
                // If still unavailable after re-check, bail out
                if store.isUnavailable { return }
            }

            let matches = await store.findMatches(for: pageURL)
            matchingCredentials = matches
            showPrompt = !matches.isEmpty
        }
    }

    // MARK: - Submit Detected Handler

    private func handleSubmitDetected(body: [String: Any]) {
        // If we just filled this form ourselves, suppress the save prompt
        guard !autofillDidFill else {
            autofillDidFill = false
            return
        }

        guard let isNewPassword = body["isNewPassword"] as? Bool, isNewPassword else { return }

        let username = body["username"] as? String ?? ""
        let password = body["password"] as? String ?? ""
        guard !password.isEmpty else { return }

        let domain = webView?.url?.host ?? "Unknown site"

        pendingSaveUsername = username
        pendingSavePassword = password
        pendingSaveTitle = domain
        showSave = true
    }

    // MARK: - Fill Orchestration

    /// Called when the user selects a credential from the picker.
    func fill(credential: PassCredentialMeta) {
        guard let webView else { return }
        showPrompt = false

        Task {
            guard let secret = await store.fetchCredential(
                shareId: credential.shareId,
                itemId: credential.itemId
            ) else {
                print("[AutofillController] fetchCredential returned nil")
                return
            }

            let usernameValue = secret.email.isEmpty ? secret.username : secret.email

            // Fill username via callAsyncJavaScript with arguments (no string interpolation)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    webView.callAsyncJavaScript(
                        "return window.__tridentAutofillHelper.fill(selector, value)",
                        arguments: [
                            "selector": "input[autocomplete=\"username\"], input[type=\"email\"], input[type=\"text\"]",
                            "value": usernameValue
                        ],
                        in: nil,
                        in: .defaultClient
                    ) { _ in }

                    webView.callAsyncJavaScript(
                        "return window.__tridentAutofillHelper.fill(selector, value)",
                        arguments: [
                            "selector": "input[type=\"password\"]",
                            "value": secret.password
                        ],
                        in: nil,
                        in: .defaultClient
                    ) { _ in
                        continuation.resume()
                    }
                }
            }

            autofillDidFill = true

            if credential.hasTOTP {
                await handleTOTP(shareId: credential.shareId, itemId: credential.itemId)
            }
        }
    }

    // MARK: - TOTP Handling

    private func handleTOTP(shareId: String, itemId: String) async {
        guard let code = await store.fetchTOTP(shareId: shareId, itemId: itemId) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        totpCode = code

        totpClearTimer?.cancel()

        let item = DispatchWorkItem { [weak self] in
            NSPasteboard.general.clearContents()
            DispatchQueue.main.async {
                self?.totpCode = nil
            }
        }
        totpClearTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    // MARK: - Save Credential

    func saveCredential(title: String, username: String, vaultName: String) {
        showSave = false
        let password = pendingSavePassword
        let url = webView?.url?.absoluteString ?? ""

        Task {
            let success = await store.saveCredential(
                title: title,
                username: username,
                email: "",
                password: password,
                url: url,
                vaultName: vaultName
            )
            if !success {
                print("[AutofillController] saveCredential failed")
            }
        }
    }

    // MARK: - Dismiss

    func dismissPrompt() {
        showPrompt = false
        matchingCredentials = []
    }

    func dismissSave() {
        showSave = false
    }
}
