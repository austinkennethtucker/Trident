/// Top-level daemon process: owns the socket server, sessions, and the
/// main poll loop.
///
/// The daemon accepts client connections over a Unix domain socket and
/// multiplexes I/O between clients and PTY child processes. Sessions
/// persist across client attach/detach cycles.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Protocol = @import("Protocol.zig");
const Session = @import("Session.zig");
const Terminal = @import("Terminal.zig");
const Server = @import("Server.zig");
const pty_mod = @import("../pty.zig");
const Pty = pty_mod.Pty;

const log = std.log.scoped(.daemon);

const Daemon = @This();

// -----------------------------------------------------------------------
// Platform-specific constants for child process setup
// -----------------------------------------------------------------------

extern "c" fn c_setsid() std.c.pid_t;

const c_ioctl = @cImport(@cInclude("sys/ioctl.h"));

/// ioctl constant for setting a controlling terminal.
const TIOCSCTTY: u32 = if (builtin.os.tag == .macos) 536900705 else blk: {
    const c = @cImport(@cInclude("sys/ioctl.h"));
    break :blk c.TIOCSCTTY;
};

// -----------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------

/// Size of the read buffer used for PTY and client I/O.
const read_buf_size: usize = 64 * 1024;

// -----------------------------------------------------------------------
// Fields
// -----------------------------------------------------------------------

/// The socket listener that accepts new client connections.
server: Server,

/// All live sessions, keyed by session name.
sessions: std.StringHashMap(*Session),

/// Connected client file descriptors.
clients: std.ArrayList(posix.fd_t),

/// Map from PTY master fd → the Terminal that owns it, for fast output
/// routing when a PTY becomes readable.
pty_terminals: std.AutoHashMap(posix.fd_t, *Terminal),

/// Global map from terminal id → Terminal for input/resize dispatch.
id_terminals: std.AutoHashMap(u32, *Terminal),

/// Map from terminal id → owning session name (not owned — points into
/// the Session's `name` field).
id_sessions: std.AutoHashMap(u32, []const u8),

/// Counter for assigning unique terminal identifiers.
next_terminal_id: u32 = 1,

/// Whether the main loop should keep running.
running: bool = true,

/// Allocator used by the daemon and all owned structures.
alloc: Allocator,

// -----------------------------------------------------------------------
// Lifecycle
// -----------------------------------------------------------------------

pub fn init(alloc: Allocator) !Daemon {
    var server = try Server.init(alloc);
    errdefer server.deinit(alloc);

    log.info("daemon listening on {s}", .{server.socket_path});

    return .{
        .server = server,
        .sessions = std.StringHashMap(*Session).init(alloc),
        .clients = std.ArrayList(posix.fd_t).init(alloc),
        .pty_terminals = std.AutoHashMap(posix.fd_t, *Terminal).init(alloc),
        .id_terminals = std.AutoHashMap(u32, *Terminal).init(alloc),
        .id_sessions = std.AutoHashMap(u32, []const u8).init(alloc),
        .alloc = alloc,
    };
}

pub fn deinit(self: *Daemon) void {
    // Close all client connections.
    for (self.clients.items) |fd| {
        _ = std.c.close(fd);
    }
    self.clients.deinit();

    // Destroy all sessions (this kills child processes and closes PTYs).
    var it = self.sessions.valueIterator();
    while (it.next()) |ptr| {
        var session: *Session = ptr.*;
        session.deinit();
        self.alloc.destroy(session);
    }
    self.sessions.deinit();

    self.pty_terminals.deinit();
    self.id_terminals.deinit();
    self.id_sessions.deinit();

    self.server.deinit(self.alloc);
}

/// Signal the main loop to exit after the current poll iteration.
pub fn stop(self: *Daemon) void {
    self.running = false;
}

// -----------------------------------------------------------------------
// Main event loop
// -----------------------------------------------------------------------

