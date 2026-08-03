//! Per-view footer status renderers, shared by both frontends. The TUI
//! writes these SGR-styled bytes straight to the terminal (tui/tui.zig's
//! draw); the GUI strips the codes and re-renders the plain text with its
//! own presentation (gui/chrome.zig's tuiStatusText). Each view's body
//! renderer stays in tui/views/<name>.zig - only the status line moved
//! here, since it's the one piece of view output the GUI also consumes.

const std = @import("std");
const ws = @import("wstudio");
const DrumMachine = ws.dsp.DrumMachine;
const Slicer = ws.dsp.Slicer;
const Sampler = ws.dsp.Sampler;
const ansi = @import("ansi.zig");
const format = @import("format.zig");
const icons = @import("icons.zig");
const spectrum_ed = @import("editors/spectrum.zig");
const synth_ed = @import("editors/synth.zig");
const synth_layout = @import("synth_layout.zig");
const automation_ed = @import("editors/automation.zig");

const rst = ansi.rst;
const bold = ansi.bold;
const dim = ansi.dim;
const acc = ansi.acc;
const red = ansi.red;
const yel = ansi.yel;
const blu = ansi.blu;
const bcyn = ansi.bcyn;
const writeModeBadge = ansi.writeModeBadge;
const writeViewBadge = ansi.writeViewBadge;
const writeViewBadgeColored = ansi.writeViewBadgeColored;
const BadgeTone = ansi.BadgeTone;

const eq_mod = ws.dsp.eq;
const automation_mod = ws.dsp.automation;

const midi = ws.midi;

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

pub fn drawTracksStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, "TRACKS", app.modal.mode);
    // row position - display rows (tracks + groups) + 1 for master
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{d}/{d}", .{ app.track_row + 1, app.track_rows_len + 1 });
    try w.writeAll(dim ++ "  oct " ++ rst);
    try w.print("{d}", .{app.modal.octave});
    if (app.modal.count > 0) try w.print("  {d}", .{app.modal.count});
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    } else {
        try w.writeAll(dim ++ "  " ++ rst);
        if (app.track_row == app.track_rows_len) {
            try w.writeAll("enter/s: fx  -/+: gain  ?: help");
        } else if (app.cursorGroup() != null) {
            try w.writeAll("enter/s: fx  z: fold  -/+: gain  R: rename");
        } else if (app.cursorTrack()) |ti| {
            const track = app.session.project.tracks.items[ti];
            switch (std.meta.activeTag(app.session.racks.items[ti].instrument)) {
                .empty => try w.writeAll("enter: instrument  a: add track  ?: help"),
                .poly_synth, .sampler, .clap, .vst3, .soundfont, .acoustic => try w.print("enter: edit  p: piano  s: fx  m: {s}", .{if (track.muted) "unmute" else "mute"}),
                .drum_machine, .slicer => try w.print("enter: grid  s: fx  m: {s}  R: rename", .{if (track.muted) "unmute" else "mute"}),
            }
        } else {
            try w.writeAll("?: help  space: play  tab: song");
        }
    }
}

