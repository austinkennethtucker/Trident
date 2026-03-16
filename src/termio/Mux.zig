//! Mux implements a termio backend that connects to the daemon process
//! over a Unix domain socket instead of owning a PTY directly. When running
//! in session mode, each surface uses a Mux backend to send input and
//! receive output via the daemon's wire protocol (see daemon/Protocol.zig).
const Mux = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const daemon = @import("../daemon.zig");
const Protocol = daemon.Protocol;
const Server = daemon.Server;

const log = std.log.scoped(.termio_mux);

// -----------------------------------------------------------------------
// Socket I/O helpers — GenericReader/Writer around a posix fd so that
// Protocol's `anytype` reader/writer parameters work without buffering.
// -----------------------------------------------------------------------

const SocketReader = std.io.GenericReader(posix.fd_t, posix.ReadError, posixRead);

fn posixRead(fd: posix.fd_t, buf: []u8) posix.ReadError!usize {
    return posix.read(fd, buf);
}

fn socketReader(fd: posix.fd_t) SocketReader {
    return .{ .context = fd };
}

// -----------------------------------------------------------------------
// Config — passed in when constructing a Mux backend
// -----------------------------------------------------------------------

pub const Config = struct {
    session_name: []const u8,
    socket_path: ?[]const u8 = null, // null = auto-detect via Server.socketPath
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

// -----------------------------------------------------------------------
// ThreadData — per-IO-thread state
// -----------------------------------------------------------------------

pub const ThreadData = struct {
    /// The connected socket fd (owned by the Mux instance, not ThreadData).
    socket_fd: posix.fd_t,

    /// The daemon-assigned terminal id for this surface.
    terminal_id: u32,

    /// Background thread that reads frames from the daemon and feeds
    /// output to the terminal emulator via Termio.processOutput.
    read_thread: ?std.Thread = null,

    /// Pipe used to signal the read thread to exit. Writing any byte
    /// to pipe[1] causes the read thread to break its poll loop.
    read_thread_pipe: [2]posix.fd_t = .{ -1, -1 },

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        // Signal the read thread to stop by writing to the quit pipe.
        if (self.read_thread_pipe[1] != -1) {
            _ = posix.write(self.read_thread_pipe[1], "x") catch {};
            posix.close(self.read_thread_pipe[1]);
        }
        if (self.read_thread) |t| t.join();
        if (self.read_thread_pipe[0] != -1) posix.close(self.read_thread_pipe[0]);
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
        // Config changes don't affect the mux backend — the daemon
        // owns process configuration.
    }
};

// -----------------------------------------------------------------------
// Instance state
// -----------------------------------------------------------------------

session_name: []const u8,
socket_path: []const u8,
command: ?[]const u8,
cwd: ?[]const u8,
socket_fd: posix.fd_t = -1,
terminal_id: u32 = 0,
alloc: Allocator,

// -----------------------------------------------------------------------
// Lifecycle
// -----------------------------------------------------------------------

pub fn init(alloc: Allocator, cfg: Config) !Mux {
    const socket_path = if (cfg.socket_path) |p|
        try alloc.dupe(u8, p)
    else
        try Server.socketPath(alloc);
    errdefer alloc.free(socket_path);

    return .{
        .session_name = try alloc.dupe(u8, cfg.session_name),
        .socket_path = socket_path,
        .command = if (cfg.command) |c| try alloc.dupe(u8, c) else null,
        .cwd = if (cfg.cwd) |c| try alloc.dupe(u8, c) else null,
        .alloc = alloc,
    };
}

pub fn deinit(self: *Mux) void {
    if (self.socket_fd != -1) posix.close(self.socket_fd);
    self.alloc.free(self.session_name);
    self.alloc.free(self.socket_path);
    if (self.command) |c| self.alloc.free(c);
    if (self.cwd) |c| self.alloc.free(c);
}

