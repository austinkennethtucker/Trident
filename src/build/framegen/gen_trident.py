#!/usr/bin/env python3
"""Generate 235 frames of a trident ASCII art animation with shimmer effect.

Each frame is 100 chars wide x 41 lines tall, using the same character set and
<span class="b"> markup as the original ghost animation.

A large, detailed trident with a wave of blue energy sweeping upward.
"""

import math
import os
import re

WIDTH = 100
HEIGHT = 41
NUM_FRAMES = 235

# We'll define the trident as raw ASCII art lines (no spans), then the
# animation logic adds spans per-frame based on the shimmer wave position.
# Each line must be exactly 100 chars (padded with spaces).

# Design: a chunky, detailed trident filling ~70 cols x 39 rows.
# Characters used: @$%*+=xo~· and space.

TRIDENT_ART = r"""
                                                 @
                                                @@@
                                               @@@@@
                                              $@@@@@$
                                             $$@@@@@$$
                              @             $$$@@@@@$$$             @
                             @@@           $$$$@@@@@$$$$           @@@
                            @@@@@         $$$$$@@@@@$$$$$         @@@@@
                           $@@@@@$       $$$$$$@@@@@$$$$$$       $@@@@@$
                          $$@@@@@$$     $$$$$$$@@@@@$$$$$$$     $$@@@@@$$
                         $$$@@@@@$$$  $$$$$$$$$@@@@@$$$$$$$$$  $$$@@@@@$$$
                        $$$$@@@@@$$$$$$$$$$$$$$@@@@@$$$$$$$$$$$$$$$@@@@@$$$$
                       $$$$$@@@@@$$$$$$$$$$$$$$@@@@@$$$$$$$$$$$$$$$$@@@@@$$$$$
                      $$$$$$$@@@@$$$$$$$$$$$$$$@@@@@$$$$$$$$$$$$$$$$$@@@@$$$$$$$
                     =$$$$$$$$@@@@@$$$$$$$$$$$$@@@@@$$$$$$$$$$$$$$@@@@@$$$$$$$$=
                     *%$$$$$$$$$$@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@$$$$$$$$$$%*
                     *%%$$$$$$$$$$$$@@@@@@@@@@@@@@@@@@@@@@@@@@@$$$$$$$$$$$$$$%%*
                     *%$$$$$$$$$$$$$$$$$$$$$$$$@@@@@$$$$$$$$$$$$$$$$$$$$$$$$$$%*
                      =%$$$$$$$$$$$$$$$$$$$$$$$@@@@@$$$$$$$$$$$$$$$$$$$$$$$$$%=
                        *%$$$$$$$$$$$$$$$$$$$$@@@@@@@$$$$$$$$$$$$$$$$$$$$$$%*
                          =%$$$$$$$$$$$$$$$$$$@@@@@@@$$$$$$$$$$$$$$$$$$$$%=
                            *%$$$$$$$$$$$$$$$$$@@@@@$$$$$$$$$$$$$$$$$$$%*
                              =%$$$$$$$$$$$$$$$@@@@@$$$$$$$$$$$$$$$$$%=
                                *%$$$$$$$$$$$$@@@@@@@$$$$$$$$$$$$$$%*
                                  =%$$$$$$$$$$$@@@@@$$$$$$$$$$$$$%=
                                    *%$$$$$$$$$@@@@@$$$$$$$$$$$%*
                                      =%$$$$$$@@@@@@@$$$$$$$$%=
                                        *%$$$$@@@@@@@$$$$$$%*
                                          =%$$$@@@@@$$$$$%=
                                            *%$$@@@@@$$%*
                                             =%$@@@@@$%=
                                              *%@@@@@%*
                                              =%@@@@@%=
                                              *%@@@@@%*
                                             =%$$@@@$$%=
                                            *%$$$@@@$$$%*
                                           =%$$$$@@@$$$$%=
                                          *%$$$$$@@@$$$$$%*
                                           =*%$$$$@$$$$%*=
                                              =*%$$$%*=
""".strip('\n')


def parse_art():
    """Parse the ASCII art into a 2D grid."""
    lines = TRIDENT_ART.split('\n')
    grid = []
    for i, line in enumerate(lines):
        # Pad or trim to exactly WIDTH
        if len(line) < WIDTH:
            line = line + ' ' * (WIDTH - len(line))
        elif len(line) > WIDTH:
            line = line[:WIDTH]
        row = []
        for ch in line:
            row.append(ch)
        grid.append(row)

    # Ensure exactly HEIGHT rows
    while len(grid) < HEIGHT:
        grid.append([' '] * WIDTH)
    grid = grid[:HEIGHT]

    return grid


def add_aura(grid):
    """Add a faint glow (·) around trident edges."""
    marks = set()
    for row in range(HEIGHT):
        for col in range(WIDTH):
            if grid[row][col] != ' ':
                for dr in [-1, 0, 1]:
                    for dc in [-1, 0, 1]:
                        if dr == 0 and dc == 0:
                            continue
                        nr, nc = row + dr, col + dc
                        if 0 <= nr < HEIGHT and 0 <= nc < WIDTH:
                            if grid[nr][nc] == ' ':
                                marks.add((nr, nc))
    for r, c in marks:
        grid[r][c] = '·'


