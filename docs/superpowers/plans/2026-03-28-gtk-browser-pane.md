# GTK Browser Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement an embedded WebKitGTK browser pane in the GTK apprt, achieving full feature parity with the macOS WKWebView browser pane.

**Architecture:** Native Zig GObject widget (`BrowserWidget`) wrapping webkitgtk-6.0 via `@cImport`. Unix socket server and TCP proxy relay run on dedicated threads. The widget integrates into the existing split tree as a sibling pane toggled by the `toggle_browser` action.

**Tech Stack:** Zig, GTK4, webkitgtk-6.0, GObject, POSIX sockets, POSIX threads

**Design Spec:** `docs/superpowers/specs/2026-03-28-gtk-browser-pane-design.md`

---

## File Map

### New files

| File | Responsibility |
|------|---------------|
| `src/apprt/gtk/class/browser_widget.zig` | GObject widget: address bar, WebKitWebView, JS console, DOM inspector, lifecycle |
| `src/apprt/gtk/browser_socket.zig` | Unix socket server: accept clients, parse JSON, dispatch 17 commands |
| `src/apprt/gtk/browser_relay.zig` | Local TCP proxy relay for HAR recording |
| `src/apprt/gtk/browser_har.zig` | Thread-safe HAR 1.2 entry recorder |

### Modified files

| File | Change |
|------|--------|
| `src/build/SharedDeps.zig` | Link `webkitgtk-6.0` when `enable-browser` is true |
| `src/apprt/gtk/class.zig` | Add `BrowserWidget` import |
| `src/apprt/gtk/class/application.zig` | Handle `toggle_browser` action in `performAction` switch |
| `src/apprt/gtk/class/split_tree.zig` | Add `browser_widget` field to Private, toggle/destroy helpers |

---

## Task 1: Build System — Link WebKitGTK

**Files:**
- Modify: `src/build/SharedDeps.zig`

- [ ] **Step 1: Add webkitgtk-6.0 linkage gated behind enable-browser**

In `src/build/SharedDeps.zig`, find the block where `gtk4` and `libadwaita-1` are linked (around line 586). Add the WebKitGTK linkage immediately after, gated behind the build flag:

```zig
step.linkSystemLibrary2("gtk4", dynamic_link_opts);
step.linkSystemLibrary2("libadwaita-1", dynamic_link_opts);

if (self.config.@"enable-browser") {
    step.linkSystemLibrary2("webkitgtk-6.0", dynamic_link_opts);
}
```

This goes inside the `fn addGtk(self: *const SharedDeps, step: *std.Build.Step.Compile)` function, right after the `libadwaita-1` line.

- [ ] **Step 2: Verify the build still compiles without browser flag**

Run: `zig build -Demit-macos-app=false`

Expected: Clean build (webkitgtk-6.0 is NOT linked).

- [ ] **Step 3: Commit**

```bash
git add src/build/SharedDeps.zig
git commit -m "build: link webkitgtk-6.0 when enable-browser is set"
```

---

## Task 2: HAR Recorder — Thread-Safe Entry Storage

**Files:**
- Create: `src/apprt/gtk/browser_har.zig`

This is a pure-Zig data structure with no GTK or WebKit dependency, so it can be built and tested first.

- [ ] **Step 1: Create the HAR recorder**

Create `src/apprt/gtk/browser_har.zig`:

```zig
const std = @import("std");

pub const HAREntry = struct {
    started_ms: i64,
    method: []const u8,
    url: []const u8,
    http_version: []const u8 = "HTTP/1.1",
    request_headers: []const Header = &.{},
    response_status: u16 = 0,
    response_status_text: []const u8 = "",
    response_headers: []const Header = &.{},
    response_body_size: i64 = -1,
    timings: HARTimings = .{},
    source: Source = .relay,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Source = enum {
        relay,
        js_intercept,
    };
};

pub const HARTimings = struct {
    connect_ms: f64 = -1,
    send_ms: f64 = -1,
    wait_ms: f64 = -1,
    receive_ms: f64 = -1,

    pub fn total(self: HARTimings) f64 {
        var t: f64 = 0;
        if (self.connect_ms >= 0) t += self.connect_ms;
        if (self.send_ms >= 0) t += self.send_ms;
        if (self.wait_ms >= 0) t += self.wait_ms;
        if (self.receive_ms >= 0) t += self.receive_ms;
        return t;
    }
};

pub const HARRecorder = struct {
    entries: std.ArrayList(HAREntry),
    is_recording: bool = false,
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator) HARRecorder {
        return .{
            .entries = std.ArrayList(HAREntry).init(alloc),
        };
    }

    pub fn deinit(self: *HARRecorder) void {
        self.entries.deinit();
    }

    pub fn start(self: *HARRecorder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entries.clearRetainingCapacity();
        self.is_recording = true;
    }

    pub fn stop(self: *HARRecorder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_recording = false;
    }

    pub fn append(self: *HARRecorder, entry: HAREntry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.is_recording) return;
        self.entries.append(entry) catch {};
    }

    pub fn entryCount(self: *HARRecorder) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    /// Export HAR 1.2 as a JSON string. Caller owns returned memory.
    pub fn exportJSON(self: *HARRecorder, alloc: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        const entries = self.entries.items;
        self.mutex.unlock();

        var buf = std.ArrayList(u8).init(alloc);
        const writer = buf.writer();

        try writer.writeAll("{\"log\":{\"version\":\"1.2\",\"creator\":{\"name\":\"Trident Browser\",\"version\":\"1.0\"},\"entries\":[");

        for (entries, 0..) |entry, i| {
            if (i > 0) try writer.writeByte(',');
            try writeHAREntry(writer, entry);
        }

        try writer.writeAll("]}}");
        return buf.toOwnedSlice();
    }

    fn writeHAREntry(writer: anytype, entry: HAREntry) !void {
        try writer.print(
            \\{{"startedDateTime":"{d}","time":{d:.1},
        , .{ entry.started_ms, entry.timings.total() });

        // Request
        try writer.print(
            \\"request":{{"method":"{s}","url":"{s}","httpVersion":"{s}",
        , .{ entry.method, entry.url, entry.http_version });
        try writer.writeAll("\"headers\":[],\"queryString\":[],\"cookies\":[],\"headersSize\":-1,\"bodySize\":-1},");

        // Response
        try writer.print(
            \\"response":{{"status":{d},"statusText":"{s}","httpVersion":"{s}",
        , .{ entry.response_status, entry.response_status_text, entry.http_version });
        try writer.print(
            \\"headers\":[],\"cookies\":[],\"redirectURL\":\"\","headersSize":-1,"bodySize":{d},
        , .{entry.response_body_size});
        try writer.print(
            \\"content":{{"size":{d},"mimeType":""}}}},
        , .{entry.response_body_size});

        // Timings
        try writer.print(
            \\"timings":{{"connect":{d:.1},"send":{d:.1},"wait":{d:.1},"receive":{d:.1}}},
        , .{ entry.timings.connect_ms, entry.timings.send_ms, entry.timings.wait_ms, entry.timings.receive_ms });

        // Source and cache
        try writer.print(
            \\"cache":{{}},"_source":"{s}"}}
        , .{@tagName(entry.source)});
    }
};
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build-lib src/apprt/gtk/browser_har.zig --name browser_har 2>&1 || echo "expected — just checking syntax"`

