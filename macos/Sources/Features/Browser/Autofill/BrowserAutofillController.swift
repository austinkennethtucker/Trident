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
    /// User-visible fill error shown in the overlay.
    @Published var fillErrorMessage: String?

    // MARK: - Private State

    private let store: AutofillStore
    /// Weak reference to the WKWebView for JS injection.
    private weak var webView: WKWebView?

    /// Set to true after we fill a form, so submitDetected suppresses save.
    var autofillDidFill: Bool = false

    /// CSS selectors extracted from the most recent formDetected message.
    private var detectedUsernameSelector: String?
    private var detectedPasswordSelector: String?

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

    func handleNavigation(to url: URL?) {
        autofillDidFill = false
        detectedUsernameSelector = nil
        detectedPasswordSelector = nil
        fillErrorMessage = nil
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

        let msgHost = AutofillStore.normalizeHost(message.frameInfo.securityOrigin.host)
        let pageHost = AutofillStore.normalizeHost(pageURL.host)

        guard let msgHost, let pageHost else { return false }
        return msgHost == pageHost
    }

    // MARK: - Form Detected Handler

    private func handleFormDetected(body: [String: Any]) {
        guard let webView,
              let pageURL = webView.url else { return }

        // Extract form-specific selectors from the detection script.
        // Use the first detected form (most pages have exactly one login form).
        if let forms = body["forms"] as? [[String: Any]], let firstForm = forms.first {
            detectedUsernameSelector = firstForm["usernameSelector"] as? String
            detectedPasswordSelector = firstForm["passwordSelector"] as? String
        } else {
            detectedUsernameSelector = nil
            detectedPasswordSelector = nil
        }

        Task {
            // Re-check session if previously unavailable
            if await store.isUnavailable {
                await store.checkSession()
                let stillUnavailable = await store.isUnavailable
                await MainActor.run {
                    sessionExpired = stillUnavailable
                }
                // If still unavailable after re-check, bail out
                if stillUnavailable { return }
            }

            let matches = await store.findMatches(for: pageURL)
            await MainActor.run {
                matchingCredentials = matches
                showPrompt = !matches.isEmpty
            }
        }
    }

    // MARK: - Submit Detected Handler

    private func handleSubmitDetected(body: [String: Any]) {
        let domain = webView?.url?.host ?? "Unknown site"
        consumeSubmitDetected(
            isNewPassword: body["isNewPassword"] as? Bool ?? false,
            username: body["username"] as? String ?? "",
            password: body["password"] as? String ?? "",
            domain: domain
        )
    }

    func consumeSubmitDetected(isNewPassword: Bool, username: String, password: String, domain: String) {
        // If we just filled this form ourselves, suppress the save prompt
        guard !autofillDidFill else {
            autofillDidFill = false
            return
        }

        guard isNewPassword else { return }
        guard !password.isEmpty else { return }

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
                await MainActor.run {
                    fillErrorMessage = "Could not load this Proton Pass login. Check your session and try again."
                }
                print("[AutofillController] fetchCredential returned nil")
                return
            }

            let usernameValue = secret.email.isEmpty ? secret.username : secret.email

            async let usernameFill = fillField(
                in: webView,
                selector: detectedUsernameSelector ?? "input[autocomplete=\"username\"], input[type=\"email\"], input[type=\"text\"]",
                value: usernameValue
            )
            async let passwordFill = fillField(
                in: webView,
                selector: detectedPasswordSelector ?? "input[type=\"password\"]",
                value: secret.password
            )

            let usernameFilled = await usernameFill
            let passwordFilled = await passwordFill

            await MainActor.run {
                autofillDidFill = usernameFilled || passwordFilled
                fillErrorMessage = fillErrorMessageFor(usernameFilled: usernameFilled, passwordFilled: passwordFilled)
            }

            if credential.hasTOTP {
                await handleTOTP(shareId: credential.shareId, itemId: credential.itemId)
            }
        }
    }

    private func fillField(in webView: WKWebView, selector: String, value: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                webView.callAsyncJavaScript(
                    "return window.__tridentAutofillHelper.fill(selector, value)",
                    arguments: [
                        "selector": selector,
                        "value": value
                    ],
                    in: nil,
                    in: .defaultClient
                ) { result in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value as? Bool ?? false)
                    case .failure(let error):
                        print("[AutofillController] JS fill failed for selector '\(selector)': \(error)")
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    private func fillErrorMessageFor(usernameFilled: Bool, passwordFilled: Bool) -> String? {
        switch (usernameFilled, passwordFilled) {
        case (true, true):
            return nil
        case (false, false):
            return "Could not find the login fields on this page."
        case (false, true):
            return "Filled the password, but the username field could not be found."
        case (true, false):
            return "Filled the username, but the password field could not be found."
        }
    }

    // MARK: - TOTP Handling

    private func handleTOTP(shareId: String, itemId: String) async {
        guard let code = await store.fetchTOTP(shareId: shareId, itemId: itemId) else { return }

        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)

            totpCode = code
            totpClearTimer?.cancel()

            let expectedCode = code
            let item = DispatchWorkItem { [weak self] in
                if Self.shouldClearTOTPPasteboard(
                    currentString: NSPasteboard.general.string(forType: .string),
                    expectedTOTP: expectedCode
                ) {
                    NSPasteboard.general.clearContents()
                }
                self?.totpCode = nil
            }
            totpClearTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
        }
    }

    static func shouldClearTOTPPasteboard(currentString: String?, expectedTOTP: String) -> Bool {
        currentString == expectedTOTP
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

    func dismissFillError() {
        fillErrorMessage = nil
    }
}
