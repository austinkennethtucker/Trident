import SwiftUI
import WebKit

/// NSViewRepresentable wrapping WKWebView for use in SwiftUI.
/// The WKWebView is owned by the model and persists across view rebuilds.
struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var model: BrowserPaneModel

    func makeNSView(context: Context) -> WKWebView {
        let wv = model.webView

        // Load initial URL if not already navigated
        if wv.url == nil, !model.urlString.isEmpty, let url = URL(string: model.urlString) {
            wv.load(URLRequest(url: url))
        }

        return wv
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Updates driven by model.navigate(), not here
    }

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
}
