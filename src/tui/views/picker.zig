//! Instrument-picker view.

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

/// Names + one-line descriptions for the instrument picker. Order must match
/// `app.picker_kinds`.
const picker_menu = [_]struct { name: []const u8, desc: []const u8 }{
    .{ .name = "Synth",        .desc = "subtractive/FM polysynth — piano-roll sequenceable" },
    .{ .name = "Sampler",      .desc = "one clip played chromatically — :load-sample to swap" },
    .{ .name = "Drum Machine", .desc = "8-pad step sequencer with per-pad sampler" },
};

pub fn drawInstrumentPicker(app: anytype, w: *std.Io.Writer, rows: usize) !void {
    const track_name = if (app.cursor < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.cursor].name
    else
        "?";

    try w.writeAll(bold ++ " INSERT INSTRUMENT" ++ rst);
    try w.writeAll(acc);
    try w.print("  \"{s}\"", .{track_name});
    try w.writeAll(rst);
    try endLine(w);
    try endLine(w);

    for (picker_menu, 0..) |item, i| {
        const is_sel = (i == app.picker_cursor);
        if (is_sel) try w.writeAll(sel);
        try w.writeAll(if (is_sel) "  > " else "    ");
        try w.print("{s: <14}", .{item.name});
        if (!is_sel) try w.writeAll(dim);
        try w.print(" {s}", .{item.desc});
        try w.writeAll(rst);
        try endLine(w);
    }

    const used = 2 + picker_menu.len;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