Since this file imports std only, verify syntax by reading for obvious issues. The full build test comes in Task 7.

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/browser_har.zig
git commit -m "feat(gtk): add HAR 1.2 recorder for browser pane"
```

---

## Task 3: Socket Server — Unix Domain Socket + Command Dispatch

**Files:**
- Create: `src/apprt/gtk/browser_socket.zig`

The socket server runs on a dedicated thread, accepts newline-delimited JSON, and dispatches commands to a callback. It does NOT directly reference WebKit — it calls function pointers provided by the BrowserWidget.

- [ ] **Step 1: Create the socket server**

Create `src/apprt/gtk/browser_socket.zig`:

```zig
const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.browser_socket);

/// Function type for dispatching a command on the GTK main thread.
/// Takes the command name and the full JSON object as a string.
/// Returns a JSON response string (caller owns memory).
pub const CommandHandler = *const fn (cmd: []const u8, json: []const u8, ctx: *anyopaque) []const u8;

pub const BrowserSocket = struct {
    socket_path: [104]u8 = undefined,
    socket_path_len: usize = 0,
    socket_fd: posix.fd_t = -1,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    handler: CommandHandler,
    handler_ctx: *anyopaque,
    alloc: std.mem.Allocator,

    pub fn init(
        alloc: std.mem.Allocator,
        pane_id: [8]u8,
        handler: CommandHandler,
        handler_ctx: *anyopaque,
    ) !BrowserSocket {
        var self = BrowserSocket{
            .handler = handler,
            .handler_ctx = handler_ctx,
            .alloc = alloc,
        };

        // Build socket path: /tmp/trident/b-<8chars>.sock
        const dir = "/tmp/trident";
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const path = std.fmt.bufPrint(&self.socket_path, "{s}/b-{s}.sock", .{ dir, pane_id }) catch unreachable;
        self.socket_path_len = path.len;

        return self;
    }

    pub fn socketPath(self: *const BrowserSocket) []const u8 {
        return self.socket_path[0..self.socket_path_len];
    }

    pub fn start(self: *BrowserSocket) !void {
        // Remove stale socket
        std.fs.deleteFileAbsolute(self.socketPath()) catch {};

        // Create Unix socket
        self.socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(self.socket_fd);

        // Bind
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes = self.socketPath();
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        try posix.bind(self.socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Set permissions to 0600
        std.fs.cwd().chmodAbsolute(self.socketPath(), 0o600) catch {};

        // Listen
        try posix.listen(self.socket_fd, 5);

        // Start accept thread
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        log.info("socket server started at: {s}", .{self.socketPath()});
    }

    pub fn stop(self: *BrowserSocket) void {
        self.running.store(false, .release);
        if (self.socket_fd >= 0) {
            posix.close(self.socket_fd);
            self.socket_fd = -1;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        std.fs.deleteFileAbsolute(self.socketPath()) catch {};
    }

    fn acceptLoop(self: *BrowserSocket) void {
        while (self.running.load(.acquire)) {
            // Use poll to check for new connections with timeout
            var pfds = [_]posix.pollfd{.{
                .fd = self.socket_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const nready = posix.poll(&pfds, 500) catch break;
            if (nready == 0) continue;

            const client_fd = posix.accept(self.socket_fd, null, null) catch continue;
            self.handleClient(client_fd);
            posix.close(client_fd);
        }
    }

    fn handleClient(self: *BrowserSocket, fd: posix.fd_t) void {
        var buf: [65536]u8 = undefined;
        var filled: usize = 0;

        while (self.running.load(.acquire)) {
            var pfds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const nready = posix.poll(&pfds, 500) catch break;
            if (nready == 0) continue;

            const n = posix.read(fd, buf[filled..]) catch break;
            if (n == 0) break; // Client disconnected
            filled += n;

            // Process complete lines
            while (std.mem.indexOf(u8, buf[0..filled], "\n")) |nl| {
                const line = buf[0..nl];
                if (line.len > 0) {
                    self.processLine(fd, line);
                }
                // Shift remaining data
                const rest = filled - (nl + 1);
                if (rest > 0) {
                    std.mem.copyForwards(u8, buf[0..rest], buf[nl + 1 .. filled]);
                }
                filled = rest;
            }
        }
    }

    fn processLine(self: *BrowserSocket, fd: posix.fd_t, line: []const u8) void {
        // Extract "cmd" field from JSON
        const cmd = extractCmd(line) orelse {
            const err_resp = "{\"ok\":false,\"error\":\"missing 'cmd' field\"}\n";
            _ = posix.write(fd, err_resp) catch {};
            return;
        };

        // Dispatch to handler (which runs on GTK main thread internally)
        const response = self.handler(cmd, line, self.handler_ctx);
        defer self.alloc.free(response);

        _ = posix.write(fd, response) catch {};
        _ = posix.write(fd, "\n") catch {};
    }

    /// Quick extraction of the "cmd" value from a JSON string without full parsing.
    fn extractCmd(json: []const u8) ?[]const u8 {
        const key = "\"cmd\"";
        const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
        const after_key = json[key_pos + key.len ..];

        // Skip : and whitespace
        var i: usize = 0;
        while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t')) : (i += 1) {}

        // Expect opening quote
        if (i >= after_key.len or after_key[i] != '"') return null;
        i += 1;
        const start = i;

        // Find closing quote
        while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
        if (i >= after_key.len) return null;

        return after_key[start..i];
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/apprt/gtk/browser_socket.zig
git commit -m "feat(gtk): add Unix socket server for browser pane commands"
```

---

## Task 4: Proxy Relay — Local TCP Forwarder

**Files:**
- Create: `src/apprt/gtk/browser_relay.zig`

TCP relay that sits between WebKitWebView and the upstream proxy, logging traffic for HAR recording.

- [ ] **Step 1: Create the proxy relay**

Create `src/apprt/gtk/browser_relay.zig`:

```zig
const std = @import("std");
const posix = std.posix;
const HARRecorder = @import("browser_har.zig").HARRecorder;
const HAREntry = @import("browser_har.zig").HAREntry;
const HARTimings = @import("browser_har.zig").HARTimings;

const log = std.log.scoped(.browser_relay);

pub const BrowserRelay = struct {
    listen_fd: posix.fd_t = -1,
    local_port: u16 = 0,
    upstream_proxy: ?[]const u8 = null,
    har_recorder: ?*HARRecorder = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) BrowserRelay {
        return .{ .alloc = alloc };
    }

    pub fn start(self: *BrowserRelay) !void {
        // Create TCP socket on loopback
        self.listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(self.listen_fd);

        // Enable SO_REUSEADDR
        const optval: u32 = 1;
        try posix.setsockopt(self.listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));

        // Bind to 127.0.0.1:0 (random port)
        var addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = 0, // OS-assigned
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        };
        try posix.bind(self.listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

        // Get assigned port
        var bound_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(self.listen_fd, @ptrCast(&bound_addr), &addr_len);
        self.local_port = std.mem.bigToNative(u16, bound_addr.port);

        try posix.listen(self.listen_fd, 16);

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, relayLoop, .{self});

        log.info("relay started on 127.0.0.1:{d}", .{self.local_port});
    }

    pub fn stop(self: *BrowserRelay) void {
        self.running.store(false, .release);
        if (self.listen_fd >= 0) {
            posix.close(self.listen_fd);
            self.listen_fd = -1;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn relayLoop(self: *BrowserRelay) void {
        while (self.running.load(.acquire)) {
            var pfds = [_]posix.pollfd{.{
                .fd = self.listen_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const nready = posix.poll(&pfds, 500) catch break;
            if (nready == 0) continue;

            const client_fd = posix.accept(self.listen_fd, null, null) catch continue;

            // Handle in a detached thread to avoid blocking accept loop
            _ = std.Thread.spawn(.{}, handleConnection, .{ self, client_fd }) catch {
                posix.close(client_fd);
                continue;
            };
        }
    }

    fn handleConnection(self: *BrowserRelay, client_fd: posix.fd_t) void {
        defer posix.close(client_fd);

        // Read initial request
        var buf: [65536]u8 = undefined;
        const n = posix.read(client_fd, &buf) catch return;
        if (n == 0) return;
        const request = buf[0..n];

        // Parse request line
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const request_line = request[0..line_end];
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;

        const start_time = std.time.milliTimestamp();

        if (std.mem.eql(u8, method, "CONNECT")) {
            self.handleConnect(client_fd, target, start_time);
        } else {
            self.handleHTTP(client_fd, method, target, request, start_time);
        }
    }

    fn handleConnect(self: *BrowserRelay, client_fd: posix.fd_t, target: []const u8, start_time: i64) void {
        // Parse host:port
        const colon = std.mem.indexOf(u8, target, ":") orelse return;
        const host = target[0..colon];
        const port_str = target[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return;

        // Connect to remote (or upstream proxy)
        const remote_fd = self.connectToTarget(host, port) catch return;
        defer posix.close(remote_fd);

        const connect_time = std.time.milliTimestamp();

        // Send 200 Connection Established to client
        const response = "HTTP/1.1 200 Connection Established\r\n\r\n";
        _ = posix.write(client_fd, response) catch return;

        // Log to HAR
        if (self.har_recorder) |hr| {
            hr.append(.{
                .started_ms = start_time,
                .method = "CONNECT",
                .url = target,
                .response_status = 200,
                .response_status_text = "Connection Established",
                .timings = .{
                    .connect_ms = @as(f64, @floatFromInt(connect_time - start_time)),
                },
                .source = .relay,
            });
        }

        // Bidirectional relay
        self.pipeData(client_fd, remote_fd);
    }

    fn handleHTTP(self: *BrowserRelay, client_fd: posix.fd_t, method: []const u8, target: []const u8, request: []const u8, start_time: i64) void {
        // Parse URL for direct connection
        const url = std.Uri.parse(target) catch return;
        const host = url.host orelse return;
        const port: u16 = url.port orelse 80;

        const remote_fd = self.connectToTarget(host, port) catch return;
        defer posix.close(remote_fd);

        // Forward request
        _ = posix.write(remote_fd, request) catch return;

        // Read response
        var resp_buf: [65536]u8 = undefined;
        const resp_n = posix.read(remote_fd, &resp_buf) catch return;
        if (resp_n == 0) return;

        _ = posix.write(client_fd, resp_buf[0..resp_n]) catch return;

        // Log to HAR
        if (self.har_recorder) |hr| {
            hr.append(.{
                .started_ms = start_time,
                .method = method,
                .url = target,
                .response_status = 200,
                .response_body_size = @intCast(resp_n),
                .timings = .{
                    .connect_ms = 0,
                    .wait_ms = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time)),
                },
                .source = .relay,
            });
        }

        // Continue relaying
        self.pipeData(client_fd, remote_fd);
    }

    fn connectToTarget(self: *BrowserRelay, host: []const u8, port: u16) !posix.fd_t {
        _ = self; // upstream proxy support added later
        const addr_list = try std.net.Address.resolveIp(host, port);
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        try posix.connect(fd, @ptrCast(&addr_list), @sizeOf(@TypeOf(addr_list)));
        return fd;
    }

    fn pipeData(_: *BrowserRelay, fd_a: posix.fd_t, fd_b: posix.fd_t) void {
        var buf_a: [65536]u8 = undefined;
        var buf_b: [65536]u8 = undefined;
        while (true) {
            var pfds = [_]posix.pollfd{
                .{ .fd = fd_a, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = fd_b, .events = posix.POLL.IN, .revents = 0 },
            };
            const nready = posix.poll(&pfds, 5000) catch break;
            if (nready == 0) continue;

            if (pfds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(fd_a, &buf_a) catch break;
                if (n == 0) break;
                _ = posix.write(fd_b, buf_a[0..n]) catch break;
            }
            if (pfds[1].revents & posix.POLL.IN != 0) {
                const n = posix.read(fd_b, &buf_b) catch break;
                if (n == 0) break;
                _ = posix.write(fd_a, buf_b[0..n]) catch break;
            }

            // Check for hangup/error
            const hup_err = posix.POLL.HUP | posix.POLL.ERR;
            if (pfds[0].revents & hup_err != 0 or pfds[1].revents & hup_err != 0) break;
        }
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/apprt/gtk/browser_relay.zig
git commit -m "feat(gtk): add TCP proxy relay for browser HAR recording"
```

---

## Task 5: Browser Widget — GObject Class with WebKitGTK

**Files:**
- Create: `src/apprt/gtk/class/browser_widget.zig`
- Modify: `src/apprt/gtk/class.zig`

This is the largest task. The widget wraps WebKitWebView and builds the full UI.

- [ ] **Step 1: Add BrowserWidget import to class.zig**

In `src/apprt/gtk/class.zig`, add:

```zig
pub const BrowserWidget = if (@import("build_config").enable_browser)
    @import("class/browser_widget.zig").BrowserWidget
else
    void;
```

Add this after the existing `pub const Surface = ...` line.

- [ ] **Step 2: Create the browser widget**

Create `src/apprt/gtk/class/browser_widget.zig`. This file uses `@cImport` for WebKitGTK since zig-gobject does not include webkit bindings:

```zig
const std = @import("std");
const build_config = @import("build_config");
const gobject = @import("gobject");
const gtk = @import("gtk");
const glib = @import("glib");

const Common = @import("../class.zig").Common;
const BrowserSocket = @import("../browser_socket.zig").BrowserSocket;
const BrowserRelay = @import("../browser_relay.zig").BrowserRelay;
const HARRecorder = @import("../browser_har.zig").HARRecorder;

const c = @cImport({
    @cInclude("webkit/webkit.h");
});

const log = std.log.scoped(.browser_widget);

pub const BrowserWidget = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyBrowserWidget",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        // WebKit
        web_view: ?*c.WebKitWebView = null,

        // UI widgets
        url_entry: ?*gtk.Entry = null,
        back_button: ?*gtk.Button = null,
        forward_button: ?*gtk.Button = null,
        reload_button: ?*gtk.Button = null,
        progress_bar: ?*gtk.ProgressBar = null,
        proxy_indicator: ?*gtk.Image = null,
        console_box: ?*gtk.Box = null,
        console_output: ?*gtk.TextView = null,
        console_input: ?*gtk.Entry = null,
        inspector_active: bool = false,

        // Infrastructure
        socket_server: ?*BrowserSocket = null,
        proxy_relay: ?*BrowserRelay = null,
        har_recorder: ?*HARRecorder = null,

        // Config
        proxy_url: ?[]const u8 = null,
        proxy_cert_path: ?[]const u8 = null,
        tls_strict: bool = true,

        // Allocator for dynamic memory
        alloc: std.mem.Allocator = std.heap.c_allocator,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        self.as(gtk.Orientable).setOrientation(.vertical);
        widget.addCssClass("browser-pane");

        // -- Address Bar --
        const toolbar = gtk.Box.new(.horizontal, 4);
        toolbar.as(gtk.Widget).addCssClass("browser-toolbar");
        toolbar.as(gtk.Widget).setMarginStart(8);
        toolbar.as(gtk.Widget).setMarginEnd(8);
        toolbar.as(gtk.Widget).setMarginTop(4);
        toolbar.as(gtk.Widget).setMarginBottom(4);

        // Back button
        priv.back_button = gtk.Button.newFromIconName("go-previous-symbolic");
        priv.back_button.?.as(gtk.Widget).setSensitive(0);
        _ = gtk.Button.signals.clicked.connect(priv.back_button.?, *Self, &onBackClicked, self, .{});
        toolbar.append(priv.back_button.?.as(gtk.Widget));

        // Forward button
        priv.forward_button = gtk.Button.newFromIconName("go-next-symbolic");
        priv.forward_button.?.as(gtk.Widget).setSensitive(0);
        _ = gtk.Button.signals.clicked.connect(priv.forward_button.?, *Self, &onForwardClicked, self, .{});
        toolbar.append(priv.forward_button.?.as(gtk.Widget));

        // Reload button
        priv.reload_button = gtk.Button.newFromIconName("view-refresh-symbolic");
        _ = gtk.Button.signals.clicked.connect(priv.reload_button.?, *Self, &onReloadClicked, self, .{});
        toolbar.append(priv.reload_button.?.as(gtk.Widget));

        // URL entry
        priv.url_entry = @ptrCast(gtk.Entry.new());
        priv.url_entry.?.as(gtk.Widget).setHexpand(1);
        _ = gtk.Entry.signals.activate.connect(priv.url_entry.?, *Self, &onUrlActivated, self, .{});
        toolbar.append(priv.url_entry.?.as(gtk.Widget));

        // Proxy indicator (hidden by default)
        priv.proxy_indicator = @ptrCast(gtk.Image.newFromIconName("security-high-symbolic"));
        priv.proxy_indicator.?.as(gtk.Widget).setVisible(0);
        toolbar.append(priv.proxy_indicator.?.as(gtk.Widget));

        self.as(gtk.Box).append(toolbar.as(gtk.Widget));

        // -- Progress Bar --
        priv.progress_bar = @ptrCast(gtk.ProgressBar.new());
        priv.progress_bar.?.as(gtk.Widget).setVisible(0);
        self.as(gtk.Box).append(priv.progress_bar.?.as(gtk.Widget));

        // -- WebKitWebView --
        const web_view = c.webkit_web_view_new();
        priv.web_view = @ptrCast(web_view);

        // Register JS message handler for HAR interception
        const ucm = c.webkit_web_view_get_user_content_manager(priv.web_view.?);
        _ = c.webkit_user_content_manager_register_script_message_handler(ucm, "harLog", null);

        // Make the WebView expand to fill available space
        c.gtk_widget_set_vexpand(@ptrCast(web_view), 1);
        c.gtk_widget_set_hexpand(@ptrCast(web_view), 1);
        self.as(gtk.Box).append(@ptrCast(web_view));

        // -- JS Console (hidden by default) --
        priv.console_box = gtk.Box.new(.vertical, 0);
        priv.console_box.?.as(gtk.Widget).setVisible(0);
        priv.console_box.?.as(gtk.Widget).addCssClass("browser-console");

        // Console output
        priv.console_output = @ptrCast(gtk.TextView.new());
        priv.console_output.?.setEditable(0);
        priv.console_output.?.setMonospace(1);
        priv.console_output.?.setWrapMode(.word_char);

        const scroll = gtk.ScrolledWindow.new();
        scroll.setChild(priv.console_output.?.as(gtk.Widget));
        scroll.as(gtk.Widget).setSizeRequest(-1, 120);
        priv.console_box.?.append(scroll.as(gtk.Widget));

        // Console input
        const input_box = gtk.Box.new(.horizontal, 4);
        const prompt_label = gtk.Label.new(">");
        prompt_label.as(gtk.Widget).addCssClass("monospace");
        input_box.append(prompt_label.as(gtk.Widget));

        priv.console_input = @ptrCast(gtk.Entry.new());
        priv.console_input.?.as(gtk.Widget).setHexpand(1);
        _ = gtk.Entry.signals.activate.connect(priv.console_input.?, *Self, &onConsoleSubmit, self, .{});
        input_box.append(priv.console_input.?.as(gtk.Widget));

        priv.console_box.?.append(input_box.as(gtk.Widget));
        self.as(gtk.Box).append(priv.console_box.?.as(gtk.Widget));

        // -- Start infrastructure --
        self.startInfrastructure();

        log.info("browser widget initialized", .{});
    }

    fn startInfrastructure(self: *Self) void {
        const priv = self.private();
        const alloc = priv.alloc;

        // HAR recorder
        const har = alloc.create(HARRecorder) catch return;
        har.* = HARRecorder.init(alloc);
        priv.har_recorder = har;

        // Proxy relay
        const relay = alloc.create(BrowserRelay) catch return;
        relay.* = BrowserRelay.init(alloc);
        relay.har_recorder = har;
        relay.start() catch |err| {
            log.warn("proxy relay failed to start: {}", .{err});
        };
        priv.proxy_relay = relay;

        // Socket server
        var pane_id: [8]u8 = undefined;
        std.crypto.random.bytes(&pane_id);
        // Convert to hex for path
        var hex_id: [8]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (pane_id[0..4], 0..) |byte, i| {
            hex_id[i * 2] = hex_chars[byte >> 4];
            hex_id[i * 2 + 1] = hex_chars[byte & 0xf];
        }

        const sock = alloc.create(BrowserSocket) catch return;
        sock.* = BrowserSocket.init(alloc, hex_id, &handleSocketCommand, @ptrCast(self)) catch return;
        sock.start() catch |err| {
            log.warn("socket server failed to start: {}", .{err});
        };
        priv.socket_server = sock;

        // Apply proxy config
        if (priv.proxy_url) |proxy| {
            self.applyProxyConfig(proxy);
        }
    }

    // MARK: - Button Handlers

    fn onBackClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.web_view) |wv| c.webkit_web_view_go_back(wv);
    }

    fn onForwardClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.web_view) |wv| c.webkit_web_view_go_forward(wv);
    }

    fn onReloadClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.web_view) |wv| c.webkit_web_view_reload(wv);
    }

    fn onUrlActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.navigateToEntry();
    }

    fn onConsoleSubmit(_: *gtk.Entry, self: *Self) callconv(.c) void {
        const priv = self.private();
        const entry = priv.console_input orelse return;
        const buf = entry.as(gtk.Editable).getText();
        const code: []const u8 = std.mem.span(buf);
        if (code.len == 0) return;

        self.appendConsoleOutput("> ");
        self.appendConsoleOutput(code);
        self.appendConsoleOutput("\n");

        self.evaluateJS(code);
        entry.as(gtk.Editable).deleteText(0, -1);
    }

    // MARK: - Navigation

    pub fn navigate(self: *Self, url: []const u8) void {
        const priv = self.private();
        const wv = priv.web_view orelse return;

        // Auto-prepend https://
        var buf: [4096]u8 = undefined;
        const normalized = if (std.mem.indexOf(u8, url, "://") == null)
            std.fmt.bufPrintZ(&buf, "https://{s}", .{url}) catch return
        else
            std.fmt.bufPrintZ(&buf, "{s}", .{url}) catch return;

        c.webkit_web_view_load_uri(wv, normalized.ptr);

        // Update URL entry
        if (priv.url_entry) |entry| {
            entry.as(gtk.Editable).setText(@ptrCast(normalized.ptr));
        }
    }

    fn navigateToEntry(self: *Self) void {
        const priv = self.private();
        const entry = priv.url_entry orelse return;
        const buf = entry.as(gtk.Editable).getText();
        const url: []const u8 = std.mem.span(buf);
        if (url.len > 0) self.navigate(url);
    }

    // MARK: - JavaScript Evaluation

    pub fn evaluateJS(self: *Self, code: []const u8) void {
        const priv = self.private();
        const wv = priv.web_view orelse return;
        // Null-terminate the code for C API
        var buf: [65536]u8 = undefined;
        const code_z = std.fmt.bufPrintZ(&buf, "{s}", .{code}) catch return;
        c.webkit_web_view_evaluate_javascript(
            wv,
            code_z.ptr,
            @intCast(code_z.len),
            null, // world
            null, // source_uri
            null, // cancellable
            null, // callback (fire-and-forget for console)
            null, // user_data
        );
    }

    // MARK: - Inspector

    pub fn toggleInspector(self: *Self) void {
        const priv = self.private();
        priv.inspector_active = !priv.inspector_active;
        if (priv.inspector_active) {
            self.evaluateJS(@embedFile("../../../inspector_overlay.js"));
        } else {
            self.evaluateJS(
                \\(function(){
                \\  document.getElementById('__trident-inspector-overlay')?.remove();
                \\  document.getElementById('__trident-inspector-label')?.remove();
                \\  window.__tridentInspector = false;
                \\})();
            );
        }
    }

    // MARK: - Console Output

    fn appendConsoleOutput(self: *Self, text: []const u8) void {
        const priv = self.private();
        const tv = priv.console_output orelse return;
        const buffer = tv.getBuffer();
        var end_iter: c.GtkTextIter = undefined;
        buffer.getEndIter(&end_iter);
        buffer.insert(&end_iter, @ptrCast(text.ptr), @intCast(text.len));
    }

    pub fn toggleConsole(self: *Self) void {
        const priv = self.private();
        if (priv.console_box) |box| {
            const visible = box.as(gtk.Widget).getVisible();
            box.as(gtk.Widget).setVisible(if (visible != 0) 0 else 1);
        }
    }

    // MARK: - Proxy Config

    fn applyProxyConfig(self: *Self, proxy_url: []const u8) void {
        const priv = self.private();
        const wv = priv.web_view orelse return;
        _ = proxy_url;

        // Get network session and apply proxy settings
        const session = c.webkit_web_view_get_network_session(wv);
        if (session != null) {
            var buf: [1024]u8 = undefined;
            const url_z = std.fmt.bufPrintZ(&buf, "{s}", .{proxy_url}) catch return;
            const proxy_settings = c.webkit_network_proxy_settings_new(url_z.ptr, null);
            c.webkit_network_session_set_proxy_settings(
                session,
                c.WEBKIT_NETWORK_PROXY_MODE_CUSTOM,
                proxy_settings,
            );
        }

        // Show proxy indicator
        if (priv.proxy_indicator) |img| {
            img.as(gtk.Widget).setVisible(1);
        }
    }

    pub fn setProxy(self: *Self, proxy_url: ?[]const u8) void {
        const priv = self.private();
        priv.proxy_url = proxy_url;
        if (priv.proxy_relay) |relay| relay.upstream_proxy = proxy_url;

        if (proxy_url) |url| {
            self.applyProxyConfig(url);
        } else {
            // Clear proxy
            const wv = priv.web_view orelse return;
            const session = c.webkit_web_view_get_network_session(wv);
            if (session != null) {
                c.webkit_network_session_set_proxy_settings(
                    session,
                    c.WEBKIT_NETWORK_PROXY_MODE_DEFAULT,
                    null,
                );
            }
            if (priv.proxy_indicator) |img| {
                img.as(gtk.Widget).setVisible(0);
            }
        }
    }

    // MARK: - Socket Command Handler

    fn handleSocketCommand(cmd: []const u8, json: []const u8, ctx: *anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Commands are dispatched on the socket thread.
        // For WebKit calls, we need to dispatch to the GTK main thread.
        // For now, we handle simple commands inline and complex ones via idle.
        _ = json;

        if (std.mem.eql(u8, cmd, "status")) {
            return std.fmt.allocPrint(self.private().alloc,
                \\{{"ok":true,"url":"","title":"","loading":false}}
            , .{}) catch return "{\"ok\":false}";
        }

        // Default: unknown command
        return std.fmt.allocPrint(self.private().alloc,
            \\{{"ok":false,"error":"unknown command: {s}"}}
        , .{cmd}) catch return "{\"ok\":false}";
    }

    // MARK: - Cleanup

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.socket_server) |sock| {
            sock.stop();
            priv.alloc.destroy(sock);
            priv.socket_server = null;
        }

        if (priv.proxy_relay) |relay| {
            relay.stop();
            priv.alloc.destroy(relay);
            priv.proxy_relay = null;
        }

        if (priv.har_recorder) |har| {
            har.deinit();
            priv.alloc.destroy(har);
            priv.har_recorder = null;
        }

        const parent_dispose = gobject.ext.as(
            gobject.Object.Class.VTable,
            Class.parent,
        ).dispose;
        if (parent_dispose) |f| f(self.as(gobject.Object));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;
};
```

- [ ] **Step 3: Create the inspector overlay JS file**

Create `src/apprt/gtk/inspector_overlay.js` (embedded at compile time via `@embedFile`):

```javascript
(function() {
    if (window.__tridentInspector) { return; }
    window.__tridentInspector = true;

    const overlay = document.createElement('div');
    overlay.id = '__trident-inspector-overlay';
    overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff6b35;background:rgba(255,107,53,0.1);display:none;transition:all 0.05s ease;';
    document.body.appendChild(overlay);

    const label = document.createElement('div');
    label.id = '__trident-inspector-label';
    label.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;background:#1a1a2e;color:#e0e0e0;font:11px/1.4 monospace;padding:4px 8px;border-radius:4px;display:none;max-width:400px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';
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
        if (el.className && typeof el.className === 'string') info += '.' + el.className.trim().split(/\s+/).join('.');
        info += ' (' + Math.round(rect.width) + 'x' + Math.round(rect.height) + ')';
        label.textContent = info;
        label.style.left = Math.min(rect.left, window.innerWidth - 300) + 'px';
        label.style.top = Math.max(0, rect.top - 24) + 'px';
        label.style.display = 'block';
    }, true);
})();
```

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/browser_widget.zig src/apprt/gtk/class.zig src/apprt/gtk/inspector_overlay.js
git commit -m "feat(gtk): add BrowserWidget GObject class with WebKitGTK"
```

