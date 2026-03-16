//! The main entrypoint for the `ghostty` application. This also serves
//! as the process initialization code for the `libghostty` library.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const build_config = @import("build_config.zig");
const macos = @import("macos");
const cli = @import("cli.zig");
const renderer = @import("renderer.zig");
const apprt = @import("apprt.zig");
const internal_os = @import("os/main.zig");

const App = @import("App.zig");
const Ghostty = @import("main_c.zig").Ghostty;
const state = &@import("global.zig").state;

/// The return type for main() depends on the build artifact. The lib build
/// also calls "main" in order to run the CLI actions, but it calls it as
/// an API and not an entrypoint.
const MainReturn = switch (build_config.artifact) {
    .lib => noreturn,
    else => void,
};

pub fn main() !MainReturn {
    // Check for --daemon flag BEFORE any GUI/AppKit initialization.
    // The daemon is a pure POSIX process that must not touch AppKit.
    for (std.os.argv[1..]) |arg_ptr| {
        const arg = std.mem.span(arg_ptr);
        if (std.mem.eql(u8, arg, "--daemon")) {
            const daemon_mod = @import("daemon.zig");
            const alloc = std.heap.c_allocator;
            var daemon = daemon_mod.Daemon.init(alloc) catch |err| {
                std.log.err("daemon init failed: {}", .{err});
                posix.exit(1);
            };
            defer daemon.deinit();
            daemon.run() catch |err| {
                std.log.err("daemon exited with error: {}", .{err});
                posix.exit(1);
            };
            posix.exit(0);
        }
    }

    // Check for --session <name> flag. When present, ensure the daemon is
    // running and set the TRIDENT_SESSION env var so that Surface.init
    // uses the mux backend instead of exec.
    session: for (std.os.argv[1..], 1..) |arg_ptr, i| {
        const arg = std.mem.span(arg_ptr);
        if (std.mem.eql(u8, arg, "--session")) {
            // Next argument is the session name.
            if (i + 1 >= std.os.argv.len) {
                var buffer: [1024]u8 = undefined;
                var stderr_writer = std.fs.File.stderr().writer(&buffer);
                const stderr_w = &stderr_writer.interface;
                stderr_w.print("Error: --session requires a session name argument\n", .{}) catch {};
                stderr_w.flush() catch {};
                posix.exit(1);
            }
            const session_name = std.mem.span(std.os.argv[i + 1]);

            // Ensure the daemon is running.
            ensureDaemonRunning() catch |err| {
                std.log.err("failed to ensure daemon is running: {}", .{err});
                posix.exit(1);
            };

            // Set the env var so Surface.init can detect session mode.
            const rc = internal_os.setenv("TRIDENT_SESSION", session_name);
            if (rc != 0) {
                std.log.err("failed to set TRIDENT_SESSION env var", .{});
                posix.exit(1);
            }

            break :session;
        }
    }

    // We first start by initializing our global state. This will setup
    // process-level state we need to run the terminal. The reason we use
    // a global is because the C API needs to be able to access this state;
    // no other Zig code should EVER access the global state.
    state.init() catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buffer);
        const stderr = &stderr_writer.interface;
        defer posix.exit(1);
        const ErrSet = @TypeOf(err) || error{Unknown};
        switch (@as(ErrSet, @errorCast(err))) {
            error.MultipleActions => try stderr.print(
                "Error: multiple CLI actions specified. You must specify only one\n" ++
                    "action starting with the `+` character.\n",
                .{},
            ),

            error.InvalidAction => try stderr.print(
                "Error: unknown CLI action specified. CLI actions are specified with\n" ++
                    "the '+' character.\n\n" ++
                    "All valid CLI actions can be listed with `ghostty +help`\n",
                .{},
            ),

            else => try stderr.print("invalid CLI invocation err={}\n", .{err}),
        }
        try stderr.flush();
    };
    defer state.deinit();
    const alloc = state.alloc;

    if (comptime builtin.mode == .Debug) {
        std.log.warn("This is a debug build. Performance will be very poor.", .{});
        std.log.warn("You should only use a debug build for developing Ghostty.", .{});
        std.log.warn("Otherwise, please rebuild in a release mode.", .{});
    }

    // Execute our action if we have one
    if (state.action) |action| {
        std.log.info("executing CLI action={}", .{action});
        posix.exit(action.run(alloc) catch |err| err: {
            std.log.err("CLI action failed error={}", .{err});
            break :err 1;
        });
        return;
    }

    if (comptime build_config.app_runtime == .none) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Usage: ghostty +<action> [flags]\n\n", .{});
        try stdout.print(
            \\This is the Ghostty helper CLI that accompanies the graphical Ghostty app.
            \\To launch the terminal directly, please launch the graphical app
            \\(i.e. Ghostty.app on macOS). This CLI can be used to perform various
            \\actions such as inspecting the version, listing fonts, etc.
            \\
            \\On macOS, the terminal can also be launched using `open -na Ghostty.app`,
            \\or `open -na Ghostty.app --args --foo=bar --baz=qux` to pass arguments.
            \\
            \\We don't have proper help output yet, sorry! Please refer to the
            \\source code or Discord community for help for now. We'll fix this in time.
            \\
        ,
            .{},
        );

        posix.exit(0);
    }

    // Create our app state
    const app: *App = try App.create(alloc);
    defer app.destroy();

    // Create our runtime app
    var app_runtime: apprt.App = undefined;
    try app_runtime.init(app, .{});
    defer app_runtime.terminate();

    // Since - by definition - there are no surfaces when first started, the
    // quit timer may need to be started. The start timer will get cancelled if/
    // when the first surface is created.
    if (@hasDecl(apprt.App, "startQuitTimer")) app_runtime.startQuitTimer();

    // Run the GUI event loop
    try app_runtime.run();
}

