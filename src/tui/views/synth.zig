//! Synth editor view, its row primitives, and its status bar.

const std = @import("std");
const ws = @import("wstudio");
const PolySynth = ws.dsp.PolySynth;
const engine_mod = ws.engine;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");
const synth_layout = @import("../../ui/synth_layout.zig");

// Bare-name aliases for the shared palette/primitives.
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
const synthBar = style.synthBar;
const synthSection = style.synthSection;
const barRow = style.barRow;
const enumRow = style.enumRow;
const rowHead = style.rowHead;
const rowVal = style.rowVal;

const synth_ed = @import("../../ui/editors/synth.zig");

fn drawSynthTitle(w: *std.Io.Writer, subview: synth_ed.Subview, name: []const u8, focused: bool) !void {
    try w.writeAll(bcyn ++ bold ++ " \u{2593} ");
    try w.writeAll(icons.iconOr(icons.synth ++ " ", ""));
    try w.writeAll("SYNTH " ++ rst);
    inline for (synth_ed.subviews) |tab| {
        if (tab.subview == subview) {
            try w.writeAll(bcyn ++ bold);
            try w.print("[{s}]", .{tab.short_label});
        } else {
            try w.writeAll(dim);
            try w.print(" {s} ", .{tab.short_label});
        }
        try w.writeAll(rst);
    }
    if (focused) try w.writeAll(bcyn ++ bold ++ "  FOCUS" ++ rst);
    try w.writeAll("  " ++ acc);
    try w.print("\"{s}\"", .{name});
    try w.writeAll(rst);
    try endLine(w);
}

/// Render the synth editor into `w`, applying vertical scroll so it fits
/// within `max_rows`. Always shows the title line, then slices the current
/// subview's body to keep the cursor in view. `app.synth_subview` picks one
/// of two panes (see synth_ed.Subview): "main"/"mod" each pack their cards
/// into 1-3 columns by terminal width (see `drawSynthGrid`/
/// synth_layout.zig).
pub fn drawSynthEditor(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    // Available rows for the view body (excludes the caller's header +
    // transport + status - 4 rows total, no separate hr() rule rows anymore).
    const max_rows = rows -| 4;
    switch (app.synth_subview) {
        .main => try drawSynthGrid(app, w, max_rows, cols, .main),
        .mod => try drawSynthGrid(app, w, max_rows, cols, .mod),
    }
}

/// `main_sections`' render functions, in the exact same order as the table
/// itself - the single place that maps a `synth_layout.SectionDef` to the
/// code that actually draws it. `sec*` bodies stay ordinary Zig (bespoke
/// formatting/dimming per param); only *which sections exist and in what
/// order* is table-driven.
const RenderFn = *const fn (w: *std.Io.Writer, synth: *const PolySynth, c: u16) anyerror!void;
const main_render_fns = [_]RenderFn{
    secOscA,   secOscB,    secOscC, secSub,  secNoise, secMod,
    secFilter, secFilter2, secEnv,  secFenv, secVoice, secArp,
    secOut,
};
comptime {
    if (main_render_fns.len != synth_layout.main_sections.len)
        @compileError("views/synth.zig: main_render_fns must mirror synth_layout.main_sections 1:1");
}