---

## Task 6: Split Tree Integration & Action Dispatch

**Files:**
- Modify: `src/apprt/gtk/class/split_tree.zig`
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add browser_widget field to SplitTree Private**

In `src/apprt/gtk/class/split_tree.zig`, add to the `Private` struct (around line 230, after `pane_tab_groups`):

```zig
/// The browser widget shown beside terminal panes, if any.
browser_widget: ?*BrowserWidget = null,
browser_paned: ?*gtk.Paned = null,
```

Also add the import at the top of the file:

```zig
const BrowserWidget = @import("../class.zig").BrowserWidget;
```

- [ ] **Step 2: Add toggleBrowser method to SplitTree**

Add this method to the `SplitTree` extern struct (after existing public methods):

```zig
pub fn toggleBrowser(self: *Self) void {
    if (@TypeOf(BrowserWidget) == void) return; // Browser not compiled in

    const priv = self.private();

    if (priv.browser_widget) |browser| {
        // Remove browser pane
        if (priv.browser_paned) |paned| {
            // Get the terminal side (start child)
            const terminal_widget = paned.getStartChild() orelse return;
            terminal_widget.ref();

            // Remove paned from tree_bin, put terminal back
            paned.setStartChild(null);
            paned.setEndChild(null);
            priv.tree_bin.setChild(terminal_widget);
            terminal_widget.unref();
        }

        browser.as(gobject.Object).unref();
        priv.browser_widget = null;
        priv.browser_paned = null;
    } else {
        // Create browser pane
        const browser = gobject.ext.newInstance(BrowserWidget, .{});
        priv.browser_widget = browser;

        // Get current content from tree_bin
        const current = priv.tree_bin.as(adw.Bin).getChild() orelse return;
        current.ref();
        priv.tree_bin.setChild(null);

        // Create paned: terminal on left, browser on right
        const paned = gtk.Paned.new(.horizontal);
        paned.setStartChild(current);
        paned.setEndChild(browser.as(gtk.Widget));
        paned.setPosition(400); // Initial split position
        priv.browser_paned = paned;

        priv.tree_bin.setChild(paned.as(gtk.Widget));
        current.unref();
    }
}
```

