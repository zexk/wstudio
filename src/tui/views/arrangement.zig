//! Arrangement (song timeline) view + its status bar.
//!
//! Track lanes (rows) × bars (columns). Each lane shows the clips placed on it;
//! `j/k` move between lanes (shared with the tracks view's `cursor`), `h/l`
//! move the bar cursor, and the window scrolls horizontally to keep the cursor
//! visible. In song mode the playhead bar is tinted while playing.

const std = @import("std");
const ws = @import("wstudio");
const engine_mod = ws.engine;
const Transport = ws.Transport;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");
const waveform = @import("../../ui/waveform.zig");
const types = ws.types;

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const sel = style.sel;
const blu = style.blu;
const mag = style.mag;
const bcyn = style.bcyn;
const endLine = style.endLine;

// The gutter width lives with the editor (ui/editors/arrangement.zig) since
// its mouse column math must agree with this draw path.
const arrangement_ed = @import("../../ui/editors/arrangement.zig");
const gutter = arrangement_ed.gutter;
const step_grid = @import("../../ui/editors/step_grid.zig");

/// Bars that fit in the timeline area for a terminal `cols` wide, at cell
/// width `cw` from `App.arrCellWidth()`.
pub fn visibleBars(cols: usize, cw: usize) usize {
    if (cols <= gutter + cw) return 1;
    return (cols - gutter) / cw;
}

/// One ruler cell's label in `color`, clamped to `width` columns and padded
/// back out to it. Every label here is user-supplied or unbounded (section
/// names, tempo/meter marks, 3-digit bars in a 3-wide cell), so the cell has
/// to do the clamping - byte slicing would split a codepoint, and a label
/// wider than the cell shifts every bar after it.
fn writeCell(w: *std.Io.Writer, color: []const u8, text: []const u8, width: usize) !void {
    try w.writeAll(color);
    try style.writePadded(w, text, width);
}

fn playheadBar(app: anytype, snap: engine_mod.UiSnapshot) ?u32 {
    if (!snap.playing or !app.session.song_mode) return null;
    var t: Transport = .{
        .sample_rate = app.session.project.sample_rate,
        .tempo_bpm = app.session.project.tempo_bpm,
        .position_frames = snap.position_frames,
    };
    const tick = t.positionBeats() * ws.time_grid.ticks_per_beat;
    if (!std.math.isFinite(tick) or tick >= @as(f64, @floatFromInt(std.math.maxInt(u32))))
        return std.math.maxInt(u32);
    return @intFromFloat(@max(tick, 0.0));
}

/// Where a loop edge falls relative to the ruler cell starting at `tick` and
/// spanning `cell_ticks`. The cell stride is the grid, not the bar, so the
/// edge tick rarely lands on a cell start exactly - hence the range test.
/// `end_tick` is exclusive, so its bracket rides the cell it opens.
pub fn loopEdge(tick: u32, cell_ticks: u32, start_tick: u32, end_tick: u32) ?enum { start, end } {
    const cell_end = tick +| cell_ticks;
    if (start_tick >= tick and start_tick < cell_end) return .start;
    if (end_tick >= tick and end_tick < cell_end) return .end;
    return null;
}

/// Text for a tempo or meter change landing in the ruler cell that starts at
/// `tick` (null = none). Linear scan, but both maps hold at most 64 points
/// (`time_map.max_tempo_points`) and only the visible cells ask.
fn mapPointLabel(p: *const ws.Project, tick: u32, cell_ticks: u32, buf: []u8) ?[]const u8 {
    const cell_end = tick +| cell_ticks;
    for (p.tempo_points.items) |point| {
        const at = ws.Project.tickAtBeat(point.beat);
        if (at >= tick and at < cell_end) return std.fmt.bufPrint(buf, "{d:.0}", .{point.bpm}) catch null;
    }
    for (p.meter_points.items) |point| {
        const at = ws.Project.tickAtBeat(point.beat);
        if (at >= tick and at < cell_end) return std.fmt.bufPrint(buf, "{d}/{d}", .{ point.numerator, point.denominator }) catch null;
    }
    return null;
}

/// One character per amplitude step, quietest first.
const wave_glyphs = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

