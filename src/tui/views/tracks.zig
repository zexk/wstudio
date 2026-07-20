//! Tracks view + its status bar.

const std = @import("std");
const ws = @import("wstudio");
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");

// Aliases so the moved render bodies reference the shared palette/primitives
// by their original bare names.
const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const sel = style.sel;
const mag = style.mag;
const endLine = style.endLine;

/// Row-badge chips for a rack's FX chain, in signal-flow order. Chains can
/// hold up to nine units but a track row's width is shared with gain/pan and
/// the keybind hint, so show the first four and fold the rest into "+n".
fn writeFxBadges(w: *std.Io.Writer, fx: *const ws.Fx) !void {
    const max_chips = 4;
    for (fx.units.items, 0..) |u, n| {
        if (n == max_chips) {
            try w.print(" +{d}", .{fx.units.items.len - max_chips});
            break;
        }
        try w.writeByte(' ');
        try w.writeAll(spectrum_ed.badgeLabel3(u.kind()));
    }
}

/// Gain readout: dim "0dB" at the default, else an accented "+/-Ndb" -
/// shared by the track/group/master rows. `dim_at_default` is whether to
/// actually dim (false when the row itself is selected, or - track rows
/// only - faded from solo/mute; group/master rows have no faded state).
fn writeGainCell(w: *std.Io.Writer, gdb: f32, dim_at_default: bool) !void {
    if (gdb == 0.0) {
        if (dim_at_default) try w.writeAll(dim);
        try w.writeAll("  0dB");
        if (dim_at_default) try w.writeAll(rst);
    } else {
        const sign: []const u8 = if (gdb >= 0.0) "+" else "";
        try w.print("  {s}{d:.0}dB", .{ sign, gdb });
    }
}

/// One real track's row. Members of a group render indented under their
/// group's own row (see App.rebuildTrackRows for the folder ordering), which
/// replaced the old per-track "‣group" suffix tag.
fn writeTrackRow(app: anytype, w: *std.Io.Writer, ti: u16, is_sel: bool, in_sel: bool, cols: usize) !void {
    const track = app.session.project.tracks.items[ti];
    // Row content builds up in a scratch buffer so the keybind hint can
    // be pinned to the right edge (writeSplitRow) instead of trailing
    // wherever the left content happens to end.
    var row_buf: [768]u8 = undefined;
    var row_w = std.Io.Writer.fixed(&row_buf);
    const lw = &row_w;
    const inst_tag = std.meta.activeTag(app.session.racks.items[ti].instrument);
    const is_empty = inst_tag == .empty;
    const label: []const u8 = if (is_empty) "-- empty --" else app.session.racks.items[ti].label;
    const hint: []const u8 = if (!is_sel) "" else switch (inst_tag) {
        .empty => dim ++ "[enter:insert]" ++ rst,
        .drum_machine, .slicer => dim ++ "[enter:grid]" ++ rst,
        else => dim ++ "[enter:edit]" ++ rst,
    };
    // muted-but-not-selected rows get a dim wash over everything
    const faded = track.muted and !is_sel;
    const marker: []const u8 = if (is_sel) ">" else if (in_sel) "~" else " ";
    const grouped = if (track.group) |g| (g < app.session.groups.len and app.session.groups[g] != null) else false;

    if (is_sel) try lw.writeAll(sel) else if (in_sel) try lw.writeAll(yel);
    if (faded) try lw.writeAll(dim);
    try lw.writeByte(' ');
    try lw.writeAll(marker);
    try lw.writeByte(' ');
    if (in_sel and !is_sel) try lw.writeAll(rst);
    // group members sit indented under their group's row
    if (grouped) try lw.writeAll("  ");
    try lw.print("{d} ", .{ti + 1});
    // name padded - color wraps the whole padded field so the field
    // width itself never sees an escape code (matches the label/gain
    // color-wrap pattern below); track.color == 0 is uncolored.
    const track_color: ?[]const u8 = if (!is_sel and !faded and track.color > 0 and track.color <= style.track_palette.len)
        style.track_palette[track.color - 1]
    else
        null;
    if (track_color) |c| try lw.writeAll(c);
    try lw.print("{s: <8}", .{track.name});
    if (track_color != null) try lw.writeAll(rst);
    try lw.writeByte(' ');
    // instrument-kind icon - a single Mono-font cell either way, so
    // blank tracks' plain space keeps every row's columns aligned.
    const kind_icon: []const u8 = switch (inst_tag) {
        .empty => " ",
        .poly_synth => icons.synth,
        .sampler => icons.sampler,
        .drum_machine => icons.drum,
        .slicer => icons.slicer,
        .clap => icons.synth,
        .soundfont => icons.soundfont,
    };
    try lw.writeAll(kind_icon);
    try lw.writeByte(' ');
    // muted indicator: yellow only when row isn't already faded
    if (track.muted) {
        if (!faded) try lw.writeAll(yel);
        try lw.writeByte('M');
        if (!faded) try lw.writeAll(rst);
        if (is_sel) try lw.writeAll(sel);
    } else {
        try lw.writeByte(' ');
    }
    // solo indicator: green
    if (track.soloed) {
        if (!faded) try lw.writeAll(grn);
        try lw.writeByte('S');
        if (!faded) try lw.writeAll(rst);
        if (is_sel) try lw.writeAll(sel);
    } else {
        try lw.writeByte(' ');
    }
    // instrument / rack label - accent only on active, unselected rows
    if (!is_sel and !faded) try lw.writeAll(acc);
    try lw.print(" [{s}]", .{label});
    if (!is_sel and !faded) try lw.writeAll(rst);
    // FX badges - the chain's units in signal-flow order. Not gated on
    // is_empty: a chain can be built before the instrument is picked.
    if (ti < app.session.racks.items.len) {
        const rfx = &app.session.racks.items[ti].fx;
        if (rfx.units.items.len > 0) {
            if (!is_sel and !faded) try lw.writeAll(acc);
            try writeFxBadges(lw, rfx);
            if (!is_sel and !faded) try lw.writeAll(rst);
        }
    }
    // Gain / pan - always shown; dim at defaults, accented when non-default.
    {
        const pan = track.pan;
        // gain
        try writeGainCell(lw, track.gain_db, !is_sel and !faded);
        // pan
        if (pan == 0.0) {
            if (!is_sel and !faded) try lw.writeAll(dim);
            try lw.writeAll("  C");
            if (!is_sel and !faded) try lw.writeAll(rst);
        } else {
            const pct: i32 = @intFromFloat(@abs(pan) * 100.0);
            try lw.print("  {s}{d}%", .{ if (pan < 0.0) "L" else "R", pct });
        }
    }
    // keybind hint - pinned to the right edge (dropped by writeSplitRow
    // before the row content whenever the two would collide)
    try style.writeSplitRow(w, row_w.buffered(), hint, cols -| 1);
}

