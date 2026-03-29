const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.browser_socket);

/// Callback type for processing browser commands.
///
/// Receives the extracted command name (e.g. "navigate"), the full raw JSON
/// line, and an opaque context pointer supplied at init time. Returns a
/// JSON-encoded response string that must remain valid until the next call
/// (ownership: caller may write it to the fd and then discard it).
pub const CommandHandler = *const fn (
    cmd: []const u8,
    json: []const u8,
    ctx: *anyopaque,
) []const u8;

/// Unix domain socket server for the GTK browser pane.
///
/// Accepts newline-delimited JSON commands from local clients and dispatches
/// them through a CommandHandler callback.  The socket is placed at
/// `/tmp/trident/b-<8-hex-chars>.sock` (max 104 bytes to satisfy the POSIX
/// sockaddr_un path limit) and is chmod 0600 so only the owning user can
/// connect.
pub const BrowserSocket = struct {
    // Socket path stored as a fixed-size array (max 104 bytes including NUL).
    socket_path: [104]u8,
    socket_path_len: usize,

    socket_fd: posix.fd_t = -1,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    handler: CommandHandler,
    handler_ctx: *anyopaque,
    alloc: std.mem.Allocator,

    /// Create a new BrowserSocket for the given 8-byte hex pane ID.
    ///
    /// Creates `/tmp/trident/` if it does not already exist.
    /// Does NOT start listening — call `start()` after init.
    pub fn init(
        alloc: std.mem.Allocator,
        pane_id: [8]u8,
        handler: CommandHandler,
        handler_ctx: *anyopaque,
    ) !BrowserSocket {
        // Ensure the directory exists (mode 0755 is fine for the directory;
        // the socket file itself is restricted to 0600).
        posix.mkdir("/tmp/trident", 0o755) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var self: BrowserSocket = .{
            .socket_path = undefined,
            .socket_path_len = 0,
            .running = std.atomic.Value(bool).init(false),
            .handler = handler,
            .handler_ctx = handler_ctx,
            .alloc = alloc,
        };

        // Build path: "/tmp/trident/b-XXXXXXXX.sock\x00"
        // pane_id is already the 8-byte ASCII hex string.
        var buf: [104]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &buf,
            "/tmp/trident/b-{s}.sock",
            .{pane_id},
        );

        if (path.len >= 104) return error.PathTooLong;

        @memset(&self.socket_path, 0);
        @memcpy(self.socket_path[0..path.len], path);
        self.socket_path_len = path.len;

        return self;
    }

    /// Return the socket path as a slice (without NUL terminator).
    pub fn socketPath(self: *const BrowserSocket) []const u8 {
        return self.socket_path[0..self.socket_path_len];
    }

    /// Bind and listen on the socket, then spawn the accept loop thread.
    pub fn start(self: *BrowserSocket) !void {
        const path = self.socketPath();

        // Remove stale socket file if present (harmless if missing).
        posix.unlink(path) catch {};

        // Create the Unix stream socket.
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        // Build sockaddr_un.
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);

        // Bind the socket to the filesystem path.
        try posix.bind(
            fd,
            @ptrCast(&addr),
            @sizeOf(posix.sockaddr.un),
        );

        // Restrict to owner-only access (like `chmod 600`).
        try posix.fchmodat(
            posix.AT.FDCWD,
            path,
            0o600,
            0,
        );

        // Start accepting connections (backlog of 5).
        try posix.listen(fd, 5);

        self.socket_fd = fd;
        self.running.store(true, .release);

        // Spawn the accept loop on a dedicated OS thread.
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        log.info("browser socket listening at {s}", .{path});
    }

    /// Signal the accept loop to stop, close the socket, and join the thread.
    pub fn stop(self: *BrowserSocket) void {
        self.running.store(false, .release);

        // Closing the fd unblocks any blocking accept()/poll() call.
        if (self.socket_fd >= 0) {
            posix.close(self.socket_fd);
            self.socket_fd = -1;
        }

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        // Clean up the socket file.
        posix.unlink(self.socketPath()) catch {};

        log.info("browser socket stopped", .{});
    }

    // -------------------------------------------------------------------------
    // Private thread functions
    // -------------------------------------------------------------------------

    /// Main loop: poll for incoming connections with a 500 ms timeout so we
    /// can check `running` periodically without blocking forever.
    fn acceptLoop(self: *BrowserSocket) void {
        while (self.running.load(.acquire)) {
            var pfd = [1]posix.pollfd{.{
                .fd = self.socket_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const ready = posix.poll(&pfd, 500) catch |err| {
                log.err("poll error: {}", .{err});
                break;
            };

            if (ready == 0) continue; // timeout — loop and recheck running

            if (pfd[0].revents & posix.POLL.IN == 0) continue;

            // Accept the waiting connection.
            const client_fd = posix.accept(self.socket_fd, null, null) catch |err| {
                if (self.running.load(.acquire)) {
                    log.err("accept error: {}", .{err});
                }
                continue;
            };

            self.handleClient(client_fd);
        }
    }

    /// Read all data from a connected client, process complete JSON lines, and
    /// close the fd when the client disconnects.
    fn handleClient(self: *BrowserSocket, fd: posix.fd_t) void {
        defer posix.close(fd);

        // 64 KB buffer — plenty for any reasonable command.
        var buf: [65536]u8 = undefined;
        var buf_len: usize = 0;

        while (true) {
            const space = buf[buf_len..];
            if (space.len == 0) {
                log.warn("client send buffer overflow — dropping connection", .{});
                break;
            }

            const n = posix.read(fd, space) catch |err| {
                log.err("read error: {}", .{err});
                break;
            };
            if (n == 0) break; // EOF: client disconnected

            buf_len += n;

            // Process every complete line (terminated by '\n').
            var line_start: usize = 0;
            while (std.mem.indexOf(u8, buf[line_start..buf_len], "\n")) |rel| {
                const nl = line_start + rel;
                const line = buf[line_start..nl];
                line_start = nl + 1;

                if (line.len == 0) continue;

                self.processLine(fd, line);
            }

            // Shift unconsumed bytes to the front of the buffer.
            if (line_start > 0 and line_start < buf_len) {
                std.mem.copyForwards(u8, buf[0..], buf[line_start..buf_len]);
            }
            buf_len -= line_start;
        }
    }

    /// Parse the "cmd" field from a JSON line and call the handler.
    /// Writes the response (plus a newline) back to the client fd.
    fn processLine(self: *BrowserSocket, fd: posix.fd_t, line: []const u8) void {
        const cmd = extractCmd(line) orelse {
            const err_resp = "{\"ok\":false,\"error\":\"missing cmd field\"}\n";
            _ = posix.write(fd, err_resp) catch {};
            return;
        };

        const response = self.handler(cmd, line, self.handler_ctx);

        // Write response + newline.
        _ = posix.write(fd, response) catch {};
        _ = posix.write(fd, "\n") catch {};
    }
};

// -----------------------------------------------------------------------------
// Helper: extract the "cmd" field value from a JSON string without a full parse.
//
// Finds the first occurrence of `"cmd"`, skips the `:` separator and any
// whitespace, then reads the quoted string value.  Returns null if not found
// or malformed.
// -----------------------------------------------------------------------------
fn extractCmd(json: []const u8) ?[]const u8 {
    // Find `"cmd"` key.
    const key = "\"cmd\"";
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;

    var i = key_pos + key.len;

    // Skip whitespace then expect ':'.
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != ':') return null;
    i += 1;

    // Skip whitespace then expect opening '"'.
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;

    const value_start = i;

    // Scan to closing '"' (no escape handling — command names are ASCII).
    while (i < json.len and json[i] != '"') i += 1;
    if (i >= json.len) return null;

    return json[value_start..i];
}