/// The block glyph for the loudest sample under one timeline cell of an
/// audio clip: the arrangement's waveform, at one character per grid step.
/// Null when the cell is not audio, the source is gone, or the cell sits
/// past the end of the region's audio (a clip can outlast the sound it
/// holds - the engine simply stops, see `Engine.renderAudioLane`), and the
/// caller keeps drawing its plain clip body there.
///
/// Timeline frames drive the lookup, not a share of the clip's tick span,
/// so the picture agrees with playback for a file at a different sample
/// rate or a stretched region instead of stretching to fill the box.
fn audioCellGlyph(p: *const ws.Project, clip: *const ws.Clip, bar: u32, grid_ticks: u32) ?[]const u8 {
    const region = switch (clip.content) {
        .audio => |a| a,
        else => return null,
    };
    const source = p.audioSource(region.source_id) orelse return null;
    const channels = @max(source.channel_count, 1);
    const available = source.samples.len / channels;
    if (available <= region.source_start_frame) return null;
    const length = @min(region.source_length_frames, available - region.source_start_frame);
    if (length == 0) return null;

    const clip_frame = p.framesAtBeat(ws.time_grid.tickToBeat(clip.start_tick));
    const rate_ratio = @as(f64, @floatFromInt(@max(source.sample_rate, 1))) /
        @as(f64, @floatFromInt(@max(p.sample_rate, 1))) /
        @as(f64, @floatCast(@max(region.stretch_ratio, 0.001)));
    var offsets: [2]u64 = undefined;
    for (&offsets, [2]u32{ bar, bar +| grid_ticks }) |*out, tick| {
        const timeline = p.framesAtBeat(ws.time_grid.tickToBeat(tick)) -| clip_frame;
        const scaled = @as(f64, @floatFromInt(timeline)) * rate_ratio;
        out.* = if (scaled >= @as(f64, @floatFromInt(length))) length else @intFromFloat(@max(scaled, 0));
    }
    if (offsets[0] >= length) return null;
    const hi = @max(offsets[1], offsets[0] + 1);
    // Reversed playback mirrors what is heard, so mirror the picture too.
    const lo_f = if (region.reverse) length -| @min(hi, length) else offsets[0];
    const hi_f = if (region.reverse) length -| offsets[0] else @min(hi, length);
    const lo = (region.source_start_frame + lo_f) * channels;
    const end = @min((region.source_start_frame + hi_f) * channels, source.samples.len);
    if (end <= lo) return null;

    var peak: [1]f32 = undefined;
    waveform.peakBucketsSampled(source.samples[@intCast(lo)..@intCast(end)], &peak, 32);
    const scaled = peak[0] * types.dbToGain(std.math.clamp(region.gain_db, -60.0, 24.0));
    // Square root, not the raw peak: a linear map spends most of the eight
    // glyphs on the loud half and draws quiet material as a flat line.
    const level: usize = @intFromFloat(@min(
        @as(f32, @floatFromInt(wave_glyphs.len - 1)),
        @sqrt(std.math.clamp(scaled, 0, 1)) * @as(f32, @floatFromInt(wave_glyphs.len)),
    ));
    return wave_glyphs[level];
}

