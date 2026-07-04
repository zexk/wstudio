//! Piano-roll view + its status bar.

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
const theory = ws.theory;

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

const note_names = [_][]const u8{
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
};

fn pitchLabel(pitch: u7, buf: *[5]u8) []const u8 {
    const octave: i32 = @divTrunc(@as(i32, pitch), 12) - 1;
    const name = note_names[pitch % 12];
    var len: usize = 0;
    @memcpy(buf[0..name.len], name);
    len += name.len;
    if (octave < 0) {
        buf[len] = '-';
        len += 1;
        buf[len] = '0' + @as(u8, @intCast(-octave));
        len += 1;
    } else {
        buf[len] = '0' + @as(u8, @intCast(octave));
        len += 1;
    }
    return buf[0..len];
}

fn isBlackKey(pitch: u7) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

pub fn drawPianoRoll(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;

    // Playhead step within the loop (maxInt when stopped — never matches a visible step).
    const play_step: u16 = if (snap.playing) blk: {
        const sr: f64 = @floatFromInt(app.session.project.sample_rate);
        const bpm: f64 = app.session.project.tempo_bpm;
        const raw_beats: f64 = @as(f64, @floatFromInt(snap.position_frames)) / (sr * 60.0 / bpm);
        break :blk @intFromFloat(@mod(raw_beats, pp.length_beats) * 4.0);
    } else std.math.maxInt(u16);

    const name = if (app.piano_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.piano_track].name
    else "?";

    try w.writeAll(bold ++ " " ++ icons.synth ++ " PIANO ROLL" ++ rst);
    try w.print(" \"{s}\"", .{name});
    // Clip-editing mode: show which arrangement clip the edits land in.
    if (app.piano_clip_link) |link| {
        try w.writeAll("  " ++ acc);
        try w.print("clip@bar {d}", .{link.start_bar + 1});
        try w.writeAll(rst);
    }
    if (app.piano_scale) |s| {
        try w.writeAll("  " ++ mag);
        try w.print("scale {s} {s}", .{ theory.pitchClassName(s.root), s.kind.label() });
        try w.writeAll(rst);
    }
    try endLine(w);

    // 3 internal header rows (title + col labels + loop marker) + vis_rows note rows
    // + outer header(2) + footer(3) must fit within `rows`, so max note rows = rows - 8.
    const vis_rows: usize = @min(rows -| 8, 24);
    const left: u16 = app.piano_scroll_step;

    // Show the full loop (+ end-marker column) up to what fits on screen.
    // Prefix = 6 chars (" C4  │"), each step cell = 3 chars.
    const loop_step: u16 = @intFromFloat(pp.length_beats * 4.0);
    const max_step_cols: usize = (cols -| 6) / 3;
    const vis_cols: usize = @min(@as(usize, loop_step) + 1, max_step_cols);

    // Column header: beat markers (prefix = 5-char label + 1-char │ = 6 visual cols)
    try w.writeAll(dim ++ "      " ++ rst);
    for (0..vis_cols) |col| {
        const step = left + @as(u16, @intCast(col));
        if (step % 4 == 0) {
            try w.writeAll(dim);
            try w.print("{d:<3}", .{step / 4 + 1});
            try w.writeAll(rst);
        } else {
            try w.writeAll(dim ++ "·  " ++ rst);
        }
    }
    try endLine(w);

    // Loop-end / playhead marker row (between header and notes)
    try w.writeAll(dim ++ "      " ++ rst);
    for (0..vis_cols) |col| {
        const step = left + @as(u16, @intCast(col));
        if (step == play_step) {
            try w.writeAll(grn ++ bold ++ "▾  " ++ rst);
        } else if (step == loop_step) {
            try w.writeAll(acc ++ "┤  " ++ rst);
        } else if (step % 4 == 0) {
            try w.writeAll(dim ++ "│  " ++ rst);
        } else {
            try w.writeAll("   ");
        }
    }
    try endLine(w);

    // Visual-mode selection: a step range spanning every pitch row.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.piano_visual_anchor orelse app.piano_cursor_step;
    const sel_lo: u16 = @min(sel_anchor, app.piano_cursor_step);
    const sel_hi: u16 = @max(sel_anchor, app.piano_cursor_step);

    // Note rows (top of view = high pitch)
    const top: u7 = app.piano_scroll_pitch;
    for (0..vis_rows) |row| {
        const pitch_i: i32 = @as(i32, top) - @as(i32, @intCast(row));
        if (pitch_i < 0 or pitch_i > 127) {
            try endLine(w);
            continue;
        }
        const pitch: u7 = @intCast(pitch_i);
        const black = isBlackKey(pitch);
        const is_cur_row = (pitch == app.piano_cursor_pitch);
        // Out-of-scale rows are dimmed like a black key so the eye can find
        // the current scale/mode at a glance; off (no `:scale` set) dims
        // nothing, matching the pre-scale-highlighting look.
        const in_scale = if (app.piano_scale) |s| s.contains(pitch) else true;
        const row_dim = black or !in_scale;

        var lbuf: [5]u8 = undefined;
        const label = pitchLabel(@intCast(pitch), &lbuf);
        if (row_dim) try w.writeAll(dim);
        try w.print(" {s: <4}", .{label});
        if (row_dim) try w.writeAll(rst);
        try w.writeAll(dim ++ "│" ++ rst);

        for (0..vis_cols) |col| {
            const step = left + @as(u16, @intCast(col));
            const beat_pos = @as(f64, @floatFromInt(step)) * 0.25;
            const is_cur = is_cur_row and (step == app.piano_cursor_step);
            const in_sel = visual_active and step >= sel_lo and step <= sel_hi;
            const starts = pp.noteStartsAt(pitch, beat_pos);
            const covers = pp.noteCovers(pitch, beat_pos);

            if (is_cur) {
                try w.writeAll(sel);
                if (starts) try w.writeAll("[  ")
                else if (covers) try w.writeAll("=  ")
                else try w.writeAll("·  ");
                try w.writeAll(rst);
            } else if (starts) {
                // Shade the note head by velocity: loud = bold, soft = dim.
                // Selected notes (visual mode) swap the accent for yellow.
                const vel = pp.velocityAt(pitch, beat_pos) orelse 0.85;
                const head = if (vel >= 0.8) bold else if (vel < 0.45) dim else "";
                const note_color = if (in_sel) yel else acc;
                try w.writeAll(note_color);
                try w.writeAll(head);
                try w.writeAll("[" ++ rst);
                try w.writeAll(note_color);
                try w.writeAll("= " ++ rst);
            } else if (covers) {
                try w.writeAll(if (in_sel) yel else acc);
                try w.writeAll("=  " ++ rst);
            } else if (step % 4 == 0) {
                try w.writeAll(if (in_sel) yel else dim);
                try w.writeAll("│  " ++ rst);
            } else if (in_sel) {
                try w.writeAll(yel ++ "·  " ++ rst);
            } else {
                if (row_dim) try w.writeAll(dim);
                try w.writeAll("·  ");
                if (row_dim) try w.writeAll(rst);
            }
        }
        try endLine(w);
    }

    // used includes the 2 outer rows (header + hr) so padding aligns with drum-grid convention
    const used = 5 + vis_rows;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawPianoRollStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;

    var lbuf: [5]u8 = undefined;
    const label = pitchLabel(@intCast(app.piano_cursor_pitch), &lbuf);
    const beat_pos = @as(f64, @floatFromInt(app.piano_cursor_step)) * 0.25;
    const bar = app.piano_cursor_step / 4 + 1;
    const sub = app.piano_cursor_step % 4 + 1;

    if (app.modal.mode == .visual) {
        try w.writeAll(yel ++ sel ++ " VISUAL " ++ rst);
    } else {
        try w.writeAll(acc ++ sel ++ " PIANO " ++ rst);
    }
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{s}", .{label});
    try w.writeAll(dim ++ "  bar " ++ rst);
    try w.print("{d}.{d}", .{ bar, sub });
    try w.writeAll(dim ++ "  len " ++ rst);
    try w.print("{d:.2}b", .{app.piano_note_len});
    try w.writeAll(dim ++ "  loop " ++ rst);
    try w.print("{d:.0}b", .{pp.length_beats});
    // Note count at cursor pitch
    var n_here: usize = 0;
    _ = beat_pos;
    for (pp.notes[0..pp.note_count]) |n| {
        if (n.pitch == app.piano_cursor_pitch) n_here += 1;
    }
    try w.writeAll(dim ++ "  notes " ++ rst);
    try w.print("{d}/{d}", .{ n_here, pp.note_count });
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

