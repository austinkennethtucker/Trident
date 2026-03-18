const std = @import("std");
const Allocator = std.mem.Allocator;
const CoreSurface = @import("Surface.zig");

/// A group of tabs within a single split pane. Each pane in the split tree
/// holds a PaneTabGroup, which manages a stack of surfaces. Only the active
/// surface is rendered; background tabs keep their PTY running.
const PaneTabGroup = @This();

alloc: Allocator,
tabs: std.ArrayListUnmanaged(*CoreSurface),
active_index: usize,

pub fn init(alloc: Allocator, initial_surface: *CoreSurface) PaneTabGroup {
    var tabs: std.ArrayListUnmanaged(*CoreSurface) = .empty;
    tabs.append(alloc, initial_surface) catch @panic("OOM");
    return .{
        .alloc = alloc,
        .tabs = tabs,
        .active_index = 0,
    };
}

pub fn deinit(self: *PaneTabGroup) void {
    self.tabs.deinit(self.alloc);
}

/// Add a new tab after the active tab and make it active.
pub fn addTab(self: *PaneTabGroup, surface: *CoreSurface) !void {
    const insert_pos = self.active_index + 1;
    try self.tabs.insert(self.alloc, insert_pos, surface);
    self.active_index = insert_pos;
}

/// Remove the tab at the given index. If the active tab is removed,
/// the next tab becomes active (or the previous if it was the last).
/// If the last tab is removed, tabs will be empty.
pub fn removeTab(self: *PaneTabGroup, index: usize) void {
    if (index >= self.tabs.items.len) return;
    _ = self.tabs.orderedRemove(index);

    if (self.tabs.items.len == 0) {
        self.active_index = 0;
        return;
    }

    if (self.active_index >= self.tabs.items.len) {
        self.active_index = self.tabs.items.len - 1;
    } else if (index < self.active_index) {
        self.active_index -= 1;
    }
}

/// Set the active tab by index.
pub fn setActive(self: *PaneTabGroup, index: usize) void {
    if (index >= self.tabs.items.len) return;
    self.active_index = index;
}

/// Move a tab from one position to another.
pub fn moveTab(self: *PaneTabGroup, from: usize, to: usize) void {
    if (from >= self.tabs.items.len or to >= self.tabs.items.len) return;
    if (from == to) return;

    const tab = self.tabs.orderedRemove(from);

    // Adjust active_index for the removal
    var new_active = self.active_index;
    if (from == new_active) {
        // The moved tab was active; it stays active at its new position
        self.tabs.insert(self.alloc, to, tab) catch @panic("OOM: moveTab insert after remove");
        self.active_index = to;
        return;
    }

    if (from < new_active) {
        new_active -= 1;
    }

    self.tabs.insert(self.alloc, to, tab) catch @panic("OOM: moveTab insert after remove");

    if (to <= new_active) {
        new_active += 1;
    }
    self.active_index = new_active;
}

/// Returns the currently active surface.
pub fn activeTab(self: *const PaneTabGroup) *CoreSurface {
    return self.tabs.items[self.active_index];
}

/// Returns the number of tabs.
pub fn tabCount(self: *const PaneTabGroup) usize {
    return self.tabs.items.len;
}

// ─── Tests ───

test "init and basic properties" {
    const alloc = std.testing.allocator;
    const surface: *CoreSurface = @ptrFromInt(0x1000);
    var group = PaneTabGroup.init(alloc, surface);
    defer group.deinit();

    try std.testing.expectEqual(@as(usize, 1), group.tabCount());
    try std.testing.expectEqual(@as(usize, 0), group.active_index);
    try std.testing.expectEqual(surface, group.activeTab());
}

