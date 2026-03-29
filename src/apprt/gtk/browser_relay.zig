/// TCP proxy relay for GTK browser pane HAR recording.
///
/// BrowserRelay listens on a loopback TCP port and acts as an HTTP/HTTPS
/// proxy between WebKitWebView (configured to use 127.0.0.1:<port>) and the
/// real network. Every request is intercepted so it can be logged to the HAR
/// recorder. CONNECT tunnels are relayed bidirectionally after the 200 reply.
///
/// Think of it like a transparent firewall that logs everything passing
/// through before forwarding it on.
const std = @import("std");
const posix = std.posix;

const HARRecorder = @import("browser_har.zig").HARRecorder;
const HAREntry = @import("browser_har.zig").HAREntry;

const log = std.log.scoped(.browser_relay);

/// Maximum size of a single HTTP request/response header block we buffer.
const max_header_buf = 64 * 1024; // 64 KiB
/// poll() timeout in milliseconds used by the accept loop.
const accept_timeout_ms = 500;
/// poll() timeout in milliseconds used by the pipe loop.
const pipe_timeout_ms = 5_000;
/// Buffer size for bidirectional pipe reads.
const pipe_buf_size = 16 * 1024;

pub const BrowserRelay = struct {
    /// Listening socket file descriptor, or -1 when not started.
    listen_fd: posix.fd_t = -1,
    /// The port that was actually assigned by the OS (0 until start()).
    local_port: u16 = 0,
    /// Optional upstream proxy URL (e.g. "http://corp-proxy:8080").
    /// Currently stored for future use; direct connect is always used for now.
    upstream_proxy: ?[]const u8 = null,
    /// Optional HAR recorder to log entries into.
    har_recorder: ?*HARRecorder = null,
    /// Background accept-loop thread, or null when stopped.
    thread: ?std.Thread = null,
    /// Signals the accept loop to exit cleanly.
    running: std.atomic.Value(bool),
    alloc: std.mem.Allocator,

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    pub fn init(alloc: std.mem.Allocator) BrowserRelay {
        return .{
            .running = std.atomic.Value(bool).init(false),
            .alloc = alloc,
        };
    }

    /// Bind to 127.0.0.1:0 (OS picks the port), start listening, and spawn
    /// the background relay thread.
    pub fn start(self: *BrowserRelay) !void {
        // Create a TCP socket on the loopback interface.
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        // SO_REUSEADDR lets us rebind quickly after a crash (like setting the
        // "reuse port" option in nginx).
        try posix.setsockopt(
            fd,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        // Bind to 127.0.0.1 on port 0 — the OS will assign a free port.
        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = 0,
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
            .zero = [_]u8{0} ** 8,
        };
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

        // Find out which port the OS actually assigned.
        var bound_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);
        const assigned_port = std.mem.bigToNative(u16, bound_addr.port);

        // Start accepting connections (backlog of 128 — like listen() in a
        // basic network daemon).
        try posix.listen(fd, 128);

        self.listen_fd = fd;
        self.local_port = assigned_port;
        self.running.store(true, .seq_cst);

        self.thread = try std.Thread.spawn(.{}, relayLoop, .{self});
        log.info("browser relay listening on 127.0.0.1:{d}", .{assigned_port});
    }

    /// Signal the relay loop to stop, close the listening socket, and wait
    /// for the thread to finish.
    pub fn stop(self: *BrowserRelay) void {
        self.running.store(false, .seq_cst);

        if (self.listen_fd != -1) {
            posix.close(self.listen_fd);
            self.listen_fd = -1;
        }

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        log.info("browser relay stopped", .{});
    }

    // -------------------------------------------------------------------------
    // Accept loop (runs on background thread)
    // -------------------------------------------------------------------------

    /// Loops until running is set to false, polling the listen socket for
    /// incoming connections and dispatching each one to its own thread.
    fn relayLoop(self: *BrowserRelay) void {
        log.debug("relay loop started", .{});

        while (self.running.load(.seq_cst)) {
            // poll() with a timeout so we check `running` periodically.
            // This is like a select() in a classic UNIX daemon.
            var pfd = [1]posix.pollfd{.{
                .fd = self.listen_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const n = posix.poll(&pfd, accept_timeout_ms) catch |err| {
                log.err("poll on listen_fd failed: {}", .{err});
                break;
            };

            if (n == 0) continue; // timeout — loop to re-check running flag

            if (pfd[0].revents & posix.POLL.ERR != 0 or
                pfd[0].revents & posix.POLL.HUP != 0)
            {
                log.debug("listen_fd HUP/ERR — stopping relay loop", .{});
                break;
            }

            if (pfd[0].revents & posix.POLL.IN == 0) continue;

            // Accept the incoming connection.
            var client_addr: posix.sockaddr = undefined;
            var client_len: posix.socklen_t = @sizeOf(posix.sockaddr);
            const client_fd = posix.accept(
                self.listen_fd,
                &client_addr,
                &client_len,
            ) catch |err| {
                if (!self.running.load(.seq_cst)) break;
                log.warn("accept failed: {}", .{err});
                continue;
            };

            // Spawn a detached thread for each connection so connections are
            // handled concurrently (like inetd with nowait mode).
            const t = std.Thread.spawn(.{}, handleConnection, .{ self, client_fd }) catch |err| {
                log.err("failed to spawn connection thread: {}", .{err});
                posix.close(client_fd);
                continue;
            };
            t.detach();
        }

        log.debug("relay loop exited", .{});
    }

    // -------------------------------------------------------------------------
    // Per-connection dispatch
    // -------------------------------------------------------------------------

    /// Entry point for each accepted connection thread.
    /// Reads the first HTTP request line, dispatches to CONNECT or plain HTTP.
    fn handleConnection(self: *BrowserRelay, client_fd: posix.fd_t) void {
        defer posix.close(client_fd);

        const start_time = std.time.milliTimestamp();

        // Read the request into a stack buffer.
        var buf: [max_header_buf]u8 = undefined;
        const n = posix.read(client_fd, &buf) catch |err| {
            log.warn("read from client failed: {}", .{err});
            return;
        };
        if (n == 0) return;

        const request = buf[0..n];

        // Parse the first line: "METHOD target HTTP/x.y\r\n..."
        const first_line_end = std.mem.indexOfScalar(u8, request, '\n') orelse {
            log.warn("no newline in request — dropping", .{});
            return;
        };
        const first_line = std.mem.trimRight(u8, request[0..first_line_end], "\r");

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;
        // third token is the HTTP version — we don't need it here

        if (std.mem.eql(u8, method, "CONNECT")) {
            self.handleConnect(client_fd, target, start_time) catch |err| {
                log.warn("CONNECT to {s} failed: {}", .{ target, err });
            };
        } else {
            self.handleHTTP(client_fd, method, target, request, start_time) catch |err| {
                log.warn("HTTP {s} {s} failed: {}", .{ method, target, err });
            };
        }
    }

    // -------------------------------------------------------------------------
    // CONNECT tunnel
    // -------------------------------------------------------------------------

    /// Handles a CONNECT request: connect to the target, send 200, then pipe
    /// bidirectionally. Used for HTTPS tunnelling.
    fn handleConnect(
        self: *BrowserRelay,
        client_fd: posix.fd_t,
        target: []const u8,
        start_time: i64,
    ) !void {
        // target is "host:port"
        const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse {
            return error.MalformedConnectTarget;
        };
        const host = target[0..colon];
        const port_str = target[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            return error.MalformedConnectTarget;
        };

        const server_fd = try self.connectToTarget(host, port);
        defer posix.close(server_fd);

        // Tell the client the tunnel is established.
        const ok = "HTTP/1.1 200 Connection Established\r\n\r\n";
        _ = try posix.write(client_fd, ok);

        // Log a synthetic CONNECT entry to the HAR recorder.
        if (self.har_recorder) |rec| {
            var entry = HAREntry.initConnect(self.alloc, target, start_time);
            rec.addEntry(&entry) catch |err| {
                log.warn("HAR addEntry (CONNECT) failed: {}", .{err});
            };
        }

        log.debug("CONNECT tunnel established to {s}", .{target});
        self.pipeData(client_fd, server_fd);
    }

    // -------------------------------------------------------------------------
    // Plain HTTP relay
    // -------------------------------------------------------------------------

    /// Handles a plain HTTP request: parse the target URL, connect to the
    /// origin, forward the request, read the response, forward it back, and
    /// log the exchange to the HAR recorder.
    fn handleHTTP(
        self: *BrowserRelay,
        client_fd: posix.fd_t,
        method: []const u8,
        target: []const u8,
        request: []const u8,
        start_time: i64,
    ) !void {
        // Parse the URL to extract host and port.
        const uri = std.Uri.parse(target) catch {
            return error.MalformedURL;
        };

        const host: []const u8 = switch (uri.host orelse return error.MissingHost) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };

        const port: u16 = uri.port orelse 80;

        const server_fd = try self.connectToTarget(host, port);
        defer posix.close(server_fd);

        // Forward the complete buffered request to the origin server.
        var sent: usize = 0;
        while (sent < request.len) {
            const wrote = try posix.write(server_fd, request[sent..]);
            if (wrote == 0) return error.ServerClosedEarly;
            sent += wrote;
        }

        // Read the response and buffer it for HAR logging.
        var resp_buf = std.ArrayList(u8).init(self.alloc);
        defer resp_buf.deinit();

        var tmp: [pipe_buf_size]u8 = undefined;
        // Read at least the response headers (until we hit \r\n\r\n or EOF).
        var headers_done = false;
        while (!headers_done) {
            const n = posix.read(server_fd, &tmp) catch break;
            if (n == 0) break;
            resp_buf.appendSlice(tmp[0..n]) catch break;
            if (std.mem.indexOf(u8, resp_buf.items, "\r\n\r\n") != null) {
                headers_done = true;
            }
        }

        // Forward what we have to the client.
        if (resp_buf.items.len > 0) {
            var fw: usize = 0;
            while (fw < resp_buf.items.len) {
                const wrote = posix.write(client_fd, resp_buf.items[fw..]) catch break;
                if (wrote == 0) break;
                fw += wrote;
            }
        }

        // Log the exchange.
        if (self.har_recorder) |rec| {
            var entry = HAREntry.initHTTP(
                self.alloc,
                method,
                target,
                request,
                resp_buf.items,
                start_time,
            ) catch |err| {
                log.warn("HAREntry.initHTTP failed: {}", .{err});
                return;
            };
            rec.addEntry(&entry) catch |err| {
                log.warn("HAR addEntry (HTTP) failed: {}", .{err});
            };
        }

        log.debug("HTTP {s} {s} proxied ({d} resp bytes)", .{
            method,
            target,
            resp_buf.items.len,
        });

        // Continue piping any remaining streaming data.
        self.pipeData(client_fd, server_fd);
    }

    // -------------------------------------------------------------------------
    // Target connection
    // -------------------------------------------------------------------------

    /// Resolve `host` via DNS and open a TCP connection to `host:port`.
    /// Upstream proxy forwarding is not yet implemented; direct connect is
    /// always used regardless of `upstream_proxy`.
    fn connectToTarget(
        self: *BrowserRelay,
        host: []const u8,
        port: u16,
    ) !posix.fd_t {
        _ = self; // upstream_proxy forwarding reserved for future work

        // std.net.Address.resolveIp handles both IPv4 and IPv6 literals.
        // For hostnames we fall back to getaddrinfo via std.net.
        const addr = std.net.Address.resolveIp(host, port) catch blk: {
            // resolveIp only handles numeric IPs; try getAddressList for DNS.
            const list = try std.net.getAddressList(host, port);
            defer list.deinit();
            if (list.addrs.len == 0) return error.DnsResolutionFailed;
            break :blk list.addrs[0];
        };

        const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        try posix.connect(fd, &addr.any, addr.getOsSockLen());
        return fd;
    }

    // -------------------------------------------------------------------------
    // Bidirectional pipe
    // -------------------------------------------------------------------------

    /// Relay data in both directions between fd_a and fd_b until one side
    /// closes, errors, or hangs up. Uses poll() so neither direction starves
    /// the other — analogous to a pipe in a firewall policy with stateful
    /// inspection on both sides simultaneously.
    fn pipeData(self: *BrowserRelay, fd_a: posix.fd_t, fd_b: posix.fd_t) void {
        _ = self;

        var buf: [pipe_buf_size]u8 = undefined;

        while (true) {
            var pfds = [2]posix.pollfd{
                .{ .fd = fd_a, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = fd_b, .events = posix.POLL.IN, .revents = 0 },
            };

            const n = posix.poll(&pfds, pipe_timeout_ms) catch return;
            if (n == 0) return; // timeout — treat as idle close

            for (0..2) |i| {
                const src_fd = pfds[i].fd;
                const dst_fd = pfds[1 - i].fd;
                const rev = pfds[i].revents;

                if (rev & (posix.POLL.HUP | posix.POLL.ERR) != 0) return;
                if (rev & posix.POLL.IN == 0) continue;

                const nread = posix.read(src_fd, &buf) catch return;
                if (nread == 0) return; // EOF

                var written: usize = 0;
                while (written < nread) {
                    const nw = posix.write(dst_fd, buf[written..nread]) catch return;
                    if (nw == 0) return;
                    written += nw;
                }
            }
        }
    }
};
