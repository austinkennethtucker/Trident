/// The debug overlay that can be drawn on top of the terminal
/// during the rendering process.
///
/// This is implemented by doing all the drawing on the CPU via z2d,
/// since the debug overlay isn't that common, z2d is pretty fast, and
/// it simplifies our implementation quite a bit by not relying on us
/// having a bunch of shaders that we have to write per-platform.
///
/// Initialize the overlay, apply features with `applyFeatures`, then
/// get the resulting image with `pendingImage` to upload to the GPU.
/// This works in concert with `renderer.image.State` to simplify. Draw
/// it on the GPU as an image composited on top of the terminal output.
const Overlay = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const terminal = @import("../terminal/main.zig");
const size = @import("size.zig");
const Size = size.Size;
const CellSize = size.CellSize;
const Image = @import("image.zig").Image;

const log = std.log.scoped(.renderer_overlay);

/// The colors we use for overlays.
pub const Color = enum {
    hyperlink, // light blue
    semantic_prompt, // orange/gold
    semantic_input, // cyan
    vi_cursor, // amber/yellow

    pub fn rgb(self: Color) z2d.pixel.RGB {
        return switch (self) {
            .hyperlink => .{ .r = 180, .g = 180, .b = 255 },
            .semantic_prompt => .{ .r = 255, .g = 200, .b = 64 },
            .semantic_input => .{ .r = 64, .g = 200, .b = 255 },
            .vi_cursor => .{ .r = 255, .g = 160, .b = 0 },
        };
    }

    /// The fill color for rectangles.
    pub fn rectFill(self: Color) z2d.Pixel {
        return self.alphaPixel(96);
    }

    /// The border color for rectangles.
    pub fn rectBorder(self: Color) z2d.Pixel {
        return self.alphaPixel(200);
    }

    /// The raw RGB as a pixel.
    pub fn pixel(self: Color) z2d.Pixel {
        return self.rgb().asPixel();
    }

    fn alphaPixel(self: Color, alpha: u8) z2d.Pixel {
        var rgba: z2d.pixel.RGBA = .fromPixel(self.pixel());
        rgba.a = alpha;
        return rgba.multiply().asPixel();
    }
};

/// The surface we're drawing our overlay to.
surface: z2d.Surface,

/// Cell size information so we can map grid coordinates to pixels.
cell_size: CellSize,

/// The set of available features and their configuration.
pub const Feature = union(enum) {
    highlight_hyperlinks,
    semantic_prompts,
    vi_cursor: struct { row: usize, col: usize },
    vi_mode_indicator: []const u8,
    vi_line_numbers: struct {
        mode: enum { relative, absolute },
        cursor_row: usize,
        viewport_top_abs_row: usize,
        viewport_rows: usize,
        has_mode_indicator: bool,
    },
};

pub const InitError = Allocator.Error || error{
    // The terminal dimensions are invalid to support an overlay.
    // Either too small or too big.
    InvalidDimensions,
};

/// Initialize a new, blank overlay.
pub fn init(alloc: Allocator, sz: Size) InitError!Overlay {
    // Our surface does NOT need to take into account padding because
    // we render the overlay using the image subsystem and shaders which
    // already take that into account.
    const term_size = sz.terminal();
    var sfc = z2d.Surface.initPixel(
        .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        alloc,
        std.math.cast(i32, term_size.width) orelse
            return error.InvalidDimensions,
        std.math.cast(i32, term_size.height) orelse
            return error.InvalidDimensions,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWidth, error.InvalidHeight => return error.InvalidDimensions,
    };
    errdefer sfc.deinit(alloc);

    return .{
        .surface = sfc,
        .cell_size = sz.cell,
    };
}

pub fn deinit(self: *Overlay, alloc: Allocator) void {
    self.surface.deinit(alloc);
}

/// Returns a pending image that can be used to copy, convert, upload, etc.
pub fn pendingImage(self: *const Overlay) Image.Pending {
    return .{
        .width = @intCast(self.surface.getWidth()),
        .height = @intCast(self.surface.getHeight()),
        .pixel_format = .rgba,
        .data = @ptrCast(self.surface.image_surface_rgba.buf.ptr),
    };
}