/// The "main"/"mod" subviews: every section card packed into 1-3 columns
/// by `cols` (see synth_layout.numCols), each column rendered into its own
/// temp buffer and then zipped row-by-row - the same technique the old
/// wide-mode OSC A/B split used, generalized from "2 fixed columns, top
/// block only" to "N columns, every section". The whole grid scrolls
/// together (one `scroll` offset shared by every column), matching
/// `editors/synth.zig`'s `updateScroll`/`moveEntry`. `subview` picks which
/// section/render-fn tables the grid reads; everything else is identical.
fn drawSynthGrid(app: anytype, w: *std.Io.Writer, max_rows: usize, cols: usize, comptime subview: synth_ed.Subview) !void {
    const sections = comptime switch (subview) {
        .main => &synth_layout.main_sections,
        .mod => &synth_layout.mod_sections,
    };
    const render_fns = comptime switch (subview) {
        .main => &main_render_fns,
        .mod => &mod_render_fns,
    };
    const n = synth_layout.numCols(cols);
    const col_w = synth_layout.colWidth(cols, n);
    style.form_bar_w = @min(style.form_bar_w_default + (col_w -| 100) / 2, 40);
    style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);

    const order = if (subview == .main) synth_layout.mainOrder(n) else synth_layout.modOrder(n);
    const heights = if (subview == .main) synth_layout.mainHeights(n) else synth_layout.modHeights(n);
    var body_rows: usize = 0;
    for (heights) |h| body_rows = @max(body_rows, h);

    const idx = synth_layout.indexContaining(order, app.synth_cursor) orelse 0;
    const cursor_row = if (order.len > 0) order[idx].row else 0;

    // The scroll window is content rows only - `max_rows` also counts the
    // title row emitted below, which never scrolls. Clamping against
    // `max_rows` directly here left the window one row too tall for what
    // the write loop actually has room for, so the very last content row
    // (whatever the cursor scrolled all the way down to reach) silently
    // never got written even though `scroll` claimed to include it.
    const content_rows = max_rows -| 1;
    var scroll = @min(app.synth_scroll, body_rows -| content_rows);
    if (cursor_row < scroll) scroll = cursor_row;
    if (cursor_row >= scroll + content_rows) scroll = cursor_row -| content_rows + 1;
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

    try drawSynthTitle(w, subview, name, app.synth_section_focus);
    var written: usize = 1;

    if (app.synth_section_focus) {
        const section = order[idx].section;
        style.form_bar_w = @min(style.form_bar_w_default + (cols -| 100) / 2, 40);
        style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);
        var focus_buf: [16 * 1024]u8 = undefined;
        var fw = std.Io.Writer.fixed(&focus_buf);
        try render_fns[section](&fw, synth, c);
        var lines = std.mem.splitSequence(u8, fw.buffered(), "\r\n");
        while (lines.next()) |line| {
            if (written >= max_rows) break;
            try style.writeClamped(w, line, cols);
            try endLine(w);
            written += 1;
        }
        while (written < max_rows) : (written += 1) try endLine(w);
        app.synth_scroll = 0;
        return;
    }

    var bufs: [synth_layout.max_cols][16 * 1024]u8 = undefined;
    var writers: [synth_layout.max_cols]std.Io.Writer = undefined;
    var col_rows = [_]usize{0} ** synth_layout.max_cols;
    for (0..n) |i| writers[i] = std.Io.Writer.fixed(&bufs[i]);
    const placements = if (subview == .main) synth_layout.mainPlacements(n) else synth_layout.modPlacements(n);
    for (sections, 0..) |sec, si| {
        const col = placements[si].col;
        // Keep rendered rows aligned with cursor placement.
        while (col_rows[col] < placements[si].row0) : (col_rows[col] += 1) try endLine(&writers[col]);
        try render_fns[si](&writers[col], synth, c);
        try endLine(&writers[col]);
        col_rows[col] += sec.params.len + sec.extra_rows + 2;
    }

    var iters: [synth_layout.max_cols]std.mem.SplitIterator(u8, .sequence) = undefined;
    for (0..n) |i| iters[i] = std.mem.splitSequence(u8, writers[i].buffered(), "\r\n");

    var row: usize = 0;
    while (row < body_rows) : (row += 1) {
        // Every column's iterator must advance once per row regardless of
        // whether the row is about to be skipped by the scroll check below
        // - otherwise a scrolled-past row's lines are never consumed and
        // every column desyncs from `row` for the rest of the frame.
        var lines = [_][]const u8{""} ** synth_layout.max_cols;
        for (0..n) |i| {
            if (row < heights[i]) lines[i] = iters[i].next() orelse "";
        }
        if (written >= max_rows) break;
        if (row < scroll) continue;
        for (0..n) |i| {
            if (i + 1 < n) {
                try style.writePadded(w, lines[i], col_w);
            } else {
                try style.writeClamped(w, lines[i], cols -| col_w * (n - 1));
            }
        }
        try endLine(w);
        written += 1;
    }
    while (written < max_rows) : (written += 1) try endLine(w);
}

/// `mod_sections`' render functions - the `.mod` counterpart to
/// `main_render_fns`.
const mod_render_fns = [_]RenderFn{
    secLfo, secLfo2, secLfo3, secEnv3, secMacro, secMatrix,
};
comptime {
    if (mod_render_fns.len != synth_layout.mod_sections.len)
        @compileError("views/synth.zig: mod_render_fns must mirror synth_layout.mod_sections 1:1");
}

// The section renderers below emit one header row + one row per param each.
// Which sections exist per subview, their order, and how they pack into
// columns now lives in synth_layout.zig's comptime tables - see
// drawSynthGrid/main_render_fns below for how MAIN consumes them. MOD/FX
// keep their previous per-subview rendering for now (see synth_layout.zig's
// module doc comment).

