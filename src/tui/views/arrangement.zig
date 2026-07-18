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

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const sel = style.sel;
const blu = style.blu;
const bcyn = style.bcyn;
const endLine = style.endLine;

// The gutter width lives with the editor (ui/editors/arrangement.zig) since
// its mouse column math must agree with this draw path.
const arrangement_ed = @import("../../ui/editors/arrangement.zig");
const gutter = arrangement_ed.gutter;

/// Bars that fit in the timeline area for a terminal `cols` wide, at cell
/// width `cw` from `App.arrCellWidth()`.
pub fn visibleBars(cols: usize, cw: usize) usize {
    if (cols <= gutter + cw) return 1;
    return (cols - gutter) / cw;
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

pub fn drawArrangement(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
) !void {
    const ticks_per_bar = ws.time_grid.barTicks(app.session.project.beats_per_bar);
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
    try w.writeAll(bold ++ " " ++ icons.arrangement ++ " ARRANGEMENT" ++ rst ++ "  ");
    try w.writeAll(mode_tag);
    try w.print("  " ++ bcyn ++ "{s}" ++ rst, .{app.arr_grid.label()});
    try endLine(w);

    // Bar ruler. Bars inside an armed loop region wear the accent colour.
    const p = &app.session.project;
    const loop_on = p.loop_enabled and p.loop_end_bar > p.loop_start_bar;
    for (0..gutter - 1) |_| try w.writeByte(' ');
    for (0..visible) |c| {
        const bar = scroll +| @as(u32, @intCast(c)) *| grid_ticks;
        const downbeat = bar % ticks_per_bar == 0;
        const in_loop = loop_on and
            bar >= p.loop_start_bar *| ticks_per_bar and
            bar < p.loop_end_bar *| ticks_per_bar;
        try w.writeAll(if (in_loop) yel ++ "│" ++ rst else if (downbeat) blu ++ "│" ++ rst else dim ++ "│" ++ rst);
        if (cw == 2) {
            // Compact: no room for a bar number without corrupting column
            // alignment - the separator's colour already marks downbeat/loop.
            try w.writeAll(if (in_loop) yel ++ "·" ++ rst else " ");
        } else if (downbeat) {
            try w.print("{s}{d: <3}{s}", .{ if (in_loop) yel else dim, bar / ticks_per_bar + 1, rst });
            try w.splatByteAll(' ', cw - 4);
        } else if (in_loop) {
            try w.writeAll(yel ++ "···" ++ rst);
            try w.splatByteAll(' ', cw - 4);
        } else {
            try w.splatByteAll(' ', cw - 1);
        }
    }
    try endLine(w);

    // Visual-mode selection: a bar range on the current lane only.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = (app.arr_visual_anchor orelse app.arr_cursor_bar) *| grid_ticks;
    const sel_lo: u32 = @min(sel_anchor, cur_bar);
    const sel_hi: u32 = @max(sel_anchor, cur_bar);

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

    for (app.session.project.tracks.items[lane_scroll..last_lane], lane_scroll..) |track, li| {
        const lane = app.session.arrangement.lane(li);
        const is_sel_lane = li == app.cursor;
        // Per-track color (see tui/style.zig's track_palette, cycled with
        // `[`/`]` in the tracks view) - falls back to the generic accent
        // for clip cells below (unchanged look for uncolored tracks), and
        // to no color at all for the lane name (matches tracks.zig's own
        // name-coloring, which leaves an uncolored track plain).
        const track_color: ?[]const u8 = if (track.color > 0 and track.color <= style.track_palette.len)
            style.track_palette[track.color - 1]
        else
            null;

        if (is_sel_lane) try w.writeAll(sel);
        if (!is_sel_lane) if (track_color) |c| try w.writeAll(c);
        try w.print(" {d: >2} {s: <8}", .{ li + 1, track.name[0..@min(track.name.len, 8)] });
        if (!is_sel_lane) if (track_color) |_| try w.writeAll(rst);
        if (is_sel_lane) try w.writeAll(rst);

        for (0..visible) |c| {
            const bar = scroll +| @as(u32, @intCast(c)) *| grid_ticks;
            const downbeat = bar % ticks_per_bar == 0;
            try w.writeAll(if (downbeat) blu ++ "│" ++ rst else dim ++ "│" ++ rst);

            const clip = if (lane) |l| l.clipAt(bar) else null;
            const covered = clip != null;
            const is_start = covered and clip.?.start_tick == bar;
            const is_cursor = is_sel_lane and bar == cur_bar;
            const is_play = playhead == bar;
            const in_sel = visual_active and is_sel_lane and bar >= sel_lo and bar <= sel_hi;

            // Drum clips wear their variant letter on the start cell.
            const letter: ?u8 = if (is_start) switch (clip.?.content) {
                .drum => |d| ws.dsp.DrumMachine.variantLetter(d.variant),
                .melodic => null,
            } else null;

            if (is_cursor) {
                try w.writeAll(sel);
            } else if (is_play) {
                try w.writeAll(grn ++ bold);
            } else if (in_sel) {
                try w.writeAll(yel);
            } else if (covered) {
                try w.writeAll(track_color orelse acc);
            }
            if (cw == 2) {
                if (!covered) {
                    try w.writeAll(if (in_sel) "·" else if (is_play and !is_cursor) "‖" else " ");
                } else if (letter) |ch| {
                    try w.print("{c}", .{ch});
                } else {
                    try w.writeAll(if (is_start) "▌" else "█");
                }
            } else if (!covered) {
                try w.writeAll(if (in_sel) " · " else if (is_play and !is_cursor) " ‖ " else "   ");
            } else if (letter) |ch| {
                try w.print("▌{c}█", .{ch});
            } else {
                try w.writeAll(if (is_start) "▌██" else "███");
            }
            if (cw > 4) {
                if (covered) {
                    for (0..cw - 4) |_| try w.writeAll("█");
                } else try w.splatByteAll(' ', cw - 4);
            }
            if (is_cursor or is_play or covered or in_sel) try w.writeAll(rst);
        }
        try endLine(w);
    }

    const used = 2 + (last_lane - lane_scroll);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
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
    };
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), playheadBar(app, snap));
}