/// Clear the overlay.
pub fn reset(self: *Overlay) void {
    self.surface.paintPixel(.{ .rgba = .{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 0,
    } });
}

/// Apply the given features to this overlay. This will draw on top of
/// any pre-existing content in the overlay.
pub fn applyFeatures(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
    features: []const Feature,
) void {
    for (features) |f| switch (f) {
        .highlight_hyperlinks => self.highlightHyperlinks(
            alloc,
            state,
        ),
        .semantic_prompts => self.highlightSemanticPrompts(
            alloc,
            state,
        ),
        .vi_cursor => |pos| self.highlightViCursor(alloc, pos.row, pos.col),
        .vi_mode_indicator => |text| self.highlightViModeIndicator(alloc, state, text),
        .vi_line_numbers => |data| self.highlightViLineNumbers(alloc, state, data),
    };
}

/// Add rectangles around contiguous hyperlinks in the render state.
///
/// Note: this currently doesn't take into account unique hyperlink IDs
/// because the render state doesn't contain this. This will be added
/// later.
fn highlightHyperlinks(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
) void {
    const border_color = Color.hyperlink.rectBorder();
    const fill_color = Color.hyperlink.rectFill();

    const row_slice = state.row_data.slice();
    const row_raw = row_slice.items(.raw);
    const row_cells = row_slice.items(.cells);
    for (row_raw, row_cells, 0..) |row, cells, y| {
        if (!row.hyperlink) continue;

        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);

        var x: usize = 0;
        while (x < raw_cells.len) {
            // Skip cells without hyperlinks
            if (!raw_cells[x].hyperlink) {
                x += 1;
                continue;
            }

            // Found start of a hyperlink run
            const start_x = x;

            // Find end of contiguous hyperlink cells
            while (x < raw_cells.len and raw_cells[x].hyperlink) x += 1;
            const end_x = x;

            self.highlightGridRect(
                alloc,
                start_x,
                y,
                end_x - start_x,
                1,
                border_color,
                fill_color,
            ) catch |err| {
                std.log.warn("Error drawing hyperlink border: {}", .{err});
            };
        }
    }
}

fn highlightSemanticPrompts(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
) void {
    const row_slice = state.row_data.slice();
    const row_raw = row_slice.items(.raw);
    const row_cells = row_slice.items(.cells);

    // Highlight the row-level semantic prompt bars. The prompts are easy
    // because they're part of the row metadata.
    {
        const prompt_border = Color.semantic_prompt.rectBorder();
        const prompt_fill = Color.semantic_prompt.rectFill();

        var y: usize = 0;
        while (y < row_raw.len) {
            // If its not a semantic prompt row, skip it.
            if (row_raw[y].semantic_prompt == .none) {
                y += 1;
                continue;
            }

            // Find the full length of the semantic prompt row by connecting
            // all continuations.
            const start_y = y;
            y += 1;
            while (y < row_raw.len and
                row_raw[y].semantic_prompt == .prompt_continuation)
            {
                y += 1;
            }
            const end_y = y; // Exclusive

            const bar_width = @min(@as(usize, 5), self.cell_size.width);
            self.highlightPixelRect(
                alloc,
                0,
                start_y,
                bar_width,
                end_y - start_y,
                prompt_border,
                prompt_fill,
            ) catch |err| {
                log.warn("Error drawing semantic prompt bar: {}", .{err});
            };
        }
    }

    // Highlight contiguous semantic cells within rows.
    for (row_cells, 0..) |cells, y| {
        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);

        var x: usize = 0;
        while (x < raw_cells.len) {
            const cell = raw_cells[x];
            const content = cell.semantic_content;
            const start_x = x;

            // We skip output because its just the rest of the non-prompt
            // parts and it makes the overlay too noisy.
            if (cell.semantic_content == .output) {
                x += 1;
                continue;
            }

            // Find the end of this content.
            x += 1;
            while (x < raw_cells.len) {
                const next = raw_cells[x];
                if (next.semantic_content != content) break;
                x += 1;
            }

            const color: Color = switch (content) {
                .prompt => .semantic_prompt,
                .input => .semantic_input,
                .output => unreachable,
            };

            self.highlightGridRect(
                alloc,
                start_x,
                y,
                x - start_x,
                1,
                color.rectBorder(),
                color.rectFill(),
            ) catch |err| {
                log.warn("Error drawing semantic content highlight: {}", .{err});
            };
        }
    }
}