pub fn drawDrumStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    const p = app.drum_cursor[0];
    const s = app.drum_cursor[1];
    const dm = app.drumMachine();
    try writeModeBadge(w, app.modal.mode);
    try right.print(bcyn ++ "{s}" ++ rst ++ "  ", .{app.drum_grid.label()});
    try writeViewBadge(right, "DRUM", app.modal.mode);
    try w.writeAll(dim ++ "  pad " ++ rst);
    try w.print("{d}/{d}", .{ p + 1, DrumMachine.max_pads });
    try w.writeAll(dim ++ "  step " ++ rst);
    try w.print("{d}/{d}", .{ s + 1, dm.step_count });
    try w.writeAll(dim ++ "  len " ++ rst);
    try w.print("{d}", .{dm.step_count});
    try w.writeAll(dim ++ "  swing " ++ rst);
    try w.print("{d:.0}%", .{dm.swing.load(.monotonic)});
    if (dm.stepActive(@intCast(p), s)) {
        try w.writeAll(dim ++ "  vel " ++ rst);
        try w.print("{d}", .{dm.stepVel(@intCast(p), s)});
        // Only shown once tuned - an untuned step is the overwhelming case
        // and a permanent "tune 0" would just be noise on the status line.
        const semis = dm.stepTune(@intCast(p), s);
        if (semis != 0) {
            try w.writeAll(dim ++ "  tune " ++ rst);
            try w.print("{s}{d}", .{ if (semis > 0) "+" else "", semis });
        }
        const prob = dm.stepProb(@intCast(p), s);
        if (prob != 100) {
            try w.writeAll(dim ++ "  chance " ++ rst);
            try w.print("{d}%", .{prob});
        }
        const cond = dm.stepCond(@intCast(p), s);
        if (cond != .always) {
            try w.writeAll(dim ++ "  cond " ++ rst);
            try w.writeAll(cond.label());
        }
        const roll = dm.stepRetrig(@intCast(p), s);
        if (roll >= 2) {
            try w.writeAll(dim ++ "  roll " ++ rst);
            try w.print("x{d}", .{roll});
        }
        const micro = dm.stepMicro(@intCast(p), s);
        if (micro != 0) {
            try w.writeAll(dim ++ "  micro " ++ rst);
            try w.print("{s}{d}%", .{ if (micro > 0) "+" else "", micro });
        }
    }
    // The fill switch is machine-wide and changes what plays, so it stays
    // visible while engaged rather than only on the step that reads it.
    if (dm.fill_on.load(.monotonic)) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(bold);
        try w.writeAll("FILL");
        try w.writeAll(rst);
    }
    if (dm.choke_group[p] != 0) {
        try w.writeAll(dim ++ "  choke " ++ rst);
        try w.print("{d}", .{dm.choke_group[p]});
    }
    // Same "only when it differs" rule as tune above: almost every row
    // follows the pattern, and saying so on every frame is noise.
    if (dm.pad_len[p] != 0) {
        try w.writeAll(dim ++ "  loop " ++ rst);
        try w.print("{d}", .{dm.padSteps(@intCast(p), dm.step_count)});
    }
    try w.writeAll("  ");
    try w.writeAll(bold);
    try w.writeAll(dm.padName(@intCast(p)));
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

pub fn drawSlicerStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    const sl = app.slicerInst();
    const sIdx: u8 = @intCast(app.slicer_cursor[0]);
    const s = app.slicer_cursor[1];
    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, "SLICER", app.modal.mode);
    try w.writeAll(dim ++ "  pat " ++ rst);
    try w.print("{c}", .{Slicer.variantLetter(sl.variant)});
    try w.writeAll(dim ++ "  slice " ++ rst);
    try w.print("{d}/{d}", .{ sIdx + 1, sl.slice_count });
    try w.writeAll(dim ++ "  step " ++ rst);
    try w.print("{d}/{d}", .{ s + 1, sl.step_count });
    if (sl.stepActive(sIdx, s)) {
        try w.writeAll(dim ++ "  vel " ++ rst);
        try w.print("{d}", .{sl.stepVel(sIdx, s)});
        // Each parameter lock only appears once set - same "an unset lock is
        // the overwhelming case, and saying so every frame is noise" rule the
        // drum status above follows.
        const semis = sl.stepTune(sIdx, s);
        if (semis != 0) {
            try w.writeAll(dim ++ "  tune " ++ rst);
            try w.print("{s}{d}", .{ if (semis > 0) "+" else "", semis });
        }
        const prob = sl.stepProb(sIdx, s);
        if (prob != 100) {
            try w.writeAll(dim ++ "  chance " ++ rst);
            try w.print("{d}%", .{prob});
        }
        const cond = sl.stepCond(sIdx, s);
        if (cond != .always) {
            try w.writeAll(dim ++ "  cond " ++ rst);
            try w.writeAll(cond.label());
        }
        const roll = sl.stepRetrig(sIdx, s);
        if (roll >= 2) {
            try w.writeAll(dim ++ "  roll " ++ rst);
            try w.print("x{d}", .{roll});
        }
        const micro = sl.stepMicro(sIdx, s);
        if (micro != 0) {
            try w.writeAll(dim ++ "  micro " ++ rst);
            try w.print("{s}{d}%", .{ if (micro > 0) "+" else "", micro });
        }
    }
    // Machine-wide and changes what plays, so it stays visible while engaged
    // rather than only on the steps that read it.
    if (sl.fill_on.load(.monotonic)) {
        try w.writeAll(dim ++ "  " ++ rst ++ bold ++ "FILL" ++ rst);
    }
    if (sl.slice_len[sIdx] != 0) {
        try w.writeAll(dim ++ "  loop " ++ rst);
        try w.print("{d}", .{sl.sliceSteps(sIdx, sl.step_count)});
    }
    try w.writeAll(dim ++ "  swing " ++ rst);
    try w.print("{d:.0}%", .{sl.swing.load(.monotonic)});
    if (sIdx < sl.slice_count) {
        const pad = &sl.slices[sIdx];
        try w.writeAll(dim ++ "  " ++ rst);
        try w.print("{d:.0}-{d:.0}%", .{ pad.start_norm * 100.0, pad.end_norm * 100.0 });
        if (@abs(pad.pitch_semitones) > 0.01) {
            try w.writeAll(dim ++ "  pitch " ++ rst);
            try w.print("{s}{d:.0}", .{ if (pad.pitch_semitones >= 0) "+" else "", pad.pitch_semitones });
        }
        if (pad.reverse) try w.writeAll(dim ++ "  " ++ blu ++ "rev" ++ rst);
    }
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

