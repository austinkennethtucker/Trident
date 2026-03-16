const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");

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
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("+attach is not yet implemented\n", .{});
    try stdout.flush();
    return 1;
}
