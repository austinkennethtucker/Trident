import Foundation
import WebKit

/// Manages injected JavaScript for DOM element inspection overlay.
/// Highlights hovered elements and shows tag/class/id info.
class BrowserInspectorOverlay {
    private weak var webView: WKWebView?
    private(set) var isActive: Bool = false

    private let overlayScript = """
    (function() {
        if (window.__tridentInspector) { return; }
        window.__tridentInspector = true;

        const overlay = document.createElement('div');
        overlay.id = '__trident-inspector-overlay';
        overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff6b35;background:rgba(255,107,53,0.1);display:none;transition:all 0.05s ease;';
        document.body.appendChild(overlay);

        const label = document.createElement('div');
        label.id = '__trident-inspector-label';
        label.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;background:#1a1a2e;color:#e0e0e0;font:11px/1.4 SF Mono,Menlo,monospace;padding:4px 8px;border-radius:4px;display:none;max-width:400px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';
        document.body.appendChild(label);

        let lastTarget = null;
        document.addEventListener('mousemove', function(e) {
            const el = document.elementFromPoint(e.clientX, e.clientY);
            if (!el || el === overlay || el === label || el === lastTarget) return;
            lastTarget = el;
            const rect = el.getBoundingClientRect();
            overlay.style.left = rect.left + 'px';
            overlay.style.top = rect.top + 'px';
            overlay.style.width = rect.width + 'px';
            overlay.style.height = rect.height + 'px';
            overlay.style.display = 'block';

            let info = el.tagName.toLowerCase();
            if (el.id) info += '#' + el.id;
            if (el.className && typeof el.className === 'string') info += '.' + el.className.trim().split(/\\s+/).join('.');
            info += ' (' + Math.round(rect.width) + 'x' + Math.round(rect.height) + ')';
            label.textContent = info;
            label.style.left = Math.min(rect.left, window.innerWidth - 300) + 'px';
            label.style.top = Math.max(0, rect.top - 24) + 'px';
            label.style.display = 'block';
        }, true);
    })();
    """

    private let removeScript = """
    (function() {
        document.getElementById('__trident-inspector-overlay')?.remove();
        document.getElementById('__trident-inspector-label')?.remove();
        window.__tridentInspector = false;
    })();
    """

    init(webView: WKWebView?) {
        self.webView = webView
    }

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate()
        }
    }

    func activate() {
        isActive = true
        webView?.evaluateJavaScript(overlayScript, completionHandler: nil)
    }

    func deactivate() {
        isActive = false
        webView?.evaluateJavaScript(removeScript, completionHandler: nil)
    }
}
