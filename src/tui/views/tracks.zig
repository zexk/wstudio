//! Tracks view + its status bar.

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
        try w.writeAll(switch (u.kind()) {
            .gate => "gate", .comp => "cmp", .eq => "eq",
            .sat => "sat", .crush => "crs", .chorus => "cho",
            .phaser => "pha", .delay => "dly", .reverb => "rev",
        });
    }
}

pub fn drawTracks(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    try w.writeAll(bold ++ " TRACKS" ++ rst);
    try endLine(w);

    // Vertical scroll over the track rows — the master row below is always
    // pinned/visible (like a fixed footer channel), so only plain tracks
    // need a window. Budget: title(1) + master(1) + footer(3) are always
    // spoken for; `rows` is exact here (unlike editors/piano.zig's
    // ensureVisible, called before render, which has to approximate),
    // so clamp directly against it — same pattern as drawArrangement's
    // `arr_scroll_bar`.
    const track_count = app.session.project.tracks.items.len;
    const vis_rows: usize = rows -| 5;
    if (app.cursor < track_count) {
        if (app.cursor < app.track_scroll) app.track_scroll = app.cursor;
        if (vis_rows > 0 and app.cursor >= app.track_scroll + vis_rows) app.track_scroll = app.cursor - vis_rows + 1;
    }
    app.track_scroll = if (track_count > vis_rows) @min(app.track_scroll, track_count - vis_rows) else 0;
    const scroll = app.track_scroll;
    const last_visible = @min(track_count, scroll + vis_rows);
    app.track_rows_shown = last_visible - scroll;

    // Visual-mode selection: a contiguous track range (master excluded, the
    // cursor never reaches it while this mode is active — see
    // App.handleTracksVisual).
    const visual_active = app.modal.mode == .visual;
    const sel_anchor = app.tracks_visual_anchor orelse app.cursor;
    const sel_lo = @min(sel_anchor, app.cursor);
    const sel_hi = @max(sel_anchor, app.cursor);

    for (app.session.project.tracks.items[scroll..last_visible], scroll..) |track, i| {
        // Row content builds up in a scratch buffer so the keybind hint can
        // be pinned to the right edge (writeSplitRow) instead of trailing
        // wherever the left content happens to end.
        var row_buf: [768]u8 = undefined;
        var row_w = std.Io.Writer.fixed(&row_buf);
        const lw = &row_w;
        const in_sel = visual_active and i >= sel_lo and i <= sel_hi;
        const inst_tag = std.meta.activeTag(app.session.racks.items[i].instrument);
        const is_empty = inst_tag == .empty;
        const label: []const u8 = if (is_empty) "-- empty --" else app.session.racks.items[i].label;
        const hint: []const u8 = switch (inst_tag) {
            .empty => dim ++ "[enter:insert]" ++ rst,
            .drum_machine => dim ++ "[enter:grid]" ++ rst,
            else => dim ++ "[enter:edit]" ++ rst,
        };
        const is_sel = (i == app.cursor);
        // muted-but-not-selected rows get a dim wash over everything
        const faded = track.muted and !is_sel;
        const marker: []const u8 = if (is_sel) ">" else if (in_sel) "~" else " ";

        if (is_sel) try lw.writeAll(sel) else if (in_sel) try lw.writeAll(yel);
        if (faded) try lw.writeAll(dim);
        try lw.writeByte(' ');
        try lw.writeAll(marker);
        try lw.writeByte(' ');
        if (in_sel and !is_sel) try lw.writeAll(rst);
        try lw.print("{d} ", .{i + 1});
        // name padded — color wraps the whole padded field so the field
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
        // instrument-kind icon — a single Mono-font cell either way, so
        // blank tracks' plain space keeps every row's columns aligned.
        const kind_icon: []const u8 = switch (inst_tag) {
            .empty => " ",
            .poly_synth => icons.synth,
            .sampler => icons.sampler,
            .drum_machine => icons.drum,
            .slicer => icons.slicer,
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
        // instrument / rack label — accent only on active, unselected rows
        if (!is_sel and !faded) try lw.writeAll(acc);
        try lw.print(" [{s}]", .{label});
        if (!is_sel and !faded) try lw.writeAll(rst);
        // FX badges — the chain's units in signal-flow order. Not gated on
        // is_empty: a chain can be built before the instrument is picked.
        if (i < app.session.racks.items.len) {
            const rfx = &app.session.racks.items[i].fx;
            if (rfx.units.items.len > 0) {
                if (!is_sel and !faded) try lw.writeAll(acc);
                try writeFxBadges(lw, rfx);
                if (!is_sel and !faded) try lw.writeAll(rst);
            }
        }
        // Gain / pan — always shown; dim at defaults, accented when non-default.
        {
            const gdb = track.gain_db;
            const pan = track.pan;
            // gain
            if (gdb == 0.0) {
                if (!is_sel and !faded) try lw.writeAll(dim);
                try lw.writeAll("  0dB");
                if (!is_sel and !faded) try lw.writeAll(rst);
            } else {
                const sign: []const u8 = if (gdb >= 0.0) "+" else "";
                try lw.print("  {s}{d:.0}dB", .{ sign, gdb });
            }
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
        // Group membership tag — a small "belongs to" marker, only shown
        // when actually grouped. Group name truncated to 8 chars, same cap
        // the track-name field itself uses.
        if (track.group) |g| {
            if (g < app.session.groups.len) {
                if (app.session.groups[g]) |grp| {
                    if (!is_sel and !faded) try lw.writeAll(dim);
                    try lw.print("  \u{2023}{s}", .{grp.name[0..@min(grp.name.len, 8)]});
                    if (!is_sel and !faded) try lw.writeAll(rst);
                }
            }
        }
        // keybind hint — pinned to the right edge (dropped by writeSplitRow
        // before the row content whenever the two would collide)
        try style.writeSplitRow(w, row_w.buffered(), hint, cols -| 1);
        try endLine(w);
    }

    // Master row — same shape as a track row (icon, FX badges, gain) but
    // fixed at the end, unnamed, un-deletable, and with no pan/mute/solo/
    // piano-roll (see the on_master branch in App.handleKey).
    {
        var row_buf: [768]u8 = undefined;
        var row_w = std.Io.Writer.fixed(&row_buf);
        const lw = &row_w;
        const is_sel = (track_count == app.cursor);
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
        {
            const gdb = app.master_gain_db;
            if (gdb == 0.0) {
                if (!is_sel) try lw.writeAll(dim);
                try lw.writeAll("  0dB");
                if (!is_sel) try lw.writeAll(rst);
            } else {
                const sign: []const u8 = if (gdb >= 0.0) "+" else "";
                try lw.print("  {s}{d:.0}dB", .{ sign, gdb });
            }
        }
        try style.writeSplitRow(w, row_w.buffered(), dim ++ "[enter:fx]" ++ rst, cols -| 1);
        try endLine(w);
    }

    // title(1) + master(1) actually printed above, plus the visible track
    // rows — was "4 +" (stale from before the header/transport hr() rows
    // were removed), leaving 2 rows of dead blank space above the footer.
    const used = 2 + (last_visible - scroll);
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawTracksStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer, cmds: []const cmd_mod.Def) !void {
    switch (app.modal.mode) {
        .command => try cmd_mod.writePrompt(w, cmds, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor, 60),
        .search => try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor),
        else => {
            try style.writeModeBadge(w, app.modal.mode);
            try right.writeAll(acc ++ "TRACKS" ++ rst);
            // track position
            try w.writeAll(dim ++ "  " ++ rst);
            try w.print("{d}/{d}", .{ app.cursor + 1, app.session.project.tracks.items.len + 1 });
            try w.writeAll(dim ++ "  oct " ++ rst);
            try w.print("{d}", .{app.modal.octave});
            if (app.modal.count > 0) try w.print("  {d}", .{app.modal.count});
            if (app.status_len > 0) {
                try w.writeAll(dim ++ "  " ++ rst);
                try w.writeAll(app.status_buf[0..app.status_len]);
            }
        },
    }
}