/// Draw a filled block cursor at the given grid position for vi mode.
fn highlightViCursor(
    self: *Overlay,
    alloc: Allocator,
    row: usize,
    col: usize,
) void {
    const fill_color = Color.vi_cursor.rectFill();
    const border_color = Color.vi_cursor.rectBorder();

    self.highlightGridRect(
        alloc,
        col,
        row,
        1,
        1,
        border_color,
        fill_color,
    ) catch |err| {
        log.warn("Error drawing vi cursor: {}", .{err});
    };
}

/// Draw a mode indicator bar at the bottom-left of the overlay for vi mode.
/// The bar width matches the mode label length, and visual modes use a
/// different color to provide visual distinction without text rendering.
///
/// Uses direct pixel writes (not z2d path compositing) to guarantee a
/// uniform bar without alpha accumulation from any previously-drawn
/// overlay features on the same surface.
fn highlightViModeIndicator(
    self: *Overlay,
    _: Allocator,
    state: *const terminal.RenderState,
    text: []const u8,
) void {
    // Bar width matches the mode label length (e.g., "-- NORMAL --" = 14 cells)
    const bar_width: usize = @min(if (text.len > 0) text.len else 8, state.cols);
    const bar_row: usize = if (state.rows > 0) state.rows - 1 else 0;

    // Use different colors for different modes:
    // NORMAL = amber (vi_cursor color), VISUAL modes = selection-like blue
    const is_visual = text.len > 0 and (std.mem.indexOf(u8, text, "VISUAL") != null or
        std.mem.indexOf(u8, text, "V-BLOCK") != null);

    const fill_color = if (is_visual) vi_visual_fill() else Color.vi_cursor.rectFill();

    // Calculate pixel dimensions
    const px_x: i32 = 0;
    const px_y: i32 = std.math.cast(i32, bar_row *| self.cell_size.height) orelse return;
    const px_width: usize = bar_width *| self.cell_size.width;
    const px_height: usize = self.cell_size.height;

    // Direct pixel write — paintStride replaces pixels (no alpha
    // compositing), ensuring the bar is uniform regardless of any
    // other overlay features drawn on the same row.
    for (0..px_height) |dy| {
        const y: i32 = px_y +| @as(i32, std.math.cast(i32, dy) orelse continue);
        self.surface.paintStride(px_x, y, px_width, fill_color);
    }
}

