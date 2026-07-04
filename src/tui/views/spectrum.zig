//! Spectrum + EQ view (track and master) + its status bar.

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

fn brailleBarInv(rem: usize) u21 {
    const bits: u8 = switch (rem) {
        0 => 0b11111111,
        1 => 0b00111111,
        2 => 0b00011011,
        3 => 0b00001001,
        else => 0b00000000,
    };
    return @as(u21, 0x2800) | @as(u21, bits);
}

pub fn drawSpectrumView(
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

    const spectrum_snap = if (is_track)
        app.session.engine.trackSpectrumSnapshot(app.eq_track)
    else
        app.session.engine.masterSpectrumSnapshot();

    // Pre-check whether the EQ row will be drawn so visual_rows can be sized correctly.
    const eq_ptr: ?*eq_mod.GraphicEq = blk: {
        if (is_track) {
            if (app.eq_track >= app.session.racks.items.len) break :blk null;
            if (app.session.racks.items[app.eq_track].fx.eq) |*e| break :blk e;
            break :blk null;
        }
        if (app.session.master_fx.eq) |*e| break :blk e;
        break :blk null;
    };
    const has_eq = eq_ptr != null;
    const eq_row: usize = if (has_eq) 1 else 0;
    // Master-only read-only compressor readout (no visual editor yet — see
    // `:master-comp`).
    const has_comp = !is_track and app.session.master_fx.comp != null;
    const comp_row: usize = if (has_comp) 2 else 0;

    // 1 header + visual_rows spectrum + 1 hz label + eq_row/comp_row must fit in rows-5.
    const visual_rows = @min(spectrum_rows, rows -| (7 + eq_row + comp_row));
    // Limit band count to available horizontal space (3-char indent + bands).
    const draw_bands = @min(spectrum_band_count, cols -| 5);

    const db_range: f32 = 70.0;
    const db_offset: f32 = -60.0;

    const title_icon = if (is_track) icons.eq else icons.master;
    try w.writeAll(bold ++ " " ++ rst);
    try w.writeAll(title_icon);
    try w.writeAll(bold ++ " SPECTRUM" ++ rst);
    try w.print(" \"{s}\"", .{title});
    try endLine(w);

    for (0..visual_rows) |visual_row_inv| {
        const visual_row = visual_rows - 1 - visual_row_inv;

        try w.writeAll(dim ++ "   " ++ rst);

        if (visual_row == visual_rows - 1) {
            try w.writeAll(dim ++ " 0dB");
            try endLine(w);
            continue;
        }
        if (visual_row == visual_rows - 2) {
            try w.writeAll(dim ++ " -6dB");
            try endLine(w);
            continue;
        }
        if (visual_row == visual_rows - 3) {
            try w.writeAll(dim ++ "-12dB");
            try endLine(w);
            continue;
        }

        if (spectrum_snap) |ssnap| {
            for (0..draw_bands) |band| {
                const db_val = ssnap.bins[band];
                const raw = (db_val - db_offset) / db_range;
                const norm = if (std.math.isNan(raw)) 0.0 else std.math.clamp(raw, 0.0, 1.0);
                const total_pixels = @as(u32, @intCast(visual_rows)) * 4;
                const pixel_height = @as(usize, @intFromFloat(norm * @as(f32, @floatFromInt(total_pixels))));

                const pixel_start = (visual_rows - 1 - visual_row) * 4;
                const rem = if (pixel_height > pixel_start)
                    @min(pixel_height - pixel_start, 4)
                else
                    0;

                // colour by level: top rows are louder
                const row_norm: f32 = @as(f32, @floatFromInt(visual_rows - 1 - visual_row)) /
                    @as(f32, @floatFromInt(visual_rows));
                const colour: []const u8 = if (row_norm > 0.85) red
                    else if (row_norm > 0.65) yel
                    else grn;
                try w.writeAll(if (rem > 0) colour else dim);

                const ch = brailleBarInv(rem);
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(ch, &utf8_buf) catch unreachable;
                try w.writeAll(utf8_buf[0..utf8_len]);
                try w.writeAll(rst);
            }
        } else {
            try w.writeAll(dim);
            for (0..draw_bands) |_| {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(brailleBarInv(0), &utf8_buf) catch unreachable;
                try w.writeAll(utf8_buf[0..utf8_len]);
            }
        }
        try endLine(w);
    }

    try w.writeAll(dim ++ "Hz   ");
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

    var fi: usize = 0;
    for (0..draw_bands) |band| {
        if (fi < freq_labels.len and band == freq_labels[fi].idx) {
            const label = freq_labels[fi].label;
            if (band + label.len < draw_bands) {
                try w.writeAll(label);
                fi += 1;
            } else {
                try w.writeByte(' ');
            }
        } else {
            try w.writeByte(' ');
        }
    }
    try endLine(w);

    if (eq_ptr) |e| {
        const bypass_str: []const u8 = if (e.bypass) " [BYPASS]" else "";
        try w.writeAll(bold ++ " EQ" ++ rst);
        try w.writeAll(red);
        try w.writeAll(bypass_str);
        try w.writeAll(rst ++ "  ");
        for (0..eq_mod.num_eq_bands) |b| {
            const is_cur = (b == app.eq_cursor);
            const val = e.bands[b].gain_db;
            if (is_cur) try w.writeAll(acc ++ bold);
            const marker: []const u8 = if (is_cur) ">" else " ";
            try w.print("{s}{d: <4.0}", .{ marker, val });
            if (is_cur) try w.writeAll(rst);
        }
        try endLine(w);
    }

    if (has_comp) {
        const c = &app.session.master_fx.comp.?;
        try w.writeAll(bold ++ " COMP" ++ rst ++ dim ++ "  (:master-comp to adjust)" ++ rst);
        try endLine(w);
        try w.print("   thresh {d: <5.0}dB  ratio {d: <4.1}:1  atk {d: <4.0}ms  rel {d: <4.0}ms  makeup {d: <4.1}dB", .{
            c.threshold_db, c.ratio, c.attack_ms, c.release_ms, c.makeup_db,
        });
        try endLine(w);
    }

    // Pad to fill the view's row budget (rows-5) so the footer stays pinned.
    // lines written: 1 (header) + visual_rows + 1 (hz label) + eq_row + comp_row
    const used = 4 + visual_rows + eq_row + comp_row; // "+2 over lines-written" matches other views
    for (used..@max(used, rows -| 3)) |_| try endLine(w);
}

