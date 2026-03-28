# Browser Pane Roadmap

Feature roadmap for the Trident embedded browser pane. Organized by priority tier based on impact and effort.

## Completed

- **Browser tabs** — Multiple tabs per browser pane with shared proxy/HAR/socket infrastructure, tab bar UI, and socket commands (`tab_new`, `tab_close`, `tab_switch`, `tab_list`).

---

## Tier 1 — High Impact, Moderate Effort

### 1. Open terminal links in browser pane
Route clicked URLs to the browser pane instead of the system browser when the pane is visible. The terminal already detects URLs via OSC 8 hyperlinks and regex matching (`open_url` action). Add a preference or auto-detect: if the browser pane is open, navigate there instead of calling `NSWorkspace.shared.open()`.

**Key files:** `Ghostty.App.swift` (`openURL`), `action.zig` (`open_url`), `BrowsableSurface.swift`

### 2. Find-in-page
Add Cmd+F search within the browser pane. WKWebView has built-in `find(_:configuration:)` support (macOS 13+). Show a search bar overlay with match count, next/prev navigation.

**Key files:** `BrowserPaneView.swift`, `BrowserPaneModel.swift`

### 3. Send URL from terminal to browser
New action `browser_navigate` that takes selected text or clipboard content and navigates the active browser tab to it. Bindable to a keybind. Also add a socket command `terminal_selection` that returns the current terminal selection text.

**Key files:** `action.zig`, `Ghostty.App.swift`, `BrowserSocketServer.swift`

### 4. Page zoom
Expose `WKWebView.pageZoom` with Cmd+Plus / Cmd+Minus / Cmd+0 shortcuts. Show current zoom level in the address bar. Persist per-domain zoom preferences.

**Key files:** `BrowserPaneModel.swift`, `BrowserPaneView.swift`, `BrowserWebView.swift`

### 5. Download management
Implement `WKDownloadDelegate` to intercept file downloads. Show a progress indicator in the browser pane, save to `~/Downloads`, and notify on completion.

**Key files:** `BrowserPaneModel.swift` (add `WKDownloadDelegate` conformance)

---

## Tier 2 — Medium Effort, High Value

### 6. Bidirectional text piping
Send terminal command output to the browser (render HTML/JSON/markdown), or paste browser content into the terminal. Add socket commands: `terminal_send` (write text to paired PTY), `terminal_output` (capture recent terminal output).

**Key files:** `BrowserSocketServer.swift`, `SurfaceView_AppKit.swift`, `Termio.zig`

### 7. Network request viewer
The HAR recorder already captures request metadata. Build a panel UI (similar to Chrome's Network tab) showing request/response list with method, URL, status, timing. Filterable by type. Click to expand headers and body.

**Key files:** New `BrowserNetworkPanel.swift`, `BrowserHARRecorder.swift`, `BrowserPaneView.swift`

### 8. Browser in popup terminals
Allow a browser-only popup window (no terminal split) via popup config: `popup = docs:browser:true` or a dedicated `browser-popup` config. Useful for quick documentation lookups that float above the terminal.

**Key files:** `popup.zig`, `PopupManager.swift`/`PopupController.swift`, `BrowserTabManager.swift`

### 9. User-Agent switcher
Dropdown menu in the address bar to switch between common user agents (desktop Chrome, mobile Safari, Googlebot, etc.). Uses `WKWebView.customUserAgent`. Persist selection per tab.

**Key files:** `BrowserPaneModel.swift`, `BrowserPaneView.swift`

### 10. Persistent history and bookmarks
Store navigation history and bookmarks in `~/.config/trident/browser/`. Show history via address bar autocomplete. Bookmarks accessible from a dropdown. Simple JSON storage.

**Key files:** New `BrowserHistory.swift`, New `BrowserBookmarks.swift`, `BrowserPaneView.swift`

---

## Tier 3 — Lower Effort, Nice-to-Have

### 11. Tab drag-and-drop reordering
Let users drag browser tab buttons to reorder them. Use SwiftUI `.onDrag` / `.onDrop` modifiers on `BrowserTabButton`.

**Key files:** `BrowserTabBar.swift`, `BrowserTabManager.swift`

### 12. Tab pinning
Pin frequently-used tabs to the left of the tab bar. Pinned tabs show only a favicon, can't be closed accidentally, and persist across browser toggle.

**Key files:** `BrowserTabManager.swift`, `BrowserTabBar.swift`

### 13. Reader mode
Strip page chrome and render article text in a clean, readable format. Use Mozilla's Readability.js (injected via `WKUserScript`) or a Swift port. Toggle via a button in the address bar.

**Key files:** `BrowserPaneModel.swift`, `BrowserPaneView.swift`

### 14. Print-to-PDF
Export current page as PDF using `WKWebView.createPDF()` (macOS 12+). Add Cmd+P handler and a `pdf_export` socket command. Save dialog for output path.

**Key files:** `BrowserPaneModel.swift`, `BrowserSocketServer.swift`

### 15. Dark mode for web content
Inject `prefers-color-scheme: dark` CSS media override to match the terminal's dark theme. Toggle automatically based on terminal background color or add a manual toggle.

**Key files:** `BrowserPaneModel.swift` (add `WKUserScript` injection in `createWebView()`)

---

## Future Considerations

These are larger efforts that may be worth exploring later:

- **Linux/GTK browser pane** — Port the browser feature using WebKitGTK. Major effort but brings platform parity.
- **Chrome DevTools Protocol (CDP)** — Expose CDP over the socket server for integration with external tools (Puppeteer, Playwright).
- **WebSocket inspection** — Monitor and display WebSocket frames in the network panel.
- **Vi-mode browser navigation** — When vi mode is active, add j/k scrolling, f for link hints, gi for form focus in the browser pane.
- **Extension/plugin system** — Allow user scripts or browser extensions to be loaded into the browser pane.
