const std = @import("std");
const Allocator = std.mem.Allocator;

const gdk = @import("gdk");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const popupmod = @import("../../apprt/popup.zig");
const configpkg = @import("../../config.zig");

const Window = @import("class/window.zig").Window;
const WeakRef = @import("weak_ref.zig").WeakRef;

const log = std.log.scoped(.popup_manager);

/// Manages popup terminal instances for the GTK apprt.
///
/// Each popup is identified by a profile name (e.g. "quick", "calc").
/// The manager tracks which windows exist for each profile and handles
/// the toggle/show/hide lifecycle.
pub const PopupManager = struct {
    const WindowEntry = struct {
        name: [:0]const u8,
        weak_ref: WeakRef(Window) = .empty,
        stale: bool = false,

        fn deinit(self: *const WindowEntry, alloc: Allocator) void {
            alloc.free(self.name);
        }
    };

    alloc: Allocator,
    profiles: std.ArrayListUnmanaged(popupmod.NamedProfile) = .empty,
    windows: std.ArrayListUnmanaged(WindowEntry) = .empty,

    pub fn init(alloc: Allocator) PopupManager {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *PopupManager) void {
        for (self.profiles.items) |entry| entry.deinit(self.alloc);
        self.profiles.deinit(self.alloc);

        for (self.windows.items) |entry| entry.deinit(self.alloc);
        self.windows.deinit(self.alloc);
    }

    /// Load popup profiles from the config. This replaces any previously
    /// stored profiles. It does NOT destroy existing windows -- those will
    /// be lazily cleaned up on next toggle/show/hide.
    pub fn loadConfig(self: *PopupManager, config: *const configpkg.Config) void {
        for (self.profiles.items) |entry| entry.deinit(self.alloc);
        self.profiles.clearRetainingCapacity();

        for (config.popup.entries.items) |entry| {
            const cloned = popupmod.NamedProfile.init(
                self.alloc,
                entry.named_profile.name,
                entry.named_profile.profile,
            ) catch |err| {
                log.warn("failed to duplicate popup profile '{s}': {}", .{
                    entry.named_profile.name,
                    err,
                });
                continue;
            };

            self.profiles.append(self.alloc, cloned) catch |err| {
                log.warn("failed to store popup profile '{s}': {}", .{
                    entry.named_profile.name,
                    err,
                });
                cloned.deinit(self.alloc);
                continue;
            };
        }

        log.debug("loaded {} popup profiles", .{self.profiles.items.len});
    }

    /// Toggle a popup by name: create+show if not exists, show if hidden,
    /// hide if visible.
    pub fn toggle(self: *PopupManager, name: []const u8, inherited_cwd: ?[:0]const u8) bool {
        if (self.findValidWindow(name)) |win| {
            defer win.unref();
            const widget = win.as(gtk.Widget);
            if (widget.isVisible() != 0) {
                return self.hide(name);
            } else {
                // If stale (config changed), destroy and recreate
                if (self.isWindowStale(name)) {
                    self.destroyWindow(name);
                    return self.createAndShow(name, inherited_cwd);
                }
                widget.setVisible(1);
                gtk.Window.present(win.as(gtk.Window));
                return true;
            }
        }

        return self.createAndShow(name, inherited_cwd);
    }

    /// Show a popup by name: create+show if not exists, show if hidden,
    /// no-op if already visible.
    pub fn show(self: *PopupManager, name: []const u8, inherited_cwd: ?[:0]const u8) bool {
        if (self.findValidWindow(name)) |win| {
            defer win.unref();
            const widget = win.as(gtk.Widget);
            if (widget.isVisible() != 0) return true;
            // If stale (config changed), destroy and recreate
            if (self.isWindowStale(name)) {
                self.destroyWindow(name);
                return self.createAndShow(name, inherited_cwd);
            }
            widget.setVisible(1);
            gtk.Window.present(win.as(gtk.Window));
            return true;
        }

        return self.createAndShow(name, inherited_cwd);
    }

    /// Hide a popup by name. If persist=false in the profile, destroy
    /// the window instead of just hiding it.
    pub fn hide(self: *PopupManager, name: []const u8) bool {
        const idx = self.findWindowIndex(name) orelse return false;
        const win = self.windows.items[idx].weak_ref.get() orelse {
            // Window was destroyed externally, clean up the stale entry.
            self.removeWindowAt(idx);
            return false;
        };
        defer win.unref();

        // Check if the profile says to destroy on hide
        const profile = self.getProfile(name);
        if (profile) |p| {
            if (!p.persist) {
                win.as(gtk.Window).destroy();
                self.removeWindowAt(idx);
                return true;
            }
        }

        win.as(gtk.Widget).setVisible(0);
        return true;
    }

    /// Update popup profiles from a new config. Handles:
    /// - Removed profiles: destroy any running popup window immediately
    /// - New profiles: stored for lazy creation on next toggle/show
    /// - Changed profiles: stored config updated; visible popups keep
    ///   running. Windows are marked stale so the next toggle cycle
    ///   (hide→show) destroys and recreates them with new config.
    pub fn updateProfileConfigs(self: *PopupManager, config: *const configpkg.Config) void {
        // 1. Destroy windows for truly removed profiles only
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const wname = self.windows.items[i].name;
            const still_exists = config.popup.get(wname) != null;

            if (!still_exists) {
                if (self.windows.items[i].weak_ref.get()) |win| {
                    defer win.unref();
                    win.as(gtk.Window).destroy();
                }
                self.removeWindowAt(i);
            } else {
                i += 1;
            }
        }

        // IMPORTANT: markStaleIfChanged must run BEFORE loadConfig because it
        // reads old profile string fields (cwd, command, keybind) that loadConfig
        // will free and replace. Reordering these steps causes use-after-free.
        // 2. Mark existing windows as stale — they'll be destroyed and
        //    recreated on next toggle if hidden, or kept alive if visible
        //    until the user toggles them.
        for (self.windows.items) |window_entry| {
            self.markStaleIfChanged(window_entry.name, config);
        }

        // 3. Reload stored profiles from new config
        self.loadConfig(config);
    }

    /// Hide (or destroy) all popup windows. Called during quit.
    pub fn hideAll(self: *PopupManager) void {
        for (self.windows.items) |window_entry| {
            if (window_entry.weak_ref.get()) |win| {
                defer win.unref();
                win.as(gtk.Window).destroy();
            }
        }
        for (self.windows.items) |window_entry| window_entry.deinit(self.alloc);
        self.windows.clearRetainingCapacity();
    }

    /// Create a new popup window and show it.
    fn createAndShow(self: *PopupManager, name: []const u8, inherited_cwd: ?[:0]const u8) bool {
        // Get the GIO application (which is our GhosttyApplication)
        const gio_app = gio.Application.getDefault() orelse {
            log.warn("no default application available for popup creation", .{});
            return false;
        };
        const gtk_app = gobject.ext.cast(gtk.Application, gio_app) orelse {
            log.warn("default application is not a GTK application", .{});
            return false;
        };

        // Verify the profile exists
        const profile = self.getProfile(name) orelse {
            log.warn("no popup profile found for name '{s}'", .{name});
            return false;
        };

        // Allocate an owned sentinel-terminated copy of the name
        const name_z = self.alloc.dupeZ(u8, name) catch |err| {
            log.warn("failed to allocate popup profile name: {}", .{err});
            return false;
        };

        // Create a new window with is-popup=true
        const win = gobject.ext.newInstance(Window, .{
            .application = gtk_app,
            .@"is-popup" = true,
        });

        // Store popup metadata on the window so surfaces and winproto
        // modules can read it without reaching back into PopupManager.
        win.setPopupProfileName(name_z);
        win.setPopupGeometry(profile);

        // Track the window with a weak reference
        var weak_ref: WeakRef(Window) = .empty;
        weak_ref.set(win);

        self.windows.append(self.alloc, .{
            .name = name_z,
            .weak_ref = weak_ref,
        }) catch |err| {
            log.warn("failed to track popup window: {}", .{err});
            self.alloc.free(name_z);
            win.as(gtk.Window).destroy();
            return false;
        };

        // Bind config so window config stays in sync with app config
        _ = gobject.Object.bindProperty(
            gio_app.as(gobject.Object),
            "config",
            win.as(gobject.Object),
            "config",
            .{},
        );

        const working_directory = popupmod.resolveWorkingDirectory(
            self.alloc,
            profile.cwd,
            inherited_cwd,
            std.posix.getenv("HOME"),
        ) catch .{};
        defer working_directory.deinit(self.alloc);

        // Create initial tab
        win.newTabForWindow(null, .{
            .working_directory = working_directory.path,
            .background_opacity = profile.opacity,
            .window_padding_color = .extend,
        });

        // Apply popup size from profile before presenting.
        applyPopupSize(win.as(gtk.Window), profile);

        // Show the window
        gtk.Window.present(win.as(gtk.Window));

        return true;
    }

    /// Apply popup profile width/height to a GTK window before presenting.
    /// Resolves percentage dimensions against the primary monitor's geometry.
    fn applyPopupSize(gtk_win: *gtk.Window, profile: popupmod.PopupProfile) void {
        const display = gdk.Display.getDefault() orelse return;
        const monitors = display.getMonitors();
        const first = monitors.getObject(0) orelse return;
        const monitor: *gdk.Monitor = @ptrCast(@alignCast(first));

        var geom: gdk.Rectangle = undefined;
        monitor.getGeometry(&geom);

        const mon_w: u32 = @intCast(geom.f_width);
        const mon_h: u32 = @intCast(geom.f_height);

        const width: c_int = @intCast(switch (profile.width.unit) {
            .percent => mon_w * profile.width.value / 100,
            .pixels => profile.width.value,
        });
        const height: c_int = @intCast(switch (profile.height.unit) {
            .percent => mon_h * profile.height.value / 100,
            .pixels => profile.height.value,
        });

        gtk_win.setDefaultSize(width, height);
    }

    // -- Internal helpers --

    /// Find a valid window by name. Returns a strong reference that the
    /// caller must release with unref() when done. Returns null if the
    /// window doesn't exist or was destroyed externally.
    fn findValidWindow(self: *PopupManager, name: []const u8) ?*Window {
        const idx = self.findWindowIndex(name) orelse return null;
        const win = self.windows.items[idx].weak_ref.get() orelse {
            // Window was destroyed externally, clean up the stale entry.
            self.removeWindowAt(idx);
            return null;
        };
        return win;
    }

    fn findWindowIndex(self: *const PopupManager, name: []const u8) ?usize {
        for (self.windows.items, 0..) |window_entry, i| {
            if (std.mem.eql(u8, window_entry.name, name)) return i;
        }
        return null;
    }

    fn removeWindowAt(self: *PopupManager, idx: usize) void {
        const window_entry = self.windows.orderedRemove(idx);
        window_entry.deinit(self.alloc);
    }

    /// Check if a tracked window is marked stale (config changed since creation).
    fn isWindowStale(self: *const PopupManager, name: []const u8) bool {
        const idx = self.findWindowIndex(name) orelse return false;
        return self.windows.items[idx].stale;
    }

    /// Mark a window stale if its profile differs from the new config.
    /// Compares the stored (old) profile against the new config's profile
    /// for the same name. Uses field-by-field comparison for non-string
    /// fields and content comparison for string fields.
    fn markStaleIfChanged(self: *PopupManager, name: []const u8, config: *const configpkg.Config) void {
        const win_idx = self.findWindowIndex(name) orelse return;
        const old_profile = self.getProfile(name) orelse return;

        if (config.popup.get(name)) |new_profile| {
            if (popupmod.profileChanged(old_profile, new_profile)) {
                self.windows.items[win_idx].stale = true;
            }
        }
    }

    /// Destroy a tracked popup window by name.
    fn destroyWindow(self: *PopupManager, name: []const u8) void {
        const idx = self.findWindowIndex(name) orelse return;
        if (self.windows.items[idx].weak_ref.get()) |win| {
            defer win.unref();
            win.as(gtk.Window).destroy();
        }
        self.removeWindowAt(idx);
    }

    fn getProfile(self: *const PopupManager, name: []const u8) ?popupmod.PopupProfile {
        for (self.profiles.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.profile;
        }
        return null;
    }
};
