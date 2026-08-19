//! Tracks view + its status bar.

const std = @import("std");
const ws = @import("wstudio");
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");
const format = @import("../../ui/format.zig");
const spectrum_ed = @import("../../ui/editors/fx_editor.zig");

// Bare-name aliases for the shared palette/primitives.
const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const sel = style.sel;
const mag = style.mag;
const red = style.red;
const endLine = style.endLine;

/// One-cell ascii mnemonic per instrument kind, for terminals without the
/// Nerd Font. Every kind gets its own letter: this column is the only thing
/// naming the kind on a track row, so two kinds sharing one would make them
/// indistinguishable (which is exactly what `.clap`/`.vst3` did against
/// `.poly_synth`'s "S" until the test below went in). "X" reads as external
/// and is the only letter free of the mute/solo/record columns two cells
/// over.
fn kindLetter(kind: ws.InstrumentKind) []const u8 {
    return switch (kind) {
        // zig fmt: off
        .empty        => " ",
        .audio        => "W",
        .poly_synth   => "S",
        .sampler      => "P",
        .drum_machine => "D",
        .slicer       => "C",
        .clap, .vst3  => "X",
        .soundfont    => "F",
        .acoustic     => "A",
        // zig fmt: on
    };
}

test "every instrument kind has its own ascii mnemonic" {
    for (std.meta.tags(ws.InstrumentKind)) |a| {
        for (std.meta.tags(ws.InstrumentKind)) |b| {
            if (a == b) continue;
            // `.clap`/`.vst3` are the one pair that may share: they are both
            // "a hosted plugin" and the Nerd Font path shares a glyph too.
            if ((a == .clap and b == .vst3) or (a == .vst3 and b == .clap)) continue;
            try std.testing.expect(!std.mem.eql(u8, kindLetter(a), kindLetter(b)));
        }
    }
}

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
fn writeTrackRow(app: anytype, w: *std.Io.Writer, ti: u16, is_sel: bool, in_sel: bool, cols: usize, name_w: usize) !void {
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
        .empty => dim ++ "[enter insert]" ++ rst,
        // No editor to open: an audio track is edited on the arrangement.
        .audio => "",
        .drum_machine, .slicer => dim ++ "[enter grid]" ++ rst,
        else => dim ++ "[enter edit]" ++ rst,
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
    try style.writePadded(lw, track.name, name_w);
    if (track_color != null) try lw.writeAll(rst);
    try lw.writeByte(' ');
    // instrument-kind icon - a single cell either way (Mono glyph or the
    // ascii mnemonic below), so blank tracks' plain space keeps every row's
    // columns aligned regardless of `has_nerdfonts`. No adjacent text names
    // the kind here (unlike a view's title bar), so the no-icon fallback is
    // a letter rather than "", or the column would just go blank.
    const kind_icon: []const u8 = if (icons.font_installed) switch (inst_tag) {
        .empty => " ",
        .audio => icons.audio_track,
        .poly_synth => icons.synth,
        .sampler => icons.sampler,
        .drum_machine => icons.drum,
        .slicer => icons.slicer,
        .clap, .vst3 => icons.plugin,
        .soundfont, .acoustic => icons.soundfont,
    } else kindLetter(inst_tag);
    try lw.writeAll(kind_icon);
    try lw.writeByte(' ');
    // muted indicator: yellow only when row isn't already faded - icon when
    // the Nerd Font is installed, else the 'm'-keybind mnemonic letter, never
    // both (see icons.zig's font_installed contract).
    if (track.muted) {
        if (!faded) try lw.writeAll(yel);
        if (icons.font_installed) try lw.writeAll(icons.mute) else try lw.writeByte('M');
        if (!faded) try lw.writeAll(rst);
        if (is_sel) try lw.writeAll(sel);
    } else {
        try lw.writeByte(' ');
    }
    // solo indicator: green
    if (track.soloed) {
        if (!faded) try lw.writeAll(grn);
        if (icons.font_installed) try lw.writeAll(icons.solo) else try lw.writeByte('S');
        if (!faded) try lw.writeAll(rst);
        if (is_sel) try lw.writeAll(sel);
    } else {
        try lw.writeByte(' ');
    }
    // record-arm indicator: red, `r` toggles - inert unless the rack is a
    // Sampler (see `Session.isAudioArmed`), but shown for any armed track
    // so the state stays visible regardless of instrument kind.
    if (ti < app.session.armed.items.len and app.session.armed.items[ti]) {
        if (!faded) try lw.writeAll(red);
        if (icons.font_installed) try lw.writeAll(icons.record) else try lw.writeByte('R');
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
    // Aux-send count - only shown when the track has at least one, same
    // "quiet unless non-default" convention gain/pan below use. Set with
    // `:track-send`; this is just a count, not which target/level.
    {
        var send_count: usize = 0;
        for (track.sends) |s| if (s != null) {
            send_count += 1;
        };
        if (send_count > 0) {
            if (!is_sel and !faded) try lw.writeAll(acc);
            try lw.print(" \u{2192}{d}", .{send_count});
            if (!is_sel and !faded) try lw.writeAll(rst);
        }
    }
    // Gain / pan - always shown; dim at defaults, accented when non-default.
    {
        const pan = track.pan;
        // gain
        try writeGainCell(lw, track.gain_db, !is_sel and !faded);
        // pan
        var pan_buf: [16]u8 = undefined;
        const pan_label = format.panLabel(&pan_buf, pan);
        const centered = pan_label.len == 1;
        if (centered and !is_sel and !faded) try lw.writeAll(dim);
        try lw.print("  {s}", .{pan_label});
        if (centered and !is_sel and !faded) try lw.writeAll(rst);
    }
    // keybind hint - pinned to the right edge (dropped by writeSplitRow
    // before the row content whenever the two would collide)
    try style.writeSplitRow(w, row_w.buffered(), hint, cols -| 1);
}

/// A group's own row - same shape as a track row (name, FX badges, bus
/// gain) plus a fold arrow and its `:group-*` slot number where a track row
/// has its track number. Folded groups show how many member rows they hide;
/// unfolded ones don't need to - the members sit right below.
fn writeGroupRow(app: anytype, w: *std.Io.Writer, gi: u8, is_sel: bool, in_sel: bool, cols: usize, name_w: usize) !void {
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
    try style.writePadded(lw, grp.name, name_w);
    if (!is_sel) try lw.writeAll(rst);
    if (!is_sel) try lw.writeAll(acc);
    try lw.writeAll(" [group]");
    if (!is_sel) try lw.writeAll(rst);
    // Bus solo/mute indicators - same green/yellow S/M-or-icon shape a
    // track row's own flags get.
    if (grp.soloed) {
        try lw.writeByte(' ');
        if (!is_sel) try lw.writeAll(grn);
        if (icons.font_installed) try lw.writeAll(icons.solo) else try lw.writeByte('S');
        if (!is_sel) try lw.writeAll(rst);
    }
    if (grp.muted) {
        try lw.writeByte(' ');
        if (!is_sel) try lw.writeAll(yel);
        if (icons.font_installed) try lw.writeAll(icons.mute) else try lw.writeByte('M');
        if (!is_sel) try lw.writeAll(rst);
    }
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
    const hint: []const u8 = if (is_sel) dim ++ "[enter fx  z fold]" ++ rst else "";
    try style.writeSplitRow(w, row_w.buffered(), hint, cols -| 1);
}
// zig fmt: on

pub fn drawTracks(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    const mode_tag: []const u8 = if (app.session.song_mode) grn ++ "SONG" ++ rst else dim ++ "PATTERN" ++ rst;
    try w.writeAll(bold ++ " TRACKS" ++ rst ++ "  ");
    try w.writeAll(mode_tag);
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

    // The name column is as wide as the widest name on screen: 8 keeps the
    // old shape for ordinary names, 24 caps what one absurd name can claim.
    // Padding every row to one width is what keeps the columns after the
    // name (kind, FX badges, gain, pan) lined up - `{s: <8}` padded but
    // never truncated, so a long name shifted its own row's tail alone.
    var name_w: usize = 8;
    for (app.trackRows()[scroll..last_visible]) |trow| {
        const name = switch (trow) {
            .group => |gi| if (app.session.groups[gi]) |g| g.name else "",
            .track => |ti| app.session.project.tracks.items[ti].name,
        };
        name_w = @max(name_w, @min(style.visibleWidth(name), 24));
    }

    for (app.trackRows()[scroll..last_visible], scroll..) |trow, ri| {
        const in_sel = visual_active and ri >= sel_lo and ri <= sel_hi;
        const is_sel = (ri == app.track_row);
        switch (trow) {
            .group => |gi| try writeGroupRow(app, w, gi, is_sel, in_sel, cols, name_w),
            .track => |ti| try writeTrackRow(app, w, ti, is_sel, in_sel, cols, name_w),
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
        try style.writePadded(lw, "MASTER", name_w);
        try lw.writeByte(' ');
        try lw.writeAll(icons.iconOr(icons.master, " "));
        // One blank per column a track row spends on its icon gap and its
        // mute/solo/arm flags, so [bus] lands under the tracks' [synth].
        try lw.writeAll("    ");
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
        const hint: []const u8 = if (is_sel) dim ++ "[enter fx]" ++ rst else "";
        try style.writeSplitRow(w, row_w.buffered(), hint, cols -| 1);
        try endLine(w);
    }

    const used = 2 + (last_visible - scroll);
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}

// zig fmt: off

// zig fmt: on
