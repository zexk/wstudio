//! Per-view footer status renderers, shared by both frontends. The TUI
//! writes these SGR-styled bytes straight to the terminal (tui/main.zig's
//! draw); the GUI strips the codes and re-renders the plain text with its
//! own presentation (gui/chrome.zig's tuiStatusText). Each view's body
//! renderer stays in tui/views/<name>.zig - only the status line moved
//! here, since it's the one piece of view output the GUI also consumes.

const std = @import("std");
const ws = @import("wstudio");
const DrumMachine = ws.dsp.DrumMachine;
const Slicer = ws.dsp.Slicer;
const ansi = @import("ansi.zig");
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

/// Full-word label for a filter type - shared by drawSynthStatus below.
fn filterTypeName(ft: anytype) []const u8 {
    return switch (ft) {
        .lp => "lp",
        .hp => "hp",
        .bp => "bp",
        .notch => "notch",
        .ladder => "ladder",
        .diode => "diode",
        .comb => "comb",
        .formant => "formant",
    };
}

const eq_mod = ws.dsp.eq;
const automation_mod = ws.dsp.automation;

/// Full-word label for an LFO shape - shared by drawSynthStatus below.
fn lfoShapeName(shape: anytype) []const u8 {
    return switch (shape) {
        .sine => "sine",
        .triangle => "tri",
        .saw => "saw",
        .square => "sqr",
        .sh => "s&h",
        .chaos => "chaos",
        .custom => "custom",
    };
}

/// Full-word label for a unison mode - shared by drawSynthStatus below.
fn uniModeName(mode: anytype) []const u8 {
    return switch (mode) {
        .spread => "spread",
        .step => "step",
        .harmonic => "harmonic",
        .ratio => "ratio",
    };
}

