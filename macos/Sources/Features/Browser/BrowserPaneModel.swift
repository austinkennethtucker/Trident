import Foundation
import Combine
import WebKit
import Network
import Security

/// Model backing the embedded browser pane. Manages navigation state
/// and owns the WKWebView instance (persists across SwiftUI rebuilds).
class BrowserPaneModel: NSObject, ObservableObject {
    let id = UUID()

    @Published var urlString: String = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    @Published private(set) var estimatedProgress: Double = 0

    /// Proxy URL (e.g., "http://127.0.0.1:8080"). Mutable via setProxy().
    @Published var proxyURL: String?
    /// Path to PEM CA cert for proxy
    let proxyCertPath: String?
    /// Whether to enforce TLS validation
    let tlsStrict: Bool

    private var observations: [NSKeyValueObservation] = []
    private(set) var socketServer: BrowserSocketServer?
    var inspectorOverlay: BrowserInspectorOverlay?
    @Published var jsConsoleVisible: Bool = false
    @Published var jsConsoleOutput: String = ""

    /// Last captured TLS certificate chain from navigation delegate.
    private(set) var lastCertificateChain: [[String: Any]]?

    /// Local proxy relay for routing traffic and HAR recording.
    private(set) var proxyRelay: BrowserProxyRelay?

    /// Whether this model owns its proxy relay (and should stop it on deinit).
    private let ownsRelay: Bool

    /// HAR recorder for capturing HTTP request/response metadata.
    let harRecorder: BrowserHARRecorder

    /// Per-tab autofill controller. Nil when autofill is disabled via config.
    let autofillController: BrowserAutofillController?

    /// Whether autofill is active for this tab (config-driven).
    let autofillEnabled: Bool

    /// The WKWebView instance. Created lazily on first access so the proxy
    /// relay is guaranteed to be running before the web view configures its
    /// proxy settings.
    private(set) lazy var webView: WKWebView = createWebView()

    /// Creates a standalone model that owns its own proxy relay, socket server,
    /// and HAR recorder. Used when the browser pane has no tab manager.
    convenience init(proxyURL: String? = nil, proxyCertPath: String? = nil, tlsStrict: Bool = true) {
        let recorder = BrowserHARRecorder()

        // Start a local proxy relay
        var relay: BrowserProxyRelay?
        let r = BrowserProxyRelay()
        r.upstreamProxy = proxyURL
        r.harRecorder = recorder
        do {
            try r.start()
            relay = r
            print("[BrowserPane] Proxy relay started on port \(r.localPort)")
        } catch {
            print("[BrowserPane] Proxy relay failed to start: \(error)")
        }

        self.init(
            proxyURL: proxyURL,
            proxyCertPath: proxyCertPath,
            tlsStrict: tlsStrict,
            sharedRelay: relay,
            ownsRelay: true,
            harRecorder: recorder
        )

        // Standalone models also own a socket server
        let server = BrowserSocketServer(paneId: id)
        server.model = self
        do {
            try server.start()
            self.socketServer = server
            print("[BrowserPane] Socket server started at: \(server.socketPath)")
        } catch {
            print("[BrowserPane] Socket server failed to start: \(error)")
        }
    }

    /// Creates a model with shared (externally-owned) infrastructure.
    /// Used by BrowserTabManager to create per-tab models.
    init(
        proxyURL: String? = nil,
        proxyCertPath: String? = nil,
        tlsStrict: Bool = true,
        sharedRelay: BrowserProxyRelay?,
        ownsRelay: Bool,
        harRecorder: BrowserHARRecorder,
        autofillStore: AutofillStore? = nil,
        autofillEnabled: Bool = false
    ) {
        self.proxyURL = proxyURL
        self.proxyCertPath = proxyCertPath
        self.tlsStrict = tlsStrict
        self.proxyRelay = sharedRelay
        self.ownsRelay = ownsRelay
        self.harRecorder = harRecorder
        self.autofillEnabled = autofillEnabled
        if autofillEnabled, let store = autofillStore {
            self.autofillController = BrowserAutofillController(store: store)
        } else {
            self.autofillController = nil
        }
        super.init()
    }

    deinit {
        if ownsRelay {
            socketServer?.stop()
            proxyRelay?.stop()
        }
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }

    // MARK: - WKWebView Creation