const wf_names = [_][]const u8{ "sine", "saw", "tri", "sqr", "wt" };

/// The `wt.table` row. A plain name readout rather than `enumRow`'s inline
/// option strip: five bundled names plus "imported" would run well past a
/// synth column's width (same reason the soundfont view prints its preset).
fn wtTableRow(w: *std.Io.Writer, is_sel: bool, dimmed: bool, kind: ?ws.dsp.synth.BundledWavetable) !void {
    try rowHead(w, is_sel, dimmed, "wt.table");
    try w.writeByte(' ');
    try rowVal(w, is_sel, dimmed, synth_ed.wtTableName(kind));
    try endLine(w);
}

fn secOscA(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC A", acc);

    // zig fmt: off
    try enumRow(w, c == 0, false, acc, "waveform", &wf_names, @intFromEnum(synth.waveform));

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

    // uni.mode/warp/wt.pos: formerly the standalone UNI MODE/WARP/WAVETABLE
    // sections' "osc a" rows - folded into this card so each oscillator's
    // controls live in one place instead of three cross-cutting sections.
    try enumRow(w, c == 39, synth.unison <= 1, acc, "uni.mode", &uni_mode_names, @intFromEnum(synth.unison_mode));
    try enumRow(w, c == 41, false, acc, "warp", &warp_mode_names, @intFromEnum(synth.warp_mode));
    try barRow(w, c == 42, synth.warp_mode == .none, acc, "warp amt", synth.warp_amount, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.warp_amount}));
    try barRow(w, c == 185, synth.waveform != .wavetable, acc, "wt.pos", synth.wt_pos, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.wt_pos}));
    try wtTableRow(w, c == 251, synth.waveform != .wavetable, synth.wt_bundled);
}
// zig fmt: on

fn secOscB(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC B", acc);

    const b_on = synth.osc_b_on;
    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 6, false, acc, "on/off", &on_names, if (b_on) 0 else 1);

    // zig fmt: off
    try enumRow(w, c == 7, !b_on, acc, "waveform", &wf_names, @intFromEnum(synth.osc_b_waveform));

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

    // uni.mode/warp/wt.pos - see secOscA's matching rows for why these live
    // here now instead of in standalone UNI MODE/WARP/WAVETABLE sections.
    try enumRow(w, c == 40, !b_on or synth.osc_b_unison <= 1, acc, "uni.mode", &uni_mode_names, @intFromEnum(synth.osc_b_unison_mode));
    try enumRow(w, c == 43, !b_on, acc, "warp", &warp_mode_names, @intFromEnum(synth.osc_b_warp_mode));
    try barRow(w, c == 44, !b_on or synth.osc_b_warp_mode == .none, acc, "warp amt", synth.osc_b_warp_amount, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_warp_amount}));
    try barRow(w, c == 186, !b_on or synth.osc_b_waveform != .wavetable, acc, "wt.pos", synth.osc_b_wt_pos, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_b_wt_pos}));
    try wtTableRow(w, c == 252, !b_on or synth.osc_b_waveform != .wavetable, synth.osc_b_wt_bundled);
}

fn secMod(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
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

fn secEnv(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "AMP ENV", grn);

    try barRow(w, c == 16, false, grn, "attack", synth.attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.attack_s}));
    try barRow(w, c == 17, false, grn, "decay", synth.decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.decay_s}));
    try barRow(w, c == 18, false, grn, "sustain", synth.sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.sustain}));
    try barRow(w, c == 19, false, grn, "release", synth.release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.release_s}));
}

const filter_type_names = [_][]const u8{ "lp", "hp", "bp", "ntch", "ladr", "diod", "comb", "frmt" };

fn secFilter(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER 1", yel);

    try enumRow(w, c == 20, false, yel, "type", &filter_type_names, @intFromEnum(synth.filter_type));

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

fn secFenv(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER ENV", grn);

    try barRow(w, c == 24, false, grn, "f.attack", synth.fenv_attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_attack_s}));
    try barRow(w, c == 25, false, grn, "f.decay", synth.fenv_decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_decay_s}));
    try barRow(w, c == 26, false, grn, "f.sustain", synth.fenv_sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.fenv_sustain}));
    try barRow(w, c == 27, false, grn, "f.release", synth.fenv_release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.fenv_release_s}));
}

