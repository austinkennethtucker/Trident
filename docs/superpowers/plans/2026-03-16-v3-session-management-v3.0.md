# v3.0 Session Management MVP — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a daemon that owns PTY sessions, a wire protocol for GUI↔daemon communication, and CLI commands for attach/detach — enabling `trident --session work` to persist terminal processes across GUI quit/restart.

**Architecture:** A new `src/daemon/` package implements the background PTY server. A binary wire protocol over Unix socket connects the GUI. A new `Mux` backend variant in `src/termio/` replaces `Exec` when in session mode. CLI commands use the existing `+action` pattern.

**Tech Stack:** Zig 0.15.2+, xev (event loop), POSIX sockets, posix_spawn for daemonization.

**Spec:** `docs/superpowers/specs/2026-03-16-v3-session-management-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `src/daemon.zig` | Package root — re-exports daemon types |
| `src/daemon/Protocol.zig` | Wire protocol: message types, frame encode/decode |
| `src/daemon/Session.zig` | Session state: named session holding terminal entries |
| `src/daemon/Terminal.zig` | Per-terminal state in daemon: PTY fd, screen tracker, metadata |
| `src/daemon/Server.zig` | Socket listener, client connection handling, message dispatch |
| `src/daemon/Daemon.zig` | Top-level daemon: owns Server + Sessions, main event loop |
| `src/termio/Mux.zig` | Mux backend: socket-based I/O source replacing Exec for session mode |
| `src/cli/attach.zig` | `+attach` CLI command |
| `src/cli/detach.zig` | `+detach` CLI command |
| `src/cli/list_sessions.zig` | `+list-sessions` CLI command |
| `src/cli/kill_session.zig` | `+kill-session` CLI command |

### Modified Files

| File | Change |
|------|--------|
| `src/termio/backend.zig` | Add `mux` variant to `Kind`, `Backend`, `ThreadData`, `Config` unions |
| `src/cli/ghostty.zig` | Add new action enum variants and routing |
| `src/cli.zig` | Add imports for new CLI modules |
| `src/main_ghostty.zig` | Handle `--session` flag, detect `--daemon` mode |
| `src/Surface.zig` | Pass session mode info through to Termio init |
| `src/config/Config.zig` | Add `session-restore` config field |

---

## Chunk 1: Wire Protocol

The protocol is the foundation — both daemon and client depend on it. It has no external dependencies and is fully unit-testable.

### Task 1: Protocol message types and frame format

**Files:**
- Create: `src/daemon/Protocol.zig`
- Create: `src/daemon.zig`

- [ ] **Step 1: Create the daemon package root**

```zig
// src/daemon.zig
pub const Protocol = @import("daemon/Protocol.zig");
```

- [ ] **Step 2: Define message types and frame encoding**

Create `src/daemon/Protocol.zig` with:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.daemon_protocol);

/// Maximum frame payload size (16 MiB).
pub const max_payload_size: u32 = 16 * 1024 * 1024;

/// Frame header: 4-byte big-endian payload length + 1-byte message type.
pub const header_size: usize = 5;

/// Client → Daemon message types.
pub const ClientMsg = enum(u8) {
    create_session = 0x01,
    create_terminal = 0x02,
    attach_session = 0x03,
    detach_session = 0x04,
    input = 0x05,
    resize = 0x06,
    close_terminal = 0x07,
    list_sessions = 0x08,
    destroy_session = 0x09,
};

/// Daemon → Client message types.
pub const ServerMsg = enum(u8) {
    output = 0x81,
    session_info = 0x82,
    terminal_created = 0x83,
    terminal_exited = 0x84,
    @"error" = 0x85,
    screen_snapshot = 0x86,
    session_layout = 0x87,
};

/// A length-prefixed string in the wire format.
pub const WireString = struct {
    len: u16,
    data: []const u8,
};

// ─── Frame Encoding ─────────────────────────────────────────

/// Write a frame header + payload to the writer.
/// Frame format: [4 bytes: payload len (big-endian u32)][1 byte: msg type][payload]
pub fn writeFrame(writer: anytype, msg_type: u8, payload: []const u8) !void {
    const len: u32 = @intCast(payload.len);
    try writer.writeInt(u32, len, .big);
    try writer.writeByte(msg_type);
    try writer.writeAll(payload);
}

/// Encode a length-prefixed string into the buffer writer.
pub fn writeString(writer: anytype, s: []const u8) !void {
    const len: u16 = std.math.cast(u16, s.len) orelse return error.StringTooLong;
    try writer.writeInt(u16, len, .big);
    try writer.writeAll(s);
}

/// Encode a u32 value.
pub fn writeU32(writer: anytype, val: u32) !void {
    try writer.writeInt(u32, val, .big);
}

/// Encode a u16 value.
pub fn writeU16(writer: anytype, val: u16) !void {
    try writer.writeInt(u16, val, .big);
}

/// Encode an i32 value.
pub fn writeI32(writer: anytype, val: i32) !void {
    try writer.writeInt(i32, val, .big);
}

// ─── Frame Decoding ─────────────────────────────────────────

/// Result of reading a frame header.
pub const FrameHeader = struct {
    payload_len: u32,
    msg_type: u8,
};

/// Read a frame header from the reader.
/// Returns null if the reader is at EOF (clean disconnect).
pub fn readFrameHeader(reader: anytype) !?FrameHeader {
    const len = reader.readInt(u32, .big) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    if (len > max_payload_size) return error.FrameTooLarge;
    const msg_type = try reader.readByte();
    return .{ .payload_len = len, .msg_type = msg_type };
}

/// Read a length-prefixed string. Caller owns the returned slice.
pub fn readString(alloc: Allocator, reader: anytype) ![]const u8 {
    const len = try reader.readInt(u16, .big);
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    const n = try reader.readAll(buf);
    if (n != len) return error.UnexpectedEof;
    return buf;
}

/// Read a u32 value.
pub fn readU32(reader: anytype) !u32 {
    return reader.readInt(u32, .big);
}

/// Read a u16 value.
pub fn readU16(reader: anytype) !u16 {
    return reader.readInt(u16, .big);
}

/// Read an i32 value.
pub fn readI32(reader: anytype) !i32 {
    return reader.readInt(i32, .big);
}

// ─── Convenience Builders ───────────────────────────────────

/// Build a `create_session` frame. Caller owns returned buffer.
pub fn buildCreateSession(alloc: Allocator, name: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    const writer = buf.writer();
    try writeString(writer, name);
    // Write frame
    var frame = std.ArrayList(u8).init(alloc);
    errdefer frame.deinit();
    const fw = frame.writer();
    try writeFrame(fw, @intFromEnum(ClientMsg.create_session), buf.items);
    buf.deinit();
    return frame.toOwnedSlice();
}

/// Build a `list_sessions` frame (empty payload).
pub fn buildListSessions(alloc: Allocator) ![]const u8 {
    var frame = std.ArrayList(u8).init(alloc);
    const fw = frame.writer();
    try writeFrame(fw, @intFromEnum(ClientMsg.list_sessions), &.{});
    return frame.toOwnedSlice();
}

/// Build an `input` frame.
pub fn buildInput(alloc: Allocator, terminal_id: u32, data: []const u8) ![]const u8 {
    var payload = std.ArrayList(u8).init(alloc);
    errdefer payload.deinit();
    const pw = payload.writer();
    try writeU32(pw, terminal_id);
    try pw.writeAll(data);

    var frame = std.ArrayList(u8).init(alloc);
    errdefer frame.deinit();
    const fw = frame.writer();
    try writeFrame(fw, @intFromEnum(ClientMsg.input), payload.items);
    payload.deinit();
    return frame.toOwnedSlice();
}

/// Build a `resize` frame.
pub fn buildResize(alloc: Allocator, terminal_id: u32, cols: u16, rows: u16) ![]const u8 {
    var payload = std.ArrayList(u8).init(alloc);
    errdefer payload.deinit();
    const pw = payload.writer();
    try writeU32(pw, terminal_id);
    try writeU16(pw, cols);
    try writeU16(pw, rows);

    var frame = std.ArrayList(u8).init(alloc);
    errdefer frame.deinit();
    const fw = frame.writer();
    try writeFrame(fw, @intFromEnum(ClientMsg.resize), payload.items);
    payload.deinit();
    return frame.toOwnedSlice();
}

// ─── Tests ──────────────────────────────────────────────────

test "writeFrame and readFrameHeader roundtrip" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const writer = buf.writer();

    try writeFrame(writer, @intFromEnum(ClientMsg.list_sessions), &.{});

    var fbs = std.io.fixedBufferStream(buf.items);
    const header = (try readFrameHeader(fbs.reader())).?;
    try std.testing.expectEqual(@as(u32, 0), header.payload_len);
    try std.testing.expectEqual(@intFromEnum(ClientMsg.list_sessions), header.msg_type);
}

test "writeString and readString roundtrip" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    try writeString(buf.writer(), "work");

    var fbs = std.io.fixedBufferStream(buf.items);
    const str = try readString(alloc, fbs.reader());
    defer alloc.free(str);
    try std.testing.expectEqualStrings("work", str);
}

test "readFrameHeader returns null on EOF" {
    var fbs = std.io.fixedBufferStream(&[_]u8{});
    const header = try readFrameHeader(fbs.reader());
    try std.testing.expect(header == null);
}

test "readFrameHeader rejects oversized frame" {
    var buf: [5]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], max_payload_size + 1, .big);
    buf[4] = 0x01;
    var fbs = std.io.fixedBufferStream(&buf);
    const result = readFrameHeader(fbs.reader());
    try std.testing.expectError(error.FrameTooLarge, result);
}

test "writeFrame with payload roundtrip" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const payload = "hello";
    try writeFrame(buf.writer(), @intFromEnum(ServerMsg.output), payload);

    var fbs = std.io.fixedBufferStream(buf.items);
    const reader = fbs.reader();
    const header = (try readFrameHeader(reader)).?;
    try std.testing.expectEqual(@as(u32, 5), header.payload_len);
    try std.testing.expectEqual(@intFromEnum(ServerMsg.output), header.msg_type);

    var payload_buf: [5]u8 = undefined;
    const n = try reader.readAll(&payload_buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", &payload_buf);
}
```

