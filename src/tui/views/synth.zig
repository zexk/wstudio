//! Synth editor view, its row primitives, and its status bar.

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

const synth_ed = @import("../editors/synth.zig");

/// Render the synth editor into `w`, applying vertical scroll so it fits
/// within `max_rows`. Always shows the title line, then slices the parameter
/// body to keep the cursor in view. Wide terminals (synth_ed.twoCol) get the
/// sections zipped into two side-by-side columns — OSC A and the shaping
/// sections left, OSC B and modulation/output right — 25 body rows instead
/// of 50; narrow ones keep the single-column stack.
pub fn drawSynthEditor(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize, snap: engine_mod.UiSnapshot) !void {
    _ = snap;
    // Available rows for the view body (excludes the caller's header +
    // transport + status — 3 rows total, no separate hr() rule rows anymore).
    const max_rows = rows -| 3;
    const two_col = synth_ed.twoCol(cols);

    // Stretch the param bars (and the section rules with them) into free
    // width — single-column mode gets at most a few extra cells before the
    // two-column split takes over at 108; there each column stretches its
    // own bars. The knobs were reset to the compact defaults by App.draw.
    const col_w = synth_ed.colWidth(cols);
    style.form_bar_w = if (two_col)
        @min(style.form_bar_w_default + (col_w -| 56), 40)
    else
        @min(style.form_bar_w_default + (cols -| 100) / 2, 40);
    style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);

    // Clamp scroll so the cursor row is visible and the window never runs
    // past the layout's last row (the two layouts' heights differ, so a
    // stale offset from the other mode must not survive a resize).
    const cursor_row = if (two_col) synth_ed.paramColRow(app.synth_cursor).row else synth_ed.paramRow(app.synth_cursor);
    const body_rows: usize = if (two_col) 25 else 50; // rows below the shared title
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

    const name = if (app.synth_track < app.session.project.tracks.items.len)
        app.session.project.tracks.items[app.synth_track].name
    else "?";

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
        var tmp_l: [16 * 1024]u8 = undefined;
        var wl = std.Io.Writer.fixed(&tmp_l);
        try drawSynthColLeft(&wl, synth, c);
        var tmp_r: [16 * 1024]u8 = undefined;
        var wr = std.Io.Writer.fixed(&tmp_r);
        try drawSynthColRight(&wr, synth, c);

        var it_l = std.mem.splitSequence(u8, wl.buffered(), "\r\n");
        var it_r = std.mem.splitSequence(u8, wr.buffered(), "\r\n");
        var row: usize = 1;
        while (true) : (row += 1) {
            const ll = it_l.next() orelse "";
            const rl = it_r.next() orelse "";
            if (ll.len == 0 and rl.len == 0) break; // both exhausted (trailing empties)
            if (written >= max_rows) break;
            if (row < scroll + 1) continue;
            try style.writePadded(w, ll, col_w);
            try style.writeClamped(w, rl, cols -| col_w);
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
// The two-column split/order is mirrored by editors/synth.zig's paramColRow,
// the single-column order (in drawSynthEditor's else-branch above) by its
// paramRow — keep renderers and row maps in sync.

/// OSC A + the shaping sections: 25 rows (7 + 5 + 5 + 5 + 3).
fn drawSynthColLeft(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    try secOscA(w, synth, c);
    try secEnv(w, synth, c);
    try secFilter(w, synth, c);
    try secFenv(w, synth, c);
    try secVoice(w, synth, c);
}

/// OSC B + modulation/output sections: 25 rows (9 + 3 + 5 + 3 + 3 + 2).
fn drawSynthColRight(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    try secOscB(w, synth, c);
    try secMod(w, synth, c);
    try secLfo(w, synth, c);
    try secSub(w, synth, c);
    try secNoise(w, synth, c);
    try secOut(w, synth, c);
}

const wf_names = [_][]const u8{ "sine", "saw", "tri", "sqr" };

fn secOscA(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC A", acc);

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

fn secOscB(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "OSC B", acc);

    const b_on = synth.osc_b_on;
    const on_names = [_][]const u8{ "on", "off" };
    try enumRow(w, c == 6, false, acc, "on/off", &on_names, if (b_on) 0 else 1);

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

fn secFilter(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "FILTER", yel);

    const ft_names = [_][]const u8{ "lp", "hp", "bp", "ntch" };
    const ft_idx: usize = switch (synth.filter_type) {
        .lp => 0, .hp => 1, .bp => 2, .notch => 3,
    };
    try enumRow(w, c == 20, false, yel, "type", &ft_names, ft_idx);

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
    {
        const sign: []const u8 = if (synth.fenv_amount >= 0.0) "+" else "";
        try barRow(w, c == 23, false, yel, "f.env.amt", synth.fenv_amount + 4.0, 8.0,
            try std.fmt.bufPrint(&buf, "{s}{d:.1} oct", .{ sign, synth.fenv_amount }));
    }
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

fn secLfo(w: *std.Io.Writer, synth: anytype, c: u8) !void {
    var buf: [40]u8 = undefined;
    try synthSection(w, "LFO", mag);

    const lfo_names = [_][]const u8{ "sine", "tri", "saw", "sqr" };
    const lfo_idx: usize = switch (synth.lfo_shape) {
        .sine => 0, .triangle => 1, .saw => 2, .square => 3,
    };
    try enumRow(w, c == 28, false, mag, "shape", &lfo_names, lfo_idx);

    try barRow(w, c == 29, false, mag, "rate", synth.lfo_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{synth.lfo_rate_hz}));
    try barRow(w, c == 30, false, mag, "depth", synth.lfo_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{synth.lfo_depth}));

    const tgt_names = [_][]const u8{ "off", "filt", "pitch", "amp" };
    const tgt_idx: usize = switch (synth.lfo_target) {
        .none => 0, .filter => 1, .pitch => 2, .amp => 3,
    };
    try enumRow(w, c == 31, false, mag, "target", &tgt_names, tgt_idx);
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

pub fn drawSynthStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer, cmds: []const cmd_mod.Def) !void {
    if (app.modal.mode == .command) {
        try cmd_mod.writePrompt(w, cmds, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor, 60);
        return;
    }
    if (app.modal.mode == .search) {
        try cmd_mod.writeSearchPrompt(w, app.modal.cmd_buf[0..app.modal.cmd_len], app.modal.cmd_cursor);
        return;
    }
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) { .poly_synth => {}, else => return }
    const synth = &rack.instrument.poly_synth;

    const labels = [_][]const u8{
        "waveform", "pls.width", "detune", "unison", "uni.det", "spread",
        "b.on", "b.waveform", "b.pw", "b.semi", "b.detune", "b.level", "b.unison", "b.uni.det",
        "mod.mode", "mod.amount",
        "attack", "decay", "sustain", "release",
        "filt.type", "cutoff", "res", "f.env.amt",
        "f.attack", "f.decay", "f.sustain", "f.release",
        "lfo.shape", "lfo.rate", "lfo.depth", "lfo.target",
        "voice.mode", "glide",
        "sub.level", "sub.shape",
        "noise.level", "noise.color",
        "gain",
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
        20 => try w.writeAll(switch (synth.filter_type) {
            .lp => "lp", .hp => "hp", .bp => "bp", .notch => "notch",
        }),
        21 => if (synth.filter_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz",  .{synth.filter_cutoff}),
        22 => try w.print("{d:.3}",       .{synth.filter_res}),
        23 => {
            const sign: []const u8 = if (synth.fenv_amount >= 0.0) "+" else "";
            try w.print("{s}{d:.1} oct",  .{ sign, synth.fenv_amount });
        },
        24 => try w.print("{d:.3} s",     .{synth.fenv_attack_s}),
        25 => try w.print("{d:.3} s",     .{synth.fenv_decay_s}),
        26 => try w.print("{d:.3}",       .{synth.fenv_sustain}),
        27 => try w.print("{d:.3} s",     .{synth.fenv_release_s}),
        28 => try w.writeAll(switch (synth.lfo_shape) {
            .sine => "sine", .triangle => "tri", .saw => "saw", .square => "sqr",
        }),
        29 => try w.print("{d:.2} Hz",    .{synth.lfo_rate_hz}),
        30 => try w.print("{d:.2}",       .{synth.lfo_depth}),
        31 => try w.writeAll(switch (synth.lfo_target) {
            .none => "off", .filter => "filter", .pitch => "pitch", .amp => "amp",
        }),
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
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