/// Shared footer keeps selection views inside the same status contract as the
/// editors: mode and identity stay visible while filtering or showing errors.
pub fn drawPickerStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer, label: []const u8, action: []const u8, filterable: bool) !void {
    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, label, app.modal.mode);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
    try w.writeAll(dim ++ "  " ++ rst ++ "j/k: move  g/G: ends");
    if (filterable) try w.writeAll("  /: filter");
    try w.print("  enter: {s}  esc: cancel", .{action});
}

/// Help's footer status row: the live `/` prompt while typing, otherwise
/// mode badge + any pending status message + the key hints - same
/// message-before-hints clamp ordering views/browser.zig documents.
pub fn drawHelpStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, "HELP", app.modal.mode);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
    try w.writeAll(dim ++ "  " ++ rst ++ "j/k: scroll  d/u: page  g/G: top/bottom  /: search  n/N: next/prev  ?/esc: close");
}

pub fn drawFxStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer, target: spectrum_ed.EqTarget) !void {
    const fx = spectrum_ed.fxPtr(app, target) orelse {
        if (app.status_len > 0) try w.print(" {s}", .{app.status_buf[0..app.status_len]});
        return;
    };
    if (spectrum_ed.focusedUnit(app, fx)) |unit| {
        const k = unit.kind();
        try writeModeBadge(w, app.modal.mode);
        try writeViewBadge(right, "FX", app.modal.mode);
        try w.writeAll(dim ++ "  " ++ rst);
        try w.print("{d}/{d} {s}", .{ app.fx_focus + 1, fx.units.items.len, spectrum_ed.unitLabel(k) });
        try w.writeAll(dim ++ "  " ++ rst);
        if (unit.bypassed) try w.writeAll(red ++ "BYP" ++ rst ++ "  ");
        const bf = spectrum_ed.eqBandField(app.fx_param);
        const eq_band_select = k == .eq and app.eq_band_select;
        switch (k) {
            // Band-select mode: no field is actually live yet, so show
            // which band instead of a param/value pair that h/l can't
            // touch until `enter` opens it.
            .eq => if (eq_band_select) {
                try w.print("band {d}/{d}", .{ bf.band + 1, eq_mod.num_eq_bands });
            } else {
                var vbuf: [16]u8 = undefined;
                var nbuf: [64]u8 = undefined;
                try w.print("b{d} {s} {s}", .{ bf.band + 1, spectrum_ed.formatParamName(&nbuf, &unit.payload, app.fx_param), spectrum_ed.formatValue(app, &vbuf, &unit.payload, app.fx_param) });
            },
            else => {
                var vbuf: [16]u8 = undefined;
                var nbuf: [64]u8 = undefined;
                try w.print("{s} {s}", .{ spectrum_ed.formatParamName(&nbuf, &unit.payload, app.fx_param), spectrum_ed.formatValue(app, &vbuf, &unit.payload, app.fx_param) });
            },
        }
        if (!eq_band_select) {
            try w.writeAll(dim ++ "  [" ++ rst);
            try w.print("{d}/{d}", .{ app.fx_param + 1, spectrum_ed.visibleParamCount(app, k, &unit.payload) });
            try w.writeAll(dim ++ "]" ++ rst);
        }
    } else {
        try writeModeBadge(w, app.modal.mode);
        try writeViewBadge(right, "FX", app.modal.mode);
        try w.writeAll(dim ++ "  chain empty: 'a' inserts an effect" ++ rst);
    }
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

pub fn drawSynthStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    switch (rack.instrument) {
        .poly_synth => {},
        else => return,
    }
    const synth = &rack.instrument.poly_synth;

    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, "SYNTH", app.modal.mode);
    try w.writeAll(dim ++ "  " ++ rst);
    var label_buf: [24]u8 = undefined;
    try w.writeAll(synth_ed.paramLabel(app.synth_cursor, &label_buf));
    try w.writeAll(dim ++ ": " ++ rst);
    try w.writeAll(acc);
    try synth_ed.writeParamValue(synth, app.synth_cursor, w);
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