// The function std.log will call.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // On Mac, we use unified logging. To view this:
    //
    //   sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
    //
    // macOS logging is thread safe so no need for locks/mutexes
    macos: {
        if (comptime !builtin.target.os.tag.isDarwin()) break :macos;
        if (!state.logging.macos) break :macos;

        const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";

        // Convert our levels to Mac levels
        const mac_level: macos.os.LogType = switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .err,
            .err => .fault,
        };

        // Initialize a logger. This is slow to do on every operation
        // but we shouldn't be logging too much.
        const logger = macos.os.Log.create(build_config.bundle_id, @tagName(scope));
        defer logger.release();
        logger.log(std.heap.c_allocator, mac_level, prefix ++ format, args);
    }

    stderr: {
        // don't log debug messages to stderr unless we are a debug build
        if (comptime builtin.mode != .Debug and level == .debug) break :stderr;

        // skip if we are not logging to stderr
        if (!state.logging.stderr) break :stderr;

        // Lock so we are thread-safe
        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();

        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch break :stderr;
        nosuspend stderr.flush() catch break :stderr;
    }
}

pub const std_options: std.Options = .{
    // Our log level is always at least info in every build mode.
    //
    // Note, we don't lower this to debug even with conditional logging
    // via GHOSTTY_LOG because our debug logs are very expensive to
    // calculate and we want to make sure they're optimized out in
    // builds.
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },

    .logFn = logFn,
};

/// Check if the daemon is running by trying to connect to its socket.
/// If not running, spawn it as a background process and wait for it to
/// start listening (up to 2 seconds).
fn ensureDaemonRunning() !void {
    const alloc = std.heap.c_allocator;
    const daemon_mod = @import("daemon.zig");

    const socket_path = try daemon_mod.Server.socketPath(alloc);
    defer alloc.free(socket_path);

    // Try to connect to the existing socket.
    if (tryConnectSocket(socket_path)) {
        // Daemon is already running.
        return;
    }

    // Daemon is not running — spawn it.
    // Acquire a lock file to prevent two processes from racing to spawn
    // competing daemon instances (e.g. two terminals launched at once).
    const lock_path = try std.fmt.allocPrint(alloc, "{s}.lock", .{socket_path});
    defer alloc.free(lock_path);

    const lock_file = std.fs.createFileAbsolute(lock_path, .{
        .truncate = false,
    }) catch |err| {
        std.log.warn("failed to create daemon lock file: {}", .{err});
        // Proceed without lock — best effort.
        return spawnDaemon(socket_path);
    };
    defer lock_file.close();

    lock_file.lock(.exclusive) catch |err| {
        std.log.warn("failed to acquire daemon lock: {}", .{err});
        // Proceed without lock — best effort.
        return spawnDaemon(socket_path);
    };
    defer lock_file.unlock();

    // Re-check — another process may have started the daemon while we
    // waited for the lock.
    if (tryConnectSocket(socket_path)) return;

    return spawnDaemon(socket_path);
}

