/// Socket listener for the daemon process.
///
/// Manages a Unix domain socket that clients connect to. The socket path
/// is platform-specific:
///   - macOS: `$TMPDIR/trident-daemon.sock`
///   - Linux: `$XDG_RUNTIME_DIR/trident/daemon.sock`
///
/// The parent directory is created with 0o700 permissions if it doesn't
/// exist, so only the owning user can access the socket.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Server = @This();

// -----------------------------------------------------------------------
// Fields
// -----------------------------------------------------------------------

/// The listening socket file descriptor.
listen_fd: posix.fd_t,

/// Path to the socket file on disk (owned by this struct).
socket_path: []const u8,

// -----------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------

/// Return the platform-specific socket path. The caller owns the
/// returned slice and must free it with `alloc.free()`.
///
/// - macOS: `$TMPDIR/trident-daemon.sock` (falls back to `/tmp`)
/// - Linux: `$XDG_RUNTIME_DIR/trident/daemon.sock`
///          (falls back to `/tmp/trident-<uid>/daemon.sock`)
///
/// The parent directory is created with mode 0o700 if it doesn't exist.
pub fn socketPath(alloc: Allocator) ![]const u8 {
    if (comptime builtin.os.tag.isDarwin()) {
        const tmpdir = posix.getenv("TMPDIR") orelse "/tmp";
        return try std.fmt.allocPrint(alloc, "{s}/trident-daemon.sock", .{tmpdir});
    } else {
        // Linux / other POSIX
        if (posix.getenv("XDG_RUNTIME_DIR")) |xrd| {
            const dir = try std.fmt.allocPrint(alloc, "{s}/trident", .{xrd});
            defer alloc.free(dir);
            posix.mkdir(dir, 0o700) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            return try std.fmt.allocPrint(alloc, "{s}/trident/daemon.sock", .{xrd});
        } else {
            const uid = std.c.getuid();
            const dir = try std.fmt.allocPrint(alloc, "/tmp/trident-{d}", .{uid});
            defer alloc.free(dir);
            posix.mkdir(dir, 0o700) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            return try std.fmt.allocPrint(alloc, "/tmp/trident-{d}/daemon.sock", .{uid});
        }
    }
}

/// Create and bind the listening socket. Removes a stale socket file if
/// one already exists at the resolved path.
pub fn init(alloc: Allocator) !Server {
    const path = try socketPath(alloc);
    errdefer alloc.free(path);

    // Only remove the socket file if no daemon is listening on it.
    stale_check: {
        const test_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch break :stale_check;
        defer posix.close(test_fd);
        var test_addr: posix.sockaddr.un = undefined;
        test_addr.family = posix.AF.UNIX;
        @memset(&test_addr.path, 0);
        if (path.len < test_addr.path.len) {
            @memcpy(test_addr.path[0..path.len], path);
            posix.connect(test_fd, @ptrCast(&test_addr), @sizeOf(posix.sockaddr.un)) catch {
                // Connect failed → stale socket, safe to remove.
                posix.unlink(path) catch {};
                break :stale_check;
            };
            // Connect succeeded → another daemon is running.
            return error.DaemonAlreadyRunning;
        }
    }

    // Create the UNIX-domain stream socket with CLOEXEC so forked PTY
    // children don't inherit the listen fd.
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    // Build sockaddr_un and bind.
    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);

    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);

    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Start listening (backlog of 5 pending connections).
    try posix.listen(fd, 5);

    return .{
        .listen_fd = fd,
        .socket_path = path,
    };
}

/// Close the listening socket, remove the socket file, and free the path.
pub fn deinit(self: *Server, alloc: Allocator) void {
    posix.close(self.listen_fd);
    posix.unlink(self.socket_path) catch {};
    alloc.free(self.socket_path);
}

/// Accept a single incoming client connection. CLOEXEC prevents forked
/// PTY children from inheriting the accepted client fd.
pub fn accept(self: *Server) !posix.fd_t {
    return try posix.accept(self.listen_fd, null, null, posix.SOCK.CLOEXEC);
}

/// Return the listening fd for use in a poll set.
pub fn getFd(self: *const Server) posix.fd_t {
    return self.listen_fd;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "socketPath returns a non-empty string" {
    const alloc = std.testing.allocator;
    const path = try socketPath(alloc);
    defer alloc.free(path);

    try std.testing.expect(path.len > 0);
    // The path should end with "trident-daemon.sock" or "daemon.sock".
    try std.testing.expect(std.mem.endsWith(u8, path, "daemon.sock"));
}

test "init and deinit round-trip" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc);
    defer server.deinit(alloc);

    // The listen fd should be a valid (non-negative) file descriptor.
    try std.testing.expect(server.listen_fd >= 0);
    try std.testing.expect(server.socket_path.len > 0);

    // The socket file should exist on disk.
    std.fs.accessAbsolute(server.socket_path, .{}) catch {
        return error.SocketFileNotFound;
    };
}
