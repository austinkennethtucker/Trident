/// Wire protocol for daemon ↔ client communication.
///
/// Every message is wrapped in a frame:
///
///   [ payload_len : 4 bytes big-endian ] [ msg_type : 1 byte ] [ payload … ]
///
/// `payload_len` is the number of bytes *after* the header (i.e. does NOT
/// include the 5-byte header itself). The maximum allowed payload size is
/// `max_payload_size` (16 MiB by default). Strings inside payloads are
/// length-prefixed with a 2-byte big-endian u16.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Maximum payload size in bytes (16 MiB). Frames larger than this are
/// rejected during decoding with `error.FrameTooLarge`.
pub const max_payload_size: u32 = 16 * 1024 * 1024;

/// Size of the fixed frame header in bytes (4 for length + 1 for type).
pub const header_size: usize = 5;

// ---------------------------------------------------------------------------
// Message types
// ---------------------------------------------------------------------------

/// Messages sent from a client to the daemon.
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

/// Messages sent from the daemon to a client.
pub const ServerMsg = enum(u8) {
    output = 0x81,
    session_info = 0x82,
    terminal_created = 0x83,
    terminal_exited = 0x84,
    @"error" = 0x85,
    screen_snapshot = 0x86,
    session_layout = 0x87,
};

// ---------------------------------------------------------------------------
// Frame header
// ---------------------------------------------------------------------------

pub const FrameHeader = struct {
    /// Length of the payload that follows the header.
    payload_len: u32,
    /// Raw message-type byte (use `clientMsg()` / `serverMsg()` to cast).
    msg_type: u8,

    /// Try to interpret `msg_type` as a `ClientMsg`.
    pub fn clientMsg(self: FrameHeader) ?ClientMsg {
        return std.meta.intToEnum(ClientMsg, self.msg_type) catch null;
    }

    /// Try to interpret `msg_type` as a `ServerMsg`.
    pub fn serverMsg(self: FrameHeader) ?ServerMsg {
        return std.meta.intToEnum(ServerMsg, self.msg_type) catch null;
    }
};

// ---------------------------------------------------------------------------
// Integer helpers (all big-endian)
// ---------------------------------------------------------------------------

pub fn writeU32(writer: anytype, value: u32) !void {
    try writer.writeAll(&mem.toBytes(mem.nativeToBig(u32, value)));
}

pub fn readU32(reader: anytype) !u32 {
    var buf: [4]u8 = undefined;
    try reader.readNoEof(&buf);
    return mem.bigToNative(u32, mem.bytesToValue(u32, &buf));
}

pub fn writeU16(writer: anytype, value: u16) !void {
    try writer.writeAll(&mem.toBytes(mem.nativeToBig(u16, value)));
}

pub fn readU16(reader: anytype) !u16 {
    var buf: [2]u8 = undefined;
    try reader.readNoEof(&buf);
    return mem.bigToNative(u16, mem.bytesToValue(u16, &buf));
}

pub fn writeI32(writer: anytype, value: i32) !void {
    try writer.writeAll(&mem.toBytes(mem.nativeToBig(i32, value)));
}

pub fn readI32(reader: anytype) !i32 {
    var buf: [4]u8 = undefined;
    try reader.readNoEof(&buf);
    return mem.bigToNative(i32, mem.bytesToValue(i32, &buf));
}

// ---------------------------------------------------------------------------
// String encode / decode (u16 length-prefixed)
// ---------------------------------------------------------------------------

/// Write a length-prefixed string. The length prefix is a 2-byte big-endian
/// u16 giving the number of bytes in the string (max 65535).
pub fn writeString(writer: anytype, s: []const u8) !void {
    const len: u16 = std.math.cast(u16, s.len) orelse return error.StringTooLong;
    try writeU16(writer, len);
    try writer.writeAll(s);
}

/// Read a length-prefixed string. The caller owns the returned slice and
/// must free it with `alloc.free()`.
pub fn readString(alloc: Allocator, reader: anytype) ![]const u8 {
    const len: u16 = try readU16(reader);
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    try reader.readNoEof(buf);
    return buf;
}

// ---------------------------------------------------------------------------
// Frame encode / decode
// ---------------------------------------------------------------------------

