//! Sampler / drum-pad editor view, waveform draw, + its status bar.

const std = @import("std");
const ws = @import("wstudio");
const DrumMachine = ws.dsp.DrumMachine;
const Sampler = ws.dsp.Sampler;
const engine_mod = ws.engine;
const midi = ws.midi;
const style = @import("../style.zig");
const icons = @import("../../ui/icons.zig");
const format = @import("../../ui/format.zig");

// Bare-name aliases for the shared palette/primitives.
const rst = style.rst;
const bold = style.bold;
const dim = style.dim;
const acc = style.acc;
const grn = style.grn;
const bcyn = style.bcyn;
const mag = style.mag;
const yel = style.yel;
const sel = style.sel;
const endLine = style.endLine;
const hr = style.hr;
const synthSection = style.synthSection;
const barRow = style.barRow;
const enumRow = style.enumRow;

// Waveform panel caps live with the editor (ui/editors/sampler.zig) since
// its waveformNorm/waveRows mouse hit-testing mirrors this draw path.
const sampler_ed = @import("../../ui/editors/sampler.zig");
const wave_max_w = sampler_ed.wave_max_w;
const wave_max_rows = sampler_ed.wave_max_rows;
const waveform = @import("../../ui/waveform.zig");

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
    const is_slice = app.sampler_target == .slice;
    // Drum pads and slices share the compact 10-param layout (no KEY
    // section); only the standalone Sampler gets root/voice rows.
    const pad_target = is_drum or is_slice;

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
    const pad_idx: u8 = @intCast(app.drum_cursor[0]);
    const pad: *const ws.dsp.Pad = if (is_drum) padOf(app.drumMachine(), pad_idx) else if (is_slice) sliceOf(app) else blk: {
        if (app.editingSampler()) |s| break :blk &s.pad;
        break :blk ws.dsp.pad.emptyPad();
    };

    // Body budget: the caller's header + transport + status (4 rows total,
    // no separate hr() rule rows anymore) are reserved outside `rows`.
    const body = rows -| 4;
    var written: usize = 0;

    // ── Title ────────────────────────────────────
    try w.writeAll(bcyn ++ bold ++ " \u{2593} " ++ rst);
    const kind_icon: []const u8 = if (is_drum) icons.drum else if (is_slice) icons.slicer else icons.sampler;
    try w.writeAll(icons.iconOr(kind_icon, ""));
    if (icons.font_installed) try w.writeAll(" ");
    try w.writeAll(bcyn ++ bold);
    try w.writeAll(if (is_drum) "DRUM MACHINE " else if (is_slice) "SLICER " else "SAMPLER ");
    try w.writeAll(rst ++ acc);
    try w.print("\"{s}\"", .{track_name});
    try w.writeAll(rst ++ dim);
    if (is_drum) {
        try w.print("  pad {d}/{d} ", .{ pad_idx + 1, DrumMachine.max_pads });
        try w.writeAll(rst ++ acc);
        try w.print("\"{s}\"", .{app.drumMachine().padName(pad_idx)});
        try w.writeAll(rst);
    } else if (is_slice) {
        if (app.slicerInst().slice_count == 0)
            try w.writeAll("  no slices ")
        else
            try w.print("  slice {d}/{d} ", .{ app.slicer_cursor[0] + 1, app.slicerInst().slice_count });
        try w.writeAll(rst ++ acc);
        try w.print("\"{s}\"", .{app.slicerInst().clipName()});
        try w.writeAll(rst);
    } else {
        try w.writeAll(rst ++ acc);
        try w.print("\"{s}\"", .{if (app.editingSampler()) |s| s.clipName() else "clip"});
        try w.writeAll(rst);
    }
    try endLine(w);
    written += 1;

    if (is_drum) {
        try drawDrumBank(app, w, pad_idx);
        written += 3;
    } else if (is_slice and pad.samples.len > 0) {
        try drawSliceMap(app, w, cols);
        written += 3;
    }

    if (pad_target and pad.samples.len == 0) {
        try synthSection(w, "SAMPLE", acc);
        written += 1;
        try w.writeAll(dim);
        try w.writeAll(if (is_drum) "  This pad has no sample." else if (app.slicerInst().hasAudio()) "  Audio loaded, but no slices exist." else "  No audio loaded for this slicer.");
        try w.writeAll(rst);
        try endLine(w);
        written += 1;
        if (is_slice and app.slicerInst().hasAudio())
            try w.writeAll(acc ++ "  enter" ++ rst ++ dim ++ "  open the slice grid to chop" ++ rst)
        else
            try w.writeAll(acc ++ "  enter" ++ rst ++ dim ++ " / " ++ rst ++ acc ++ ":load" ++ rst ++ dim ++ "  open the sample browser" ++ rst);
        try endLine(w);
        written += 1;
        while (written < body) : (written += 1) try endLine(w);
        return;
    }

    // ── Waveform panel ───────────────────────────
    // The section headers + param rows need ~22 (pad/slice) / ~26 (sampler)
    // lines; give the waveform whatever vertical space remains, capped for
    // readability.
    const param_lines = sampler_ed.paramLineCount(pad_target);
    const wave_rows: usize = @min(wave_max_rows, body -| (written + param_lines));
    if (wave_rows >= 2) {
        try drawWaveformPad(w, pad, app.session.project.sample_rate, cols, wave_rows);
        written += wave_rows;
    }

    var buf: [40]u8 = undefined;
    const duration = @max(ws.dsp.pad.playDurationSeconds(pad, app.session.project.sample_rate), 0.001);

    // zig fmt: off
    // ── SAMPLE ───────────────────────────────────
    try synthSection(w, sampler_ed.pad_sections[0].title, acc);
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
    try barRow(w, c == 12, false, acc, "stretch", pad.stretch_ratio, 4.0,
        try std.fmt.bufPrint(&buf, "{d:.2}x", .{pad.stretch_ratio}));
    try enumRow(w, c == 20, pad.stretch_ratio == 1, acc, "warp", &ws.dsp.pad.warp_method_names, @intFromEnum(pad.warp_method));
    {
        try enumRow(w, c == 14, false, acc, "play", &ws.dsp.pad.play_mode_names, @intFromEnum(ws.dsp.pad.playMode(pad)));
        try enumRow(w, c == 19, false, acc, "loop", &ws.dsp.pad.loop_mode_names, @intFromEnum(pad.loop));
    }
    written += 7;

    // ── AMP ENV ──────────────────────────────────
    try synthSection(w, sampler_ed.pad_sections[1].title, grn);
    written += 1;
    try barRow(w, c == 3, false, grn, "attack", pad.attack_s, duration,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.attack_s}));
    try barRow(w, c == 4, false, grn, "decay", pad.decay_s, duration,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.decay_s}));
    try barRow(w, c == 5, false, grn, "sustain", pad.sustain, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.3}", .{pad.sustain}));
    try barRow(w, c == 6, false, grn, "release", pad.release_s, duration,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.release_s}));
    written += 4;

    // ── OUT ──────────────────────────────────────
    try synthSection(w, sampler_ed.pad_sections[2].title, bcyn);
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
    try barRow(w, c == 13, false, bcyn, "filter", pad.filter + 1.0, 2.0,
        format.filterLabel(&buf, pad.filter));
    written += 4;

    // ── FADE: edit fades multiplied on top of the amp envelope ───────────────
    try synthSection(w, sampler_ed.pad_sections[3].title, acc);
    written += 1;
    try barRow(w, c == 10, false, acc, "fade in", pad.fade_in_s, duration,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.fade_in_s}));
    try barRow(w, c == 11, false, acc, "fade out", pad.fade_out_s, duration,
        try std.fmt.bufPrint(&buf, "{d:.3} s", .{pad.fade_out_s}));
    written += 2;

    // ── MOD: per-pad LFO offsetting one of pitch/gain/pan/filter ─────────────
    try synthSection(w, sampler_ed.pad_sections[4].title, bcyn);
    written += 1;
    try barRow(w, c == 15, false, bcyn, "rate", pad.mod_rate_hz, 20.0,
        try std.fmt.bufPrint(&buf, "{d:.2} Hz", .{pad.mod_rate_hz}));
    try barRow(w, c == 16, false, bcyn, "depth", pad.mod_depth, 1.0,
        try std.fmt.bufPrint(&buf, "{d:.2}", .{pad.mod_depth}));
    try enumRow(w, c == 17, false, bcyn, "shape", &ws.dsp.lfo.shape_names, @intFromEnum(pad.mod_shape));
    try enumRow(w, c == 18, false, bcyn, "dest", &ws.dsp.pad.mod_dest_names, @intFromEnum(pad.mod_dest));
    written += 4;

    // ── KEY (standalone sampler only): the root note ─────────────────────────
    if (!pad_target) {
        try synthSection(w, sampler_ed.key_section.title, grn);
        written += 1;
        const root: u7 = if (app.editingSampler()) |s| s.root_note else 60;
        var nbuf: [5]u8 = undefined;
        try barRow(w, c == Sampler.root_note_id, false, grn, "root", @floatFromInt(root), 127.0,
            try std.fmt.bufPrint(&buf, "{s} ({d})", .{ midi.noteName(root, &nbuf), root }));
        written += 1;
        const mono = if (app.editingSampler()) |s| s.mono else false;
        const voice_names = [_][]const u8{ "poly", "mono" };
        try enumRow(w, c == Sampler.mono_id, false, grn, "voice", &voice_names, if (mono) 1 else 0);
        written += 1;
    }
    // zig fmt: on

    while (written < body) : (written += 1) try endLine(w);
}

