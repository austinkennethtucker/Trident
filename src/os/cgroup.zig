const std = @import("std");

const log = std.log.scoped(.@"linux-cgroup");

fn currentFromPath(buf: []u8, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var read_buf: [64]u8 = undefined;
    var file_reader = file.reader(&read_buf);
    const reader = &file_reader.interface;
    const len = reader.readSliceShort(buf) catch return null;
    if (len == 0) return null;
    const contents = buf[0..len];

    // Find the last ':'
    const idx = std.mem.lastIndexOfScalar(u8, contents, ':') orelse return null;
    return std.mem.trimRight(u8, contents[idx + 1 ..], " \r\n");
}

/// Returns the path to the cgroup for the given pid.
pub fn current(buf: []u8, pid: u32) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Read our cgroup by opening /proc/<pid>/cgroup and reading the first
    // line. The first line will look something like this:
    // 0::/user.slice/user-1000.slice/session-1.scope
    // The cgroup path is the third field.
    const path = std.fmt.bufPrint(&path_buf, "/proc/{}/cgroup", .{pid}) catch return null;
    return currentFromPath(buf, path);
}

const testing = std.testing;

test "cgroup currentFromPath" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = tmp.dir;
    var buf: [256]u8 = undefined;

    // Normal cases
    {
        try dir.writeFile(.{
            .sub_path = "cgroup1",
            .data = "0::/user.slice/user-1000.slice/session-1.scope\n",
        });
        const path = try dir.realpathAlloc(testing.allocator, "cgroup1");
        defer testing.allocator.free(path);

        const res = currentFromPath(&buf, path);
        try testing.expectEqualStrings("/user.slice/user-1000.slice/session-1.scope", res.?);
    }

    // With carriage return
    {
        try dir.writeFile(.{
            .sub_path = "cgroup2",
            .data = "1:name=systemd:/foo/bar\r\n",
        });
        const path = try dir.realpathAlloc(testing.allocator, "cgroup2");
        defer testing.allocator.free(path);

        const res = currentFromPath(&buf, path);
        try testing.expectEqualStrings("/foo/bar", res.?);
    }

    // Missing colon
    {
        try dir.writeFile(.{
            .sub_path = "cgroup3",
            .data = "invalid_no_colon\n",
        });
        const path = try dir.realpathAlloc(testing.allocator, "cgroup3");
        defer testing.allocator.free(path);

        const res = currentFromPath(&buf, path);
        try testing.expect(res == null);
    }

    // Empty file
    {
        try dir.writeFile(.{
            .sub_path = "cgroup4",
            .data = "",
        });
        const path = try dir.realpathAlloc(testing.allocator, "cgroup4");
        defer testing.allocator.free(path);

        const res = currentFromPath(&buf, path);
        try testing.expect(res == null);
    }

    // Invalid file
    {
        const path = "/nonexistent_dir/nonexistent_file";
        const res = currentFromPath(&buf, path);
        try testing.expect(res == null);
    }
}
