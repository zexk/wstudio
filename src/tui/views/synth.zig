//! Synth editor view, its row primitives, and its status bar.

const std = @import("std");
const ws = @import("wstudio");
const types = ws.types;
const Project = ws.Project;
const Transport = ws.Transport;
const DrumMachine = ws.dsp.DrumMachine;
const eq_mod = ws.dsp.eq;
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

const synth_ed = @import("../editors/synth.zig");

/// Render the synth editor into `w`, applying vertical scroll so it fits
/// within `max_rows`. Always shows the title line, then slices the parameter
/// body to keep the cursor in view. Wide terminals (synth_ed.twoCol) get an
/// A/B-over-C layout: OSC A and OSC B side by side on top (osc-specific
/// params), then every other, non-oscillator section stacked full-width
/// beneath (see synth_ed.body_rows_wide); narrow terminals keep the plain
/// single-column stack.
pub fn drawSynthEditor(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    // Available rows for the view body (excludes the caller's header +
    // transport + status — 4 rows total, no separate hr() rule rows anymore).
    const max_rows = rows -| 4;
    const two_col = synth_ed.twoCol(cols);

    // Stretch the param bars (and the section rules with them) into free
    // width — single-column mode gets at most a few extra cells before the
    // wide layout takes over at 108. The wide layout sets its own widths
    // per block below (narrower for the OSC A/B top block, full-width for
    // the stacked section beneath). The knobs were reset to the compact
    // defaults by App.draw.
    const col_w = synth_ed.colWidth(cols);
    if (!two_col) {
        style.form_bar_w = @min(style.form_bar_w_default + (cols -| 100) / 2, 40);
        style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);
    }

    // Clamp scroll so the cursor row is visible and the window never runs
    // past the layout's last row (the two layouts' heights differ, so a
    // stale offset from the other mode must not survive a resize).
    const cursor_row = if (two_col) synth_ed.paramColRow(app.synth_cursor).row else synth_ed.paramRow(app.synth_cursor);
    const body_rows: usize = if (two_col) synth_ed.body_rows_wide else synth_ed.body_rows_single;
    var scroll = @min(app.synth_scroll, (body_rows + 1) -| max_rows);
    if (cursor_row < scroll) scroll = cursor_row;
    if (cursor_row >= scroll + max_rows) scroll = cursor_row -| max_rows + 1;
    // Written back so mouse hit-testing (editors/synth.zig paramAtRow) maps
    // clicks through the same offset this frame actually rendered with.
    app.synth_scroll = scroll;

    if (app.synth_track >= app.session.racks.items.len) {
        for (0..max_rows) |_| try endLine(w);
        return;
    }
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => {
            for (0..max_rows) |_| try endLine(w);
            return;
        },
    }
    const synth = &rack.instrument.poly_synth;
    const c = app.synth_cursor;

    // zig fmt: off
    const name = if (app.synth_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.synth_track].name
    else "?";
    // zig fmt: on

    // Title (row 0) — always emitted, outside the scroll window.
    try w.writeAll(bcyn ++ bold ++ " \u{2593} " ++ icons.synth ++ " SYNTH " ++ rst);
    try w.writeAll(acc);
    try w.print("\"{s}\"", .{name});
    try w.writeAll(rst);
    try endLine(w);
    var written: usize = 1;

    // Render the body into temp buffers, then slice out the visible rows.
    // Each copied line gets its own explicit \x1b[K clear (endLine) rather
    // than relying on the source line's own embedded one: splitSequence
    // yields one trailing EMPTY segment when a buffer ends with the "\r\n"
    // delimiter (it always does, since every source line ends via endLine),
    // and that empty segment has no embedded clear code of its own —
    // without this, scrolling to the exact end of the param list left stale
    // text from a previous frame's different scroll position visible on
    // that row.
    if (two_col) {
        // Top block: OSC A / OSC B side by side, bars scaled to half-width.
        style.form_bar_w = @min(style.form_bar_w_default + (col_w -| 56), 40);
        style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);
        var tmp_l: [16 * 1024]u8 = undefined;
        var wl = std.Io.Writer.fixed(&tmp_l);
        try secOscA(&wl, synth, c);
        var tmp_r: [16 * 1024]u8 = undefined;
        var wr = std.Io.Writer.fixed(&tmp_r);
        try secOscB(&wr, synth, c);

        // Bottom block: every non-oscillator section, stacked full-width.
        style.form_bar_w = @min(style.form_bar_w_default + (cols -| 100) / 2, 40);
        style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);
        var tmp_b: [16 * 1024]u8 = undefined;
        var wb = std.Io.Writer.fixed(&tmp_b);
        try drawSynthBottom(&wb, synth, c);

        var it_l = std.mem.splitSequence(u8, wl.buffered(), "\r\n");
        var it_r = std.mem.splitSequence(u8, wr.buffered(), "\r\n");
        var it_b = std.mem.splitSequence(u8, wb.buffered(), "\r\n");
        var row: usize = 1;
        while (row <= synth_ed.body_rows_wide) : (row += 1) {
            const in_top = row <= synth_ed.top_h;
            const ll = if (in_top) it_l.next() orelse "" else "";
            const rl = if (in_top) it_r.next() orelse "" else "";
            const bl = if (!in_top) it_b.next() orelse "" else "";
            if (written >= max_rows) break;
            if (row < scroll + 1) continue;
            if (in_top) {
                try style.writePadded(w, ll, col_w);
                try style.writeClamped(w, rl, cols -| col_w);
            } else {
                try w.writeAll(bl);
            }
            try endLine(w);
            written += 1;
        }
    } else {
        // Original single-column section order (paramRow's row map).
        var tmp: [16 * 1024]u8 = undefined;
        var tw = std.Io.Writer.fixed(&tmp);
        try secOscA(&tw, synth, c);
        try secOscB(&tw, synth, c);
        try secMod(&tw, synth, c);
        try secEnv(&tw, synth, c);
        try secFilter(&tw, synth, c);
        try secFenv(&tw, synth, c);
        try secLfo(&tw, synth, c);
        try secVoice(&tw, synth, c);
        try secSub(&tw, synth, c);
        try secNoise(&tw, synth, c);
        try secOut(&tw, synth, c);
        try secUniMode(&tw, synth, c);
        try secWarp(&tw, synth, c);
        try secFilter2(&tw, synth, c);
        try secOscC(&tw, synth, c);
        try secMatrix(&tw, synth, c);
        try secFxDist(&tw, synth, c);
        try secFxCrush(&tw, synth, c);
        try secFxFlanger(&tw, synth, c);
        try secLfo2(&tw, synth, c);
        try secLfo3(&tw, synth, c);
        try secMacro(&tw, synth, c);
        try secFxPhaser(&tw, synth, c);

        var line_it = std.mem.splitSequence(u8, tw.buffered(), "\r\n");
        var row: usize = 1;
        while (line_it.next()) |line| : (row += 1) {
            if (written >= max_rows) break;
            if (row < scroll + 1) continue;
            try w.writeAll(line);
            try endLine(w);
            written += 1;
        }
    }
    while (written < max_rows) : (written += 1) try endLine(w);
}

