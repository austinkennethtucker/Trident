//! X11 window protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gdk = @import("gdk");
const gdk_x11 = @import("gdk_x11");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const xlib = @import("xlib");

pub const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/XKBlib.h");
});

const input = @import("../../../input.zig");
const popupmod = @import("../../popup.zig");
const Config = @import("../../../config.zig").Config;
const ApprtWindow = @import("../class/window.zig").Window;

const log = std.log.scoped(.gtk_x11);

pub const App = struct {
    display: *xlib.Display,
    base_event_code: c_int,
    atoms: Atoms,

    pub fn init(
        _: Allocator,
        gdk_display: *gdk.Display,
        app_id: [:0]const u8,
        config: *const Config,
    ) !?App {
        // If the display isn't X11, then we don't need to do anything.
        const gdk_x11_display = gobject.ext.cast(
            gdk_x11.X11Display,
            gdk_display,
        ) orelse return null;

        const xlib_display = gdk_x11_display.getXdisplay();

        const x11_program_name: [:0]const u8 = if (config.@"x11-instance-name") |pn|
            pn
        else if (builtin.mode == .Debug)
            "ghostty-debug"
        else
            "ghostty";

        // Set the X11 window class property (WM_CLASS) if are are on an X11
        // display.
        //
        // Note that we also set the program name here using g_set_prgname.
        // This is how the instance name field for WM_CLASS is derived when
        // calling gdk_x11_display_set_program_class; there does not seem to be
        // a way to set it directly. It does not look like this is being set by
        // our other app initialization routines currently, but since we're
        // currently deriving its value from x11-instance-name effectively, I
        // feel like gating it behind an X11 check is better intent.
        //
        // This makes the property show up like so when using xprop:
        //
        //     WM_CLASS(STRING) = "ghostty", "com.mitchellh.ghostty"
        //
        // Append "-debug" on both when using the debug build.
        glib.setPrgname(x11_program_name);
        gdk_x11.X11Display.setProgramClass(gdk_display, app_id);

        // XKB
        log.debug("Xkb.init: initializing Xkb", .{});
        log.debug("Xkb.init: running XkbQueryExtension", .{});
        var opcode: c_int = 0;
        var base_event_code: c_int = 0;
        var base_error_code: c_int = 0;
        var major = c.XkbMajorVersion;
        var minor = c.XkbMinorVersion;
        if (c.XkbQueryExtension(
            @ptrCast(@alignCast(xlib_display)),
            &opcode,
            &base_event_code,
            &base_error_code,
            &major,
            &minor,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbQueryExtension", .{});
            return error.XkbInitializationError;
        }

        log.debug("Xkb.init: running XkbSelectEventDetails", .{});
        if (c.XkbSelectEventDetails(
            @ptrCast(@alignCast(xlib_display)),
            c.XkbUseCoreKbd,
            c.XkbStateNotify,
            c.XkbModifierStateMask,
            c.XkbModifierStateMask,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbSelectEventDetails", .{});
            return error.XkbInitializationError;
        }

        return .{
            .display = xlib_display,
            .base_event_code = base_event_code,
            .atoms = .init(gdk_x11_display),
        };
    }

    pub fn deinit(self: *App, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    /// Checks for an immediate pending XKB state update event, and returns the
    /// keyboard state based on if it finds any. This is necessary as the
    /// standard GTK X11 API (and X11 in general) does not include the current
    /// key pressed in any modifier state snapshot for that event (e.g. if the
    /// pressed key is a modifier, that is not necessarily reflected in the
    /// modifiers).
    ///
    /// Returns null if there is no event. In this case, the caller should fall
    /// back to the standard GDK modifier state (this likely means the key
    /// event did not result in a modifier change).
    pub fn eventMods(
        self: App,
        device: ?*gdk.Device,
        gtk_mods: gdk.ModifierType,
    ) ?input.Mods {
        _ = device;
        _ = gtk_mods;

        // Shoutout to Mozilla for figuring out a clean way to do this, this is
        // paraphrased from Firefox/Gecko in widget/gtk/nsGtkKeyUtils.cpp.
        if (c.XEventsQueued(
            @ptrCast(@alignCast(self.display)),
            c.QueuedAfterReading,
        ) == 0) return null;

        var nextEvent: c.XEvent = undefined;
        _ = c.XPeekEvent(@ptrCast(@alignCast(self.display)), &nextEvent);
        if (nextEvent.type != self.base_event_code) return null;

        const xkb_event: *c.XkbEvent = @ptrCast(&nextEvent);
        if (xkb_event.any.xkb_type != c.XkbStateNotify) return null;

        const xkb_state_notify_event: *c.XkbStateNotifyEvent = @ptrCast(xkb_event);
        // Check the state according to XKB masks.
        const lookup_mods = xkb_state_notify_event.lookup_mods;
        var mods: input.Mods = .{};

        log.debug("X11: found extra XkbStateNotify event w/lookup_mods: {b}", .{lookup_mods});
        if (lookup_mods & c.ShiftMask != 0) mods.shift = true;
        if (lookup_mods & c.ControlMask != 0) mods.ctrl = true;
        if (lookup_mods & c.Mod1Mask != 0) mods.alt = true;
        if (lookup_mods & c.Mod4Mask != 0) mods.super = true;
        if (lookup_mods & c.LockMask != 0) mods.caps_lock = true;

        return mods;
    }

    pub fn supportsPopup(_: App) bool {
        return true;
    }

    pub fn initPopup(_: *App, apprt_window: *ApprtWindow) !void {
        // Remove window decorations for popup terminals.
        // This must happen before the window is realized (before Window.init).
        apprt_window.as(gtk.Window).setDecorated(0);
    }
};

pub const Window = struct {
    app: *App,
    apprt_window: *ApprtWindow,
    x11_surface: *gdk_x11.X11Surface,

    blur_region: Region = .{},

    // Cache last applied values to avoid redundant X11 property updates.
    // Redundant property updates seem to cause some visual glitches
    // with some window managers: https://github.com/ghostty-org/ghostty/pull/8075
    last_applied_blur_region: ?Region = null,
    last_applied_decoration_hints: ?MotifWMHints = null,
    popup_placement_warned: bool = false,

    pub fn init(
        alloc: Allocator,
        app: *App,
        apprt_window: *ApprtWindow,
    ) !Window {
        _ = alloc;

        const surface = apprt_window.as(gtk.Native).getSurface() orelse
            return error.NotX11Surface;

        const x11_surface = gobject.ext.cast(
            gdk_x11.X11Surface,
            surface,
        ) orelse return error.NotX11Surface;

        // For popup/quick-terminal windows, update size and position
        // when the window enters a new monitor.
        if (apprt_window.isQuickTerminal()) {
            _ = gdk.Surface.signals.enter_monitor.connect(
                surface,
                *ApprtWindow,
                enteredMonitor,
                apprt_window,
                .{},
            );
        }

        return .{
            .app = app,
            .apprt_window = apprt_window,
            .x11_surface = x11_surface,
        };
    }

    pub fn deinit(self: Window, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn resizeEvent(self: *Window) !void {
        // The blur region must update with window resizes
        try self.syncBlur();
    }

    pub fn syncAppearance(self: *Window) !void {
        // The user could have toggled between CSDs and SSDs,
        // therefore we need to recalculate the blur region offset.
        self.blur_region = blur: {
            // NOTE(pluiedev): CSDs are a f--king mistake.
            // Please, GNOME, stop this nonsense of making a window ~30% bigger
            // internally than how they really are just for your shadows and
            // rounded corners and all that fluff. Please. I beg of you.
            var x: f64 = 0;
            var y: f64 = 0;

            self.apprt_window.as(gtk.Native).getSurfaceTransform(&x, &y);

            // Transform surface coordinates to device coordinates.
            const scale: f64 = @floatFromInt(self.apprt_window.as(gtk.Widget).getScaleFactor());
            x *= scale;
            y *= scale;

            break :blur .{
                .x = @intFromFloat(x),
                .y = @intFromFloat(y),
            };
        };
        self.syncBlur() catch |err| {
            log.err("failed to synchronize blur={}", .{err});
        };
        self.syncDecorations() catch |err| {
            log.err("failed to synchronize decorations={}", .{err});
        };

        if (self.apprt_window.isQuickTerminal()) {
            self.syncPopup() catch |err| {
                log.warn("failed to sync popup appearance={}", .{err});
            };
        }
    }

    pub fn clientSideDecorationEnabled(self: Window) bool {
        return switch (self.apprt_window.getWindowDecoration()) {
            .auto, .client => true,
            .server, .none => false,
        };
    }

    fn syncBlur(self: *Window) !void {
        // FIXME: This doesn't currently factor in rounded corners on Adwaita,
        // which means that the blur region will grow slightly outside of the
        // window borders. Unfortunately, actually calculating the rounded
        // region can be quite complex without having access to existing APIs
        // (cf. https://github.com/cutefishos/fishui/blob/41d4ba194063a3c7fff4675619b57e6ac0504f06/src/platforms/linux/blurhelper/windowblur.cpp#L134)
        // and I think it's not really noticeable enough to justify the effort.
        // (Wayland also has this visual artifact anyway...)

        const gtk_widget = self.apprt_window.as(gtk.Widget);
        const config = if (self.apprt_window.getConfig()) |v| v.get() else return;

        // When blur is disabled, remove the property if it was previously set
        const blur = config.@"background-blur";
        if (!blur.enabled()) {
            if (self.last_applied_blur_region != null) {
                try self.deleteProperty(self.app.atoms.kde_blur);
                self.last_applied_blur_region = null;
            }

            return;
        }

        // Transform surface coordinates to device coordinates.
        const scale = gtk_widget.getScaleFactor();
        self.blur_region.width = gtk_widget.getWidth() * scale;
        self.blur_region.height = gtk_widget.getHeight() * scale;

        // Only update X11 properties when the blur region actually changes
        if (self.last_applied_blur_region) |last| {
            if (std.meta.eql(self.blur_region, last)) return;
        }

        log.debug("set blur={}, window xid={}, region={}", .{
            blur,
            self.x11_surface.getXid(),
            self.blur_region,
        });

        try self.changeProperty(
            Region,
            self.app.atoms.kde_blur,
            c.XA_CARDINAL,
            ._32,
            .{ .mode = .replace },
            &self.blur_region,
        );
        self.last_applied_blur_region = self.blur_region;
    }

    fn syncDecorations(self: *Window) !void {
        var hints: MotifWMHints = .{};

        self.getWindowProperty(
            MotifWMHints,
            self.app.atoms.motif_wm_hints,
            self.app.atoms.motif_wm_hints,
            ._32,
            .{},
            &hints,
        ) catch |err| switch (err) {
            // motif_wm_hints is already initialized, so this is fine
            error.PropertyNotFound => {},

            error.RequestFailed,
            error.PropertyTypeMismatch,
            error.PropertyFormatMismatch,
            => return err,
        };

        hints.flags.decorations = true;
        hints.decorations.all = switch (self.apprt_window.getWindowDecoration()) {
            .server => true,
            .auto, .client, .none => false,
        };

        // Only update decoration hints when they actually change
        if (self.last_applied_decoration_hints) |last| {
            if (std.meta.eql(hints, last)) return;
        }

        try self.changeProperty(
            MotifWMHints,
            self.app.atoms.motif_wm_hints,
            self.app.atoms.motif_wm_hints,
            ._32,
            .{ .mode = .replace },
            &hints,
        );
        self.last_applied_decoration_hints = hints;
    }

    fn syncPopup(self: *Window) !void {
        const xid = self.x11_surface.getXid();
        const display: *c.Display = @ptrCast(@alignCast(self.app.display));

        // Set window type to dialog so WMs float it
        var window_type = [1]c.Atom{self.app.atoms.net_wm_window_type_dialog};
        _ = c.XChangeProperty(
            display,
            xid,
            self.app.atoms.net_wm_window_type,
            c.XA_ATOM,
            32,
            c.PropModeReplace,
            @ptrCast(&window_type),
            1,
        );

        // Set _NET_WM_STATE: above + skip_taskbar + skip_pager
        var state_atoms = [3]c.Atom{
            self.app.atoms.net_wm_state_above,
            self.app.atoms.net_wm_state_skip_taskbar,
            self.app.atoms.net_wm_state_skip_pager,
        };
        _ = c.XChangeProperty(
            display,
            xid,
            self.app.atoms.net_wm_state,
            c.XA_ATOM,
            32,
            c.PropModeReplace,
            @ptrCast(&state_atoms),
            3,
        );

        // Warn once about unsupported placement offsets (anchor, x, y)
        if (self.apprt_window.isPopup() and !self.popup_placement_warned) {
            const popup_anchor = self.apprt_window.popupAnchor();
            const popup_x = self.apprt_window.popupX();
            const popup_y = self.apprt_window.popupY();
            if (popup_anchor != null or popup_x != null or popup_y != null) {
                log.warn(
                    "popup profile placement offsets and anchors are not yet fully supported on X11; using position only",
                    .{},
                );
                self.popup_placement_warned = true;
            }
        }

        // Get monitor geometry for positioning
        const gdk_display = gdk.Display.getDefault() orelse return;
        const monitors = gdk_display.getMonitors();
        const first = monitors.getObject(0) orelse return;
        const monitor: *gdk.Monitor = @ptrCast(@alignCast(first));

        var monitor_geo: gdk.Rectangle = undefined;
        monitor.getGeometry(&monitor_geo);

        const config = if (self.apprt_window.getConfig()) |v| v.get() else return;
        const position = popupPosition(self.apprt_window, config);

        const win_w: c_int = self.apprt_window.as(gtk.Widget).getWidth();
        const win_h: c_int = self.apprt_window.as(gtk.Widget).getHeight();

        const mon_x = monitor_geo.f_x;
        const mon_y = monitor_geo.f_y;
        const mon_w = monitor_geo.f_width;
        const mon_h = monitor_geo.f_height;

        var x: c_int = undefined;
        var y: c_int = undefined;

        switch (position) {
            .center => {
                x = mon_x + @divTrunc(mon_w - win_w, 2);
                y = mon_y + @divTrunc(mon_h - win_h, 2);
            },
            .top => {
                x = mon_x + @divTrunc(mon_w - win_w, 2);
                y = mon_y;
            },
            .bottom => {
                x = mon_x + @divTrunc(mon_w - win_w, 2);
                y = mon_y + mon_h - win_h;
            },
            .left => {
                x = mon_x;
                y = mon_y + @divTrunc(mon_h - win_h, 2);
            },
            .right => {
                x = mon_x + mon_w - win_w;
                y = mon_y + @divTrunc(mon_h - win_h, 2);
            },
        }

        _ = c.XMoveWindow(display, xid, x, y);
        _ = c.XRaiseWindow(display, xid);
    }

    pub fn addSubprocessEnv(self: *Window, env: *std.process.EnvMap) !void {
        var buf: [64]u8 = undefined;
        const window_id = try std.fmt.bufPrint(
            &buf,
            "{}",
            .{self.x11_surface.getXid()},
        );

        try env.put("WINDOWID", window_id);
    }

    pub fn setUrgent(self: *Window, urgent: bool) !void {
        self.x11_surface.setUrgencyHint(@intFromBool(urgent));
    }

    fn getWindowProperty(
        self: *Window,
        comptime T: type,
        name: c.Atom,
        typ: c.Atom,
        comptime format: PropertyFormat,
        options: struct {
            offset: c_long = 0,
            length: c_long = std.math.maxInt(c_long),
            delete: bool = false,
        },
        result: *T,
    ) GetWindowPropertyError!void {
        // FIXME: Maybe we should switch to libxcb one day.
        // Sounds like a much better idea than whatever this is
        var actual_type_return: c.Atom = undefined;
        var actual_format_return: c_int = undefined;
        var nitems_return: c_ulong = undefined;
        var bytes_after_return: c_ulong = undefined;
        var prop_return: ?format.bufferType() = null;

        const code = c.XGetWindowProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
            options.offset,
            options.length,
            @intFromBool(options.delete),
            typ,
            &actual_type_return,
            &actual_format_return,
            &nitems_return,
            &bytes_after_return,
            @ptrCast(&prop_return),
        );
        if (code != c.Success) return error.RequestFailed;

        if (actual_type_return == c.None) return error.PropertyNotFound;
        if (typ != actual_type_return) return error.PropertyTypeMismatch;
        if (@intFromEnum(format) != actual_format_return) return error.PropertyFormatMismatch;

        const data_ptr: *T = @ptrCast(prop_return);
        result.* = data_ptr.*;
        _ = c.XFree(prop_return);
    }

    fn changeProperty(
        self: *Window,
        comptime T: type,
        name: c.Atom,
        typ: c.Atom,
        comptime format: PropertyFormat,
        options: struct {
            mode: PropertyChangeMode,
        },
        value: *T,
    ) X11Error!void {
        const data: format.bufferType() = @ptrCast(value);

        const status = c.XChangeProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
            typ,
            @intFromEnum(format),
            @intFromEnum(options.mode),
            data,
            @divExact(@sizeOf(T), @sizeOf(format.elemType())),
        );

        // For some godforsaken reason Xlib alternates between
        // error values (0 = success) and booleans (1 = success), and they look exactly
        // the same in the signature (just `int`, since Xlib is written in C89)...
        if (status == 0) return error.RequestFailed;
    }

    fn deleteProperty(self: *Window, name: c.Atom) X11Error!void {
        const status = c.XDeleteProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
        );
        if (status == 0) return error.RequestFailed;
    }
};

const X11Error = error{
    RequestFailed,
};

const GetWindowPropertyError = X11Error || error{
    PropertyNotFound,
    PropertyTypeMismatch,
    PropertyFormatMismatch,
};

const Atoms = struct {
    kde_blur: c.Atom,
    motif_wm_hints: c.Atom,
    net_wm_window_type: c.Atom,
    net_wm_window_type_dialog: c.Atom,
    net_wm_state: c.Atom,
    net_wm_state_above: c.Atom,
    net_wm_state_skip_taskbar: c.Atom,
    net_wm_state_skip_pager: c.Atom,

    fn init(display: *gdk_x11.X11Display) Atoms {
        return .{
            .kde_blur = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_KDE_NET_WM_BLUR_BEHIND_REGION",
            ),
            .motif_wm_hints = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_MOTIF_WM_HINTS",
            ),
            .net_wm_window_type = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_NET_WM_WINDOW_TYPE",
            ),
            .net_wm_window_type_dialog = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_NET_WM_WINDOW_TYPE_DIALOG",
            ),
            .net_wm_state = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_NET_WM_STATE",
            ),
            .net_wm_state_above = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_NET_WM_STATE_ABOVE",
            ),
            .net_wm_state_skip_taskbar = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_NET_WM_STATE_SKIP_TASKBAR",
            ),
            .net_wm_state_skip_pager = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_NET_WM_STATE_SKIP_PAGER",
            ),
        };
    }
};