/// Called before termio begins to set up initial terminal state.
/// The daemon owns the PTY, so there's nothing to configure here.
pub fn initTerminal(self: *Mux, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

/// Called on the IO thread. Connects to the daemon socket, creates
/// (or joins) a session, spawns a terminal, attaches, and starts
/// the background read thread.
pub fn threadEnter(
    self: *Mux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // ---- Connect to the daemon socket ----
    const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(sock);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);

    const path_bytes = self.socket_path;
    if (path_bytes.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path_bytes.len], path_bytes);

    try posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    self.socket_fd = sock;

    const reader = socketReader(sock);

    // ---- create_session (idempotent — daemon ignores if name exists) ----
    {
        var payload_buf: [256]u8 = undefined;
        var payload_fbs = std.io.fixedBufferStream(&payload_buf);
        try Protocol.writeString(payload_fbs.writer(), self.session_name);
        const payload = payload_buf[0..payload_fbs.pos];

        try sendFrame(sock, @intFromEnum(Protocol.ClientMsg.create_session), payload);
    }
    // Consume session_info response.
    {
        const header = (try Protocol.readFrameHeader(reader)) orelse
            return error.DaemonDisconnected;
        try skipPayload(reader, header.payload_len);
    }

    // ---- create_terminal ----
    {
        // Payload: session_name (string) + command (string) + cwd (string)
        //          + cols (u16) + rows (u16).
        // Maximum reasonable size: 3 * (2 + 256) + 4 = 778 bytes.
        var ct_buf: [1024]u8 = undefined;
        var ct_fbs = std.io.fixedBufferStream(&ct_buf);
        const w = ct_fbs.writer();
        try Protocol.writeString(w, self.session_name);
        try Protocol.writeString(w, self.command orelse "");
        try Protocol.writeString(w, self.cwd orelse "");
        const grid = io.size.grid();
        try Protocol.writeU16(w, @intCast(grid.columns));
        try Protocol.writeU16(w, @intCast(grid.rows));

        try sendFrame(sock, @intFromEnum(Protocol.ClientMsg.create_terminal), ct_buf[0..ct_fbs.pos]);
    }
    // Read terminal_created response.
    {
        const header = (try Protocol.readFrameHeader(reader)) orelse
            return error.DaemonDisconnected;
        if (header.msg_type == @intFromEnum(Protocol.ServerMsg.terminal_created)) {
            self.terminal_id = try Protocol.readU32(reader);
        } else {
            // Unexpected response — skip the payload.
            try skipPayload(reader, header.payload_len);
            return error.UnexpectedResponse;
        }
    }

    // ---- attach_session ----
    {
        var payload_buf: [256]u8 = undefined;
        var payload_fbs = std.io.fixedBufferStream(&payload_buf);
        try Protocol.writeString(payload_fbs.writer(), self.session_name);
        const payload = payload_buf[0..payload_fbs.pos];

        try sendFrame(sock, @intFromEnum(Protocol.ClientMsg.attach_session), payload);
    }
    // Consume the attach response (may include screen_snapshot frames
    // followed by a different message type indicating end of snapshots).
    {
        while (true) {
            const header = (try Protocol.readFrameHeader(reader)) orelse break;
            if (header.msg_type != @intFromEnum(Protocol.ServerMsg.screen_snapshot)) {
                // Non-snapshot frame ends the snapshot stream.
                try skipPayload(reader, header.payload_len);
                break;
            }
            // Snapshot payload: terminal_id(4) + cols(2) + rows(2) + data
            var payload = try alloc.alloc(u8, header.payload_len);
            defer alloc.free(payload);
            try reader.readNoEof(payload);
            if (payload.len > 8) {
                io.processOutput(payload[8..]);
            }
        }
    }

    // ---- Start the background read thread ----
    const pipe = try posix.pipe2(.{ .CLOEXEC = true });
    errdefer {
        posix.close(pipe[0]);
        posix.close(pipe[1]);
    }

    td.backend = .{ .mux = .{
        .socket_fd = sock,
        .terminal_id = self.terminal_id,
        .read_thread_pipe = pipe,
    } };

    td.backend.mux.read_thread = try std.Thread.spawn(
        .{},
        readThreadMain,
        .{ sock, io, pipe[0] },
    );
}

pub fn threadExit(self: *Mux, td: *termio.Termio.ThreadData) void {
    _ = self;
    // ThreadData.deinit handles read thread cleanup via the quit pipe.
    _ = td;
}

pub fn focusGained(
    self: *Mux,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // No termios polling needed — the daemon owns the PTY.
}

pub fn resize(
    self: *Mux,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = screen_size;
    if (self.socket_fd == -1) return;

    // Payload: terminal_id (u32) + cols (u16) + rows (u16) = 8 bytes.
    var payload_buf: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&payload_buf);
    const w = fbs.writer();
    try Protocol.writeU32(w, self.terminal_id);
    try Protocol.writeU16(w, @intCast(grid_size.columns));
    try Protocol.writeU16(w, @intCast(grid_size.rows));

    sendFrame(self.socket_fd, @intFromEnum(Protocol.ClientMsg.resize), &payload_buf) catch |err| {
        log.warn("failed to send resize to daemon err={}", .{err});
    };
}