// The section renderers below emit one header row + one row per param each.
// The wide layout's OSC A/B top block + drawSynthBottom's order is mirrored
// by editors/synth.zig's paramColRow, the single-column order (in
// drawSynthEditor's else-branch above) by its paramRow — keep renderers and
// row maps in sync.

/// Every non-oscillator section, stacked full-width beneath OSC A/B in the
/// wide layout (body_rows_wide - top_h rows; the MATRIX section is the big
/// one at 25). OSC C is 3rd-oscillator content but lives here (not the top
/// A/B block) since the wide layout's top block is a fixed 2-column split —
/// see body_rows_wide's own history for why a 3-column top block was skipped.
fn drawSynthBottom(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    try secMod(w, synth, c);
    try secEnv(w, synth, c);
    try secFilter(w, synth, c);
    try secFenv(w, synth, c);
    try secLfo(w, synth, c);
    try secVoice(w, synth, c);
    try secSub(w, synth, c);
    try secNoise(w, synth, c);
    try secOut(w, synth, c);
    try secUniMode(w, synth, c);
    try secWarp(w, synth, c);
    try secFilter2(w, synth, c);
    try secOscC(w, synth, c);
    try secMatrix(w, synth, c);
    try secFxDist(w, synth, c);
    try secFxCrush(w, synth, c);
    try secFxFlanger(w, synth, c);
    try secLfo2(w, synth, c);
    try secLfo3(w, synth, c);
    try secMacro(w, synth, c);
    try secFxPhaser(w, synth, c);
}

const wf_names = [_][]const u8{ "sine", "saw", "tri", "sqr" };

fn secOscA(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC A", acc);

    // zig fmt: off
    const wf_idx: usize = switch (synth.waveform) {
        .sine => 0, .saw => 1, .triangle => 2, .square => 3,
    };
    try enumRow(w, c == 0, false, acc, "waveform", &wf_names, wf_idx);

    // param 1: pulse width (only meaningful for square)
    try barRow(w, c == 1, synth.waveform != .square, acc, "pls.width", synth.pulse_width, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.pulse_width}));

    // params 2–5: detune, unison, uni.det, spread
    try barRow(w, c == 2, false, acc, "detune", synth.detune_cents + 100.0, 200.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ct", .{synth.detune_cents}));
    try barRow(w, c == 3, false, acc, "unison", @floatFromInt(synth.unison), 16.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.unison}));
    try barRow(w, c == 4, false, acc, "uni.det", synth.unison_detune, 100.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ct", .{synth.unison_detune}));
    try barRow(w, c == 5, false, acc, "spread", synth.unison_spread, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.unison_spread}));
}
// zig fmt: on

