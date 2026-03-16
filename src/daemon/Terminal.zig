/// Per-terminal state owned by the daemon process.
///
/// Each `Terminal` represents a single PTY/child-process pair. The daemon
/// keeps these alive across client attach/detach cycles. A fixed-size ring
/// buffer captures recent output so that a newly-attached client can receive
/// a screen snapshot without re-reading the scrollback from the child.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Terminal = @This();

// -----------------------------------------------------------------------
// Platform-specific ioctl constant for setting the terminal window size.
// See src/pty.zig for the canonical derivation.
// -----------------------------------------------------------------------
const TIOCSWINSZ: u32 = if (builtin.os.tag == .macos) 2148037735 else blk: {
    const c = @cImport(@cInclude("sys/ioctl.h"));
    break :blk c.TIOCSWINSZ;
};

const c_ioctl = @cImport(@cInclude("sys/ioctl.h"));

// -----------------------------------------------------------------------
// Simple circular buffer (std.RingBuffer does not exist in Zig 0.15.2)
// -----------------------------------------------------------------------

/// A fixed-capacity circular byte buffer. New writes silently overwrite the
/// oldest data when the buffer is full (no allocation, no error).
pub const RingBuffer = struct {
    buf: []u8,
    /// Index of the next byte to write (wraps around).
    write_pos: usize = 0,
    /// Number of valid bytes currently stored (capped at buf.len).
    len: usize = 0,

    pub fn init(alloc: Allocator, capacity: usize) Allocator.Error!RingBuffer {
        const buf = try alloc.alloc(u8, capacity);
        return .{ .buf = buf };
    }

    pub fn deinit(self: *RingBuffer, alloc: Allocator) void {
        alloc.free(self.buf);
        self.buf = &.{};
        self.write_pos = 0;
        self.len = 0;
    }

    /// Append `data` to the ring, overwriting oldest bytes if necessary.
    pub fn write(self: *RingBuffer, data: []const u8) void {
        if (self.buf.len == 0) return;

        for (data) |byte| {
            self.buf[self.write_pos] = byte;
            self.write_pos = (self.write_pos + 1) % self.buf.len;
            if (self.len < self.buf.len) {
                self.len += 1;
            }
        }
    }

    /// Return buffered content as up to two contiguous slices (the ring may
    /// wrap around the underlying array). The first slice is the older data.
    pub fn readable(self: *const RingBuffer) struct { []const u8, []const u8 } {
        if (self.len == 0) return .{ &.{}, &.{} };

        if (self.len < self.buf.len) {
            // Haven't wrapped yet — all data sits before write_pos.
            const start = self.write_pos - self.len;
            return .{ self.buf[start..self.write_pos], &.{} };
        }

        // Buffer is full and has wrapped. write_pos points at the oldest byte.
        return .{
            self.buf[self.write_pos..],
            self.buf[0..self.write_pos],
        };
    }
};

// -----------------------------------------------------------------------
// Terminal fields
// -----------------------------------------------------------------------

/// Default output ring buffer size: 1 MiB.
const default_buffer_size: usize = 1024 * 1024;

/// Unique terminal identifier (assigned by the daemon).
id: u32,

/// Master side of the PTY.
pty_fd: posix.fd_t,

/// PID of the child process running in the PTY.
child_pid: posix.pid_t,

/// Current terminal dimensions.
cols: u16,
rows: u16,

/// Command that was spawned (owned copy).
command: []const u8,

/// Working directory at spawn time (owned copy).
cwd: []const u8,

/// Whether the child process has exited.
exited: bool = false,

/// Exit code of the child process (valid only when `exited` is true).
exit_code: i32 = 0,

/// Recent output ring buffer — captures the tail of child output so that
/// attaching clients can get a screen snapshot.
output_buffer: RingBuffer,

/// Allocator used for all owned memory in this struct.
alloc: Allocator,

// -----------------------------------------------------------------------
// Options struct passed to init
// -----------------------------------------------------------------------

pub const Options = struct {
    id: u32,
    pty_fd: posix.fd_t,
    child_pid: posix.pid_t,
    cols: u16 = 80,
    rows: u16 = 24,
    command: []const u8,
    cwd: []const u8,
    buffer_size: usize = default_buffer_size,
};

