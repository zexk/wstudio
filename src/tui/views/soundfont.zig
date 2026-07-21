//! SoundFont editor view: GAIN/PAN/TRANSPOSE bars + the current PRESET, and
//! its status bar. Loading a font and jumping to a preset are `:load`/
//! `:sf-preset` (see ui/commands.zig), not drawn controls here.

const std = @import("std");
const ws = @import("wstudio");
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const bcyn = style.bcyn;
const endLine = style.endLine;
const synthSection = style.synthSection;
const barRow = style.barRow;
const rowHead = style.rowHead;
const rowVal = style.rowVal;

pub fn drawSoundfontEditor(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
) !void {
    _ = snap;
    _ = cols;
    const c = app.soundfont_param;
    const track_idx = app.soundfont_track;
    const track_name = if (track_idx < app.session.project.tracks.items.len)
        app.session.project.tracks.items[track_idx].name
    else
        "?";
    const sf = app.editingSoundfont();

    const body = rows -| 4;
    var written: usize = 0;

    // ── Title ────────────────────────────────────
    try w.writeAll(bcyn ++ bold ++ " \u{2593} " ++ rst);
    try w.writeAll(icons.soundfont);
    try w.writeAll(bcyn ++ bold ++ " SOUNDFONT " ++ rst ++ acc);
    try w.print("\"{s}\"", .{track_name});
    try w.writeAll(rst);
    try endLine(w);
    written += 1;

    if (sf == null or sf.?.presetCount() == 0) {
        try synthSection(w, "FONT", acc);
        written += 1;
        try w.writeAll(dim ++ "  No SoundFont loaded." ++ rst);
        try endLine(w);
        written += 1;
        try w.writeAll(acc ++ "  :load" ++ rst ++ dim ++ "  open the .sf2 browser" ++ rst);
        try endLine(w);
        written += 1;
        while (written < body) : (written += 1) try endLine(w);
        return;
    }
    const s = sf.?;

    var buf: [40]u8 = undefined;

    // zig fmt: off
    try synthSection(w, "OUT", acc);
    written += 1;
    try barRow(w, c == 0, false, acc, "gain", s.gain, 2.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{s.gain}));
    try barRow(w, c == 1, false, acc, "pan", s.pan + 1.0, 2.0,
        try std.fmt.bufPrint(&buf, "{s}", .{if (@abs(s.pan) < 0.005) "C" else if (s.pan < 0) "L" else "R"}));
    {
        const semi = s.transpose_semitones;
        try barRow(w, c == 2, false, acc, "transpose", semi + 24.0, 48.0,
            try std.fmt.bufPrint(&buf, "{s}{d:.0} st", .{ if (semi >= 0) "+" else "", semi }));
    }
    written += 3;
    // zig fmt: on

    try synthSection(w, "PROGRAM", style.grn);
    written += 1;
    try rowHead(w, c == 3, false, "preset");
    try w.writeByte(' ');
    var pbuf: [64]u8 = undefined;
    const preset_str = try std.fmt.bufPrint(&pbuf, "{s} ({d}/{d})", .{ s.presetName(), s.preset_index + 1, s.presetCount() });
    try rowVal(w, c == 3, false, preset_str);
    try endLine(w);
    written += 1;

    if (s.presetBankProgram()) |bp| {
        try w.writeAll(dim ++ "    bank " ++ rst);
        try w.print("{d}", .{bp.bank});
        try w.writeAll(dim ++ "  prog " ++ rst);
        try w.print("{d}", .{bp.program});
        if (s.presetKeyRange()) |kr| {
            var lo_buf: [5]u8 = undefined;
            var hi_buf: [5]u8 = undefined;
            try w.writeAll(dim ++ "  keys " ++ rst);
            try w.print("{s}-{s}", .{ ws.midi.noteName(@intCast(@min(kr.lo, 127)), &lo_buf), ws.midi.noteName(@intCast(@min(kr.hi, 127)), &hi_buf) });
            try w.writeAll(dim);
            try w.print("  ({d} region{s})", .{ kr.region_count, if (kr.region_count == 1) "" else "s" });
            try w.writeAll(rst);
        }
        try endLine(w);
        written += 1;
    }

    while (written < body) : (written += 1) try endLine(w);
}
