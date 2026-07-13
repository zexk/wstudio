//! Synth-editor input: param row navigation ({/} jump sections), h/l nudges
//! routed over the engine command queue to the audio thread, and the
//! cursor-row/scroll math shared with the renderer in views/synth.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const style = @import("../style.zig");
const App = @import("../app.zig").App;
const spectrum = @import("spectrum.zig");
const piano = @import("piano.zig");
const preset_picker = @import("preset_picker.zig");
const history = @import("../history.zig");

// zig fmt: off
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    switch (key) {
        .escape => { history.flushParamNudge(app); app.view = .tracks; return true; },
        .ctrl_r => { history.doRedo(app); return true; },
        .char => |c| switch (c) {
            // Block insert mode — piano keys conflict with parameter navigation.
            'i' => return true,
            's' => { history.flushParamNudge(app); spectrum.switchToTrack(app, app.synth_track); return true; },
            // p opens the piano roll for this track (matches p in the tracks view);
            // e in the piano roll comes back here, so synth <-> roll is bidirectional.
            'p' => {
                history.flushParamNudge(app);
                piano.switchTo(app, app.synth_track);
                if (app.view == .piano_roll) app.autoSongMode(false);
                return true;
            },
            // f browses factory + saved presets — same apply path as :synth-preset.
            'f' => { history.flushParamNudge(app); preset_picker.open(app, .synth, app.synth_track); return true; },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            // j/k rows and h/l nudges take a vim count prefix (3j, 5l, …).
            'j' => { moveCursor(app, app.takeCount()); return true; },
            'k' => { moveCursor(app, -app.takeCount()); return true; },
            'h' => { adjustParam(app, -app.takeCount()); return true; },
            'l' => { adjustParam(app, app.takeCount()); return true; },
            'H' => { adjustParam(app, -10 * app.takeCount()); return true; },
            'L' => { adjustParam(app, 10 * app.takeCount()); return true; },
            'g' => { history.flushParamNudge(app); app.synth_cursor = 0; updateScroll(app); return true; },
            'G' => { history.flushParamNudge(app); app.synth_cursor = style.synth_param_count - 1; updateScroll(app); return true; },
            '}', '{' => {
                history.flushParamNudge(app);
                const section_starts = [_]u8{ 0, 6, 14, 16, 20, 24, 28, 32, 34, 36, 38, 39 };
                if (c == '}') {
                    for (section_starts) |s| {
                        if (s > app.synth_cursor) {
                            app.synth_cursor = s;
                            break;
                        }
                    }
                } else {
                    var sec_idx: usize = 0;
                    for (section_starts, 0..) |s, idx| {
                        if (s <= app.synth_cursor) sec_idx = idx;
                    }
                    if (app.synth_cursor == section_starts[sec_idx] and sec_idx > 0) {
                        app.synth_cursor = section_starts[sec_idx - 1];
                    } else {
                        app.synth_cursor = section_starts[sec_idx];
                    }
                }
                updateScroll(app);
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

/// Move the param cursor by `delta` rows, clamped to the param list.
fn moveCursor(app: *App, delta: i32) void {
    app.synth_cursor = @intCast(std.math.clamp(
        @as(i32, app.synth_cursor) + delta, 0, style.synth_param_count - 1,
    ));
    updateScroll(app);
}
// zig fmt: on

/// Wide terminals split the editor into OSC A / OSC B side by side on top
/// (7 and 9 rows respectively — OSC B is taller, so the top block is 9 rows)
/// followed by every other section stacked full-width beneath, instead of
/// one 51-row scroll. 108 cols keeps both oscillator columns comfortably
/// above their own widest row (OSC B's 9-row block).
pub const two_col_min_cols: usize = 108;

pub fn twoCol(cols: usize) bool {
    return cols >= two_col_min_cols;
}

/// Left column's width in the OSC A/B top block; the right column takes the rest.
pub fn colWidth(cols: usize) usize {
    return cols / 2;
}

/// Row budget of the OSC A/B top block (max of OSC A's 7 rows and OSC B's 9).
pub const top_h: usize = 9;

/// Total body rows (below the shared title) in the wide A/B-over-C layout.
pub const body_rows_wide: usize = 46;

// zig fmt: off
/// Column + row of `cursor` within the wide layout (row 0 is the shared
/// title). OSC A/B (rows 1-9) are side by side, col meaningful; everything
/// else (rows 10-43) is a single full-width column and col is unused. Must
/// stay in sync with secOscA/secOscB/drawSynthBottom in views/synth.zig,
/// exactly like paramRow mirrors the single-column order.
pub fn paramColRow(cursor: u8) struct { col: u1, row: usize } {
    return switch (cursor) {
        0...5   => .{ .col = 0, .row = 2  + @as(usize, cursor) },        // OSC A (header at 1)
        6...13  => .{ .col = 1, .row = 2  + @as(usize, cursor - 6) },    // OSC B (header at 1)
        14...15 => .{ .col = 0, .row = 11 + @as(usize, cursor - 14) },   // MOD (header at 10)
        16...19 => .{ .col = 0, .row = 14 + @as(usize, cursor - 16) },   // ENV (header at 13)
        20...23 => .{ .col = 0, .row = 19 + @as(usize, cursor - 20) },   // FILTER (header at 18)
        24...27 => .{ .col = 0, .row = 24 + @as(usize, cursor - 24) },   // FENV (header at 23)
        28...31 => .{ .col = 0, .row = 29 + @as(usize, cursor - 28) },   // LFO (header at 28)
        32...33 => .{ .col = 0, .row = 34 + @as(usize, cursor - 32) },   // VOICE (header at 33)
        34...35 => .{ .col = 0, .row = 37 + @as(usize, cursor - 34) },   // SUB (header at 36)
        36...37 => .{ .col = 0, .row = 40 + @as(usize, cursor - 36) },   // NOISE (header at 39)
        38      => .{ .col = 0, .row = 43 },                             // OUT (header at 42)
        39...40 => .{ .col = 0, .row = 45 + @as(usize, cursor - 39) },   // UNI MODE (header at 44)
        else    => .{ .col = 0, .row = 0 },
    };
}

/// Row index of `synth_cursor` within drawSynthEditor's output (0-based).
/// Must stay in sync with the layout in tui.drawSynthEditor.
pub fn paramRow(cursor: u8) usize {
    return switch (cursor) {
        0...5  => 2 + @as(usize, cursor),          // OSC A section (header at row 1)
        6...13 => 9 + @as(usize, cursor - 6),      // OSC B (header at row 8)
        14...15 => 18 + @as(usize, cursor - 14),   // MOD (header at 17)
        16...19 => 21 + @as(usize, cursor - 16),   // ENV (header at 20)
        20...23 => 26 + @as(usize, cursor - 20),   // FILTER (header at 25)
        24...27 => 31 + @as(usize, cursor - 24),   // FENV (header at 30)
        28...31 => 36 + @as(usize, cursor - 28),   // LFO (header at 35)
        32...33 => 41 + @as(usize, cursor - 32),   // VOICE (header at 40)
        34...35 => 44 + @as(usize, cursor - 34),   // SUB (header at 43)
        36...37 => 47 + @as(usize, cursor - 36),   // NOISE (header at 46)
        38      => 50,                              // OUT (header at 49)
        39...40 => 52 + @as(usize, cursor - 39),   // UNI MODE (header at 51)
        else    => 0,
    };
}
// zig fmt: on

pub fn updateScroll(app: *App) void {
    // Will be re-clamped against the real max_rows at draw time (views/
    // synth.zig's drawSynthEditor); this is just a same-ballpark estimate
    // so the scroll is already reasonable before that first real draw.
    // Was 20 (tuned against the old rows-|5 body budget, pre-hr()-removal);
    // bumped by the same +2 the real budget gained.
    const max_rows: usize = 22;
    const row = paramRow(app.synth_cursor);
    if (row < app.synth_scroll) app.synth_scroll = row;
    if (row >= app.synth_scroll + max_rows) app.synth_scroll = row - max_rows + 1;
}

// zig fmt: off
/// Nudge the selected synth-editor parameter. The change is routed over the
/// engine command queue and applied on the audio thread (PolySynth.adjustParam)
/// so it never races the block reader — the editor view reflects it on the
/// next frame. See engine.Command.set_track_param. Also notes the nudge for
/// undo (history.noteParamNudge), coalescing a run of h/l presses on the
/// same param into one undo step.
fn adjustParam(app: *App, steps: i32) void {
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => return,
    }
    app.dirty = true;
    history.noteParamNudge(app, app.synth_track, app.synth_cursor, steps);
    _ = app.session.engine.send(.{ .set_track_param = .{
        .track = app.synth_track,
        .id    = app.synth_cursor,
        .steps = steps,
    } });
}
// zig fmt: on

/// The param index whose row (in the *scrolled* on-screen layout) is `row`,
/// or null for the title row / a row that doesn't land on any param (a
/// section-header line). Scans `paramRow`/`paramColRow` — cheap (39 params)
/// and it's already the exact row math the renderer uses, so no new layout
/// logic. In wide mode `x` only picks a column within the OSC A/B top block
/// (rows 1-9); everything below that is a single full-width column.
fn paramAtRow(app: *App, row: usize, x: usize, cols: u16) ?u8 {
    if (row == 0) return null; // title
    const full_row = app.synth_scroll + row;
    var i: u8 = 0;
    if (twoCol(cols)) {
        if (full_row <= top_h) {
            const col: u1 = if (x < colWidth(cols)) 0 else 1;
            while (i < style.synth_param_count) : (i += 1) {
                const cr = paramColRow(i);
                if (cr.col == col and cr.row == full_row) return i;
            }
            return null;
        }
        while (i < style.synth_param_count) : (i += 1) {
            if (paramColRow(i).row == full_row) return i;
        }
        return null;
    }
    while (i < style.synth_param_count) : (i += 1) {
        if (paramRow(i) == full_row) return i;
    }
    return null;
}

/// Click a param row to select it. Scroll over a param row nudges it via
/// the existing `adjustParam` (same step `h`/`l` use); **ctrl**+scroll is
/// the coarse step (matches `H`/`L`).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16) void {
    switch (ev.kind) {
        .press => {
            const p = paramAtRow(app, row, ev.x, cols) orelse return;
            history.flushParamNudge(app);
            app.synth_cursor = p;
            updateScroll(app);
        },
        .scroll_up, .scroll_down => {
            const p = paramAtRow(app, row, ev.x, cols) orelse return;
            app.synth_cursor = p;
            updateScroll(app);
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            adjustParam(app, dir * (if (ev.ctrl) @as(i32, 10) else 1));
        },
        else => {},
    }
}
