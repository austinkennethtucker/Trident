# v5 Design Spec: Relative Line Numbers in Vi Mode

**Status:** Approved
**Date:** 2026-03-15
**Depends on:** v4 (Vi Mode) — shipped
**Estimated effort:** 8-10 hours

## Overview

Add a line number gutter to vi-mode that shows relative line numbers — like Neovim's `set relativenumber`. The gutter overlays the leftmost columns of the terminal using the existing z2d overlay system. No renderer pipeline changes, no platform-specific code.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Gutter approach | Overlay (no content shift) | Zero side effects, matches existing overlay pattern, no SIGWINCH/reflow |
| Digit rendering | Hand-drawn z2d paths (swappable interface) | Self-contained, no font system dependency; interface allows future font-atlas upgrade |
| Gutter width | Auto-size per frame | Minimizes obscured content, adapts to scrollback depth |
| Color scheme | Dark Recessed | 30% black background, 40% white relative numbers, bright white current line |
| Separator | Thin 1px vertical line | 20% white, crisp edge between gutter and content |
| Toggle behavior | On/off for configured mode | Config picks relative vs absolute; keybind shows/hides |
| Auto-activate | Yes | Line numbers appear immediately on vi-mode entry if configured |
| Default | Off | No behavior change unless user opts in |

## 1. Gutter Rendering & Layout

### Approach

A new `Feature` variant (`.vi_line_numbers`) in `Overlay.zig` draws the gutter directly on the existing z2d CPU surface. The overlay is composited on top of all terminal content via the image shader pipeline — identically on Metal, OpenGL, and WebGL. No platform-specific overlay code exists or is needed.

### Layout

- Gutter occupies the leftmost N columns of the terminal, overlaying content underneath.
- Background: 30% black overlay on top of terminal background (darkened/recessed effect).
- 1px vertical separator line at the right edge of the gutter (20% white).
- Width: auto-sized per frame based on the largest number displayed.

### Number Format

- **Relative mode:** Current cursor line shows its absolute scrollback row number (bright white, bold). All other visible lines show the distance from the cursor (40% white).
- **Absolute mode:** All lines show their absolute scrollback row number. Current cursor line highlighted in bright white.

### Gutter Width Auto-Sizing

Width is computed per frame from the maximum number that will be displayed:

| Max visible number | Gutter width (cells) |
|--------------------|----------------------|
| 1-9                | 1 digit + 1 separator = 2 |
| 10-99              | 2 digits + 1 separator = 3 |
| 100-999            | 3 digits + 1 separator = 4 |
| 1000-9999          | 4 digits + 1 separator = 5 |

In relative mode, the max is `viewport_rows - 1` (typically 2-3 cells). In absolute mode, the max depends on total scrollback depth.

### Rendering Order

In `generic.zig`, `.vi_line_numbers` is appended to the feature list **after** `.vi_cursor` and `.vi_mode_indicator`. This means line numbers render last in `applyFeatures`, on top of search highlights, selections, the vi cursor, and other overlays in the gutter area.

Exception: the gutter background is **not drawn** on the bottom row when the mode indicator is active, so the indicator bar remains fully visible beneath the gutter columns.

## 2. Digit Rendering

### Hand-Drawn z2d Paths (Initial)

Each digit 0-9 is defined as ~10-20 z2d line/curve commands, scaled to fit within a cell with ~10% padding on each side. Similar in approach to how `src/font/sprite/Face.zig` draws box-drawing characters using the sprite canvas.

- Anti-aliasing disabled (matches existing overlay style — sharp edges)
- Digits are right-aligned within the gutter
- The separator `│` is a single vertical line stroke

### Swappable Interface

The gutter rendering function calls digit drawing through a clear interface boundary:

```
drawDigitString(ctx, row_y, gutter_width, number_string, color)
```

This function handles positioning and iterating over characters. Each character is drawn by `drawDigit(ctx, x, y, width, height, digit)`. A future font-atlas implementation replaces `drawDigit` internals without touching the gutter layout logic.

### Quality

- Readable at typical cell sizes (10x20, 14x28) — comparable to sprite-drawn box-drawing characters
- May look slightly blocky at very small sizes (8x16) — acceptable for v1
- Upgradeable to font-rendered glyphs via the swappable interface

## 3. Configuration

### Config Key

```
vi-mode-line-numbers = off | relative | absolute
```

- `off` (default): No line numbers. Current behavior preserved.
- `relative`: Current line shows absolute number, other lines show distance from cursor.
- `absolute`: All lines show absolute scrollback row number, current line highlighted.

Added to `src/config/Config.zig` as an enum field. Flows through `DerivedConfig` in `generic.zig`.

### Runtime Toggle

- New keybind action: `toggle_vi_line_numbers` in `Binding.zig`, scoped to surface.
- No default key binding — user adds one if desired.
- Toggle is on/off for the configured mode (does not cycle through modes).
- If `vi-mode-line-numbers` is `off`, the toggle action has no effect.
- A `vi_line_numbers_visible: bool` field on `Surface` tracks the toggle state, defaulting to `true` on vi-mode entry (auto-activate).

### Hot-Reload

Config changes to `vi-mode-line-numbers` take effect on the next render frame. If vi-mode is active, the gutter appears, disappears, or changes mode immediately.

## 4. State Plumbing

### Render State Extension

Two new fields on `State.zig`'s `ViMode` struct:

- `line_numbers: enum { off, relative, absolute }` — active mode (reflects config + runtime toggle)
- `viewport_top_abs_row: ?usize` — absolute scrollback row of the viewport's top-left corner. Used to derive the absolute row number of any visible line: `viewport_top_abs_row + viewport_row_index`.

