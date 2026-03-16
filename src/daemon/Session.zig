/// A named session that groups one or more terminals.
///
/// Sessions are the primary unit of persistence in the daemon — a user
/// can detach from a session and re-attach later, finding all terminals
/// still running. At most one client may be attached to a session at a
/// time; attempting to attach while another client is connected returns
/// an error.
const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Terminal = @import("Terminal.zig");

const Session = @This();

// -----------------------------------------------------------------------
// Fields
// -----------------------------------------------------------------------

/// Human-readable session name (owned copy).
name: []const u8,

/// Terminals belonging to this session, keyed by terminal id.
terminals: std.AutoHashMap(u32, *Terminal),

/// File descriptor of the currently-attached client connection, or null
/// if no client is attached.
attached_client: ?posix.fd_t = null,

/// Unix timestamp (seconds since epoch) when the session was created.
created_at: i64,

/// Allocator used for all owned memory in this struct.
alloc: Allocator,

// -----------------------------------------------------------------------
// Lifecycle
// -----------------------------------------------------------------------

/// Create a new session with the given name. The caller retains no
/// ownership of `name`; this function duplicates it.
pub fn init(alloc: Allocator, name: []const u8) Allocator.Error!Session {
    const owned_name = try alloc.dupe(u8, name);
    return .{
        .name = owned_name,
        .terminals = std.AutoHashMap(u32, *Terminal).init(alloc),
        .created_at = std.time.timestamp(),
        .alloc = alloc,
    };
}

/// Destroy all terminals and free all owned memory.
pub fn deinit(self: *Session) void {
    // Iterate over all terminals, deinit each one, then free the pointer.
    var it = self.terminals.valueIterator();
    while (it.next()) |ptr| {
        const terminal: *Terminal = ptr.*;
        terminal.deinit();
        self.alloc.destroy(terminal);
    }
    self.terminals.deinit();
    self.alloc.free(self.name);
}

// -----------------------------------------------------------------------
// Terminal management
// -----------------------------------------------------------------------

/// Add a terminal to the session. The session takes ownership of the
/// pointer; it will call `deinit()` + `destroy()` during `removeTerminal`
/// or `deinit`.
pub fn addTerminal(self: *Session, terminal: *Terminal) Allocator.Error!void {
    try self.terminals.put(terminal.id, terminal);
}

/// Remove and destroy a terminal by id. Returns `true` if the terminal
/// was found and removed, `false` if no terminal with that id existed.
pub fn removeTerminal(self: *Session, id: u32) bool {
    const kv = self.terminals.fetchRemove(id) orelse return false;
    var terminal = kv.value;
    terminal.deinit();
    self.alloc.destroy(terminal);
    return true;
}

/// Return the number of terminals in this session.
pub fn terminalCount(self: *const Session) u32 {
    return @intCast(self.terminals.count());
}

// -----------------------------------------------------------------------
// Client attachment
// -----------------------------------------------------------------------

pub const AttachError = error{AlreadyAttached};

/// Whether a client is currently attached to this session.
pub fn isAttached(self: *const Session) bool {
    return self.attached_client != null;
}

/// Attach a client to this session. Returns `error.AlreadyAttached` if
/// another client is already connected.
pub fn attach(self: *Session, client_fd: posix.fd_t) AttachError!void {
    if (self.attached_client != null) return error.AlreadyAttached;
    self.attached_client = client_fd;
}

/// Unconditionally detach the current client.
pub fn detach(self: *Session) void {
    self.attached_client = null;
}

/// Detach only if the given fd matches the currently-attached client.
/// This is used during client disconnect to avoid accidentally detaching
/// a different client that raced to attach.
pub fn detachIfClient(self: *Session, fd: posix.fd_t) void {
    if (self.attached_client) |current| {
        if (current == fd) {
            self.attached_client = null;
        }
    }
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "session lifecycle" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, "test-session");
    defer session.deinit();

    try std.testing.expectEqualStrings("test-session", session.name);
    try std.testing.expectEqual(@as(u32, 0), session.terminalCount());
    try std.testing.expect(!session.isAttached());
}

test "attach and detach" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, "sess");
    defer session.deinit();

    try session.attach(42);
    try std.testing.expect(session.isAttached());

    // Double-attach should fail.
    try std.testing.expectError(error.AlreadyAttached, session.attach(99));

    // detachIfClient with wrong fd should be a no-op.
    session.detachIfClient(99);
    try std.testing.expect(session.isAttached());

    // detachIfClient with correct fd should detach.
    session.detachIfClient(42);
    try std.testing.expect(!session.isAttached());
}

test "add and remove terminals" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, "sess");
    defer session.deinit();

    // We can't easily create a real PTY in a unit test, so we create a
    // Terminal with a dummy fd. The deinit will attempt to close it, which
    // is harmless for an invalid fd.
    const term = try alloc.create(Terminal);
    term.* = try Terminal.init(alloc, .{
        .id = 1,
        .pty_fd = -1, // dummy
        .child_pid = 1, // dummy (init)
        .command = "/bin/sh",
        .cwd = "/tmp",
        .buffer_size = 64,
    });
    // Mark as exited so deinit doesn't try to kill PID 1.
    term.markExited(0);

    try session.addTerminal(term);
    try std.testing.expectEqual(@as(u32, 1), session.terminalCount());

    try std.testing.expect(session.removeTerminal(1));
    try std.testing.expectEqual(@as(u32, 0), session.terminalCount());

    // Removing again should return false.
    try std.testing.expect(!session.removeTerminal(1));
}
