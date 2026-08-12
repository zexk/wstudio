//! Slicer-grid view + its status bar: the slice step grid, one row per chop.
//! The clip's waveform (boundaries, cursor region) is drawn by the slice
//! panel instead - views/sampler.zig, on 'e'. The input half lives in
//! editors/slicer.zig.

const std = @import("std");
const ws = @import("wstudio");
const Slicer = ws.dsp.Slicer;
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const red = style.red;
const sel = style.sel;
const blu = style.blu;
const mag = style.mag;
const endLine = style.endLine;

// Grid geometry lives with the editor (ui/editors/slicer.zig) since its
// mouse hit-testing shares the exact same layout math.
const slicer_ed = @import("../../ui/editors/slicer.zig");
const step_grid = @import("../../ui/editors/step_grid.zig");
const gutter = slicer_ed.gutter;
const cell_width: usize = 3;

/// How many steps fit in `cols` - same periodic-separator math as
/// views/drum.zig's visibleSteps.
fn visibleSteps(cols: usize, steps_per_beat: u32) u32 {
    if (cols <= gutter) return 1;
    const avail = cols - gutter;
    var n: u32 = 0;
    while (n < Slicer.max_steps) {
        const next = n + 1;
        const sep = (next + steps_per_beat - 1) / steps_per_beat;
        if (next * cell_width + sep > avail) break;
        n = next;
    }
    return @max(1, n);
}

