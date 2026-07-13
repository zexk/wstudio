//! Piano-roll view + its status bar.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const Project = ws.Project;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const eq_mod = ws.dsp.eq;
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

// Writes the trailing padding after a step's glyph. When `tick` is set the
// last padding column carries a decorative beat separator instead of a
// blank: the separator rides in the trailing pad of the step BEFORE a
// downbeat, marking the boundary between beats, and shares its column with
// the beat number the header row prints on that same boundary.
fn writeStepPad(w: *std.Io.Writer, pad: usize, tick: bool, tick_color: []const u8) !void {
    if (pad == 0) return;
    if (!tick) {
        try w.splatByteAll(' ', pad);
        return;
    }
    if (pad > 1) try w.splatByteAll(' ', pad - 1);
    try w.writeAll(tick_color);
    try w.writeAll("│");
    try w.writeAll(rst);
}

fn isBlackKey(pitch: u7) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

/// Whether some OTHER melodic track has a note starting or covering this
/// pitch/beat, for `:ghost`'s background overlay. Cheap enough to call per
/// cell: track counts and view sizes are both small in a TUI.
const GhostHit = enum { none, starts, covers };
fn ghostAt(app: anytype, pitch: u7, beat_pos: f64) GhostHit {
    for (0..app.session.racks.items.len) |i| {
        if (i == app.piano_track) continue;
        const pp = if (app.session.racks.items[i].pattern_player) |*p| p else continue;
        if (pp.noteStartsAt(pitch, beat_pos)) return .starts;
        if (pp.noteCovers(pitch, beat_pos)) return .covers;
    }
    return .none;
}