pub fn run(self: *Daemon) !void {
    var read_buf: [read_buf_size]u8 = undefined;

    while (self.running) {
        // ---------------------------------------------------------
        // Build the pollfds array: [listen_fd, ...client fds, ...pty fds]
        // ---------------------------------------------------------
        const n_fds = 1 + self.clients.items.len + self.pty_terminals.count();
        const pollfds = try self.alloc.alloc(posix.pollfd, n_fds);
        defer self.alloc.free(pollfds);

        // Slot 0: listen socket
        pollfds[0] = .{ .fd = self.server.getFd(), .events = posix.POLL.IN, .revents = undefined };

        // Client fds
        const client_base: usize = 1;
        for (self.clients.items, 0..) |fd, i| {
            pollfds[client_base + i] = .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined };
        }

        // PTY fds
        const pty_base: usize = client_base + self.clients.items.len;
        {
            var pty_it = self.pty_terminals.keyIterator();
            var idx: usize = 0;
            while (pty_it.next()) |key_ptr| {
                pollfds[pty_base + idx] = .{ .fd = key_ptr.*, .events = posix.POLL.IN, .revents = undefined };
                idx += 1;
            }
        }

        // ---------------------------------------------------------
        // Poll (block until something happens)
        // ---------------------------------------------------------
        _ = posix.poll(pollfds, -1) catch |err| {
            log.warn("poll failed: {}", .{err});
            continue;
        };

        // ---------------------------------------------------------
        // Handle listen socket: accept new clients
        // ---------------------------------------------------------
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            self.acceptClient() catch |err| {
                log.warn("accept failed: {}", .{err});
            };
        }

        // ---------------------------------------------------------
        // Handle client fds (iterate backwards so removal is safe)
        // ---------------------------------------------------------
        {
            var i: usize = self.clients.items.len;
            while (i > 0) {
                i -= 1;
                const pfd = &pollfds[client_base + i];
                const fd = pfd.fd;

                if (pfd.revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                    self.disconnectClient(fd);
                    _ = self.clients.orderedRemove(i);
                    continue;
                }

                if (pfd.revents & posix.POLL.IN != 0) {
                    self.handleClientData(fd, &read_buf) catch |err| {
                        log.warn("client read error fd={d}: {}", .{ fd, err });
                        self.disconnectClient(fd);
                        _ = self.clients.orderedRemove(i);
                    };
                }
            }
        }

        // ---------------------------------------------------------
        // Handle PTY fds
        // ---------------------------------------------------------
        {
            for (pollfds[pty_base..]) |pfd| {
                const fd = pfd.fd;

                if (pfd.revents & posix.POLL.HUP != 0) {
                    self.handlePtyHangup(fd);
                    continue;
                }

                if (pfd.revents & posix.POLL.IN != 0) {
                    self.handlePtyOutput(fd, &read_buf);
                }
            }
        }

        // ---------------------------------------------------------
        // Reap any exited child processes (non-blocking)
        // ---------------------------------------------------------
        self.reapChildren();
    }
}

// -----------------------------------------------------------------------
// Accept / disconnect helpers
// -----------------------------------------------------------------------

fn acceptClient(self: *Daemon) !void {
    const fd = try self.server.accept();
    try self.clients.append(fd);
    log.info("client connected fd={d}", .{fd});
}

fn disconnectClient(self: *Daemon, fd: posix.fd_t) void {
    log.info("client disconnected fd={d}", .{fd});

    // Detach from any session this client was attached to.
    var it = self.sessions.valueIterator();
    while (it.next()) |ptr| {
        const session: *Session = ptr.*;
        session.detachIfClient(fd);
    }

    _ = std.c.close(fd);
}

// -----------------------------------------------------------------------
// Client message handling
// -----------------------------------------------------------------------