pub fn drawPianoRollStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    if (app.piano_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.piano_track];
    const pp = if (rack.pattern_player != null)
        &app.session.racks.items[app.piano_track].pattern_player.?
    else
        return;
    // zig fmt: on

    var lbuf: [5]u8 = undefined;
    const label = ws.midi.noteName(@intCast(app.piano_cursor_pitch), &lbuf);
    const spb: u16 = app.pianoStepsPerBeat();
    const beat_pos = @as(f64, @floatFromInt(app.piano_cursor_step)) / @as(f64, @floatFromInt(spb));
    const beat_index = app.piano_cursor_step / spb;
    const beats_per_bar: u16 = app.session.project.beats_per_bar;
    const bar = beat_index / beats_per_bar + 1;
    const beat = beat_index % beats_per_bar + 1;
    const sub = app.piano_cursor_step % spb + 1;
    const note = pp.noteAt(app.piano_cursor_pitch, beat_pos);

    // zig fmt: off
    try writeModeBadge(w, app.modal.mode);
    try right.print(bcyn ++ "{s}" ++ rst ++ "  ", .{app.piano_division.label()});
    try writeViewBadge(right, "PIANO", app.modal.mode);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{s}", .{label});
    try w.writeAll(dim ++ "  pos " ++ rst);
    try w.print("{d}.{d}.{d}", .{ bar, beat, sub });
    if (note) |n| {
        try w.writeAll(dim ++ "  note " ++ rst);
        try w.print("{d:.2}b", .{n.duration_beat});
        try w.writeAll(dim ++ "  vel " ++ rst);
        try w.print("{d:.0}%", .{n.velocity * 100.0});
    } else {
        try w.writeAll(dim ++ "  new " ++ rst);
        try w.print("{d:.2}b", .{app.piano_note_len});
    }
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    } else if (note != null) {
        try w.writeAll(dim ++ "  [ ]: resize  < >: velocity  M: move" ++ rst);
    } else {
        try w.writeAll(dim ++ "  n/N: note/rest + advance  enter: toggle  a: hear" ++ rst);
    }
}

/// Names for the sampler param rows, indexed by `app.sampler_param`. The last
/// two (root, voice) apply only to the standalone Sampler, not drum pads.
const sampler_param_labels = [_][]const u8{
    "start", "end",      "pitch",    "attack",  "decay",  "sustain", "release", "gain", "pan",
    "reverse", "fade in", "fade out", "stretch", "filter", "play",    "root",    "voice",
};