const lfo_shape_names = [_][]const u8{ "drawn", "s&h", "chaos" };
const lfo_wave_names = [_][]const u8{ "drawn", "sine", "tri", "saw", "sqr" };
const lfo_retrig_names = [_][]const u8{ "free", "key", "1shot" };

/// The seven ids each LFO slot owns, in the order its rows draw:
/// shape, wave preset, rate, sync, retrig, phase offset, slew.
const lfo_slot_ids = [3][7]u16{
    .{ 28, 397, 29, 256, 259, 262, 265 },
    .{ 95, 398, 96, 257, 260, 263, 266 },
    .{ 97, 399, 98, 258, 261, 264, 267 },
};

/// A slot's live values, so `secLfoSlot` draws all three from one body.
fn lfoSlotState(synth: *const PolySynth, slot: u8) struct {
    shape: ws.dsp.synth.LfoShape,
    rate: f32,
    sync: ws.dsp.synth.LfoSync,
    retrig: ws.dsp.synth.LfoRetrig,
    phase_offset: f32,
    slew_ms: f32,
} {
    return switch (slot) {
        0 => .{ .shape = synth.lfo_shape, .rate = synth.lfo_rate_hz, .sync = synth.lfo_sync, .retrig = synth.lfo_retrig, .phase_offset = synth.lfo_phase_offset, .slew_ms = synth.lfo_slew_ms },
        1 => .{ .shape = synth.lfo2_shape, .rate = synth.lfo2_rate_hz, .sync = synth.lfo2_sync, .retrig = synth.lfo2_retrig, .phase_offset = synth.lfo2_phase_offset, .slew_ms = synth.lfo2_slew_ms },
        else => .{ .shape = synth.lfo3_shape, .rate = synth.lfo3_rate_hz, .sync = synth.lfo3_sync, .retrig = synth.lfo3_retrig, .phase_offset = synth.lfo3_phase_offset, .slew_ms = synth.lfo3_slew_ms },
    };
}

/// The LFO is a pure mod source - its routing lives on MATRIX rows (the
/// matrix absorbed the old depth/target params). What's left here is how it
/// moves: shape, how fast, whether the tempo or the Hz knob decides that,
/// and how it behaves across note-ons.
///
/// `sync` draws as a bar rather than an enum strip: 17 note divisions won't
/// fit a column, and they're ordered slow-to-fast, so bar position reads as
/// "how fast" at a glance with the exact division in the value slot.
fn secLfoSlot(w: *std.Io.Writer, synth: *const PolySynth, c: u16, slot: u8, title: []const u8) !void {
    var buf: [40]u8 = undefined;
    const ids = lfo_slot_ids[slot];
    const s = lfoSlotState(synth, slot);
    const synced = s.sync != .off;
    try synthSection(w, title, mag);

    try enumRow(w, c == ids[0], false, mag, "shape", &lfo_shape_names, @intFromEnum(s.shape));
    // Loading a wave overwrites the drawn points, so the row is inert (and
    // dimmed) while the slot is on a shape that doesn't read them.
    try enumRow(w, c == ids[1], s.shape != .drawn, mag, "wave", &lfo_wave_names,
        @intFromEnum(ws.dsp.synth.lfoWaveOf(synth.lfo_custom[slot][0..synth.lfo_custom_count[slot]])));
    // The Hz knob is inert while a division is set, so dim it and say so.
    try barRow(w, c == ids[2], synced, mag, "rate", s.rate, 20.0, if (synced)
        try std.fmt.bufPrint(&buf, "{s} sync", .{s.sync.label()})
    else
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{s.rate}));
    try barRow(w, c == ids[3], false, mag, "sync", @floatFromInt(@intFromEnum(s.sync)), @floatFromInt(@typeInfo(ws.dsp.synth.LfoSync).@"enum".fields.len - 1), s.sync.label());
    try enumRow(w, c == ids[4], false, mag, "retrig", &lfo_retrig_names, @intFromEnum(s.retrig));
    try barRow(w, c == ids[5], false, mag, "phase", s.phase_offset, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{s.phase_offset}));
    try barRow(w, c == ids[6], false, mag, "slew", s.slew_ms, 500.0,
        try std.fmt.bufPrint(&buf, "{d:.0} ms", .{s.slew_ms}));
    try secLfoShapePlot(w, synth, slot, s.shape);
}

fn secLfo(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    try secLfoSlot(w, synth, c, 0, "LFO 1");
}

fn secLfo2(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    try secLfoSlot(w, synth, c, 1, "LFO 2");
}

fn secLfo3(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    try secLfoSlot(w, synth, c, 2, "LFO 3");
}