/// A group's own row - same shape as a track row (name, FX badges, bus
/// gain) plus a fold arrow and its `:group-*` slot number where a track row
/// has its track number. Folded groups show how many member rows they hide;
/// unfolded ones don't need to - the members sit right below.
fn writeGroupRow(app: anytype, w: *std.Io.Writer, gi: u8, is_sel: bool, in_sel: bool, cols: usize) !void {
    const grp = &app.session.groups[gi].?;
    var row_buf: [768]u8 = undefined;
    var row_w = std.Io.Writer.fixed(&row_buf);
    const lw = &row_w;
    const marker: []const u8 = if (is_sel) ">" else if (in_sel) "~" else " ";

    // zig fmt: off
    if (is_sel) try lw.writeAll(sel) else if (in_sel) try lw.writeAll(yel);
    try lw.writeByte(' ');
    try lw.writeAll(marker);
    try lw.writeByte(' ');
    if (in_sel and !is_sel) try lw.writeAll(rst);
    if (!is_sel) try lw.writeAll(mag);
    try lw.print("{s}{d} ", .{ @as([]const u8, if (grp.folded) "\u{25B8}" else "\u{25BE}"), gi + 1 });
    try lw.print("{s: <8}", .{grp.name[0..@min(grp.name.len, 8)]});
    if (!is_sel) try lw.writeAll(rst);
    if (!is_sel) try lw.writeAll(acc);
    try lw.writeAll(" [group]");
    if (!is_sel) try lw.writeAll(rst);
    if (grp.fx.units.items.len > 0) {
        if (!is_sel) try lw.writeAll(acc);
        try writeFxBadges(lw, &grp.fx);
        if (!is_sel) try lw.writeAll(rst);
    }
    // Bus fader - same dim-at-default shape as track gain.
    try writeGainCell(lw, grp.gain_db, !is_sel);
    if (grp.folded) {
        var members: usize = 0;
        for (app.session.project.tracks.items) |t| {
            if (t.group) |g| { if (g == gi) members += 1; }
        }
        if (!is_sel) try lw.writeAll(dim);
        try lw.print("  ({d} track{s})", .{ members, if (members == 1) "" else "s" });
        if (!is_sel) try lw.writeAll(rst);
    }
    const hint: []const u8 = if (is_sel) dim ++ "[enter:fx z:fold]" ++ rst else "";
    try style.writeSplitRow(w, row_w.buffered(), hint, cols -| 1);
}
// zig fmt: on