- [ ] **Step 3: Handle toggle_browser in application.zig performAction**

In `src/apprt/gtk/class/application.zig`, find the `performAction` switch statement. After the `.toggle_fullscreen` case (around line 773), add:

```zig
.toggle_browser => {
    const surface = Action.targetSurface(self, target) orelse return false;
    const split_tree = surface.as(gtk.Widget).getAncestor(SplitTree.getGObjectType());
    if (split_tree) |st| {
        @as(*SplitTree, @ptrCast(@alignCast(st))).toggleBrowser();
        return true;
    }
    return false;
},
```

Also add the import at the top if not already present:

```zig
const SplitTree = @import("split_tree.zig").SplitTree;
```

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/split_tree.zig src/apprt/gtk/class/application.zig
git commit -m "feat(gtk): wire toggle_browser action to split tree"
```

---

## Task 7: Build Verification on Linux

**Files:** None (verification only)

- [ ] **Step 1: Install webkitgtk-6.0 dev package**

On Ubuntu/Debian:
```bash
sudo apt install libwebkitgtk-6.0-dev
```

On Fedora:
```bash
sudo dnf install webkitgtk6.0-devel
```

- [ ] **Step 2: Build with browser enabled**

```bash
zig build -Denable-browser=true 2>&1 | head -50
```

Expected: Compiles without errors. If there are `@cImport` issues with `webkit/webkit.h`, verify the include path is correct (may need `webkit2gtk-6.0` instead of `webkit` depending on the distro's pkg-config).

- [ ] **Step 3: Build without browser (regression check)**

```bash
zig build 2>&1 | head -20
```

Expected: Clean build with no WebKitGTK references.

- [ ] **Step 4: Run and test toggle**

```bash
zig build run -Denable-browser=true
```

Then press the `toggle_browser` keybind. Expected: A split pane appears with the browser widget (address bar, empty WebView, buttons).

- [ ] **Step 5: Test socket API**

```bash
SOCK=$(ls /tmp/trident/b-*.sock | head -1)
echo '{"cmd":"navigate","url":"https://example.com"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"status"}' | socat - UNIX-CONNECT:$SOCK
```

Expected: Browser navigates; status returns URL and title.

---

## Task 8: Complete Socket Command Handlers

**Files:**
- Modify: `src/apprt/gtk/class/browser_widget.zig`

The `handleSocketCommand` function in Task 5 is a stub. This task fills in all 17 commands.

- [ ] **Step 1: Implement navigation commands (navigate, back, forward, reload, status)**

Replace the `handleSocketCommand` function body with a full dispatch. Each WebKit-touching command must use `glib.idleAdd()` to dispatch to the GTK main thread and a mutex/condition to wait for the result.

Add a helper struct for main-thread dispatch:

```zig
const MainThreadDispatch = struct {
    result: ?[]const u8 = null,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    widget: *Self,
    cmd: []const u8,
    json: []const u8,

    fn idleCallback(user_data: ?*anyopaque) callconv(.c) c_int {
        const dispatch: *MainThreadDispatch = @ptrCast(@alignCast(user_data.?));
        dispatch.result = dispatch.widget.executeCommand(dispatch.cmd, dispatch.json);
        dispatch.mutex.lock();
        dispatch.done = true;
        dispatch.cond.signal();
        dispatch.mutex.unlock();
        return 0; // G_SOURCE_REMOVE
    }
};
```

Then update `handleSocketCommand` to use it:

```zig
fn handleSocketCommand(cmd: []const u8, json: []const u8, ctx: *anyopaque) []const u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    var dispatch = MainThreadDispatch{
        .widget = self,
        .cmd = cmd,
        .json = json,
    };
    _ = glib.idleAdd(&MainThreadDispatch.idleCallback, @ptrCast(&dispatch));

    dispatch.mutex.lock();
    while (!dispatch.done) dispatch.cond.wait(&dispatch.mutex);
    dispatch.mutex.unlock();

    return dispatch.result orelse "{\"ok\":false}";
}
```

Add `executeCommand` that runs on the GTK main thread:

```zig
fn executeCommand(self: *Self, cmd: []const u8, json: []const u8) []const u8 {
    const priv = self.private();
    const alloc = priv.alloc;

    if (std.mem.eql(u8, cmd, "navigate")) {
        const url = extractStringField(json, "url") orelse
            return allocResponse(alloc, false, "missing 'url' parameter");
        self.navigate(url);
        return allocResponse(alloc, true, null);
    }
    if (std.mem.eql(u8, cmd, "back")) {
        if (priv.web_view) |wv| c.webkit_web_view_go_back(wv);
        return allocResponse(alloc, true, null);
    }
    if (std.mem.eql(u8, cmd, "forward")) {
        if (priv.web_view) |wv| c.webkit_web_view_go_forward(wv);
        return allocResponse(alloc, true, null);
    }
    if (std.mem.eql(u8, cmd, "reload")) {
        if (priv.web_view) |wv| c.webkit_web_view_reload(wv);
        return allocResponse(alloc, true, null);
    }
    if (std.mem.eql(u8, cmd, "status")) {
        const wv = priv.web_view orelse return allocResponse(alloc, true, null);
        const uri = c.webkit_web_view_get_uri(wv);
        const title = c.webkit_web_view_get_title(wv);
        const loading = c.webkit_web_view_is_loading(wv);
        return std.fmt.allocPrint(alloc,
            \\{{"ok":true,"url":"{s}","title":"{s}","loading":{s}}}
        , .{
            if (uri != null) std.mem.span(uri) else "",
            if (title != null) std.mem.span(title) else "",
            if (loading != 0) "true" else "false",
        }) catch return "{\"ok\":false}";
    }

    // ... remaining commands follow the same pattern ...

    if (std.mem.eql(u8, cmd, "proxy_set")) {
        const url = extractStringField(json, "url");
        self.setProxy(url);
        return allocResponse(alloc, true, null);
    }
    if (std.mem.eql(u8, cmd, "har_start")) {
        if (priv.har_recorder) |hr| hr.start();
        return allocResponse(alloc, true, null);
    }
    if (std.mem.eql(u8, cmd, "har_stop")) {
        if (priv.har_recorder) |hr| {
            hr.stop();
            return std.fmt.allocPrint(alloc,
                \\{{"ok":true,"entry_count":{d}}}
            , .{hr.entryCount()}) catch return "{\"ok\":false}";
        }
        return allocResponse(alloc, true, null);
    }
    if (std.mem.eql(u8, cmd, "har_export")) {
        if (priv.har_recorder) |hr| {
            const har_json = hr.exportJSON(alloc) catch return allocResponse(alloc, false, "export failed");
            defer alloc.free(har_json);
            return std.fmt.allocPrint(alloc,
                \\{{"ok":true,"har":{s}}}
            , .{har_json}) catch return "{\"ok\":false}";
        }
        return allocResponse(alloc, true, null);
    }

    return std.fmt.allocPrint(alloc,
        \\{{"ok":false,"error":"unknown command: {s}"}}
    , .{cmd}) catch return "{\"ok\":false}";
}

