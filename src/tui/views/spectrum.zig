//! FX rack view (track and master) + its status bar.
//!
//! The FX chain is the view's centrepiece: a boxed strip of the four chain
//! slots in signal-flow order (comp → eq → delay → reverb), with the
//! focused slot's editor filling the body below. The spectrum analyzer is
//! part of the EQ slot's editor — it draws (and runs) only while that slot
//! has focus. The input half lives in editors/spectrum.zig.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const Project = ws.Project;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const eq_mod = ws.dsp.eq;
const cmd_mod = @import("../cmd.zig");
const spectrum_ed = @import("../editors/spectrum.zig");
const engine_mod = ws.engine;
const pattern_mod = ws.dsp.pattern;
const midi = ws.midi;
const style = @import("../style.zig");
const icons = @import("../icons.zig");

// Aliases so the render bodies reference the shared palette/primitives
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

// Short frequency labels for the EQ band row, in eq_mod.iso_frequencies order.
const eq_freq_labels = [_][]const u8{ "31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" };

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

/// Section-divider label for the focused slot's editor body.
fn sectionLabel(u: spectrum_ed.FxUnit) []const u8 {
    return switch (u) {
        .comp => "COMPRESSOR",
        .eq => "EQ + SPECTRUM",
        .delay => "DELAY",
        .reverb => "REVERB",
    };
}

/// Accent colour per slot — used by its section divider and param bars.
fn sectionColor(u: spectrum_ed.FxUnit) []const u8 {
    return switch (u) {
        .comp => yel,
        .eq => grn,
        .delay => blu,
        .reverb => mag,
    };
}

/// The 3-row chain strip: IN → four slot boxes in signal-flow order → OUT.
/// The focused slot gets a heavy accent border; present units are green
/// (red if the EQ is bypassed), absent ones dim with a hollow dot. Geometry
/// (7-col gutter, 11-wide boxes, 3-wide arrows) is mirrored by the strip
/// constants in editors/spectrum.zig for mouse hit-testing. In compact
/// mode (short terminals) only the middle row is drawn — same columns,
/// just without the box borders.
fn drawChainStrip(app: anytype, w: *std.Io.Writer, chain: *const ws.Fx, compact: bool) !void {
    if (!compact) {
        try w.writeAll("       ");
        inline for (0..4) |i| {
            const u: spectrum_ed.FxUnit = @enumFromInt(i);
            const focused = u == app.fx_focus;
            if (i > 0) try w.writeAll("   ");
            try w.writeAll(if (focused) acc ++ bold ++ "\u{250F}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2513}"
                           else dim ++ "\u{250C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}");
            try w.writeAll(rst);
        }
        try endLine(w);
    }

    try w.writeAll(dim ++ " IN \u{2500}\u{25B6} " ++ rst);
    inline for (0..4) |i| {
        const u: spectrum_ed.FxUnit = @enumFromInt(i);
        const focused = u == app.fx_focus;
        const present = spectrum_ed.isPresent(chain, u);
        const bypassed = u == .eq and present and chain.eq.?.bypass;
        if (i > 0) try w.writeAll(dim ++ "\u{2500}\u{25B6} " ++ rst);
        try w.writeAll(if (focused) acc ++ bold ++ "\u{2503}" else dim ++ "\u{2502}");
        try w.writeAll(rst);
        try w.writeAll(if (focused) bwht ++ bold else if (bypassed) red else if (present) grn else dim);
        try w.print(" {s: <7}", .{spectrum_ed.unitLabel(u)});
        try w.writeAll(rst);
        try w.writeAll(if (bypassed) red else if (present) grn else dim);
        try w.writeAll(if (present) "\u{25CF}" else "\u{25CB}");
        try w.writeAll(rst);
        try w.writeAll(if (focused) acc ++ bold ++ "\u{2503}" else dim ++ "\u{2502}");
        try w.writeAll(rst);
    }
    try w.writeAll(dim ++ "\u{2500}\u{25B6} OUT" ++ rst);
    try endLine(w);

    if (!compact) {
        try w.writeAll("       ");
        inline for (0..4) |i| {
            const u: spectrum_ed.FxUnit = @enumFromInt(i);
            const focused = u == app.fx_focus;
            if (i > 0) try w.writeAll("   ");
            try w.writeAll(if (focused) acc ++ bold ++ "\u{2517}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{251B}"
                           else dim ++ "\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}");
            try w.writeAll(rst);
        }
        try endLine(w);
    }
}