/// Draw the line number gutter for vi mode.
fn highlightViLineNumbers(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
    data: anytype,
) void {
    const viewport_rows = data.viewport_rows;
    const cursor_row = data.cursor_row;
    const top_abs = data.viewport_top_abs_row;

    if (state.cols < 4) return;

    const max_number: usize = switch (data.mode) {
        .relative => if (viewport_rows > 1) viewport_rows - 1 else 1,
        .absolute => top_abs + viewport_rows,
    };
    const gw = gutterWidth(max_number);

    if (gw * 3 > state.cols) return;

    // Skip gutter background on bottom row if mode indicator active
    const indicator_row: ?usize = if (data.has_mode_indicator and state.rows > 0) state.rows - 1 else null;

    // Draw gutter background (30% black) using paintStride (direct pixel replacement)
    const bg_color = gutterBackground();
    const gutter_px_width: usize = gw * self.cell_size.width;
    for (0..viewport_rows) |row| {
        if (indicator_row) |ir| {
            if (row == ir) continue;
        }
        const py: i32 = std.math.cast(i32, row * self.cell_size.height) orelse continue;
        for (0..self.cell_size.height) |dy| {
            const y: i32 = py +| @as(i32, std.math.cast(i32, dy) orelse continue);
            self.surface.paintStride(0, y, gutter_px_width, bg_color);
        }
    }

    // Draw separator line (1px wide at right edge of gutter)
    const sep_color = gutterSeparator();
    const sep_x: i32 = std.math.cast(i32, gutter_px_width -| 1) orelse return;
    for (0..viewport_rows) |row| {
        // Skip indicator row to preserve mode indicator visual
        if (indicator_row) |ir| {
            if (row == ir) continue;
        }
        const py: i32 = std.math.cast(i32, row * self.cell_size.height) orelse continue;
        for (0..self.cell_size.height) |dy| {
            const y: i32 = py +| @as(i32, std.math.cast(i32, dy) orelse continue);
            self.surface.paintStride(sep_x, y, 1, sep_color);
        }
    }

    // Draw line numbers
    var ctx: z2d.Context = .init(alloc, &self.surface);
    defer ctx.deinit();
    ctx.setAntiAliasingMode(.none);
    ctx.setHairline(false);

    for (0..viewport_rows) |row| {
        const number: usize = if (row == cursor_row)
            top_abs + row + 1
        else switch (data.mode) {
            .relative => if (row > cursor_row) row - cursor_row else cursor_row - row,
            .absolute => top_abs + row + 1,
        };

        const color = if (row == cursor_row) gutterBrightDigit() else gutterDimDigit();

        self.drawDigitString(&ctx, number, row, gw, color) catch |err| {
            log.warn("Error drawing line number: {}", .{err});
            return;
        };
    }
}

// -- Digit drawing (7-segment style) --

const DigitSegments = struct {
    top: bool = false,
    top_left: bool = false,
    top_right: bool = false,
    middle: bool = false,
    bottom_left: bool = false,
    bottom_right: bool = false,
    bottom: bool = false,
};

fn digitSegments(d: u8) DigitSegments {
    return switch (d) {
        0 => .{ .top = true, .top_left = true, .top_right = true, .bottom_left = true, .bottom_right = true, .bottom = true },
        1 => .{ .top_right = true, .bottom_right = true },
        2 => .{ .top = true, .top_right = true, .middle = true, .bottom_left = true, .bottom = true },
        3 => .{ .top = true, .top_right = true, .middle = true, .bottom_right = true, .bottom = true },
        4 => .{ .top_left = true, .top_right = true, .middle = true, .bottom_right = true },
        5 => .{ .top = true, .top_left = true, .middle = true, .bottom_right = true, .bottom = true },
        6 => .{ .top = true, .top_left = true, .middle = true, .bottom_left = true, .bottom_right = true, .bottom = true },
        7 => .{ .top = true, .top_right = true, .bottom_right = true },
        8 => .{ .top = true, .top_left = true, .top_right = true, .middle = true, .bottom_left = true, .bottom_right = true, .bottom = true },
        9 => .{ .top = true, .top_left = true, .top_right = true, .middle = true, .bottom_right = true, .bottom = true },
        else => .{},
    };
}

/// Draw a single digit (0-9) within the given pixel bounding box.
/// Uses z2d line paths in a 7-segment style (no font dependency).
fn drawDigit(
    ctx: *z2d.Context,
    bx: f64,
    by: f64,
    bw: f64,
    bh: f64,
    digit: u8,
) !void {
    const mx = bw * 0.15;
    const my = bh * 0.10;
    const x0 = bx + mx;
    const x1 = bx + bw - mx;
    const y0 = by + my;
    const y1 = by + bh - my;
    const ym = by + bh / 2.0;

    const segs = digitSegments(digit);

    if (segs.top) { try ctx.moveTo(x0, y0); try ctx.lineTo(x1, y0); }
    if (segs.top_left) { try ctx.moveTo(x0, y0); try ctx.lineTo(x0, ym); }
    if (segs.top_right) { try ctx.moveTo(x1, y0); try ctx.lineTo(x1, ym); }
    if (segs.middle) { try ctx.moveTo(x0, ym); try ctx.lineTo(x1, ym); }
    if (segs.bottom_left) { try ctx.moveTo(x0, ym); try ctx.lineTo(x0, y1); }
    if (segs.bottom_right) { try ctx.moveTo(x1, ym); try ctx.lineTo(x1, y1); }
    if (segs.bottom) { try ctx.moveTo(x0, y1); try ctx.lineTo(x1, y1); }
}

