import Foundation
import Combine

/// Manages multiple browser tabs within a single browser pane.
/// Each tab has its own BrowserPaneModel (and WKWebView), while the
/// proxy relay, HAR recorder, and socket server are shared.
class BrowserTabManager: ObservableObject {
    struct Tab: Identifiable {
        let id = UUID()
        let model: BrowserPaneModel
    }

    @Published var tabs: [Tab] = []
    @Published var activeTabIndex: Int = 0

    /// Called when the last tab is closed, signaling the browser pane should hide.
    var onLastTabClosed: (() -> Void)?

    /// Shared infrastructure across all tabs.
    let harRecorder: BrowserHARRecorder
    private(set) var proxyRelay: BrowserProxyRelay?
    private(set) var socketServer: BrowserSocketServer?
    /// Shared autofill vault index and pass-cli interface, nil when disabled.
    private(set) var autofillStore: AutofillStore?

    /// Config values forwarded to new tab models.
    private let proxyURL: String?
    private let proxyCertPath: String?
    private let tlsStrict: Bool
    private let autofillEnabled: Bool
    private let autofillVault: String?

    /// Combine subscriptions for forwarding child objectWillChange.
    private var childCancellables: [UUID: AnyCancellable] = [:]

    /// The currently active tab's model, or nil if no tabs exist.
    var activeModel: BrowserPaneModel? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex].model
    }

    init(
        proxyURL: String? = nil,
        proxyCertPath: String? = nil,
        tlsStrict: Bool = true,
        autofillEnabled: Bool = false,
        autofillVault: String? = nil
    ) {
        self.proxyURL = proxyURL
        self.proxyCertPath = proxyCertPath
        self.tlsStrict = tlsStrict
        self.autofillEnabled = autofillEnabled
        self.autofillVault = autofillVault
        self.harRecorder = BrowserHARRecorder()
        if autofillEnabled {
            self.autofillStore = AutofillStore(vaultName: autofillVault)
        }

        // Start shared proxy relay
        let relay = BrowserProxyRelay()
        relay.upstreamProxy = proxyURL
        relay.harRecorder = harRecorder
        do {
            try relay.start()
            self.proxyRelay = relay
            print("[BrowserTabManager] Proxy relay started on port \(relay.localPort)")
        } catch {
            print("[BrowserTabManager] Proxy relay failed to start: \(error)")
        }

        // Start shared socket server
        let paneId = UUID()
        let server = BrowserSocketServer(paneId: paneId)
        server.tabManager = self
        do {
            try server.start()
            self.socketServer = server
            print("[BrowserTabManager] Socket server started at: \(server.socketPath)")
        } catch {
            print("[BrowserTabManager] Socket server failed to start: \(error)")
        }

        // Create the first tab
        _ = addTab()
    }

    deinit {
        socketServer?.stop()
        proxyRelay?.stop()
    }

    // MARK: - Tab Management

    /// Add a new tab, optionally pre-loaded with a URL. Returns the index.
    @discardableResult
    func addTab(url: String? = nil) -> Int {
        let model = BrowserPaneModel(
            proxyURL: proxyURL,
            proxyCertPath: proxyCertPath,
            tlsStrict: tlsStrict,
            sharedRelay: proxyRelay,
            ownsRelay: false,
            harRecorder: harRecorder,
            autofillStore: autofillStore,
            autofillEnabled: autofillEnabled
        )
        if let url = url {
            model.navigate(to: url)
        }

        let tab = Tab(model: model)
        let insertIndex = tabs.isEmpty ? 0 : activeTabIndex + 1
        tabs.insert(tab, at: insertIndex)
        activeTabIndex = insertIndex

        // Forward child model changes so the tab bar re-renders
        childCancellables[tab.id] = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        return insertIndex
    }

    /// Close a tab at the given index. Returns true if the browser pane
    /// should close (last tab was closed).
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }

        let tab = tabs[index]
        childCancellables.removeValue(forKey: tab.id)
        tabs.remove(at: index)

        if tabs.isEmpty {
            onLastTabClosed?()
            return true
        }

        // Adjust active index
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }

        return false
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
    }

    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        activeTabIndex = (activeTabIndex + 1) % tabs.count
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        activeTabIndex = (activeTabIndex - 1 + tabs.count) % tabs.count
    }

    // MARK: - HAR Recording (delegates to shared recorder)

    func startHARRecording() { harRecorder.start() }
    func stopHARRecording() { harRecorder.stop() }
    func exportHAR() -> [String: Any] { harRecorder.exportHAR() }
}
