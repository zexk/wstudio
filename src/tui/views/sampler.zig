//! Sampler / drum-pad editor view, waveform draw, + its status bar.

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

/// Names for the sampler param rows, indexed by `app.sampler_param`. Indices
/// 10-11 (root, voice) apply only to the standalone Sampler, not drum pads.
const sampler_param_labels = [_][]const u8{
    "start", "end", "pitch", "attack", "decay", "sustain", "release", "gain", "pan", "reverse", "root", "voice",
};

/// Waveform panel caps: width in columns (was 120 — bumped so wide terminals
/// use their space) and height in rows (min'd against the leftover row
/// budget, so short terminals see the same 7-8 rows as before). Mirrored by
/// editors/sampler.zig's waveformNorm/waveRows for mouse hit-testing.
pub const wave_max_w: usize = 240;
pub const wave_max_rows: usize = 14;

pub fn drawSamplerEditor(
    app: anytype,
    w: *std.Io.Writer,
    rows: usize,
    cols: usize,
    snap: engine_mod.UiSnapshot,
) !void {
    _ = snap;
    const c = app.sampler_param;
    const is_drum = app.sampler_target == .drum;

    // Wide terminals: stretch the param bars (and the section rules with
    // them) into the free width. Compact stays exactly as before below
    // 100 cols; the knobs were reset to the defaults by App.draw.
    style.form_bar_w = @min(style.form_bar_w_default + (cols -| 100) / 2, 40);
    style.form_section_w = style.form_section_w_default + (style.form_bar_w - style.form_bar_w_default);

    // Resolve the pad being edited and the surrounding labels from the target.
    const track_idx = app.sampler_target.track();
    const track_name = if (track_idx < app.session.project.tracks.items.len)
        app.session.project.tracks.items[track_idx].name
    else
        "?";
    const pad_idx = app.drum_cursor[0];
    const pad: *const ws.dsp.Pad = if (is_drum) padOf(app.drumMachine(), pad_idx) else blk: {
        if (app.editingSampler()) |s| break :blk &s.pad;
        break :blk placeholderPad();
    };

    // Body budget: the caller's header + transport + status (4 rows total,
    // no separate hr() rule rows anymore) are reserved outside `rows`.
    const body = rows -| 4;
    var written: usize = 0;

    // ── Title ────────────────────────────────────
    try w.writeAll(bcyn ++ bold ++ " \u{2593} " ++ rst);
    try w.writeAll(if (is_drum) icons.drum else icons.sampler);
    try w.writeAll(bcyn ++ bold ++ " SAMPLER " ++ rst);
    try w.writeAll(acc);
    try w.print("\"{s}\"", .{track_name});
    try w.writeAll(rst ++ dim);
    if (is_drum) {
        try w.print("  pad {d}/{d} ", .{ pad_idx + 1, DrumMachine.max_pads });
        try w.writeAll(rst ++ acc);
        try w.print("\"{s}\"", .{app.drumMachine().padName(pad_idx)});
        try w.writeAll(rst);
    } else {
        try w.writeAll(rst ++ acc);
        try w.print("\"{s}\"", .{if (app.editingSampler()) |s| s.clipName() else "clip"});
        try w.writeAll(rst);
    }
    try endLine(w);
    written += 1;

    // ── Waveform panel ───────────────────────────
    // The section headers + param rows need ~13 (drum) / ~16 (sampler) lines;
    // give the waveform whatever vertical space remains, capped for readability.
    const param_lines: usize = if (is_drum) 13 else 17;
    const wave_rows: usize = @min(wave_max_rows, body -| (written + param_lines));
    if (wave_rows >= 2) {
        try drawWaveformPad(w, pad, cols, wave_rows);
        written += wave_rows;
    }

    var buf: [40]u8 = undefined;

    // zig fmt: off
    // ── SAMPLE ───────────────────────────────────
    try synthSection(w, "SAMPLE", acc);
    written += 1;
    try barRow(w, c == 0, false, acc, "start", pad.start_norm, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{pad.start_norm}));
    try barRow(w, c == 1, false, acc, "end", pad.end_norm, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{pad.end_norm}));
    {
        const semi = pad.pitch_semitones;
        try barRow(w, c == 2, false, acc, "pitch", semi + 24.0, 48.0,
            try std.fmt.bufPrint(&buf, "{s}{d:.0} st", .{ if (semi >= 0) "+" else "", semi }));
    }
    written += 3;

    // ── AMP ENV ──────────────────────────────────
    try synthSection(w, "AMP ENV", grn);
    written += 1;
    try barRow(w, c == 3, false, grn, "attack", pad.attack_s, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.attack_s}));
    try barRow(w, c == 4, false, grn, "decay", pad.decay_s, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.decay_s}));
    try barRow(w, c == 5, false, grn, "sustain", pad.sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{pad.sustain}));
    try barRow(w, c == 6, false, grn, "release", pad.release_s, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.release_s}));
    written += 4;

    // ── OUT ──────────────────────────────────────
    try synthSection(w, "OUT", bcyn);
    written += 1;
    try barRow(w, c == 7, false, bcyn, "gain", pad.gain, 2.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{pad.gain}));
    {
        const pan = pad.pan;
        const lab = if (@abs(pan) < 0.005)
            try std.fmt.bufPrint(&buf, "C", .{})
        else if (pan < 0)
            try std.fmt.bufPrint(&buf, "L{d:.0}", .{-pan * 100})
        else
            try std.fmt.bufPrint(&buf, "R{d:.0}", .{pan * 100});
        try barRow(w, c == 8, false, bcyn, "pan", pan + 1.0, 2.0, lab);
    }
    {
        const rev_names = [_][]const u8{ "off", "on" };
        try enumRow(w, c == 9, false, bcyn, "reverse", &rev_names, if (pad.reverse) 1 else 0);
    }
    written += 3;

    // ── KEY (standalone sampler only): the root note ─────────────────────────
    if (!is_drum) {
        try synthSection(w, "KEY", grn);
        written += 1;
        const root: u7 = if (app.editingSampler()) |s| s.root_note else 60;
        var nbuf: [5]u8 = undefined;
        try barRow(w, c == 10, false, grn, "root", @floatFromInt(root), 127.0,
            try std.fmt.bufPrint(&buf, "{s} ({d})", .{ midi.noteName(root, &nbuf), root }));
        written += 1;
        const mono = if (app.editingSampler()) |s| s.mono else false;
        const voice_names = [_][]const u8{ "poly", "mono" };
        try enumRow(w, c == 11, false, grn, "voice", &voice_names, if (mono) 1 else 0);
        written += 1;
    }
    // zig fmt: on

    while (written < body) : (written += 1) try endLine(w);
}

