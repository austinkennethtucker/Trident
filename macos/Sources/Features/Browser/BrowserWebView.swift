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
}