pub fn drawTracks(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    try w.writeAll(bold ++ " TRACKS" ++ rst);
    try endLine(w);

    // Vertical scroll over the display rows (tracks + group rows - see
    // App.TrackRow) - the master row below is always pinned/visible (like a
    // fixed footer channel), so only the list needs a window. Budget:
    // title(1) + master(1) + footer(3) are always spoken for; `rows` is
    // exact here (unlike editors/piano.zig's ensureVisible, called before
    // render, which has to approximate), so clamp directly against it -
    // same pattern as drawArrangement's `arr_scroll_bar`.
    app.tracksRowSync();
    const row_count = app.track_rows_len;
    const vis_rows: usize = rows -| 6;
    if (app.track_row < row_count) {
        if (app.track_row < app.track_scroll) app.track_scroll = app.track_row;
        if (vis_rows > 0 and app.track_row >= app.track_scroll + vis_rows) app.track_scroll = app.track_row - vis_rows + 1;
    }
    app.track_scroll = if (row_count > vis_rows) @min(app.track_scroll, row_count - vis_rows) else 0;
    const scroll = app.track_scroll;
    const last_visible = @min(row_count, scroll + vis_rows);
    app.track_rows_shown = last_visible - scroll;

    // Visual-mode selection: a contiguous display-row range (master
    // excluded, the cursor never reaches it while this mode is active - see
    // App.handleTracksVisual).
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.tracks_visual_anchor orelse app.track_row;
    const sel_lo = @min(sel_anchor, app.track_row);
    const sel_hi = @max(sel_anchor, app.track_row);

    for (app.trackRows()[scroll..last_visible], scroll..) |trow, ri| {
        const in_sel = visual_active and ri >= sel_lo and ri <= sel_hi;
        const is_sel = (ri == app.track_row);
        switch (trow) {
            .group => |gi| try writeGroupRow(app, w, gi, is_sel, in_sel, cols),
            .track => |ti| try writeTrackRow(app, w, ti, is_sel, in_sel, cols),
        }
        try endLine(w);
    }

    // Master row - same shape as a track row (icon, FX badges, gain) but
    // fixed at the end, unnamed, un-deletable, and with no pan/mute/solo/
    // piano-roll (see the on_master branch in App.handleKey).
    {
        var row_buf: [768]u8 = undefined;
        var row_w = std.Io.Writer.fixed(&row_buf);
        const lw = &row_w;
        const is_sel = (row_count == app.track_row);
        const marker: []const u8 = if (is_sel) ">" else " ";
        if (is_sel) try lw.writeAll(sel);
        try lw.writeByte(' ');
        try lw.writeAll(marker);
        try lw.writeAll("   ");
        try lw.print("{s: <8}", .{"MASTER"});
        try lw.writeByte(' ');
        try lw.writeAll(icons.master);
        try lw.writeAll("   ");
        if (!is_sel) try lw.writeAll(acc);
        try lw.writeAll(" [bus]");
        if (!is_sel) try lw.writeAll(rst);
        {
            const mfx = &app.session.master_fx;
            if (mfx.units.items.len > 0) {
                if (!is_sel) try lw.writeAll(acc);
                try writeFxBadges(lw, mfx);
                if (!is_sel) try lw.writeAll(rst);
            }
        }
        try writeGainCell(lw, app.master_gain_db, !is_sel);
        const hint: []const u8 = if (is_sel) dim ++ "[enter:fx]" ++ rst else "";
        try style.writeSplitRow(w, row_w.buffered(), hint, cols -| 1);
        try endLine(w);
    }

    const used = 2 + (last_visible - scroll);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

// zig fmt: off

// zig fmt: on
