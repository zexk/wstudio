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

pub fn drawDrumGrid(app: anytype, w: *std.Io.Writer, rows: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    const playing_step = app.drumMachine().currentStep();
    const is_playing = app.session.engine.uiSnapshot().playing;
    const cur_pad = app.drum_cursor[0];
    const cur_step = app.drum_cursor[1];

    const dm = app.drumMachine();
    const step_count = dm.step_count;
    const track_name = app.session.project.tracks.items[app.drum_track].name;

    // Visual-mode selection: a step range spanning every pad row.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.drum_visual_anchor orelse cur_step;
    const sel_lo: u8 = @min(sel_anchor, cur_step);
    const sel_hi: u8 = @max(sel_anchor, cur_step);
    try w.writeAll(bold ++ " " ++ icons.drum ++ " DRUMS" ++ rst);
    try w.print(" \"{s}\"", .{track_name});
    try w.writeAll("  " ++ acc);
    try w.print("pat {c}", .{DrumMachine.variantLetter(dm.variant)});
    try w.writeAll(rst ++ dim);
    try w.print(" {d}/{d}", .{ dm.variant + 1, dm.variant_count });
    try endLine(w);

    // step header — only the active range (step_count) is shown
    try w.writeAll(dim ++ "      ");
    for (0..step_count) |s| {
        if (s % 4 == 0) try w.writeAll("│");
        try w.print("{d:>2} ", .{s + 1});
    }
    try endLine(w);

    for (0..DrumMachine.max_pads) |p| {
        const name = dm.padName(@intCast(p));
        try w.writeAll(dim);
        try w.print(" {s: <4} ", .{name[0..@min(name.len, 4)]});
        try w.writeAll(rst);
        for (0..step_count) |s| {
            if (s % 4 == 0) {
                try w.writeAll(dim ++ "│" ++ rst);
            }
            const active = dm.stepActive(@intCast(p), @intCast(s));
            const is_cursor = (p == cur_pad and s == cur_step);
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

    const used = 4 + DrumMachine.max_pads;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawDrumStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.modal.mode == .command) {
        try w.writeAll(dim ++ " :" ++ rst);
        try w.print("{s}_", .{app.modal.cmd_buf[0..app.modal.cmd_len]});
        return;
    }
    const p = app.drum_cursor[0];
    const s = app.drum_cursor[1];
    const dm = app.drumMachine();
    if (app.modal.mode == .visual) {
        try w.writeAll(yel ++ sel ++ " VISUAL " ++ rst);
    } else {
        try w.writeAll(acc ++ sel ++ " DRUM " ++ rst);
    }
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
    try w.writeAll("  ");
    try w.writeAll(bold);
    try w.writeAll(dm.padName(p));
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

