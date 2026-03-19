import SwiftUI
import WebKit

/// NSViewRepresentable wrapping WKWebView for use in SwiftUI.
/// Uses a non-persistent data store for session isolation.
struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var model: BrowserPaneModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent data store — no cross-session bleed
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Bind model to webView for KVO
        model.bind(to: webView)

        // Load initial URL if set
        if !model.urlString.isEmpty, let url = URL(string: model.urlString) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Updates driven by model.navigate(), not here
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserPaneModel

        init(model: BrowserPaneModel) {
            self.model = model
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            // TLS proxy trust is v8.1. For now, only handle tls-strict=false.
            if !model.tlsStrict {
                // WARNING: Disabling TLS validation — only for testing
                if let trust = challenge.protectionSpace.serverTrust {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                    return
                }
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
