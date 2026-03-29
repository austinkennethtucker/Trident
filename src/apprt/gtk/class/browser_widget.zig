const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const glib = @import("glib");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const BrowserSocket = @import("../browser_socket.zig").BrowserSocket;
const BrowserRelay = @import("../browser_relay.zig").BrowserRelay;
const HARRecorder = @import("../browser_har.zig").HARRecorder;

const c = @cImport({
    @cInclude("webkit/webkit.h");
});

const log = std.log.scoped(.gtk_browser_widget);

/// The inspector overlay JavaScript, embedded at comptime from the sibling
/// JS file. Injected into web pages to highlight DOM elements on hover.
const inspector_js = @embedFile("../inspector_overlay.js");

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
        // WebKit web view — stored as opaque pointer because it comes from
        // a C library (WebKitGTK) via @cImport.
        web_view: ?*anyopaque = null,

        // --- UI widgets (address bar, progress, console) ---
        url_entry: ?*gtk.Entry = null,
        back_button: ?*gtk.Button = null,
        forward_button: ?*gtk.Button = null,
        reload_button: ?*gtk.Button = null,
        progress_bar: ?*gtk.ProgressBar = null,
        proxy_indicator: ?*gtk.Image = null,
        console_box: ?*gtk.Box = null,
        console_output: ?*gtk.TextView = null,
        console_input: ?*gtk.Entry = null,

        // --- State ---
        inspector_active: bool = false,

        // --- Infrastructure (socket server, relay proxy, HAR recorder) ---
        socket_server: ?*BrowserSocket = null,
        proxy_relay: ?*BrowserRelay = null,
        har_recorder: ?*HARRecorder = null,

        // --- Config ---
        proxy_url: ?[*:0]const u8 = null,
        proxy_cert_path: ?[*:0]const u8 = null,
        tls_strict: bool = true,

        alloc: Allocator = std.heap.c_allocator,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    // -----------------------------------------------------------------------
    // GObject lifecycle
    // -----------------------------------------------------------------------

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const widget = self.as(gtk.Widget);
        self.as(gtk.Orientable).setOrientation(.vertical);
        widget.addCssClass("browser-pane");

        const priv = self.private();

        // -- Address bar (horizontal box) --
        const toolbar = gtk.Box.new(.horizontal, 4);
        toolbar.as(gtk.Widget).addCssClass("toolbar");
        toolbar.as(gtk.Widget).addCssClass("browser-toolbar");

        // Navigation buttons
        const back_btn = gtk.Button.new();
        back_btn.setLabel("\u{25c0}"); // left-pointing triangle
        back_btn.as(gtk.Widget).setTooltipText("Back");
        priv.back_button = back_btn;

        const fwd_btn = gtk.Button.new();
        fwd_btn.setLabel("\u{25b6}"); // right-pointing triangle
        fwd_btn.as(gtk.Widget).setTooltipText("Forward");
        priv.forward_button = fwd_btn;

        const reload_btn = gtk.Button.new();
        reload_btn.setLabel("\u{21bb}"); // clockwise arrow
        reload_btn.as(gtk.Widget).setTooltipText("Reload");
        priv.reload_button = reload_btn;

        // URL entry
        const url_entry = gtk.Entry.new();
        url_entry.as(gtk.Widget).setHexpand(1);
        url_entry.setPlaceholderText("Enter URL...");
        priv.url_entry = url_entry;

        // Proxy indicator (hidden by default)
        const proxy_icon = gtk.Image.newFromIconName("network-transmit-symbolic");
        proxy_icon.as(gtk.Widget).setVisible(0);
        proxy_icon.as(gtk.Widget).setTooltipText("Proxy active");
        priv.proxy_indicator = proxy_icon;

        toolbar.append(back_btn.as(gtk.Widget));
        toolbar.append(fwd_btn.as(gtk.Widget));
        toolbar.append(reload_btn.as(gtk.Widget));
        toolbar.append(url_entry.as(gtk.Widget));
        toolbar.append(proxy_icon.as(gtk.Widget));
        self.as(gtk.Box).append(toolbar.as(gtk.Widget));

        // -- Progress bar (hidden until loading) --
        const progress = gtk.ProgressBar.new();
        progress.as(gtk.Widget).setVisible(0);
        priv.progress_bar = progress;
        self.as(gtk.Box).append(progress.as(gtk.Widget));

        // -- WebKitWebView --
        const raw_wv = c.webkit_web_view_new();
        if (raw_wv) |wv| {
            c.gtk_widget_set_vexpand(wv, 1);
            c.gtk_widget_set_hexpand(wv, 1);
            priv.web_view = wv;
            // Append as a GTK widget via the C API; we cast to our Zig
            // gtk.Widget so we can use the Zig append method.
            const gtk_wv: *gtk.Widget = @ptrCast(@alignCast(wv));
            self.as(gtk.Box).append(gtk_wv);
        } else {
            log.err("webkit_web_view_new() returned null", .{});
        }

        // -- JS console panel (hidden by default) --
        const console_box = gtk.Box.new(.vertical, 2);
        console_box.as(gtk.Widget).setVisible(0);
        console_box.as(gtk.Widget).addCssClass("browser-console");

        const console_scroll = gtk.ScrolledWindow.new();
        console_scroll.as(gtk.Widget).setVexpand(1);
        console_scroll.setMinContentHeight(120);

        const console_output = gtk.TextView.new();
        console_output.setEditable(0);
        console_output.setCursorVisible(0);
        console_output.as(gtk.Widget).addCssClass("monospace");
        console_scroll.setChild(console_output.as(gtk.Widget));
        console_box.append(console_scroll.as(gtk.Widget));

        const console_input = gtk.Entry.new();
        console_input.setPlaceholderText("JavaScript...");
        console_box.append(console_input.as(gtk.Widget));

        priv.console_output = console_output;
        priv.console_input = console_input;
        priv.console_box = console_box;
        self.as(gtk.Box).append(console_box.as(gtk.Widget));

        // -- Signal connections --
        _ = gtk.Button.signals.clicked.connect(back_btn, *Self, &onBackClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(fwd_btn, *Self, &onForwardClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(reload_btn, *Self, &onReloadClicked, self, .{});
        _ = gtk.Entry.signals.activate.connect(url_entry, *Self, &onUrlActivated, self, .{});
        _ = gtk.Entry.signals.activate.connect(console_input, *Self, &onConsoleSubmit, self, .{});

        // -- Start background infrastructure --
        self.startInfrastructure();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Tear down infrastructure in reverse order.
        if (priv.socket_server) |srv| {
            srv.stop();
            priv.alloc.destroy(srv);
            priv.socket_server = null;
        }
        if (priv.proxy_relay) |relay| {
            relay.stop();
            priv.alloc.destroy(relay);
            priv.proxy_relay = null;
        }
        if (priv.har_recorder) |rec| {
            rec.deinit();
            priv.alloc.destroy(rec);
            priv.har_recorder = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    // -----------------------------------------------------------------------
    // Button / entry signal handlers
    // -----------------------------------------------------------------------

    fn onBackClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.web_view) |wv| c.webkit_web_view_go_back(@ptrCast(wv));
    }

    fn onForwardClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.web_view) |wv| c.webkit_web_view_go_forward(@ptrCast(wv));
    }

    fn onReloadClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.web_view) |wv| c.webkit_web_view_reload(@ptrCast(wv));
    }

    fn onUrlActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.url_entry) |entry| {
            const text = entry.as(gtk.Editable).getText();
            self.navigate(std.mem.span(text));
        }
    }

    fn onConsoleSubmit(_: *gtk.Entry, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.console_input) |entry| {
            const text = entry.as(gtk.Editable).getText();
            const code = std.mem.span(text);
            if (code.len == 0) return;

            // Echo the input to the console output.
            var buf: [512]u8 = undefined;
            const echo = std.fmt.bufPrint(&buf, "> {s}\n", .{code}) catch return;
            self.appendConsoleOutput(echo);

            // Evaluate the JS.
            self.evaluateJS(code);

            // Clear input.
            entry.as(gtk.Editable).setText("");
        }
    }

    // -----------------------------------------------------------------------
    // Public methods
    // -----------------------------------------------------------------------

    /// Navigate to the given URL. If the URL does not contain "://", the
    /// widget auto-prepends "https://".
    pub fn navigate(self: *Self, url: []const u8) void {
        const priv = self.private();
        const wv = priv.web_view orelse return;

        // Build a null-terminated URL, prepending https:// if needed.
        var buf: [4096]u8 = undefined;
        const full_url = if (std.mem.indexOf(u8, url, "://") != null)
            std.fmt.bufPrintZ(&buf, "{s}", .{url}) catch return
        else
            std.fmt.bufPrintZ(&buf, "https://{s}", .{url}) catch return;

        c.webkit_web_view_load_uri(@ptrCast(wv), full_url.ptr);

        // Update the URL entry to reflect where we're actually going.
        if (priv.url_entry) |entry| {
            entry.as(gtk.Editable).setText(full_url.ptr);
        }
    }

    /// Evaluate arbitrary JavaScript in the web view's page context.
    pub fn evaluateJS(self: *Self, code: []const u8) void {
        const priv = self.private();
        const wv = priv.web_view orelse return;

        // webkit_web_view_evaluate_javascript needs a null-terminated string.
        var buf: [8192]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{code}) catch return;

        c.webkit_web_view_evaluate_javascript(
            @ptrCast(wv),
            z.ptr,
            @intCast(z.len),
            null, // world
            null, // source_uri
            null, // cancellable
            null, // callback
            null, // user_data
        );
    }

    /// Toggle the DOM inspector overlay. Injects the overlay JS on first
    /// activation; removes the overlay elements on deactivation.
    pub fn toggleInspector(self: *Self) void {
        const priv = self.private();
        priv.inspector_active = !priv.inspector_active;

        if (priv.inspector_active) {
            self.evaluateJS(inspector_js);
        } else {
            self.evaluateJS(
                \\(function() {
                \\    var o = document.getElementById('__trident-inspector-overlay');
                \\    var l = document.getElementById('__trident-inspector-label');
                \\    if (o) o.remove();
                \\    if (l) l.remove();
                \\    window.__tridentInspector = false;
                \\})();
            );
        }
    }

    /// Set proxy and TLS config before the widget starts rendering.
    /// Must be called before the widget is realized (i.e. right after creation).
    pub fn configure(self: *Self, proxy_url: ?[*:0]const u8, proxy_cert_path: ?[*:0]const u8, tls_strict: bool) void {
        const priv = self.private();
        priv.proxy_url = proxy_url;
        priv.proxy_cert_path = proxy_cert_path;
        priv.tls_strict = tls_strict;
    }

    /// Show or hide the JS console panel at the bottom of the widget.
    pub fn toggleConsole(self: *Self) void {
        const priv = self.private();
        if (priv.console_box) |box| {
            const vis = box.as(gtk.Widget).getVisible();
            box.as(gtk.Widget).setVisible(if (vis != 0) 0 else 1);
        }
    }

    /// Configure the proxy used by WebKit's network session.
    /// Pass `null` to clear the proxy and use direct connections.
    pub fn setProxy(self: *Self, url: ?[]const u8) void {
        const priv = self.private();
        const wv = priv.web_view orelse return;

        const session = c.webkit_web_view_get_network_session(@ptrCast(wv));
        if (session == null) return;

        if (url) |u| {
            var buf: [1024]u8 = undefined;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{u}) catch return;
            const settings = c.webkit_network_proxy_settings_new(z.ptr, null);
            c.webkit_network_session_set_proxy_settings(
                session,
                c.WEBKIT_NETWORK_PROXY_MODE_CUSTOM,
                settings,
            );
            if (priv.proxy_indicator) |icon| icon.as(gtk.Widget).setVisible(1);
        } else {
            c.webkit_network_session_set_proxy_settings(
                session,
                c.WEBKIT_NETWORK_PROXY_MODE_DEFAULT,
                null,
            );
            if (priv.proxy_indicator) |icon| icon.as(gtk.Widget).setVisible(0);
        }
    }

    /// Append a line of text to the JS console output panel.
    pub fn appendConsoleOutput(self: *Self, text: []const u8) void {
        const priv = self.private();
        const tv = priv.console_output orelse return;
        const buffer = tv.getBuffer();
        var end_iter: gtk.TextIter = undefined;
        buffer.getEndIter(&end_iter);
        buffer.insert(&end_iter, text.ptr, @intCast(text.len));
    }

    // -----------------------------------------------------------------------
    // Infrastructure (socket server, relay, HAR recorder)
    // -----------------------------------------------------------------------

    fn startInfrastructure(self: *Self) void {
        const priv = self.private();
        const alloc = priv.alloc;

        // HAR recorder
        const rec = alloc.create(HARRecorder) catch {
            log.err("failed to allocate HARRecorder", .{});
            return;
        };
        rec.* = HARRecorder.init(alloc);
        priv.har_recorder = rec;

        // Proxy relay
        const relay = alloc.create(BrowserRelay) catch {
            log.err("failed to allocate BrowserRelay", .{});
            return;
        };
        relay.* = BrowserRelay.init(alloc);
        relay.har_recorder = rec;
        relay.start() catch |err| {
            log.err("failed to start BrowserRelay: {}", .{err});
        };
        priv.proxy_relay = relay;

        // Unix socket server for external control
        const pane_id = generatePaneId();
        const srv = alloc.create(BrowserSocket) catch {
            log.err("failed to allocate BrowserSocket", .{});
            return;
        };
        srv.* = BrowserSocket.init(alloc, pane_id, &handleSocketCommand, @ptrCast(self)) catch |err| {
            log.err("failed to init BrowserSocket: {}", .{err});
            alloc.destroy(srv);
            return;
        };
        srv.start() catch |err| {
            log.err("failed to start BrowserSocket: {}", .{err});
        };
        priv.socket_server = srv;

        // TLS configuration
        if (!priv.tls_strict) {
            if (priv.web_view) |wv| {
                const session = c.webkit_web_view_get_network_session(@ptrCast(wv));
                if (session != null) {
                    c.webkit_network_session_set_tls_errors_policy(session, 1); // WEBKIT_TLS_ERRORS_POLICY_IGNORE = 1
                }
            }
            log.warn("TLS validation disabled for browser pane", .{});
        }
    }

    /// Generate a random 8-byte hex pane identifier.
    fn generatePaneId() [8]u8 {
        var id: [8]u8 = undefined;
        const hex = "0123456789abcdef";
        var rng_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&rng_bytes);
        for (rng_bytes, 0..) |b, i| {
            id[i * 2] = hex[b >> 4];
            id[i * 2 + 1] = hex[b & 0x0f];
        }
        return id;
    }

    /// Socket command dispatcher. Called from the BrowserSocket accept loop
    /// thread. For commands that must run on the GTK main thread (navigate,
    /// back, forward, reload, js_eval, etc.) we use glib.idleAdd to schedule
    /// them. Async commands (js_eval, dom_snapshot, cert_info) use a
    /// mutex/condvar pattern to block the socket thread until the GTK thread
    /// produces a result.
    fn handleSocketCommand(
        cmd: []const u8,
        json: []const u8,
        ctx: *anyopaque,
    ) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const priv = self.private();

        if (std.mem.eql(u8, cmd, "status")) {
            return statusResponse(priv);
        } else if (std.mem.eql(u8, cmd, "navigate")) {
            const url = extractJsonString(json, "url") orelse
                return "{\"ok\":false,\"error\":\"missing url field\"}";
            var nav_ctx = IdleNavigateCtx{
                .self = self.ref(),
                .url = undefined,
                .url_len = 0,
            };
            const copy_len = @min(url.len, nav_ctx.url.len);
            @memcpy(nav_ctx.url[0..copy_len], url[0..copy_len]);
            nav_ctx.url_len = copy_len;
            // Schedule on GTK thread and block until complete.
            _ = glib.idleAdd(idleNavigate, &nav_ctx);
            nav_ctx.mutex.lock();
            while (!nav_ctx.done) nav_ctx.cond.wait(&nav_ctx.mutex);
            nav_ctx.mutex.unlock();
            return "{\"ok\":true}";
        } else if (std.mem.eql(u8, cmd, "back")) {
            _ = glib.idleAddOnce(idleBack, self.ref());
            return "{\"ok\":true}";
        } else if (std.mem.eql(u8, cmd, "forward")) {
            _ = glib.idleAddOnce(idleForward, self.ref());
            return "{\"ok\":true}";
        } else if (std.mem.eql(u8, cmd, "reload")) {
            _ = glib.idleAddOnce(idleReload, self.ref());
            return "{\"ok\":true}";
        } else if (std.mem.eql(u8, cmd, "proxy_set")) {
            const url = extractJsonString(json, "url");
            var proxy_ctx = IdleProxyCtx{
                .self = self.ref(),
                .url = undefined,
                .url_len = 0,
                .clear = url == null,
            };
            if (url) |u| {
                const copy_len = @min(u.len, proxy_ctx.url.len);
                @memcpy(proxy_ctx.url[0..copy_len], u[0..copy_len]);
                proxy_ctx.url_len = copy_len;
            }
            _ = glib.idleAdd(idleProxySet, &proxy_ctx);
            proxy_ctx.mutex.lock();
            while (!proxy_ctx.done) proxy_ctx.cond.wait(&proxy_ctx.mutex);
            proxy_ctx.mutex.unlock();
            return "{\"ok\":true}";
        } else if (std.mem.eql(u8, cmd, "har_start")) {
            if (priv.har_recorder) |rec| rec.start();
            return "{\"ok\":true}";
        } else if (std.mem.eql(u8, cmd, "har_stop")) {
            if (priv.har_recorder) |rec| rec.stop();
            return "{\"ok\":true}";
        } else if (std.mem.eql(u8, cmd, "har_export")) {
            if (priv.har_recorder) |rec| {
                _ = rec.exportJSON(priv.alloc) catch return "{\"ok\":false,\"error\":\"export failed\"}";
                return "{\"ok\":true,\"info\":\"exported (retrieve via socket read)\"}";
            }
            return "{\"ok\":false,\"error\":\"no recorder\"}";
        } else if (std.mem.eql(u8, cmd, "js_eval")) {
            const code = extractJsonString(json, "code") orelse
                return "{\"ok\":false,\"error\":\"missing code field\"}";
            return self.handleJsEval(code);
        } else if (std.mem.eql(u8, cmd, "dom_snapshot")) {
            return self.handleDomSnapshot();
        } else if (std.mem.eql(u8, cmd, "screenshot")) {
            return "{\"ok\":false,\"error\":\"screenshot not yet implemented on Linux\"}";
        } else if (std.mem.eql(u8, cmd, "cookies_get")) {
            return "{\"ok\":false,\"error\":\"cookies_get not yet implemented on Linux\"}";
        } else if (std.mem.eql(u8, cmd, "cookies_set")) {
            return "{\"ok\":false,\"error\":\"cookies_set not yet implemented on Linux\"}";
        } else if (std.mem.eql(u8, cmd, "session_export")) {
            return self.handleSessionExport();
        } else if (std.mem.eql(u8, cmd, "session_import")) {
            const ls_data = extractJsonString(json, "localStorage");
            return self.handleSessionImport(ls_data);
        } else if (std.mem.eql(u8, cmd, "cert_info")) {
            return self.handleCertInfo();
        } else {
            return "{\"ok\":false,\"error\":\"unknown command\"}";
        }
    }

    /// Return a simple JSON status blob.
    fn statusResponse(priv: *Private) []const u8 {
        _ = priv;
        return "{\"ok\":true,\"status\":\"running\"}";
    }

    // -----------------------------------------------------------------------
    // Async JS evaluation (blocks socket thread, runs JS on GTK thread)
    // -----------------------------------------------------------------------

    /// Shared context between the socket thread (which waits) and the GTK
    /// main thread (which runs the WebKit JS evaluation and signals completion).
    const JSEvalContext = struct {
        /// The BrowserWidget that owns the web view.
        widget: *Self,
        /// Null-terminated JS code to evaluate (stack buffer, valid during call).
        code_buf: [8192]u8 = undefined,
        code_len: usize = 0,
        /// Result or error string, allocated with `alloc`. Caller must free.
        result: ?[]const u8 = null,
        err_msg: ?[]const u8 = null,
        /// Synchronization.
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
        alloc: Allocator,
    };

    /// Dispatch JS evaluation to the GTK thread and block until it completes.
    /// Returns a JSON response string (static or allocated — the socket layer
    /// only needs it until the next command).
    fn handleJsEval(self: *Self, code: []const u8) []const u8 {
        const priv = self.private();
        if (priv.web_view == null) return "{\"ok\":false,\"error\":\"no web view\"}";

        var eval_ctx = JSEvalContext{
            .widget = self,
            .alloc = priv.alloc,
        };
        const copy_len = @min(code.len, eval_ctx.code_buf.len - 1);
        @memcpy(eval_ctx.code_buf[0..copy_len], code[0..copy_len]);
        eval_ctx.code_buf[copy_len] = 0;
        eval_ctx.code_len = copy_len;

        // Schedule the evaluation on the GTK main thread.
        _ = glib.idleAdd(idleJsEval, &eval_ctx);

        // Block until the GTK callback signals completion.
        eval_ctx.mutex.lock();
        while (!eval_ctx.done) {
            eval_ctx.cond.wait(&eval_ctx.mutex);
        }
        eval_ctx.mutex.unlock();

        if (eval_ctx.err_msg) |err| {
            _ = err;
            return "{\"ok\":false,\"error\":\"js evaluation failed\"}";
        }

        if (eval_ctx.result) |result| {
            // Build a JSON response. We use a thread-local static buffer
            // since the socket only needs the response until processLine
            // writes it to the fd.
            const S = struct {
                threadlocal var resp_buf: [65536]u8 = undefined;
            };
            const resp = std.fmt.bufPrint(&S.resp_buf, "{{\"ok\":true,\"result\":{s}}}", .{
                jsonEscapeToString(result),
            }) catch return "{\"ok\":true,\"result\":\"(response too large)\"}";
            return resp;
        }

        return "{\"ok\":true,\"result\":null}";
    }

    /// GTK idle callback: runs webkit_web_view_evaluate_javascript and collects
    /// the result via the async finish callback.
    fn idleJsEval(data: ?*anyopaque) callconv(.c) c_int {
        const eval_ctx: *JSEvalContext = @ptrCast(@alignCast(data orelse {
            return 0; // G_SOURCE_REMOVE
        }));
        const priv = eval_ctx.widget.private();
        const wv = priv.web_view orelse {
            eval_ctx.mutex.lock();
            eval_ctx.err_msg = "no web view";
            eval_ctx.done = true;
            eval_ctx.cond.signal();
            eval_ctx.mutex.unlock();
            return 0;
        };

        c.webkit_web_view_evaluate_javascript(
            @ptrCast(wv),
            &eval_ctx.code_buf,
            @intCast(eval_ctx.code_len),
            null, // world
            null, // source_uri
            null, // cancellable
            &jsEvalFinishCallback,
            @ptrCast(eval_ctx),
        );

        return 0; // G_SOURCE_REMOVE — run once
    }

    /// GAsyncReadyCallback invoked when webkit_web_view_evaluate_javascript
    /// completes. Extracts the result and signals the waiting socket thread.
    /// Uses C-compatible types since it's called from WebKitGTK's C API.
    fn jsEvalFinishCallback(
        source: ?*anyopaque,
        result: ?*anyopaque,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const eval_ctx: *JSEvalContext = @ptrCast(@alignCast(user_data orelse return));
        defer {
            eval_ctx.mutex.lock();
            eval_ctx.done = true;
            eval_ctx.cond.signal();
            eval_ctx.mutex.unlock();
        }

        var err: ?*c.GError = null;
        const js_result = c.webkit_web_view_evaluate_javascript_finish(
            @ptrCast(source),
            @ptrCast(result),
            &err,
        );

        if (err) |e| {
            eval_ctx.err_msg = "js error";
            c.g_error_free(e);
            return;
        }

        if (js_result) |jsc_val| {
            const cstr = c.jsc_value_to_string(jsc_val);
            if (cstr) |s| {
                const span = std.mem.span(s);
                // Dupe into our allocator so it outlives the JSC value.
                eval_ctx.result = eval_ctx.alloc.dupe(u8, span) catch null;
                c.g_free(@ptrCast(s));
            }
        }
    }

    // -----------------------------------------------------------------------
    // dom_snapshot (wraps js_eval with "html" key in response)
    // -----------------------------------------------------------------------

    fn handleDomSnapshot(self: *Self) []const u8 {
        const priv = self.private();
        if (priv.web_view == null) return "{\"ok\":false,\"error\":\"no web view\"}";

        var eval_ctx = JSEvalContext{
            .widget = self,
            .alloc = priv.alloc,
        };
        const code = "document.documentElement.outerHTML";
        @memcpy(eval_ctx.code_buf[0..code.len], code);
        eval_ctx.code_buf[code.len] = 0;
        eval_ctx.code_len = code.len;

        _ = glib.idleAdd(idleJsEval, &eval_ctx);
        eval_ctx.mutex.lock();
        while (!eval_ctx.done) eval_ctx.cond.wait(&eval_ctx.mutex);
        eval_ctx.mutex.unlock();

        if (eval_ctx.err_msg != null) {
            return "{\"ok\":false,\"error\":\"dom snapshot failed\"}";
        }

        if (eval_ctx.result) |result| {
            const S = struct {
                threadlocal var resp_buf: [65536]u8 = undefined;
            };
            const resp = std.fmt.bufPrint(&S.resp_buf, "{{\"ok\":true,\"html\":{s}}}", .{
                jsonEscapeToString(result),
            }) catch return "{\"ok\":true,\"html\":\"(response too large)\"}";
            return resp;
        }

        return "{\"ok\":true,\"html\":null}";
    }

    // -----------------------------------------------------------------------
    // session_export / session_import
    // -----------------------------------------------------------------------

    /// Export session data: localStorage via JS eval.
    /// Cookies are not yet implemented on Linux, so we return an empty array.
    fn handleSessionExport(self: *Self) []const u8 {
        const ls_json = self.handleJsEval(
            \\(function(){try{var o={};for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);o[k]=localStorage.getItem(k);}return JSON.stringify(o);}catch(e){return '{}';}})()
        );
        // ls_json is already a JSON response like {"ok":true,"result":"..."}
        // We need to extract the result and wrap it in the session format.
        // For simplicity, return a combined response.
        const S = struct {
            threadlocal var buf: [65536]u8 = undefined;
        };
        // Check if js_eval succeeded by looking at the response
        if (std.mem.indexOf(u8, ls_json, "\"ok\":true")) |_| {
            const resp = std.fmt.bufPrint(&S.buf, "{{\"ok\":true,\"session\":{{\"cookies\":[],\"localStorage\":{s}}}}}", .{
                extractJsonValue(ls_json, "result") orelse "null",
            }) catch return "{\"ok\":false,\"error\":\"response too large\"}";
            return resp;
        }
        return "{\"ok\":false,\"error\":\"failed to export localStorage\"}";
    }

    /// Import session data: localStorage via JS eval.
    /// Cookies are not yet implemented on Linux.
    fn handleSessionImport(self: *Self, ls_data: ?[]const u8) []const u8 {
        if (ls_data) |data| {
            // Build JS to import localStorage entries.
            // The data should be a JSON string like '{"key":"value",...}'.
            var code_buf: [16384]u8 = undefined;
            const code = std.fmt.bufPrint(&code_buf, "(function(){{var d={s};for(var k in d){{localStorage.setItem(k,d[k]);}}}})();", .{data}) catch
                return "{\"ok\":false,\"error\":\"localStorage data too large\"}";
            _ = self.handleJsEval(code);
        }
        return "{\"ok\":true}";
    }

    // -----------------------------------------------------------------------
    // cert_info
    // -----------------------------------------------------------------------

    /// Context for cert_info idle callback.
    const CertInfoCtx = struct {
        widget: *Self,
        tls_errors: c_uint = 0,
        has_tls: bool = false,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
    };

    fn handleCertInfo(self: *Self) []const u8 {
        const priv = self.private();
        if (priv.web_view == null) return "{\"ok\":false,\"error\":\"no web view\"}";

        var cert_ctx = CertInfoCtx{ .widget = self };
        _ = glib.idleAdd(idleCertInfo, &cert_ctx);

        cert_ctx.mutex.lock();
        while (!cert_ctx.done) cert_ctx.cond.wait(&cert_ctx.mutex);
        cert_ctx.mutex.unlock();

        if (!cert_ctx.has_tls) {
            return "{\"ok\":true,\"certificates\":[],\"info\":\"no TLS connection\"}";
        }

        const S = struct {
            threadlocal var buf: [4096]u8 = undefined;
        };
        const resp = std.fmt.bufPrint(&S.buf, "{{\"ok\":true,\"certificates\":[{{\"tls_errors\":{d}}}]}}", .{
            cert_ctx.tls_errors,
        }) catch return "{\"ok\":false,\"error\":\"response too large\"}";
        return resp;
    }

    fn idleCertInfo(data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *CertInfoCtx = @ptrCast(@alignCast(data orelse return 0));
        defer {
            ctx.mutex.lock();
            ctx.done = true;
            ctx.cond.signal();
            ctx.mutex.unlock();
        }

        const priv = ctx.widget.private();
        const wv = priv.web_view orelse return 0;

        var cert: ?*anyopaque = null;
        var errors: c_uint = 0;
        const has_tls = c.webkit_web_view_get_tls_info(
            @ptrCast(wv),
            @ptrCast(&cert),
            @ptrCast(&errors),
        );

        ctx.has_tls = has_tls != 0 and cert != null;
        ctx.tls_errors = errors;
        return 0;
    }

    // -----------------------------------------------------------------------
    // Idle callbacks — run on GTK main thread via glib.idleAddOnce
    // -----------------------------------------------------------------------

    const IdleNavigateCtx = struct {
        self: *Self,
        url: [4096]u8,
        url_len: usize,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
    };

    fn idleNavigate(data: ?*anyopaque) callconv(.c) c_int {
        const ctx_ptr: *IdleNavigateCtx = @ptrCast(@alignCast(data orelse return 0));
        ctx_ptr.self.navigate(ctx_ptr.url[0..ctx_ptr.url_len]);
        ctx_ptr.self.unref();
        ctx_ptr.mutex.lock();
        ctx_ptr.done = true;
        ctx_ptr.cond.signal();
        ctx_ptr.mutex.unlock();
        return 0; // G_SOURCE_REMOVE
    }

    const IdleProxyCtx = struct {
        self: *Self,
        url: [1024]u8,
        url_len: usize,
        clear: bool,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
    };

    fn idleProxySet(data: ?*anyopaque) callconv(.c) c_int {
        const ctx_ptr: *IdleProxyCtx = @ptrCast(@alignCast(data orelse return 0));
        if (ctx_ptr.clear) {
            ctx_ptr.self.setProxy(null);
        } else {
            ctx_ptr.self.setProxy(ctx_ptr.url[0..ctx_ptr.url_len]);
        }
        ctx_ptr.self.unref();
        ctx_ptr.mutex.lock();
        ctx_ptr.done = true;
        ctx_ptr.cond.signal();
        ctx_ptr.mutex.unlock();
        return 0; // G_SOURCE_REMOVE
    }

    fn idleBack(self_opaque: *Self) callconv(.c) void {
        const priv = self_opaque.private();
        if (priv.web_view) |wv| c.webkit_web_view_go_back(@ptrCast(wv));
        self_opaque.unref();
    }

    fn idleForward(self_opaque: *Self) callconv(.c) void {
        const priv = self_opaque.private();
        if (priv.web_view) |wv| c.webkit_web_view_go_forward(@ptrCast(wv));
        self_opaque.unref();
    }

    fn idleReload(self_opaque: *Self) callconv(.c) void {
        const priv = self_opaque.private();
        if (priv.web_view) |wv| c.webkit_web_view_reload(@ptrCast(wv));
        self_opaque.unref();
    }

    // -----------------------------------------------------------------------
    // JSON helpers (lightweight, no full parser needed)
    // -----------------------------------------------------------------------

    /// Extract a quoted string value for a given key from a JSON blob.
    /// Only handles simple cases (no nested objects as values, no escapes
    /// in the value). Returns the raw content between the quotes.
    fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
        // Search for "key" in the JSON
        var search_buf: [256]u8 = undefined;
        const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

        const key_pos = std.mem.indexOf(u8, json, search_key) orelse return null;
        var i = key_pos + search_key.len;

        // Skip whitespace then expect ':'
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
        if (i >= json.len or json[i] != ':') return null;
        i += 1;

        // Skip whitespace then expect opening '"'
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
        if (i >= json.len or json[i] != '"') return null;
        i += 1;

        const value_start = i;
        // Scan to closing '"' (handle \" escapes)
        while (i < json.len) {
            if (json[i] == '\\' and i + 1 < json.len) {
                i += 2;
                continue;
            }
            if (json[i] == '"') break;
            i += 1;
        }
        if (i >= json.len) return null;

        return json[value_start..i];
    }

    /// Extract a raw JSON value (could be string, number, object, etc.) for
    /// a given key. Returns the raw text including quotes for strings.
    fn extractJsonValue(json: []const u8, key: []const u8) ?[]const u8 {
        var search_buf: [256]u8 = undefined;
        const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

        const key_pos = std.mem.indexOf(u8, json, search_key) orelse return null;
        var i = key_pos + search_key.len;

        // Skip whitespace then expect ':'
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
        if (i >= json.len or json[i] != ':') return null;
        i += 1;

        // Skip whitespace
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
        if (i >= json.len) return null;

        const value_start = i;

        // Determine value type and find its end
        if (json[i] == '"') {
            // String value — find closing quote
            i += 1;
            while (i < json.len) {
                if (json[i] == '\\' and i + 1 < json.len) {
                    i += 2;
                    continue;
                }
                if (json[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
        } else {
            // Non-string value — scan to delimiter
            while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != ']') i += 1;
        }

        return json[value_start..i];
    }

    /// Produce a JSON-escaped version of a string, wrapped in double quotes.
    /// Uses a thread-local buffer. Suitable for embedding in JSON responses.
    fn jsonEscapeToString(input: []const u8) []const u8 {
        const S = struct {
            threadlocal var buf: [65536]u8 = undefined;
        };
        var pos: usize = 0;
        S.buf[pos] = '"';
        pos += 1;

        for (input) |ch| {
            if (pos + 6 >= S.buf.len) break; // leave room for worst-case escape + closing quote
            switch (ch) {
                '"' => {
                    S.buf[pos] = '\\';
                    S.buf[pos + 1] = '"';
                    pos += 2;
                },
                '\\' => {
                    S.buf[pos] = '\\';
                    S.buf[pos + 1] = '\\';
                    pos += 2;
                },
                '\n' => {
                    S.buf[pos] = '\\';
                    S.buf[pos + 1] = 'n';
                    pos += 2;
                },
                '\r' => {
                    S.buf[pos] = '\\';
                    S.buf[pos + 1] = 'r';
                    pos += 2;
                },
                '\t' => {
                    S.buf[pos] = '\\';
                    S.buf[pos + 1] = 't';
                    pos += 2;
                },
                else => {
                    if (ch < 0x20) {
                        // Control character — use \u00XX escape
                        const hex = "0123456789abcdef";
                        S.buf[pos] = '\\';
                        S.buf[pos + 1] = 'u';
                        S.buf[pos + 2] = '0';
                        S.buf[pos + 3] = '0';
                        S.buf[pos + 4] = hex[ch >> 4];
                        S.buf[pos + 5] = hex[ch & 0x0f];
                        pos += 6;
                    } else {
                        S.buf[pos] = ch;
                        pos += 1;
                    }
                },
            }
        }

        S.buf[pos] = '"';
        pos += 1;

        return S.buf[0..pos];
    }

    // -----------------------------------------------------------------------
    // GObject boilerplate (Common mixin + Class)
    // -----------------------------------------------------------------------

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };
};
