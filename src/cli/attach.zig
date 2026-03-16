const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const daemon = @import("../daemon.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// The name or ID of the session to attach to. If not specified,
    /// attaches to the most recently detached session.
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

/// The `attach` command reattaches to a previously detached Ghostty session.
///
/// If a session name is given with `--session`, the command will attach to that
/// specific session. Otherwise, it attaches to the most recently detached
/// session.
///
/// Flags:
///
///   * `--session`: The name or ID of the session to attach to.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: Options = .{};
    defer opts.deinit();
    try args.parse(Options, alloc, &opts, &iter);

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const session_name = opts.session orelse {
        // TODO: In the future, pick the most recently detached session
        // by querying the daemon's session list. For now, require an
        // explicit name.
        try stderr.print("Error: --session is required. Usage: ghostty +attach --session=<name>\n", .{});
        try stderr.flush();
        return 1;
    };

    // Verify the daemon is reachable by trying to connect to its socket.
    const socket_path = daemon.Server.socketPath(alloc) catch {
        try stderr.print("Error: failed to determine daemon socket path\n", .{});
        try stderr.flush();
        return 1;
    };
    defer alloc.free(socket_path);

    if (!isDaemonRunning(socket_path)) {
        try stderr.print("Error: daemon is not running. Start it with: ghostty --daemon\n", .{});
        try stderr.flush();
        return 1;
    }

    // Re-exec the current binary with --session <name>.
    // This replaces the current process entirely (exec does not return).
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch {
        try stderr.print("Error: failed to determine executable path\n", .{});
        try stderr.flush();
        return 1;
    };

    // Build a null-terminated copy of the exe path.
    var path_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_z_buf[0..exe_path.len], exe_path);
    path_z_buf[exe_path.len] = 0;
    const exe_path_z: [*:0]const u8 = path_z_buf[0..exe_path.len :0];

    const session_flag: [*:0]const u8 = "--session";
    const argv_list: [4:null]?[*:0]const u8 = .{
        exe_path_z,
        session_flag,
        session_name.ptr,
        null,
    };

    // execvpeZ replaces this process. If it returns, something went wrong.
    const exec_err = posix.execvpeZ(exe_path_z, @ptrCast(&argv_list), std.c.environ);

    try stderr.print("Error: exec failed: {}\n", .{exec_err});
    try stderr.flush();
    return 1;
}

/// Try to connect to the daemon's Unix domain socket.
/// Returns true if the connection succeeds (daemon is listening).
fn isDaemonRunning(socket_path: []const u8) bool {
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(sock);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);
    if (socket_path.len >= addr.path.len) return false;
    @memcpy(addr.path[0..socket_path.len], socket_path);

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return false;
    return true;
}
