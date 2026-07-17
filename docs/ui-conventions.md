# TUI conventions

Layout and chrome rules every view follows, plus the design decisions
behind them. The authoritative code lives in `src/tui/style.zig` (plus the
shared SGR palette in `src/ui/ansi.zig`) and `tui/main.zig`'s `draw`; views
implement these rules per file.

## Frame anatomy and the row budget

`tui/main.zig`'s `draw` owns four rows of chrome: the header line and the `hr`
divider above a view (`content_top = 2`), and the meter row, prompt
row, and status row below it. A view receives the full terminal `rows`
and must emit exactly `rows - 4` lines, padding with `endLine` at the
end of its draw:

```zig
const used = <rows actually printed, including titles>;
for (used..@max(used, rows -| 4)) |_| try endLine(w);
```

Getting `used` wrong is a recurring bug class: forgetting to count a
title/preamble row scrolls the real header off screen or leaves dead
blank rows above the footer. When sizing scrollable content, subtract
the view's own internal header rows too (the piano roll's note rows are
`rows - 7`: 4 chrome rows plus its 3 internal header rows).

The prompt row is dedicated: `:` and `/` input renders there, between
the meter and status rows, so the status row keeps its badge and info
while the user types.

## Status row

The left edge is a lualine-style mode badge: a single letter (N/I/V,
plus C/S for command/search) on a color-coded background, then plain
uncolored text. Deliberately minimal: an earlier design with full-word
chips and a powerline divider was rejected against a real lualine
screenshot; real lualine chips only the mode and leaves the rest plain.
Right-aligned content (L/R meters, view tag, zoom/song flags) is pinned
to the row edge via `style.writeSplitRow`. Views that draw their own
status content must still surface `App.setStatus` feedback rather than
eating it.

## Chrome rows

Header/transport rows go through `style.writeChromeRow`: clamped to
`cols`, no fill. A reverse-video header fill was tried and read as a
stray highlighted bar; no separator reads cleaner than either that or
an extra rule row. `endLine` resets SGR before erasing so background
color never bleeds into the right edge.

## Frame delivery

Each frame is wrapped in the DEC 2026 synchronized-update bracket so
terminals repaint atomically (no tearing/flicker). The frame buffer
must be sized generously: a 32KB buffer once overflowed at max
pads x steps and corrupted the closing bracket, which presented as
"glitching pads", not as an obvious overflow. It is 160KB now.

Terminals smaller than 80x14 get a resize gate instead of a broken
layout.

## Icons

Icon glyphs are Private Use Area codepoints from an embedded Nerd Font
subset (see `src/ui/icons.zig`). Every icon site either also has an
ASCII rendering (shown instead when the font is not installed) or sits
next to text that already says the same thing, so a missing font never
shows a tofu box carrying information. The Mono variant guarantees one
cell per glyph, keeping hand-aligned columns intact.

## Alignment lockstep

Some widths are shared contracts, not per-view choices: the tracks
view's name column width and its mouse hit-testing gutter move
together, and form-width knobs are reset per frame in `tui/main.zig`'s `draw`.
Change one side of such a pair and the other silently misaligns.