    /// JavaScript injected at document start to monkey-patch fetch() and XMLHttpRequest
    /// for HAR recording. Posts captured request/response metadata to the native layer
    /// via window.webkit.messageHandlers.harLog.
    static let harInterceptScript = """
    (function() {
        if (window.__tridentHARHooked) return;
        window.__tridentHARHooked = true;

        // Intercept fetch()
        const origFetch = window.fetch;
        window.fetch = function() {
            const startTime = Date.now();
            const input = arguments[0];
            const init = arguments[1] || {};
            const method = (init.method || 'GET').toUpperCase();
            const url = (typeof input === 'string') ? input : (input.url || '');
            const reqHeaders = {};
            if (init.headers) {
                if (init.headers instanceof Headers) {
                    init.headers.forEach(function(v, k) { reqHeaders[k] = v; });
                } else {
                    Object.assign(reqHeaders, init.headers);
                }
            }

            return origFetch.apply(this, arguments).then(function(response) {
                const entry = {
                    method: method,
                    url: url,
                    status: response.status,
                    statusText: response.statusText,
                    requestHeaders: reqHeaders,
                    responseHeaders: {},
                    duration: Date.now() - startTime
                };
                response.headers.forEach(function(v, k) { entry.responseHeaders[k] = v; });
                try { window.webkit.messageHandlers.harLog.postMessage(entry); } catch(e) {}
                return response;
            }).catch(function(err) {
                try {
                    window.webkit.messageHandlers.harLog.postMessage({
                        method: method, url: url, status: 0, statusText: err.message,
                        requestHeaders: reqHeaders, responseHeaders: {}, duration: Date.now() - startTime
                    });
                } catch(e) {}
                throw err;
            });
        };

        // Intercept XMLHttpRequest
        const origOpen = XMLHttpRequest.prototype.open;
        const origSend = XMLHttpRequest.prototype.send;

        XMLHttpRequest.prototype.open = function(method, url) {
            this.__harMethod = method;
            this.__harURL = url;
            this.__harReqHeaders = {};
            return origOpen.apply(this, arguments);
        };

        const origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            if (this.__harReqHeaders) this.__harReqHeaders[name] = value;
            return origSetHeader.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function() {
            const self = this;
            const startTime = Date.now();
            this.addEventListener('loadend', function() {
                const respHeaders = {};
                (self.getAllResponseHeaders() || '').trim().split('\\r\\n').forEach(function(line) {
                    const idx = line.indexOf(':');
                    if (idx > 0) respHeaders[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
                });
                try {
                    window.webkit.messageHandlers.harLog.postMessage({
                        method: self.__harMethod || 'GET',
                        url: self.__harURL || '',
                        status: self.status,
                        statusText: self.statusText,
                        requestHeaders: self.__harReqHeaders || {},
                        responseHeaders: respHeaders,
                        duration: Date.now() - startTime
                    });
                } catch(e) {}
            });
            return origSend.apply(this, arguments);
        };
    })();
    """

    /// JavaScript injected at document end (main frame only, page world) for
    /// form detection + submit capture. Loaded from the bundled resource file.
    static let autofillDetectionScript: String = {
        guard let url = Bundle.main.url(forResource: "autofill-detection", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("[BrowserPane] autofill-detection.js not found in bundle")
            return ""
        }
        return source
    }()

    /// JavaScript injected at document end (defaultClient world) for safe field fill.
    /// Loaded from the bundled resource file.
    static let autofillFillScript: String = {
        guard let url = Bundle.main.url(forResource: "autofill-fill", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("[BrowserPane] autofill-fill.js not found in bundle")
            return ""
        }
        return source
    }()

    /// Creates and configures the WKWebView. Called once via lazy initialization.
    /// NOTE: This must not be called during init — proxyRelay must be set up first.
    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent data store — no cross-session bleed
        let dataStore = WKWebsiteDataStore.nonPersistent()