- [ ] **Step 3: Verify it compiles**

```bash
zig build -Demit-macos-app=false 2>&1 | head -20
```

Expected: Clean build (new files don't need to be wired into the build unless imported by existing code)

Actually, since these are new files not imported by anything yet, we need to verify with direct compilation:

```bash
zig test src/daemon/Protocol.zig 2>&1 | tail -10
```

Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add -f src/daemon.zig src/daemon/Protocol.zig
git commit -m "feat(daemon): add wire protocol message types and frame encode/decode"
```

---

## Chunk 2: Daemon Session & Terminal State

### Task 2: Terminal state container

**Files:**
- Create: `src/daemon/Terminal.zig`

The daemon-side terminal holds the PTY fd, metadata, and a screen content tracker for snapshot-on-attach.

- [ ] **Step 1: Create Terminal.zig**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const log = std.log.scoped(.daemon_terminal);

const Terminal = @This();

/// Daemon-assigned unique ID.
id: u32,

/// The PTY master file descriptor. Owned by this Terminal.
pty_fd: posix.fd_t,

/// Child process PID.
child_pid: posix.pid_t,

/// Current terminal dimensions.
cols: u16,
rows: u16,

/// Original command that spawned this terminal.
command: []const u8,

/// Current working directory (updated via OSC 7 if available).
cwd: []const u8,

/// Whether the child process has exited.
exited: bool = false,

/// Exit code (valid only if exited == true).
exit_code: i32 = 0,

/// Circular buffer of recent PTY output (raw bytes).
/// Used for screen state reconstruction on attach.
output_buffer: std.RingBuffer,

/// Allocator used for this terminal's owned memory.
alloc: Allocator,

pub fn init(alloc: Allocator, opts: struct {
    id: u32,
    pty_fd: posix.fd_t,
    child_pid: posix.pid_t,
    cols: u16,
    rows: u16,
    command: []const u8,
    cwd: []const u8,
    buffer_size: usize,
}) !Terminal {
    const command = try alloc.dupe(u8, opts.command);
    errdefer alloc.free(command);
    const cwd = try alloc.dupe(u8, opts.cwd);
    errdefer alloc.free(cwd);
    const output_buffer = try std.RingBuffer.init(alloc, opts.buffer_size);
    errdefer output_buffer.deinit(alloc);

    return .{
        .id = opts.id,
        .pty_fd = opts.pty_fd,
        .child_pid = opts.child_pid,
        .cols = opts.cols,
        .rows = opts.rows,
        .command = command,
        .cwd = cwd,
        .output_buffer = output_buffer,
        .alloc = alloc,
    };
}

pub fn deinit(self: *Terminal) void {
    // Kill child if still running
    if (!self.exited) {
        posix.kill(self.child_pid, posix.SIG.TERM) catch {};
    }
    // Close PTY fd
    posix.close(self.pty_fd);
    self.output_buffer.deinit(self.alloc);
    self.alloc.free(self.command);
    self.alloc.free(self.cwd);
}

/// Record output bytes from the PTY (called on every read).
pub fn recordOutput(self: *Terminal, data: []const u8) void {
    self.output_buffer.writeSlice(data) catch {
        // Buffer full — overwrite oldest data (ring buffer wraps)
    };
}

/// Mark child as exited.
pub fn markExited(self: *Terminal, code: i32) void {
    self.exited = true;
    self.exit_code = code;
}

/// Resize the PTY.
pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
    self.cols = cols;
    self.rows = rows;
    // ioctl TIOCSWINSZ
    const ws = posix.winsize{
        .ws_col = cols,
        .ws_row = rows,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const TIOCSWINSZ = if (@hasDecl(posix.T, "IOCSWINSZ")) posix.T.IOCSWINSZ else 0x5414;
    _ = posix.system.ioctl(self.pty_fd, TIOCSWINSZ, @intFromPtr(&ws));
}

/// Get buffered output for snapshot sync. Returns a slice view of the ring buffer.
pub fn getBufferedOutput(self: *const Terminal) []const u8 {
    return self.output_buffer.readableSlice(0);
}
```

- [ ] **Step 2: Verify it compiles**

```bash
zig build -Demit-macos-app=false 2>&1 | head -20
```

- [ ] **Step 3: Commit**

```bash
git add -f src/daemon/Terminal.zig
git commit -m "feat(daemon): add Terminal state container with PTY ownership and output buffer"
```

---

### Task 3: Session state container

**Files:**
- Create: `src/daemon/Session.zig`
- Modify: `src/daemon.zig`

- [ ] **Step 1: Create Session.zig**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

const Terminal = @import("Terminal.zig");

const log = std.log.scoped(.daemon_session);

const Session = @This();

/// Session name (e.g. "work", "ops").
name: []const u8,

/// Terminals in this session, keyed by terminal ID.
terminals: std.AutoHashMap(u32, *Terminal),

/// Socket fd of the attached client (null if detached).
attached_client: ?std.posix.fd_t = null,

/// When this session was created.
created_at: i64,

/// Allocator for session-owned memory.
alloc: Allocator,

pub fn init(alloc: Allocator, name: []const u8) !Session {
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);

    return .{
        .name = owned_name,
        .terminals = std.AutoHashMap(u32, *Terminal).init(alloc),
        .created_at = std.time.timestamp(),
        .alloc = alloc,
    };
}

