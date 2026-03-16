# v5 Relative Line Numbers — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a line number gutter to vi-mode that shows relative (or absolute) line numbers, drawn on the existing z2d overlay surface.

**Architecture:** New config enum → Surface plumbing → render state → Overlay.Feature variant → z2d digit drawing. All rendering is CPU-side on the overlay surface; no platform-specific or shader changes.

**Tech Stack:** Zig 0.15.2+, z2d (2D vector graphics), existing overlay compositing pipeline.

**Spec:** `docs/superpowers/specs/2026-03-15-v5-relative-line-numbers-design.md`

---

## Chunk 1: Config, State, and Plumbing

### Task 1: Add config enum type and field

**Files:**
- Modify: `src/config/Config.zig`

- [ ] **Step 1: Add the `ViModeLineNumbers` enum**

Near the other enum types (around `WindowPaddingColor` at line ~5541), add:

```zig
pub const ViModeLineNumbers = enum {
    off,
    relative,
    absolute,
};
```

- [ ] **Step 2: Add the config field**

In the main config struct, near other vi/window options, add:

```zig
/// Show line numbers in the gutter during vi mode.
///
/// When set to `relative`, the current cursor line shows its absolute
/// scrollback row number and all other lines show their distance from the
/// cursor — like Neovim's `set relativenumber`. When set to `absolute`,
/// all lines show their absolute scrollback row number.
///
/// Line numbers overlay the leftmost terminal columns. They appear
/// automatically when entering vi mode and can be toggled at runtime
/// via the `toggle_vi_line_numbers` keybind action.
@"vi-mode-line-numbers": ViModeLineNumbers = .off,
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build (no errors)

- [ ] **Step 4: Commit**

```bash
git add src/config/Config.zig
git commit -m "feat(config): add vi-mode-line-numbers option (off/relative/absolute)"
```

---

### Task 2: Add config to Surface's DerivedConfig

**Files:**
- Modify: `src/Surface.zig`

- [ ] **Step 1: Add field to Surface.DerivedConfig struct**

In the `DerivedConfig` struct (line ~300), add after `scroll_to_bottom`:

```zig
vi_mode_line_numbers: configpkg.ViModeLineNumbers,
```

- [ ] **Step 2: Initialize the field in DerivedConfig.init()**

In the `return .{` block (line ~381), add:

```zig
.vi_mode_line_numbers = config.@"vi-mode-line-numbers",
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build

- [ ] **Step 4: Commit**

```bash
git add src/Surface.zig
git commit -m "feat(surface): plumb vi-mode-line-numbers config to Surface.DerivedConfig"
```

---

### Task 3: Extend ViMode render state

**Files:**
- Modify: `src/renderer/State.zig`

- [ ] **Step 1: Add `LineNumbers` enum to ViMode**

Inside the `ViMode` struct (line ~37), add:

```zig
pub const LineNumbers = enum {
    off,
    relative,
    absolute,
};
```

- [ ] **Step 2: Add new fields to ViMode**

After the existing `mode_text` field (line ~48):

```zig
/// Which line number mode is active (off if disabled or toggled off).
line_numbers: LineNumbers = .off,

/// Absolute scrollback row of the viewport's top-left corner.
/// Used to derive any visible line's absolute row: viewport_top_abs_row + row_index.
/// Null if vi mode is inactive.
viewport_top_abs_row: ?usize = null,
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build

- [ ] **Step 4: Commit**

```bash
git add src/renderer/State.zig
git commit -m "feat(renderer): add line_numbers and viewport_top_abs_row to ViMode render state"
```

---

### Task 4: Surface state plumbing

**Files:**
- Modify: `src/Surface.zig`

- [ ] **Step 1: Add toggle field to Surface**

After `vi_mode: ?ViMode = null` (line ~128), add:

```zig
/// Whether vi-mode line numbers are currently visible (runtime toggle).
/// Defaults to true on vi-mode entry (auto-activate).
vi_line_numbers_visible: bool = true,
```

- [ ] **Step 2: Reset toggle in enter_vi_mode handler**

In the `.enter_vi_mode` action handler (line ~6088), after `self.vi_mode = ViMode.init(cursor_pin);` (line ~6116), add:

```zig
self.vi_line_numbers_visible = true;
```

- [ ] **Step 3: Update `updateViModeRenderState()` to set line number fields**

In `updateViModeRenderState()` (line ~2581), after setting `mode_text`, extend the render state assignment. Replace the existing assignment block:

```zig
self.renderer_state.vi_mode = .{
    .active = true,
    .cursor_row = if (vp_point) |pt| @intCast(pt.viewport.y) else null,
    .cursor_col = if (vp_point) |pt| @intCast(pt.viewport.x) else null,
    .mode_text = switch (vi.sub_mode) {
        .normal => "-- NORMAL --",
        .visual => "-- VISUAL --",
        .visual_line => "-- VISUAL LINE --",
        .visual_block => "-- V-BLOCK --",
    },
};
```

With:

```zig
// Compute viewport top absolute row for line numbers
const viewport_top = screen.pages.getTopLeft(.viewport);
const viewport_top_abs_row: ?usize = if (screen.pages.pointFromPin(.screen, viewport_top)) |sp|
    @intCast(sp.screen.y)
else
    null;

// Determine line number mode: config + runtime toggle
const line_numbers: rendererpkg.State.ViMode.LineNumbers = if (self.vi_line_numbers_visible)
    switch (self.config.vi_mode_line_numbers) {
        .off => .off,
        .relative => .relative,
        .absolute => .absolute,
    }
else
    .off;

self.renderer_state.vi_mode = .{
    .active = true,
    .cursor_row = if (vp_point) |pt| @intCast(pt.viewport.y) else null,
    .cursor_col = if (vp_point) |pt| @intCast(pt.viewport.x) else null,
    .mode_text = switch (vi.sub_mode) {
        .normal => "-- NORMAL --",
        .visual => "-- VISUAL --",
        .visual_line => "-- VISUAL LINE --",
        .visual_block => "-- V-BLOCK --",
    },
    .line_numbers = line_numbers,
    .viewport_top_abs_row = viewport_top_abs_row,
};
```

**Note:** The `@import("renderer/State.zig")` path may need adjustment — check how other files in Surface.zig import renderer types. Look for existing `rendererpkg` or `@import("renderer.zig")` usage and follow that pattern. The ViMode type is at `rendererpkg.State.ViMode.LineNumbers`.

- [ ] **Step 4: Verify it compiles**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build

- [ ] **Step 5: Commit**

```bash
git add src/Surface.zig
git commit -m "feat(surface): plumb vi-mode line number state to renderer"
```

---

### Task 5: Add keybind action

**Files:**
- Modify: `src/input/Binding.zig`
- Modify: `src/Surface.zig`

- [ ] **Step 1: Add action to Binding.zig**

After `enter_vi_mode` (line ~755), add:

```zig
/// Toggle vi mode line numbers on or off.
///
/// If `vi-mode-line-numbers` is configured to `relative` or `absolute`,
/// this toggles the line number gutter visibility while in vi mode.
/// Has no effect if `vi-mode-line-numbers` is `off` or vi mode is not active.
toggle_vi_line_numbers,
```

- [ ] **Step 2: Add to the surface scope in `scope()`**

Find the block where `enter_vi_mode` is listed in the `.surface` scope (line ~1384) and add `toggle_vi_line_numbers` to the same list:

```zig
.enter_vi_mode,
.toggle_vi_line_numbers,
```

- [ ] **Step 3: Add action handler in Surface.zig**

In `performBindingAction`, after the `.enter_vi_mode` handler block (line ~6119), add:

```zig
.toggle_vi_line_numbers => {
    // Only toggle if vi mode is active and config enables line numbers
    if (self.vi_mode == null) return true;
    if (self.config.vi_mode_line_numbers == .off) return true;
    self.vi_line_numbers_visible = !self.vi_line_numbers_visible;
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.updateViModeRenderState();
    self.queueRender() catch {};
},
```

- [ ] **Step 4: Verify it compiles**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build

- [ ] **Step 5: Commit**

```bash
git add src/input/Binding.zig src/Surface.zig
git commit -m "feat(input): add toggle_vi_line_numbers keybind action"
```

---

## Chunk 2: Overlay Feature and Gutter Rendering

### Task 6: Add Feature variant and wire up in generic.zig

**Files:**
- Modify: `src/renderer/Overlay.zig`
- Modify: `src/renderer/generic.zig`

- [ ] **Step 1: Add Feature variant to Overlay.zig**

In the `Feature` union (line ~71), add after `vi_mode_indicator`:

```zig
vi_line_numbers: struct {
    mode: enum { relative, absolute },
    cursor_row: usize,
    viewport_top_abs_row: usize,
    viewport_rows: usize,
    has_mode_indicator: bool,
},
```

- [ ] **Step 2: Add match arm in applyFeatures**

In `applyFeatures` (line ~141), add a new case in the `switch`:

```zig
.vi_line_numbers => |data| self.highlightViLineNumbers(alloc, state, data),
```

- [ ] **Step 3: Add stub highlightViLineNumbers**

After `highlightViModeIndicator` (line ~363), add a stub:

```zig
/// Draw the line number gutter for vi mode.
fn highlightViLineNumbers(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
    data: anytype,
) void {
    _ = self;
    _ = alloc;
    _ = state;
    _ = data;
    // TODO: implement in Task 8
}
```

- [ ] **Step 4: Construct the feature in generic.zig**

In `generic.zig`, inside the `if (state.vi_mode.active)` block (line ~1281), after the vi_cursor feature construction (line ~1293), add:

```zig
// Line numbers — only if enabled and cursor is visible
if (state.vi_mode.line_numbers != .off) {
    if (state.vi_mode.cursor_row) |cursor_row| {
        if (state.vi_mode.viewport_top_abs_row) |top_abs| {
            feature_list.append(arena_alloc, .{
                .vi_line_numbers = .{
                    .mode = switch (state.vi_mode.line_numbers) {
                        .off => unreachable,
                        .relative => .relative,
                        .absolute => .absolute,
                    },
                    .cursor_row = cursor_row,
                    .viewport_top_abs_row = top_abs,
                    .viewport_rows = self.terminal_state.rows,
                    .has_mode_indicator = state.vi_mode.mode_text != null,
                },
            }) catch {};
        }
    }
}
```

- [ ] **Step 5: Verify it compiles**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build

- [ ] **Step 6: Commit**

```bash
git add src/renderer/Overlay.zig src/renderer/generic.zig
git commit -m "feat(renderer): add vi_line_numbers overlay feature variant and wire-up"
```

---

### Task 7: Implement digit drawing

**Files:**
- Modify: `src/renderer/Overlay.zig`

This is the largest task. Each digit 0-9 is drawn as z2d path commands, scaled to fit within a cell.

- [ ] **Step 1: Add digit path drawing function**

After the `highlightViLineNumbers` stub, add the digit drawing infrastructure. Each digit is drawn within a bounding box `(x, y, w, h)` using z2d path commands. The digits use a simple 7-segment-like style with straight lines for readability at small sizes.

```zig
/// Draw a single digit (0-9) within the given pixel bounding box.
/// The digit is drawn using z2d line paths (no font dependency).
fn drawDigit(
    ctx: *z2d.Context,
    bx: f64,
    by: f64,
    bw: f64,
    bh: f64,
    digit: u8,
) !void {
    // Margins: 15% horizontal, 10% vertical
    const mx = bw * 0.15;
    const my = bh * 0.10;
    const x0 = bx + mx; // left
    const x1 = bx + bw - mx; // right
    const y0 = by + my; // top
    const y1 = by + bh - my; // bottom
    const ym = by + bh / 2.0; // center y

    // Each digit is defined as a set of line segments.
    // Segments: T=top, M=middle, B=bottom, TL=top-left, TR=top-right, BL=bottom-left, BR=bottom-right
    const segs = digitSegments(digit);

    if (segs.top) {
        try ctx.moveTo(x0, y0);
        try ctx.lineTo(x1, y0);
    }
    if (segs.top_left) {
        try ctx.moveTo(x0, y0);
        try ctx.lineTo(x0, ym);
    }
    if (segs.top_right) {
        try ctx.moveTo(x1, y0);
        try ctx.lineTo(x1, ym);
    }
    if (segs.middle) {
        try ctx.moveTo(x0, ym);
        try ctx.lineTo(x1, ym);
    }
    if (segs.bottom_left) {
        try ctx.moveTo(x0, ym);
        try ctx.lineTo(x0, y1);
    }
    if (segs.bottom_right) {
        try ctx.moveTo(x1, ym);
        try ctx.lineTo(x1, y1);
    }
    if (segs.bottom) {
        try ctx.moveTo(x0, y1);
        try ctx.lineTo(x1, y1);
    }

}

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
```

- [ ] **Step 2: Add drawDigitString function**

This is the swappable interface — draws a right-aligned number string in the gutter:

```zig
/// Draw a number as right-aligned digit string in the gutter area.
/// Each digit occupies one cell width. This is the swappable interface
/// for digit rendering — replace drawDigit internals for font-atlas rendering.
fn drawDigitString(
    self: *Overlay,
    ctx: *z2d.Context,
    number: usize,
    row: usize,
    gutter_width: usize,
    color: z2d.Pixel,
) !void {
    // Convert number to digits (max 5 digits for gutter width 5+1)
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

    // Right-align: the rightmost digit goes in column (gutter_width - 2)
    // (gutter_width - 1 is the separator column)
    const num_cols = gutter_width -| 1; // columns available for digits
    if (digit_count > num_cols) return; // shouldn't happen but guard

    const cell_w: f64 = @floatFromInt(self.cell_size.width);
    const cell_h: f64 = @floatFromInt(self.cell_size.height);
    const row_y: f64 = @floatFromInt(row * self.cell_size.height);

    ctx.setSourceToPixel(color);
    ctx.setLineWidth(1.5);

    // Draw digits right-to-left
    var i: usize = 0;
    while (i < digit_count) : (i += 1) {
        const col = num_cols - 1 - i; // column position (0-based from left)
        const col_x: f64 = @floatFromInt(col * self.cell_size.width);
        try drawDigit(ctx, col_x, row_y, cell_w, cell_h, digits[i]);
    }

    try ctx.stroke();
}
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build

- [ ] **Step 4: Commit**

```bash
git add src/renderer/Overlay.zig
git commit -m "feat(overlay): implement z2d hand-drawn digit paths (0-9) and drawDigitString"
```

---

### Task 8: Implement gutter rendering

**Files:**
- Modify: `src/renderer/Overlay.zig`

- [ ] **Step 1: Add gutter color constants**

After the existing `vi_visual_border` function (line ~375), add:

```zig
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
```

- [ ] **Step 2: Add gutterWidth helper**

```zig
/// Compute the gutter width (in cells) for the given maximum number.
/// Returns digit columns + 1 separator column.
fn gutterWidth(max_number: usize) usize {
    if (max_number == 0) return 2; // "0" + separator
    var digits: usize = 0;
    var n = max_number;
    while (n > 0) : (digits += 1) n /= 10;
    return digits + 1; // digits + separator
}
```

- [ ] **Step 3: Replace highlightViLineNumbers stub with full implementation**

Replace the stub from Task 6 with:

```zig
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

    // Skip if terminal is too narrow for a gutter
    if (state.cols < 4) return;

    // Compute max number to determine gutter width
    const max_number: usize = switch (data.mode) {
        .relative => if (viewport_rows > 1) viewport_rows - 1 else 1,
        .absolute => top_abs + viewport_rows,
    };
    const gw = gutterWidth(max_number);

    // Don't draw if gutter would take up more than 1/3 of terminal width
    if (gw * 3 > state.cols) return;

    // Detect if mode indicator is active (occupies bottom row).
    // This info is passed via the Feature payload since terminal.RenderState
    // does not have vi_mode (that lives on renderer.State).
    const indicator_row: ?usize = if (data.has_mode_indicator and state.rows > 0) state.rows - 1 else null;

    // Draw gutter background (30% black)
    const bg_color = gutterBackground();
    const gutter_px_width: usize = gw * self.cell_size.width;
    for (0..viewport_rows) |row| {
        // Skip bottom row background if mode indicator is active
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
    const total_height = viewport_rows * self.cell_size.height;
    for (0..total_height) |dy| {
        const y: i32 = std.math.cast(i32, dy) orelse continue;
        self.surface.paintStride(sep_x, y, 1, sep_color);
    }

    // Draw line numbers
    var ctx: z2d.Context = .init(alloc, &self.surface);
    defer ctx.deinit();
    ctx.setAntiAliasingMode(.none);
    ctx.setHairline(false);

    for (0..viewport_rows) |row| {
        const number: usize = if (row == cursor_row)
            // Current line: always show absolute row number (1-based)
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
```

- [ ] **Step 4: Verify it compiles**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build

- [ ] **Step 5: Commit**

```bash
git add src/renderer/Overlay.zig
git commit -m "feat(overlay): implement vi-mode line number gutter rendering"
```

---

## Chunk 3: Tests and Verification

### Task 9: Add unit tests

**Files:**
- Modify: `src/renderer/Overlay.zig`

- [ ] **Step 1: Add test for gutterWidth**

At the bottom of `Overlay.zig`, add:

```zig
test "gutterWidth computes correct width" {
    const testing = std.testing;
    // Single digit + separator
    try testing.expectEqual(@as(usize, 2), gutterWidth(0));
    try testing.expectEqual(@as(usize, 2), gutterWidth(9));
    // Two digits + separator
    try testing.expectEqual(@as(usize, 3), gutterWidth(10));
    try testing.expectEqual(@as(usize, 3), gutterWidth(99));
    // Three digits + separator
    try testing.expectEqual(@as(usize, 4), gutterWidth(100));
    try testing.expectEqual(@as(usize, 4), gutterWidth(999));
    // Four digits + separator
    try testing.expectEqual(@as(usize, 5), gutterWidth(1000));
    try testing.expectEqual(@as(usize, 5), gutterWidth(9999));
}

test "digitSegments returns correct segments for all digits" {
    const testing = std.testing;
    // Digit 0: all segments except middle
    const s0 = digitSegments(0);
    try testing.expect(s0.top);
    try testing.expect(s0.top_left);
    try testing.expect(s0.top_right);
    try testing.expect(!s0.middle);
    try testing.expect(s0.bottom_left);
    try testing.expect(s0.bottom_right);
    try testing.expect(s0.bottom);

    // Digit 1: only right side
    const s1 = digitSegments(1);
    try testing.expect(!s1.top);
    try testing.expect(!s1.top_left);
    try testing.expect(s1.top_right);
    try testing.expect(!s1.middle);
    try testing.expect(!s1.bottom_left);
    try testing.expect(s1.bottom_right);
    try testing.expect(!s1.bottom);

    // Digit 8: all segments
    const s8 = digitSegments(8);
    try testing.expect(s8.top);
    try testing.expect(s8.top_left);
    try testing.expect(s8.top_right);
    try testing.expect(s8.middle);
    try testing.expect(s8.bottom_left);
    try testing.expect(s8.bottom_right);
    try testing.expect(s8.bottom);

    // Invalid digit: no segments
    const s_invalid = digitSegments(10);
    try testing.expect(!s_invalid.top);
    try testing.expect(!s_invalid.middle);
    try testing.expect(!s_invalid.bottom);
}
```

- [ ] **Step 2: Run the tests**

Run: `zig build test -Dtest-filter="gutterWidth" 2>&1 | tail -10`
Expected: Tests pass

**Note:** Use `zig build test` (not bare `zig test`) because Overlay.zig imports z2d and terminal packages that require the build system's dependency resolution.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/Overlay.zig
git commit -m "test(overlay): add unit tests for gutterWidth and digitSegments"
```

---

### Task 10: Build verification and visual test

**Files:** None (verification only)

- [ ] **Step 1: Full build (skip app bundle)**

Run: `zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Clean build with no warnings

- [ ] **Step 2: Run full test suite with filter**

Run: `zig build test -Dtest-filter="gutterWidth" 2>&1 | tail -10`
Expected: Tests pass

- [ ] **Step 3: Visual test (manual)**

1. Set config: `vi-mode-line-numbers = relative`
2. Launch the terminal with `zig build run` (or build the macOS app with `macos/build.nu`)
3. Open a file with content (e.g., `cat /etc/hosts`)
4. Enter vi mode (keybind for `enter_vi_mode`)
5. Verify:
   - Line number gutter appears on the left
   - Current line shows absolute number (bright white)
   - Other lines show relative distance (dimmed)
   - Navigate with j/k — numbers update
   - Gutter background is darkened
   - Thin separator line visible
6. Test with `vi-mode-line-numbers = absolute` — all numbers should be absolute
7. Test with `vi-mode-line-numbers = off` — no gutter should appear

- [ ] **Step 4: Final commit (if any fixups needed)**

```bash
git add -A
git commit -m "fix: address visual test findings for vi-mode line numbers"
```

---

## Implementation Notes

**Build command:** Always use `zig build -Demit-macos-app=false` during development to skip the app bundle and speed up compilation.

**Import paths:** Surface.zig already imports the renderer package as `rendererpkg`. Use `rendererpkg.State.ViMode.LineNumbers` for the enum type. Check existing imports at the top of Surface.zig.

**z2d `paintStride`:** Does direct pixel replacement (memset), not compositing. Used for the gutter background and separator to avoid alpha doubling issues (same approach as the mode indicator in dc6fe49). Signature: `paintStride(x: i32, y: i32, len: usize, pixel: Pixel)` — writes `len` pixels starting at `(x, y)` going right. Use `paintStride(x, y, 1, color)` for single-pixel writes (there is no per-pixel `paintPixel(x, y, color)` method).

**z2d RGBA initialization:** Always use `.fromPixel()` to create RGBA values, not direct struct literals. The `z2d.pixel.RGBA` type uses premultiplied alpha; `.fromPixel()` ensures correct conversion. Pattern: `var rgba: z2d.pixel.RGBA = .fromPixel((z2d.pixel.RGB{ .r = R, .g = G, .b = B }).asPixel()); rgba.a = ALPHA; return rgba.multiply().asPixel();`

**terminal.RenderState vs renderer.State:** Inside `applyFeatures`, the `state` parameter is `*const terminal.RenderState` — it has `.rows` and `.cols` but NOT `.vi_mode`. Vi-mode state lives on `renderer.State`, which is only accessible in generic.zig's critical section. Any vi-mode data needed in Overlay must be passed through the Feature payload.

**`pointFromPin` can return null:** Always handle the null case. If `pointFromPin(.screen, viewport_top)` returns null, set `viewport_top_abs_row = null` and skip line numbers.

**Line numbers are 1-based:** The spec says absolute numbers represent scrollback row numbers. Row 0 in screen coordinates should display as "1" to the user (matching Neovim convention).

**Task ordering:** Tasks 1-5 (Chunk 1) must be done sequentially. Task 6 depends on Tasks 3+4+5. Tasks 7-8 depend on Task 6. Task 9 depends on Tasks 7-8. Task 10 depends on all.