/// Write a complete frame: header + payload.
pub fn writeFrame(writer: anytype, msg_type: u8, payload: []const u8) !void {
    const len: u32 = std.math.cast(u32, payload.len) orelse return error.PayloadTooLarge;
    if (len > max_payload_size) return error.PayloadTooLarge;
    try writeU32(writer, len);
    try writer.writeByte(msg_type);
    if (payload.len > 0) {
        try writer.writeAll(payload);
    }
}

/// Read the fixed 5-byte frame header. Returns `null` on clean EOF
/// (i.e. the very first byte is EOF). Returns `error.FrameTooLarge` if
/// the declared payload length exceeds `max_payload_size`.
pub fn readFrameHeader(reader: anytype) !?FrameHeader {
    // Try to read the first byte; a clean EOF here is normal.
    var buf: [header_size]u8 = undefined;
    buf[0] = reader.readByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    // The remaining 4 header bytes must be present — EOF here is an error.
    try reader.readNoEof(buf[1..header_size]);

    const payload_len = mem.bigToNative(u32, mem.bytesToValue(u32, buf[0..4]));
    if (payload_len > max_payload_size) return error.FrameTooLarge;

    return FrameHeader{
        .payload_len = payload_len,
        .msg_type = buf[4],
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "frame roundtrip" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const payload = "hello daemon";
    const msg_type: u8 = @intFromEnum(ClientMsg.create_session);

    try writeFrame(fbs.writer(), msg_type, payload);

    // Reset to read back.
    fbs.pos = 0;
    const hdr = (try readFrameHeader(fbs.reader())).?;
    try std.testing.expectEqual(msg_type, hdr.msg_type);
    try std.testing.expectEqual(@as(u32, payload.len), hdr.payload_len);
    try std.testing.expectEqual(ClientMsg.create_session, hdr.clientMsg().?);

    var payload_buf: [payload.len]u8 = undefined;
    try fbs.reader().readNoEof(&payload_buf);
    try std.testing.expectEqualStrings(payload, &payload_buf);
}

test "string roundtrip" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const original = "ghostty-session-42";
    try writeString(fbs.writer(), original);

    fbs.pos = 0;
    const decoded = try readString(std.testing.allocator, fbs.reader());
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "EOF returns null" {
    var empty: [0]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&empty);

    const result = try readFrameHeader(fbs.reader());
    try std.testing.expect(result == null);
}

test "oversized frame rejected" {
    var buf: [header_size]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    // Write a payload_len that exceeds max_payload_size.
    const too_big: u32 = max_payload_size + 1;
    try writeU32(fbs.writer(), too_big);
    try fbs.writer().writeByte(@intFromEnum(ServerMsg.output));

    fbs.pos = 0;
    const result = readFrameHeader(fbs.reader());
    try std.testing.expectError(error.FrameTooLarge, result);
}

test "payload roundtrip with multiple fields" {
    // Simulate a create_session payload: session name (string) + cols (u16) + rows (u16).
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    // Build payload into a separate buffer first.
    var payload_buf: [256]u8 = undefined;
    var payload_fbs = std.io.fixedBufferStream(&payload_buf);
    const pw = payload_fbs.writer();

    try writeString(pw, "my-session");
    try writeU16(pw, 120); // cols
    try writeU16(pw, 40); // rows
    try writeI32(pw, -1); // sentinel

    const payload = payload_buf[0..payload_fbs.pos];

    // Write as a frame.
    try writeFrame(fbs.writer(), @intFromEnum(ClientMsg.create_session), payload);

    // Read it back.
    fbs.pos = 0;
    const hdr = (try readFrameHeader(fbs.reader())).?;
    try std.testing.expectEqual(@as(u32, @intCast(payload.len)), hdr.payload_len);
    try std.testing.expectEqual(ClientMsg.create_session, hdr.clientMsg().?);

    // Decode payload fields.
    const r = fbs.reader();
    const name = try readString(std.testing.allocator, r);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("my-session", name);

    try std.testing.expectEqual(@as(u16, 120), try readU16(r));
    try std.testing.expectEqual(@as(u16, 40), try readU16(r));
    try std.testing.expectEqual(@as(i32, -1), try readI32(r));
}