pub fn deinit(self: *Session) void {
    // Destroy all terminals (kills processes, closes PTYs)
    var it = self.terminals.valueIterator();
    while (it.next()) |term_ptr| {
        term_ptr.*.deinit();
        self.alloc.destroy(term_ptr.*);
    }
    self.terminals.deinit();
    self.alloc.free(self.name);
}

/// Add a terminal to this session. Takes ownership.
pub fn addTerminal(self: *Session, terminal: *Terminal) !void {
    try self.terminals.put(terminal.id, terminal);
}

/// Remove and destroy a terminal by ID.
pub fn removeTerminal(self: *Session, id: u32) void {
    if (self.terminals.fetchRemove(id)) |entry| {
        entry.value.deinit();
        self.alloc.destroy(entry.value);
    }
}

/// Check if a client is currently attached.
pub fn isAttached(self: *const Session) bool {
    return self.attached_client != null;
}

/// Attach a client. Returns error if already attached.
pub fn attach(self: *Session, client_fd: std.posix.fd_t) !void {
    if (self.attached_client != null) return error.SessionAlreadyAttached;
    self.attached_client = client_fd;
}

/// Detach the current client.
pub fn detach(self: *Session) void {
    self.attached_client = null;
}

/// Detach if the given client fd is the attached one (for cleanup on disconnect).
pub fn detachIfClient(self: *Session, client_fd: std.posix.fd_t) void {
    if (self.attached_client == client_fd) {
        self.attached_client = null;
    }
}