fn handleClientData(self: *Daemon, fd: posix.fd_t, buf: *[read_buf_size]u8) !void {
    const n = posix.read(fd, buf) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => {
            // Treat as disconnect — the caller will clean up.
            return error.ConnectionResetByPeer;
        },
        else => return err,
    };

    if (n == 0) {
        // EOF — client disconnected cleanly.
        return error.EndOfStream;
    }

    // Parse the frame header from the received bytes.
    var fbs = std.io.fixedBufferStream(buf[0..n]);
    const reader = fbs.reader();

    while (true) {
        const hdr = Protocol.readFrameHeader(reader) catch break;
        const header = hdr orelse break;

        // Read the payload.
        if (header.payload_len > n - fbs.pos) break; // incomplete frame
        const payload = buf[fbs.pos..][0..header.payload_len];
        fbs.pos += header.payload_len;

        // Dispatch based on message type.
        const msg_type = header.clientMsg() orelse {
            log.warn("unknown message type 0x{x:0>2} from fd={d}", .{ header.msg_type, fd });
            continue;
        };

        self.handleClientMessage(fd, msg_type, payload) catch |err| {
            log.warn("error handling {s} from fd={d}: {}", .{ @tagName(msg_type), fd, err });
            self.sendError(fd, @tagName(msg_type), @errorName(err)) catch {};
        };
    }
}