pub fn drawArrangement(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
) !void {
    const grid_ticks = app.arr_grid.ticks();
    const cw: usize = app.arrCellWidth();
    const visible = visibleBars(cols, cw);

    // Keep the bar cursor inside the visible window.
    const vis: u32 = @intCast(visible);
    if (app.arr_cursor_bar < app.arr_scroll_bar) app.arr_scroll_bar = app.arr_cursor_bar;
    if (app.arr_cursor_bar >= app.arr_scroll_bar +| vis) app.arr_scroll_bar = app.arr_cursor_bar - vis + 1;

    const scroll = app.arr_scroll_bar *| grid_ticks;
    const cur_bar = app.arr_cursor_bar *| grid_ticks;
    const playhead = playheadBar(app, snap);

    const mode_tag: []const u8 = if (app.session.song_mode) grn ++ "SONG" ++ rst else dim ++ "PATTERN" ++ rst;
    try w.writeAll(bold ++ " ");
    try w.writeAll(icons.iconOr(icons.arrangement ++ " ", ""));
    try w.writeAll("ARRANGEMENT" ++ rst ++ "  ");
    try w.writeAll(mode_tag);
    try w.print("  " ++ bcyn ++ "{s}" ++ rst, .{app.arr_grid.label()});
    try endLine(w);

    // Bar ruler. Bars inside an armed loop region wear the accent colour.
    const p = &app.session.project;
    const loop_on = p.loop_enabled and p.loop_end_bar > p.loop_start_bar;
    // Bar starts come from the meter map, not one fixed bar length - see
    // Project.barAtTick.
    const loop_start_tick = p.tickAtBar(p.loop_start_bar);
    const loop_end_tick = p.tickAtBar(p.loop_end_bar);
    for (0..gutter - 1) |_| try w.writeByte(' ');
    for (0..visible) |c| {
        const bar = scroll +| @as(u32, @intCast(c)) *| grid_ticks;
        const bar_pos = p.barAtTick(bar);
        const downbeat = bar_pos.start_tick == bar;
        const in_loop = loop_on and bar >= loop_start_tick and bar < loop_end_tick;
        const section_name: ?[]const u8 = for (p.sections.items) |section| {
            if (section.tick == bar) break section.name;
        } else null;
        // The loop's two edges wear brackets; the bars between keep the plain
        // tinted separator. A tempo/meter change crosses its separator.
        const edge = if (loop_on) loopEdge(bar, grid_ticks, loop_start_tick, loop_end_tick) else null;
        var map_buf: [8]u8 = undefined;
        const map_label = mapPointLabel(p, bar, grid_ticks, &map_buf);
        if (edge) |e| {
            try w.writeAll(yel ++ bold);
            try w.writeAll(if (e == .start) "[" else "]");
            try w.writeAll(rst);
        } else if (map_label != null) {
            try w.writeAll(mag ++ bold ++ "╪" ++ rst);
        } else try w.writeAll(if (in_loop) yel ++ "│" ++ rst else if (downbeat) blu ++ "│" ++ rst else dim ++ "│" ++ rst);
        if (cw == 2) {
            // Compact: no room for a bar number without corrupting column
            // alignment - the separator's colour already marks downbeat/loop.
            try w.writeAll(if (in_loop) yel ++ "·" ++ rst else " ");
        } else if (section_name) |name| {
            try writeCell(w, bold, name, cw - 1);
        } else if (downbeat) {
            // A change usually lands on a downbeat, where the bar number owns
            // the cell - recolour it rather than hide it. Off-bar changes get
            // the value spelled out below.
            var bar_buf: [8]u8 = undefined;
            const num = std.fmt.bufPrint(&bar_buf, "{d}", .{bar_pos.bar + 1}) catch "+";
            try writeCell(w, if (map_label != null) mag else if (in_loop) yel else dim, num, cw - 1);
        } else if (map_label) |label| {
            try writeCell(w, mag, label, cw - 1);
        } else if (in_loop) {
            try writeCell(w, yel, "···", cw - 1);
        } else {
            try w.splatByteAll(' ', cw - 1);
        }
    }
    try endLine(w);

    // Visual-mode selection: a bar range, spanning either the anchored
    // lane band (`v`, blockwise) or every lane (`V`, linewise - a null lane
    // anchor). See editors/step_grid.zig's rowRange.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = (app.arr_visual_anchor orelse app.arr_cursor_bar) *| grid_ticks;
    const sel_lo: u32 = @min(sel_anchor, cur_bar);
    const sel_hi: u32 = @max(sel_anchor, cur_bar);
    const sel_lanes = step_grid.rowRange(usize, app.arr_visual_lane_anchor, app.cursor, app.session.project.tracks.items.len);

    // Lanes: vertical scroll over tracks, same window-clamp technique the
    // horizontal bar scroll above uses (exact `rows` is known here, unlike
    // editors/piano.zig's ensureVisible which has to approximate). Budget:
    // title(1) + ruler(1) + footer(4) = 6 are always spoken for.
    const lane_count = app.session.project.tracks.items.len;
    const vis_lanes: usize = rows -| 6;
    if (app.cursor < lane_count) {
        if (app.cursor < app.arr_scroll_lane) app.arr_scroll_lane = app.cursor;
        if (vis_lanes > 0 and app.cursor >= app.arr_scroll_lane + vis_lanes) app.arr_scroll_lane = app.cursor - vis_lanes + 1;
    }
    app.arr_scroll_lane = if (lane_count > vis_lanes) @min(app.arr_scroll_lane, lane_count - vis_lanes) else 0;
    const lane_scroll = app.arr_scroll_lane;
    const last_lane = @min(lane_count, lane_scroll + vis_lanes);
    const any_soloed = for (app.session.project.tracks.items) |t| {
        if (t.soloed) break true;
    } else false;

    for (app.session.project.tracks.items[lane_scroll..last_lane], lane_scroll..) |track, li| {
        const lane = app.session.arrangement.lane(li);
        const is_sel_lane = li >= sel_lanes.lo and li <= sel_lanes.hi;
        // Per-track color (see tui/style.zig's track_palette, cycled with
        // `[`/`]` in the tracks view) - falls back to the generic accent
        // for clip cells below (unchanged look for uncolored tracks), and
        // to no color at all for the lane name (matches tracks.zig's own
        // name-coloring, which leaves an uncolored track plain).
        const track_color: ?[]const u8 = if (track.color > 0 and track.color <= style.track_palette.len)
            style.track_palette[track.color - 1]
        else
            null;

        // A lane the mix can't hear reads as one: the badge names why, and
        // its clips drop the track colour below.
        const silent = track.muted or (any_soloed and !track.soloed);
        if (is_sel_lane) try w.writeAll(sel);
        if (track.muted) try w.writeAll(yel) else if (track.soloed) try w.writeAll(grn);
        try w.writeByte(if (track.muted) 'M' else if (track.soloed) 'S' else ' ');
        if ((track.muted or track.soloed) and !is_sel_lane) try w.writeAll(rst);
        if (is_sel_lane) try w.writeAll(sel);
        if (!is_sel_lane) if (track_color) |c| try w.writeAll(c);
        try w.print("{d: >2} ", .{li + 1});
        try style.writePadded(w, track.name, 8);
        if (!is_sel_lane) if (track_color) |_| try w.writeAll(rst);
        if (is_sel_lane) try w.writeAll(rst);

        for (0..visible) |c| {
            const bar = scroll +| @as(u32, @intCast(c)) *| grid_ticks;
            const downbeat = p.barAtTick(bar).start_tick == bar;
            try w.writeAll(if (downbeat) blu ++ "│" ++ rst else dim ++ "│" ++ rst);

            const clip = if (lane) |l| l.clipAt(bar) else null;
            const covered = clip != null;
            const is_start = covered and clip.?.start_tick == bar;
            // `clipAt` reports the top layer only, so a stack of two looked
            // exactly like one clip. Shade the body where more than one covers
            // the cell (see arrangement.zig - only same-layer overlaps evict).
            var stacked = false;
            if (covered) {
                var hits: u8 = 0;
                for (lane.?.clips.items) |other| {
                    if (other.covers(bar)) hits +|= 1;
                    if (hits > 1) break;
                }
                stacked = hits > 1;
            }
            // An audio clip draws its own envelope instead of a solid bar,
            // so a lane of one-shots reads as the hits it holds. A stack of
            // overlapping clips keeps the shaded body - the picture would be
            // of the top layer only, which is exactly what the shading warns
            // the eye about.
            const wave: ?[]const u8 = if (covered and !stacked)
                audioCellGlyph(p, clip.?, bar, grid_ticks)
            else
                null;
            const body: []const u8 = wave orelse (if (stacked) "▓" else "█");
            const is_cursor = is_sel_lane and bar == cur_bar;
            const is_play = playhead == bar;
            const in_sel = visual_active and is_sel_lane and bar >= sel_lo and bar <= sel_hi;

            // Drum clips wear their variant letter on the start cell, audio
            // regions an 'A' - melodic clips stay plain, which is what the
            // whole lane looked like before either mark existed. An audio
            // clip drawing its envelope drops the badge: the picture already
            // says "audio", and the start cell is where the transient is,
            // which is the one column worth not covering up.
            const letter: ?u8 = if (is_start) switch (clip.?.content) {
                .drum => |d| ws.dsp.DrumMachine.variantLetter(d.variant),
                .audio => if (wave == null) @as(u8, 'A') else null,
                .melodic => null,
            } else null;

            if (is_cursor) {
                try w.writeAll(sel);
            } else if (is_play) {
                try w.writeAll(grn ++ bold);
            } else if (in_sel) {
                try w.writeAll(yel);
            } else if (covered) {
                try w.writeAll(if (silent) dim else track_color orelse acc);
            }
            // The separator owns the cell's first column, the clip body the
            // rest - one shape for every width, where a hard 3-column body
            // (plus a `cw > 4` tail) overflowed the row at cw == 3.
            const width = cw - 1;
            if (!covered) {
                const mark: []const u8 = if (in_sel) "·" else if (is_play and !is_cursor) "‖" else " ";
                if (width == 1) {
                    try w.writeAll(mark);
                } else {
                    try w.writeByte(' ');
                    try w.writeAll(mark);
                    try w.splatByteAll(' ', width - 2);
                }
            } else if (letter) |ch| {
                if (width > 1) try w.writeAll("▌");
                try w.writeByte(ch);
                for (0..width -| 2) |_| try w.writeAll(body);
            } else if (is_start) {
                try w.writeAll("▌");
                for (0..width -| 1) |_| try w.writeAll(body);
            } else {
                for (0..width) |_| try w.writeAll(body);
            }
            if (is_cursor or is_play or covered or in_sel) try w.writeAll(rst);
        }
        try endLine(w);
    }

    const used = 2 + (last_lane - lane_scroll);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

test "loop brackets land on the cells holding each edge" {
    // Bars 2-4 (ticks 3840..11520) on a 1/4-note grid: the edges fall inside
    // the cells that open at those ticks, not on any other beat.
    const cell: u32 = 960;
    try std.testing.expectEqual(.start, loopEdge(3840, cell, 3840, 11520).?);
    try std.testing.expectEqual(.end, loopEdge(11520, cell, 3840, 11520).?);
    try std.testing.expectEqual(@as(?@TypeOf(loopEdge(0, 1, 0, 1).?), null), loopEdge(4800, cell, 3840, 11520));
    // A grid coarser than the loop still marks both edges on their cells.
    try std.testing.expectEqual(.start, loopEdge(0, 7680, 3840, 11520).?);
    try std.testing.expectEqual(.end, loopEdge(7680, 7680, 3840, 11520).?);
}

test "playhead tick saturates for positions beyond the arrangement range" {
    const app = .{
        .session = .{
            .song_mode = true,
            .project = .{
                .sample_rate = @as(u32, 48_000),
                .tempo_bpm = @as(f64, 120.0),
            },
        },
    };
    const snap: engine_mod.UiSnapshot = .{
        .playing = true,
        .pre_rolling = false,
        .position_frames = std.math.maxInt(u64),
        .peak = .{ 0.0, 0.0 },
        .correlation = 1.0,
        .lufs_momentary = ws.dsp.LoudnessMeter.floor_lufs,
        .lufs_short_term = ws.dsp.LoudnessMeter.floor_lufs,
        .lufs_integrated = ws.dsp.LoudnessMeter.floor_lufs,
    };
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), playheadBar(app, snap));
}

