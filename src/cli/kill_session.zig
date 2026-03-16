const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const daemon = @import("../daemon.zig");
const Protocol = daemon.Protocol;
const Server = daemon.Server;

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// The name or ID of the session to kill. If not specified,
    /// kills the current session.
    session: ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `kill-session` command terminates a Ghostty session and all of its
/// associated processes.
///
/// If a session name is given with `--session`, the command will kill that
/// specific session. Otherwise, it kills the current session.
///
/// Flags:
///
///   * `--session`: The name or ID of the session to kill.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: Options = .{};
    defer opts.deinit();
    try args.parse(Options, alloc, &opts, &iter);

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // The --session flag is required.
    const session_name = opts.session orelse {
        try stderr.print("Usage: trident +kill-session --session=<name>\n", .{});
        try stderr.print("\nThe --session flag is required.\n", .{});
        try stderr.flush();
        return 1;
    };

    // Resolve the daemon socket path.
    const socket_path = Server.socketPath(alloc) catch {
        try stderr.print("Failed to resolve daemon socket path\n", .{});
        try stderr.flush();
        return 1;
    };
    defer alloc.free(socket_path);

    // Connect to the daemon's Unix domain socket.
    const fd = connectToDaemon(socket_path) catch {
        try stderr.print("No daemon running. Start one with: trident --daemon\n", .{});
        try stderr.flush();
        return 1;
    };
    defer posix.close(fd);

    // Build and send the destroy_session request.
    {
        // Build payload: session name as a length-prefixed string.
        var payload_buf: [1024]u8 = undefined;
        var payload_fbs = std.io.fixedBufferStream(&payload_buf);
        Protocol.writeString(payload_fbs.writer(), session_name) catch {
            try stderr.print("Session name too long\n", .{});
            try stderr.flush();
            return 1;
        };
        const payload = payload_buf[0..payload_fbs.pos];

        // Write the full frame (header + payload) into a buffer and send it.
        const frame_len = Protocol.header_size + payload.len;
        const frame_buf = alloc.alloc(u8, frame_len) catch {
            try stderr.print("Out of memory\n", .{});
            try stderr.flush();
            return 1;
        };
        defer alloc.free(frame_buf);

        var frame_fbs = std.io.fixedBufferStream(frame_buf);
        Protocol.writeFrame(frame_fbs.writer(), @intFromEnum(Protocol.ClientMsg.destroy_session), payload) catch {
            try stderr.print("Failed to build request\n", .{});
            try stderr.flush();
            return 1;
        };

        writeAllFd(fd, frame_buf) catch {
            try stderr.print("Failed to send request to daemon\n", .{});
            try stderr.flush();
            return 1;
        };
    }

    // Read the response into a buffer.
    var recv_buf: [65536]u8 = undefined;
    const n = readResponse(fd, &recv_buf) catch {
        try stderr.print("Failed to read response from daemon\n", .{});
        try stderr.flush();
        return 1;
    };
    if (n == 0) {
        try stderr.print("Daemon closed connection unexpectedly\n", .{});
        try stderr.flush();
        return 1;
    }

    // Parse the frame header from the response.
    var fbs = std.io.fixedBufferStream(recv_buf[0..n]);
    const reader = fbs.reader();

    const maybe_header = Protocol.readFrameHeader(reader) catch {
        try stderr.print("Malformed response from daemon\n", .{});
        try stderr.flush();
        return 1;
    };
    const header = maybe_header orelse {
        try stderr.print("Empty response from daemon\n", .{});
        try stderr.flush();
        return 1;
    };

    // Verify we have the full payload.
    const remaining = n - fbs.pos;
    if (remaining < header.payload_len) {
        try stderr.print("Incomplete response from daemon\n", .{});
        try stderr.flush();
        return 1;
    }

    // Extract payload.
    const payload = recv_buf[fbs.pos..][0..header.payload_len];

    // Dispatch on response type.
    if (header.serverMsg()) |msg| {
        switch (msg) {
            .session_info => {
                // The daemon sends the updated session list as confirmation.
                try stdout.print("Session '{s}' destroyed.\n", .{session_name});
                try stdout.flush();
                return 0;
            },
            .@"error" => {
                return handleErrorResponse(alloc, payload, stderr);
            },
            else => {
                try stderr.print("Unexpected response type from daemon: 0x{x:0>2}\n", .{header.msg_type});
                try stderr.flush();
                return 1;
            },
        }
    } else {
        try stderr.print("Unknown response type from daemon: 0x{x:0>2}\n", .{header.msg_type});
        try stderr.flush();
        return 1;
    }
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

/// Connect to the daemon's Unix domain socket at the given path.
fn connectToDaemon(socket_path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);
    if (socket_path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    return fd;
}

/// Write the entire buffer to a file descriptor, retrying on partial writes.
fn writeAllFd(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const w = try posix.write(fd, data[written..]);
        if (w == 0) return error.BrokenPipe;
        written += w;
    }
}

/// Read a complete response from the daemon. May need multiple reads to
/// get the full frame (header + payload).
fn readResponse(fd: posix.fd_t, buf: []u8) !usize {
    var total: usize = 0;

    // First read: get at least the header.
    while (total < Protocol.header_size) {
        const n = posix.read(fd, buf[total..]) catch |err| return err;
        if (n == 0) return total; // EOF
        total += n;
    }

    // Parse the payload length from the header to know how much more to read.
    const payload_len = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, buf[0..4]));
    const frame_len = Protocol.header_size + payload_len;

    // Read remaining bytes if we don't have the full frame yet.
    while (total < frame_len) {
        if (total >= buf.len) return error.BufferTooSmall;
        const n = posix.read(fd, buf[total..]) catch |err| return err;
        if (n == 0) return total; // EOF
        total += n;
    }

    return total;
}

/// Parse and print a daemon error response. Returns exit code 1.
fn handleErrorResponse(alloc: Allocator, payload: []const u8, stderr: anytype) !u8 {
    var efbs = std.io.fixedBufferStream(payload);
    const er = efbs.reader();

    var ctx_owned = true;
    const context = Protocol.readString(alloc, er) catch blk: {
        ctx_owned = false;
        break :blk "unknown";
    };
    defer if (ctx_owned) alloc.free(context);

    var msg_owned = true;
    const message = Protocol.readString(alloc, er) catch blk: {
        msg_owned = false;
        break :blk "unknown error";
    };
    defer if (msg_owned) alloc.free(message);

    try stderr.print("Error ({s}): {s}\n", .{ context, message });
    try stderr.flush();
    return 1;
}
