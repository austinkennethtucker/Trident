const ErrorList = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = struct {
    message: [:0]const u8,
};

/// The list of errors. This will use the arena allocator associated
/// with the config structure (or whatever allocated used to call ErrorList
/// functions).
list: std.ArrayListUnmanaged(Error) = .empty,

/// True if there are no errors.
pub fn empty(self: ErrorList) bool {
    return self.list.items.len == 0;
}

/// Add a new error to the list.
pub fn add(self: *ErrorList, alloc: Allocator, err: Error) !void {
    try self.list.append(alloc, err);
}

test "ErrorList: empty and add" {
    const testing = std.testing;
    var list: ErrorList = .{};
    defer list.list.deinit(testing.allocator);

    try testing.expect(list.empty());

    try list.add(testing.allocator, .{ .message = "test error" });
    try testing.expect(!list.empty());
    try testing.expectEqual(@as(usize, 1), list.list.items.len);
    try testing.expectEqualStrings("test error", list.list.items[0].message);

    try list.add(testing.allocator, .{ .message = "test error 2" });
    try testing.expect(!list.empty());
    try testing.expectEqual(@as(usize, 2), list.list.items.len);
    try testing.expectEqualStrings("test error", list.list.items[0].message);
    try testing.expectEqualStrings("test error 2", list.list.items[1].message);
}
