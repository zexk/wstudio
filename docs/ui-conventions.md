# TUI conventions

Layout and chrome rules every view follows, plus the design decisions
behind them. The authoritative code lives in `src/tui/style.zig` (plus the
shared SGR palette in `src/ui/ansi.zig`) and `tui/tui.zig`'s `draw`; views
implement these rules per file.

## Frame anatomy and the row budget

`tui/tui.zig`'s `draw` owns four rows of chrome: the header line and the `hr`
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

The left edge is a lualine-style mode badge: N/I/V, C/S for
command/search, V-L for visual-line selection, or V-E for visual editing,
on a color-coded background, then plain uncolored text. Deliberately minimal:
an earlier design with full-word
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

## Measuring width

Width means display columns, never bytes and never codepoints.
`style.visibleWidth` and `style.writeClamped` walk a row through one shared
`nextCell` step: an SGR escape costs nothing, a combining mark costs nothing,
an East Asian Wide or emoji glyph costs two, everything else costs one
(`style.charWidth`). Slicing a name by bytes splits a codepoint, and counting
codepoints under-measures every CJK name by half - both of which put a row
past the right edge, where it wraps and pushes the whole frame down a line.
`writeClamped` drops a wide glyph that would straddle the edge rather than
emitting half of one. The private use area stays one column, because the
icon font's Mono variant guarantees that.

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

That rule is a terminal rule: the GUI links the font in, so its toolbar
buttons carry a glyph and nothing else, and they take it from the same
font rather than from DejaVu's arrows and math signs, which sit at a
different weight and optical size. `widgets.iconButton` then pins every
one of them to the same square, since ImGui would otherwise size each
button to its own glyph's advance width.

## Alignment lockstep

Some widths are shared contracts, not per-view choices: the tracks
view's name column width and its mouse hit-testing gutter move
together, and form-width knobs are reset per frame in `tui/tui.zig`'s `draw`.
Change one side of such a pair and the other silently misaligns.