/// Full-word label for an arpeggiator mode - shared by drawSynthStatus below.
fn arpModeName(mode: anytype) []const u8 {
    return switch (mode) {
        .up => "up",
        .down => "down",
        .updown => "up/dn",
        .downup => "dn/up",
        .played => "played",
        .random => "random",
        .chord => "chord",
    };
}

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
                .poly_synth, .sampler => try w.print("enter: edit  p: piano  s: fx  m: {s}", .{if (track.muted) "unmute" else "mute"}),
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
    }
    if (dm.choke_group[p] != 0) {
        try w.writeAll(dim ++ "  choke " ++ rst);
        try w.print("{d}", .{dm.choke_group[p]});
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
    const sIdx = app.slicer_cursor[0];
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
                try w.print("b{d} {s} {s}", .{ bf.band + 1, spectrum_ed.paramName(&unit.payload, app.fx_param), spectrum_ed.formatValue(app, &vbuf, &unit.payload, app.fx_param) });
            },
            else => {
                var vbuf: [16]u8 = undefined;
                try w.print("{s} {s}", .{ spectrum_ed.paramName(&unit.payload, app.fx_param), spectrum_ed.formatValue(app, &vbuf, &unit.payload, app.fx_param) });
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
    switch (app.synth_cursor) {
        0 => try w.writeAll(switch (synth.waveform) {
            .sine => "sine",
            .saw => "saw",
            .triangle => "tri",
            .square => "sqr",
            .wavetable => "wt",
        }),
        1 => try w.print("{d:.2}", .{synth.pulse_width}),
        2 => try w.print("{d:.0} ct", .{synth.detune_cents}),
        3 => try w.print("{d}", .{synth.unison}),
        4 => try w.print("{d:.1} ct", .{synth.unison_detune}),
        5 => try w.print("{d:.2}", .{synth.unison_spread}),
        6 => try w.writeAll(if (synth.osc_b_on) "on" else "off"),
        7 => try w.writeAll(switch (synth.osc_b_waveform) {
            .sine => "sine",
            .saw => "saw",
            .triangle => "tri",
            .square => "sqr",
            .wavetable => "wt",
        }),
        8 => try w.print("{d:.2}", .{synth.osc_b_pulse_width}),
        9 => try w.print("{d:.0} st", .{synth.osc_b_semi}),
        10 => try w.print("{d:.0} ct", .{synth.osc_b_detune_cents}),
        11 => try w.print("{d:.2}", .{synth.osc_b_level}),
        12 => try w.print("{d}", .{synth.osc_b_unison}),
        13 => try w.print("{d:.1} ct", .{synth.osc_b_unison_detune}),
        14 => try w.writeAll(switch (synth.mod_mode) {
            .none => "off",
            .ring => "ring",
            .am_a_to_b => "AM A\u{2192}B",
            .am_b_to_a => "AM B\u{2192}A",
            .fm_a_to_b => "FM A\u{2192}B",
            .fm_b_to_a => "FM B\u{2192}A",
        }),
        15 => switch (synth.mod_mode) {
            .fm_a_to_b, .fm_b_to_a => try w.print("\u{03b2}={d:.2}", .{synth.mod_amount}),
            else => try w.print("{d:.2}", .{synth.mod_amount}),
        },
        16 => try w.print("{d:.3} s", .{synth.attack_s}),
        17 => try w.print("{d:.3} s", .{synth.decay_s}),
        18 => try w.print("{d:.3}", .{synth.sustain}),
        19 => try w.print("{d:.3} s", .{synth.release_s}),
        20 => try w.writeAll(filterTypeName(synth.filter_type)),
        21 => if (synth.filter_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz", .{synth.filter_cutoff}),
        22 => try w.print("{d:.3}", .{synth.filter_res}),
        24 => try w.print("{d:.3} s", .{synth.fenv_attack_s}),
        25 => try w.print("{d:.3} s", .{synth.fenv_decay_s}),
        26 => try w.print("{d:.3}", .{synth.fenv_sustain}),
        27 => try w.print("{d:.3} s", .{synth.fenv_release_s}),
        28 => try w.writeAll(lfoShapeName(synth.lfo_shape)),
        29 => try w.print("{d:.2} Hz", .{synth.lfo_rate_hz}),
        32 => try w.writeAll(switch (synth.voice_mode) {
            .poly => "poly",
            .mono => "mono",
            .legato => "legato",
        }),
        33 => if (synth.glide_s == 0.0) try w.writeAll("off") else try w.print("{d:.3} s", .{synth.glide_s}),
        34 => if (synth.sub_level == 0.0) try w.writeAll("off") else try w.print("{d:.2}", .{synth.sub_level}),
        35 => try w.writeAll(switch (synth.sub_shape) {
            .sine => "sine",
            .square => "sqr",
        }),
        36 => if (synth.noise_level == 0.0) try w.writeAll("off") else try w.print("{d:.2}", .{synth.noise_level}),
        37 => try w.print("{d:.2}", .{synth.noise_color}),
        38 => try w.print("{d:.3}", .{synth.gain}),
        39 => try w.writeAll(uniModeName(synth.unison_mode)),
        40 => try w.writeAll(uniModeName(synth.osc_b_unison_mode)),
        41 => try w.writeAll(switch (synth.warp_mode) {
            .none => "none",
            .bend => "bend",
            .mirror => "mirror",
            .sync => "sync",
        }),
        42 => try w.print("{d:.2}", .{synth.warp_amount}),
        43 => try w.writeAll(switch (synth.osc_b_warp_mode) {
            .none => "none",
            .bend => "bend",
            .mirror => "mirror",
            .sync => "sync",
        }),
        44 => try w.print("{d:.2}", .{synth.osc_b_warp_amount}),
        45 => try w.writeAll(if (synth.filter2_on) "on" else "off"),
        46 => try w.writeAll(filterTypeName(synth.filter2_type)),
        47 => if (synth.filter2_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter2_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz", .{synth.filter2_cutoff}),
        48 => try w.print("{d:.3}", .{synth.filter2_res}),
        49 => try w.writeAll(switch (synth.filter_routing) {
            .series => "series",
            .parallel => "parallel",
        }),
        50 => try w.writeAll(if (synth.osc_c_on) "on" else "off"),
        51 => try w.writeAll(switch (synth.osc_c_waveform) {
            .sine => "sine",
            .saw => "saw",
            .triangle => "tri",
            .square => "sqr",
            .wavetable => "wt",
        }),
        52 => try w.print("{d:.2}", .{synth.osc_c_pulse_width}),
        53 => try w.print("{d:.0} st", .{synth.osc_c_semi}),
        54 => try w.print("{d:.0} ct", .{synth.osc_c_detune_cents}),
        55 => try w.print("{d:.2}", .{synth.osc_c_level}),
        56 => try w.print("{d}", .{synth.osc_c_unison}),
        57 => try w.print("{d:.1} ct", .{synth.osc_c_unison_detune}),
        58 => try w.writeAll(uniModeName(synth.osc_c_unison_mode)),
        59...82 => {
            const row = synth.mod_matrix[(app.synth_cursor - 59) / 3];
            switch ((app.synth_cursor - 59) % 3) {
                // zig fmt: off
                0 => try w.writeAll(synth_layout.modSourceName(row.source)),
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
        108 => try w.writeAll(if (synth.fx_delay_on) "on" else "off"),
        109 => try w.print("{d:.3} s",     .{synth.fx_delay_time_s}),
        110 => try w.print("{d:.2}",       .{synth.fx_delay_feedback}),
        111 => try w.print("{d:.2}",       .{synth.fx_delay_mix}),
        112 => try w.writeAll(if (synth.fx_reverb_on) "on" else "off"),
        113 => try w.print("{d:.2}",       .{synth.fx_reverb_room}),
        114 => try w.print("{d:.2}",       .{synth.fx_reverb_damp}),
        115 => try w.print("{d:.2}",       .{synth.fx_reverb_mix}),
        116 => try w.writeAll(if (synth.arp_on) "on" else "off"),
        117 => try w.writeAll(arpModeName(synth.arp_mode)),
        118 => try w.print("{d}",          .{synth.arp_octaves}),
        119 => try w.print("{d:.1} Hz",    .{synth.arp_rate_hz}),
        120 => try w.print("{d:.2}",       .{synth.arp_gate}),
        121 => try w.writeAll(if (synth.arp_hold) "on" else "off"),
        122 => try w.print("{d:.3} s",     .{synth.env3_attack_s}),
        123 => try w.print("{d:.3} s",     .{synth.env3_decay_s}),
        124 => try w.print("{d:.3}",       .{synth.env3_sustain}),
        125 => try w.print("{d:.3} s",     .{synth.env3_release_s}),
        132 => try w.writeAll(if (synth.fx_gate_on) "on" else "off"),
        133 => try w.print("{d:.0} dB",    .{synth.fx_gate_threshold_db}),
        134 => try w.print("{d:.1} ms",    .{synth.fx_gate_attack_ms}),
        135 => try w.print("{d:.0} ms",    .{synth.fx_gate_release_ms}),
        137 => try w.writeAll(if (synth.fx_comp_on) "on" else "off"),
        138 => try w.print("{d:.0} dB",    .{synth.fx_comp_threshold_db}),
        139 => try w.print("{d:.1}:1",     .{synth.fx_comp_ratio}),
        140 => try w.print("{d:.1} ms",    .{synth.fx_comp_attack_ms}),
        141 => try w.print("{d:.0} ms",    .{synth.fx_comp_release_ms}),
        142 => try w.print("{d:.1} dB",    .{synth.fx_comp_makeup_db}),
        144 => try w.writeAll(if (synth.fx_mb_on) "on" else "off"),
        145 => try w.print("{d:.0} Hz",    .{synth.fx_mb_xover_lo}),
        146 => try w.print("{d:.0} Hz",    .{synth.fx_mb_xover_hi}),
        147 => try w.print("{d:.1} ms",    .{synth.fx_mb_attack_ms}),
        148 => try w.print("{d:.0} ms",    .{synth.fx_mb_release_ms}),
        149 => try w.writeAll(if (synth.fx_mb_style == .ott) "OTT" else "classic"),
        150 => try w.print("{d:.2}",       .{synth.fx_mb_mix}),
        151 => try w.print("{d:.0} dB",    .{synth.fx_mb_low_threshold_db}),
        152 => try w.print("{d:.1}:1",     .{synth.fx_mb_low_ratio}),
        153 => try w.print("{d:.1} dB",    .{synth.fx_mb_low_makeup_db}),
        154 => try w.print("{d:.0} dB",    .{synth.fx_mb_mid_threshold_db}),
        155 => try w.print("{d:.1}:1",     .{synth.fx_mb_mid_ratio}),
        156 => try w.print("{d:.1} dB",    .{synth.fx_mb_mid_makeup_db}),
        157 => try w.print("{d:.0} dB",    .{synth.fx_mb_high_threshold_db}),
        158 => try w.print("{d:.1}:1",     .{synth.fx_mb_high_ratio}),
        159 => try w.print("{d:.1} dB",    .{synth.fx_mb_high_makeup_db}),
        161 => try w.writeAll(if (synth.fx_ott_on) "on" else "off"),
        162 => try w.print("{d:.2}",       .{synth.fx_ott_depth}),
        163 => try w.print("{d:.2}x",      .{synth.fx_ott_time}),
        164 => try w.print("{d:.1} dB",    .{synth.fx_ott_gain_in_db}),
        165 => try w.print("{d:.1} dB",    .{synth.fx_ott_gain_out_db}),
        167 => try w.writeAll(if (synth.fx_eq_on) "on" else "off"),
        168 => try w.print("{d:.0} Hz",    .{synth.fx_eq_low_freq}),
        169 => try w.print("{d:.1} dB",    .{synth.fx_eq_low_gain_db}),
        170 => try w.print("{d:.0} Hz",    .{synth.fx_eq_mid_freq}),
        171 => try w.print("{d:.1} dB",    .{synth.fx_eq_mid_gain_db}),
        172 => try w.print("{d:.2}",       .{synth.fx_eq_mid_q}),
        173 => try w.print("{d:.0} Hz",    .{synth.fx_eq_high_freq}),
        174 => try w.print("{d:.1} dB",    .{synth.fx_eq_high_gain_db}),
        176 => try w.writeAll(if (synth.fx_chorus_on) "on" else "off"),
        177 => try w.print("{d:.2} Hz",    .{synth.fx_chorus_rate_hz}),
        178 => try w.print("{d:.1} ms",    .{synth.fx_chorus_depth_ms}),
        179 => try w.print("{d:.2}",       .{synth.fx_chorus_mix}),
        181 => try w.writeAll(if (synth.fx_freq_shift_on) "on" else "off"),
        182 => try w.print("{d:.0} Hz",    .{synth.fx_freq_shift_hz}),
        183 => try w.print("{d:.2}",       .{synth.fx_freq_shift_mix}),
        185 => try w.print("{d:.2}",       .{synth.wt_pos}),
        186 => try w.print("{d:.2}",       .{synth.osc_b_wt_pos}),
        187 => try w.print("{d:.2}",       .{synth.osc_c_wt_pos}),
        188 => try w.writeAll(if (synth.fx_tape_on) "on" else "off"),
        189 => try w.print("{d:.2} Hz",    .{synth.fx_tape_wow_rate_hz}),
        190 => try w.print("{d:.2}",       .{synth.fx_tape_wow_depth}),
        191 => try w.print("{d:.2} Hz",    .{synth.fx_tape_flutter_rate_hz}),
        192 => try w.print("{d:.2}",       .{synth.fx_tape_flutter_depth}),
        193 => try w.print("{d:.2}",       .{synth.fx_tape_mix}),
        // zig fmt: on
        else => {},
    }
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

/// Names for the sampler param rows, indexed by `app.sampler_param`. Indices
/// 10-11 (root, voice) apply only to the standalone Sampler, not drum pads.
const sampler_param_labels = [_][]const u8{
    "start", "end", "pitch", "attack", "decay", "sustain", "release", "gain", "pan", "reverse", "root", "voice",
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

    const cursor_tick = app.arr_cursor_bar * app.arr_grid.ticks();
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
        try w.writeAll(dim ++ "  " ++ rst ++ yel ++ icons.loop ++ " loop " ++ rst ++ yel);
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
    if (app.browser_bookmark_mode) {
        try w.writeAll(dim ++ "  " ++ rst ++ "enter: jump  d: remove  esc: back");
    } else {
        try w.writeAll(dim ++ "  " ++ rst ++ "enter: open  /: search  B: locations  esc: cancel");
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
    if (app.preset_picker_kind == .synth) try w.writeAll("  a: audition C3");
    try w.writeAll("  enter: apply  /: filter  d: delete  esc: close");
}
