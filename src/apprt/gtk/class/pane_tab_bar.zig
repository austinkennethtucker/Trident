const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;

pub const PaneTabBar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyPaneTabBar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        pub const @"tab-selected" = struct {
            pub const name = "tab-selected";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{c_uint}, void);
        };

        pub const @"tab-closed" = struct {
            pub const name = "tab-closed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{c_uint}, void);
        };

        pub const @"new-tab-requested" = struct {
            pub const name = "new-tab-requested";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };
    };

    const TabButton = struct {
        container: *gtk.Box,
        button: *gtk.Button,
        close_button: *gtk.Button,
        label: *gtk.Label,
        surface: *Surface,
    };

    const Private = struct {
        tabs: std.ArrayListUnmanaged(TabButton) = .empty,
        active_index: usize = 0,
        new_button: ?*gtk.Button = null,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const widget = self.as(gtk.Widget);
        self.as(gtk.Orientable).setOrientation(.horizontal);
        widget.addCssClass("toolbar");
        widget.addCssClass("linked");
        widget.setHalign(.fill);
        widget.setValign(.start);
        widget.setSizeRequest(-1, 26);
    }

    pub fn setTabs(self: *Self, tabs: []const *Surface, active_index: usize) void {
        self.clearTabs();

        const priv = self.private();
        priv.active_index = active_index;

        for (tabs, 0..) |surface, index| {
            const container = gtk.Box.new(.horizontal, 4);
            const button = gtk.Button.new();
            const close_button = gtk.Button.new();
            const label = gtk.Label.new(tabTitle(surface));
            const inner = gtk.Box.new(.horizontal, 4);

            button.setChild(inner.as(gtk.Widget));
            button.setHasFrame(0);
            button.as(gtk.Widget).setHexpand(1);
            button.as(gtk.Widget).addCssClass("flat");
            if (index == active_index) button.as(gtk.Widget).addCssClass("suggested-action");

            label.setEllipsize(.end);
            label.setMaxWidthChars(20);
            inner.append(label.as(gtk.Widget));

            close_button.setLabel("x");
            close_button.setHasFrame(0);
            close_button.as(gtk.Widget).addCssClass("flat");

            container.append(button.as(gtk.Widget));
            container.append(close_button.as(gtk.Widget));
            self.as(gtk.Box).append(container.as(gtk.Widget));

            _ = gtk.Button.signals.clicked.connect(
                button,
                *Self,
                buttonClicked,
                self,
                .{},
            );
            _ = gtk.Button.signals.clicked.connect(
                close_button,
                *Self,
                closeButtonClicked,
                self,
                .{},
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                surfaceTitleChanged,
                self,
                .{ .detail = "title" },
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                surfaceTitleChanged,
                self,
                .{ .detail = "title-override" },
            );

            priv.tabs.append(std.heap.c_allocator, .{
                .container = container,
                .button = button,
                .close_button = close_button,
                .label = label,
                .surface = surface,
            }) catch @panic("OOM");
        }

        const new_button = gtk.Button.new();
        new_button.setLabel("+");
        new_button.setHasFrame(0);
        new_button.as(gtk.Widget).addCssClass("flat");
        self.as(gtk.Box).append(new_button.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(
            new_button,
            *Self,
            newButtonClicked,
            self,
            .{},
        );
        priv.new_button = new_button;
    }

    pub fn getActiveSurface(self: *Self) ?*Surface {
        const priv = self.private();
        if (priv.tabs.items.len == 0 or priv.active_index >= priv.tabs.items.len) return null;
        return priv.tabs.items[priv.active_index].surface;
    }

    fn clearTabs(self: *Self) void {
        const priv = self.private();

        for (priv.tabs.items) |tab| {
            _ = gobject.signalHandlersDisconnectMatched(
                tab.surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
            self.as(gtk.Box).remove(tab.container.as(gtk.Widget));
        }
        priv.tabs.clearRetainingCapacity();

        if (priv.new_button) |button| {
            self.as(gtk.Box).remove(button.as(gtk.Widget));
            priv.new_button = null;
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.clearTabs();
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().tabs.deinit(std.heap.c_allocator);
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn tabTitle(surface: *Surface) [*:0]const u8 {
        const title = surface.getEffectiveTitle() orelse return "Terminal";
        return if (title.len == 0) "Terminal" else title.ptr;
    }

    fn buttonClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        for (priv.tabs.items, 0..) |tab, index| {
            if (tab.button == button) {
                signals.@"tab-selected".impl.emit(self, null, .{@as(u32, @intCast(index))}, null);
                return;
            }
        }
    }

    fn closeButtonClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        for (priv.tabs.items, 0..) |tab, index| {
            if (tab.close_button == button) {
                signals.@"tab-closed".impl.emit(self, null, .{@as(u32, @intCast(index))}, null);
                return;
            }
        }
    }

    fn newButtonClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        signals.@"new-tab-requested".impl.emit(self, null, .{}, null);
    }

    fn surfaceTitleChanged(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        for (priv.tabs.items) |tab| {
            if (tab.surface == surface) {
                tab.label.setLabel(tabTitle(surface));
                return;
            }
        }
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            signals.@"tab-selected".impl.register(.{});
            signals.@"tab-closed".impl.register(.{});
            signals.@"new-tab-requested".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