/// One cycle of the slot's drawn shape as a block-glyph sparkline, on the
/// card's last row (the `extra_rows = 1` its `synth_layout` entry declares).
/// A read-only picture: the breakpoints and their bends are edited in the
/// GUI's curve widget, and this is what tells a TUI-only user which of the
/// eight shape presets is actually loaded and how far it has been drawn away
/// from. Slots on `.sh`/`.chaos` draw nothing - their motion isn't a cycle.
fn secLfoShapePlot(w: *std.Io.Writer, synth: *const PolySynth, slot: u8, shape: ws.dsp.synth.LfoShape) !void {
    const bars = [_][]const u8{ "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}" };
    try rowHead(w, false, shape != .drawn, "curve");
    if (shape != .drawn) return endLine(w);
    try w.writeAll(mag);
    const columns = 24;
    for (0..columns) |i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, columns);
        const v = synth.lfoValueAt(slot, phase);
        const level: usize = @intFromFloat(std.math.clamp((v + 1.0) * 0.5, 0.0, 1.0) * @as(f32, bars.len - 1));
        try w.writeAll(bars[level]);
    }
    try w.writeAll(rst);
    try endLine(w);
}

/// Four macro knobs - pure mod sources (mc1-mc4 on MATRIX rows), no sound
/// of their own, automatable as ids 99-102.
fn secMacro(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
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

const arp_mode_names = [_][]const u8{ "up", "down", "up/dn", "dn/up", "played", "random", "chord" };

/// A step sequencer in front of note triggering - see PolySynth's own ARP
/// doc comment.
fn secArp(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "ARP", bcyn);

    const on = synth.arp_on;
    try enumRow(w, c == 116, false, bcyn, "on/off", &on_off_names, if (on) 0 else 1);
    try enumRow(w, c == 117, !on, bcyn, "mode", &arp_mode_names, @intFromEnum(synth.arp_mode));
    try barRow(w, c == 118, !on or synth.arp_mode == .chord, bcyn, "octaves", @floatFromInt(synth.arp_octaves), 4.0,
        try std.fmt.bufPrint(&buf, "{d}", .{synth.arp_octaves}));
    const synced = synth.arp_sync != .off;
    try barRow(w, c == 119, !on or synced, bcyn, "rate", synth.arp_rate_hz, 20.0, if (synced)
        try std.fmt.bufPrint(&buf, "{s} sync", .{synth.arp_sync.label()})
    else
        try std.fmt.bufPrint(&buf, "{d:.1} Hz", .{synth.arp_rate_hz}));
    try barRow(w, c == 268, !on, bcyn, "sync", @floatFromInt(@intFromEnum(synth.arp_sync)), @floatFromInt(@typeInfo(ws.dsp.synth.LfoSync).@"enum".fields.len - 1), synth.arp_sync.label());
    try barRow(w, c == 120, !on, bcyn, "gate", synth.arp_gate, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.arp_gate}));
    try enumRow(w, c == 121, !on, bcyn, "hold", &on_off_names, if (synth.arp_hold) 0 else 1);
}

/// A third ADSR with no fixed destination - a pure MATRIX source (env3),
/// same shape as FENV but not tied to the filter.
fn secEnv3(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "ENV 3", grn);

    try barRow(w, c == 122, false, grn, "attack", synth.env3_attack_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.env3_attack_s}));
    try barRow(w, c == 123, false, grn, "decay", synth.env3_decay_s, 5.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.env3_decay_s}));
    try barRow(w, c == 124, false, grn, "sustain", synth.env3_sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.env3_sustain}));
    try barRow(w, c == 125, false, grn, "release", synth.env3_release_s, 10.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{synth.env3_release_s}));
}