fn drawDrumBank(app: anytype, w: *std.Io.Writer, selected: u8) !void {
    const dm = app.drumMachine();
    const bank_start = selected / 8 * 8;
    var title_buf: [32]u8 = undefined;
    try synthSection(w, try std.fmt.bufPrint(&title_buf, "PAD BANK {d}/{d}", .{ selected / 8 + 1, DrumMachine.max_pads / 8 }), mag);
    for (0..2) |row| {
        try w.writeAll("  ");
        for (0..4) |column| {
            const index: u8 = bank_start + @as(u8, @intCast(row * 4 + column));
            const active = index == selected;
            try w.writeAll(if (active) sel else if (dm.pads[index] == null) dim else rst);
            try w.print(" {d: >2} {s: <8} ", .{ index + 1, dm.padName(index) });
            try w.writeAll(rst);
        }
        try endLine(w);
    }
}

fn drawSliceMap(app: anytype, w: *std.Io.Writer, cols: usize) !void {
    const sl = app.slicerInst();
    const width = @min(cols -| 4, wave_max_w);
    const selected: u8 = @intCast(app.slicer_cursor[0]);
    const bank_start = selected / 8 * 8;
    const bank_count = @max(1, (sl.slice_count + 7) / 8);
    var title_buf: [32]u8 = undefined;
    try synthSection(w, try std.fmt.bufPrint(&title_buf, "SLICE MAP {d}/{d}", .{ selected / 8 + 1, bank_count }), mag);
    try w.writeAll("  ");
    for (0..8) |offset| {
        const index: u8 = bank_start + @as(u8, @intCast(offset));
        if (index >= sl.slice_count) {
            try w.writeAll(dim ++ " --      " ++ rst);
            continue;
        }
        try w.writeAll(if (index == selected) sel else rst);
        try w.print(" {d: >2} {d: >3}% ", .{ index + 1, sl.slices[index].start_norm * 100 });
        try w.writeAll(rst);
    }
    try endLine(w);
    try w.writeAll("  ");
    for (0..width) |column| {
        const norm = @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(@max(width -| 1, 1)));
        var slice: ?u8 = null;
        for (0..sl.slice_count) |index| {
            if (norm >= sl.slices[index].start_norm and norm <= sl.slices[index].end_norm) slice = @intCast(index);
        }
        if (slice) |index| {
            try w.writeAll(if (index == app.slicer_cursor[0]) yel ++ bold else dim);
            try w.writeAll(if (@abs(norm - sl.slices[index].start_norm) < 1.0 / @as(f32, @floatFromInt(width))) "\u{2503}" else "\u{2501}");
            try w.writeAll(rst);
        } else try w.writeByte(' ');
    }
    try endLine(w);
}