/// Spawn the daemon as a detached background process and poll for up to
/// 2 seconds until it starts accepting connections.
fn spawnDaemon(socket_path: []const u8) !void {
    std.log.info("daemon not running, starting it...", .{});

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch |err| {
        std.log.err("failed to get self exe path: {}", .{err});
        return err;
    };

    // We need a null-terminated copy for the argv.
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_buf[0..exe_path.len], exe_path);
    path_buf[exe_path.len] = 0;
    const exe_path_z: [*:0]const u8 = path_buf[0..exe_path.len :0];

    const daemon_flag: [*:0]const u8 = "--daemon";
    const argv_list: [3:null]?[*:0]const u8 = .{ exe_path_z, daemon_flag, null };

    const pid = try posix.fork();
    if (pid == 0) {
        // Child process: become session leader, close stdio, exec daemon.
        _ = std.c.setsid();

        // Close stdin/stdout/stderr so the daemon is fully detached.
        posix.close(0);
        posix.close(1);
        posix.close(2);

        // Redirect to /dev/null.
        const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
        if (devnull != 0) {
            posix.dup2(devnull, 0) catch posix.exit(1);
        }
        posix.dup2(devnull, 1) catch posix.exit(1);
        posix.dup2(devnull, 2) catch posix.exit(1);
        if (devnull > 2) posix.close(devnull);

        const err = posix.execvpeZ(exe_path_z, @ptrCast(&argv_list), std.c.environ);
        _ = err;
        posix.exit(1);
    }

    // Parent: wait for the daemon socket to appear (max 2 seconds).
    const max_polls = 40; // 40 * 50ms = 2000ms
    for (0..max_polls) |_| {
        std.time.sleep(50 * std.time.ns_per_ms);
        if (tryConnectSocket(socket_path)) {
            std.log.info("daemon started successfully", .{});
            return;
        }
    }

    std.log.err("timed out waiting for daemon to start", .{});
    return error.DaemonStartTimeout;
}

/// Try to connect to a Unix domain socket at the given path.
/// Returns true if the connection succeeded (daemon is listening).
fn tryConnectSocket(socket_path: []const u8) bool {
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

test {
    _ = @import("pty.zig");
    _ = @import("Command.zig");
    _ = @import("font/main.zig");
    _ = @import("apprt.zig");
    _ = @import("renderer.zig");
    _ = @import("termio.zig");
    _ = @import("input.zig");
    _ = @import("cli.zig");
    _ = @import("surface_mouse.zig");

    // Libraries
    _ = @import("tripwire.zig");
    _ = @import("benchmark/main.zig");
    _ = @import("crash/main.zig");
    _ = @import("datastruct/main.zig");
    _ = @import("inspector/main.zig");
    _ = @import("lib/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("terminfo/main.zig");
    _ = @import("simd/main.zig");
    _ = @import("synthetic/main.zig");
    _ = @import("unicode/main.zig");
    _ = @import("unicode/props_uucode.zig");
    _ = @import("unicode/symbols_uucode.zig");

    // Extra
    _ = @import("extra/bash.zig");
    _ = @import("extra/fish.zig");
    _ = @import("extra/sublime.zig");
    _ = @import("extra/vim.zig");
    _ = @import("extra/zsh.zig");
}
