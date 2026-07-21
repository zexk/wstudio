//! Drum-grid view + its status bar.

const std = @import("std");
const ws = @import("wstudio");
const DrumMachine = ws.dsp.DrumMachine;
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");
const drum_ed = @import("../../ui/editors/drum.zig");

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
const endLine = style.endLine;

// Grid geometry lives with the editor (ui/editors/drum.zig) since its mouse
// hit-testing shares the exact same column/bank math.
const gutter = drum_ed.gutter;
const pads_per_bank = drum_ed.pads_per_bank;
const banksShown = drum_ed.banksShown;
const bankWindowStart = drum_ed.bankWindowStart;

/// How many steps fit in `cols` at cell_width each, PLUS the periodic "│"
/// separator (one extra column every 4 steps) - a plain `(cols-gutter)/
/// cell_width` overcounts by ignoring that extra column and overflows the
/// terminal width once enough separators accumulate. The loop itself exits
/// as soon as the next step wouldn't fit, so it stays cheap regardless of
/// how long the pattern has grown (`max_steps` is just the safety bound).
fn visibleSteps(cols: usize, cell_width: usize) u32 {
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
    const cur_pad: u8 = @intCast(app.drum_cursor[0]);
    const cur_step = app.drum_cursor[1];

    const dm = app.drumMachine();
    const step_count = dm.step_count;
    const step_count_u32: u32 = step_count;
    const track_name = app.session.project.tracks.items[app.drum_track].name;
    const cell_width = app.drumCellWidth();

    // Horizontal step scroll, cursor-follow - same "clamped at draw"
    // convention as views/arrangement.zig's arr_scroll_bar. Needed once
    // step_count exceeds what fits at cell_width cols/step (max_steps = 64
    // won't fit most terminals at 3 chars/step).
    const visible = visibleSteps(cols, cell_width);
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
    // MPC-style pad banking: the grid windows to whole banks - the bank
    // group containing the cursor, not a smooth scroll - so 64 pads never
    // blow out the terminal height. Tall terminals stack several banks at
    // once (banksShown); J/K (editors/drum.zig) jump a whole bank; j/k
    // crossing the window's edge pages it along with them.
    const bank_count = (DrumMachine.max_pads + pads_per_bank - 1) / pads_per_bank;
    const bank = cur_pad / pads_per_bank;
    const bank_start = bankWindowStart(cur_pad, rows);
    const bank_end = @min(bank_start + banksShown(rows) * pads_per_bank, DrumMachine.max_pads);
    try w.writeAll(bold ++ " ");
    try w.writeAll(icons.iconOr(icons.drum ++ " ", ""));
    try w.writeAll("DRUMS" ++ rst);
    try w.print(" \"{s}\"", .{track_name});
    try w.writeAll("  " ++ acc);
    try w.print("pat {c}", .{DrumMachine.variantLetter(dm.variant)});
    try w.writeAll(rst ++ dim);
    try w.print(" {d}/{d}", .{ dm.variant + 1, dm.variant_count });
    try w.writeAll(dim ++ "  bank " ++ rst);
    if (bank_end - bank_start > pads_per_bank) {
        try w.print("{d}-{d}/{d}", .{ bank_start / pads_per_bank + 1, (bank_end - 1) / pads_per_bank + 1, bank_count });
    } else {
        try w.print("{d}/{d}", .{ bank + 1, bank_count });
    }
    try endLine(w);

    // step header - only the visible scroll window is shown
    try w.writeAll(dim ++ "          ");
    var col: u32 = 0;
    while (col < visible and scroll + col < step_count_u32) : (col += 1) {
        const s = scroll + col;
        if (s % 4 == 0) try w.writeAll("│");
        if (cell_width == 1) {
            try w.writeAll(if (s % 4 == 0) "·" else " ");
        } else {
            try w.print("{d:>2}", .{s + 1});
            try w.splatByteAll(' ', cell_width - 2);
        }
    }
    try endLine(w);

    // One tint per choke group so paired pads (e.g. closed/open hihat) read
    // at a glance; ungrouped pads stay dim as before.
    const choke_colors = [_][]const u8{ yel, mag, blu, red };
    var printed: usize = 0;
    for (bank_start..bank_end) |p| {
        // A dim rule between stacked banks. Mirrored by editors/drum.zig's
        // mouse pad mapping (pads_per_bank + 1 rows per stacked bank).
        if (p != bank_start and p % pads_per_bank == 0) {
            try writeBankRule(w, scroll, visible, step_count_u32, cell_width);
            printed += 1;
        }
        const name = dm.padName(@intCast(p));
        const group = dm.choke_group[p];
        try w.writeAll(if (group != 0) choke_colors[(group - 1) % choke_colors.len] else dim);
        // 8 = the rename cap (:rename), so no legal name truncates -
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
            try w.writeAll(style.stepCellSgr(active, is_cursor, is_play, in_sel));

            // Glyph tracks the step's velocity (0-127): full → quietest,
            // five bands now that velocity isn't a 2-bit level anymore.
            const glyph: u8 = if (!active) ' ' else switch (dm.stepVel(@intCast(p), @intCast(s))) {
                102...127 => 'X',
                76...101 => 'x',
                51...75 => 'o',
                26...50 => '-',
                else => '.',
            };
            if (cell_width == 1) {
                try w.writeByte(glyph);
            } else {
                try w.writeByte('[');
                try w.splatByteAll(' ', (cell_width - 3) / 2);
                try w.writeByte(glyph);
                try w.splatByteAll(' ', cell_width - 3 - (cell_width - 3) / 2);
                try w.writeByte(']');
            }
            try w.writeAll(rst);
        }
        try endLine(w);
        printed += 1;
    }

    const used = 4 + printed;
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

/// One dim horizontal rule spanning exactly the grid's width (gutter +
/// visible step cells + their periodic "│" columns) - the boundary row
/// between stacked banks.
fn writeBankRule(w: *std.Io.Writer, scroll: u32, visible: u32, step_count: u32, cell_width: usize) !void {
    try w.writeAll(dim);
    for (0..gutter) |_| try w.writeAll("\u{2500}");
    var col: u32 = 0;
    while (col < visible and scroll + col < step_count) : (col += 1) {
        if ((scroll + col) % 4 == 0) try w.writeAll("\u{2500}");
        for (0..cell_width) |_| try w.writeAll("\u{2500}");
    }
    try endLine(w);
}
