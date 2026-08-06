//! Synth-editor input: param row navigation ({/} jump sections, Tab cycles
//! subviews), h/l nudges routed over the engine command queue (all but
//! `wt.table`, which allocates - see `stepWtTable`), and the
//! cursor-row/scroll math shared with the renderer in views/synth.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const App = @import("../app.zig").App;
const spectrum = @import("fx_editor.zig");
const piano = @import("piano.zig");
const preset_picker = @import("preset_picker.zig");
const history = @import("../history.zig");
const fuzzy = @import("../fuzzy.zig");
const synth_layout = @import("../synth_layout.zig");

/// The synth editor's two panes, cycled by Tab: oscillator/envelope/
/// filter/voice params ("main") and modulation sources - the matrix, LFOs,
/// ENV 3, macros - ("mod"). `App.synth_cursor` stays one flat param-id
/// space across both (it IS the PolySynth param id - engine commands and
/// undo key off it directly) - the subview only changes which ids are
/// reachable and how they're laid out on screen. Both are driven by
/// synth_layout.zig's comptime section tables. The rack's FX chain (the
/// spectrum view) owns effects; the synth has none of its own.
pub const Subview = enum { main, mod };
pub const SubviewSpec = struct { subview: Subview, short_label: []const u8, label: [:0]const u8 };
pub const subviews = [_]SubviewSpec{
    .{ .subview = .main, .short_label = "MAIN", .label = "MAIN" },
    .{ .subview = .mod, .short_label = "MOD", .label = "MODULATION" },
};

/// `id`'s display label for an FX param. These ids are no editor's rows
/// any more (the synth has no FX section of its own - see `Subview`); they
/// survive as mod-matrix destinations, which address the *rack* chain's
/// units through `fx_instance_id`, so the matrix still needs a name to
/// print for one. Reorder-handle ids are never a destination so they fall
/// to "-" along with any other gap.
pub fn fxParamLabel(id: u16) []const u8 {
    return switch (id) {
        // zig fmt: off
        83 => "dist.on", 84 => "dist.drive", 85 => "dist.mix",
        86 => "crush.on", 87 => "crush.bits", 88 => "crush.rate", 89 => "crush.mix",
        90 => "flng.on", 91 => "flng.rate", 92 => "flng.depth", 93 => "flng.fdbk", 94 => "flng.mix",
        103 => "phsr.on", 104 => "phsr.rate", 105 => "phsr.depth", 106 => "phsr.fdbk", 107 => "phsr.mix",
        108 => "dly.on", 109 => "dly.time", 110 => "dly.fdbk", 111 => "dly.mix",
        112 => "vrb.on", 113 => "vrb.room", 114 => "vrb.damp", 115 => "vrb.mix",
        132 => "gate.on", 133 => "gate.thresh", 134 => "gate.attack", 135 => "gate.release",
        137 => "comp.on", 138 => "comp.thresh", 139 => "comp.ratio", 140 => "comp.attack", 141 => "comp.release", 142 => "comp.makeup",
        144 => "mb.on", 145 => "mb.xover.lo", 146 => "mb.xover.hi", 147 => "mb.attack", 148 => "mb.release", 149 => "mb.style", 150 => "mb.mix",
        151 => "mb.lo.thresh", 152 => "mb.lo.ratio", 153 => "mb.lo.makeup",
        154 => "mb.mid.thresh", 155 => "mb.mid.ratio", 156 => "mb.mid.makeup",
        157 => "mb.hi.thresh", 158 => "mb.hi.ratio", 159 => "mb.hi.makeup",
        161 => "ott.on", 162 => "ott.depth", 163 => "ott.time", 164 => "ott.gain.in", 165 => "ott.gain.out",
        167 => "eq.on", 168 => "eq.lo.freq", 169 => "eq.lo.gain", 170 => "eq.mid.freq", 171 => "eq.mid.gain",
        172 => "eq.mid.q", 173 => "eq.hi.freq", 174 => "eq.hi.gain",
        176 => "chor.on", 177 => "chor.rate", 178 => "chor.depth", 179 => "chor.mix",
        181 => "frqs.on", 182 => "frqs.shift", 183 => "frqs.mix",
        188 => "tape.on", 189 => "tape.wow.rate", 190 => "tape.wow.depth",
        191 => "tape.flt.rate", 192 => "tape.flt.depth", 193 => "tape.mix",
        else => "-",
        // zig fmt: on
    };
}