const PropertyChangeMode = enum(c_int) {
    replace = c.PropModeReplace,
    prepend = c.PropModePrepend,
    append = c.PropModeAppend,
};

const PropertyFormat = enum(c_int) {
    _8 = 8,
    _16 = 16,
    _32 = 32,

    fn elemType(comptime self: PropertyFormat) type {
        return switch (self) {
            ._8 => c_char,
            ._16 => c_int,
            ._32 => c_long,
        };
    }

    fn bufferType(comptime self: PropertyFormat) type {
        // The buffer type has to be a multi-pointer to bytes
        // *aligned to the element type* (very important,
        // otherwise you'll read garbage!)
        //
        // I know this is really ugly. X11 is ugly. I consider it apropos.
        return [*]align(@alignOf(self.elemType())) u8;
    }
};

const Region = extern struct {
    x: c_long = 0,
    y: c_long = 0,
    width: c_long = 0,
    height: c_long = 0,
};

// See Xm/MwmUtil.h, packaged with the Motif Window Manager
const MotifWMHints = extern struct {
    flags: packed struct(c_ulong) {
        _pad: u1 = 0,
        decorations: bool = false,

        // We don't really care about the other flags
        _rest: std.meta.Int(.unsigned, @bitSizeOf(c_ulong) - 2) = 0,
    } = .{},
    functions: c_ulong = 0,
    decorations: packed struct(c_ulong) {
        all: bool = false,

        // We don't really care about the other flags
        _rest: std.meta.Int(.unsigned, @bitSizeOf(c_ulong) - 1) = 0,
    } = .{},
    input_mode: c_long = 0,
    status: c_ulong = 0,
};