fn allocResponse(alloc: std.mem.Allocator, ok: bool, err_msg: ?[]const u8) []const u8 {
    if (err_msg) |msg| {
        return std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch return "{\"ok\":false}";
    }
    return if (ok) alloc.dupe(u8, "{\"ok\":true}") catch return "{\"ok\":true}" else alloc.dupe(u8, "{\"ok\":false}") catch return "{\"ok\":false}";
}

fn extractStringField(json: []const u8, field: []const u8) ?[]const u8 {
    // Find "field":"value" pattern
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "\"{s}\"", .{field}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
    if (i >= after_key.len) return null;
    return after_key[start..i];
}
```

- [ ] **Step 2: Implement remaining commands (js_eval, dom_snapshot, screenshot, cookies, session, cert_info)**

These follow the same pattern but use WebKitGTK async APIs. For `js_eval` and `dom_snapshot`, use `webkit_web_view_evaluate_javascript()` with a GAsyncReadyCallback. For `screenshot`, use `webkit_web_view_get_snapshot()`. For cookies, use `webkit_cookie_manager_get_cookies()`.

Each async command uses a local mutex/condition pair to block the socket thread until the GTK callback fires.

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/class/browser_widget.zig
git commit -m "feat(gtk): implement all 17 browser socket commands"
```

