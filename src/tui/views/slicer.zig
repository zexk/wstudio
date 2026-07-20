//! Slicer-grid view + its status bar: a chop-context waveform pane (every
//! slice boundary marked, cursor slice highlighted, a ruler numbering the
//! slices) stacked over the step grid. The input half lives in
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
const bcyn = style.bcyn;
const endLine = style.endLine;

// Grid/waveform geometry lives with the editor (ui/editors/slicer.zig)
// since its mouse hit-testing shares the exact same layout math.
const waveform = @import("../../ui/waveform.zig");
const slicer_ed = @import("../../ui/editors/slicer.zig");
const gutter = slicer_ed.gutter;
const cell_width: usize = 3;
const wave_indent = slicer_ed.wave_indent;
const wave_max_w = slicer_ed.wave_max_w;
const Layout = slicer_ed.Layout;
const layout = slicer_ed.layout;

/// How many steps fit in `cols` - same periodic-separator math as
/// views/drum.zig's visibleSteps.
fn visibleSteps(cols: usize) u32 {
    if (cols <= gutter) return 1;
    const avail = cols - gutter;
    var n: u32 = 0;
    while (n < Slicer.max_steps) {
        const next = n + 1;
        const sep = (next + 3) / 4;
        if (next * cell_width + sep > avail) break;
        n = next;
    }
    return @max(1, n);
}

/// Ruler label for slice `i` (0-based): 1-9, then a-z, then '+' past 35 -
/// one column per label, MPC-bank style.
fn sliceLabel(i: usize) u8 {
    if (i < 9) return @intCast('1' + i);
    if (i < 35) return @intCast('a' + (i - 9));
    return '+';
}

/// Column of a normalized position within the pane's width.
fn normCol(norm: f32, width: usize) usize {
    const col: usize = @intFromFloat(std.math.clamp(norm, 0.0, 1.0) * @as(f32, @floatFromInt(width)));
    return @min(col, width -| 1);
}

