const std = @import("std");

/// The built-in profile name for the quick/dropdown terminal.
pub const quick_profile_name: [:0]const u8 = "quick";

/// Dimension: either absolute pixels or a percentage of screen.
/// Parsed from strings like "400" (pixels) or "80%" (percentage).
pub const Dimension = struct {
    value: u32,
    unit: Unit,

    pub const Unit = enum { pixels, percent };

    pub fn initPixels(v: u32) Dimension {
        return .{ .value = v, .unit = .pixels };
    }

    pub fn initPercent(v: u32) Dimension {
        return .{ .value = v, .unit = .percent };
    }

    /// Parse from a string like "400" or "80%".
    /// Conforms to the parseCLI convention used by the config framework.
    pub fn parseCLI(input: ?[]const u8) !Dimension {
        const s = input orelse return error.ValueRequired;
        if (s.len == 0) return error.InvalidValue;
        if (s[s.len - 1] == '%') {
            const num = std.fmt.parseInt(u32, s[0 .. s.len - 1], 10) catch
                return error.InvalidValue;
            if (num == 0 or num > 100) return error.InvalidValue;
            return initPercent(num);
        }
        const num = std.fmt.parseInt(u32, s, 10) catch
            return error.InvalidValue;
        return initPixels(num);
    }
};

pub const Position = enum {
    center,
    top,
    bottom,
    left,
    right,
};

pub const Anchor = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,
};

/// Profile definition for a named popup terminal.
/// Field names are designed to work with the parseAutoStruct framework
/// (colon-delimited key:value pairs).
pub const PopupProfile = struct {
    position: Position = .center,
    anchor: ?Anchor = null,
    x: ?Dimension = null,
    y: ?Dimension = null,
    width: Dimension = Dimension.initPercent(80),
    height: Dimension = Dimension.initPercent(80),
    keybind: ?[]const u8 = null,
    command: ?[]const u8 = null,
    autohide: bool = true,
    persist: bool = true,
    cwd: ?[]const u8 = null,
    opacity: ?f64 = null,

    /// C-compatible representation of a PopupProfile.
    /// Sync with: ghostty_popup_profile_config_s in ghostty.h
    pub const C = extern struct {
        position: c_int,
        width_value: u32,
        width_is_percent: bool,
        height_value: u32,
        height_is_percent: bool,
        autohide: bool,
        persist: bool,
        /// Sentinel-terminated command string, or null if no command.
        /// This points into separately allocated memory (dupeZ'd),
        /// because the source `command` field is `?[]const u8` (no sentinel).
        command: ?[*:0]const u8,
        /// Sentinel-terminated CWD path, or null if not set.
        cwd: ?[*:0]const u8,
        /// Background opacity 0.0-1.0, or -1.0 if not set (extern structs can't have optionals).
        opacity: f64,
    };

    /// Convert to C-compatible representation.
    /// `command_z` is the pre-allocated sentinel-terminated copy of `command`,
    /// or null if no command was specified.
    /// `cwd_z` is the pre-allocated sentinel-terminated copy of `cwd`,
    /// or null if no cwd was specified.
    pub fn cval(self: PopupProfile, command_z: ?[*:0]const u8, cwd_z: ?[*:0]const u8) C {
        return .{
            .position = @intFromEnum(self.position),
            .width_value = self.width.value,
            .width_is_percent = self.width.unit == .percent,
            .height_value = self.height.value,
            .height_is_percent = self.height.unit == .percent,
            .autohide = self.autohide,
            .persist = self.persist,
            .command = command_z,
            .cwd = cwd_z,
            .opacity = if (self.opacity) |o| o else -1.0,
        };
    }
};

/// An owned popup profile paired with its name.
pub const NamedProfile = struct {
    name: [:0]const u8,
    profile: PopupProfile,

    pub fn init(alloc: std.mem.Allocator, name: []const u8, profile: PopupProfile) !NamedProfile {
        const owned_name = try alloc.dupeZ(u8, name);
        errdefer alloc.free(owned_name);
        return .{
            .name = owned_name,
            .profile = try cloneProfile(profile, alloc),
        };
    }

    pub fn clone(self: NamedProfile, alloc: std.mem.Allocator) !NamedProfile {
        return .{
            .name = try alloc.dupeZ(u8, self.name),
            .profile = try cloneProfile(self.profile, alloc),
        };
    }

    pub fn deinit(self: *const NamedProfile, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        freeProfileStrings(self.profile, alloc);
    }
};

pub const ResolvedWorkingDirectory = struct {
    path: ?[:0]const u8 = null,
    owned: bool = false,

    pub fn deinit(self: ResolvedWorkingDirectory, alloc: std.mem.Allocator) void {
        if (!self.owned) return;
        if (self.path) |path| alloc.free(path);
    }
};

pub fn resolveWorkingDirectory(
    alloc: std.mem.Allocator,
    explicit_cwd: ?[]const u8,
    inherited_cwd: ?[:0]const u8,
    home: ?[]const u8,
) !ResolvedWorkingDirectory {
    const cwd = explicit_cwd orelse return .{ .path = inherited_cwd };
    if ((cwd.len == 1 and cwd[0] == '~') or
        (cwd.len > 1 and cwd[0] == '~' and cwd[1] == '/'))
    {
        if (home) |home_dir| {
            return .{
                .path = try std.fmt.allocPrintSentinel(
                    alloc,
                    "{s}{s}",
                    .{ home_dir, cwd[1..] },
                    0,
                ),
                .owned = true,
            };
        }
    }

    return .{
        .path = try alloc.dupeZ(u8, cwd),
        .owned = true,
    };
}