---

## Task 9: TLS Configuration

**Files:**
- Modify: `src/apprt/gtk/class/browser_widget.zig`

- [ ] **Step 1: Apply TLS config on widget init**

In the `startInfrastructure` function, after proxy config, add TLS handling:

```zig
// TLS configuration
if (!priv.tls_strict) {
    const wv = priv.web_view orelse return;
    const session = c.webkit_web_view_get_network_session(wv);
    if (session != null) {
        c.webkit_network_session_set_tls_errors_policy(
            session,
            c.WEBKIT_TLS_ERRORS_POLICY_IGNORE,
        );
    }
    log.warn("TLS validation disabled for browser pane", .{});
}
```

- [ ] **Step 2: Commit**

```bash
git add src/apprt/gtk/class/browser_widget.zig
git commit -m "feat(gtk): apply TLS config (strict/ignore) to browser pane"
```

---

## Task 10: Config Bridging

**Files:**
- Modify: `src/apprt/gtk/class/browser_widget.zig`
- Modify: `src/apprt/gtk/class/split_tree.zig`

- [ ] **Step 1: Pass config to BrowserWidget on creation**

Add a `configure` method to `BrowserWidget`:

```zig
pub fn configure(self: *Self, config: anytype) void {
    const priv = self.private();
    priv.proxy_url = config.browserProxy();
    priv.proxy_cert_path = config.browserProxyCert();
    priv.tls_strict = config.browserTlsStrict();
}
```