pub fn drawSpectrumStatus(app: anytype, w: *std.Io.Writer, is_track: bool, cmds: []const cmd_mod.Def) !void {
    if (app.modal.mode == .command) {
        try cmd_mod.writePrompt(w, cmds, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor, 60);
        return;
    }
    const eq_ptr: ?*eq_mod.GraphicEq = blk: {
        if (is_track) {
            if (app.eq_track >= app.session.racks.items.len) break :blk null;
            if (app.session.racks.items[app.eq_track].fx.eq) |*e| break :blk e;
            break :blk null;
        }
        if (app.session.master_fx.eq) |*e| break :blk e;
        break :blk null;
    };
    if (eq_ptr) |e| {
        const freq = eq_mod.iso_frequencies[app.eq_cursor];
        const gain = e.bands[app.eq_cursor].gain_db;
        const sign: []const u8 = if (gain >= 0) "+" else "";
        try w.writeAll(acc ++ sel ++ " EQ " ++ rst);
        try w.writeAll(dim ++ "  " ++ rst);
        try w.print("{d:.0}Hz", .{freq});
        try w.writeAll("  ");
        try w.print("{s}{d:.1}dB", .{ sign, gain });
        try w.writeAll(dim ++ "  [" ++ rst);
        try w.print("{d}/{d}", .{app.eq_cursor + 1, eq_mod.num_eq_bands});
        try w.writeAll(dim ++ "]" ++ rst);
        if (e.bypass) {
            try w.writeAll("  " ++ red ++ "BYPASS" ++ rst);
        }
        if (app.status_len > 0) {
            try w.writeAll(dim ++ "  " ++ rst);
            try w.writeAll(app.status_buf[0..app.status_len]);
        }
        return;
    }
    if (app.status_len > 0) {
        try w.print(" {s}", .{app.status_buf[0..app.status_len]});
    }
}