pub fn profileChanged(old: PopupProfile, new: PopupProfile) bool {
    return old.position != new.position or
        old.anchor != new.anchor or
        !optionalDimensionEqual(old.x, new.x) or
        !optionalDimensionEqual(old.y, new.y) or
        old.width.value != new.width.value or
        old.width.unit != new.width.unit or
        old.height.value != new.height.value or
        old.height.unit != new.height.unit or
        old.autohide != new.autohide or
        old.persist != new.persist or
        !optionalF64Equal(old.opacity, new.opacity) or
        !optionalSliceEqual(old.command, new.command) or
        !optionalSliceEqual(old.cwd, new.cwd) or
        !optionalSliceEqual(old.keybind, new.keybind);
}

pub fn cloneProfile(profile: PopupProfile, alloc: std.mem.Allocator) !PopupProfile {
    var cloned = profile;
    if (profile.keybind) |keybind| cloned.keybind = try alloc.dupe(u8, keybind);
    errdefer if (cloned.keybind) |keybind| alloc.free(keybind);

    if (profile.command) |command| cloned.command = try alloc.dupe(u8, command);
    errdefer if (cloned.command) |command| alloc.free(command);

    if (profile.cwd) |cwd| cloned.cwd = try alloc.dupe(u8, cwd);
    return cloned;
}

pub fn freeProfileStrings(profile: PopupProfile, alloc: std.mem.Allocator) void {
    if (profile.keybind) |keybind| alloc.free(keybind);
    if (profile.command) |command| alloc.free(command);
    if (profile.cwd) |cwd| alloc.free(cwd);
}

/// Validate a popup profile name.
/// Allowed characters: [a-zA-Z0-9_-], must be non-empty.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

test "Dimension: parse pixels" {
    const d = try Dimension.parseCLI("400");
    try std.testing.expectEqual(@as(u32, 400), d.value);
    try std.testing.expectEqual(Dimension.Unit.pixels, d.unit);
}

test "Dimension: parse percent" {
    const d = try Dimension.parseCLI("80%");
    try std.testing.expectEqual(@as(u32, 80), d.value);
    try std.testing.expectEqual(Dimension.Unit.percent, d.unit);
}

test "Dimension: reject zero percent" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI("0%"));
}

test "Dimension: reject over 100 percent" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI("101%"));
}

test "Dimension: reject empty" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI(""));
}

test "Dimension: reject null" {
    try std.testing.expectError(error.ValueRequired, Dimension.parseCLI(null));
}

test "isValidName: valid names" {
    try std.testing.expect(isValidName("quick"));
    try std.testing.expect(isValidName("my-popup"));
    try std.testing.expect(isValidName("calc_2"));
}

test "isValidName: invalid names" {
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("bad name"));
    try std.testing.expect(!isValidName("bad:name"));
    try std.testing.expect(!isValidName("bad@name"));
}

test "PopupProfile: default cwd and opacity are null" {
    const p = PopupProfile{};
    try std.testing.expect(p.cwd == null);
    try std.testing.expect(p.opacity == null);
}

test "PopupProfile.C: opacity -1.0 means unset" {
    const p = PopupProfile{};
    const c = p.cval(null, null);
    try std.testing.expectEqual(@as(f64, -1.0), c.opacity);
    try std.testing.expect(c.cwd == null);
}

test "PopupProfile.C: opacity passes through" {
    const p = PopupProfile{ .opacity = 0.8 };
    const c = p.cval(null, null);
    try std.testing.expectEqual(@as(f64, 0.8), c.opacity);
}

test "resolveWorkingDirectory prefers explicit cwd over inherited cwd" {
    const testing = std.testing;
    const resolved = try resolveWorkingDirectory(
        testing.allocator,
        "~/projects/trident",
        "/tmp/inherited",
        "/Users/tester",
    );
    defer resolved.deinit(testing.allocator);

    try testing.expect(resolved.owned);
    try testing.expectEqualStrings("/Users/tester/projects/trident", resolved.path.?);
}

test "resolveWorkingDirectory falls back to inherited cwd" {
    const testing = std.testing;
    const inherited: [:0]const u8 = "/tmp/inherited";
    const resolved = try resolveWorkingDirectory(testing.allocator, null, inherited, null);

    try testing.expect(!resolved.owned);
    try testing.expectEqualStrings(inherited, resolved.path.?);
}

test "resolveWorkingDirectory keeps literal tilde when home is unavailable" {
    const testing = std.testing;
    const resolved = try resolveWorkingDirectory(testing.allocator, "~/projects/trident", null, null);
    defer resolved.deinit(testing.allocator);

    try testing.expect(resolved.owned);
    try testing.expectEqualStrings("~/projects/trident", resolved.path.?);
}

test "profileChanged detects hot reload relevant field changes" {
    const base = PopupProfile{
        .width = Dimension.initPercent(80),
        .height = Dimension.initPercent(40),
        .command = "echo hello",
        .cwd = "/tmp",
        .keybind = "ctrl+grave_accent",
        .opacity = 0.5,
    };

    try std.testing.expect(!profileChanged(base, base));
    try std.testing.expect(profileChanged(base, .{
        .width = Dimension.initPercent(90),
        .height = base.height,
        .command = base.command,
        .cwd = base.cwd,
        .keybind = base.keybind,
        .opacity = base.opacity,
    }));
    try std.testing.expect(profileChanged(base, .{
        .width = base.width,
        .height = base.height,
        .command = "echo updated",
        .cwd = base.cwd,
        .keybind = base.keybind,
        .opacity = base.opacity,
    }));
}

fn optionalDimensionEqual(a: ?Dimension, b: ?Dimension) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.value == b.?.value and a.?.unit == b.?.unit;
}

fn optionalSliceEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn optionalF64Equal(a: ?f64, b: ?f64) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}