In `SplitTree.toggleBrowser()`, after creating the browser widget, call configure with the surface's config before `startInfrastructure` runs. This requires reordering init to defer infrastructure startup until after configure.

- [ ] **Step 2: Commit**

```bash
git add src/apprt/gtk/class/browser_widget.zig src/apprt/gtk/class/split_tree.zig
git commit -m "feat(gtk): bridge browser config from Zig config to widget"
```

---

## Task 11: Final Integration Test

**Files:** None (verification only)

- [ ] **Step 1: Full build + run**

```bash
zig build -Denable-browser=true && zig build run -Denable-browser=true
```

- [ ] **Step 2: Test all socket commands**

```bash
SOCK=$(ls /tmp/trident/b-*.sock | head -1)

# Navigation
echo '{"cmd":"navigate","url":"https://example.com"}' | socat - UNIX-CONNECT:$SOCK
sleep 2
echo '{"cmd":"status"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"back"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"forward"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"reload"}' | socat - UNIX-CONNECT:$SOCK

# JavaScript
echo '{"cmd":"js_eval","code":"document.title"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"dom_snapshot"}' | socat - UNIX-CONNECT:$SOCK

# Screenshot
echo '{"cmd":"screenshot"}' | socat - UNIX-CONNECT:$SOCK | python3 -c "import sys,json,base64; d=json.load(sys.stdin); open('/tmp/shot.png','wb').write(base64.b64decode(d['png_b64']))"

# Cookies
echo '{"cmd":"cookies_get"}' | socat - UNIX-CONNECT:$SOCK

# Certificate
echo '{"cmd":"cert_info"}' | socat - UNIX-CONNECT:$SOCK

# HAR
echo '{"cmd":"har_start"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"navigate","url":"https://example.com"}' | socat - UNIX-CONNECT:$SOCK
sleep 2
echo '{"cmd":"har_stop"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"har_export"}' | socat - UNIX-CONNECT:$SOCK | python3 -m json.tool

# Proxy
echo '{"cmd":"proxy_set","url":"http://127.0.0.1:8080"}' | socat - UNIX-CONNECT:$SOCK
echo '{"cmd":"proxy_set","url":null}' | socat - UNIX-CONNECT:$SOCK
```

- [ ] **Step 3: Verify cleanup**

Toggle browser on, then off. Verify:
- Socket file is removed from `/tmp/trident/`
- No zombie threads
- No WebKit process orphans

- [ ] **Step 4: Commit any fixes from testing**

```bash
git add -A
git commit -m "fix(gtk): integration test fixes for browser pane"
```