fn handleClientMessage(
    self: *Daemon,
    client_fd: posix.fd_t,
    msg_type: Protocol.ClientMsg,
    payload: []const u8,
) !void {
    var fbs = std.io.fixedBufferStream(payload);
    const reader = fbs.reader();

    switch (msg_type) {
        .create_session => {
            const name = try Protocol.readString(self.alloc, reader);
            defer self.alloc.free(name);

            if (self.sessions.contains(name)) {
                return self.sendError(client_fd, "create_session", "session already exists");
            }

            const session = try self.alloc.create(Session);
            session.* = try Session.init(self.alloc, name);
            errdefer {
                session.deinit();
                self.alloc.destroy(session);
            }

            try self.sessions.put(session.name, session);
            log.info("created session '{s}'", .{session.name});

            try self.sendSessionInfo(client_fd, session);
        },

        .create_terminal => {
            const session_name = try Protocol.readString(self.alloc, reader);
            defer self.alloc.free(session_name);
            const command = try Protocol.readString(self.alloc, reader);
            defer self.alloc.free(command);
            const cwd = try Protocol.readString(self.alloc, reader);
            defer self.alloc.free(cwd);
            const cols = try Protocol.readU16(reader);
            const rows = try Protocol.readU16(reader);

            const session = self.sessions.get(session_name) orelse {
                return self.sendError(client_fd, "create_terminal", "session not found");
            };

            const tid = self.next_terminal_id;
            self.next_terminal_id += 1;

            const result = try self.spawnPty(command, cwd, cols, rows);

            const terminal = try self.alloc.create(Terminal);
            terminal.* = try Terminal.init(self.alloc, .{
                .id = tid,
                .pty_fd = result.master_fd,
                .child_pid = result.pid,
                .cols = cols,
                .rows = rows,
                .command = command,
                .cwd = cwd,
            });
            errdefer {
                terminal.deinit();
                self.alloc.destroy(terminal);
            }

            try session.addTerminal(terminal);
            try self.pty_terminals.put(result.master_fd, terminal);
            try self.id_terminals.put(tid, terminal);
            try self.id_sessions.put(tid, session.name);

            log.info("created terminal id={d} in session '{s}' pid={d}", .{ tid, session.name, result.pid });

            try self.sendTerminalCreated(client_fd, tid);
        },

        .attach_session => {
            const name = try Protocol.readString(self.alloc, reader);
            defer self.alloc.free(name);

            const session = self.sessions.get(name) orelse {
                return self.sendError(client_fd, "attach_session", "session not found");
            };

            session.attach(client_fd) catch {
                return self.sendError(client_fd, "attach_session", "session already attached");
            };

            log.info("client fd={d} attached to session '{s}'", .{ client_fd, session.name });

            // Send screen snapshots for each terminal in the session.
            var term_it = session.terminals.valueIterator();
            while (term_it.next()) |tptr| {
                const terminal: *Terminal = tptr.*;
                try self.sendScreenSnapshot(client_fd, terminal);
            }
        },

        .detach_session => {
            const name = try Protocol.readString(self.alloc, reader);
            defer self.alloc.free(name);

            const session = self.sessions.get(name) orelse {
                return self.sendError(client_fd, "detach_session", "session not found");
            };

            session.detach();
            log.info("client detached from session '{s}'", .{session.name});
        },

        .input => {
            const tid = try Protocol.readU32(reader);
            const remaining = payload[fbs.pos..];

            const terminal = self.id_terminals.get(tid) orelse {
                return self.sendError(client_fd, "input", "terminal not found");
            };

            // Write the input data to the terminal's PTY master fd.
            _ = posix.write(terminal.pty_fd, remaining) catch |err| {
                log.warn("pty write failed for terminal {d}: {}", .{ tid, err });
            };
        },

        .resize => {
            const tid = try Protocol.readU32(reader);
            const cols = try Protocol.readU16(reader);
            const rows = try Protocol.readU16(reader);

            const terminal = self.id_terminals.get(tid) orelse {
                return self.sendError(client_fd, "resize", "terminal not found");
            };

            terminal.resize(cols, rows) catch |err| {
                log.warn("resize failed for terminal {d}: {}", .{ tid, err });
            };
        },

        .close_terminal => {
            const tid = try Protocol.readU32(reader);

            const session_name = self.id_sessions.get(tid) orelse {
                return self.sendError(client_fd, "close_terminal", "terminal not found");
            };

            const session = self.sessions.get(session_name) orelse {
                return self.sendError(client_fd, "close_terminal", "session not found");
            };

            // Unregister from our lookup maps before Session.removeTerminal
            // destroys the Terminal (and closes the PTY fd).
            const terminal = self.id_terminals.get(tid) orelse {
                return self.sendError(client_fd, "close_terminal", "terminal not found");
            };
            _ = self.pty_terminals.remove(terminal.pty_fd);
            _ = self.id_terminals.remove(tid);
            _ = self.id_sessions.remove(tid);

            _ = session.removeTerminal(tid);
            log.info("closed terminal id={d} in session '{s}'", .{ tid, session_name });
        },

        .list_sessions => {
            try self.sendSessionList(client_fd);
        },

        .destroy_session => {
            const name = try Protocol.readString(self.alloc, reader);
            defer self.alloc.free(name);

            const kv = self.sessions.fetchRemove(name) orelse {
                return self.sendError(client_fd, "destroy_session", "session not found");
            };

            var session = kv.value;

            // Clean up lookup maps for every terminal in this session.
            var term_it = session.terminals.iterator();
            while (term_it.next()) |entry| {
                const terminal: *Terminal = entry.value_ptr.*;
                _ = self.pty_terminals.remove(terminal.pty_fd);
                _ = self.id_terminals.remove(terminal.id);
                _ = self.id_sessions.remove(terminal.id);
            }

            session.deinit();
            self.alloc.destroy(session);
            log.info("destroyed session '{s}'", .{name});

            // Send the updated session list as confirmation.
            try self.sendSessionList(client_fd);
        },
    }
}

// -----------------------------------------------------------------------
// PTY creation
// -----------------------------------------------------------------------

const SpawnResult = struct {
    master_fd: posix.fd_t,
    pid: posix.pid_t,
};