/// `p`'s field-suffixed label for a matrix slot (`fields == 3`) id, e.g.
/// "1 source"/"1 dest"/"1 depth" - the format `secMatrix` (views/synth.zig)
/// itself renders.
fn matrixFieldLabel(p: synth_layout.ParamEntry, id: u16, buf: []u8) []const u8 {
    const field: []const u8 = switch (id - p.id) {
        0 => "source",
        1 => "dest",
        else => "depth",
    };
    return std.fmt.bufPrint(buf, "{s} {s}", .{ p.label, field }) catch p.label;
}

/// `id`'s display label - the single source both the status bar
/// (views/synth.zig's `drawSynthStatus`) and `/` search (`searchCandidates`
/// below, via `App.searchSynthParams`) resolve through. Searches MAIN then
/// MOD's synth_layout tables (the single source of truth for those ids'
/// groupings) before falling back to `fxParamLabel` for the range
/// synth_layout intentionally doesn't cover. `buf` only gets written for a
/// matrix field id (`fields > 1`); every other id returns its static label
/// directly.
pub fn paramLabel(id: u16, buf: []u8) []const u8 {
    for (synth_layout.main_sections) |sec| {
        for (sec.params) |p| {
            if (id < p.id or id >= p.id + p.fields) continue;
            if (p.fields == 1) return p.label;
            return matrixFieldLabel(p, id, buf);
        }
    }
    for (synth_layout.mod_sections) |sec| {
        for (sec.params) |p| {
            if (id < p.id or id >= p.id + p.fields) continue;
            if (p.fields == 1) return p.label;
            return matrixFieldLabel(p, id, buf);
        }
    }
    return fxParamLabel(id);
}

/// One `/`-searchable param: which subview it lives in plus its engine id
/// (its label is resolved on demand via `paramLabel` - not stored here, so
/// this stays a plain value with no buffer to own).
pub const SearchCandidate = struct { subview: Subview, id: u16 };

/// Every param in both subviews, in a stable order (MAIN's declaration
/// order, then MOD's) - the flat list `App.searchSynthParams` walks. A
/// matrix slot (`fields == 3`) contributes one candidate per field,
/// matching `paramLabel`'s per-field labels.
// ---------------------------------------------------------------------------
// Param value text - the id -> "what this value reads as" mapping (names for
// enum params, units for the rest). Lived in ui/status.zig as the TUI status
// line's private switch until the GUI needed the same strings: without it
// every GUI row rendered its raw float, so a filter type read "3.00" and a
// matrix destination read "21.00". One table, both frontends.
// ---------------------------------------------------------------------------

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

fn lfoRetrigName(mode: anytype) []const u8 {
    return switch (mode) {
        .free => "free",
        .key => "key",
        .one_shot => "1-shot",
    };
}

/// A rate row's display: the plain Hz knob, or the division that's
/// overriding it. Printing the division on the rate row too is what keeps a
/// synced slot from showing a stale, inert Hz value.
fn writeRate(w: *std.Io.Writer, sync: ws.dsp.synth.LfoSync, hz: f32, comptime fmt: []const u8) !void {
    if (sync == .off) return w.print(fmt, .{hz});
    try w.print("{s} sync", .{sync.label()});
}

fn uniModeName(mode: anytype) []const u8 {
    return switch (mode) {
        .spread => "spread",
        .step => "step",
        .harmonic => "harmonic",
        .ratio => "ratio",
    };
}