pub fn drawFxView(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
    is_track: bool,
) !void {
    _ = snap;

    const title: []const u8 = if (is_track) blk: {
        const name = if (app.eq_track < app.session.project.tracks.items.len)
            app.session.project.tracks.items[app.eq_track].name
        else
            "?";
        break :blk name;
    } else "MASTER";

    const title_icon = if (is_track) icons.eq else icons.master;
    try w.writeAll(bold ++ " " ++ rst);
    try w.writeAll(title_icon);
    try w.writeAll(bold ++ " FX RACK" ++ rst);
    try w.print(" \"{s}\"", .{title});
    try endLine(w);

    // Null only when the viewed track was deleted out from under the view —
    // app.zig's guard kicks back to tracks on the next key; just pad here.
    const chain = spectrum_ed.fxPtr(app, is_track) orelse {
        for (3..@max(3, rows -| 3)) |_| try endLine(w);
        return;
    };

    const compact = spectrum_ed.compactLayout(rows);
    try drawChainStrip(app, w, chain, compact);

    if (!compact) {
        try w.writeAll(dim ++ "  tab/H/L:slot  a:add/remove  h/l:param  j/k:adjust  b:eq bypass" ++ rst);
        try endLine(w);
    }

    const focus = app.fx_focus;
    try synthSection(w, sectionLabel(focus), sectionColor(focus));

    var body_lines: usize = 0;
    switch (focus) {
        .eq => {
            // The EQ slot's editor: live spectrum graph up top, the 10 band
            // bars underneath. The analyzer only runs while this slot has
            // focus (editors/spectrum.zig parks it on focus change).
            const spectrum_snap = if (is_track)
                app.session.engine.trackSpectrumSnapshot(app.eq_track)
            else
                app.session.engine.masterSpectrumSnapshot();

            const bands = spectrum_ed.eqBandRows(chain);
            // Header + strip + hint + section (6; 3 in compact mode) + graph
            // + hz label + band rows must fit in rows-5. usize annotation
            // matters: @min against the comptime spectrum_rows bound
            // otherwise narrows the type to u5, and `visual_rows * 4`
            // overflows it.
            const visual_rows: usize = @min(spectrum_rows, rows -| ((if (compact) @as(usize, 9) else 12) + bands));
            // Limit band count to available horizontal space (6-char dB gutter + bands).
            const draw_bands = @min(spectrum_band_count, cols -| 8);

            const db_range: f32 = 70.0;
            const db_offset: f32 = -60.0;

            // Axis labels sit in the 6-char gutter at their true heights on
            // the dB scale, so bars draw on every row.
            const total_pixels = visual_rows * 4;
            const axis_labels = [_]struct { db: f32, label: []const u8 }{
                .{ .db = 0.0,   .label = "  0dB" },
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
                    const colour: []const u8 = if (row_norm > 0.85) red
                        else if (row_norm > 0.65) yel
                        else grn;
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
                // No snapshot (analyzer idle): leave the graph area blank —
                // endLine clears to the right edge.
                try endLine(w);
            }

            try w.writeAll(dim ++ "Hz    ");
            const freq_labels = [_]struct { idx: usize, label: []const u8 }{
                .{ .idx = 0,  .label = "20"  },
                .{ .idx = 12, .label = "40"  },
                .{ .idx = 24, .label = "80"  },
                .{ .idx = 36, .label = "160" },
                .{ .idx = 48, .label = "320" },
                .{ .idx = 55, .label = "640" },
                .{ .idx = 61, .label = "1.2k"},
                .{ .idx = 67, .label = "2.5k"},
                .{ .idx = 72, .label = "5k"  },
                .{ .idx = 76, .label = "10k" },
                .{ .idx = 78, .label = "20k" },
            };

            // Pad each label out to its target bin (`idx`) by tracked column,
            // not by looping one char per bin — a previous version wrote each
            // label in a single step without advancing the loop past its
            // extra characters, so every label after the first drifted right
            // of its bin and the top "20k" (human hearing's upper edge)
            // always landed past the terminal width and got dropped, even on
            // normal-width terminals with room to spare.
            var col: usize = 0;
            for (freq_labels) |lbl| {
                if (lbl.idx >= draw_bands) continue;
                // Never start before one space past the previous label —
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

            if (chain.eq) |*e| {
                // Bar row: one glyph per band, its height tracking gain (▄ =
                // flat, taller = boost, shorter = cut), coloured by
                // direction/magnitude. The selected band is bracketed.
                try w.writeAll("   ");
                for (0..eq_mod.num_eq_bands) |b| {
                    const is_cur = (b == app.fx_param);
                    const gain = e.bands[b].gain_db;
                    if (is_cur) try w.writeAll(bold ++ acc ++ " [" ++ rst) else try w.writeAll("  ");
                    try w.writeAll(if (is_cur) bwht else eqColor(gain));
                    if (is_cur) try w.writeAll(bold);
                    try w.writeAll(eqGlyph(gain));
                    try w.writeAll(rst);
                    if (is_cur) try w.writeAll(bold ++ acc ++ "] " ++ rst) else try w.writeAll("  ");
                }
                try endLine(w);

                // Value row: signed dB under each bar.
                try w.writeAll("   ");
                for (0..eq_mod.num_eq_bands) |b| {
                    const is_cur = (b == app.fx_param);
                    const val = e.bands[b].gain_db;
                    if (is_cur) try w.writeAll(acc ++ bold);
                    try w.print("{d: ^5.0}", .{val});
                    if (is_cur) try w.writeAll(rst);
                }
                try endLine(w);

                // Frequency row — matches eq_mod.iso_frequencies' order.
                try w.writeAll(dim ++ "   ");
                for (eq_freq_labels) |lbl| try w.print("{s: ^5}", .{lbl});
                try w.writeAll(rst);
                try endLine(w);
            } else {
                try w.writeAll(dim ++ "   no EQ — press 'a' to add" ++ rst);
                try endLine(w);
            }
            body_lines = visual_rows + 1 + bands;
        },
        else => |u| {
            if (spectrum_ed.isPresent(chain, u)) {
                // One synth-editor-style bar per param, filled against the
                // same [min, max] setParam clamps to.
                for (0..spectrum_ed.paramCount(u)) |i| {
                    const is_sel = (i == app.fx_param);
                    const range = spectrum_ed.paramRange(u, i);
                    const v = spectrum_ed.getParam(chain, u, i);
                    const norm = std.math.clamp((v - range[0]) / (range[1] - range[0]), 0.0, 1.0);
                    var vbuf: [16]u8 = undefined;
                    try barRow(w, is_sel, false, sectionColor(u), spectrum_ed.paramName(u, i), norm, 1.0, formatFxValue(&vbuf, u, i, chain));
                }
                body_lines = spectrum_ed.paramCount(u);
            } else {
                try w.writeAll(dim);
                try w.print("   no {s} — press 'a' to add", .{spectrum_ed.unitLabel(u)});
                try w.writeAll(rst);
                try endLine(w);
                body_lines = 1;
            }
        },
    }

    // Pad to fill the view's row budget (rows-5) so the footer stays pinned.
    // lines written: 1 (header) + strip + hint + 1 (section) + body_lines,
    // where strip+hint is 4 rows normally, 1 in compact mode.
    const prelude: usize = if (compact) 3 else 6;
    const used = prelude + 2 + body_lines; // "+2 over lines-written" matches other views
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

/// Formats param `idx` of unit `u` with a unit-appropriate suffix, e.g.
/// "-6.0dB", "4.0:1", "120ms", "35%".
fn formatFxValue(buf: []u8, u: spectrum_ed.FxUnit, idx: usize, fx: *const ws.Fx) []const u8 {
    const v = spectrum_ed.getParam(fx, u, idx);
    return switch (u) {
        .eq => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
        .comp => switch (idx) {
            0, 4 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            1 => std.fmt.bufPrint(buf, "{d:.1}:1", .{v}) catch "?",
            2, 3 => std.fmt.bufPrint(buf, "{d:.0}ms", .{v}) catch "?",
            else => "?",
        },
        .delay => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.0}ms", .{v * 1000.0}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .reverb => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
    };
}

pub fn drawFxStatus(app: anytype, w: *std.Io.Writer, is_track: bool, cmds: []const cmd_mod.Def) !void {
    if (app.modal.mode == .command) {
        try cmd_mod.writePrompt(w, cmds, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor, 60);
        return;
    }
    if (app.modal.mode == .search) {
        try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor);
        return;
    }
    const fx = spectrum_ed.fxPtr(app, is_track) orelse {
        if (app.status_len > 0) try w.print(" {s}", .{app.status_buf[0..app.status_len]});
        return;
    };
    const u = app.fx_focus;
    try w.writeAll(acc ++ sel);
    try w.print(" {s} ", .{spectrum_ed.unitLabel(u)});
    try w.writeAll(rst ++ dim ++ "  " ++ rst);
    if (spectrum_ed.isPresent(fx, u)) {
        switch (u) {
            .eq => {
                const freq = eq_mod.iso_frequencies[app.fx_param];
                const gain = spectrum_ed.getParam(fx, u, app.fx_param);
                const sign: []const u8 = if (gain >= 0) "+" else "";
                try w.print("{d:.0}Hz", .{freq});
                try w.writeAll("  ");
                try w.print("{s}{d:.1}dB", .{ sign, gain });
                if (fx.eq.?.bypass) try w.writeAll("  " ++ red ++ "BYPASS" ++ rst);
            },
            else => {
                var vbuf: [16]u8 = undefined;
                try w.print("{s} {s}", .{ spectrum_ed.paramName(u, app.fx_param), formatFxValue(&vbuf, u, app.fx_param, fx) });
            },
        }
        try w.writeAll(dim ++ "  [" ++ rst);
        try w.print("{d}/{d}", .{ app.fx_param + 1, spectrum_ed.paramCount(u) });
        try w.writeAll(dim ++ "]" ++ rst);
    } else {
        try w.writeAll(dim ++ "not added — press 'a'" ++ rst);
    }
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}