/// Render the waveform pane + ruler: per-column peak fill, every slice
/// start (and the last slice's end) drawn as a bright marker, the cursor
/// slice's own region and markers highlighted. With no slices yet the
/// whole clip draws in accent - the "look at what you loaded, then chop"
/// state.
fn drawWavePane(
    app: anytype,
    w: *std.Io.Writer,
    sl: *const Slicer,
    cols: usize,
    wave_rows: usize,
) !void {
    const width = @min(cols -| wave_indent, wave_max_w);
    const samples = sl.samples;
    const cur = app.slicer_cursor[0];

    // Per-column peak amplitude over the column's sample bucket, normalized
    // to the loudest column (same shape as views/sampler.zig's pane).
    var amp: [wave_max_w]f32 = undefined;
    waveform.peakBuckets(samples, amp[0..width]);
    var peak: f32 = 1e-6;
    for (amp[0..width]) |a| peak = @max(peak, a);
    const inv_peak = 1.0 / peak;

    // Marker + region maps. 0 = no marker; otherwise the slice label (the
    // last slice's end shares the final column with no label of its own).
    var marker: [wave_max_w]u8 = [_]u8{0} ** wave_max_w;
    var marker_cur: [wave_max_w]bool = [_]bool{false} ** wave_max_w;
    var in_cur: [wave_max_w]bool = [_]bool{false} ** wave_max_w;
    const count = sl.slice_count;
    for (0..count) |i| {
        const col = normCol(sl.slices[i].start_norm, width);
        if (marker[col] == 0) marker[col] = sliceLabel(i);
        if (i == cur) marker_cur[col] = true;
    }
    if (count > 0) {
        const last_end = normCol(sl.slices[count - 1].end_norm, width);
        if (marker[last_end] == 0) marker[last_end] = 255; // unlabeled end marker
        if (cur + 1 == count) marker_cur[last_end] = true;
        const p = &sl.slices[cur];
        const s_col = normCol(p.start_norm, width);
        const e_col = normCol(p.end_norm, width);
        for (s_col..@max(s_col + 1, e_col)) |x| in_cur[x] = true;
        marker_cur[e_col] = true;
    }

    const center = @as(f32, @floatFromInt(wave_rows)) / 2.0;
    for (0..wave_rows) |row| {
        try w.writeAll("  ");
        const d_from_center = @abs(@as(f32, @floatFromInt(row)) + 0.5 - center);
        for (0..width) |x| {
            const radius = amp[x] * inv_peak * center;
            const filled = d_from_center <= radius;
            if (marker[x] != 0) {
                try w.writeAll(if (marker_cur[x]) yel ++ bold else bcyn);
                try w.writeAll("\u{2503}" ++ rst); // ┃
            } else if (filled) {
                try w.writeAll(if (count == 0 or in_cur[x]) acc else dim);
                try w.writeAll("\u{2588}" ++ rst); // █
            } else if (row == @as(usize, @intFromFloat(center))) {
                try w.writeAll(dim ++ "\u{2500}" ++ rst); // ─ zero axis
            } else {
                try w.writeByte(' ');
            }
        }
        try endLine(w);
    }

    // Ruler: each slice's number under its start marker.
    try w.writeAll("  ");
    for (0..width) |x| {
        if (marker[x] != 0 and marker[x] != 255) {
            try w.writeAll(if (marker_cur[x]) yel ++ bold else dim);
            try w.writeByte(marker[x]);
            try w.writeAll(rst);
        } else {
            try w.writeByte(' ');
        }
    }
    try endLine(w);
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
    const cur_slice = app.slicer_cursor[0];
    const cur_step = app.slicer_cursor[1];
    const step_count_u32: u32 = sl.step_count;
    const track_name = app.session.project.tracks.items[app.slicer_track].name;

    const visible = visibleSteps(cols);
    const cur_step_u32: u32 = cur_step;
    if (cur_step_u32 < app.slicer_step_scroll) app.slicer_step_scroll = cur_step_u32;
    if (cur_step_u32 >= app.slicer_step_scroll + visible) app.slicer_step_scroll = cur_step_u32 - visible + 1;
    const scroll = app.slicer_step_scroll;

    // MPC-style slice banking, same shape the drum grid uses for its pads.
    const slices_per_bank = 8;
    const slice_count = sl.slice_count;
    const bank_count = if (slice_count == 0) 1 else (slice_count + slices_per_bank - 1) / slices_per_bank;
    const bank = cur_slice / slices_per_bank;
    const bank_start = @as(usize, bank) * slices_per_bank;
    const bank_end = @min(bank_start + slices_per_bank, slice_count);

    // Visual-mode selection: a step range spanning every slice row.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.slicer_visual_anchor orelse cur_step;
    const sel_lo: u32 = @min(sel_anchor, cur_step);
    const sel_hi: u32 = @max(sel_anchor, cur_step);

    const lay = layout(slice_count, rows);
    var written: usize = 0;

    try w.writeAll(bold ++ " " ++ icons.slicer ++ " SLICER" ++ rst);
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

    if (lay.wave_rows > 0) {
        try drawWavePane(app, w, sl, cols, lay.wave_rows);
        written += lay.wave_rows + 1; // + ruler
    }

    if (slice_count == 0) {
        try w.writeAll(dim ++ "  no slices yet - :chop finds the transients, :slice <n> equal-divides" ++ rst);
        try endLine(w);
        try w.writeAll(dim ++ "  (:load [file.wav] loads your own clip)" ++ rst);
        try endLine(w);
        written += 2;
        for (written..@max(written, rows -| 4)) |_| try endLine(w);
        return;
    }

    // Step header - only the visible scroll window is shown.
    try w.writeAll(dim ++ "          ");
    var col: u32 = 0;
    while (col < visible and scroll + col < step_count_u32) : (col += 1) {
        const s = scroll + col;
        if (s % 4 == 0) try w.writeAll("│");
        try w.print("{d:>2} ", .{s + 1});
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
        try w.print(" #{d: <3}    ", .{sIdx + 1});
        try w.writeAll(rst);
        col = 0;
        while (col < visible and scroll + col < step_count_u32) : (col += 1) {
            const s = scroll + col;
            if (s % 4 == 0) try w.writeAll(dim ++ "│" ++ rst);
            const active = sl.stepActive(@intCast(sIdx), @intCast(s));
            const is_cursor = (sIdx == cur_slice and s == cur_step_u32);
            const is_play = is_playing and (s == playing_step);
            const in_sel = visual_active and s >= sel_lo and s <= sel_hi;
            try w.writeAll(style.stepCellSgr(active, is_cursor, is_play, in_sel));
            // Glyph tracks the step's velocity - same five bands as the
            // drum grid.
            try w.writeAll(if (!active) "[ ]" else switch (sl.stepVel(@intCast(sIdx), @intCast(s))) {
                102...127 => "[X]",
                76...101 => "[x]",
                51...75 => "[o]",
                26...50 => "[-]",
                else => "[.]",
            });
            try w.writeAll(rst);
        }
        try endLine(w);
        written += 1;
    }
    // Pad a partial last bank so the pane height never jumps between banks.
    for ((bank_end - bank_start)..lay.bank_rows) |_| {
        try endLine(w);
        written += 1;
    }

    for (written..@max(written, rows -| 4)) |_| try endLine(w);
}
