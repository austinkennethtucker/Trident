# GTK Browser Pane Design

**Date:** 2026-03-28
**Status:** Approved
**Feature:** v8.0 Linux — Embedded browser pane for GTK apprt
**Depends on:** macOS browser pane (PR #51, #56)

## Summary

Implement an embedded WebKitGTK browser pane in the Linux/GTK application runtime, achieving feature parity with the existing macOS WKWebView browser pane. The browser targets offensive security workflows: intercepting proxy routing, DOM inspection, cookie/session manipulation, and CLI-driven automation via a Unix domain socket API.

## Target

- **WebKitGTK version:** webkitgtk-6.0 (GTK4-native)
- **Build gating:** `-Denable-browser=true` flag (existing, currently macOS-only)
- **System dependency:** `libwebkitgtk-6.0-dev` (Debian/Ubuntu) / `webkitgtk6.0-devel` (Fedora)

## Architecture

### Approach: Native Zig GObject Widget

All browser code is written in Zig using the same `gobject.ext.defineClass()` pattern as every other GTK widget in the codebase. WebKitGTK's C API is accessed via the zig-gobject auto-generated bindings or `@cImport` fallback.

Alternatives considered:
- **Separate process with foreign surface embed** — Rejected. Fragile on Wayland, high IPC complexity, architecturally alien.
- **C shim library** — Rejected. Introduces C source in a pure-Zig codebase, adds unnecessary abstraction layer.

## Build System

In `src/build/SharedDeps.zig`, when `enable-browser` is true and app_runtime is GTK:

```zig
if (self.config.@"enable-browser") {
    step.linkSystemLibrary2("webkitgtk-6.0", dynamic_link_opts);
}
```

**Binding strategy:** First check if the `ghostty-org/zig-gobject` fork generates webkitgtk-6.0 bindings (look for a `webkitgtk6` or `webkit2gtk6` module). If yes, register the module import for type-safe Zig methods. If not, use `@cImport(@cInclude("webkit/webkit.h"))` for raw C function access. The `@cImport` path is the safe default — it always works with any system-installed WebKitGTK.

The `enable-browser` build flag and `build_config.enable_browser` comptime constant already exist.

## Widget Architecture

### BrowserWidget (`src/apprt/gtk/class/browser_widget.zig`)

GObject class extending `gtk.Box` (vertical orientation):

```
BrowserWidget (gtk.Box, vertical)
+-- AddressBar (gtk.Box, horizontal)
|   +-- Back button (gtk.Button, chevron-left)
|   +-- Forward button (gtk.Button, chevron-right)
|   +-- Reload/Stop button (gtk.Button, toggles on loading state)
|   +-- URL entry (gtk.Entry, activates on Enter)
|   +-- Proxy indicator (gtk.Image, shield icon, visible when proxy active)
|   +-- Inspector toggle (gtk.ToggleButton, eye icon)
|   +-- JS Console toggle (gtk.ToggleButton, terminal icon)
+-- Progress bar (gtk.ProgressBar, visible during loading)
+-- WebKitWebView (the browser engine)
+-- JS Console panel (gtk.Box, vertical, togglable visibility)
    +-- Output (gtk.ScrolledWindow > gtk.TextView, monospace, read-only)
    +-- Input (gtk.Box: ">" label + gtk.Entry)
```

**Key properties:**
- Extends `gtk.Box` (not `adw.Bin`) because multiple children are stacked vertically
- `Parent = gtk.Box`
- Private struct holds: `web_view`, `url_entry`, `progress_bar`, `console_output`, `console_input`, `socket_server`, `proxy_relay`, `har_recorder`, config fields

**WebView setup:**
- Ephemeral `WebKitWebContext` (session isolation, no persistent cookies/cache)
- Navigation signals connected for URL/title/loading state updates
- `"load-changed"` signal for progress tracking
- `"decide-policy"` signal for navigation interception

**CSS classes:** `"browser-toolbar"`, `"browser-console"` for theme integration.

## Split Tree Integration

### toggle_browser Action

The `toggle_browser` action creates/destroys a browser pane beside the active terminal surface.

**Flow:**

```
User keybind --> toggle_browser action
  --> Application.performAction() switch case
    --> Gets active surface's SplitTree
    --> If no browser: create BrowserWidget, insert as horizontal split via gtk.Paned
    --> If browser exists: remove BrowserWidget, unsplit
```

**Split tree changes:**
- `SplitTree` private struct gains: `browser_widget: ?*BrowserWidget`
- One browser per split tree (tab-level, not per-pane)
- The `gtk.Paned` accepts any `gtk.Widget` — no data structure changes needed

**Config bridging:**
- Browser config (`browser-proxy`, `browser-proxy-cert`, `browser-tls-strict`) read via `ghostty_config_get()` at creation time, same pattern as surface config access.

## Socket Server (`src/apprt/gtk/browser_socket.zig`)

Unix domain socket at `/tmp/trident/b-<8-char-uuid>.sock` (mode 0600). Newline-delimited JSON protocol, identical to macOS.

**Implementation:**
- `std.posix.socket()` / `bind()` / `listen()` / `accept()` for Unix socket
- `std.json` for parsing and serialization
- Dedicated thread with `std.posix.poll()` for multiplexing clients
- Commands touching WebKitWebView dispatch to GTK main thread via `glib.idleAdd()`

**17 commands (full parity with macOS):**

| Command | Description |
|---------|-------------|
| `navigate` | Load URL |
| `back` | History back |
| `forward` | History forward |
| `reload` | Reload page |
| `status` | URL, title, loading state |
| `js_eval` | Execute JavaScript, return result |
| `dom_snapshot` | Return outerHTML |
| `screenshot` | Capture viewport as PNG base64 |
| `cookies_get` | Get cookies for current domain |
| `cookies_set` | Set a cookie |
| `session_export` | Export cookies + localStorage |
| `session_import` | Import cookies + localStorage |
| `cert_info` | TLS certificate chain details |
| `proxy_set` | Change proxy at runtime |
| `har_start` | Begin HAR recording |
| `har_stop` | Stop recording |
| `har_export` | Export HAR 1.2 JSON |

## Proxy Routing

### WebKitGTK Native Proxy API

Unlike macOS (which needs a local relay workaround), WebKitGTK has first-class proxy support:

```c
webkit_network_session_set_proxy_settings(
    session,
    WEBKIT_NETWORK_PROXY_MODE_CUSTOM,
    webkit_network_proxy_settings_new(proxy_uri, NULL)
);
```

This is called directly — no local relay needed for basic proxy routing.

### Local Relay for HAR Recording (`src/apprt/gtk/browser_relay.zig`)

A local TCP relay proxy is still needed for intercepting and logging HTTP traffic for HAR recording:

```
WebKitWebView --> local relay (127.0.0.1:<random>) --> upstream proxy (or direct)
```

**Implementation:**
- `std.posix.socket()` + `std.posix.poll()` for TCP relay
- Dedicated thread alongside socket server
- Handles HTTP CONNECT tunneling and plain HTTP forwarding
- Logs request metadata to HAR recorder when recording is active

When HAR recording is not active, the relay is bypassed — WebKitGTK routes directly through its native proxy settings.

## TLS Handling

- **`browser-tls-strict = false`:** `webkit_website_data_manager_set_tls_errors_policy()` with `WEBKIT_TLS_ERRORS_POLICY_IGNORE`
- **`browser-proxy-cert` set:** Inject CA into `GTlsDatabase` for the web context, allowing the intercept proxy's CA to be trusted without system-wide changes
- **Default:** Standard system trust store validation

## HAR Recorder (`src/apprt/gtk/browser_har.zig`)

Thread-safe in-memory recorder (mutex-protected). Identical data model to macOS `BrowserHARRecorder.swift`.

**Data types:**
- `HAREntry`: startedDateTime, method, url, httpVersion, requestHeaders, responseStatus, responseHeaders, bodySize, timings, source (relay vs js_intercept)
- `HARTimings`: connect, send, wait, receive

**Two capture sources:**
1. **Relay proxy** — HTTP: full headers/status/timing. CONNECT: host:port, timing, bytes (no decrypted HTTPS content).
2. **Injected JS** — Monkey-patches `fetch()` and `XMLHttpRequest` at document start. Posts entries via `webkit_user_content_manager_register_script_message_handler()` + `"script-message-received"` signal.

**Export:** HAR 1.2 format via `har_export` socket command.

## DOM Inspector & JS Console

**DOM inspector:** Same injected JavaScript as macOS (platform-independent). Orange highlight overlay + floating label showing `tag#id.class (WxH)`. Injected via `webkit_web_view_evaluate_javascript()`. Toggled via address bar button.

**JS console:** GTK-native panel (not injected):
- `gtk.TextView` (monospace, read-only, scrollable) for output
- `gtk.Entry` with `">"` prompt for input
- Enter submits JS via `webkit_web_view_evaluate_javascript()`, result/error appended to output
- Toggled via address bar button

## File Inventory

### New files (4)

| File | Purpose | ~Lines |
|------|---------|--------|
| `src/apprt/gtk/class/browser_widget.zig` | GObject widget: address bar, WebView, JS console, inspector | ~800 |
| `src/apprt/gtk/browser_socket.zig` | Unix socket server, JSON command dispatch | ~500 |
| `src/apprt/gtk/browser_relay.zig` | Local TCP proxy relay for HAR recording | ~400 |
| `src/apprt/gtk/browser_har.zig` | HAR 1.2 recorder (thread-safe, mutex) | ~200 |

### Modified files (4)

| File | Change | ~Lines |
|------|--------|--------|
| `src/build/SharedDeps.zig` | Link `webkitgtk-6.0` when `enable-browser` | ~10 |
| `src/apprt/gtk/class/application.zig` | Handle `toggle_browser` in `performAction` switch | ~20 |
| `src/apprt/gtk/class/split_tree.zig` | Add `browser_widget` field, toggle helper | ~40 |
| `src/apprt/gtk/class.zig` | Import `browser_widget` module | ~2 |

### Not in scope

- `src/config/Config.zig` — browser config fields already exist
- `src/apprt/action.zig` — `toggle_browser` already defined
- `include/ghostty.h` — action enum already present
- macOS code — no changes
- Vendored WebKitGTK — system library, dynamically linked

## Testing

**Build:** `zig build -Denable-browser=true` (requires `webkitgtk-6.0` dev package)

**Manual verification via socket API:**
```bash
SOCK=$(ls /tmp/trident/b-*.sock | head -1)
echo '{"cmd":"navigate","url":"https://example.com"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"status"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"cert_info"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"js_eval","code":"document.title"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"har_start"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"navigate","url":"https://example.com"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"har_stop"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"har_export"}' | socat - UNIX-CONNECT:$SOCK | python3 -m json.tool
```

**Proxy test:** Start mitmproxy, `proxy_set`, navigate, verify traffic in mitmproxy.

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| zig-gobject may not include webkitgtk-6.0 bindings | Medium | Fall back to `@cImport` for raw C access |
| webkitgtk-6.0 not available on older distros | Medium | Gated behind `enable-browser` flag, documented as optional |
| WebKitGTK crashes/leaks | Low | Separate web process (default for WebKit2), crash doesn't take down terminal |
| HAR HTTPS content opacity | Inherent | Document limitation — relay sees CONNECT metadata only, JS intercept covers fetch/XHR |