fn secOscB(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC B", acc);

    const b_on = synth.osc_b_on;
    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 6, false, acc, "on/off", &on_names, if (b_on) 0 else 1);

    // zig fmt: off
    const wfb_idx: usize = switch (synth.osc_b_waveform) {
        .sine => 0, .saw => 1, .triangle => 2, .square => 3,
    };
    try enumRow(w, c == 7, !b_on, acc, "waveform", &wf_names, wfb_idx);

    try barRow(w, c == 8, !b_on, acc, "pls.width", synth.osc_b_pulse_width, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_pulse_width}));
    try barRow(w, c == 9, !b_on, acc, "semi", synth.osc_b_semi + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.0}", .{synth.osc_b_semi}));
    try barRow(w, c == 10, !b_on, acc, "detune", synth.osc_b_detune_cents + 100.0, 200.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ct", .{synth.osc_b_detune_cents}));
    try barRow(w, c == 11, !b_on, acc, "level", synth.osc_b_level, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_level}));
    try barRow(w, c == 12, !b_on, acc, "unison", @floatFromInt(synth.osc_b_unison), 16.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.osc_b_unison}));
    try barRow(w, c == 13, !b_on, acc, "uni.det", synth.osc_b_unison_detune, 100.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ct", .{synth.osc_b_unison_detune}));
}

fn secMod(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "MOD  (A \u{2194} B)", mag);

    const mod_on = synth.mod_mode != .none;
    const mod_names = [_][]const u8{ "off", "ring", "AM>B", "AM>A", "FM>B", "FM>A" };
    const mod_idx: usize = switch (synth.mod_mode) {
        .none => 0, .ring => 1, .am_a_to_b => 2, .am_b_to_a => 3,
        .fm_a_to_b => 4, .fm_b_to_a => 5,
    };
    try enumRow(w, c == 14, false, mag, "mode", &mod_names, mod_idx);

    {
        const is_fm = switch (synth.mod_mode) { .fm_a_to_b, .fm_b_to_a => true, else => false };
        const vs = if (is_fm)
            try std.fmt.bufPrint(&buf, "\u{03B2}={d:.2}", .{synth.mod_amount})
        else
            try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.mod_amount});
        try barRow(w, c == 15, !mod_on, mag, "amount", synth.mod_amount, 8.0, vs);
    }
}

fn secEnv(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "ENV", grn);

    try barRow(w, c == 16, false, grn, "attack", synth.attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.attack_s}));
    try barRow(w, c == 17, false, grn, "decay", synth.decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.decay_s}));
    try barRow(w, c == 18, false, grn, "sustain", synth.sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.sustain}));
    try barRow(w, c == 19, false, grn, "release", synth.release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.release_s}));
}

const filter_type_names = [_][]const u8{ "lp", "hp", "bp", "ntch", "ladr", "comb" };

fn filterTypeIdx(ft: anytype) usize {
    return switch (ft) { .lp => 0, .hp => 1, .bp => 2, .notch => 3, .ladder => 4, .comb => 5 };
}

fn filterTypeName(ft: anytype) []const u8 {
    return switch (ft) { .lp => "lp", .hp => "hp", .bp => "bp", .notch => "notch", .ladder => "ladder", .comb => "comb" };
}

fn secFilter(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER", yel);

    try enumRow(w, c == 20, false, yel, "type", &filter_type_names, filterTypeIdx(synth.filter_type));

    {
        const log_norm = std.math.log2(synth.filter_cutoff / 20.0) /
            std.math.log2(20_000.0 / 20.0);
        const vs = if (synth.filter_cutoff >= 1_000.0)
            try std.fmt.bufPrint(&buf, "{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.filter_cutoff});
        try barRow(w, c == 21, false, yel, "cutoff", log_norm, 1.0, vs);
    }
    try barRow(w, c == 22, false, yel, "res", synth.filter_res, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.filter_res}));
}

fn secFenv(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FENV", grn);

    try barRow(w, c == 24, false, grn, "f.attack", synth.fenv_attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_attack_s}));
    try barRow(w, c == 25, false, grn, "f.decay", synth.fenv_decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_decay_s}));
    try barRow(w, c == 26, false, grn, "f.sustain", synth.fenv_sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.fenv_sustain}));
    try barRow(w, c == 27, false, grn, "f.release", synth.fenv_release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_release_s}));
}

const lfo_shape_names = [_][]const u8{ "sine", "tri", "saw", "sqr", "s&h" };

fn lfoShapeIdx(shape: anytype) usize {
    return switch (shape) { .sine => 0, .triangle => 1, .saw => 2, .square => 3, .sh => 4 };
}