/// Fork a child process running `command` inside a new PTY.
///
/// The child process gets its own session (setsid), the slave side of
/// the PTY as its controlling terminal, and stdin/stdout/stderr all
/// dup'd to the slave fd. The parent keeps the master fd and closes
/// the slave.
///
/// We do the child setup manually rather than using Pty.childPreExec()
/// because that helper closes the slave fd before we can dup2 it to the
/// standard streams.
fn spawnPty(
    self: *Daemon,
    command: []const u8,
    cwd: []const u8,
    cols: u16,
    rows: u16,
) !SpawnResult {
    _ = self;

    // Open the PTY pair using the existing Pty module.
    var pty = try Pty.open(.{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    });
    errdefer pty.deinit();

    const slave_fd = pty.slave;
    const master_fd = pty.master;

    // Prepare a null-terminated copy of the command string BEFORE
    // forking (malloc between fork and exec is undefined behavior).
    var cmd_buf: [4096]u8 = undefined;
    if (command.len >= cmd_buf.len) return error.CommandTooLong;
    @memcpy(cmd_buf[0..command.len], command);
    cmd_buf[command.len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);

    // Fork.
    const pid = try posix.fork();

    if (pid == 0) {
        // ---- Child process ----
        // Any error here is fatal — we must exit, never return.

        // Create a new process session.
        if (c_setsid() < 0) posix.exit(127);

        // Set the slave as the controlling terminal.
        if (c_ioctl.ioctl(slave_fd, TIOCSCTTY, @as(c_ulong, 0)) < 0)
            posix.exit(127);

        // Dup the slave fd to stdin, stdout, stderr.
        posix.dup2(slave_fd, posix.STDIN_FILENO) catch posix.exit(127);
        posix.dup2(slave_fd, posix.STDOUT_FILENO) catch posix.exit(127);
        posix.dup2(slave_fd, posix.STDERR_FILENO) catch posix.exit(127);

        // Close original slave and master fds (they're now accessible
        // via the standard streams).
        if (slave_fd > posix.STDERR_FILENO) posix.close(slave_fd);
        posix.close(master_fd);

        // Change working directory if specified.
        if (cwd.len > 0) {
            posix.chdir(cwd) catch {};
        }

        // Exec the command via /bin/sh -c so the user can pass a full
        // command string with arguments.
        const argv = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            cmd_z,
            null,
        };
        const envp = if (builtin.link_libc) std.c.environ else @as([*:null]const ?[*:0]const u8, &.{null});
        _ = posix.execvpeZ("/bin/sh", &argv, envp);

        // If exec failed, exit.
        posix.exit(127);
    }

    // ---- Parent process ----
    // Close the slave side; only the master is needed by the daemon.
    _ = std.c.close(slave_fd);

    return .{
        .master_fd = master_fd,
        .pid = @intCast(pid),
    };
}

// -----------------------------------------------------------------------
// PTY output and hangup
// -----------------------------------------------------------------------

fn handlePtyOutput(self: *Daemon, fd: posix.fd_t, buf: *[read_buf_size]u8) void {
    const n = posix.read(fd, buf) catch |err| {
        log.warn("pty read error fd={d}: {}", .{ fd, err });
        return;
    };

    if (n == 0) {
        // EOF on the PTY — child exited.
        self.handlePtyHangup(fd);
        return;
    }

    const terminal = self.pty_terminals.get(fd) orelse return;
    terminal.recordOutput(buf[0..n]);

    // If there is an attached client on this terminal's session, forward
    // the output.
    const session_name = self.id_sessions.get(terminal.id) orelse return;
    const session = self.sessions.get(session_name) orelse return;
    const client_fd = session.attached_client orelse return;

    self.sendOutput(client_fd, terminal.id, buf[0..n]) catch |err| {
        log.warn("failed to send output to client fd={d}: {}", .{ client_fd, err });
    };
}

fn handlePtyHangup(self: *Daemon, fd: posix.fd_t) void {
    const terminal = self.pty_terminals.get(fd) orelse return;
    log.info("pty hangup for terminal id={d}", .{terminal.id});

    terminal.markExited(0);

    // Notify attached client if any.
    const session_name = self.id_sessions.get(terminal.id) orelse return;
    const session = self.sessions.get(session_name) orelse return;
    if (session.attached_client) |client_fd| {
        self.sendTerminalExited(client_fd, terminal.id, 0) catch {};
    }

    // Remove the PTY fd from the poll set (it's closed by Terminal.deinit
    // when the session or terminal is destroyed).
    _ = self.pty_terminals.remove(fd);
}

