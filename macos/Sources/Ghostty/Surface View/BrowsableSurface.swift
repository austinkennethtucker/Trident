import SwiftUI
import GhosttyKit

extension Ghostty {
    /// BrowsableSurface wraps InspectableSurface and optionally shows
    /// an embedded browser pane beside the terminal. Follows the same
    /// pattern as InspectableSurface wraps SurfaceWrapper for the inspector.
    struct BrowsableSurface: View {
        @EnvironmentObject var ghostty: Ghostty.App

        /// Same as InspectableSurface, see the doc comments there.
        @ObservedObject var surfaceView: SurfaceView
        var isSplit: Bool = false

        // The fractional area of the terminal vs. the browser (0.5 = 50/50)
        @State private var browserSplit: CGFloat = 0.5

        var body: some View {
            let center = NotificationCenter.default
            let pubBrowser = center.publisher(
                for: Notification.didToggleBrowser,
                object: surfaceView
            )

            ZStack {
                if !surfaceView.browserVisible {
                    InspectableSurface(
                        surfaceView: surfaceView,
                        isSplit: isSplit
                    )
                } else if let tabManager = surfaceView.browserTabManager {
                    SplitView(
                        .horizontal,
                        $browserSplit,
                        dividerColor: ghostty.config.splitDividerColor,
                        left: {
                            InspectableSurface(
                                surfaceView: surfaceView,
                                isSplit: true
                            )
                        },
                        right: {
                            BrowserPaneView(
                                tabManager: tabManager,
                                onBrowserFocused: { [weak surfaceView] in
                                    surfaceView?.focusDidChange(false)
                                }
                            )
                        },
                        onEqualize: {
                            guard let surface = surfaceView.surface else { return }
                            ghostty.splitEqualize(surface: surface)
                        }
                    )
                }
            }
            .onReceive(pubBrowser) { _ in
                onToggleBrowser()
            }
        }

        private func onToggleBrowser() {
            // Ensure tab manager exists before showing, with config from ghostty
            if surfaceView.browserTabManager == nil {
                let manager = BrowserTabManager(
                    proxyURL: ghostty.config.browserProxy,
                    proxyCertPath: ghostty.config.browserProxyCert,
                    tlsStrict: ghostty.config.browserTlsStrict,
                    autofillEnabled: ghostty.config.browserAutofill,
                    autofillVault: ghostty.config.browserAutofillVault
                )
                manager.onLastTabClosed = { [weak surfaceView] in
                    surfaceView?.browserVisible = false
                }
                surfaceView.browserTabManager = manager
            }
            surfaceView.browserVisible.toggle()
        }
    }
}