pub fn terminalCount(self: *const Session) usize {
    return self.terminals.count();
}
```

- [ ] **Step 2: Update daemon.zig re-exports**

```zig
// src/daemon.zig
pub const Protocol = @import("daemon/Protocol.zig");
pub const Session = @import("daemon/Session.zig");
pub const Terminal = @import("daemon/Terminal.zig");
```

- [ ] **Step 3: Verify it compiles**

```bash
zig build -Demit-macos-app=false 2>&1 | head -20
```

- [ ] **Step 4: Commit**

```bash
git add -f src/daemon/Session.zig src/daemon.zig
git commit -m "feat(daemon): add Session state container with terminal management and client tracking"
```

---

## Chunk 3: CLI Commands

Add the CLI commands before the daemon implementation — they're simpler and establish the user-facing interface.

### Task 4: Add action enum variants

**Files:**
- Modify: `src/cli/ghostty.zig`
- Modify: `src/cli.zig`

- [ ] **Step 1: Read current ghostty.zig action enum and routing**

Read `src/cli/ghostty.zig` to find the Action enum, `options()`, and `runMain()`.

- [ ] **Step 2: Add new action variants to the enum**

In the `Action` enum, add after the last existing variant:

```zig
    @"attach",
    @"detach",
    @"list-sessions",
    @"kill-session",
