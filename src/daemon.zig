/// Daemon subsystem for persistent terminal session management.
///
/// The daemon runs as a long-lived background process that owns terminal
/// sessions. Clients (GUI windows) connect to the daemon over a Unix
/// domain socket and exchange length-prefixed binary frames defined by
/// the wire protocol.
pub const Protocol = @import("daemon/Protocol.zig");
pub const Session = @import("daemon/Session.zig");
pub const Terminal = @import("daemon/Terminal.zig");
