const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.browser_har);

/// A single HTTP header (name/value pair).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Where the request was captured.
pub const Source = enum {
    /// Captured via the relay/proxy path.
    relay,
    /// Captured via JavaScript interception in the page.
    js_intercept,
};

/// Per-entry timing breakdown in milliseconds.
/// -1 means "not applicable / not measured" (HAR 1.2 convention).
pub const HARTimings = struct {
    connect_ms: f64 = -1,
    send_ms: f64 = -1,
    wait_ms: f64 = -1,
    receive_ms: f64 = -1,

    /// Sum of non-negative timings (HAR 1.2: total must equal sum of
    /// all phases that are >= 0).
    pub fn total(self: HARTimings) f64 {
        var t: f64 = 0;
        if (self.connect_ms >= 0) t += self.connect_ms;
        if (self.send_ms >= 0) t += self.send_ms;
        if (self.wait_ms >= 0) t += self.wait_ms;
        if (self.receive_ms >= 0) t += self.receive_ms;
        return t;
    }
};

/// A single recorded HTTP transaction.
pub const HAREntry = struct {
    /// Unix epoch in milliseconds when the request started.
    started_ms: i64,

    method: []const u8,
    url: []const u8,

    /// e.g. "HTTP/1.1"
    http_version: []const u8 = "HTTP/1.1",

    request_headers: []const Header = &.{},

    response_status: u16,
    response_status_text: []const u8,
    response_headers: []const Header = &.{},

    /// -1 means unknown (HAR 1.2 convention).
    response_body_size: i64 = -1,

    timings: HARTimings = .{},
    source: Source,
};

/// Thread-safe HTTP Archive (HAR 1.2) recorder.
///
/// Typical lifecycle:
///   var rec = HARRecorder.init(alloc);
///   defer rec.deinit();
///   rec.start();
///   rec.append(.{ ... });
///   const json = try rec.exportJSON(alloc);
///   defer alloc.free(json);
///   rec.stop();
pub const HARRecorder = struct {
    alloc: Allocator,
    entries: std.ArrayList(HAREntry),
    is_recording: bool,
    mutex: std.Thread.Mutex,

    pub fn init(alloc: Allocator) HARRecorder {
        return .{
            .alloc = alloc,
            .entries = .empty,
            .is_recording = false,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *HARRecorder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entries.deinit(self.alloc);
    }

    /// Begin a new recording session. Clears any previously recorded entries
    /// and sets `is_recording = true`.
    pub fn start(self: *HARRecorder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entries.clearRetainingCapacity();
        self.is_recording = true;
    }

    /// Stop the recording session. Entries are preserved for export.
    pub fn stop(self: *HARRecorder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_recording = false;
    }

    /// Append an entry. Silently ignored when not recording.
    pub fn append(self: *HARRecorder, entry: HAREntry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.is_recording) return;
        self.entries.append(self.alloc, entry) catch |err| {
            log.err("failed to append HAR entry: {}", .{err});
        };
    }

    /// Returns the number of recorded entries.
    pub fn entryCount(self: *HARRecorder) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    /// Export all recorded entries as a HAR 1.2 JSON string.
    /// The caller owns the returned slice and must free it with `alloc.free`.
    pub fn exportJSON(self: *HARRecorder, alloc: Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);

        try w.writeAll("{\"log\":{");
        try w.writeAll("\"version\":\"1.2\",");
        try w.writeAll("\"creator\":{\"name\":\"Trident\",\"version\":\"1.0\"},");
        try w.writeAll("\"entries\":[");

        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try w.writeByte(',');
            try writeEntry(w, entry);
        }

        try w.writeAll("]}}");

        return buf.toOwnedSlice(alloc);
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    fn writeEntry(w: anytype, entry: HAREntry) !void {
        try w.writeByte('{');

        // startedDateTime — ISO 8601 from epoch millis
        const secs: u64 = @intCast(@divFloor(entry.started_ms, 1000));
        const ms_part: u64 = @intCast(@mod(entry.started_ms, 1000));
        const epoch = std.time.epoch;
        const epoch_secs = epoch.EpochSeconds{ .secs = secs };
        const year_day = epoch_secs.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch_secs.getDaySeconds();

        try w.print(
            "\"startedDateTime\":\"{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\",",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_secs.getHoursIntoDay(),
                day_secs.getMinutesIntoHour(),
                day_secs.getSecondsIntoMinute(),
                ms_part,
            },
        );

        // time (total duration)
        try w.print("\"time\":{d:.3},", .{entry.timings.total()});

        // request object
        try w.writeAll("\"request\":{");
        try w.writeAll("\"method\":\"");
        try writeJSONString(w, entry.method);
        try w.writeAll("\",");
        try w.writeAll("\"url\":\"");
        try writeJSONString(w, entry.url);
        try w.writeAll("\",");
        try w.writeAll("\"httpVersion\":\"");
        try writeJSONString(w, entry.http_version);
        try w.writeAll("\",");
        try w.writeAll("\"headers\":");
        try writeHeaders(w, entry.request_headers);
        try w.writeAll(",\"queryString\":[],\"cookies\":[],\"headersSize\":-1,\"bodySize\":-1");
        try w.writeByte('}');

        try w.writeByte(',');

        // response object
        try w.writeAll("\"response\":{");
        try w.print("\"status\":{d},", .{entry.response_status});
        try w.writeAll("\"statusText\":\"");
        try writeJSONString(w, entry.response_status_text);
        try w.writeAll("\",");
        try w.writeAll("\"httpVersion\":\"");
        try writeJSONString(w, entry.http_version);
        try w.writeAll("\",");
        try w.writeAll("\"headers\":");
        try writeHeaders(w, entry.response_headers);
        try w.writeAll(",\"cookies\":[],\"redirectURL\":\"\",\"headersSize\":-1,");
        try w.print("\"bodySize\":{d},", .{entry.response_body_size});
        try w.writeAll("\"content\":{\"size\":");
        try w.print("{d}", .{entry.response_body_size});
        try w.writeAll(",\"mimeType\":\"\"}}");

        try w.writeByte(',');

        // cache
        try w.writeAll("\"cache\":{},");

        // timings
        try w.writeAll("\"timings\":{");
        try w.print("\"connect\":{d:.3},", .{entry.timings.connect_ms});
        try w.print("\"send\":{d:.3},", .{entry.timings.send_ms});
        try w.print("\"wait\":{d:.3},", .{entry.timings.wait_ms});
        try w.print("\"receive\":{d:.3}", .{entry.timings.receive_ms});
        try w.writeByte('}');

        try w.writeByte(',');

        // non-standard extension field for source tracking
        try w.writeAll("\"_source\":\"");
        try w.writeAll(switch (entry.source) {
            .relay => "relay",
            .js_intercept => "js_intercept",
        });
        try w.writeByte('"');

        try w.writeByte('}');
    }

    fn writeHeaders(w: anytype, headers: []const Header) !void {
        try w.writeByte('[');
        for (headers, 0..) |h, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":\"");
            try writeJSONString(w, h.name);
            try w.writeAll("\",\"value\":\"");
            try writeJSONString(w, h.value);
            try w.writeAll("\"}");
        }
        try w.writeByte(']');
    }

    /// Writes `s` with JSON string escaping.
    pub fn writeJSONString(w: anytype, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    try w.print("\\u{x:0>4}", .{c});
                },
                else => try w.writeByte(c),
            }
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "HARRecorder: init and deinit" {
    var rec = HARRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try std.testing.expectEqual(@as(usize, 0), rec.entryCount());
    try std.testing.expect(!rec.is_recording);
}