The existing `cursor_row: ?usize` field (already in `ViMode`) provides the cursor's viewport-relative row. No new field is needed for this — it is reused directly.

**Coordinate spaces (clarification):**
- **Viewport-relative** (`pointFromPin(.viewport, pin)`): Row 0 is the top of the visible area. Used for relative distance computation and positioning within the overlay surface. The existing `cursor_row` field is in this space.
- **Scrollback-absolute** (`pointFromPin(.screen, pin)`): Row 0 is the very first line in the scrollback history. Used for displaying absolute line numbers.

The cursor's absolute row for display = `viewport_top_abs_row + cursor_row`.

**How to compute `viewport_top_abs_row` in `updateViModeRenderState()`:**
```zig
const viewport_top = screen.pages.getTopLeft(.viewport);
const screen_point = screen.pages.pointFromPin(.screen, viewport_top);
// viewport_top_abs_row = screen_point.screen.y
```

### Feature Variant Payload

The `.vi_line_numbers` variant in `Overlay.Feature` carries its data as payload:

```zig
vi_line_numbers: struct {
    mode: enum { relative, absolute },
    cursor_row: usize,           // viewport-relative (from ViMode.cursor_row)
    viewport_top_abs_row: usize, // scrollback-absolute row of viewport top (from ViMode.viewport_top_abs_row)
    viewport_rows: usize,        // total visible rows (from terminal.rows, already in render state)
},
```

**Null guard:** `generic.zig` only appends `.vi_line_numbers` when `cursor_row != null` (cursor is visible in viewport). This mirrors the existing guard on `.vi_cursor` (`if (state.vi_mode.cursor_row) |row|`).

### Data Flow

```
Surface.updateViModeRenderState()
  |-- read config vi-mode-line-numbers
  |-- check vi_line_numbers_visible toggle
  |-- compute cursor viewport row via pointFromPin(.viewport, cursor_pin)
  |-- compute viewport top absolute row via pointFromPin(.screen, viewport_top_pin)
  |-- set renderer_state.vi_mode.line_numbers = relative|absolute|off
  |-- set renderer_state.vi_mode.viewport_top_abs_row = screen_y
  v
generic.zig updateFrame() critical section
  |-- read state.vi_mode
  |-- if line_numbers != .off AND cursor_row != null:
  |     viewport_rows read from terminal.rows (already available in render state)
  |     append .vi_line_numbers { .mode, .cursor_row, .viewport_top_abs_row, .viewport_rows }
  v
Overlay.applyFeatures()
  |-- highlightViLineNumbers(payload)
  |     Compute gutter_width from max displayed number
  |     Draw 30% black background behind gutter (skip bottom row if mode indicator active)
  |     Draw 1px separator line at gutter right edge
  |     For each visible row:
  |       abs_row = viewport_top_abs_row + row_index
  |       if row_index == cursor_row:
  |         draw abs_row in bright white (current line)
  |       else if mode == .relative:
  |         draw |cursor_row - row_index| in 40% white
  |       else: // absolute
  |         draw abs_row in 40% white
  v
overlay uploaded as GPU image, composited on top of terminal
```

## 5. Performance

- Zero cost when vi-mode is inactive or line numbers are off.
- Only iterates visible rows (viewport height, typically 25-80 rows).
- Per-frame cost: ~50 rows × ~15 path operations per digit × 2 digits average = ~1,500 z2d path ops. Modest addition to the existing overlay redraw.
- Gutter width recomputed per frame via one `log10` — negligible.
- No allocations in the hot path; digit drawing uses the existing z2d context.

## 6. Edge Cases

| Scenario | Behavior |
|----------|----------|
| Terminal < 4 columns wide | Skip gutter entirely |
| Cursor scrolled off viewport | `cursor_row` is null; skip `.vi_line_numbers` feature (no gutter drawn). Mirrors existing `.vi_cursor` null guard. |
| Scrollback garbage collection (page pruned) | Cursor resets to viewport top-left (existing behavior); line numbers follow automatically |
| Visual selection in gutter area | Selection renders first, line numbers render on top (partially obscure selection in gutter columns) |
| Search highlights in gutter area | Same — numbers on top |
| Mode indicator overlap (bottom row) | Gutter background is skipped on the bottom row when the mode indicator is active, preserving the indicator's visual. The bottom row's line number digit still renders on top. |
| Light terminal themes | 30% black overlay still darkens gutter; 40% white digits visible against light backgrounds, though less distinct. Acceptable for v1. |

## Files to Modify

| File | Changes |
|------|---------|
| `src/config/Config.zig` | Add `vi-mode-line-numbers` enum field (off/relative/absolute) |
| `src/renderer/State.zig` | Add `line_numbers` and `viewport_top_abs_row` to `ViMode` struct (reuse existing `cursor_row`) |
| `src/Surface.zig` | Extend `updateViModeRenderState()` to compute and set line number fields; add `vi_line_numbers_visible` toggle field |
| `src/renderer/generic.zig` | Read line number config, append `.vi_line_numbers` feature when active |
| `src/renderer/Overlay.zig` | Add `.vi_line_numbers` feature variant; implement `highlightViLineNumbers()`, `drawDigitString()`, `drawDigit()` |
| `src/input/Binding.zig` | Add `toggle_vi_line_numbers` action |

## No Platform-Specific Changes

Metal.zig and OpenGL.zig require zero changes. The overlay system is entirely platform-agnostic — it draws on a CPU surface and uploads as a texture. Both renderers already composite this texture identically.