```

- [ ] **Step 3: Add imports, options routing, and runMain routing**

Add imports at the top of `ghostty.zig`:
```zig
const attach_cmd = @import("attach.zig");
const detach_cmd = @import("detach.zig");
const list_sessions = @import("list_sessions.zig");
const kill_session = @import("kill_session.zig");
```

Add to the `options()` comptime switch:
```zig
.@"attach" => attach_cmd.Options,
.@"detach" => detach_cmd.Options,
.@"list-sessions" => list_sessions.Options,
.@"kill-session" => kill_session.Options,
```

Add to the `runMain()` switch:
```zig
.@"attach" => try attach_cmd.run(alloc),
.@"detach" => try detach_cmd.run(alloc),
.@"list-sessions" => try list_sessions.run(alloc),
.@"kill-session" => try kill_session.run(alloc),
```

- [ ] **Step 4: Create stub CLI command files**

Create `src/cli/attach.zig`:
```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;

pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    session: ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |*arena| arena.deinit();
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Attach to an existing Trident daemon session.
///
/// If `--session` is not specified, attaches to the most recently used session.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("attach: not yet implemented (session={?s})\n", .{opts.session});
    return 1;
}
```

Create `src/cli/detach.zig`:
```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;

pub const Options = struct {
    pub fn deinit(self: *Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Detach from the current Trident daemon session.
///
/// The session continues running in the daemon. Reattach with `+attach`.
pub fn run(alloc: Allocator) !u8 {
    _ = alloc;
    const stdout = std.io.getStdOut().writer();
    try stdout.print("detach: not yet implemented\n", .{});
    return 1;
}
```

Create `src/cli/list_sessions.zig`:
```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;

pub const Options = struct {
    pub fn deinit(self: *Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// List active Trident daemon sessions.
///
/// Connects to the daemon and prints session names, terminal counts, and uptime.
pub fn run(alloc: Allocator) !u8 {
    _ = alloc;
    const stdout = std.io.getStdOut().writer();
    try stdout.print("list-sessions: not yet implemented\n", .{});
    return 1;
}
```

Create `src/cli/kill_session.zig`:
```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;

pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    session: ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |*arena| arena.deinit();
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Kill a Trident daemon session and all its terminals.
///
/// The `--session` flag specifies which session to kill.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("kill-session: not yet implemented (session={?s})\n", .{opts.session});
    return 1;
}
```

- [ ] **Step 5: Verify it compiles**

```bash
zig build -Demit-macos-app=false 2>&1 | head -20
```

- [ ] **Step 6: Test the stubs**

```bash
zig build run -- +list-sessions 2>&1
zig build run -- +attach --help 2>&1
```

Expected: Stub output / help text

- [ ] **Step 7: Commit**

```bash
git add src/cli/attach.zig src/cli/detach.zig src/cli/list_sessions.zig src/cli/kill_session.zig src/cli/ghostty.zig
git commit -m "feat(cli): add stub commands for attach, detach, list-sessions, kill-session"
```

---

## Chunk 4: Daemon Server

### Task 5: Socket listener and daemon main loop

**Files:**
- Create: `src/daemon/Server.zig`
- Create: `src/daemon/Daemon.zig`
- Modify: `src/daemon.zig`

This is the largest task. The daemon listens on a Unix socket, accepts client connections, reads frames, and dispatches to session management.

- [ ] **Step 1: Create Server.zig**

The server manages the listening socket and connected clients. Read `src/daemon/Protocol.zig` for the wire format before implementing.

Server.zig should:
- `init()`: create and bind the Unix domain socket, listen
- `accept()`: accept a new client connection
- `readFrame()`: read one protocol frame from a client fd
- `writeFrame()`: write one protocol frame to a client fd
- `deinit()`: close listening socket, remove socket file

Socket path: on macOS use `$TMPDIR/trident-daemon.sock`, on Linux use `$XDG_RUNTIME_DIR/trident/daemon.sock` with fallback to `/tmp/trident-$UID/daemon.sock`.

Include a `pub fn socketPath(alloc: Allocator) ![]const u8` helper that resolves the platform-specific path.

- [ ] **Step 2: Create Daemon.zig**

The daemon owns the Server and a `SessionMap` (`std.StringHashMap(*Session)`). Its main loop:

1. Poll the listening socket + all client fds (using `std.posix.poll`)
2. Accept new clients
3. Read frames from clients
4. Dispatch based on message type:
   - `create_session` → create new Session, respond with session_info
   - `create_terminal` → fork/exec PTY in session, respond with terminal_created
   - `attach_session` → mark client as attached, send screen_snapshot for each terminal
   - `detach_session` → mark client as detached
   - `input` → write bytes to terminal's PTY fd
   - `resize` → ioctl TIOCSWINSZ on terminal's PTY fd
   - `close_terminal` → kill process, remove from session
   - `list_sessions` → respond with session_info
   - `destroy_session` → destroy session and all terminals
5. Poll PTY fds for output → read, buffer in Terminal, forward as `output` frames to attached client

Daemon.zig should have:
- `pub fn init(alloc: Allocator) !Daemon`
- `pub fn deinit(self: *Daemon) void`
- `pub fn run(self: *Daemon) !void` — main event loop (blocks until stopped)
- `pub fn stop(self: *Daemon) void` — signal the loop to exit

- [ ] **Step 3: Add daemon entry point to main_ghostty.zig**

In `main_ghostty.zig`, before the action detection, check for `--daemon`:

```zig
// Check if we're being asked to run as a daemon
for (std.os.argv[1..]) |arg| {
    if (std.mem.eql(u8, std.mem.span(arg), "--daemon")) {
        const daemon_mod = @import("daemon.zig");
        var daemon = try daemon_mod.Daemon.init(alloc);
        defer daemon.deinit();
        try daemon.run();
        return;
    }
}
```

- [ ] **Step 4: Update daemon.zig re-exports**

```zig
pub const Protocol = @import("daemon/Protocol.zig");
pub const Session = @import("daemon/Session.zig");
pub const Terminal = @import("daemon/Terminal.zig");
pub const Server = @import("daemon/Server.zig");
pub const Daemon = @import("daemon/Daemon.zig");
```

- [ ] **Step 5: Verify it compiles**

```bash
zig build -Demit-macos-app=false 2>&1 | head -20
```

- [ ] **Step 6: Manual test — start daemon**

```bash
zig build run -- --daemon &
ls $TMPDIR/trident-daemon.sock
kill %1
```

Expected: Socket file appears, daemon runs until killed

- [ ] **Step 7: Commit**

```bash
git add -f src/daemon/Server.zig src/daemon/Daemon.zig src/daemon.zig src/main_ghostty.zig
git commit -m "feat(daemon): add socket server and daemon main loop with session dispatch"
```

---

## Chunk 5: Wire CLI Commands to Daemon

### Task 6: Implement list-sessions command

**Files:**
- Modify: `src/cli/list_sessions.zig`

- [ ] **Step 1: Implement the command**

Replace the stub with real daemon communication:

1. Resolve socket path using `Server.socketPath()`
2. Connect to the Unix socket
3. Send a `list_sessions` frame
4. Read the `session_info` response
5. Print sessions to stdout

- [ ] **Step 2: Test manually**

```bash
# Terminal 1: start daemon
zig build run -- --daemon

# Terminal 2: list sessions (should show empty)
zig build run -- +list-sessions
```

- [ ] **Step 3: Commit**

```bash
git add src/cli/list_sessions.zig
git commit -m "feat(cli): implement list-sessions command with daemon communication"
```

### Task 7: Implement kill-session command

**Files:**
- Modify: `src/cli/kill_session.zig`

Same pattern as list-sessions: connect to socket, send `destroy_session` frame, read response.

- [ ] **Step 1: Implement the command**
- [ ] **Step 2: Test manually**
- [ ] **Step 3: Commit**

```bash
git add src/cli/kill_session.zig
git commit -m "feat(cli): implement kill-session command"
```

---

## Chunk 6: Mux Backend + Session Mode

### Task 8: Add mux variant to Termio backend

**Files:**
- Create: `src/termio/Mux.zig`
- Modify: `src/termio/backend.zig`

- [ ] **Step 1: Create Mux.zig skeleton**

`Mux.zig` follows the same pattern as `Exec.zig` but communicates with the daemon:

```zig
pub const Mux = @This();

pub const Config = struct {
    session_name: []const u8,
    socket_path: []const u8,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    cols: u16,
    rows: u16,
};

pub const ThreadData = struct {
    socket_fd: std.posix.fd_t,
    terminal_id: u32,
    // xev integration for reading from socket
};

pub fn init(alloc: Allocator, cfg: Config) !Mux { ... }
pub fn deinit(self: *Mux) void { ... }
pub fn initTerminal(self: *Mux, t: *terminal.Terminal) void { ... }
pub fn threadEnter(self: *Mux, alloc, io, td) !void { ... }
pub fn threadExit(self: *Mux, td: *ThreadData) void { ... }
pub fn focusGained(self: *Mux, td, focused) !void { ... }
pub fn resize(self: *Mux, grid_size, screen_size) !void { ... }
pub fn queueWrite(self: *Mux, alloc, td, data, linefeed) !void { ... }
pub fn childExitedAbnormally(gpa, t, exit_code, runtime_ms) !void { ... }
```

Key differences from Exec:
- `threadEnter`: connects to daemon socket, sends `create_terminal`, receives terminal_id. Starts read loop on socket fd (event-driven via xev, not a blocking read thread).
- `queueWrite`: encodes `input` frame and writes to socket
- `resize`: encodes `resize` frame and writes to socket
- No `termiosTimer` (daemon owns the PTY)
- No child process watcher (daemon sends `terminal_exited` frame)

- [ ] **Step 2: Add mux variant to backend.zig**

Add `mux` to all four unions:

```zig
pub const Kind = enum { exec, mux };
pub const Config = union(Kind) { exec: termio.Exec.Config, mux: termio.Mux.Config };
pub const Backend = union(Kind) { exec: termio.Exec, mux: termio.Mux, ... };
pub const ThreadData = union(Kind) { exec: termio.Exec.ThreadData, mux: termio.Mux.ThreadData, ... };
```

Add dispatch for `mux` in every method (resize, queueWrite, threadEnter, etc.).

- [ ] **Step 3: Wire session mode into Surface.zig**

In `Surface.init()`, check if the apprt passed a session name. If so, create `Mux.Config` instead of `Exec.Config`:

```zig
const io_backend: termio.backend.Config = if (session_name) |name|
    .{ .mux = .{
        .session_name = name,
        .socket_path = try daemon.Server.socketPath(alloc),
        .cols = @intCast(size.grid.columns),
        .rows = @intCast(size.grid.rows),
    } }
else
    .{ .exec = .{ ... } };  // existing Exec config
```

- [ ] **Step 4: Pass --session flag through apprt**

In `main_ghostty.zig`, detect `--session <name>` flag before creating the app, pass it through apprt initialization so surfaces know to use mux mode.

- [ ] **Step 5: Verify it compiles**

```bash
zig build -Demit-macos-app=false 2>&1 | head -20
```

- [ ] **Step 6: Commit**

```bash
git add -f src/termio/Mux.zig src/termio/backend.zig src/Surface.zig src/main_ghostty.zig
git commit -m "feat(termio): add Mux backend variant for daemon session mode"
```

---

## Chunk 7: End-to-End Integration

### Task 9: Auto-start daemon from --session flag

**Files:**
- Modify: `src/main_ghostty.zig`

- [ ] **Step 1: Implement auto-start**

When `--session <name>` is specified and no daemon socket exists:
1. Use `posix_spawn` to launch `trident --daemon`
2. Poll for socket file (max 2s, 50ms intervals)
3. Connect and proceed with GUI launch

- [ ] **Step 2: Commit**

```bash
git add src/main_ghostty.zig
git commit -m "feat(session): auto-start daemon on first --session use via posix_spawn"
```

### Task 10: Implement attach and detach commands

**Files:**
- Modify: `src/cli/attach.zig`
- Modify: `src/cli/detach.zig`

- [ ] **Step 1: Implement attach**

`+attach` connects to the daemon, sends `attach_session`, then launches the GUI in session mode (same as `--session` but for an existing session).

- [ ] **Step 2: Implement detach**

`+detach` sends a message to the running GUI (via the existing app mailbox or a separate mechanism) to close the session window and send `detach_session` to the daemon.

- [ ] **Step 3: Add detach keybind action**

Add `detach_session` to `src/input/Binding.zig` Action enum, scoped to surface. Handler in `Surface.zig` sends `detach_session` to daemon and closes the window.

- [ ] **Step 4: End-to-end test**

```bash
# Start a session
zig build run -- --session work

# In the session terminal, start something long-running
# sleep 3600

# Detach (close window via keybind or close button)

# Verify daemon still has the session
zig build run -- +list-sessions
# Expected: "work" with 1 terminal

# Reattach
zig build run -- +attach --session=work
# Expected: terminal appears with sleep still running
```

- [ ] **Step 5: Commit**

```bash
git add src/cli/attach.zig src/cli/detach.zig src/input/Binding.zig src/Surface.zig
git commit -m "feat(session): implement attach/detach commands and keybind action"
```

---

## Chunk 8: Build Verification & Config

### Task 11: Add session-restore config field

**Files:**
- Modify: `src/config/Config.zig`

- [ ] **Step 1: Add the enum and config field**

```zig
pub const SessionRestore = enum {
    layout,
    off,
};

// In the config struct:
@"session-restore": SessionRestore = .off,
```

- [ ] **Step 2: Commit**

```bash
git add src/config/Config.zig
git commit -m "feat(config): add session-restore config field (layout/off)"
```

### Task 12: Full build verification

- [ ] **Step 1: Full build**

```bash
zig build -Demit-macos-app=false 2>&1 | head -20
```

- [ ] **Step 2: Run protocol tests**

```bash
zig test src/daemon/Protocol.zig 2>&1 | tail -10
```

- [ ] **Step 3: Format check**

```bash
zig fmt --check src/daemon/ src/cli/attach.zig src/cli/detach.zig src/cli/list_sessions.zig src/cli/kill_session.zig src/termio/Mux.zig
```

- [ ] **Step 4: Commit any fixups**

---

## Implementation Notes

**Build command:** Always use `zig build -Demit-macos-app=false` during development.

**Testing strategy:** Protocol.zig has unit tests. Daemon/Server/Mux are integration-tested manually (start daemon, run CLI commands, verify behavior). Full automated integration tests are deferred to v3.1+.

**Task ordering:** Chunks 1-3 are independent and can run in parallel. Chunk 4 depends on Chunks 1+2. Chunk 5 depends on Chunk 4. Chunk 6 depends on Chunks 1+4. Chunk 7 depends on everything. Chunk 8 is independent.

**Parallelizable tasks:**
- Chunk 1 (Protocol) + Chunk 2 (Session/Terminal state) + Chunk 3 (CLI stubs)
- After those land: Chunk 4 (Daemon) + Chunk 6 (Mux backend) can overlap

**Key risk:** The Mux backend (Task 8) is the most complex integration point. The read model change from blocking PTY reads to event-driven socket reads affects the IO thread's event loop. If this proves difficult, a transitional approach is to spawn a dedicated read thread for the socket (same pattern as Exec.ReadThread) before optimizing to xev integration.

**macOS-specific:** The `--daemon` entry point must NOT initialize any Cocoa/Metal frameworks. It should be a pure POSIX process. Ensure `main_ghostty.zig` routes to the daemon path before any AppKit setup.