// -----------------------------------------------------------------------
// Child reaping
// -----------------------------------------------------------------------

fn reapChildren(self: *Daemon) void {
    // Use the raw C waitpid rather than std.posix.waitpid because the
    // latter hits `unreachable` on ECHILD (no children), which would
    // crash the daemon on every poll iteration when no terminals exist.
    while (true) {
        var status: c_int = 0;
        const pid = std.c.waitpid(-1, &status, std.c.W.NOHANG);
        if (pid <= 0) break; // 0 = no status available, -1 = error (ECHILD)

        const exit_code: i32 = if (posix.W.IFEXITED(@bitCast(status)))
            @as(i32, @intCast(posix.W.EXITSTATUS(@bitCast(status))))
        else if (posix.W.IFSIGNALED(@bitCast(status)))
            -@as(i32, @intCast(posix.W.TERMSIG(@bitCast(status))))
        else
            -1;

        // Find the terminal that owns this PID and mark it exited.
        var id_it = self.id_terminals.iterator();
        while (id_it.next()) |entry| {
            const terminal: *Terminal = entry.value_ptr.*;
            if (terminal.child_pid == pid) {
                terminal.markExited(exit_code);
                log.info("child pid={d} exited code={d} (terminal {d})", .{ pid, exit_code, terminal.id });

                // Notify attached client.
                const sn = self.id_sessions.get(terminal.id) orelse continue;
                const session = self.sessions.get(sn) orelse continue;
                if (session.attached_client) |client_fd| {
                    self.sendTerminalExited(client_fd, terminal.id, exit_code) catch {};
                }
                break;
            }
        }
    }
}

// -----------------------------------------------------------------------
// Outgoing frame helpers
// -----------------------------------------------------------------------

fn sendFrame(self: *Daemon, fd: posix.fd_t, msg_type: u8, payload: []const u8) !void {
    if (payload.len > Protocol.max_payload_size) return error.PayloadTooLarge;

    // Write header (5 bytes) + payload to the client fd.
    // We write the header first, then the payload, to avoid needing a
    // contiguous buffer for the entire frame.
    var header_buf: [Protocol.header_size]u8 = undefined;
    var hdr_fbs = std.io.fixedBufferStream(&header_buf);
    try Protocol.writeFrame(hdr_fbs.writer(), msg_type, &.{});

    // Overwrite the payload_len field with the actual payload length
    // (writeFrame wrote 0 because we passed an empty payload).
    const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(payload.len)));
    @memcpy(header_buf[0..4], &len_bytes);

    // Write header.
    try writeAll(fd, &header_buf);

    // Write payload.
    if (payload.len > 0) {
        try writeAll(fd, payload);
    }

    _ = self;
}

/// Write the entire buffer to the fd, retrying on partial writes.
fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const w = posix.write(fd, data[written..]) catch |err| {
            return err;
        };
        if (w == 0) return error.BrokenPipe;
        written += w;
    }
}

fn sendError(self: *Daemon, fd: posix.fd_t, context: []const u8, message: []const u8) !void {
    var payload_buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&payload_buf);
    const writer = fbs.writer();
    try Protocol.writeString(writer, context);
    try Protocol.writeString(writer, message);
    try self.sendFrame(fd, @intFromEnum(Protocol.ServerMsg.@"error"), payload_buf[0..fbs.pos]);
}