pub fn drawSamplerStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    const is_drum = app.sampler_target == .drum;
    const is_slice = app.sampler_target == .slice;
    const pad_idx: u8 = @intCast(app.drum_cursor[0]);
    const pad: *const ws.dsp.Pad = if (is_drum) padOf(app.drumMachine(), pad_idx) else if (is_slice) sliceOf(app) else blk: {
        if (app.editingSampler()) |s| break :blk &s.pad;
        break :blk ws.dsp.pad.emptyPad();
    };
    const cur = @min(@as(usize, app.sampler_param), sampler_param_labels.len - 1);

    // zig fmt: off
    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, if (is_slice) "SLICE" else "SAMPLER", app.modal.mode);
    if (is_drum) {
        try w.writeAll(dim ++ "  pad " ++ rst);
        try w.print("{d}", .{pad_idx + 1});
    }
    if (is_slice) {
        try w.writeAll(dim ++ "  slice " ++ rst);
        try w.print("{d}", .{app.slicer_cursor[0] + 1});
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
        8 => try w.writeAll(format.panLetter(pad.pan)),
        9 => try w.writeAll(if (pad.reverse) "on" else "off"),
        10 => try w.print("{d:.3} s", .{pad.fade_in_s}),
        11 => try w.print("{d:.3} s", .{pad.fade_out_s}),
        12 => try w.print("{d:.2}x", .{pad.stretch_ratio}),
        13 => {
            var fbuf: [12]u8 = undefined;
            try w.writeAll(format.filterLabel(&fbuf, pad.filter));
        },
        14 => try w.writeAll(ws.dsp.pad.play_mode_names[@intFromEnum(ws.dsp.pad.playMode(pad))]),
        Sampler.root_note_id => {
            const root: u7 = if (app.editingSampler()) |s| s.root_note else 60;
            var nbuf: [5]u8 = undefined;
            try w.writeAll(midi.noteName(root, &nbuf));
        },
        Sampler.mono_id => try w.writeAll(if (app.editingSampler()) |s| (if (s.mono) "mono" else "poly") else "poly"),
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

/// Names for the soundfont param rows, indexed by `app.soundfont_param`.
const soundfont_param_labels = [_][]const u8{ "gain", "pan", "transpose", "preset" };

pub fn drawSoundfontStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, app.editingSoundfontLabel(), app.modal.mode);
    const sf = app.editingSoundfont();
    const cur = @min(@as(usize, app.soundfont_param), soundfont_param_labels.len - 1);

    try w.writeAll(dim ++ "  " ++ rst);
    try w.writeAll(soundfont_param_labels[cur]);
    try w.writeAll(dim ++ ": " ++ rst);
    try w.writeAll(acc);
    switch (app.soundfont_param) {
        0 => try w.print("{d:.2}", .{if (sf) |s| s.gain else 1.0}),
        1 => try w.writeAll(if (sf) |s| format.panLetter(s.pan) else "C"),
        2 => try w.print("{s}{d:.0} st", .{ if (sf != null and sf.?.transpose_semitones >= 0) "+" else "", if (sf) |s| s.transpose_semitones else 0.0 }),
        3 => if (sf) |s| {
            if (s.presetCount() == 0) try w.writeAll("(no font loaded)") else try w.print("{s} ({d}/{d})", .{ s.presetName(), s.preset_index + 1, s.presetCount() });
        } else try w.writeAll("(no font loaded)"),
        else => {},
    }
    try w.writeAll(rst);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

pub fn drawArrangementStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    // The song/pattern toggle (T) isn't a modal.Mode - it's arrangement-
    // specific playback state - so it stays its own plain-text segment
    // rather than folding into the mode badge, keeping both pieces of info
    // the old single combined badge carried.
    try writeModeBadge(w, app.modal.mode);
    try right.print(bcyn ++ "{s}" ++ rst ++ "  ", .{app.arr_grid.label()});
    if (app.session.song_mode) {
        try writeViewBadgeColored(right, "SONG", .green);
    } else {
        try writeViewBadgeColored(right, "PATTERN", .yellow);
    }

    const cursor_tick = app.arr_cursor_bar *| app.arr_grid.ticks();
    const ticks_per_bar = ws.time_grid.barTicks(app.session.project.beats_per_bar);
    try w.writeAll(dim ++ "  bar " ++ rst);
    try w.print("{d}.{d}", .{
        cursor_tick / ticks_per_bar + 1,
        (cursor_tick % ticks_per_bar) / ws.time_grid.ticks_per_beat + 1,
    });
    try w.writeAll(dim ++ "  track " ++ rst);
    try w.print("{d}/{d}", .{ app.cursor + 1, app.session.project.tracks.items.len });

    const p = &app.session.project;
    if (p.loop_enabled and p.loop_end_bar > p.loop_start_bar) {
        try w.writeAll(dim ++ "  " ++ rst ++ yel);
        try w.writeAll(icons.iconOr(icons.loop ++ " ", ""));
        try w.writeAll("loop " ++ rst ++ yel);
        try w.print("{d}\u{2192}{d}", .{ p.loop_start_bar + 1, p.loop_end_bar });
        try w.writeAll(rst);
    }

    // On a drum lane, show which pattern variant enter would stamp.
    if (app.cursor < app.session.racks.items.len) {
        switch (app.session.racks.items[app.cursor].instrument) {
            .drum_machine => |*dm| {
                try w.writeAll(dim ++ "  pat " ++ rst);
                try w.print("{c}", .{ws.dsp.DrumMachine.variantLetter(dm.variant)});
                try w.writeAll(dim ++ "/" ++ rst);
                try w.print("{d}", .{dm.variant_count});
            },
            else => {},
        }
    }

    if (app.session.arrangement.lane(app.cursor)) |lane| {
        if (lane.clipAt(cursor_tick)) |clip| {
            try w.writeAll(dim ++ "  clip " ++ rst);
            try w.print("{d}t\u{2192}{d}t", .{ clip.start_tick, clip.endTick() });
            switch (clip.content) {
                .drum => |d| try w.print(" {s}pat{s} {c}", .{
                    dim, rst, ws.dsp.DrumMachine.variantLetter(d.variant),
                }),
                .melodic => {},
            }
        }
    }

    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