/// Return a const pointer to pad `idx`'s underlying Pad, or a placeholder if
/// the pad is out of range or not yet materialized (lazy-alloc pads).
fn padOf(dm: anytype, idx: u8) *const ws.dsp.Pad {
    if (idx >= DrumMachine.max_pads) return ws.dsp.pad.emptyPad();
    return if (dm.pads[idx]) |*s| &s.pad else ws.dsp.pad.emptyPad();
}

/// The cursor slice's Pad, or a placeholder past the slice count.
fn sliceOf(app: anytype) *const ws.dsp.Pad {
    const sl = app.slicerInst();
    if (app.slicer_cursor[0] >= sl.slice_count) return ws.dsp.pad.emptyPad();
    return &sl.slices[app.slicer_cursor[0]];
}

/// Render a centered, filled waveform of `pad` over `wave_rows` rows. Samples
/// inside the play region are drawn in accent; outside is dim. The start/end
/// markers are drawn as bright vertical bars.
/// Waveform tint per frequency band. Warm for lows, the usual accent for the
/// body, cool-bright for air - the low/high pair has to stay legible against
/// `dim` (out of region) and `bcyn` (the trim markers), which rules out
/// reusing either.
pub fn bandColor(band: waveform.Band) []const u8 {
    return switch (band) {
        .low => mag,
        .mid => acc,
        .high => yel,
    };
}

