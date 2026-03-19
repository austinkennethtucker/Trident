import Foundation
import Combine
import WebKit

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

    /// Proxy URL from config (e.g., "http://127.0.0.1:8080")
    let proxyURL: String?
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

    init(proxyURL: String? = nil, proxyCertPath: String? = nil, tlsStrict: Bool = true) {
        self.proxyURL = proxyURL
        self.proxyCertPath = proxyCertPath
        self.tlsStrict = tlsStrict
        super.init()

        let server = BrowserSocketServer(paneId: id)
        server.model = self
        try? server.start()
        self.socketServer = server
    }

    deinit {
        socketServer?.stop()
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
}