pub fn drawFileBrowserStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, "FILES", app.modal.mode);
    // Status message BEFORE the key hints: the row clamps at the terminal
    // edge, so whatever prints last is what a narrow window silently drops -
    // that must be the static hints, never live feedback (bookmarked/
    // unbookmarked, search "no match", …).
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
    if (app.browser_recent_mode) {
        try w.writeAll(dim ++ "  " ++ rst ++ "enter: open  esc: cancel");
    } else if (app.browser_bookmark_mode) {
        try w.writeAll(dim ++ "  " ++ rst ++ "enter: jump  d: remove  esc: back");
    } else {
        try w.writeAll(dim ++ "  " ++ rst ++ "enter: open  /: search");
        if (app.browser_purpose.canAudition()) try w.writeAll("  a: audition");
        if (app.browser_purpose.canMultiSelect()) try w.writeAll("  v: select");
        try w.writeAll("  B: locations  esc: cancel");
    }
}

pub fn drawAutomationStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    const clip = automation_ed.currentClip(app) orelse {
        try w.writeAll(dim ++ "clip gone - esc" ++ rst);
        return;
    };

    const bpb = app.session.project.beats_per_bar;
    const steps_per_bar: u32 = @as(u32, bpb) * 4;
    const bar = app.automation_cursor_step / steps_per_bar;
    const step_in_bar = app.automation_cursor_step % steps_per_bar;
    const beat = @as(f64, @floatFromInt(app.automation_cursor_step)) * 0.25;

    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, "AUTOMATION", app.modal.mode);
    try w.writeAll(dim ++ "  " ++ rst);
    try w.print("{d}.{d}", .{ bar + 1, step_in_bar + 1 });

    const target = app.automation_focus;
    const points = automation_ed.curvePointsConst(clip, target);
    if (automation_mod.interpolate(points, beat)) |v| {
        const explicit = automation_mod.hasPointAt(points, beat);
        try w.writeAll(dim ++ "  " ++ rst);
        if (explicit) try w.writeAll(bold);
        switch (target) {
            .gain => try w.print("{d:.1}dB", .{v}),
            .pan => try w.print("{d:.2}", .{v}),
            // Cutoff keeps its own kHz breakdown for parity with the synth
            // editor's own readout; every other synth param gets a plain
            // generic format (no per-param unit table needed for ~29 params).
            .synth_param => |id| if (id == 21) {
                if (v >= 1_000.0) try w.print("{d:.2}kHz", .{v / 1_000.0}) else try w.print("{d:.0}Hz", .{v});
            } else if (@abs(v) >= 10.0) {
                try w.print("{d:.1}", .{v});
            } else {
                try w.print("{d:.2}", .{v});
            },
        }
        if (explicit) {
            try w.writeAll(rst);
            try w.writeAll(dim ++ " (point)" ++ rst);
        } else {
            try w.writeAll(dim ++ " (interpolated)" ++ rst);
        }
    } else {
        try w.writeAll(dim ++ "  no automation yet - j/k adds a point" ++ rst);
    }

    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
}

/// Status row keeps apply errors ahead of lower-priority key hints so narrow
/// terminals preserve the feedback when the shared row clamps.
pub fn drawPresetPickerStatus(app: anytype, w: *std.Io.Writer, right: *std.Io.Writer) !void {
    try writeModeBadge(w, app.modal.mode);
    try writeViewBadge(right, "PRESETS", app.modal.mode);
    if (app.status_len > 0) {
        try w.writeAll(dim ++ "  " ++ rst);
        try w.writeAll(app.status_buf[0..app.status_len]);
    }
    try w.writeAll(dim ++ "  " ++ rst ++ "j/k: move");
    switch (app.preset_picker_kind) {
        .synth => try w.writeAll("  a: audition C3"),
        .soundfont, .acoustic => try w.writeAll("  a: audition"),
        .drum => {},
    }
    try w.writeAll("  enter: apply  /: filter  d: delete  esc: close");
}