test "addTab inserts after active" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);
    const s2: *CoreSurface = @ptrFromInt(0x2000);
    const s3: *CoreSurface = @ptrFromInt(0x3000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();

    try group.addTab(s2);
    try std.testing.expectEqual(@as(usize, 2), group.tabCount());
    try std.testing.expectEqual(@as(usize, 1), group.active_index);
    try std.testing.expectEqual(s2, group.activeTab());

    try group.addTab(s3);
    try std.testing.expectEqual(@as(usize, 3), group.tabCount());
    try std.testing.expectEqual(@as(usize, 2), group.active_index);
    try std.testing.expectEqual(s3, group.activeTab());

    // Order should be: s1, s2, s3
    try std.testing.expectEqual(s1, group.tabs.items[0]);
    try std.testing.expectEqual(s2, group.tabs.items[1]);
    try std.testing.expectEqual(s3, group.tabs.items[2]);
}

test "removeTab active tab" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);
    const s2: *CoreSurface = @ptrFromInt(0x2000);
    const s3: *CoreSurface = @ptrFromInt(0x3000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();
    try group.addTab(s2);
    try group.addTab(s3);

    // Active is s3 at index 2. Remove it.
    group.removeTab(2);
    try std.testing.expectEqual(@as(usize, 2), group.tabCount());
    try std.testing.expectEqual(@as(usize, 1), group.active_index);
    try std.testing.expectEqual(s2, group.activeTab());
}

test "removeTab before active" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);
    const s2: *CoreSurface = @ptrFromInt(0x2000);
    const s3: *CoreSurface = @ptrFromInt(0x3000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();
    try group.addTab(s2);
    try group.addTab(s3);

    // Active is s3 at index 2. Remove s1 at index 0.
    group.removeTab(0);
    try std.testing.expectEqual(@as(usize, 2), group.tabCount());
    try std.testing.expectEqual(@as(usize, 1), group.active_index);
    try std.testing.expectEqual(s3, group.activeTab());
}

test "removeTab last tab leaves empty" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();

    group.removeTab(0);
    try std.testing.expectEqual(@as(usize, 0), group.tabCount());
}

test "removeTab out of bounds is no-op" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();

    group.removeTab(5);
    try std.testing.expectEqual(@as(usize, 1), group.tabCount());
}

test "setActive" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);
    const s2: *CoreSurface = @ptrFromInt(0x2000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();
    try group.addTab(s2);

    group.setActive(0);
    try std.testing.expectEqual(s1, group.activeTab());

    group.setActive(1);
    try std.testing.expectEqual(s2, group.activeTab());

    // Out of bounds: no-op
    group.setActive(99);
    try std.testing.expectEqual(s2, group.activeTab());
}

test "moveTab" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);
    const s2: *CoreSurface = @ptrFromInt(0x2000);
    const s3: *CoreSurface = @ptrFromInt(0x3000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();
    try group.addTab(s2);
    try group.addTab(s3);

    // Active is s3 at index 2. Move s1 from 0 to 2.
    group.moveTab(0, 2);
    // New order: s2, s3, s1
    try std.testing.expectEqual(s2, group.tabs.items[0]);
    try std.testing.expectEqual(s3, group.tabs.items[1]);
    try std.testing.expectEqual(s1, group.tabs.items[2]);
    // Active should still be s3, now at index 1
    try std.testing.expectEqual(s3, group.activeTab());
}

test "moveTab active tab" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);
    const s2: *CoreSurface = @ptrFromInt(0x2000);
    const s3: *CoreSurface = @ptrFromInt(0x3000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();
    try group.addTab(s2);
    try group.addTab(s3);

    // Active is s3 at index 2. Move it to index 0.
    group.moveTab(2, 0);
    // New order: s3, s1, s2
    try std.testing.expectEqual(s3, group.tabs.items[0]);
    try std.testing.expectEqual(s1, group.tabs.items[1]);
    try std.testing.expectEqual(s2, group.tabs.items[2]);
    // Active should be s3 at index 0
    try std.testing.expectEqual(@as(usize, 0), group.active_index);
    try std.testing.expectEqual(s3, group.activeTab());
}

test "moveTab out of bounds is no-op" {
    const alloc = std.testing.allocator;
    const s1: *CoreSurface = @ptrFromInt(0x1000);

    var group = PaneTabGroup.init(alloc, s1);
    defer group.deinit();

    group.moveTab(0, 5);
    try std.testing.expectEqual(@as(usize, 1), group.tabCount());
}