/// Draw a number as right-aligned digit string in the gutter area.
/// This is the swappable interface for digit rendering.
fn drawDigitString(
    self: *Overlay,
    ctx: *z2d.Context,
    number: usize,
    row: usize,
    gutter_width_cells: usize,
    color: z2d.Pixel,
) !void {
    var digits: [6]u8 = undefined;
    var n = number;
    var digit_count: usize = 0;
    if (n == 0) {
        digits[0] = 0;
        digit_count = 1;
    } else {
        while (n > 0 and digit_count < digits.len) : (digit_count += 1) {
            digits[digit_count] = @intCast(n % 10);
            n /= 10;
        }
    }

    const num_cols = gutter_width_cells -| 1; // columns for digits (last col is separator)
    if (digit_count > num_cols) return;

    const cell_w: f64 = @floatFromInt(self.cell_size.width);
    const cell_h: f64 = @floatFromInt(self.cell_size.height);
    const row_y: f64 = @floatFromInt(row * self.cell_size.height);

    ctx.setSourceToPixel(color);
    ctx.setLineWidth(1.5);

    var i: usize = 0;
    while (i < digit_count) : (i += 1) {
        const col = num_cols - 1 - i;
        const col_x: f64 = @floatFromInt(col * self.cell_size.width);
        try drawDigit(ctx, col_x, row_y, cell_w, cell_h, digits[i]);
    }

    try ctx.stroke();
}

// -- Gutter color helpers --

/// Gutter background: 30% black overlay (darkened/recessed).
fn gutterBackground() z2d.Pixel {
    var rgba: z2d.pixel.RGBA = .fromPixel((z2d.pixel.RGB{ .r = 0, .g = 0, .b = 0 }).asPixel());
    rgba.a = 77; // 30% of 255
    return rgba.multiply().asPixel();
}

/// Gutter separator: 20% white vertical line.
fn gutterSeparator() z2d.Pixel {
    var rgba: z2d.pixel.RGBA = .fromPixel((z2d.pixel.RGB{ .r = 255, .g = 255, .b = 255 }).asPixel());
    rgba.a = 51; // 20% of 255
    return rgba.multiply().asPixel();
}

/// Relative line number color: 40% white.
fn gutterDimDigit() z2d.Pixel {
    var rgba: z2d.pixel.RGBA = .fromPixel((z2d.pixel.RGB{ .r = 255, .g = 255, .b = 255 }).asPixel());
    rgba.a = 102; // 40% of 255
    return rgba.multiply().asPixel();
}

/// Current line number color: bright white.
fn gutterBrightDigit() z2d.Pixel {
    var rgba: z2d.pixel.RGBA = .fromPixel((z2d.pixel.RGB{ .r = 255, .g = 255, .b = 255 }).asPixel());
    rgba.a = 230; // ~90% of 255
    return rgba.multiply().asPixel();
}

/// Compute the gutter width (in cells) for the given maximum number.
/// Returns digit columns + 1 separator column.
fn gutterWidth(max_number: usize) usize {
    if (max_number == 0) return 2;
    var digits: usize = 0;
    var n = max_number;
    while (n > 0) : (digits += 1) n /= 10;
    return digits + 1;
}

/// Blue fill for visual mode indicator (distinct from normal mode amber).
fn vi_visual_fill() z2d.Pixel {
    var rgba: z2d.pixel.RGBA = .fromPixel((z2d.pixel.RGB{ .r = 100, .g = 160, .b = 255 }).asPixel());
    rgba.a = 96;
    return rgba.multiply().asPixel();
}