fn lfoShapeName(shape: anytype) []const u8 {
    return switch (shape) { .sine => "sine", .triangle => "tri", .saw => "saw", .square => "sqr", .sh => "s&h" };
}

/// Shape + rate only: the LFO is a pure mod source, its routing lives on
/// MATRIX rows (the matrix absorbed the old depth/target params).
fn secLfo(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "LFO", mag);

    try enumRow(w, c == 28, false, mag, "shape", &lfo_shape_names, lfoShapeIdx(synth.lfo_shape));

    try barRow(w, c == 29, false, mag, "rate", synth.lfo_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.lfo_rate_hz}));
}

/// LFO 2/3: trailing sections (ids append after the current max — see
/// PolySynth's stable-id rule) even though they belong beside LFO 1.
fn secLfo2(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "LFO 2", mag);
    try enumRow(w, c == 95, false, mag, "shape", &lfo_shape_names, lfoShapeIdx(synth.lfo2_shape));
    try barRow(w, c == 96, false, mag, "rate", synth.lfo2_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.lfo2_rate_hz}));
}

fn secLfo3(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "LFO 3", mag);
    try enumRow(w, c == 97, false, mag, "shape", &lfo_shape_names, lfoShapeIdx(synth.lfo3_shape));
    try barRow(w, c == 98, false, mag, "rate", synth.lfo3_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.lfo3_rate_hz}));
}

/// Four macro knobs — pure mod sources (mc1-mc4 on MATRIX rows), no sound
/// of their own, automatable as ids 99-102.
fn secMacro(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "MACRO", bcyn);
    const vals = [4]f32{ synth.macro1, synth.macro2, synth.macro3, synth.macro4 };
    for (vals, 0..) |v, k| {
        var lbl: [12]u8 = undefined;
        try barRow(w, c == 99 + @as(u8, @intCast(k)), false, bcyn,
            try std.fmt.bufPrint(&lbl, "macro {d}", .{k + 1}), v, 1.0,
            try std.fmt.bufPrint(&buf, "{d:.2}", .{v}));
    }
}

fn secVoice(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "VOICE", blu);

    const vm_names = [_][]const u8{ "poly", "mono", "lgto" };
    const vm_idx: usize = switch (synth.voice_mode) {
        .poly => 0, .mono => 1, .legato => 2,
    };
    try enumRow(w, c == 32, false, blu, "mode", &vm_names, vm_idx);

    try barRow(w, c == 33, false, blu, "glide", synth.glide_s, 10.0,
        if (synth.glide_s == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.glide_s}));
}

fn secSub(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "SUB", acc);

    try barRow(w, c == 34, false, acc, "level", synth.sub_level, 1.0,
        if (synth.sub_level == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.sub_level}));
    {
        const sh_names = [_][]const u8{ "sine", "sqr" };
        const sh_idx: usize = switch (synth.sub_shape) { .sine => 0, .square => 1 };
        try enumRow(w, c == 35, synth.sub_level == 0.0, acc, "shape", &sh_names, sh_idx);
    }
}

fn secNoise(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "NOISE", acc);

    try barRow(w, c == 36, false, acc, "level", synth.noise_level, 1.0,
        if (synth.noise_level == 0.0) "off" else try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.noise_level}));
    {
        const hint: []const u8 = if (synth.noise_color < 0.33) "dark"
            else if (synth.noise_color > 0.66) "white" else "warm";
        try barRow(w, c == 37, synth.noise_level == 0.0, acc, "color", synth.noise_color, 1.0,
            try std.fmt.bufPrint(&buf, "{d:.2}  {s}", .{ synth.noise_color, hint }));
    }
}

fn secOut(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OUT", bcyn);

    try barRow(w, c == 38, false, bcyn, "gain", synth.gain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.gain}));
}

const uni_mode_names = [_][]const u8{ "spread", "step", "harm", "ratio" };

fn uniModeIdx(mode: anytype) usize {
    return switch (mode) { .spread => 0, .step => 1, .harmonic => 2, .ratio => 3 };
}

fn uniModeName(mode: anytype) []const u8 {
    return switch (mode) { .spread => "spread", .step => "step", .harmonic => "harmonic", .ratio => "ratio" };
}

fn secUniMode(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    try synthSection(w, "UNI MODE", acc);

    try enumRow(w, c == 39, synth.unison <= 1, acc, "osc a", &uni_mode_names, uniModeIdx(synth.unison_mode));
    try enumRow(w, c == 40, !synth.osc_b_on or synth.osc_b_unison <= 1, acc, "osc b", &uni_mode_names, uniModeIdx(synth.osc_b_unison_mode));
}

const warp_mode_names = [_][]const u8{ "none", "bend", "mirror", "sync" };