pub fn drawPianoRoll(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;

    // Steps per beat under the current grid (4 = straight 16ths, 6 = 16th
    // triplets, toggled by `T` — see App.pianoStepsPerBeat).
    const spb: u16 = app.pianoStepsPerBeat();
    const spbf: f64 = @floatFromInt(spb);

    // Playhead step within the loop (maxInt when stopped — never matches a visible step).
    const play_step: u16 = if (snap.playing) blk: {
        const sr: f64 = @floatFromInt(app.session.project.sample_rate);
        const bpm: f64 = app.session.project.tempo_bpm;
        const raw_beats: f64 = @as(f64, @floatFromInt(snap.position_frames)) / (sr * 60.0 / bpm);
        break :blk @intFromFloat(@mod(raw_beats, pp.length_beats) * spbf);
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
    } else if (app.session.song_mode) {
        // Unlinked + song mode: this is the scratch pattern buffer, not any
        // clip already placed in the arrangement — it stays silent in the
        // song until stamped (arrangement: enter). Flag it so editing here
        // doesn't get mistaken for editing what's actually playing.
        try w.writeAll("  " ++ red);
        try w.writeAll("scratch: not in the song until stamped (arrangement: enter)");
        try w.writeAll(rst);
    }
    if (app.piano_scale) |s| {
        try w.writeAll("  " ++ mag);
        try w.print("scale {s} {s}", .{ theory.pitchClassName(s.root), s.kind.label() });
        try w.writeAll(rst);
    }
    if (app.piano_grid == .triplet) {
        try w.writeAll("  " ++ yel ++ "triplet" ++ rst);
    }
    if (app.piano_zoom == .compact) {
        try w.writeAll("  " ++ bcyn ++ "zoom" ++ rst);
    }
    try endLine(w);

    // 3 internal header rows (title + col labels + loop marker) + vis_rows note
    // rows + the caller's header/transport/status (4 rows total) must fit
    // within `rows`, so max note rows = rows - 7.
    const vis_rows: usize = @min(rows -| 7, 24);
    const left: u16 = app.piano_scroll_step;

    // Show the full loop (+ end-marker column) up to what fits on screen.
    // Prefix = 6 chars (" C4  │"), each step cell is `cw` chars (App.pianoCellWidth,
    // toggled by `Z`: 3 normal, 1 compact).
    const cw: usize = app.pianoCellWidth();
    const loop_step: u16 = @intFromFloat(pp.length_beats * spbf);
    const max_step_cols: usize = (cols -| 6) / cw;
    const vis_cols: usize = @min(@as(usize, loop_step) + 1, max_step_cols);

    // Column header: beat numbers sit on the boundary column BEFORE their
    // beat (the same column the note grid's │ separator ticks occupy) while
    // every step keeps a plain dot, so the row reads "1 ·  ·  ·  · 2 ...".
    // The first visible beat's number lands on the last prefix column, atop
    // the note rows' │ prefix separator. Compact (cw==1) has no room for
    // multi-digit numbers without corrupting column alignment, so it falls
    // back to a plain beat tick.
    try w.writeAll(dim);
    if (cw > 1 and left % spb == 0) {
        try w.print("    {d:>2}", .{left / spb + 1});
    } else {
        try w.writeAll("      ");
    }
    try w.writeAll(rst);
    for (0..vis_cols) |col| {
        const step = left + @as(u16, @intCast(col));
        if (cw == 1) {
            if (step % spb == 0) try w.writeAll(dim ++ "|" ++ rst) else try w.writeAll(" ");
        } else if (col + 1 < vis_cols and (step + 1) % spb == 0) {
            try w.writeAll(dim);
            try w.print("·{d:>2}", .{(step + 1) / spb + 1});
            try w.writeAll(rst);
        } else {
            try w.writeAll(dim ++ "·  " ++ rst);
        }
    }
    try endLine(w);

    // Loop-end / playhead marker row (between header and notes). The plain
    // beat tick rides in the same trailing-padding column the note-grid
    // separator uses (writeStepPad above) so the two lines stay vertically
    // aligned; play/loop markers stay at the step's own leading column since
    // they mark an exact position, not a beat boundary.
    try w.writeAll(dim ++ "      " ++ rst);
    for (0..vis_cols) |col| {
        const step = left + @as(u16, @intCast(col));
        if (step == play_step) {
            try w.writeAll(grn ++ bold ++ "▾" ++ rst);
            if (cw > 1) try w.splatByteAll(' ', cw - 1);
        } else if (step == loop_step) {
            try w.writeAll(acc ++ "┤" ++ rst);
            if (cw > 1) try w.splatByteAll(' ', cw - 1);
        } else if (cw == 1) {
            if (step % spb == 0) try w.writeAll(dim ++ "│" ++ rst) else try w.writeAll(" ");
        } else {
            const next_downbeat = col + 1 < vis_cols and (step + 1) % spb == 0;
            try w.writeAll(" ");
            try writeStepPad(w, cw - 1, next_downbeat, dim);
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
            const beat_pos = @as(f64, @floatFromInt(step)) / spbf;
            const is_cur = is_cur_row and (step == app.piano_cursor_step);
            const in_sel = visual_active and step >= sel_lo and step <= sel_hi;
            const starts = pp.noteStartsAt(pitch, beat_pos);
            const covers = pp.noteCovers(pitch, beat_pos);
            const downbeat = step % spb == 0;

            // The beat separator is purely decorative: at cw>1 it rides in
            // the trailing padding of the step BEFORE a downbeat, marking
            // the boundary between beats in the same column as the header's
            // beat number; at cw==1 there is no padding to borrow, so the
            // fallback below colours the downbeat dot itself instead
            // (mirrors arrangement.zig's compact ruler).
            const next_downbeat = col + 1 < vis_cols and (step + 1) % spb == 0;
            const tick_color = if (in_sel) yel else dim;

            if (is_cur) {
                try w.writeAll(sel);
                if (starts) try w.writeAll("[")
                else if (covers) try w.writeAll("=")
                else try w.writeAll("·");
                try w.writeAll(rst);
                try writeStepPad(w, cw -| 1, next_downbeat, tick_color);
            } else if (starts) {
                // Shade the note head by velocity: loud = bold, soft = dim.
                // Selected notes (visual mode) swap the accent for yellow.
                // Compact (cw==1) has room for only the head glyph, dropping
                // the "=" tail segment normal width shows alongside it.
                const vel = pp.velocityAt(pitch, beat_pos) orelse 0.85;
                const head = if (vel >= 0.8) bold else if (vel < 0.45) dim else "";
                const note_color = if (in_sel) yel else acc;
                try w.writeAll(note_color);
                try w.writeAll(head);
                try w.writeAll("[" ++ rst);
                if (cw > 1) {
                    try w.writeAll(note_color);
                    try w.writeAll("=" ++ rst);
                    try writeStepPad(w, cw -| 2, next_downbeat, tick_color);
                }
            } else if (covers) {
                try w.writeAll(if (in_sel) yel else acc);
                try w.writeAll("=" ++ rst);
                try writeStepPad(w, cw -| 1, next_downbeat, tick_color);
            } else if (in_sel) {
                try w.writeAll(yel ++ "·" ++ rst);
                try writeStepPad(w, cw -| 1, next_downbeat, tick_color);
            } else {
                // cw==1 has no padding column to carry the beat tick, so the
                // downbeat dot itself borrows a distinct colour instead
                // (mirrors arrangement.zig's blu downbeat ruler marker).
                const ghost = if (app.piano_ghost) ghostAt(app, pitch, beat_pos) else .none;
                if (ghost != .none) {
                    try w.writeAll(dim);
                    try w.writeAll(if (ghost == .starts) "[" else "=");
                    try w.writeAll(rst);
                } else {
                    const dot_color = if (cw == 1 and downbeat) blu else if (row_dim) dim else "";
                    if (dot_color.len > 0) try w.writeAll(dot_color);
                    try w.writeAll("·");
                    if (dot_color.len > 0) try w.writeAll(rst);
                }
                try writeStepPad(w, cw -| 1, next_downbeat, tick_color);
            }
        }
        try endLine(w);
    }

    // used includes the 2 outer rows (header + hr) so padding aligns with drum-grid convention
    const used = 5 + vis_rows;
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

pub fn drawPianoRollStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else return;

    var lbuf: [5]u8 = undefined;
    const label = pitchLabel(@intCast(app.piano_cursor_pitch), &lbuf);
    const spb: u16 = app.pianoStepsPerBeat();
    const beat_pos = @as(f64, @floatFromInt(app.piano_cursor_step)) / @as(f64, @floatFromInt(spb));
    const bar = app.piano_cursor_step / spb + 1;
    const sub = app.piano_cursor_step % spb + 1;

    try style.writeModeBadge(w, app.modal.mode);
    if (app.piano_zoom == .compact) try right.writeAll(bcyn ++ "zoom" ++ rst ++ "  ");
    try style.writeViewBadge(right, "PIANO", app.modal.mode);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{s}", .{label});
    try w.writeAll(dim ++ "  bar " ++ rst);
    try w.print("{d}.{d}", .{ bar, sub });
    try w.writeAll(dim ++ "  len " ++ rst);
    try w.print("{d:.2}b", .{app.piano_note_len});
    try w.writeAll(dim ++ "  loop " ++ rst);
    try w.print("{d:.0}b", .{pp.length_beats});
    try w.writeAll(dim ++ "  grid " ++ rst);
    try w.writeAll(if (app.piano_grid == .triplet) "1/16T" else "1/16");
    // Swing only shown when it's off the straight default (50%) — a plain
    // pattern shouldn't pay status-line width for a param it isn't using.
    const swing_pct = pp.swing.load(.monotonic);
    if (swing_pct != 50.0) {
        try w.writeAll(dim ++ "  swing " ++ rst);
        try w.print("{d:.0}%", .{swing_pct});
    }
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

