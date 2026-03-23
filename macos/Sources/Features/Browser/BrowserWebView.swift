import SwiftUI
import WebKit
import Network

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
        let dataStore = WKWebsiteDataStore.nonPersistent()

        // Configure proxy routing through local relay (macOS 14+)
        if #available(macOS 14.0, *) {
            if let relay = model.proxyRelay, relay.isRunning {
                let endpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: NWEndpoint.Port(integerLiteral: relay.localPort)
                )
                dataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint)]
                print("[BrowserWebView] Proxy routing via local relay on port \(relay.localPort)")
            }
        } else if model.proxyURL != nil {
            print("[BrowserWebView] WARNING: Proxy routing requires macOS 14+, proxy config ignored")
        }

        config.websiteDataStore = dataStore

        // Register JS message handler for HAR fetch/XHR interception.
        // Use a weak wrapper to avoid retain cycle:
        // model -> webView -> userContentController -> coordinator -> model
        let contentController = config.userContentController
        contentController.add(WeakScriptMessageHandler(context.coordinator), name: "harLog")

        // Inject fetch/XHR monkey-patch script for HAR recording
        let harScript = WKUserScript(source: Self.harInterceptScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(harScript)

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

    /// JavaScript injected at document start to monkey-patch fetch() and XMLHttpRequest
    /// for HAR recording. Posts captured request/response metadata to the native layer
    /// via window.webkit.messageHandlers.harLog.
    private static let harInterceptScript = """
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

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: BrowserPaneModel

        init(model: BrowserPaneModel) {
            self.model = model
        }

        // MARK: - WKScriptMessageHandler (HAR logging from JS)

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "harLog",
                  let body = message.body as? [String: Any],
                  model.harRecorder.isRecording else { return }

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

            model.harRecorder.append(HAREntry(
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
        }

        // MARK: - WKNavigationDelegate

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
            model.storeCertificateChain(serverTrust)

            // If TLS validation is disabled entirely
            if !model.tlsStrict {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }

            // If a proxy CA cert is configured, trust it for this connection only
            if let certPath = model.proxyCertPath,
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
}