        // Configure proxy routing through local relay (macOS 14+)
        if #available(macOS 14.0, *) {
            if let relay = proxyRelay, relay.isRunning {
                let endpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: NWEndpoint.Port(integerLiteral: relay.localPort)
                )
                dataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint)]
                print("[BrowserPane] Proxy routing via local relay on port \(relay.localPort)")
            }
        } else if proxyURL != nil {
            print("[BrowserPane] WARNING: Proxy routing requires macOS 14+, proxy config ignored")
        }

        config.websiteDataStore = dataStore

        // Register JS message handler for HAR fetch/XHR interception.
        // Use a weak wrapper to avoid retain cycle:
        // model -> webView -> userContentController -> handler -> model
        let contentController = config.userContentController
        contentController.add(WeakScriptMessageHandler(self), name: "harLog")

        // Inject fetch/XHR monkey-patch script for HAR recording
        let harScript = WKUserScript(
            source: Self.harInterceptScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(harScript)

        // Register autofill scripts and message handler (when enabled)
        if autofillEnabled, !Self.autofillDetectionScript.isEmpty {
            // Handler: routes "autofill" messages to the per-tab controller
            contentController.add(WeakScriptMessageHandler(self), name: "autofill")

            // Detection script: runs in page world at document end, main frame only
            let detectionScript = WKUserScript(
                source: Self.autofillDetectionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            contentController.addUserScript(detectionScript)

            // Fill helper: runs in defaultClient world at document end
            if !Self.autofillFillScript.isEmpty {
                let fillScript = WKUserScript(
                    source: Self.autofillFillScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true,
                    in: .defaultClient
                )
                contentController.addUserScript(fillScript)
            }
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true

        setupObservations(for: wv)
        self.inspectorOverlay = BrowserInspectorOverlay(webView: wv)

        // Attach autofill controller to the web view
        autofillController?.attach(to: wv)

        return wv
    }

    /// Set up KVO observations on the web view for navigation state.
    private func setupObservations(for webView: WKWebView) {
        observations.forEach { $0.invalidate() }
        observations.removeAll()

        observations.append(webView.observe(\.url) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.autofillController?.handleNavigation(to: wv.url)
                self?.currentURL = wv.url
                if let url = wv.url?.absoluteString, self?.urlString != url {
                    self?.urlString = url
                }
            }
        })
        observations.append(webView.observe(\.title) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.pageTitle = wv.title ?? ""
            }
        })
        observations.append(webView.observe(\.isLoading) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.isLoading = wv.isLoading
            }
        })
        observations.append(webView.observe(\.canGoBack) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.canGoBack = wv.canGoBack
            }
        })
        observations.append(webView.observe(\.canGoForward) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.canGoForward = wv.canGoForward
            }
        })
        observations.append(webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.estimatedProgress = wv.estimatedProgress
            }
        })
    }

    func navigate(to urlString: String) {
        var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Auto-prepend https:// if no scheme is present
        if !normalized.contains("://") {
            normalized = "https://\(normalized)"
        }
        self.urlString = normalized
        guard let url = URL(string: normalized) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    // MARK: - Socket Command Helpers

    func evaluateJavaScript(_ code: String, completion: @escaping (Any?, Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(code, completionHandler: completion)
        }
    }

    func takeSnapshot(completion: @escaping (Data?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.webView else {
                completion(nil)
                return
            }
            let config = WKSnapshotConfiguration()
            webView.takeSnapshot(with: config) { image, _ in
                guard let image = image else {
                    completion(nil)
                    return
                }
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)
                completion(rep?.representation(using: .png, properties: [:]))
            }
        }
    }

    func getCookies(completion: @escaping ([HTTPCookie]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let store = self?.webView.configuration.websiteDataStore.httpCookieStore else {
                completion([])
                return
            }
            store.getAllCookies { cookies in
                completion(cookies)
            }
        }
    }

    func toggleInspectorOverlay() {
        inspectorOverlay?.toggle()
    }

    func runJavaScript(_ code: String) {
        evaluateJavaScript(code) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.jsConsoleOutput += "> \(code)\nError: \(error.localizedDescription)\n\n"
                } else {
                    let output = result.map { "\($0)" } ?? "undefined"
                    self?.jsConsoleOutput += "> \(code)\n\(output)\n\n"
                }
            }
        }
    }

    func setCookie(_ cookie: HTTPCookie, completion: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let store = self?.webView.configuration.websiteDataStore.httpCookieStore else {
                completion()
                return
            }
            store.setCookie(cookie, completionHandler: completion)
        }
    }

    // MARK: - Certificate Info (Phase 1)

    /// Store certificate chain info from a TLS handshake for later retrieval.
    func storeCertificateChain(_ serverTrust: SecTrust) {
        guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            DispatchQueue.main.async { [weak self] in self?.lastCertificateChain = nil }
            return
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        // OID keys used by SecCertificateCopyValues on macOS
        let oidNotBefore = kSecOIDX509V1ValidityNotBefore as String
        let oidNotAfter = kSecOIDX509V1ValidityNotAfter as String
        let oidIssuer = kSecOIDX509V1IssuerName as String
        let oidSerial = kSecOIDX509V1SerialNumber as String
        let oidSAN = kSecOIDSubjectAltName as String

        let chain = certChain.map { cert -> [String: Any] in
            var info: [String: Any] = [:]

            // Subject summary (common name or description)
            if let summary = SecCertificateCopySubjectSummary(cert) {
                info["subject"] = summary as String
            }

            // Detailed values via SecCertificateCopyValues
            let requestedOIDs = [oidNotBefore, oidNotAfter, oidIssuer, oidSerial, oidSAN] as CFArray
            if let values = SecCertificateCopyValues(cert, requestedOIDs, nil) as? [String: [String: Any]] {
                // Issuer name
                if let issuerEntry = values[oidIssuer],
                   let issuerValue = issuerEntry[kSecPropertyKeyValue as String] {
                    info["issuer"] = "\(issuerValue)"
                }

                // Validity dates
                if let notBeforeEntry = values[oidNotBefore],
                   let notBefore = notBeforeEntry[kSecPropertyKeyValue as String] as? Double {
                    let date = Date(timeIntervalSinceReferenceDate: notBefore)
                    info["notBefore"] = isoFormatter.string(from: date)
                }
                if let notAfterEntry = values[oidNotAfter],
                   let notAfter = notAfterEntry[kSecPropertyKeyValue as String] as? Double {
                    let date = Date(timeIntervalSinceReferenceDate: notAfter)
                    info["notAfter"] = isoFormatter.string(from: date)
                }

                // Subject Alternative Names
                if let sanEntry = values[oidSAN],
                   let sanSection = sanEntry[kSecPropertyKeyValue as String] as? [[String: Any]] {
                    let sans = sanSection.compactMap { $0[kSecPropertyKeyValue as String] as? String }
                    if !sans.isEmpty {
                        info["sans"] = sans
                    }
                }

                // Serial Number
                if let serialEntry = values[oidSerial],
                   let serial = serialEntry[kSecPropertyKeyValue as String] {
                    info["serialNumber"] = "\(serial)"
                }
            }

            return info
        }
        DispatchQueue.main.async { [weak self] in
            self?.lastCertificateChain = chain
        }
    }

    // MARK: - Proxy Control (Phase 2)

    /// Change proxy at runtime. Updates the relay's upstream target.
    func setProxy(_ url: String?) {
        self.proxyURL = url
        proxyRelay?.upstreamProxy = url
    }

    // MARK: - HAR Recording (Phase 4)

    func startHARRecording() {
        harRecorder.start()
    }

    func stopHARRecording() {
        harRecorder.stop()
    }

    func exportHAR() -> [String: Any] {
        harRecorder.exportHAR()
    }
}