fn secVoice(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
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

fn secSub(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
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

fn secNoise(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
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

fn secOut(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OUT", bcyn);

    try barRow(w, c == 38, false, bcyn, "gain", synth.gain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{synth.gain}));
}

const uni_mode_names = [_][]const u8{ "spread", "step", "harm", "ratio" };

const warp_mode_names = [_][]const u8{ "none", "bend", "mirror", "sync" };

fn secFilter2(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER 2", yel);

    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 45, false, yel, "on/off", &on_names, if (synth.filter2_on) 0 else 1);

    const on = synth.filter2_on;
    try enumRow(w, c == 46, !on, yel, "type", &filter_type_names, @intFromEnum(synth.filter2_type));

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

/// Plain additive 3rd oscillator - same row shape as OSC B, no mod/warp rows
/// since OSC C doesn't participate in either (see PolySynth's own doc comment).
fn secOscC(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC C", acc);

    const c_on = synth.osc_c_on;
    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 50, false, acc, "on/off", &on_names, if (c_on) 0 else 1);

    try enumRow(w, c == 51, !c_on, acc, "waveform", &wf_names, @intFromEnum(synth.osc_c_waveform));

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

    try enumRow(w, c == 58, !c_on or synth.osc_c_unison <= 1, acc, "uni.mode", &uni_mode_names, @intFromEnum(synth.osc_c_unison_mode));
    try barRow(w, c == 187, !c_on or synth.osc_c_waveform != .wavetable, acc, "wt.pos", synth.osc_c_wt_pos, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.osc_c_wt_pos}));
    try wtTableRow(w, c == 253, !c_on or synth.osc_c_waveform != .wavetable, synth.osc_c_wt_bundled);
}

/// Mod-matrix rows, 3 editor fields each (source / dest / depth). Dest and
/// depth dim while the row's source is off, mirroring the on/off gating the
/// oscillator sections use.
/// One line per slot: `N  <source>  <dest>  [bar]  <depth>`. `w`/`b` move
/// the cursor between the source/dest/depth fields (see
/// synth_layout.moveField - matrix rows are `fields = 3` entries); `j`/`k`
/// move between slots preserving whichever field was focused. Source/dest
/// dim while the slot is off, matching the oscillator sections' on/off
/// dimming convention.
fn secMatrix(w: *std.Io.Writer, synth: *const PolySynth, c: u16) !void {
    try synthSection(w, "MATRIX", mag);

    for (synth.mod_matrix, 0..) |row, k| {
        const base = PolySynth.matrixParamId(k, 0);
        const off = row.source == .none;
        const sel_src = c == base;
        const sel_dst = c == base + 1;
        const sel_dep = c == base + 2;
        const pol_id: u16 = @intCast(ws.dsp.PolySynth.mod_unipolar_id_base + k);
        const sel_pol = c == pol_id;
        const focused = sel_src or sel_dst or sel_dep or sel_pol;

        if (focused) {
            try w.writeAll(bcyn ++ bold);
            try w.print("\u{25B8} {d: <2} ", .{k + 1});
        } else {
            try w.print("  {d: <2} ", .{k + 1});
        }
        try w.writeAll(rst);

        // Polarity leads the row rather than trailing it: at three columns
        // the depth readout is already flush with the right edge, and a
        // leading cell also lets the whole matrix's polarity be read down
        // one column. Dimmed on sources that are already unipolar - the
        // toggle still stores, it just has nothing to fold.
        if (sel_pol) {
            try w.writeAll(bwht ++ bold);
        } else if (off or !row.source.isBipolar()) {
            try w.writeAll(dim);
        }
        try w.writeAll(if (row.unipolar) "un" else "bi");
        try w.writeAll(rst ++ " ");

        if (sel_src) {
            try w.writeAll(bwht ++ bold);
        } else if (off) {
            try w.writeAll(dim);
        }
        try w.print("{s: <5}", .{synth_layout.modSourceName(row.source)});
        try w.writeAll(rst ++ " ");

        if (sel_dst) {
            try w.writeAll(bwht ++ bold);
        } else if (off) {
            try w.writeAll(dim);
        }
        try w.print("{s: <14}", .{ws.dsp.PolySynth.modDestLabel(row.dest)});
        try w.writeAll(rst ++ " ");

        const bc = if (sel_dep) bcyn else if (off) dim else mag;
        try synthBar(w, row.depth + 1.0, 2.0, sel_dep, bc);
        try w.writeAll("  ");
        if (sel_dep) {
            try w.writeAll(bwht ++ bold);
        } else if (off) {
            try w.writeAll(dim);
        }
        const sign: []const u8 = if (row.depth >= 0.0) "+" else "";
        try w.print("{s}{d:.2}", .{ sign, row.depth });
        try w.writeAll(rst);
        try endLine(w);
    }
}

const on_off_names = [_][]const u8{ "on", "off" };

/// Log-normalized 0..1 bar fill for a 20Hz-20kHz frequency param - same
/// formula `secFilter`'s cutoff bar already uses (a linear fill would cram
/// almost the whole audible range into the bar's first few percent).
fn freqBarVal(hz: f32) f32 {
    return std.math.log2(hz / 20.0) / std.math.log2(20_000.0 / 20.0);
}



// zig fmt: on