fn sendSessionInfo(self: *Daemon, fd: posix.fd_t, session: *const Session) !void {
    var payload_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&payload_buf);
    const writer = fbs.writer();
    try Protocol.writeString(writer, session.name);
    try Protocol.writeU32(writer, session.terminalCount());
    try Protocol.writeI32(writer, @truncate(session.created_at));
    try self.sendFrame(fd, @intFromEnum(Protocol.ServerMsg.session_info), payload_buf[0..fbs.pos]);
}

fn sendTerminalCreated(self: *Daemon, fd: posix.fd_t, terminal_id: u32) !void {
    var payload_buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&payload_buf);
    try Protocol.writeU32(fbs.writer(), terminal_id);
    try self.sendFrame(fd, @intFromEnum(Protocol.ServerMsg.terminal_created), payload_buf[0..fbs.pos]);
}

fn sendTerminalExited(self: *Daemon, fd: posix.fd_t, terminal_id: u32, exit_code: i32) !void {
    var payload_buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&payload_buf);
    try Protocol.writeU32(fbs.writer(), terminal_id);
    try Protocol.writeI32(fbs.writer(), exit_code);
    try self.sendFrame(fd, @intFromEnum(Protocol.ServerMsg.terminal_exited), payload_buf[0..fbs.pos]);
}

fn sendOutput(self: *Daemon, fd: posix.fd_t, terminal_id: u32, data: []const u8) !void {
    // Build payload: terminal_id (4 bytes) + raw data
    const payload_len = 4 + data.len;
    if (payload_len > Protocol.max_payload_size) return error.PayloadTooLarge;

    const payload = try self.alloc.alloc(u8, payload_len);
    defer self.alloc.free(payload);

    // Write terminal id in big-endian.
    const id_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, terminal_id));
    @memcpy(payload[0..4], &id_bytes);
    @memcpy(payload[4..][0..data.len], data);

    try self.sendFrame(fd, @intFromEnum(Protocol.ServerMsg.output), payload);
}

fn sendScreenSnapshot(self: *Daemon, fd: posix.fd_t, terminal: *const Terminal) !void {
    const slices = terminal.getBufferedOutput();
    const total_len = slices[0].len + slices[1].len;

    // Payload: terminal_id (4) + cols (2) + rows (2) + data
    const payload_len = 4 + 2 + 2 + total_len;
    if (payload_len > Protocol.max_payload_size) return error.PayloadTooLarge;

    const payload = try self.alloc.alloc(u8, payload_len);
    defer self.alloc.free(payload);

    // Write header fields.
    var offset: usize = 0;
    const id_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, terminal.id));
    @memcpy(payload[offset..][0..4], &id_bytes);
    offset += 4;

    const col_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, terminal.cols));
    @memcpy(payload[offset..][0..2], &col_bytes);
    offset += 2;

    const row_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, terminal.rows));
    @memcpy(payload[offset..][0..2], &row_bytes);
    offset += 2;

    // Copy ring buffer data.
    @memcpy(payload[offset..][0..slices[0].len], slices[0]);
    offset += slices[0].len;
    @memcpy(payload[offset..][0..slices[1].len], slices[1]);

    try self.sendFrame(fd, @intFromEnum(Protocol.ServerMsg.screen_snapshot), payload);
}

fn sendSessionList(self: *Daemon, fd: posix.fd_t) !void {
    // Payload: count (u32) + repeated { name (string), terminal_count (u32), created_at (i32) }
    var payload_buf = std.ArrayList(u8).init(self.alloc);
    defer payload_buf.deinit();
    const writer = payload_buf.writer();

    const count: u32 = @intCast(self.sessions.count());
    try Protocol.writeU32(writer, count);

    var it = self.sessions.valueIterator();
    while (it.next()) |ptr| {
        const session: *Session = ptr.*;
        try Protocol.writeString(writer, session.name);
        try Protocol.writeU32(writer, session.terminalCount());
        try Protocol.writeI32(writer, @truncate(session.created_at));
    }

    try self.sendFrame(fd, @intFromEnum(Protocol.ServerMsg.session_info), payload_buf.items);
}