/// A `wt.table` row's display. "imported" is not a selectable option - it
/// only reports that `:load-wavetable` put a file in this slot, which no
/// `h`/`l` step can walk back to.
pub fn wtTableName(kind: ?ws.dsp.synth.BundledWavetable) []const u8 {
    return if (kind) |k| @tagName(k) else "imported";
}

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

/// Writes `id`'s current value the way the editor displays it. Silent for
/// ids with no display of their own (FX reorder handles, dead ids).
pub fn writeParamValue(synth: *const ws.dsp.PolySynth, id: u16, w: *std.Io.Writer) !void {
    if (ws.dsp.PolySynth.matrixParamAddr(id)) |addr| {
        const row = synth.mod_matrix[addr.row];
        switch (addr.field) {
            0 => try w.writeAll(synth_layout.modSourceName(row.source)),
            1 => try w.writeAll(ws.dsp.PolySynth.modDestLabel(row.dest)),
            2 => try w.print("{s}{d:.2}", .{ @as([]const u8, if (row.depth >= 0.0) "+" else ""), row.depth }),
            else => unreachable,
        }
        return;
    }
    switch (id) {
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
        246 => try w.print("{d:.2}", .{synth.env_curve}),
        20 => try w.writeAll(filterTypeName(synth.filter_type)),
        21 => if (synth.filter_cutoff >= 1_000.0)
            try w.print("{d:.2} kHz", .{synth.filter_cutoff / 1_000.0})
        else
            try w.print("{d:.0} Hz", .{synth.filter_cutoff}),
        22 => try w.print("{d:.3}", .{synth.filter_res}),
        249 => try w.print("{d:.1}x", .{synth.filter_drive}),
        24 => try w.print("{d:.3} s", .{synth.fenv_attack_s}),
        25 => try w.print("{d:.3} s", .{synth.fenv_decay_s}),
        26 => try w.print("{d:.3}", .{synth.fenv_sustain}),
        27 => try w.print("{d:.3} s", .{synth.fenv_release_s}),
        247 => try w.print("{d:.2}", .{synth.fenv_curve}),
        28 => try w.writeAll(lfoShapeName(synth.lfo_shape)),
        29 => try writeRate(w, synth.lfo_sync, synth.lfo_rate_hz, "{d:.2} Hz"),
        256 => try w.writeAll(synth.lfo_sync.label()),
        259 => try w.writeAll(lfoRetrigName(synth.lfo_retrig)),
        262 => try w.print("{d:.2}", .{synth.lfo_phase_offset}),
        265 => try w.print("{d:.0} ms", .{synth.lfo_slew_ms}),
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
        250 => try w.print("{d:.1}x", .{synth.filter2_drive}),
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
        ws.dsp.PolySynth.mod_unipolar_id_base...ws.dsp.PolySynth.mod_unipolar_id_base + ws.dsp.PolySynth.max_mod_rows - 1 => {
            const row = synth.mod_matrix[id - ws.dsp.PolySynth.mod_unipolar_id_base];
            try w.writeAll(if (row.unipolar) "unipolar" else "bipolar");
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
        96 => try writeRate(w, synth.lfo2_sync, synth.lfo2_rate_hz, "{d:.2} Hz"),
        257 => try w.writeAll(synth.lfo2_sync.label()),
        260 => try w.writeAll(lfoRetrigName(synth.lfo2_retrig)),
        263 => try w.print("{d:.2}",      .{synth.lfo2_phase_offset}),
        266 => try w.print("{d:.0} ms",   .{synth.lfo2_slew_ms}),
        97 => try w.writeAll(lfoShapeName(synth.lfo3_shape)),
        98 => try writeRate(w, synth.lfo3_sync, synth.lfo3_rate_hz, "{d:.2} Hz"),
        258 => try w.writeAll(synth.lfo3_sync.label()),
        261 => try w.writeAll(lfoRetrigName(synth.lfo3_retrig)),
        264 => try w.print("{d:.2}",      .{synth.lfo3_phase_offset}),
        267 => try w.print("{d:.0} ms",   .{synth.lfo3_slew_ms}),
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
        119 => try writeRate(w, synth.arp_sync, synth.arp_rate_hz, "{d:.1} Hz"),
        268 => try w.writeAll(synth.arp_sync.label()),
        120 => try w.print("{d:.2}",       .{synth.arp_gate}),
        121 => try w.writeAll(if (synth.arp_hold) "on" else "off"),
        122 => try w.print("{d:.3} s",     .{synth.env3_attack_s}),
        123 => try w.print("{d:.3} s",     .{synth.env3_decay_s}),
        124 => try w.print("{d:.3}",       .{synth.env3_sustain}),
        125 => try w.print("{d:.3} s",     .{synth.env3_release_s}),
        248 => try w.print("{d:.2}",       .{synth.env3_curve}),
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
        251, 252, 253 => try w.writeAll(wtTableName(synth.wtBundled(ws.dsp.PolySynth.wtTableSlot(id).?))),
        188 => try w.writeAll(if (synth.fx_tape_on) "on" else "off"),
        189 => try w.print("{d:.2} Hz",    .{synth.fx_tape_wow_rate_hz}),
        190 => try w.print("{d:.2}",       .{synth.fx_tape_wow_depth}),
        191 => try w.print("{d:.2} Hz",    .{synth.fx_tape_flutter_rate_hz}),
        192 => try w.print("{d:.2}",       .{synth.fx_tape_flutter_depth}),
        193 => try w.print("{d:.2}",       .{synth.fx_tape_mix}),
        // zig fmt: on
        else => {},
    }
}

/// `writeParamValue` into a caller-owned buffer, for the GUI's per-widget
/// value text. 40 bytes covers every arm above; a shorter one truncates
/// rather than failing the frame.
pub fn paramValueText(synth: *const ws.dsp.PolySynth, id: u16, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeParamValue(synth, id, &w) catch {};
    return w.buffered();
}

test "param value text covers envelope curves and filter drives" {
    var synth = try ws.dsp.PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var buf: [40]u8 = undefined;

    try std.testing.expectEqualStrings("0.00", paramValueText(&synth, 246, &buf));
    try std.testing.expectEqualStrings("0.00", paramValueText(&synth, 247, &buf));
    try std.testing.expectEqualStrings("0.00", paramValueText(&synth, 248, &buf));
    try std.testing.expectEqualStrings("1.0x", paramValueText(&synth, 249, &buf));
    try std.testing.expectEqualStrings("1.0x", paramValueText(&synth, 250, &buf));
}

pub fn searchCandidates(buf: []SearchCandidate) []const SearchCandidate {
    var n: usize = 0;
    for (synth_layout.main_sections) |sec| {
        for (sec.params) |p| {
            var f: u8 = 0;
            while (f < p.fields) : (f += 1) {
                buf[n] = .{ .subview = .main, .id = p.id + f };
                n += 1;
            }
        }
    }
    for (synth_layout.mod_sections) |sec| {
        for (sec.params) |p| {
            var f: u8 = 0;
            while (f < p.fields) : (f += 1) {
                buf[n] = .{ .subview = .mod, .id = p.id + f };
                n += 1;
            }
        }
    }
    return buf[0..n];
}

/// Exact bound on `searchCandidates`' output: every MAIN and MOD field.
/// Derived from the very tables `searchCandidates` walks - a hand-counted
/// 160 held until the mod matrix grew from 8 rows to 32, at which point `/`
/// in the synth editor wrote past the caller's buffer and panicked.
pub const max_search_candidates: usize = blk: {
    var n: usize = 0;
    for (synth_layout.main_sections) |sec| {
        for (sec.params) |p| n += p.fields;
    }
    for (synth_layout.mod_sections) |sec| {
        for (sec.params) |p| n += p.fields;
    }
    break :blk n;
};
/// `.main`'s `mainOrder` (comptime, width-aware) for the terminal width as
/// of the last draw - see `App.last_cols`'s doc comment for why `handleKey`
/// reads a cached width instead of taking one as a parameter.
fn mainOrderNow(app: *App) []const synth_layout.PositionedEntry {
    return synth_layout.mainOrder(synth_layout.numCols(app.last_cols));
}

/// `.mod`'s counterpart to `mainOrderNow`.
fn modOrderNow(app: *App) []const synth_layout.PositionedEntry {
    return synth_layout.modOrder(synth_layout.numCols(app.last_cols));
}

fn sectionOrder(order: []const synth_layout.PositionedEntry, cursor: u16) []const synth_layout.PositionedEntry {
    const idx = synth_layout.indexContaining(order, cursor) orelse return order;
    const section = order[idx].section;
    var first = idx;
    while (first > 0 and order[first - 1].section == section) first -= 1;
    var last = idx + 1;
    while (last < order.len and order[last].section == section) last += 1;
    return order[first..last];
}

fn activeMainOrder(app: *App) []const synth_layout.PositionedEntry {
    const order = mainOrderNow(app);
    return if (app.synth_section_focus) sectionOrder(order, app.synth_cursor) else order;
}

fn activeModOrder(app: *App) []const synth_layout.PositionedEntry {
    const order = modOrderNow(app);
    return if (app.synth_section_focus) sectionOrder(order, app.synth_cursor) else order;
}

/// `g`/`G`/Tab's target id for the current subview - both walk their
/// column-grid visual order (see synth_layout.zig).
fn cursorFirst(app: *App) u16 {
    return switch (app.synth_subview) {
        .main => synth_layout.firstEntry(activeMainOrder(app)),
        .mod => synth_layout.firstEntry(activeModOrder(app)),
    };
}
fn cursorLast(app: *App) u16 {
    return switch (app.synth_subview) {
        .main => synth_layout.lastEntry(activeMainOrder(app)),
        .mod => synth_layout.lastEntry(activeModOrder(app)),
    };
}

/// One discrete param edit on some id other than the cursor's, pushed as
/// its own undo entry (see `sendFxToggle`'s comment for why it flushes
/// immediately instead of coalescing like a held `h`/`l` run).
fn sendParamSteps(app: *App, id: u16, steps: i32) void {
    app.dirty = true;
    history.noteParamNudge(app, app.synth_track, id, steps);
    history.flushParamNudge(app);
    _ = app.session.engine.send(.{ .set_track_param = .{
        .track = app.synth_track,
        .id = id,
        .steps = steps,
    } });
}

/// `m` on any param in any subview: points the first free mod-matrix row
/// at that param and jumps to the row's source field, so a route is made
/// from where its destination lives instead of walking `mod_dest_ids` by
/// hand from the MOD pane - with 32 rows and every automatable param a
/// legal dest, stepping `dest` into place was the slowest thing in the
/// editor. The row is left inert (source `off`, depth 0) rather than
/// guessing a source and a depth: one param write, so one `u` undoes the
/// gesture, and an accidental press is a no-op the next `m` reuses.
fn assignModFromCursor(app: *App) void {
    if (app.synth_track >= app.session.racks.items.len) return;
    const rack = app.session.racks.items[app.synth_track];
    const synth = switch (rack.instrument) {
        .poly_synth => |*s| s,
        else => return,
    };
    const Synth = ws.dsp.PolySynth;
    const dest = app.synth_cursor;
    var label_buf: [48]u8 = undefined;
    const label = paramLabel(dest, &label_buf);

    // A row's own source/dest/depth fields are automatable but barred as
    // matrix destinations (see mod_dest_excluded_ids), so `m` on one would
    // otherwise report the generic rejection below and read as a bug.
    if (Synth.matrixParamAddr(dest) != null) {
        app.setStatus("a matrix row can't be a modulation destination", .{});
        return;
    }
    const target = Synth.modDestIndex(dest) orelse {
        app.setStatus("{s} can't be modulated", .{label});
        return;
    };
    const row = for (synth.mod_matrix, 0..) |r, i| {
        if (r.source == .none) break i;
    } else {
        app.setStatus("every one of the {d} matrix rows is in use", .{Synth.max_mod_rows});
        return;
    };

    history.flushParamNudge(app);
    const cur = Synth.modDestIndex(synth.mod_matrix[row].dest) orelse 0;
    const steps = @as(i32, @intCast(target)) - @as(i32, @intCast(cur));
    if (steps != 0) sendParamSteps(app, Synth.matrixParamId(row, 1), steps);

    app.synth_subview = .mod;
    app.synth_cursor = Synth.matrixParamId(row, 0);
    updateScroll(app);
    app.setStatus("matrix row {d} -> {s}: h/l picks a source, w then h/l sets depth", .{ row + 1, label });
}

// zig fmt: off
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    // Multi-key prefixes (docs/editing-grammar.md): `g` armed below drains
    // on the next key (gg = first param, gG = last). An unknown pair falls
    // through, so a prefix never eats a key it doesn't own.
    if (app.takePrefix(key)) |p| switch (p) {
        'g' => switch (key.char) {
            'g' => { history.flushParamNudge(app); app.synth_cursor = cursorFirst(app); updateScroll(app); return true; },
            'G' => { history.flushParamNudge(app); app.synth_cursor = cursorLast(app); updateScroll(app); return true; },
            else => {},
        },
        else => {},
    };
    switch (key) {
        .escape => { history.flushParamNudge(app); app.view = .tracks; return true; },
        .ctrl_r => { history.doRedo(app); return true; },
        .tab => {
            history.flushParamNudge(app);
            app.synth_section_focus = false;
            app.synth_subview = switch (app.synth_subview) {
                .main => .mod, .mod => .main,
            };
            app.synth_cursor = cursorFirst(app);
            updateScroll(app);
            return true;
        },
        .char => |c| switch (c) {
            // Block insert mode - piano keys conflict with parameter navigation.
            'i' => return true,
            's' => { history.flushParamNudge(app); spectrum.switchToTrack(app, app.synth_track); return true; },
            // p opens the piano roll for this track (matches p in the tracks view);
            // e in the piano roll comes back here, so synth <-> roll is bidirectional.
            'p' => {
                history.flushParamNudge(app);
                piano.switchTo(app, app.synth_track);
                if (app.view == .piano_roll) app.autoSongMode(false);
                return true;
            },
            // f browses factory + saved presets - same apply path as :synth-preset.
            'f' => { history.flushParamNudge(app); preset_picker.open(app, .synth, app.synth_track); return true; },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            'z' => {
                app.synth_section_focus = !app.synth_section_focus;
                app.synth_scroll = 0;
                return true;
            },
            // j/k rows and h/l nudges take a vim count prefix (3j, 5l, …).
            'j' => { moveCursor(app, app.takeCount()); return true; },
            'k' => { moveCursor(app, -app.takeCount()); return true; },
            'h' => { adjustParam(app, -app.takeCount()); return true; },
            'l' => { adjustParam(app, app.takeCount()); return true; },
            'H' => { adjustParam(app, -10 * app.takeCount()); return true; },
            'L' => { adjustParam(app, 10 * app.takeCount()); return true; },
            // g/G are a two-key pair (gg = first param, gG = last): 'g'
            // arms the prefix, the follow-up key drains it above.
            'g' => { _ = app.armPrefix('g'); return true; },
            // `/` isn't bound here - it falls through to modal.handle's
            // generic normal-mode search entry (App.searchSynthParams
            // handles the submit). n/N repeat, same as every other view.
            'n' => { app.searchSynthParams(1); return true; },
            'N' => { app.searchSynthParams(-1); return true; },
            // Shift focus within a multi-field entry (a mod-matrix slot's
            // source/dest/depth) - a no-op everywhere else, since every
            // other entry has exactly one field. Safe to bind unconditionally.
            'w' => { shiftField(app, 1); return true; },
            'b' => { shiftField(app, -1); return true; },
            // Claims 'm' from modal.handle's global mute for this view - the
            // synth editor has no track-mute affordance to lose, and the
            // tracks view still owns muting. See assignModFromCursor.
            'm' => { assignModFromCursor(app); return true; },
            // Jumps to the next/prev section's first id, walking the
            // subview's synth_layout order (synth_layout.jumpSection).
            '}', '{' => {
                history.flushParamNudge(app);
                switch (app.synth_subview) {
                    .main => app.synth_cursor = synth_layout.jumpSection(mainOrderNow(app), app.synth_cursor, c == '}'),
                    .mod => app.synth_cursor = synth_layout.jumpSection(modOrderNow(app), app.synth_cursor, c == '}'),
                }
                updateScroll(app);
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

/// Move the param cursor by `delta` rows within the current subview. Both
/// walk their column-grid visual order (see synth_layout.zig - column-major,
/// not numeric id order, once the terminal is wide enough to pack more than
/// one column; a mod-matrix slot's 3 fields count as one row here,
/// preserving whichever field was focused - see synth_layout.moveEntry).
fn moveCursor(app: *App, delta: i32) void {
    const order = switch (app.synth_subview) {
        .main => activeMainOrder(app),
        .mod => activeModOrder(app),
    };
    app.synth_cursor = synth_layout.moveEntry(order, app.synth_cursor, delta);
    updateScroll(app);
}

/// `w`/`b`: shift focus within the current entry's fields (a mod-matrix
/// slot's source/dest/depth) - see synth_layout.moveField. No-op for any
/// `fields == 1` entry.
fn shiftField(app: *App, delta: i32) void {
    const order = switch (app.synth_subview) {
        .main => activeMainOrder(app),
        .mod => activeModOrder(app),
    };
    app.synth_cursor = synth_layout.moveField(order, app.synth_cursor, delta);
}
// zig fmt: on

/// Wide terminals split the "main" subview into OSC A / OSC B side by side
/// on top (7 and 9 rows respectively - OSC B is taller, so the top block is
/// 9 rows) followed by every other main-pane section stacked full-width
/// beneath, instead of one long scroll. 108 cols keeps both oscillator
/// columns comfortably above their own widest row (OSC B's 9-row block).
/// The matrix subview always renders as a single full-width list regardless
/// of width - it has no OSC-A/B-style pairing to split.
pub fn updateScroll(app: *App) void {
    if (app.synth_section_focus) {
        app.synth_scroll = 0;
        return;
    }
    // Will be re-clamped against the real max_rows at draw time (views/
    // synth.zig's drawSynthEditor); this is just a same-ballpark estimate
    // so the scroll is already reasonable before that first real draw.
    // Was 20 (tuned against the old rows-|5 body budget, pre-hr()-removal);
    // bumped by the same +2 the real budget gained.
    const max_rows: usize = 22;
    // 0-based column-local row numbering - see synth_layout.zig's
    // PositionedEntry / views/synth.zig's drawSynthGrid, which this must
    // stay in lockstep with.
    const order = if (app.synth_subview == .main) mainOrderNow(app) else modOrderNow(app);
    const idx = synth_layout.indexContaining(order, app.synth_cursor) orelse 0;
    const row = if (order.len > 0) order[idx].row else 0;
    if (row < app.synth_scroll) app.synth_scroll = row;
    if (row >= app.synth_scroll + max_rows) app.synth_scroll = row - max_rows + 1;
}

// zig fmt: off
/// Nudge the selected synth-editor parameter. The change is routed over the
/// engine command queue and applied on the audio thread (PolySynth.adjustParam)
/// so it never races the block reader - the editor view reflects it on the
/// next frame. See engine.Command.set_track_param. Also notes the nudge for
/// undo (history.noteParamNudge), coalescing a run of h/l presses on the
/// same param into one undo step.
fn adjustParam(app: *App, steps: i32) void {
    if (app.synth_track >= app.session.racks.items.len) return;
    const synth = switch (app.session.racks.items[app.synth_track].instrument) {
        .poly_synth => |*s| s,
        else => return,
    };
    if (ws.dsp.PolySynth.wtTableSlot(app.synth_cursor)) |slot| return stepWtTable(app, synth, slot, steps);
    app.dirty = true;
    history.noteParamNudge(app, app.synth_track, app.synth_cursor, steps);
    _ = app.session.engine.send(.{ .set_track_param = .{
        .track = app.synth_track,
        .id    = app.synth_cursor,
        .steps = steps,
    } });
}
// zig fmt: on

/// `wt.table`'s `h`/`l`, applied here on the control thread rather than over
/// the engine queue every other param takes: picking a table reloads it and
/// rebuilds its band-limited mip levels, which allocates and runs an FFT,
/// and the audio thread must do neither. Same direct-mutation path
/// `:load-wavetable` already uses, and like it the swap isn't undoable - the
/// slot holds audio, not a value `set_track_param_abs` could restore.
fn stepWtTable(app: *App, synth: *ws.dsp.PolySynth, slot: ws.dsp.PolySynth.OscSlot, steps: i32) void {
    if (steps == 0) return;
    const Bundled = ws.dsp.synth.BundledWavetable;
    const n: i32 = @intCast(std.meta.fields(Bundled).len);
    // An imported table has no tag to step from, so `l` off it enters the
    // bundled ring at its first entry rather than refusing to move.
    const cur: i32 = if (synth.wtBundled(slot)) |kind| @intFromEnum(kind) else 0;
    const next: Bundled = @enumFromInt(@mod(cur + steps, n));
    synth.selectBundledWavetables(
        if (slot == .a) next else null,
        if (slot == .b) next else null,
        if (slot == .c) next else null,
    ) catch |e| {
        app.setStatus("wt.table: {s}", .{@errorName(e)});
        return;
    };
    app.dirty = true;
    app.setStatus("osc {s} wavetable: {s}", .{ @tagName(slot), @tagName(next) });
}

/// The param index whose row (in the *scrolled* on-screen layout) is `row`,
/// or null for the title row / a row that doesn't land on any param (a
/// section-header line). Rows resolve against `synth_layout`'s comptime
/// column/row positions (0-based content-row numbering - see
/// `drawSynthGrid`). A mod-matrix slot's dest/depth fields aren't
/// individually mouse-addressable - a click anywhere on the slot's one
/// line lands on its source field (offset 0); `w`/`b` refine from there.
fn paramAtRow(app: *App, row: usize, x: usize, cols: u16) ?u16 {
    if (row == 0) return null; // title
    const view = app.synth_subview;
    if (app.synth_section_focus) {
        if (row < 2) return null;
        const order = if (view == .main) mainOrderNow(app) else modOrderNow(app);
        const focused = sectionOrder(order, app.synth_cursor);
        const param_row = row - 2;
        return if (param_row < focused.len) focused[param_row].id else null;
    }
    const full_row = app.synth_scroll + row - 1;
    const n = synth_layout.numCols(cols);
    const cw = synth_layout.colWidth(cols, n);
    const col = @min(@as(usize, x) / cw, n - 1);
    const order = if (view == .main) synth_layout.mainOrder(n) else synth_layout.modOrder(n);
    for (order) |pe| {
        if (pe.col == col and pe.row == full_row) return pe.id;
    }
    return null;
}

/// Click a param row to select it. Scroll over a param row nudges it via
/// the existing `adjustParam` (same step `h`/`l` use); **ctrl**+scroll is
/// the coarse step (matches `H`/`L`).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16) void {
    const body_row = row;
    switch (ev.kind) {
        .press => {
            const p = paramAtRow(app, body_row, ev.x, cols) orelse return;
            history.flushParamNudge(app);
            app.synth_cursor = p;
            updateScroll(app);
        },
        .scroll_up, .scroll_down => {
            const p = paramAtRow(app, body_row, ev.x, cols) orelse return;
            app.synth_cursor = p;
            updateScroll(app);
            const dir: i32 = if (ev.kind == .scroll_up) 1 else -1;
            adjustParam(app, dir * (if (ev.ctrl) @as(i32, 10) else 1));
        },
        else => {},
    }
}
