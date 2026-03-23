import Foundation
import Combine
import WebKit
import Security

/// Model backing the embedded browser pane. Manages navigation state
/// and owns the WKWebView configuration.
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

    private var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private(set) var socketServer: BrowserSocketServer?
    var inspectorOverlay: BrowserInspectorOverlay?
    @Published var jsConsoleVisible: Bool = false
    @Published var jsConsoleOutput: String = ""

    /// Last captured TLS certificate chain from navigation delegate.
    private(set) var lastCertificateChain: [[String: Any]]?

    /// Local proxy relay for routing traffic and HAR recording.
    private(set) var proxyRelay: BrowserProxyRelay?

    /// HAR recorder for capturing HTTP request/response metadata.
    let harRecorder = BrowserHARRecorder()

    init(proxyURL: String? = nil, proxyCertPath: String? = nil, tlsStrict: Bool = true) {
        self.proxyURL = proxyURL
        self.proxyCertPath = proxyCertPath
        self.tlsStrict = tlsStrict
        super.init()

        // Start local proxy relay
        let relay = BrowserProxyRelay()
        relay.upstreamProxy = proxyURL
        relay.harRecorder = harRecorder
        do {
            try relay.start()
            self.proxyRelay = relay
            print("[BrowserPane] Proxy relay started on port \(relay.localPort)")
        } catch {
            print("[BrowserPane] Proxy relay failed to start: \(error)")
        }

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

    deinit {
        socketServer?.stop()
        proxyRelay?.stop()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }

    /// Bind to a WKWebView for KVO observation of navigation state.
    func bind(to webView: WKWebView) {
        self.webView = webView
        observations.forEach { $0.invalidate() }
        observations.removeAll()

        self.inspectorOverlay = BrowserInspectorOverlay(webView: webView)

        observations.append(webView.observe(\.url) { [weak self] wv, _ in
            DispatchQueue.main.async {
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
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }

    // MARK: - Socket Command Helpers

    func evaluateJavaScript(_ code: String, completion: @escaping (Any?, Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(code, completionHandler: completion)
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
            guard let store = self?.webView?.configuration.websiteDataStore.httpCookieStore else {
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
            guard let store = self?.webView?.configuration.websiteDataStore.httpCookieStore else {
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
                    // SecCertificateCopyValues returns dates as CFNumber (absolute time)
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
