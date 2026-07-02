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

const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const sel = style.sel;
const blu = style.blu;
const endLine = style.endLine;

/// Total chars per bar column: a 1-char separator plus 3-char content.
pub const cell_w: usize = 4;
/// Left gutter: " NN name " then the lane's leading separator.
pub const gutter: usize = 11;

/// Bars that fit in the timeline area for a terminal `cols` wide.
pub fn visibleBars(cols: usize) usize {
    if (cols <= gutter + cell_w) return 1;
    return (cols - gutter) / cell_w;
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
    const visible = visibleBars(cols);

    // Keep the bar cursor inside the visible window.
    const vis: u32 = @intCast(visible);
    if (app.arr_cursor_bar < app.arr_scroll_bar) app.arr_scroll_bar = app.arr_cursor_bar;
    if (app.arr_cursor_bar >= app.arr_scroll_bar + vis) app.arr_scroll_bar = app.arr_cursor_bar - vis + 1;

    const scroll = app.arr_scroll_bar;
    const cur_bar = app.arr_cursor_bar;
    const playhead = playheadBar(app, snap);

    const mode_tag: []const u8 = if (app.session.song_mode) grn ++ "SONG" ++ rst else dim ++ "PATTERN" ++ rst;
    try w.writeAll(bold ++ " ARRANGEMENT" ++ rst ++ "  ");
    try w.writeAll(mode_tag);
    try w.writeAll(dim ++ "   [hjkl:move  enter:stamp  e:edit-clip  []:pattern  x:del  g:play-here  T:mode  space:play  esc:back]" ++ rst);
    try endLine(w);

    // Bar ruler.
    for (0..gutter - 1) |_| try w.writeByte(' ');
    for (0..visible) |c| {
        const bar = scroll + @as(u32, @intCast(c));
        const downbeat = bar % bpb == 0;
        try w.writeAll(if (downbeat) blu ++ "│" ++ rst else dim ++ "│" ++ rst);
        if (downbeat) {
            try w.print("{s}{d: >3}{s}", .{ dim, bar + 1, rst });
        } else {
            try w.writeAll("   ");
        }
    }
    try endLine(w);

    // Lanes.
    for (app.session.project.tracks.items, 0..) |track, li| {
        const lane = app.session.arrangement.lane(li);
        const is_sel_lane = li == app.cursor;

        if (is_sel_lane) try w.writeAll(sel);
        try w.print(" {d: >2} {s: <6}", .{ li + 1, track.name[0..@min(track.name.len, 6)] });
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

            // Drum clips wear their variant letter on the start cell.
            const letter: ?u8 = if (is_start) switch (clip.?.content) {
                .drum => |d| ws.dsp.DrumMachine.variantLetter(d.variant),
                .melodic => null,
            } else null;

            if (is_cursor) {
                try w.writeAll(sel);
            } else if (is_play) {
                try w.writeAll(grn ++ bold);
            } else if (covered) {
                try w.writeAll(acc);
            }
            if (!covered) {
                try w.writeAll(if (is_play and !is_cursor) " ‖ " else "   ");
            } else if (letter) |ch| {
                try w.print("▌{c}█", .{ch});
            } else {
                try w.writeAll(if (is_start) "▌██" else "███");
            }
            if (is_cursor or is_play or covered) try w.writeAll(rst);
        }
        try endLine(w);
    }

    const used = 3 + app.session.project.tracks.items.len;
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawArrangementStatus(app: anytype, w: *std.Io.Writer) !void {
    if (app.modal.mode == .command) {
        try w.writeAll(dim ++ " :" ++ rst);
        try w.print("{s}_", .{app.modal.cmd_buf[0..app.modal.cmd_len]});
        return;
    }
    const mode_name: []const u8 = if (app.session.song_mode) "SONG" else "PATTERN";
    const mode_colour: []const u8 = if (app.session.song_mode) grn else yel;
    try w.writeAll(mode_colour);
    try w.writeAll(sel);
    try w.print(" {s} ", .{mode_name});
    try w.writeAll(rst);

    try w.writeAll(dim ++ "  bar " ++ rst);
    try w.print("{d}", .{app.arr_cursor_bar + 1});
    try w.writeAll(dim ++ "  track " ++ rst);
    try w.print("{d}/{d}", .{ app.cursor + 1, app.session.project.tracks.items.len });

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
