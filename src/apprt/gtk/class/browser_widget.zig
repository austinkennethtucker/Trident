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
    /// back, forward, reload) we use glib.idleAdd to schedule them.
    fn handleSocketCommand(
        cmd: []const u8,
        _: []const u8,
        ctx: *anyopaque,
    ) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const priv = self.private();

        if (std.mem.eql(u8, cmd, "status")) {
            return statusResponse(priv);
        } else if (std.mem.eql(u8, cmd, "navigate")) {
            // For navigate we'd need to parse the URL from the JSON payload.
            // For now, return acknowledgement — full JSON parsing is a future task.
            return "{\"ok\":true,\"info\":\"navigate: parse pending\"}";
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
            return "{\"ok\":true,\"info\":\"proxy_set: parse pending\"}";
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
        } else {
            return "{\"ok\":false,\"error\":\"not yet implemented\"}";
        }
    }

    /// Return a simple JSON status blob.
    fn statusResponse(priv: *Private) []const u8 {
        _ = priv;
        return "{\"ok\":true,\"status\":\"running\"}";
    }

    // Idle callbacks — these run on the GTK main thread via glib.idleAddOnce.
    // Each receives a ref'd *Self and unrefs after use.

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