fn secWarp(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "WARP", acc);

    const a_idx: usize = switch (synth.warp_mode) {
        .none => 0, .bend => 1, .mirror => 2, .sync => 3,
    };
    try enumRow(w, c == 41, false, acc, "osc a", &warp_mode_names, a_idx);
    try barRow(w, c == 42, synth.warp_mode == .none, acc, "amt a", synth.warp_amount, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.warp_amount}));

    const b_idx: usize = switch (synth.osc_b_warp_mode) {
        .none => 0, .bend => 1, .mirror => 2, .sync => 3,
    };
    try enumRow(w, c == 43, !synth.osc_b_on, acc, "osc b", &warp_mode_names, b_idx);
    try barRow(w, c == 44, !synth.osc_b_on or synth.osc_b_warp_mode == .none, acc, "amt b", synth.osc_b_warp_amount, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_warp_amount}));
}

fn secFilter2(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER 2", yel);

    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 45, false, yel, "on/off", &on_names, if (synth.filter2_on) 0 else 1);

    const on = synth.filter2_on;
    try enumRow(w, c == 46, !on, yel, "type", &filter_type_names, filterTypeIdx(synth.filter2_type));

    {
        const log_norm = std.math.log2(synth.filter2_cutoff / 20.0) /
            std.math.log2(20_000.0 / 20.0);
        const vs = if (synth.filter2_cutoff >= 1_000.0)
            try std.fmt.bufPrint(&buf, "{d:.2} kHz", .{synth.filter2_cutoff / 1_000.0})
        else
            try std.fmt.bufPrint(&buf, "{d:.0} Hz", .{synth.filter2_cutoff});
        try barRow(w, c == 47, !on, yel, "cutoff", log_norm, 1.0, vs);
    }
    try barRow(w, c == 48, !on, yel, "res", synth.filter2_res, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.filter2_res}));

    const routing_names = [_][]const u8{ "series", "parallel" };
    const routing_idx: usize = switch (synth.filter_routing) { .series => 0, .parallel => 1 };
    try enumRow(w, c == 49, !on, yel, "routing", &routing_names, routing_idx);
}

/// Plain additive 3rd oscillator — same row shape as OSC B, no mod/warp rows
/// since OSC C doesn't participate in either (see PolySynth's own doc comment).
fn secOscC(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC C", acc);

    const c_on = synth.osc_c_on;
    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 50, false, acc, "on/off", &on_names, if (c_on) 0 else 1);

    const wfc_idx: usize = switch (synth.osc_c_waveform) {
        .sine => 0, .saw => 1, .triangle => 2, .square => 3,
    };
    try enumRow(w, c == 51, !c_on, acc, "waveform", &wf_names, wfc_idx);

    try barRow(w, c == 52, !c_on, acc, "pls.width", synth.osc_c_pulse_width, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_c_pulse_width}));
    try barRow(w, c == 53, !c_on, acc, "semi", synth.osc_c_semi + 24.0, 48.0,
        try std.fmt.bufPrint(&buf, "{d:.0}", .{synth.osc_c_semi}));
    try barRow(w, c == 54, !c_on, acc, "detune", synth.osc_c_detune_cents + 100.0, 200.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ct", .{synth.osc_c_detune_cents}));
    try barRow(w, c == 55, !c_on, acc, "level", synth.osc_c_level, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_c_level}));
    try barRow(w, c == 56, !c_on, acc, "unison", @floatFromInt(synth.osc_c_unison), 16.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.osc_c_unison}));
    try barRow(w, c == 57, !c_on, acc, "uni.det", synth.osc_c_unison_detune, 100.0,
        try std.fmt.bufPrint(&buf, "{d:.1} ct", .{synth.osc_c_unison_detune}));

    try enumRow(w, c == 58, !c_on or synth.osc_c_unison <= 1, acc, "uni.mode", &uni_mode_names, uniModeIdx(synth.osc_c_unison_mode));
}

const mod_src_names = [_][]const u8{ "off", "lfo", "fenv", "aenv", "vel", "key", "whl", "lfo2", "lfo3", "mc1", "mc2", "mc3", "mc4" };

fn modSrcIdx(src: anytype) usize {
    return @intFromEnum(src);
}

/// 8 mod-matrix rows, 3 editor rows each (source / dest / depth). Dest and
/// depth dim while the row's source is off, mirroring the on/off gating the
/// oscillator sections use.
fn secMatrix(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "MATRIX", mag);

    for (synth.mod_matrix, 0..) |row, k| {
        const base: u8 = @intCast(59 + k * 3);
        const off = row.source == .none;
        var lbl: [12]u8 = undefined;

        // Value-only like the dest row beneath (not an enumRow menu): 13
        // sources at enumRow's 7 cells each would wrap the 80-col minimum.
        const src_lbl = try std.fmt.bufPrint(&lbl, "{d} source", .{k + 1});
        try rowHead(w, c == base, false, src_lbl);
        try rowVal(w, c == base, false, mod_src_names[modSrcIdx(row.source)]);
        try endLine(w);

        const dst_lbl = try std.fmt.bufPrint(&lbl, "{d} dest", .{k + 1});
        try rowHead(w, c == base + 1, off, dst_lbl);
        try rowVal(w, c == base + 1, off, ws.dsp.PolySynth.modDestLabel(row.dest));
        try endLine(w);

        const dep_lbl = try std.fmt.bufPrint(&lbl, "{d} depth", .{k + 1});
        const sign: []const u8 = if (row.depth >= 0.0) "+" else "";
        try barRow(w, c == base + 2, off, mag, dep_lbl, row.depth + 1.0, 2.0,
            try std.fmt.bufPrint(&buf, "{s}{d:.2}", .{ sign, row.depth }));
    }
}