/// A shared zero-length pad used when an editor has no real pad to show — keeps
/// drawing renderable without optionals or unreachable branches.
fn placeholderPad() *const ws.dsp.Pad {
    const holder = struct {
        var p: ws.dsp.Pad = .{ .samples = &[_]f32{} };
    };
    return &holder.p;
}

/// Return a const pointer to pad `idx`'s underlying Pad, or a placeholder if
/// the pad is out of range or not yet materialized (lazy-alloc pads).
fn padOf(dm: anytype, idx: u8) *const ws.dsp.Pad {
    if (idx >= DrumMachine.max_pads) return placeholderPad();
    return if (dm.pads[idx]) |*s| &s.pad else placeholderPad();
}

/// Render a centered, filled waveform of `pad` over `wave_rows` rows. Samples
/// inside the play region are drawn in accent; outside is dim. The start/end
/// markers are drawn as bright vertical bars.
fn drawWaveformPad(
    w: *std.Io.Writer,
    pad: *const ws.dsp.Pad,
    cols: usize,
    wave_rows: usize,
) !void {
    const gutter = 2;
    const width = @min(cols -| gutter, wave_max_w);
    const len = pad.samples.len;
    if (len == 0) {
        for (0..wave_rows) |_| {
            try w.writeAll(dim ++ "  (no sample)" ++ rst);
            try endLine(w);
        }
        return;
    }

    // Per-column peak amplitude over the column's sample bucket.
    var amp: [wave_max_w]f32 = undefined;
    var peak: f32 = 1e-6;
    for (0..width) |x| {
        var a: f32 = 0;
        if (len > 0) {
            const lo = x * len / width;
            const hi = @max(lo + 1, (x + 1) * len / width);
            var j = lo;
            while (j < hi and j < len) : (j += 1) a = @max(a, @abs(pad.samples[j]));
        }
        amp[x] = a;
        peak = @max(peak, a);
    }
    // Normalise to the loudest column so quiet samples are still visible.
    const inv_peak = 1.0 / peak;

    const start_col: usize = @intFromFloat(@as(f32, @floatCast(pad.start_norm)) * @as(f32, @floatFromInt(width)));
    const end_col: usize = @intFromFloat(@as(f32, @floatCast(pad.end_norm)) * @as(f32, @floatFromInt(width)));

    const center = @as(f32, @floatFromInt(wave_rows)) / 2.0;
    for (0..wave_rows) |row| {
        try w.writeAll("  ");
        const d_from_center = @abs(@as(f32, @floatFromInt(row)) + 0.5 - center);
        for (0..width) |x| {
            const is_marker = (x == start_col or x == end_col);
            const in_region = x >= start_col and x <= end_col;
            const radius = amp[x] * inv_peak * center;
            const filled = d_from_center <= radius;

            if (is_marker) {
                try w.writeAll(bcyn ++ bold ++ "\u{2503}" ++ rst); // ┃
            } else if (filled) {
                try w.writeAll(if (in_region) acc else dim);
                try w.writeAll("\u{2588}"); // █
                try w.writeAll(rst);
            } else if (row == @as(usize, @intFromFloat(center))) {
                try w.writeAll(dim ++ "\u{2500}" ++ rst); // ─ zero axis
            } else {
                try w.writeByte(' ');
            }
        }
        try endLine(w);
    }
}

