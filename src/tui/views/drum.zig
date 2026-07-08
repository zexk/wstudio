//! Drum-grid view + its status bar.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const Project = ws.Project;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const eq_mod = ws.dsp.eq;
const cmd_mod = @import("../cmd.zig");
const engine_mod = ws.engine;
const pattern_mod = ws.dsp.pattern;
const midi = ws.midi;
const style = @import("../style.zig");
const icons = @import("../icons.zig");

// Aliases so the moved render bodies reference the shared palette/primitives
// by their original bare names.
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
const bwht = style.bwht;
const endLine = style.endLine;
const hr = style.hr;
const meter = style.meter;
const spectrum_rows = style.spectrum_rows;
const spectrum_band_count = style.spectrum_band_count;
const synth_param_count = style.synth_param_count;
const synthBar = style.synthBar;
const synthSection = style.synthSection;
const rowHead = style.rowHead;
const rowVal = style.rowVal;
const barRow = style.barRow;
const enumRow = style.enumRow;

/// Left gutter before the step columns start (matches editors/drum.zig's
/// `stepAt` column math) and each step cell's width (a 1-char "│" every 4
/// steps, then a 3-char "[X]"-shaped cell).
pub const gutter: usize = 10;
const cell_width: usize = 3;

/// How many steps fit in `cols` at cell_width each, PLUS the periodic "│"
/// separator (one extra column every 4 steps) — a plain `(cols-gutter)/
/// cell_width` overcounts by ignoring that extra column and overflows the
/// terminal width once enough separators accumulate. Bounded to at most
/// max_steps iterations, cheap to just compute directly once per frame.
fn visibleSteps(cols: usize) u32 {
    if (cols <= gutter) return 1;
    const avail = cols - gutter;
    var n: u32 = 0;
    while (n < DrumMachine.max_steps) {
        const next = n + 1;
        const sep = (next + 3) / 4;
        if (next * cell_width + sep > avail) break;
        n = next;
    }
    return @max(1, n);
}