const on_off_names = [_][]const u8{ "on", "off" };

/// Internal FX sections: post-mix dist → crush → flanger inside the synth
/// itself, distinct from the track FX chain — these params are matrix and
/// automation targets (see PolySynth's FX field block).
fn secFxDist(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX DIST", red);

    const on = synth.fx_dist_on;
    try enumRow(w, c == 83, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 84, !on, red, "drive", synth.fx_dist_drive_db, 36.0,
        try std.fmt.bufPrint(&buf, "{d:.1} dB", .{synth.fx_dist_drive_db}));
    try barRow(w, c == 85, !on, red, "mix", synth.fx_dist_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_dist_mix}));
}

fn secFxCrush(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX CRUSH", red);

    const on = synth.fx_crush_on;
    try enumRow(w, c == 86, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 87, !on, red, "bits", synth.fx_crush_bits, 16.0,
        try std.fmt.bufPrint(&buf, "{d:.0}", .{synth.fx_crush_bits}));
    try barRow(w, c == 88, !on, red, "rate", synth.fx_crush_rate, 64.0,
        try std.fmt.bufPrint(&buf, "1/{d:.0}", .{synth.fx_crush_rate}));
    try barRow(w, c == 89, !on, red, "mix", synth.fx_crush_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_crush_mix}));
}

fn secFxFlanger(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX FLNG", red);

    const on = synth.fx_flanger_on;
    try enumRow(w, c == 90, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 91, !on, red, "rate", synth.fx_flanger_rate_hz, 8.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.fx_flanger_rate_hz}));
    try barRow(w, c == 92, !on, red, "depth", synth.fx_flanger_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_flanger_depth}));
    try barRow(w, c == 93, !on, red, "feedback", synth.fx_flanger_feedback, 0.95,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_flanger_feedback}));
    try barRow(w, c == 94, !on, red, "mix", synth.fx_flanger_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_flanger_mix}));
}

fn secFxPhaser(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FX PHSR", red);

    const on = synth.fx_phaser_on;
    try enumRow(w, c == 103, false, red, "on/off", &on_off_names, if (on) 0 else 1);
    try barRow(w, c == 104, !on, red, "rate", synth.fx_phaser_rate_hz, 8.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.fx_phaser_rate_hz}));
    try barRow(w, c == 105, !on, red, "depth", synth.fx_phaser_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_phaser_depth}));
    try barRow(w, c == 106, !on, red, "feedback", synth.fx_phaser_feedback, 0.95,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_phaser_feedback}));
    try barRow(w, c == 107, !on, red, "mix", synth.fx_phaser_mix, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.fx_phaser_mix}));
}

