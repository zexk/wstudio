//! FX chain view (track and master) + its status bar.
//!
//! The user-built FX chain is the view's centrepiece: a boxed strip of the
//! inserted units in signal-flow order (plus a trailing "+" box while
//! there's room), with the focused unit's editor filling the body below.
//! Chains start empty; `a` opens the FX picker. The spectrum analyzer is
//! part of an EQ unit's editor; it draws (and runs) only while one has
//! focus. The input half lives in editors/spectrum.zig.

const std = @import("std");
const ws = @import("wstudio");
const eq_mod = ws.dsp.eq;
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");

// Aliases so the render bodies reference the shared palette/primitives
// by their original bare names.
const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const yel = style.yel;
const red = style.red;
const blu = style.blu;
const mag = style.mag;
const bcyn = style.bcyn;
const bwht = style.bwht;
const endLine = style.endLine;
const hr = style.hr;
const spectrum_rows = spectrum_ed.spectrum_rows;
const spectrum_band_count = spectrum_ed.spectrum_band_count;
const synthSection = style.synthSection;
const barRow = style.barRow;
const enumRow = style.enumRow;

// Lower-eighths block glyphs, shortest (cut) to tallest (boost). 0dB lands
// on the middle glyph so a flat band still reads as a visible bar.
const eq_glyphs = [_][]const u8{
    "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
    "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}",
};

fn eqGlyph(gain_db: f32) []const u8 {
    const norm = std.math.clamp((gain_db + 18.0) / 36.0, 0.0, 1.0);
    const lvl: usize = @intFromFloat(@round(norm * @as(f32, @floatFromInt(eq_glyphs.len - 1))));
    return eq_glyphs[@min(lvl, eq_glyphs.len - 1)];
}

/// Bar-row glyph for a lowpass/highpass band: gain doesn't shape a filter
/// band's response, so the bar instead tracks slope (steeper = taller).
fn slopeGlyph(slope: u8) []const u8 {
    const lvl = @min(@as(usize, slope) * 2 - 1, eq_glyphs.len - 1);
    return eq_glyphs[lvl];
}

// Colour by direction and how far a band has been pushed: a near-flat band
// stays dim, mild boost/cut are green/blue, and pushing past ±9dB escalates
// to red/magenta so a hot band is visible at a glance.
fn eqColor(gain_db: f32) []const u8 {
    if (gain_db >= 9.0) return red;
    if (gain_db > 0.3) return grn;
    if (gain_db <= -9.0) return mag;
    if (gain_db < -0.3) return blu;
    return dim;
}

/// Bottom-anchored braille partial: `rem` of the cell's 4 sub-rows lit,
/// counted up from the cell's floor (0 = blank, 4 = full block).
fn brailleBar(rem: usize) u21 {
    const bits: u8 = switch (rem) {
        0 => 0b00000000,
        1 => 0b11000000,
        2 => 0b11100100,
        3 => 0b11110110,
        else => 0b11111111,
    };
    return @as(u21, 0x2800) | @as(u21, bits);
}

/// Accent colour per unit kind - used by its section divider and param bars.
fn sectionColor(k: ws.FxKind) []const u8 {
    return switch (k) {
        .gate => bcyn,
        .comp => yel,
        .mb_comp => yel,
        .ott => yel,
        .eq => grn,
        .sat => red,
        .crush => mag,
        .chorus => bcyn,
        .flanger => bcyn,
        .tape => bcyn,
        .phaser => yel,
        .freq_shift => acc,
        .delay => blu,
        .reverb => mag,
        .clap => acc,
    };
}

/// Whether the strip shows the trailing "+" insert box.
fn plusBoxShown(chain: *const ws.Fx) bool {
    return chain.units.items.len < ws.Fx.max_units;
}

/// One strip border row (top or bottom): a box outline per inserted unit,
/// plus a dim one for the "+" box while it's shown.
fn drawStripBorder(app: anytype, w: *std.Io.Writer, chain: *const ws.Fx, top: bool) !void {
    const boxes = chain.units.items.len + @intFromBool(plusBoxShown(chain));
    try w.writeAll("   ");
    for (0..boxes) |i| {
        const focused = i < chain.units.items.len and i == app.fx_focus;
        if (i > 0) try w.writeAll(" ");
        if (focused) {
            // zig fmt: off
            try w.writeAll(if (top) acc ++ bold ++ "\u{250F}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2513}"
                           else acc ++ bold ++ "\u{2517}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{251B}");
        } else {
            try w.writeAll(if (top) dim ++ "\u{250C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}"
                           else dim ++ "\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}");
                           // zig fmt: on
        }
        try w.writeAll(rst);
    }
    try endLine(w);
}