test "HARRecorder: start clears entries and enables recording" {
    var rec = HARRecorder.init(std.testing.allocator);
    defer rec.deinit();

    rec.start();
    try std.testing.expect(rec.is_recording);
    rec.append(.{
        .started_ms = 0,
        .method = "GET",
        .url = "http://example.com/",
        .response_status = 200,
        .response_status_text = "OK",
        .source = .relay,
    });
    try std.testing.expectEqual(@as(usize, 1), rec.entryCount());

    // start() again should clear
    rec.start();
    try std.testing.expectEqual(@as(usize, 0), rec.entryCount());
}

test "HARRecorder: append ignored when not recording" {
    var rec = HARRecorder.init(std.testing.allocator);
    defer rec.deinit();

    rec.append(.{
        .started_ms = 0,
        .method = "GET",
        .url = "http://example.com/",
        .response_status = 200,
        .response_status_text = "OK",
        .source = .relay,
    });
    try std.testing.expectEqual(@as(usize, 0), rec.entryCount());
}

test "HARRecorder: stop preserves entries" {
    var rec = HARRecorder.init(std.testing.allocator);
    defer rec.deinit();

    rec.start();
    rec.append(.{
        .started_ms = 1_000,
        .method = "POST",
        .url = "http://example.com/api",
        .response_status = 204,
        .response_status_text = "No Content",
        .source = .js_intercept,
    });
    rec.stop();
    try std.testing.expect(!rec.is_recording);
    try std.testing.expectEqual(@as(usize, 1), rec.entryCount());
}

test "HARRecorder: exportJSON is valid JSON structure" {
    var rec = HARRecorder.init(std.testing.allocator);
    defer rec.deinit();

    rec.start();
    rec.append(.{
        .started_ms = 1_700_000_000_000, // 2023-11-14 ~22:13 UTC
        .method = "GET",
        .url = "https://example.com/path?q=1",
        .http_version = "HTTP/2",
        .request_headers = &.{
            .{ .name = "Accept", .value = "text/html" },
        },
        .response_status = 200,
        .response_status_text = "OK",
        .response_headers = &.{
            .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
        },
        .response_body_size = 1024,
        .timings = .{
            .connect_ms = 10.5,
            .send_ms = 0.2,
            .wait_ms = 120.3,
            .receive_ms = 5.0,
        },
        .source = .relay,
    });

    const json = try rec.exportJSON(std.testing.allocator);
    defer std.testing.allocator.free(json);

    // Must start and end correctly
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"log\":{"));
    try std.testing.expect(std.mem.endsWith(u8, json, "]}}"));

    // Key fields present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":\"1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"_source\":\"relay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bodySize\":1024") != null);
}

test "HARTimings: total sums only non-negative values" {
    const t = HARTimings{ .send_ms = 5.0, .wait_ms = 100.0, .receive_ms = -1 };
    try std.testing.expectApproxEqAbs(@as(f64, 105.0), t.total(), 0.001);
}

test "writeJSONString: escapes special characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try HARRecorder.writeJSONString(buf.writer(std.testing.allocator), "say \"hello\\world\"\n");
    try std.testing.expectEqualStrings(
        "say \\\"hello\\\\world\\\"\\n",
        buf.items,
    );
}