pub fn drawSynthStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) { .poly_synth => {}, else => return }
    const synth = &rack.instrument.poly_synth;

    // Ids 23/30/31 are retired (absorbed into the matrix) and never land
    // under the cursor — their entries are placeholders keeping the array
    // aligned with param ids.
    const labels = [_][]const u8{
        "waveform", "pls.width", "detune", "unison", "uni.det", "spread",
        "b.on", "b.waveform", "b.pw", "b.semi", "b.detune", "b.level", "b.unison", "b.uni.det",
        "mod.mode", "mod.amount",
        "attack", "decay", "sustain", "release",
        "filt.type", "cutoff", "res", "-",
        "f.attack", "f.decay", "f.sustain", "f.release",
        "lfo.shape", "lfo.rate", "-", "-",
        "voice.mode", "glide",
        "sub.level", "sub.shape",
        "noise.level", "noise.color",
        "gain",
        "uni.mode a", "uni.mode b",
        "warp.mode a", "warp.amt a", "warp.mode b", "warp.amt b",
        "filt2.on", "filt2.type", "filt2.cutoff", "filt2.res", "filt2.routing",
        "c.on", "c.waveform", "c.pw", "c.semi", "c.detune", "c.level", "c.unison", "c.uni.det", "c.uni.mode",
        "mtx1.src", "mtx1.dest", "mtx1.depth", "mtx2.src", "mtx2.dest", "mtx2.depth",
        "mtx3.src", "mtx3.dest", "mtx3.depth", "mtx4.src", "mtx4.dest", "mtx4.depth",
        "mtx5.src", "mtx5.dest", "mtx5.depth", "mtx6.src", "mtx6.dest", "mtx6.depth",
        "mtx7.src", "mtx7.dest", "mtx7.depth", "mtx8.src", "mtx8.dest", "mtx8.depth",
        "dist.on", "dist.drive", "dist.mix",
        "crush.on", "crush.bits", "crush.rate", "crush.mix",
        "flng.on", "flng.rate", "flng.depth", "flng.fdbk", "flng.mix",
        "lfo2.shape", "lfo2.rate", "lfo3.shape", "lfo3.rate",
        "macro 1", "macro 2", "macro 3", "macro 4",
        "phsr.on", "phsr.rate", "phsr.depth", "phsr.fdbk", "phsr.mix",
    };
    const cur = @min(@as(usize, app.synth_cursor), labels.len - 1);
    try style.writeModeBadge(w, app.modal.mode);
    try style.writeViewBadge(right, "SYNTH", app.modal.mode);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(labels[cur]);
    try w.writeAll(dim ++ ": " ++ rst);
    try w.writeAll(acc);
    switch (app.synth_cursor) {
        0  => try w.writeAll(switch (synth.waveform) {
            .sine => "sine", .saw => "saw", .triangle => "tri", .square => "sqr",
        }),
        1  => try w.print("{d:.2}",       .{synth.pulse_width}),
        2  => try w.print("{d:.0} ct",    .{synth.detune_cents}),
        3  => try w.print("{d}",           .{synth.unison}),
        4  => try w.print("{d:.1} ct",    .{synth.unison_detune}),
        5  => try w.print("{d:.2}",       .{synth.unison_spread}),
        6  => try w.writeAll(if (synth.osc_b_on) "on" else "off"),
        7  => try w.writeAll(switch (synth.osc_b_waveform) {
            .sine => "sine", .saw => "saw", .triangle => "tri", .square => "sqr",
        }),
        8  => try w.print("{d:.2}",       .{synth.osc_b_pulse_width}),
        9  => try w.print("{d:.0} st",    .{synth.osc_b_semi}),
        10 => try w.print("{d:.0} ct",    .{synth.osc_b_detune_cents}),
        11 => try w.print("{d:.2}",       .{synth.osc_b_level}),
        12 => try w.print("{d}",           .{synth.osc_b_unison}),
        13 => try w.print("{d:.1} ct",    .{synth.osc_b_unison_detune}),
        14 => try w.writeAll(switch (synth.mod_mode) {
            .none => "off", .ring => "ring",
            .am_a_to_b => "AM A\u{2192}B", .am_b_to_a => "AM B\u{2192}A",
            .fm_a_to_b => "FM A\u{2192}B", .fm_b_to_a => "FM B\u{2192}A",
        }),
        15 => switch (synth.mod_mode) {
            .fm_a_to_b, .fm_b_to_a => try w.print("\u{03b2}={d:.2}", .{synth.mod_amount}),
            else                    => try w.print("{d:.2}",          .{synth.mod_amount}),
        },
        16 => try w.print("{d:.3} s",     .{synth.attack_s}),
        17 => try w.print("{d:.3} s",     .{synth.decay_s}),
        18 => try w.print("{d:.3}",       .{synth.sustain}),
        19 => try w.print("{d:.3} s",     .{synth.release_s}),
        20 => try w.writeAll(filterTypeName(synth.filter_type)),
        21 => if (synth.filter_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz",  .{synth.filter_cutoff}),
        22 => try w.print("{d:.3}",       .{synth.filter_res}),
        24 => try w.print("{d:.3} s",     .{synth.fenv_attack_s}),
        25 => try w.print("{d:.3} s",     .{synth.fenv_decay_s}),
        26 => try w.print("{d:.3}",       .{synth.fenv_sustain}),
        27 => try w.print("{d:.3} s",     .{synth.fenv_release_s}),
        28 => try w.writeAll(lfoShapeName(synth.lfo_shape)),
        29 => try w.print("{d:.2} Hz",    .{synth.lfo_rate_hz}),
        32 => try w.writeAll(switch (synth.voice_mode) {
            .poly => "poly", .mono => "mono", .legato => "legato",
        }),
        33 => if (synth.glide_s == 0.0) try w.writeAll("off")
              else try w.print("{d:.3} s", .{synth.glide_s}),
        34 => if (synth.sub_level == 0.0) try w.writeAll("off")
              else try w.print("{d:.2}",   .{synth.sub_level}),
        35 => try w.writeAll(switch (synth.sub_shape) { .sine => "sine", .square => "sqr" }),
        36 => if (synth.noise_level == 0.0) try w.writeAll("off")
              else try w.print("{d:.2}",   .{synth.noise_level}),
        37 => try w.print("{d:.2}",       .{synth.noise_color}),
        38 => try w.print("{d:.3}",       .{synth.gain}),
        39 => try w.writeAll(uniModeName(synth.unison_mode)),
        40 => try w.writeAll(uniModeName(synth.osc_b_unison_mode)),
        41 => try w.writeAll(switch (synth.warp_mode) {
            .none => "none", .bend => "bend", .mirror => "mirror", .sync => "sync",
        }),
        42 => try w.print("{d:.2}",       .{synth.warp_amount}),
        43 => try w.writeAll(switch (synth.osc_b_warp_mode) {
            .none => "none", .bend => "bend", .mirror => "mirror", .sync => "sync",
        }),
        44 => try w.print("{d:.2}",       .{synth.osc_b_warp_amount}),
        45 => try w.writeAll(if (synth.filter2_on) "on" else "off"),
        46 => try w.writeAll(filterTypeName(synth.filter2_type)),
        47 => if (synth.filter2_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter2_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz",  .{synth.filter2_cutoff}),
        48 => try w.print("{d:.3}",       .{synth.filter2_res}),
        49 => try w.writeAll(switch (synth.filter_routing) { .series => "series", .parallel => "parallel" }),
        50 => try w.writeAll(if (synth.osc_c_on) "on" else "off"),
        51 => try w.writeAll(switch (synth.osc_c_waveform) {
            .sine => "sine", .saw => "saw", .triangle => "tri", .square => "sqr",
        }),
        52 => try w.print("{d:.2}",       .{synth.osc_c_pulse_width}),
        53 => try w.print("{d:.0} st",    .{synth.osc_c_semi}),
        54 => try w.print("{d:.0} ct",    .{synth.osc_c_detune_cents}),
        55 => try w.print("{d:.2}",       .{synth.osc_c_level}),
        56 => try w.print("{d}",           .{synth.osc_c_unison}),
        57 => try w.print("{d:.1} ct",    .{synth.osc_c_unison_detune}),
        58 => try w.writeAll(uniModeName(synth.osc_c_unison_mode)),
        59...82 => {
            const row = synth.mod_matrix[(app.synth_cursor - 59) / 3];
            switch ((app.synth_cursor - 59) % 3) {
                // zig fmt: off
                0 => try w.writeAll(mod_src_names[modSrcIdx(row.source)]),
                1 => try w.writeAll(ws.dsp.PolySynth.modDestLabel(row.dest)),
                2 => try w.print("{s}{d:.2}", .{ @as([]const u8, if (row.depth >= 0.0) "+" else ""), row.depth }),
                // zig fmt: on
                else => {},
            }
        },
        // zig fmt: off
        83 => try w.writeAll(if (synth.fx_dist_on) "on" else "off"),
        84 => try w.print("{d:.1} dB",    .{synth.fx_dist_drive_db}),
        85 => try w.print("{d:.2}",       .{synth.fx_dist_mix}),
        86 => try w.writeAll(if (synth.fx_crush_on) "on" else "off"),
        87 => try w.print("{d:.0}",       .{synth.fx_crush_bits}),
        88 => try w.print("1/{d:.0}",     .{synth.fx_crush_rate}),
        89 => try w.print("{d:.2}",       .{synth.fx_crush_mix}),
        90 => try w.writeAll(if (synth.fx_flanger_on) "on" else "off"),
        91 => try w.print("{d:.2} Hz",    .{synth.fx_flanger_rate_hz}),
        92 => try w.print("{d:.2}",       .{synth.fx_flanger_depth}),
        93 => try w.print("{d:.2}",       .{synth.fx_flanger_feedback}),
        94 => try w.print("{d:.2}",       .{synth.fx_flanger_mix}),
        95 => try w.writeAll(lfoShapeName(synth.lfo2_shape)),
        96 => try w.print("{d:.2} Hz",    .{synth.lfo2_rate_hz}),
        97 => try w.writeAll(lfoShapeName(synth.lfo3_shape)),
        98 => try w.print("{d:.2} Hz",    .{synth.lfo3_rate_hz}),
        99  => try w.print("{d:.2}",      .{synth.macro1}),
        100 => try w.print("{d:.2}",      .{synth.macro2}),
        101 => try w.print("{d:.2}",      .{synth.macro3}),
        102 => try w.print("{d:.2}",      .{synth.macro4}),
        103 => try w.writeAll(if (synth.fx_phaser_on) "on" else "off"),
        104 => try w.print("{d:.2} Hz",    .{synth.fx_phaser_rate_hz}),
        105 => try w.print("{d:.2}",       .{synth.fx_phaser_depth}),
        106 => try w.print("{d:.2}",       .{synth.fx_phaser_feedback}),
        107 => try w.print("{d:.2}",       .{synth.fx_phaser_mix}),
        // zig fmt: on
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

// zig fmt: on
