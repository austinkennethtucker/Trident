import Foundation
import Combine
import WebKit

/// Model backing the embedded browser pane. Manages navigation state
/// and owns the WKWebView configuration.
class BrowserPaneModel: NSObject, ObservableObject {
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

    init(proxyURL: String? = nil, proxyCertPath: String? = nil, tlsStrict: Bool = true) {
        self.proxyURL = proxyURL
        self.proxyCertPath = proxyCertPath
        self.tlsStrict = tlsStrict
        super.init()
    }

    deinit {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }

    /// Bind to a WKWebView for KVO observation of navigation state.
    func bind(to webView: WKWebView) {
        self.webView = webView
        observations.forEach { $0.invalidate() }
        observations.removeAll()

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
        self.urlString = urlString
        guard let url = URL(string: urlString) else { return }
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }
}