/// The 3-row chain strip: IN → the inserted units in signal-flow order →
/// OUT, with a "+" box marking where `a` inserts next. The focused unit
/// gets a heavy accent border; active units are green, bypassed ones red
/// with a hollow dot. Geometry (3-col gutter, 7-wide boxes, 1-wide arrows;
/// nine boxes + "▶OUT" = 78 cols, inside an 80-col terminal) is mirrored by
/// the strip constants in editors/spectrum.zig for mouse hit-testing. In
/// compact mode (short terminals) only the middle row is drawn; same
/// columns, just without the box borders.
fn drawChainStrip(app: anytype, w: *std.Io.Writer, chain: *const ws.Fx, compact: bool) !void {
    if (!compact) try drawStripBorder(app, w, chain, true);

    try w.writeAll(dim ++ "IN\u{25B6}" ++ rst);
    for (chain.units.items, 0..) |u, i| {
        const focused = i == app.fx_focus;
        if (i > 0) try w.writeAll(dim ++ "\u{25B6}" ++ rst);
        try w.writeAll(if (focused) acc ++ bold ++ "\u{2503}" else dim ++ "\u{2502}");
        try w.writeAll(rst);
        try w.writeAll(if (focused) bwht ++ bold else if (u.bypassed) red else grn);
        try w.print("{s: <4}", .{spectrum_ed.stripLabel(u.kind())});
        try w.writeAll(rst);
        try w.writeAll(if (u.bypassed) red else grn);
        try w.writeAll(if (u.bypassed) "\u{25CB}" else "\u{25CF}");
        try w.writeAll(rst);
        try w.writeAll(if (focused) acc ++ bold ++ "\u{2503}" else dim ++ "\u{2502}");
        try w.writeAll(rst);
    }
    if (plusBoxShown(chain)) {
        if (chain.units.items.len > 0) try w.writeAll(dim ++ "\u{25B6}" ++ rst);
        try w.writeAll(dim ++ "\u{2502}  +  \u{2502}" ++ rst);
    }
    try w.writeAll(dim ++ "\u{25B6}OUT" ++ rst);
    try endLine(w);

    if (!compact) try drawStripBorder(app, w, chain, false);
}