fn drawWaveformPad(
    w: *std.Io.Writer,
    pad: *const ws.dsp.Pad,
    sample_rate: u32,
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

    // Per-column peak amplitude over the column's sample bucket, with the
    // region drawn on the timeline it actually plays on (pitch compresses,
    // stretch expands - see ui/waveform.zig).
    const scale = waveform.timeScale(pad.pitch_semitones, pad.stretch_ratio);
    var amp: [wave_max_w]f32 = undefined;
    waveform.peakBucketsWarped(pad.samples, amp[0..width], pad.start_norm, pad.end_norm, scale);
    // Tint each in-region column by its frequency content, the way a DJ
    // waveform does: bass reads at a glance, so a kick and a hat are
    // distinguishable without zooming in on their shapes.
    var bands: [wave_max_w]waveform.Band = undefined;
    waveform.bandBuckets(pad.samples, bands[0..width], sample_rate, pad.start_norm, pad.end_norm, scale);
    var peak: f32 = 1e-6;
    for (amp[0..width]) |a| peak = @max(peak, a);
    // Normalise to the loudest column so quiet samples are still visible.
    const inv_peak = 1.0 / peak;

    const start_col: usize = @intFromFloat(@as(f32, @floatCast(pad.start_norm)) * @as(f32, @floatFromInt(width)));
    const end_col: usize = @intFromFloat(@as(f32, @floatCast(pad.end_norm)) * @as(f32, @floatFromInt(width)));
    // The trim markers stay on their source columns; the accent fill follows
    // playback, so a stretched pad reads past its end marker.
    const played_col: usize = @intFromFloat(waveform.playedEndNorm(pad.start_norm, pad.end_norm, scale) * @as(f32, @floatFromInt(width)));

    const center = @as(f32, @floatFromInt(wave_rows)) / 2.0;
    for (0..wave_rows) |row| {
        try w.writeAll("  ");
        const d_from_center = @abs(@as(f32, @floatFromInt(row)) + 0.5 - center);
        for (0..width) |x| {
            const is_marker = (x == start_col or x == end_col);
            const in_region = x >= start_col and x <= played_col;
            const radius = amp[x] * inv_peak * center;
            const filled = d_from_center <= radius;

            if (is_marker) {
                try w.writeAll(bcyn ++ bold ++ "\u{2503}" ++ rst); // ┃
            } else if (filled) {
                try w.writeAll(if (in_region) bandColor(bands[x]) else dim);
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

// zig fmt: on