test "an audio cell's glyph follows the envelope and stops at the end of the sound" {
    var project = ws.Project.init(std.testing.allocator);
    defer project.deinit();
    project.sample_rate = 48_000;
    project.tempo_bpm = 120.0;

    // One second of decay, so each quarter-note cell reads a quieter quarter
    // of it than the last.
    const frames = 48_000;
    const samples = try std.testing.allocator.alloc(f32, frames);
    defer std.testing.allocator.free(samples);
    for (samples, 0..) |*s, i| {
        s.* = 1.0 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frames));
    }
    const source_id = try project.addAudioSource("decay", 48_000, 1, samples);

    // Two seconds of clip over one second of audio: the back half has no
    // sound under it at all.
    const beat = ws.time_grid.ticks_per_beat;
    var clip = ws.Clip.initAudio(0, beat * 4, .{
        .source_id = source_id,
        .source_start_frame = 0,
        .source_length_frames = frames,
    });
    defer clip.deinit(std.testing.allocator);

    var previous: usize = wave_glyphs.len;
    for (0..2) |cell| {
        const glyph = audioCellGlyph(&project, &clip, @intCast(cell * beat), beat) orelse
            return error.ExpectedGlyph;
        const level = for (wave_glyphs, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, glyph)) break i;
        } else return error.UnknownGlyph;
        try std.testing.expect(level < previous);
        previous = level;
    }
    // Past the audio, but still inside the clip box.
    try std.testing.expectEqual(@as(?[]const u8, null), audioCellGlyph(&project, &clip, beat * 3, beat));

    // A melodic clip has no envelope to draw and keeps the plain body.
    var melodic = try ws.Clip.initMelodic(std.testing.allocator, 0, beat, &.{}, 1.0);
    defer melodic.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?[]const u8, null), audioCellGlyph(&project, &melodic, 0, beat));
}