pub fn drawSlicerGrid(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    const sl = app.slicerInst();
    const playing_step = sl.currentStep();
    const is_playing = app.session.engine.uiSnapshot().playing;
    // Heal-on-draw: a :chop/:slice/undo can shrink the slice count and the
    // step count out from under a stale cursor (same clamp-at-draw
    // convention the step scroll below uses).
    if (sl.slice_count > 0 and app.slicer_cursor[0] >= sl.slice_count) app.slicer_cursor[0] = sl.slice_count - 1;
    if (app.slicer_cursor[1] >= sl.step_count) app.slicer_cursor[1] = sl.step_count -| 1;
    const cur_slice: u8 = @intCast(app.slicer_cursor[0]);
    const cur_step = app.slicer_cursor[1];
    const step_count_u32: u32 = sl.step_count;
    const track_name = app.session.project.tracks.items[app.slicer_track].name;

    const spb: u32 = @max(sl.steps_per_beat, 1);
    const stride: u32 = app.slicer_grid.ticks();
    const bar_units = spb * @as(u32, @max(app.session.project.beats_per_bar, 1)) * 4;
    const meter_denominator: u32 = @max(app.session.project.meter_denominator, 1);
    const visible = visibleSteps(cols, @max(1, spb / stride));
    const cur_step_u32: u32 = cur_step;
    if (cur_step_u32 < app.slicer_step_scroll) app.slicer_step_scroll = cur_step_u32;
    if (cur_step_u32 >= app.slicer_step_scroll + visible * stride) app.slicer_step_scroll = cur_step_u32 - (visible - 1) * stride;
    const scroll = app.slicer_step_scroll;

    // MPC-style slice banking, same shape the drum grid uses for its pads.
    const slices_per_bank = step_grid.rows_per_bank;
    const slice_count = sl.slice_count;
    const bank_count = if (slice_count == 0) 1 else (slice_count + slices_per_bank - 1) / slices_per_bank;
    const bank = cur_slice / slices_per_bank;
    const bank_start = @as(usize, bank) * slices_per_bank;
    const bank_end = @min(bank_start + slices_per_bank, slice_count);

    // Visual-mode selection: a step range, spanning either the anchored
    // slice band (`v`, blockwise) or every slice row (`V`, linewise - a null
    // slice anchor). See editors/step_grid.zig's rowRange.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.slicer_visual_anchor orelse cur_step;
    const sel_lo: u32 = @min(sel_anchor, cur_step);
    const sel_hi: u32 = @max(sel_anchor, cur_step);
    const sel_rows = step_grid.rowRange(u8, app.slicer_visual_slice_anchor, cur_slice, Slicer.max_slices);

    const bank_rows = slicer_ed.bankRows(slice_count);
    var written: usize = 0;

    try w.writeAll(bold ++ " ");
    try w.writeAll(icons.iconOr(icons.slicer ++ " ", ""));
    try w.writeAll("SLICER" ++ rst);
    try w.print(" \"{s}\"", .{track_name});
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("\"{s}\"", .{sl.clipName()});
    try w.writeAll(dim ++ "  slices " ++ rst);
    try w.print("{d}", .{slice_count});
    try w.writeAll(dim ++ "  pat " ++ rst);
    try w.print("{c}", .{Slicer.variantLetter(sl.variant)});
    if (sl.variant_count > 1) {
        try w.writeAll(dim);
        try w.print(" {d}/{d}", .{ sl.variant + 1, sl.variant_count });
        try w.writeAll(rst);
    }
    if (bank_count > 1) {
        try w.writeAll(dim ++ "  bank " ++ rst);
        try w.print("{d}/{d}", .{ bank + 1, bank_count });
    }
    try endLine(w);
    written += 1;

    if (slice_count == 0) {
        try w.writeAll(dim ++ "  no slices yet - :chop finds the transients, :slice <n> equal-divides" ++ rst);
        try endLine(w);
        if (sl.samples.len == 0)
            try w.writeAll(acc ++ "  enter" ++ rst ++ dim ++ " / " ++ rst ++ acc ++ ":load" ++ rst ++ dim ++ "  open the clip browser" ++ rst)
        else
            try w.writeAll(dim ++ "  (:load [file.wav] loads your own clip)" ++ rst);
        try endLine(w);
        written += 2;
        for (written..@max(written, rows -| 4)) |_| try endLine(w);
        return;
    }

    // Bar ruler. Labels stay within their cell even for very long patterns.
    try w.writeAll(dim ++ "          ");
    var col: u32 = 0;
    while (col < visible and scroll + col * stride < step_count_u32) : (col += 1) {
        const s = scroll + col * stride;
        if (s % spb == 0) try w.writeAll("│");
        const position_units = s * meter_denominator;
        const on_bar = position_units % bar_units == 0;
        const bar = position_units / bar_units + 1;
        if (!on_bar) try w.writeAll("   ") else if (bar < 100) try w.print("{d:>2} ", .{bar}) else try w.writeAll(" + ");
    }
    try endLine(w);
    written += 1;

    // One tint per choke group so grouped slices read as a set - same
    // palette order as the drum grid's pad names.
    const choke_colors = [_][]const u8{ yel, mag, blu, red };
    for (bank_start..bank_end) |sIdx| {
        const group = sl.choke_group[sIdx];
        if (sIdx == cur_slice) {
            try w.writeAll(acc);
        } else if (group != 0) {
            try w.writeAll(choke_colors[(group - 1) % choke_colors.len]);
        } else {
            try w.writeAll(dim);
        }
        try w.print(" #{d: <3}     ", .{sIdx + 1});
        try w.writeAll(rst);
        const slice_len = sl.sliceSteps(@intCast(sIdx), sl.step_count);
        col = 0;
        while (col < visible and scroll + col * stride < step_count_u32) : (col += 1) {
            const s = scroll + col * stride;
            if (s % spb == 0) try w.writeAll(dim ++ "│" ++ rst);
            var note_step = s;
            var active = false;
            while (note_step < @min(s + stride, step_count_u32)) : (note_step += 1) {
                if (sl.stepActive(@intCast(sIdx), @intCast(note_step))) {
                    active = true;
                    break;
                }
            }
            const is_cursor = (sIdx == cur_slice and s == cur_step_u32);
            const is_play = is_playing and (s == playing_step);
            const in_sel = visual_active and s >= sel_lo and s <= sel_hi and sIdx >= sel_rows.lo and sIdx <= sel_rows.hi;
            // Past this slice's own loop length ($) the cells stay editable
            // but never fire, so they read as empty whatever they hold - the
            // only in-grid signal that the row wraps early (views/drum.zig).
            const out_of_loop = s >= slice_len;
            try w.writeAll(style.stepCellSgr(active and !out_of_loop, is_cursor, is_play and !out_of_loop, in_sel));
            // Glyph tracks the step's velocity, brackets the parameter locks -
            // same five bands and same bracket set as the drum grid
            // (editors/step_grid.zig).
            const glyph: u8 = if (!active) ' ' else step_grid.velocityBand(sl.stepVel(@intCast(sIdx), @intCast(note_step))).glyph();
            const brackets = step_grid.stepBrackets(sl, @intCast(sIdx), @intCast(note_step), active and !out_of_loop);
            try w.print("{c}{c}{c}", .{ brackets[0], glyph, brackets[1] });
            try w.writeAll(rst);
        }
        try endLine(w);
        written += 1;
    }
    // Pad a partial last bank so the pane height never jumps between banks.
    for ((bank_end - bank_start)..bank_rows) |_| {
        try endLine(w);
        written += 1;
    }

    for (written..@max(written, rows -| 4)) |_| try endLine(w);
}