// MARK: - WKNavigationDelegate

extension BrowserPaneModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Capture certificate chain for cert_info command
        storeCertificateChain(serverTrust)

        // If TLS validation is disabled entirely
        if !tlsStrict {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // If a proxy CA cert is configured, trust it for this connection only
        if let certPath = proxyCertPath,
           let cert = loadCertificate(fromPEM: certPath) {
            SecTrustSetAnchorCertificates(serverTrust, [cert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, false)
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    /// Load a PEM-encoded certificate file and return a SecCertificate.
    /// Strips PEM headers and decodes base64 to DER format.
    private func loadCertificate(fromPEM path: String) -> SecCertificate? {
        guard let pemData = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let base64 = pemData
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let derData = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, derData as CFData)
    }
}

// MARK: - WKScriptMessageHandler (HAR logging from JS)

extension BrowserPaneModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "harLog":
            guard let body = message.body as? [String: Any],
                  harRecorder.isRecording else { return }

            let method = body["method"] as? String ?? "GET"
            let url = body["url"] as? String ?? ""
            let status = body["status"] as? Int ?? 0
            let statusText = body["statusText"] as? String ?? ""
            let duration = (body["duration"] as? Double ?? 0) / 1000.0

            var reqHeaders: [(name: String, value: String)] = []
            if let headers = body["requestHeaders"] as? [String: String] {
                reqHeaders = headers.map { (name: $0.key, value: $0.value) }
            }
            var respHeaders: [(name: String, value: String)] = []
            if let headers = body["responseHeaders"] as? [String: String] {
                respHeaders = headers.map { (name: $0.key, value: $0.value) }
            }

            harRecorder.append(HAREntry(
                startedDateTime: Date(),
                method: method,
                url: url,
                httpVersion: "HTTP/1.1",
                requestHeaders: reqHeaders,
                responseStatus: status,
                responseStatusText: statusText,
                responseHeaders: respHeaders,
                responseBodySize: 0,
                timings: HARTimings(connect: 0, send: 0, wait: duration, receive: 0),
                source: .jsIntercept
            ))

        case "autofill":
            autofillController?.handleMessage(message)

        default:
            break
        }
    }
}

// MARK: - WeakScriptMessageHandler

/// Weak wrapper to avoid retain cycle from WKUserContentController.add().
class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}