/// Blue border for visual mode indicator.
fn vi_visual_border() z2d.Pixel {
    var rgba: z2d.pixel.RGBA = .fromPixel((z2d.pixel.RGB{ .r = 100, .g = 160, .b = 255 }).asPixel());
    rgba.a = 200;
    return rgba.multiply().asPixel();
}

/// Creates a rectangle for highlighting a grid region. x/y/width/height
/// are all in grid cells.
fn highlightGridRect(
    self: *Overlay,
    alloc: Allocator,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    border_color: z2d.Pixel,
    fill_color: z2d.Pixel,
) !void {
    // All math below uses checked arithmetic to avoid overflows. The
    // inputs aren't trusted and the path this is in isn't hot enough
    // to wrarrant unsafe optimizations.

    // Calculate our width/height in pixels.
    const px_width = std.math.cast(i32, try std.math.mul(
        usize,
        width,
        self.cell_size.width,
    )) orelse return error.Overflow;
    const px_height = std.math.cast(i32, try std.math.mul(
        usize,
        height,
        self.cell_size.height,
    )) orelse return error.Overflow;

    // Calculate pixel coordinates
    const start_x: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        x,
        self.cell_size.width,
    )) orelse return error.Overflow);
    const start_y: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        y,
        self.cell_size.height,
    )) orelse return error.Overflow);
    const end_x: f64 = start_x + @as(f64, @floatFromInt(px_width));
    const end_y: f64 = start_y + @as(f64, @floatFromInt(px_height));

    // Grab our context to draw
    var ctx: z2d.Context = .init(alloc, &self.surface);
    defer ctx.deinit();

    // Don't need AA because we use sharp edges
    ctx.setAntiAliasingMode(.none);
    // Can use hairline since we have 1px borders
    ctx.setHairline(true);

    // Draw rectangle path
    try ctx.moveTo(start_x, start_y);
    try ctx.lineTo(end_x, start_y);
    try ctx.lineTo(end_x, end_y);
    try ctx.lineTo(start_x, end_y);
    try ctx.closePath();

    // Fill
    ctx.setSourceToPixel(fill_color);
    try ctx.fill();

    // Border (skip when same as fill to avoid alpha doubling at edges)
    if (!std.meta.eql(border_color, fill_color)) {
        ctx.setLineWidth(1);
        ctx.setSourceToPixel(border_color);
        try ctx.stroke();
    }
}

/// Creates a rectangle for highlighting a region. x/y are grid cells and
/// width/height are pixels.
fn highlightPixelRect(
    self: *Overlay,
    alloc: Allocator,
    x: usize,
    y: usize,
    width_px: usize,
    height: usize,
    border_color: z2d.Pixel,
    fill_color: z2d.Pixel,
) !void {
    const px_width = std.math.cast(i32, width_px) orelse return error.Overflow;
    const px_height = std.math.cast(i32, try std.math.mul(
        usize,
        height,
        self.cell_size.height,
    )) orelse return error.Overflow;

    const start_x: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        x,
        self.cell_size.width,
    )) orelse return error.Overflow);
    const start_y: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        y,
        self.cell_size.height,
    )) orelse return error.Overflow);
    const end_x: f64 = start_x + @as(f64, @floatFromInt(px_width));
    const end_y: f64 = start_y + @as(f64, @floatFromInt(px_height));

    var ctx: z2d.Context = .init(alloc, &self.surface);
    defer ctx.deinit();

    ctx.setAntiAliasingMode(.none);
    ctx.setHairline(true);

    try ctx.moveTo(start_x, start_y);
    try ctx.lineTo(end_x, start_y);
    try ctx.lineTo(end_x, end_y);
    try ctx.lineTo(start_x, end_y);
    try ctx.closePath();

    ctx.setSourceToPixel(fill_color);
    try ctx.fill();

    ctx.setLineWidth(1);
    ctx.setSourceToPixel(border_color);
    try ctx.stroke();
}