// -----------------------------------------------------------------------
// Lifecycle
// -----------------------------------------------------------------------

/// Create a new Terminal. The caller retains no ownership of the strings in
/// `opts`; this function duplicates them.
pub fn init(alloc: Allocator, opts: Options) Allocator.Error!Terminal {
    const cmd = try alloc.dupe(u8, opts.command);
    errdefer alloc.free(cmd);

    const cwd = try alloc.dupe(u8, opts.cwd);
    errdefer alloc.free(cwd);

    const ring = try RingBuffer.init(alloc, opts.buffer_size);

    return .{
        .id = opts.id,
        .pty_fd = opts.pty_fd,
        .child_pid = opts.child_pid,
        .cols = opts.cols,
        .rows = opts.rows,
        .command = cmd,
        .cwd = cwd,
        .output_buffer = ring,
        .alloc = alloc,
    };
}

/// Tear down the terminal: kill the child if still running, close the PTY
/// fd, and free all owned memory.
pub fn deinit(self: *Terminal) void {
    // Send SIGTERM to the child if it hasn't exited yet.
    if (!self.exited) {
        posix.kill(self.child_pid, posix.SIG.TERM) catch {};
    }

    // Close the master PTY fd. Use the raw syscall to avoid the Zig
    // debug-mode assertion that panics on EBADF (which is harmless here
    // — it just means the fd was already closed or never valid).
    _ = std.c.close(self.pty_fd);

    // Free owned strings and ring buffer.
    self.alloc.free(self.command);
    self.alloc.free(self.cwd);
    self.output_buffer.deinit(self.alloc);
}

// -----------------------------------------------------------------------
// Operations
// -----------------------------------------------------------------------

/// Record output received from the child process into the ring buffer.
pub fn recordOutput(self: *Terminal, data: []const u8) void {
    self.output_buffer.write(data);
}

/// Mark the child process as exited with the given exit code.
pub fn markExited(self: *Terminal, code: i32) void {
    self.exited = true;
    self.exit_code = code;
}

/// Resize the PTY to the given dimensions via ioctl(TIOCSWINSZ).
pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
    // Redeclare the winsize struct matching the kernel layout (see src/pty.zig).
    const ws: extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    } = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    if (c_ioctl.ioctl(self.pty_fd, TIOCSWINSZ, @intFromPtr(&ws)) < 0) {
        return error.IoctlFailed;
    }

    self.cols = cols;
    self.rows = rows;
}

/// Return buffered output as two slices (the ring may wrap). Concatenate
/// them for the full history. The first slice is the older data.
pub fn getBufferedOutput(self: *const Terminal) struct { []const u8, []const u8 } {
    return self.output_buffer.readable();
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "RingBuffer: basic write and read" {
    const alloc = std.testing.allocator;
    var ring = try RingBuffer.init(alloc, 8);
    defer ring.deinit(alloc);

    ring.write("hello");
    const r = ring.readable();
    try std.testing.expectEqualStrings("hello", r[0]);
    try std.testing.expectEqualStrings("", r[1]);
}

test "RingBuffer: wrap-around overwrites oldest" {
    const alloc = std.testing.allocator;
    var ring = try RingBuffer.init(alloc, 4);
    defer ring.deinit(alloc);

    ring.write("abcdef"); // capacity 4, writes 6 bytes → keeps "cdef"
    const r = ring.readable();
    // Older portion + newer portion should concatenate to "cdef".
    var combined: [4]u8 = undefined;
    @memcpy(combined[0..r[0].len], r[0]);
    @memcpy(combined[r[0].len..][0..r[1].len], r[1]);
    try std.testing.expectEqualStrings("cdef", &combined);
}

test "RingBuffer: empty buffer returns empty slices" {
    const alloc = std.testing.allocator;
    var ring = try RingBuffer.init(alloc, 8);
    defer ring.deinit(alloc);

    const r = ring.readable();
    try std.testing.expectEqual(@as(usize, 0), r[0].len);
    try std.testing.expectEqual(@as(usize, 0), r[1].len);
}