pub fn drawSamplerStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    const is_drum = app.sampler_target == .drum;
    const pad_idx = app.drum_cursor[0];
    const pad: *const ws.dsp.Pad = if (is_drum) padOf(app.drumMachine(), pad_idx) else blk: {
        if (app.editingSampler()) |s| break :blk &s.pad;
        break :blk placeholderPad();
    };
    const cur = @min(@as(usize, app.sampler_param), sampler_param_labels.len - 1);

    // zig fmt: off
    try style.writeModeBadge(w, app.modal.mode);
    try style.writeViewBadge(right, "SAMPLER", app.modal.mode);
    if (is_drum) {
        try w.writeAll(dim ++ "  pad " ++ rst);
        try w.print("{d}", .{pad_idx + 1});
    }
    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(sampler_param_labels[cur]);
    try w.writeAll(dim ++ ": " ++ rst);
    try w.writeAll(acc);
    switch (app.sampler_param) {
        0 => try w.print("{d:.2}", .{pad.start_norm}),
        1 => try w.print("{d:.2}", .{pad.end_norm}),
        2 => try w.print("{s}{d:.0} st", .{ if (pad.pitch_semitones >= 0) "+" else "", pad.pitch_semitones }),
        3 => try w.print("{d:.3} s", .{pad.attack_s}),
        4 => try w.print("{d:.3} s", .{pad.decay_s}),
        5 => try w.print("{d:.3}", .{pad.sustain}),
        6 => try w.print("{d:.3} s", .{pad.release_s}),
        7 => try w.print("{d:.2}", .{pad.gain}),
        8 => try w.writeAll(if (@abs(pad.pan) < 0.005) "C" else if (pad.pan < 0) "L" else "R"),
        9 => try w.writeAll(if (pad.reverse) "on" else "off"),
        10 => {
            const root: u7 = if (app.editingSampler()) |s| s.root_note else 60;
            var nbuf: [5]u8 = undefined;
            try w.writeAll(midi.noteName(root, &nbuf));
        },
        11 => try w.writeAll(if (app.editingSampler()) |s| (if (s.mono) "mono" else "poly") else "poly"),
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

// zig fmt: on
