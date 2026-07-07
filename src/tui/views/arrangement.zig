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
const icons = @import("../icons.zig");
const cmd_mod = @import("../cmd.zig");

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

/// Left gutter: " NN name " then the lane's leading separator. The name field
/// is 8 wide — "e-piano"-sized names showed as "e-pian" at the old 6.
pub const gutter: usize = 13;

/// Bars that fit in the timeline area for a terminal `cols` wide, at cell
/// width `cw` (`App.arrCellWidth()` — 4 normal, 2 compact).
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
    const bpb: f64 = @floatFromInt(app.session.project.beats_per_bar);
    return @intFromFloat(t.positionBeats() / bpb);
}

pub fn drawArrangement(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
) !void {
    const bpb: u32 = app.session.project.beats_per_bar;
    const cw: usize = app.arrCellWidth();
    const visible = visibleBars(cols, cw);

    // Keep the bar cursor inside the visible window.
    const vis: u32 = @intCast(visible);
    if (app.arr_cursor_bar < app.arr_scroll_bar) app.arr_scroll_bar = app.arr_cursor_bar;
    if (app.arr_cursor_bar >= app.arr_scroll_bar + vis) app.arr_scroll_bar = app.arr_cursor_bar - vis + 1;

    const scroll = app.arr_scroll_bar;
    const cur_bar = app.arr_cursor_bar;
    const playhead = playheadBar(app, snap);

    const mode_tag: []const u8 = if (app.session.song_mode) grn ++ "SONG" ++ rst else dim ++ "PATTERN" ++ rst;
    try w.writeAll(bold ++ " " ++ icons.arrangement ++ " ARRANGEMENT" ++ rst ++ "  ");
    try w.writeAll(mode_tag);
    if (app.arr_zoom == .compact) try w.writeAll("  " ++ bcyn ++ "zoom" ++ rst);
    try endLine(w);

    // Bar ruler. Bars inside an armed loop region wear the accent colour.
    const p = &app.session.project;
    const loop_on = p.loop_enabled and p.loop_end_bar > p.loop_start_bar;
    for (0..gutter - 1) |_| try w.writeByte(' ');
    for (0..visible) |c| {
        const bar = scroll + @as(u32, @intCast(c));
        const downbeat = bar % bpb == 0;
        const in_loop = loop_on and bar >= p.loop_start_bar and bar < p.loop_end_bar;
        try w.writeAll(if (in_loop) yel ++ "│" ++ rst else if (downbeat) blu ++ "│" ++ rst else dim ++ "│" ++ rst);
        if (cw == 2) {
            // Compact: no room for a bar number without corrupting column
            // alignment — the separator's colour already marks downbeat/loop.
            try w.writeAll(if (in_loop) yel ++ "·" ++ rst else " ");
        } else if (downbeat) {
            try w.print("{s}{d: <3}{s}", .{ if (in_loop) yel else dim, bar + 1, rst });
        } else if (in_loop) {
            try w.writeAll(yel ++ "···" ++ rst);
        } else {
            try w.writeAll("   ");
        }
    }
    try endLine(w);

    // Visual-mode selection: a bar range on the current lane only.
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.arr_visual_anchor orelse cur_bar;
    const sel_lo: u32 = @min(sel_anchor, cur_bar);
    const sel_hi: u32 = @max(sel_anchor, cur_bar);

    // Lanes: vertical scroll over tracks, same window-clamp technique the
    // horizontal bar scroll above uses (exact `rows` is known here, unlike
    // editors/piano.zig's ensureVisible which has to approximate). Budget:
    // title(1) + ruler(1) + footer(3) = 5 are always spoken for.
    const lane_count = app.session.project.tracks.items.len;
    const vis_lanes: usize = rows -| 5;
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

        if (is_sel_lane) try w.writeAll(sel);
        try w.print(" {d: >2} {s: <8}", .{ li + 1, track.name[0..@min(track.name.len, 8)] });
        if (is_sel_lane) try w.writeAll(rst);

        for (0..visible) |c| {
            const bar = scroll + @as(u32, @intCast(c));
            const downbeat = bar % bpb == 0;
            try w.writeAll(if (downbeat) blu ++ "│" ++ rst else dim ++ "│" ++ rst);

            const clip = if (lane) |l| l.clipAt(bar) else null;
            const covered = clip != null;
            const is_start = covered and clip.?.start_bar == bar;
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
                try w.writeAll(acc);
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
            if (is_cursor or is_play or covered or in_sel) try w.writeAll(rst);
        }
        try endLine(w);
    }

    // used includes the 2 outer rows (header + hr) so padding aligns with drum-grid convention
    const used = 4 + (last_lane - lane_scroll);
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawArrangementStatus(app: anytype, w: *std.Io.Writer, cmds: []const cmd_mod.Def) !void {
    if (app.modal.mode == .command) {
        try cmd_mod.writePrompt(w, cmds, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor, 60);
        return;
    }
    if (app.modal.mode == .search) {
        try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor);
        return;
    }
    const visual_active = app.modal.mode == .visual;
    const mode_name: []const u8 = if (visual_active) "VISUAL" else if (app.session.song_mode) "SONG" else "PATTERN";
    const mode_colour: []const u8 = if (visual_active) mag else if (app.session.song_mode) grn else yel;
    try w.writeAll(mode_colour);
    try w.writeAll(sel);
    try w.print(" {s} ", .{mode_name});
    try w.writeAll(rst);
    if (app.arr_zoom == .compact) {
        try w.writeAll(dim ++ "  " ++ rst ++ bcyn ++ "zoom" ++ rst);
    }

    try w.writeAll(dim ++ "  bar " ++ rst);
    try w.print("{d}", .{app.arr_cursor_bar + 1});
    try w.writeAll(dim ++ "  track " ++ rst);
    try w.print("{d}/{d}", .{ app.cursor + 1, app.session.project.tracks.items.len });

    const p = &app.session.project;
    if (p.loop_enabled and p.loop_end_bar > p.loop_start_bar) {
        try w.writeAll(dim ++ "  " ++ rst ++ yel ++ icons.loop ++ " loop " ++ rst ++ yel);
        try w.print("{d}\u{2192}{d}", .{ p.loop_start_bar + 1, p.loop_end_bar });
        try w.writeAll(rst);
    }

    // On a drum lane, show which pattern variant enter would stamp.
    if (app.cursor < app.session.racks.items.len) {
        switch (app.session.racks.items[app.cursor].instrument) {
            .drum_machine => |*dm| {
                try w.writeAll(dim ++ "  pat " ++ rst);
                try w.print("{c}", .{ws.dsp.DrumMachine.variantLetter(dm.variant)});
                try w.writeAll(dim ++ "/" ++ rst);
                try w.print("{d}", .{dm.variant_count});
            },
            else => {},
        }
    }

    if (app.session.arrangement.lane(app.cursor)) |lane| {
        if (lane.clipAt(app.arr_cursor_bar)) |clip| {
            try w.writeAll(dim ++ "  clip " ++ rst);
            try w.print("{d}\u{2192}{d}", .{ clip.start_bar + 1, clip.endBar() });
            switch (clip.content) {
                .drum => |d| try w.print(" {s}pat{s} {c}", .{
                    dim, rst, ws.dsp.DrumMachine.variantLetter(d.variant),
                }),
                .melodic => {},
            }
        }
    }

    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}