def is_edge(grid, row, col):
    """Check if a non-space cell is on the edge of the trident."""
    if grid[row][col] == ' ' or grid[row][col] == '·':
        return False
    for dr, dc in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        nr, nc = row + dr, col + dc
        if not (0 <= nr < HEIGHT and 0 <= nc < WIDTH):
            return True
        if grid[nr][nc] == ' ' or grid[nr][nc] == '·':
            return True
    return False


def path_position(row, col, grid):
    """Map a cell to its position along the trident's path (0.0=bottom, 1.0=tips).

    The energy wave follows this path value.
    """
    cx = WIDTH // 2

    # Bottom pommel (rows 37-40): very start of path
    if row >= 37:
        return (40 - row) / 40.0  # 0.0 to ~0.075

    # Shaft (rows 21-36)
    if row >= 21:
        return 0.075 + (36 - row) / 40.0  # ~0.075 to ~0.45

    # Crossbar region (rows 15-20): transition zone
    if row >= 15:
        return 0.45 + (20 - row) / 30.0  # ~0.45 to ~0.62

    # Prongs (rows 0-14): fan out toward tips
    # Add horizontal offset to create the splitting effect
    if row < 15:
        base = 0.62 + (14 - row) / 25.0  # ~0.62 to ~1.18
        # Horizontal offset adds slight delay to outer prongs
        dist_from_center = abs(col - cx)
        horiz_delay = dist_from_center / 300.0
        return base - horiz_delay

    return 0.5


def wave_intensity(row, col, frame, grid):
    """Calculate how much blue energy is at this position for this frame.

    Returns 0.0-1.0.
    """
    ch = grid[row][col]
    if ch == ' ':
        return 0.0

    pos = path_position(row, col, grid)

    # Two waves traveling up simultaneously, offset by half a cycle
    cycle_length = 90  # frames per full wave cycle
    wave_width = 0.15

    total = 0.0
    for wave_offset in [0.0, 0.5]:
        wave_center = ((frame / cycle_length) + wave_offset) % 1.0

        dist = abs(pos - wave_center)
        dist = min(dist, abs(pos - wave_center + 1.0), abs(pos - wave_center - 1.0))

        if dist < wave_width:
            intensity = 1.0 - (dist / wave_width)
            intensity = intensity ** 0.6  # sharpen
            total = max(total, intensity)

    return min(1.0, total)


def render_frame(grid, edge_map, frame):
    """Render a single frame with span markup."""
    lines = []

    for row in range(HEIGHT):
        parts = []
        in_span = False

        for col in range(WIDTH):
            ch = grid[row][col]
            wi = wave_intensity(row, col, frame, grid)

            # Blue conditions:
            # 1. Wave is passing through (wi > 0.4 for body, > 0.2 for edges/aura)
            # 2. Edge cells always have a faint blue
            is_e = edge_map[row][col]

            should_blue = False
            if ch == '·':
                should_blue = wi > 0.25
            elif is_e:
                should_blue = True  # edges always blue
            elif ch != ' ':
                should_blue = wi > 0.4

            if should_blue and not in_span:
                parts.append('<span class="b">')
                in_span = True
            elif not should_blue and in_span:
                parts.append('</span>')
                in_span = False

            parts.append(ch)

        if in_span:
            parts.append('</span>')

        lines.append(''.join(parts))

    return '\n'.join(lines) + '\n'


def verify_frame(frame_str):
    """Verify frame dimensions."""
    clean = re.sub(r'</?span[^>]*>', '', frame_str)
    lines = clean.split('\n')
    if lines and lines[-1] == '':
        lines = lines[:-1]

    assert len(lines) == HEIGHT, f"Expected {HEIGHT} lines, got {len(lines)}"
    for i, line in enumerate(lines):
        assert len(line) == WIDTH, \
            f"Line {i}: expected {WIDTH} chars, got {len(line)}"


def main():
    frames_dir = os.path.join(os.path.dirname(__file__), 'frames')

    # Remove existing frames
    for f in os.listdir(frames_dir):
        if f.endswith('.txt'):
            os.remove(os.path.join(frames_dir, f))

    print("Building trident shape...")
    grid = parse_art()
    add_aura(grid)

    # Pre-compute edge map
    edge_map = [[False] * WIDTH for _ in range(HEIGHT)]
    for r in range(HEIGHT):
        for c in range(WIDTH):
            edge_map[r][c] = is_edge(grid, r, c)

    print(f"Generating {NUM_FRAMES} frames...")
    for i in range(NUM_FRAMES):
        frame_str = render_frame(grid, edge_map, i)
        verify_frame(frame_str)

        filename = f"frame_{i+1:03d}.txt"
        filepath = os.path.join(frames_dir, filename)
        with open(filepath, 'w') as f:
            f.write(frame_str)

        if (i + 1) % 50 == 0:
            print(f"  Generated {i+1}/{NUM_FRAMES} frames")

    print(f"Done! {NUM_FRAMES} frames in {frames_dir}")


if __name__ == '__main__':
    main()