pub fn drawFxView(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
    target: spectrum_ed.EqTarget,
) !void {
    _ = snap;

    const title: []const u8 = switch (target) {
        .track => if (app.eq_track < app.session.project.tracks.items.len)
            app.session.project.tracks.items[app.eq_track].name
        else
            "?",
        .master => "MASTER",
        .group => if (app.eq_group < engine_mod.max_groups) blk: {
            break :blk if (app.session.groups[app.eq_group]) |g| g.name else "?";
        } else "?",
    };

    const title_icon: []const u8 = if (target == .master) icons.master else icons.eq;
    try w.writeAll(bold ++ " " ++ rst);
    try w.writeAll(icons.iconOr(title_icon, ""));
    try w.writeAll(bold);
    try w.writeAll(if (icons.font_installed) " FX CHAIN" else "FX CHAIN");
    try w.writeAll(rst);
    try w.print(" \"{s}\"", .{title});
    // A group chain has its own bus fader (-/+); keep the level in sight.
    if (target == .group and app.eq_group < engine_mod.max_groups) {
        if (app.session.groups[app.eq_group]) |g| try w.print(dim ++ "  bus {d:.1}dB" ++ rst, .{g.gain_db});
    }
    try endLine(w);

    // Null only when the viewed track/group was deleted out from under the
    // view - app.zig's guard kicks back to tracks on the next key; just pad
    // here.
    const chain = spectrum_ed.fxPtr(app, target) orelse {
        for (1..@max(1, rows -| 4)) |_| try endLine(w);
        return;
    };

    const compact = spectrum_ed.compactLayout(rows);
    try drawChainStrip(app, w, chain, compact);

    const focused = spectrum_ed.focusedUnit(app, chain);

    if (!compact) {
        try w.writeAll(dim ++ "  tab/[/]:slot  a:insert  x:remove  </>:move  b:bypass  ");
        // EQ gets its own two-stage scheme (see editors/spectrum.zig's
        // eq_band_select doc comment) - h/l means something different
        // depending which stage it's in, so the hint has to match.
        if (focused != null and focused.?.kind() == .eq) {
            if (app.eq_band_select) try w.writeAll("h/l:band  enter:edit") else try w.writeAll("j/k:field  h/l:adjust  esc:back");
        } else {
            try w.writeAll("j/k:param  h/l:adjust");
        }
        if (target == .group) try w.writeAll("  -/+:bus gain");
        try w.writeAll(rst);
        try endLine(w);
    }

    var body_lines: usize = 0;
    if (focused == null) {
        try synthSection(w, "FX CHAIN", acc);
        try w.writeAll(dim ++ "   Audio passes directly from IN to OUT." ++ rst);
        try endLine(w);
        try w.writeAll(acc ++ "   a" ++ rst ++ dim ++ "  insert an effect" ++ rst);
        try endLine(w);
        try w.writeAll(dim ++ "   Start with EQ for tone shaping, Compressor for dynamics, or Reverb for space." ++ rst);
        try endLine(w);
        body_lines = 3;
    } else if (focused.?.kind() == .eq) {
        const unit = focused.?;
        try synthSection(w, spectrum_ed.editorTitle(.eq), sectionColor(.eq));
        // The EQ unit's editor: live spectrum graph up top, the 8 band
        // columns underneath. The analyzer only runs while an EQ has focus
        // (editors/spectrum.zig parks it on focus change).
        const spectrum_snap = switch (target) {
            .track => app.session.engine.trackSpectrumSnapshot(app.eq_track),
            .master => app.session.engine.masterSpectrumSnapshot(),
            .group => app.session.engine.groupSpectrumSnapshot(app.eq_group),
        };

        const bands = spectrum_ed.eq_band_rows;
        // Header + strip + hint + section (6; 3 in compact mode) + graph
        // + hz label + band rows must fit in rows-3 (the caller's header/
        // transport/status - no separate hr() rule rows anymore). usize
        // annotation matters: @min against the comptime spectrum_rows bound
        // otherwise narrows the type to u5, and `visual_rows * 4`
        // overflows it.
        const visual_rows: usize = @min(spectrum_rows, rows -| ((if (compact) @as(usize, 7) else 10) + bands));
        // Limit band count to available horizontal space (6-char dB gutter + bands).
        const draw_bands = @min(spectrum_band_count, cols -| 8);

        const db_range: f32 = 70.0;
        const db_offset: f32 = -60.0;

        // Axis labels sit in the 6-char gutter at their true heights on
        // the dB scale, so bars draw on every row.
        const total_pixels = visual_rows * 4;
        const axis_labels = [_]struct { db: f32, label: []const u8 }{
            // zig fmt: off
            .{ .db = 0.0,   .label = "  0dB" },
            // zig fmt: on
            .{ .db = -20.0, .label = "-20dB" },
            .{ .db = -40.0, .label = "-40dB" },
        };

        for (0..visual_rows) |line| {
            const visual_row = visual_rows - 1 - line; // counted up from the graph floor

            try w.writeAll(dim);
            const tick: []const u8 = blk: {
                for (axis_labels) |a| {
                    const norm_a = std.math.clamp((a.db - db_offset) / db_range, 0.0, 1.0);
                    const px: usize = @intFromFloat(norm_a * @as(f32, @floatFromInt(total_pixels)));
                    if (@min(px / 4, visual_rows - 1) == visual_row) break :blk a.label;
                }
                break :blk "     ";
            };
            try w.writeAll(tick);
            try w.writeAll("\u{2524}" ++ rst);

            if (spectrum_snap) |ssnap| {
                // colour by level: top rows are louder
                const row_norm: f32 = @as(f32, @floatFromInt(visual_row)) /
                    @as(f32, @floatFromInt(visual_rows));
                // zig fmt: off
                const colour: []const u8 = if (row_norm > 0.85) red
                    else if (row_norm > 0.65) yel
                    else grn;
                    // zig fmt: on
                for (0..draw_bands) |band| {
                    const db_val = ssnap.bins[band];
                    const raw = (db_val - db_offset) / db_range;
                    const norm = if (std.math.isNan(raw)) 0.0 else std.math.clamp(raw, 0.0, 1.0);
                    const pixel_height: usize = @intFromFloat(norm * @as(f32, @floatFromInt(total_pixels)));

                    const rem = @min(pixel_height -| (visual_row * 4), 4);
                    if (rem == 0) {
                        try w.writeByte(' ');
                        continue;
                    }
                    try w.writeAll(colour);
                    const ch = brailleBar(rem);
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(ch, &utf8_buf) catch unreachable;
                    try w.writeAll(utf8_buf[0..utf8_len]);
                    try w.writeAll(rst);
                }
            }
            // No snapshot (analyzer idle): leave the graph area blank -
            // endLine clears to the right edge.
            try endLine(w);
        }

        try w.writeAll(dim ++ "Hz    ");
        const freq_labels = [_]struct { idx: usize, label: []const u8 }{
            // zig fmt: off
            .{ .idx = 0,  .label = "20"  },
            .{ .idx = 12, .label = "40"  },
            .{ .idx = 24, .label = "80"  },
            .{ .idx = 36, .label = "160" },
            .{ .idx = 48, .label = "320" },
            .{ .idx = 55, .label = "640" },
            .{ .idx = 61, .label = "1.2k"},
            .{ .idx = 67, .label = "2.5k"},
            .{ .idx = 72, .label = "5k"  },
            // zig fmt: on
            .{ .idx = 76, .label = "10k" },
            .{ .idx = 78, .label = "20k" },
        };

        // Pad each label out to its target bin (`idx`) by tracked column,
        // not by looping one char per bin - a previous version wrote each
        // label in a single step without advancing the loop past its
        // extra characters, so every label after the first drifted right
        // of its bin and the top "20k" (human hearing's upper edge)
        // always landed past the terminal width and got dropped, even on
        // normal-width terminals with room to spare.
        var col: usize = 0;
        for (freq_labels) |lbl| {
            if (lbl.idx >= draw_bands) continue;
            // Never start before one space past the previous label -
            // "10k"/"20k" sit only two bins apart at the top of the
            // range, closer than "10k" is wide, so clamp forward instead
            // of dropping the tick entirely (still shows, just nudged off
            // its exact bin).
            const min_start = if (col == 0) lbl.idx else col + 1;
            const start = @max(lbl.idx, min_start);
            if (6 + start + lbl.label.len > cols) break;
            for (col..start) |_| try w.writeByte(' ');
            try w.writeAll(lbl.label);
            col = start + lbl.label.len;
        }
        try endLine(w);

        const e = &unit.payload.eq;
        const bf = spectrum_ed.eqBandField(app.fx_param);
        const cur_band = bf.band;
        const cur_field = bf.field;

        // All-band overview: two dim rows so the whole curve's shape stays
        // visible at a glance (glyph height/colour = gain for a peak band,
        // slope steepness for a filter band; frequency underneath). Detail
        // for one band at a time lives below in the same barRow/enumRow
        // widgets every other FX unit's body uses - a flat 8-wide grid of
        // every field stopped scaling once a band could also carry a
        // separate slope on top of freq/q/gain.
        try w.writeAll("   ");
        for (0..eq_mod.num_eq_bands) |b| {
            const band = &e.bands[b];
            const is_cur = b == cur_band;
            if (is_cur) try w.writeAll(bold ++ acc ++ " [" ++ rst) else try w.writeAll("  ");
            if (band.kind == .peak) {
                const gain = band.gain_db;
                try w.writeAll(if (is_cur) bwht else eqColor(gain));
                if (is_cur) try w.writeAll(bold);
                try w.writeAll(eqGlyph(gain));
            } else {
                try w.writeAll(if (is_cur) bwht ++ bold else bcyn);
                try w.writeAll(slopeGlyph(band.slope));
            }
            try w.writeAll(rst);
            if (is_cur) try w.writeAll(bold ++ acc ++ "] " ++ rst) else try w.writeAll("  ");
        }
        try endLine(w);

        try w.writeAll(dim ++ "   ");
        for (0..eq_mod.num_eq_bands) |b| {
            const is_cur = b == cur_band;
            var fbuf: [8]u8 = undefined;
            const lbl = spectrum_ed.compactHz(&fbuf, e.bands[b].freq);
            if (is_cur) try w.writeAll(rst ++ acc ++ bold);
            try w.print("{s: ^5}", .{lbl});
            if (is_cur) try w.writeAll(rst ++ dim);
        }
        try w.writeAll(rst);
        try endLine(w);

        // Focused-band detail: kind/freq/q/gain-or-slope as full sliders,
        // one row each - "gain" becomes "slope" the moment the band isn't
        // peak (see eq_field_gain's doc comment), which is the actual ask
        // this redesign answers: a filter band's steepness gets a real
        // slider instead of being folded into the same cycle as its kind.
        // Rows only show a selection cursor once `enter` has actually
        // opened this band's submenu - while still in band-select, h/l
        // moves bands instead of nudging a field, so highlighting one here
        // would read as active when it isn't.
        const in_submenu = !app.eq_band_select;
        var hdr_buf: [24]u8 = undefined;
        const hdr = if (in_submenu)
            std.fmt.bufPrint(&hdr_buf, "BAND {d}", .{cur_band + 1}) catch "BAND"
        else
            std.fmt.bufPrint(&hdr_buf, "BAND {d} (enter)", .{cur_band + 1}) catch "BAND";
        try synthSection(w, hdr, sectionColor(.eq));

        const kind_idx = cur_band * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_kind;
        const kind_names = [_][]const u8{
            spectrum_ed.eq_kind_specs[0].label,
            spectrum_ed.eq_kind_specs[1].label,
            spectrum_ed.eq_kind_specs[2].label,
        };
        // zig fmt: off
        try enumRow(w, in_submenu and cur_field == spectrum_ed.eq_field_kind, false, sectionColor(.eq), "kind", &kind_names,
            @intFromFloat(@round(spectrum_ed.getParam(&unit.payload, kind_idx))));

        inline for (.{ spectrum_ed.eq_field_freq, spectrum_ed.eq_field_q, spectrum_ed.eq_field_gain }) |field| {
            const idx = cur_band * spectrum_ed.eq_fields_per_band + field;
            const v = spectrum_ed.getParam(&unit.payload, idx);
            const range = spectrum_ed.paramRange(app, &unit.payload, idx);
            const norm = std.math.clamp((v - range[0]) / (range[1] - range[0]), 0.0, 1.0);
            var vbuf: [16]u8 = undefined;
            try barRow(w, in_submenu and cur_field == field, false, sectionColor(.eq),
                spectrum_ed.paramName(&unit.payload, idx), norm, 1.0, spectrum_ed.formatValue(app, &vbuf, &unit.payload, idx));
                // zig fmt: on
        }

        body_lines = visual_rows + 1 + bands;
    } else {
        const unit = focused.?;
        const k = unit.kind();
        try synthSection(w, spectrum_ed.editorTitle(k), sectionColor(k));
        // One synth-editor-style bar per param, filled against the
        // same [min, max] setParam clamps to.
        const visible_count = spectrum_ed.visibleParamCount(app, k, &unit.payload);
        for (0..visible_count) |i| {
            const is_sel = (i == app.fx_param);
            const v = spectrum_ed.getParam(&unit.payload, i);
            if (spectrum_ed.paramToggleNames(k, i)) |names| {
                try enumRow(w, is_sel, false, sectionColor(k), spectrum_ed.paramName(&unit.payload, i), &names, if (v < 0.5) 0 else 1);
                continue;
            }
            const range = spectrum_ed.paramRange(app, &unit.payload, i);
            const norm = std.math.clamp((v - range[0]) / (range[1] - range[0]), 0.0, 1.0);
            var vbuf: [16]u8 = undefined;
            try barRow(w, is_sel, false, sectionColor(k), spectrum_ed.paramName(&unit.payload, i), norm, 1.0, spectrum_ed.formatValue(app, &vbuf, &unit.payload, i));
        }
        body_lines = visible_count;
        if (unit.bypassed) {
            try w.writeAll(red ++ "   BYPASSED" ++ rst ++ dim ++ "  (b to re-enable)" ++ rst);
            try endLine(w);
            body_lines += 1;
        }
    }

    // Pad to fill the view's row budget (rows-4) so the footer stays pinned.
    // lines written: 1 (header) + strip + hint + 1 (section) + body_lines,
    // where strip+hint is 4 rows normally, 1 in compact mode.
    const prelude: usize = if (compact) 3 else 6;
    const used = prelude + body_lines;
    for (used..@max(used, rows -| 4)) |_| try endLine(w);
}