/// Update the size of the popup terminal based on monitor dimensions.
fn enteredMonitor(
    _: *gdk.Surface,
    monitor: *gdk.Monitor,
    apprt_window: *ApprtWindow,
) callconv(.c) void {
    const window = apprt_window.as(gtk.Window);

    var monitor_size: gdk.Rectangle = undefined;
    monitor.getGeometry(&monitor_size);

    const monitor_dims: Config.QuickTerminalSize.Dimensions = .{
        .width = @intCast(monitor_size.f_width),
        .height = @intCast(monitor_size.f_height),
    };

    const dims = if (apprt_window.isPopup()) popupSizeForMonitor(
        apprt_window,
        monitor_dims,
    ) orelse return else dims: {
        const config = if (apprt_window.getConfig()) |v| v.get() else return;
        break :dims config.@"quick-terminal-size".calculate(
            config.@"quick-terminal-position",
            monitor_dims,
        );
    };

    window.setDefaultSize(@intCast(dims.width), @intCast(dims.height));
}

fn popupPosition(
    apprt_window: *ApprtWindow,
    config: *const Config,
) popupmod.Position {
    return apprt_window.popupPosition() orelse switch (config.@"quick-terminal-position") {
        .left => .left,
        .right => .right,
        .top => .top,
        .bottom => .bottom,
        .center => .center,
    };
}

fn popupDimensionToPixels(dim: popupmod.Dimension, parent: u32) u32 {
    return switch (dim.unit) {
        .percent => parent * dim.value / 100,
        .pixels => dim.value,
    };
}

fn popupSizeForMonitor(
    apprt_window: *ApprtWindow,
    monitor_dims: Config.QuickTerminalSize.Dimensions,
) ?Config.QuickTerminalSize.Dimensions {
    const width = apprt_window.popupWidth() orelse return null;
    const height = apprt_window.popupHeight() orelse return null;
    return .{
        .width = popupDimensionToPixels(width, monitor_dims.width),
        .height = popupDimensionToPixels(height, monitor_dims.height),
    };
}
