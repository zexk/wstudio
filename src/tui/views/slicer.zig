//! Slicer-grid view + its status bar: a chop-context waveform pane (every
//! slice boundary marked, cursor slice highlighted, a ruler numbering the
//! slices) stacked over the step grid. The input half lives in
//! editors/slicer.zig.

const std = @import("std");
const ws = @import("wstudio");
const Slicer = ws.dsp.Slicer;
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../icons.zig");

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

/// Left gutter before the step columns start (matches views/drum.zig's own
/// gutter/cell-width shape and editors/slicer.zig's `stepAt` column math).
pub const gutter: usize = 10;
const cell_width: usize = 3;

/// Waveform pane: 2-column indent (mirrored by `waveNorm`), width cap
/// shared with the sampler editor's pane, height fed by whatever the row
/// budget leaves over the fixed grid rows.
const wave_indent: usize = 2;
pub const wave_max_w: usize = 240;
const wave_max_rows: usize = 10;
const wave_min_rows: usize = 3;

/// Row layout of the slicer grid, shared between the draw path and
/// editors/slicer.zig's mouse hit-testing: title(1) + waveform pane +
/// ruler(1, only with the pane) + step header(1) + a fixed 8-row bank
/// window. The pane soaks up leftover height and disappears entirely on
/// short terminals (below `wave_min_rows` there's no room to read it).
pub const Layout = struct {
    wave_rows: usize,
    bank_rows: usize,

    pub fn rulerRows(self: Layout) usize {
        return @intFromBool(self.wave_rows > 0);
    }
    /// View-content row of the step-number header.
    pub fn headerRow(self: Layout) usize {
        return 1 + self.wave_rows + self.rulerRows();
    }
};

pub fn layout(slice_count: u8, rows: usize) Layout {
    const budget = rows -| 4;
    const bank_rows: usize = if (slice_count == 0) 0 else 8;
    const fixed = 1 + 1 + bank_rows; // title + header + bank window
    const spare = budget -| (fixed + 1); // +1: the ruler rides with the pane
    const wave: usize = @min(wave_max_rows, spare);
    return .{ .wave_rows = if (wave >= wave_min_rows) wave else 0, .bank_rows = bank_rows };
}

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

/// Normalized 0..1 clip position at column `x` within the waveform pane,
/// or null outside it - editors/slicer.zig's mouse slice-select uses this.
pub fn waveNorm(x: usize, cols: u16) ?f32 {
    if (x < wave_indent) return null;
    const width = @min(@as(usize, cols) -| wave_indent, wave_max_w);
    if (width == 0) return null;
    const rel = x - wave_indent;
    if (rel >= width) return null;
    return std.math.clamp(@as(f32, @floatFromInt(rel)) / @as(f32, @floatFromInt(width)), 0.0, 1.0);
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
    var peak: f32 = 1e-6;
    for (0..width) |x| {
        var a: f32 = 0;
        const lo = x * samples.len / width;
        const hi = @max(lo + 1, (x + 1) * samples.len / width);
        var j = lo;
        while (j < hi and j < samples.len) : (j += 1) a = @max(a, @abs(samples[j]));
        amp[x] = a;
        peak = @max(peak, a);
    }
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
        try w.writeAll(dim ++ "  (:load-slice [file.wav] loads your own clip)" ++ rst);
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

            if (is_cursor) {
                try w.writeAll(sel);
            } else if (is_play) {
                try w.writeAll(grn ++ bold);
            } else if (in_sel) {
                try w.writeAll(if (active) yel ++ bold else yel);
            } else if (active) {
                try w.writeAll(acc);
            } else {
                try w.writeAll(dim);
            }
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

pub fn drawSlicerStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    const sl = app.slicerInst();
    const sIdx = app.slicer_cursor[0];
    const s = app.slicer_cursor[1];
    try style.writeModeBadge(w, app.modal.mode);
    try style.writeViewBadge(right, "SLICER", app.modal.mode);
    try w.writeAll(dim ++ "  pat " ++ rst);
    try w.print("{c}", .{Slicer.variantLetter(sl.variant)});
    try w.writeAll(dim ++ "  slice " ++ rst);
    try w.print("{d}/{d}", .{ sIdx + 1, sl.slice_count });
    try w.writeAll(dim ++ "  step " ++ rst);
    try w.print("{d}/{d}", .{ s + 1, sl.step_count });
    if (sl.stepActive(sIdx, s)) {
        try w.writeAll(dim ++ "  vel " ++ rst);
        try w.print("{d}", .{sl.stepVel(sIdx, s)});
    }
    try w.writeAll(dim ++ "  swing " ++ rst);
    try w.print("{d:.0}%", .{sl.swing.load(.monotonic)});
    if (sIdx < sl.slice_count) {
        const pad = &sl.slices[sIdx];
        try w.writeAll(dim ++ "  " ++ rst);
        try w.print("{d:.0}-{d:.0}%", .{ pad.start_norm * 100.0, pad.end_norm * 100.0 });
        if (@abs(pad.pitch_semitones) > 0.01) {
            try w.writeAll(dim ++ "  pitch " ++ rst);
            try w.print("{s}{d:.0}", .{ if (pad.pitch_semitones >= 0) "+" else "", pad.pitch_semitones });
        }
        if (pad.reverse) try w.writeAll(dim ++ "  " ++ blu ++ "rev" ++ rst);
    }
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}
