import SwiftUI
import WebKit

/// NSViewRepresentable wrapping WKWebView for use in SwiftUI.
/// The WKWebView is owned by the model and persists across view rebuilds.
struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var model: BrowserPaneModel

    /// Called when the user clicks inside the web view, so the terminal
    /// surface can relinquish focus and let Cmd+V reach the browser.
    var onBrowserFocused: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let wv = model.webView

        // Load initial URL if not already navigated
        if wv.url == nil, !model.urlString.isEmpty, let url = URL(string: model.urlString) {
            wv.load(URLRequest(url: url))
        }

        // Install a local event monitor so clicks inside the WKWebView
        // trigger the focus callback (WKWebView never becomes AppKit first
        // responder when hosted inside SwiftUI).
        let callback = onBrowserFocused
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak wv] event in
            guard let wv = wv else { return event }
            let loc = event.locationInWindow
            let converted = wv.convert(loc, from: nil)
            if wv.bounds.contains(converted) {
                callback?()
            }
            return event
        }

        return wv
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Updates driven by model.navigate(), not here
    }

    // MARK: - Coordinator

    class Coordinator {
        /// Holds the local-event-monitor token so we can remove it on deinit.
        var monitor: Any?

        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