pub fn queueWrite(
    self: *Mux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;
    _ = linefeed; // Daemon receives raw bytes; line discipline is on the PTY.
    if (self.socket_fd == -1) return;

    // Payload: terminal_id (u32) + raw input bytes.
    const payload_len: u32 = 4 + @as(u32, @intCast(data.len));

    // Build the full frame: header (5 bytes) + payload.
    var header_buf: [Protocol.header_size]u8 = undefined;
    std.mem.writeInt(u32, header_buf[0..4], payload_len, .big);
    header_buf[4] = @intFromEnum(Protocol.ClientMsg.input);

    var tid_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &tid_buf, self.terminal_id, .big);

    const file: std.fs.File = .{ .handle = self.socket_fd };
    try file.writeAll(&header_buf);
    try file.writeAll(&tid_buf);
    try file.writeAll(data);
}

pub fn childExitedAbnormally(
    self: *Mux,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
    // The daemon owns process lifecycle; abnormal exits are reported
    // via the terminal_exited server message, not this callback.
}

// -----------------------------------------------------------------------
// Read thread — receives daemon frames and feeds output to the terminal
// -----------------------------------------------------------------------

fn readThreadMain(sock: posix.fd_t, io: *termio.Termio, quit_pipe: posix.fd_t) void {
    const reader = socketReader(sock);

    var pollfds: [2]posix.pollfd = .{
        .{ .fd = sock, .events = posix.POLL.IN, .revents = undefined },
        .{ .fd = quit_pipe, .events = posix.POLL.IN, .revents = undefined },
    };

    while (true) {
        // Wait for data on the socket or a quit signal.
        _ = posix.poll(&pollfds, -1) catch |err| {
            log.warn("mux read thread poll failed err={}", .{err});
            return;
        };

        // Quit pipe readable → time to exit.
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            log.info("mux read thread got quit signal", .{});
            return;
        }

        // Socket HUP/ERR → daemon disconnected.
        if (pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            log.info("daemon disconnected (HUP/ERR)", .{});
            return;
        }

        // Socket readable → read a frame.
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            const header = Protocol.readFrameHeader(reader) catch |err| {
                log.warn("mux read thread header error err={}", .{err});
                return;
            };
            const hdr = header orelse {
                log.info("daemon disconnected (EOF)", .{});
                return;
            };

            if (hdr.msg_type == @intFromEnum(Protocol.ServerMsg.output)) {
                // Output frame: 4-byte terminal_id prefix + raw terminal data.
                var buf: [65536]u8 = undefined;
                const to_read = @min(hdr.payload_len, buf.len);
                const n = reader.readAll(buf[0..to_read]) catch |err| {
                    log.warn("mux read thread data error err={}", .{err});
                    return;
                };
                // Skip the 4-byte terminal_id prefix, feed the rest.
                if (n > 4) {
                    @call(.always_inline, termio.Termio.processOutput, .{ io, buf[4..n] });
                }
                // If payload was larger than our buffer, drain the rest.
                skipBytes(reader, hdr.payload_len -| to_read);
            } else if (hdr.msg_type == @intFromEnum(Protocol.ServerMsg.terminal_exited)) {
                // Terminal's process exited on the daemon side.
                skipBytes(reader, hdr.payload_len);
                log.info("daemon reported terminal exited", .{});
                return;
            } else {
                // Unknown/unhandled message — skip payload.
                skipBytes(reader, hdr.payload_len);
            }
        }
    }
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

/// Build a frame in a stack buffer and write it to the socket fd in one go.
fn sendFrame(fd: posix.fd_t, msg_type: u8, payload: []const u8) !void {
    if (payload.len > Protocol.max_payload_size) return error.PayloadTooLarge;

    // Write the 5-byte header.
    var header_buf: [Protocol.header_size]u8 = undefined;
    std.mem.writeInt(u32, header_buf[0..4], @intCast(payload.len), .big);
    header_buf[4] = msg_type;

    const file: std.fs.File = .{ .handle = fd };
    try file.writeAll(&header_buf);
    if (payload.len > 0) {
        try file.writeAll(payload);
    }
}

/// Read and discard `n` bytes from the reader.
fn skipPayload(reader: anytype, n: u32) !void {
    var remaining: u32 = n;
    var buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        try reader.readNoEof(buf[0..chunk]);
        remaining -= @intCast(chunk);
    }
}

/// Best-effort skip of `n` bytes (ignores errors). Used in the read thread
/// where we can't propagate errors upward.
fn skipBytes(reader: anytype, n: u32) void {
    var remaining: u32 = n;
    var buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        reader.readNoEof(buf[0..chunk]) catch return;
        remaining -= @intCast(chunk);
    }
}