pub fn drawDrumGrid(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    const playing_step = app.drumMachine().currentStep();
    const is_playing = app.session.engine.uiSnapshot().playing;
    const cur_pad = app.drum_cursor[0];
    const cur_step = app.drum_cursor[1];

    const dm = app.drumMachine();
    const step_count = dm.step_count;
    const step_count_u32: u32 = step_count;
    const track_name = app.session.project.tracks.items[app.drum_track].name;

    // Horizontal step scroll, cursor-follow — same "clamped at draw"
    // convention as views/arrangement.zig's arr_scroll_bar. Needed once
    // step_count exceeds what fits at cell_width cols/step (max_steps = 64
    // won't fit most terminals at 3 chars/step).
    const visible = visibleSteps(cols);
    const cur_step_u32: u32 = cur_step;
    if (cur_step_u32 < app.drum_step_scroll) app.drum_step_scroll = cur_step_u32;
    if (cur_step_u32 >= app.drum_step_scroll + visible) app.drum_step_scroll = cur_step_u32 - visible + 1;
    const scroll = app.drum_step_scroll;

    // Visual-mode selection: a step range spanning every pad row.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.drum_visual_anchor orelse cur_step;
    const sel_lo: u32 = @min(sel_anchor, cur_step);
    const sel_hi: u32 = @max(sel_anchor, cur_step);
    const playing_step_u32: u32 = playing_step;
    // MPC-style pad banking: the grid windows to 8 rows at a time — the
    // bank containing the cursor, not a smooth scroll — so 64 pads never
    // blow out the terminal height. J/K (editors/drum.zig) jump a whole
    // bank; j/k crossing a bank boundary pages the window along with them.
    const pads_per_bank = 8;
    const bank_count = (DrumMachine.max_pads + pads_per_bank - 1) / pads_per_bank;
    const bank = cur_pad / pads_per_bank;
    const bank_start = bank * pads_per_bank;
    const bank_end = @min(bank_start + pads_per_bank, DrumMachine.max_pads);
    try w.writeAll(bold ++ " " ++ icons.drum ++ " DRUMS" ++ rst);
    try w.print(" \"{s}\"", .{track_name});
    try w.writeAll("  " ++ acc);
    try w.print("pat {c}", .{DrumMachine.variantLetter(dm.variant)});
    try w.writeAll(rst ++ dim);
    try w.print(" {d}/{d}", .{ dm.variant + 1, dm.variant_count });
    try w.writeAll(dim ++ "  bank " ++ rst);
    try w.print("{d}/{d}", .{ bank + 1, bank_count });
    try endLine(w);

    // step header — only the visible scroll window is shown
    try w.writeAll(dim ++ "          ");
    var col: u32 = 0;
    while (col < visible and scroll + col < step_count_u32) : (col += 1) {
        const s = scroll + col;
        if (s % 4 == 0) try w.writeAll("│");
        try w.print("{d:>2} ", .{s + 1});
    }
    try endLine(w);

    // One tint per choke group so paired pads (e.g. closed/open hihat) read
    // at a glance; ungrouped pads stay dim as before.
    const choke_colors = [_][]const u8{ yel, mag, blu, red };
    for (bank_start..bank_end) |p| {
        const name = dm.padName(@intCast(p));
        const group = dm.choke_group[p];
        try w.writeAll(if (group != 0) choke_colors[(group - 1) % choke_colors.len] else dim);
        // 8 = the rename cap (:pad-rename), so no legal name truncates —
        // at 4 the two stock toms both rendered as "tom-".
        try w.print(" {s: <8} ", .{name[0..@min(name.len, 8)]});
        try w.writeAll(rst);
        col = 0;
        while (col < visible and scroll + col < step_count_u32) : (col += 1) {
            const s = scroll + col;
            if (s % 4 == 0) {
                try w.writeAll(dim ++ "│" ++ rst);
            }
            const active = dm.stepActive(@intCast(p), @intCast(s));
            const is_cursor = (p == cur_pad and s == cur_step_u32);
            const is_play = is_playing and (s == playing_step_u32);
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

            // Glyph tracks the step's velocity level: full → quietest.
            try w.writeAll(if (!active) "[ ]" else switch (dm.stepVel(@intCast(p), @intCast(s))) {
                0 => "[X]",
                1 => "[x]",
                2 => "[o]",
                3 => "[.]",
            });
            try w.writeAll(rst);
        }
        try endLine(w);
    }

    const used = 4 + (bank_end - bank_start);
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawDrumStatus(app: anytype, w: *std.Io.Writer, cmds: []const cmd_mod.Def) !void {
    if (app.modal.mode == .command) {
        try cmd_mod.writePrompt(w, cmds, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor, 60);
        return;
    }
    if (app.modal.mode == .search) {
        try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor);
        return;
    }
    const p = app.drum_cursor[0];
    const s = app.drum_cursor[1];
    const dm = app.drumMachine();
    try style.writeStatusChips(w, app.modal.mode, "DRUM");
    try w.writeAll(dim ++ "  pat " ++ rst);
    try w.print("{c}", .{DrumMachine.variantLetter(dm.variant)});
    try w.writeAll(dim ++ "/" ++ rst);
    try w.print("{d}", .{dm.variant_count});
    try w.writeAll(dim ++ "  pad " ++ rst);
    try w.print("{d}/{d}", .{ p + 1, DrumMachine.max_pads });
    try w.writeAll(dim ++ "  step " ++ rst);
    try w.print("{d}/{d}", .{ s + 1, dm.step_count });
    try w.writeAll(dim ++ "  len " ++ rst);
    try w.print("{d}", .{dm.step_count});
    try w.writeAll(dim ++ "/" ++ rst);
    try w.print("{d}", .{DrumMachine.max_steps});
    try w.writeAll(dim ++ "  swing " ++ rst);
    try w.print("{d:.0}%", .{dm.swing.load(.monotonic)});
    if (dm.stepActive(p, s)) {
        try w.writeAll(dim ++ "  vel " ++ rst);
        try w.print("{d}%", .{DrumMachine.velPercent(dm.stepVel(p, s))});
    }
    if (dm.choke_group[p] != 0) {
        try w.writeAll(dim ++ "  choke " ++ rst);
        try w.print("{d}", .{dm.choke_group[p]});
    }
    try w.writeAll("  ");
    try w.writeAll(bold);
    try w.writeAll(dm.padName(p));
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

