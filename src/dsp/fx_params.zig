//! Generic (FxKind, idx) parameter addressing for the effect rack, shared by
//! the FX chain editor UI and engine-driven automation. Lives in dsp/ (not
//! ui/) so the audio-thread automation delivery path (Engine.renderOneTrack)
//! can reach it without depending on the UI module. Split out of
//! ui/editors/fx_editor.zig, which originally owned this table alone; that
//! file now delegates here and keeps only the pieces that need `*App`
//! (comp's sidechain track/pad rows, CLAP/VST3 host-state params).
//!
//! `idx` is local to one FxUnit instance, not a track- or session-wide id -
//! callers pair it with the unit's `instance_id` to name a target uniquely,
//! the same shape the PolySynth mod-matrix already uses for
//! `fx_mod_bus`/`fx_instance_id`.

const std = @import("std");
const rack = @import("../rack.zig");
const FxPayload = rack.FxPayload;
const FxKind = rack.FxKind;
const eq_mod = @import("eq.zig");
const gate_mod = @import("gate.zig");
const multiband_comp = @import("multiband_comp.zig");
const chorus_mod = @import("chorus.zig");
const limiter_mod = @import("limiter.zig");
const expander_mod = @import("expander.zig");
const clipper_mod = @import("clipper.zig");
const saturator_mod = @import("saturator.zig");
const pitch_shift_mod = @import("pitch_shift.zig");
const utility_mod = @import("utility.zig");

/// Flat param list for a multiband compressor: 7 shared controls (crossover
/// x2, attack, release, knee, style, mix) followed by 3 fields (thresh/
/// ratio/makeup) per band, low->mid->high.
pub const mb_xover_lo = 0;
pub const mb_xover_hi = 1;
pub const mb_attack = 2;
pub const mb_release = 3;
pub const mb_knee = 4;
pub const mb_style = 5;
pub const mb_mix = 6;
pub const mb_shared_count = 7;
pub const mb_fields_per_band = 3; // thresh, ratio, makeup
const mb_comp_param_count = mb_shared_count + multiband_comp.num_bands * mb_fields_per_band;

pub const MbBandField = struct { band: usize, field: usize };

pub fn mbBandField(idx: usize) MbBandField {
    const rel = idx - mb_shared_count;
    return .{ .band = rel / mb_fields_per_band, .field = rel % mb_fields_per_band };
}

const mb_band_param_names = [multiband_comp.num_bands][mb_fields_per_band][]const u8{
    .{ "lo-thr", "lo-ratio", "lo-mkup" },
    .{ "mid-thr", "mid-ratio", "mid-mkup" },
    .{ "hi-thr", "hi-ratio", "hi-mkup" },
};

fn mbBandParamName(bf: MbBandField) []const u8 {
    return mb_band_param_names[bf.band][bf.field];
}

/// EQ params are a flat `band*eq_fields_per_band + field` list (kind, freq,
/// q, gain per band) - see ui/editors/fx_editor.zig's original doc comment
/// for the full rationale (gain/slope sharing a slot, etc).
pub const eq_field_kind = 0;
pub const eq_field_freq = 1;
pub const eq_field_q = 2;
pub const eq_field_gain = 3;
pub const eq_field_solo = 4;
pub const eq_field_stereo_mode = 5;
pub const eq_field_dyn_enabled = 6;
pub const eq_field_dyn_threshold = 7;
pub const eq_field_dyn_amount = 8;
pub const eq_fields_per_band = 9;

pub fn eqBandField(idx: usize) struct { band: usize, field: usize } {
    return .{ .band = idx / eq_fields_per_band, .field = idx % eq_fields_per_band };
}

pub const EqKindSpec = struct { label: []const u8, short_label: []const u8, title: []const u8, action_label: [:0]const u8 };
pub const eq_kind_specs = [_]EqKindSpec{
    .{ .label = "peak", .short_label = "BELL", .title = "BELL FILTER", .action_label = "BELL" },
    .{ .label = "lowpass", .short_label = "HC", .title = "HIGH CUT FILTER", .action_label = "HIGH CUT" },
    .{ .label = "highpass", .short_label = "LC", .title = "LOW CUT FILTER", .action_label = "LOW CUT" },
    .{ .label = "lowshelf", .short_label = "LS", .title = "LOW SHELF FILTER", .action_label = "LOW SHELF" },
    .{ .label = "highshelf", .short_label = "HS", .title = "HIGH SHELF FILTER", .action_label = "HIGH SHELF" },
    .{ .label = "notch", .short_label = "NTCH", .title = "NOTCH FILTER", .action_label = "NOTCH" },
    .{ .label = "tiltshelf", .short_label = "TILT", .title = "TILT SHELF FILTER", .action_label = "TILT" },
};

comptime {
    if (eq_kind_specs.len != std.meta.fields(eq_mod.BandKind).len) @compileError("eq_kind_specs must cover every BandKind");
}

/// One row of the per-kind param table driving the "plain" FX kinds below -
/// everything that reduces to reading/writing one f32 field (or, for a
/// couple of clamped/derived params, calling an existing method) against a
/// static range. EQ, multiband comp, and comp's sidechain rows don't fit
/// this shape (banded indexing, cross-field/App-derived state) and keep
/// their own switch arms instead.
const ParamSpec = struct {
    name: []const u8,
    field: []const u8 = "",
    getter: ?[]const u8 = null,
    setter: ?[]const u8 = null,
    min: f32,
    max: f32,
    step_fine: f32,
    step_coarse: f32,
    round: bool = false,
};

pub fn tableName(comptime table: []const ParamSpec, idx: usize) []const u8 {
    inline for (table, 0..) |spec, i| if (i == idx) return spec.name;
    return "?";
}

pub fn tableRange(comptime table: []const ParamSpec, idx: usize) [2]f32 {
    inline for (table, 0..) |spec, i| if (i == idx) return .{ spec.min, spec.max };
    return .{ 0.0, 1.0 };
}

pub fn tableStep(comptime table: []const ParamSpec, idx: usize, coarse: bool) f32 {
    inline for (table, 0..) |spec, i| if (i == idx) return if (coarse) spec.step_coarse else spec.step_fine;
    return 1.0;
}

pub fn tableGet(self: anytype, comptime table: []const ParamSpec, idx: usize) f32 {
    inline for (table, 0..) |spec, i| {
        if (i == idx) {
            if (spec.getter) |g| return @field(@TypeOf(self.*), g)(self);
            return @field(self.*, spec.field);
        }
    }
    return 0;
}

/// Clamps (and, for whole-number params, rounds) `value` to `spec`'s range
/// before writing it - through the setter method if one's given, otherwise
/// straight into the field.
pub fn tableSet(self: anytype, comptime table: []const ParamSpec, idx: usize, value: f32) void {
    inline for (table, 0..) |spec, i| {
        if (i == idx) {
            const clamped = if (spec.round)
                std.math.clamp(@round(value), spec.min, spec.max)
            else
                std.math.clamp(value, spec.min, spec.max);
            if (spec.setter) |s| {
                @field(@TypeOf(self.*), s)(self, clamped);
            } else {
                @field(self.*, spec.field) = clamped;
            }
            return;
        }
    }
}

pub const gate_specs = [_]ParamSpec{
    .{ .name = "thresh", .field = "threshold_db", .min = -80.0, .max = 0.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "attack", .field = "attack_ms", .min = 0.1, .max = 50.0, .step_fine = 0.5, .step_coarse = 5.0 },
    .{ .name = "hold", .field = "hold_ms", .min = 0.0, .max = 500.0, .step_fine = 5.0, .step_coarse = 50.0 },
    .{ .name = "release", .field = "release_ms", .min = 5.0, .max = 1000.0, .step_fine = 10.0, .step_coarse = 100.0 },
    .{ .name = "hyst", .field = "hysteresis_db", .min = 0.0, .max = 40.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "range", .field = "range_db", .min = gate_mod.mute_range_db, .max = 0.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "sc mode", .field = "sc_mode", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "sc hpf", .field = "sc_hpf_hz", .min = 0.0, .max = 2000.0, .step_fine = 20.0, .step_coarse = 200.0 },
    .{ .name = "sc lpf", .field = "sc_lpf_hz", .min = 0.0, .max = 20000.0, .step_fine = 100.0, .step_coarse = 1000.0 },
};

pub const filter_specs = [_]ParamSpec{
    .{ .name = "mode", .field = "mode", .min = 0.0, .max = 2.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "cutoff", .field = "cutoff_hz", .min = 20.0, .max = 20000.0, .step_fine = 10.0, .step_coarse = 100.0 },
    .{ .name = "resonance", .field = "resonance", .min = 0.1, .max = 1.4, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "drive", .field = "drive_db", .min = 0.0, .max = 24.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

pub const utility_specs = [_]ParamSpec{
    .{ .name = "gain", .field = "gain_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "polarity", .field = "invert", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "mono", .field = "mono", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "channel", .field = "channel", .min = 0.0, .max = 2.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "swap", .field = "swap", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "delay", .field = "delay_frames", .min = 0.0, .max = utility_mod.Utility.max_delay_frames, .step_fine = 1.0, .step_coarse = 32.0, .round = true },
    .{ .name = "noise", .field = "noise_on", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "color", .field = "noise_color", .min = 0.0, .max = 4.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "noise dB", .field = "noise_db", .min = -60.0, .max = 0.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "autogain", .field = "autogain_on", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "target", .field = "autogain_target_lufs", .min = -36.0, .max = -6.0, .step_fine = 1.0, .step_coarse = 3.0 },
};

pub const stereo_width_specs = [_]ParamSpec{
    .{ .name = "width", .field = "width", .min = 0.0, .max = 2.0, .step_fine = 0.05, .step_coarse = 0.25 },
    .{ .name = "output", .field = "output_db", .min = -24.0, .max = 12.0, .step_fine = 0.5, .step_coarse = 3.0 },
};

pub const auto_pan_specs = [_]ParamSpec{
    .{ .name = "rate", .field = "rate_hz", .min = 0.05, .max = 20.0, .step_fine = 0.05, .step_coarse = 1.0 },
    .{ .name = "sync", .field = "sync", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "beats", .field = "beats", .min = 0.25, .max = 16.0, .step_fine = 0.25, .step_coarse = 1.0 },
    .{ .name = "depth", .field = "depth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "phase", .field = "phase", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
};

pub const transient_shaper_specs = [_]ParamSpec{
    .{ .name = "attack", .field = "attack", .min = -1.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "sustain", .field = "sustain", .min = -1.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "output", .field = "output_db", .min = -24.0, .max = 12.0, .step_fine = 0.5, .step_coarse = 3.0 },
};

pub const sat_specs = [_]ParamSpec{
    .{ .name = "drive", .field = "drive_db", .min = 0.0, .max = 36.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "output", .field = "out_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "shape", .field = "shape", .min = 0.0, .max = saturator_mod.max_shape, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
};

pub const crush_specs = [_]ParamSpec{
    .{ .name = "bits", .field = "bits", .min = 1.0, .max = 16.0, .step_fine = 1.0, .step_coarse = 4.0, .round = true },
    .{ .name = "downsmp", .field = "downsample", .min = 1.0, .max = 32.0, .step_fine = 1.0, .step_coarse = 4.0, .round = true },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

pub const chorus_specs = [_]ParamSpec{
    .{ .name = "rate", .field = "rate_hz", .min = 0.05, .max = 5.0, .step_fine = 0.05, .step_coarse = 0.5 },
    .{ .name = "depth", .field = "depth_ms", .min = 0.0, .max = chorus_mod.max_depth_ms, .step_fine = 0.5, .step_coarse = 2.0 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

pub const phaser_specs = [_]ParamSpec{
    .{ .name = "rate", .field = "rate_hz", .min = 0.05, .max = 5.0, .step_fine = 0.05, .step_coarse = 0.5 },
    .{ .name = "depth", .field = "depth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "feedback", .field = "feedback", .min = 0.0, .max = 0.9, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

/// Flanger's controls are the same shape as phaser's (mechanical copy when
/// the unit was added).
pub const flanger_specs = phaser_specs;

pub const tape_specs = [_]ParamSpec{
    .{ .name = "wow rate", .field = "wow_rate_hz", .min = 0.05, .max = 3.0, .step_fine = 0.05, .step_coarse = 0.3 },
    .{ .name = "wow depth", .field = "wow_depth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "flutter rate", .field = "flutter_rate_hz", .min = 3.0, .max = 15.0, .step_fine = 0.5, .step_coarse = 2.0 },
    .{ .name = "flutter depth", .field = "flutter_depth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

pub const freq_shift_specs = [_]ParamSpec{
    .{ .name = "shift", .field = "shift_hz", .min = -2000.0, .max = 2000.0, .step_fine = 10.0, .step_coarse = 100.0 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

pub const pitch_shift_specs = [_]ParamSpec{
    .{ .name = "shift", .field = "semitones", .min = -24.0, .max = 24.0, .step_fine = 1.0, .step_coarse = 12.0 },
    .{ .name = "fine", .field = "cents", .min = -100.0, .max = 100.0, .step_fine = 1.0, .step_coarse = 10.0 },
    .{ .name = "formant", .field = "formant", .min = pitch_shift_mod.min_formant, .max = pitch_shift_mod.max_formant, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

pub const reverb_specs = [_]ParamSpec{
    .{ .name = "room", .field = "room", .min = 0.0, .max = 0.98, .step_fine = 0.02, .step_coarse = 0.1 },
    .{ .name = "damp", .field = "damp", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "predelay", .field = "predelay_ms", .min = 0.0, .max = 250.0, .step_fine = 5.0, .step_coarse = 25.0 },
    .{ .name = "width", .field = "width", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "low cut", .field = "low_cut_hz", .min = 0.0, .max = 500.0, .step_fine = 10.0, .step_coarse = 50.0 },
};

pub const delay_specs = [_]ParamSpec{
    .{ .name = "time", .field = "time_s", .min = 0.0, .max = 2.0, .step_fine = 0.01, .step_coarse = 0.1 },
    .{ .name = "feedback", .field = "feedback", .min = 0.0, .max = 0.95, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "damp", .field = "damp", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

pub const ott_specs = [_]ParamSpec{
    .{ .name = "depth", .getter = "depth", .setter = "setDepth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "time", .field = "time", .setter = "setTime", .min = 0.25, .max = 4.0, .step_fine = 0.05, .step_coarse = 0.5 },
    .{ .name = "in", .field = "gain_in_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "out", .field = "gain_out_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
};

pub const expander_specs = [_]ParamSpec{
    .{ .name = "thresh", .field = "threshold_db", .min = -80.0, .max = 0.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "ratio", .field = "ratio", .min = 1.0, .max = 20.0, .step_fine = 0.1, .step_coarse = 1.0 },
    .{ .name = "attack", .field = "attack_ms", .min = 0.1, .max = 500.0, .step_fine = 1.0, .step_coarse = 10.0 },
    .{ .name = "release", .field = "release_ms", .min = 1.0, .max = 2000.0, .step_fine = 10.0, .step_coarse = 100.0 },
    .{ .name = "knee", .field = "knee_db", .min = 0.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "range", .field = "range_db", .min = expander_mod.max_reduction_db, .max = 0.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "sc mode", .field = "sc_mode", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "sc hpf", .field = "sc_hpf_hz", .min = 0.0, .max = 2000.0, .step_fine = 20.0, .step_coarse = 200.0 },
    .{ .name = "sc lpf", .field = "sc_lpf_hz", .min = 0.0, .max = 20000.0, .step_fine = 100.0, .step_coarse = 1000.0 },
};

pub const clipper_specs = [_]ParamSpec{
    .{ .name = "drive", .field = "drive_db", .min = 0.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "ceiling", .field = "ceiling_db", .min = -24.0, .max = 0.0, .step_fine = 0.1, .step_coarse = 1.0 },
    .{ .name = "shape", .field = "shape", .min = 0.0, .max = clipper_mod.max_shape, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "odp", .field = "odp", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "odp knee", .field = "odp_knee_db", .min = 0.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
};

pub const limiter_specs = [_]ParamSpec{
    .{ .name = "ceiling", .field = "ceiling", .min = 0.25, .max = 1.0, .step_fine = 0.005, .step_coarse = 0.05 },
    .{ .name = "release", .field = "release_ms", .min = 1.0, .max = 1000.0, .step_fine = 10.0, .step_coarse = 100.0 },
    .{ .name = "lookahead", .field = "lookahead_ms", .min = 0.0, .max = limiter_mod.max_lookahead_ms, .step_fine = 1.0, .step_coarse = 5.0 },
    .{ .name = "true peak", .field = "true_peak", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "alr", .field = "alr", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "alr knee", .field = "alr_knee_db", .min = 0.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "alr rel", .field = "alr_release_ms", .min = 10.0, .max = 2000.0, .step_fine = 10.0, .step_coarse = 100.0 },
};

/// `comp`'s first 6 params only - idx 6/7 are the sidechain track/pad
/// spinners, which need an `App` and cross-field state this table can't
/// express, so they stay UI-only (see ui/editors/fx_editor.zig) and
/// `isAutomatable` excludes them.
pub const comp_specs = [_]ParamSpec{
    .{ .name = "thresh", .field = "threshold_db", .min = -60.0, .max = 0.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "ratio", .field = "ratio", .min = 1.0, .max = 20.0, .step_fine = 0.5, .step_coarse = 2.0 },
    .{ .name = "attack", .field = "attack_ms", .min = 0.1, .max = 500.0, .step_fine = 5.0, .step_coarse = 50.0 },
    .{ .name = "release", .field = "release_ms", .min = 1.0, .max = 2000.0, .step_fine = 20.0, .step_coarse = 200.0 },
    .{ .name = "makeup", .field = "makeup_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "knee", .field = "knee_db", .min = 0.0, .max = 24.0, .step_fine = 1.0, .step_coarse = 3.0 },
    .{ .name = "hold", .field = "hold_ms", .min = 0.0, .max = 500.0, .step_fine = 5.0, .step_coarse = 50.0 },
    .{ .name = "mode", .field = "mode", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "sc det", .field = "sc_mode", .min = 0.0, .max = 1.0, .step_fine = 1.0, .step_coarse = 1.0, .round = true },
    .{ .name = "sc hpf", .field = "sc_hpf_hz", .min = 0.0, .max = 2000.0, .step_fine = 10.0, .step_coarse = 100.0 },
    .{ .name = "sc lpf", .field = "sc_lpf_hz", .min = 0.0, .max = 20000.0, .step_fine = 100.0, .step_coarse = 1000.0 },
};

/// The two UI-only comp rows (sidechain track, sidechain pad) sit directly
/// after `comp_specs`, so every switch over them keys off these instead of
/// literals - appending a comp param moves both.
pub const comp_sidechain_idx = comp_specs.len;
pub const comp_sidechain_pad_idx = comp_specs.len + 1;

/// Param count for kind `k`, including the two UI-only comp sidechain rows
/// and excluding CLAP/VST3 (those enumerate dynamically via the plugin's own
/// `parameterCount`, not this static table - see `isAutomatable`).
pub fn paramCount(k: FxKind) usize {
    return switch (k) {
        .eq => eq_mod.num_eq_bands * eq_fields_per_band,
        .mb_comp => mb_comp_param_count,
        .comp => comp_specs.len + 2, // + sidechain track + sidechain pad
        .gate => gate_specs.len,
        .filter => filter_specs.len,
        .utility => utility_specs.len,
        .stereo_width => stereo_width_specs.len,
        .auto_pan => auto_pan_specs.len,
        .sat => sat_specs.len,
        .crush => crush_specs.len,
        .chorus => chorus_specs.len,
        .phaser => phaser_specs.len,
        .flanger => flanger_specs.len,
        .tape => tape_specs.len,
        .freq_shift => freq_shift_specs.len,
        .pitch_shift => pitch_shift_specs.len,
        .reverb => reverb_specs.len,
        .delay => delay_specs.len,
        .ott => ott_specs.len,
        .limiter => limiter_specs.len,
        .expander => expander_specs.len,
        .clipper => clipper_specs.len,
        .transient_shaper => transient_shaper_specs.len,
        .clap => 0,
        .vst3 => 0,
    };
}

/// True if `idx` on kind `k` is a plain DSP param this module's
/// getParam/setParamAbsolute can address directly - false for comp's
/// sidechain rows and any CLAP/VST3 index (those need `*App`/the plugin
/// host and stay UI-only). Automation lanes and the mod-matrix should only
/// ever target ids this returns true for.
pub fn isAutomatable(k: FxKind, idx: usize) bool {
    if (idx >= paramCount(k)) return false;
    return switch (k) {
        .comp => idx < comp_specs.len,
        .clap, .vst3 => false,
        else => true,
    };
}

/// Payload-aware counterpart for hosted plugins, whose parameter tables are
/// dynamic rather than represented by `paramCount`.
pub fn isPayloadAutomatable(p: *const FxPayload, idx: usize) bool {
    return switch (p.*) {
        .clap => |plugin| idx < plugin.parameterCount(),
        .vst3 => |plugin| idx < plugin.parameterCount(),
        else => isAutomatable(std.meta.activeTag(p.*), idx),
    };
}

/// Param name at `idx` in `p` - bounds match `paramCount`.
pub fn paramName(p: *const FxPayload, idx: usize) []const u8 {
    return switch (p.*) {
        .eq => |*e| blk: {
            const bf = eqBandField(idx);
            break :blk switch (bf.field) {
                eq_field_kind => "kind",
                eq_field_freq => "freq",
                eq_field_q => "q",
                eq_field_solo => "solo",
                eq_field_stereo_mode => "stereo",
                eq_field_dyn_enabled => "dyn on",
                eq_field_dyn_threshold => "dyn thr",
                eq_field_dyn_amount => "dyn amt",
                else => if (eq_mod.usesGain(e.bands[bf.band].kind)) "gain" else "slope",
            };
        },
        .mb_comp => switch (idx) {
            mb_xover_lo => "xover-lo",
            mb_xover_hi => "xover-hi",
            mb_attack => "attack",
            mb_release => "release",
            mb_knee => "knee",
            mb_style => "style",
            mb_mix => "mix",
            else => mbBandParamName(mbBandField(idx)),
        },
        .comp => switch (idx) {
            comp_sidechain_idx => "sidechain",
            comp_sidechain_pad_idx => "scpad",
            else => tableName(&comp_specs, idx),
        },
        .gate => tableName(&gate_specs, idx),
        .filter => tableName(&filter_specs, idx),
        .utility => tableName(&utility_specs, idx),
        .stereo_width => tableName(&stereo_width_specs, idx),
        .auto_pan => tableName(&auto_pan_specs, idx),
        .transient_shaper => tableName(&transient_shaper_specs, idx),
        .sat => tableName(&sat_specs, idx),
        .crush => tableName(&crush_specs, idx),
        .chorus => tableName(&chorus_specs, idx),
        .phaser => tableName(&phaser_specs, idx),
        .flanger => tableName(&flanger_specs, idx),
        .tape => tableName(&tape_specs, idx),
        .freq_shift => tableName(&freq_shift_specs, idx),
        .pitch_shift => tableName(&pitch_shift_specs, idx),
        .reverb => tableName(&reverb_specs, idx),
        .delay => tableName(&delay_specs, idx),
        .ott => tableName(&ott_specs, idx),
        .limiter => tableName(&limiter_specs, idx),
        .expander => tableName(&expander_specs, idx),
        .clipper => tableName(&clipper_specs, idx),
        .clap => "param",
        .vst3 => "param",
    };
}

/// Current value of param `idx` in `p` - bounds match `paramCount`. CLAP/VST3
/// always read 0 here (not automatable through this path - see
/// `isAutomatable`); their live values are read through the plugin host
/// instead (ui/editors/fx_editor.zig's `getParam`).
pub fn getParam(p: *const FxPayload, idx: usize) f32 {
    return switch (p.*) {
        .eq => |*e| blk: {
            const bf = eqBandField(idx);
            const band = &e.bands[bf.band];
            break :blk switch (bf.field) {
                eq_field_kind => @floatFromInt(@intFromEnum(band.kind)),
                eq_field_freq => band.freq,
                eq_field_q => band.q,
                eq_field_solo => if (band.solo) 1.0 else 0.0,
                eq_field_stereo_mode => @floatFromInt(@intFromEnum(band.stereo_mode)),
                eq_field_dyn_enabled => if (band.dyn_enabled) 1.0 else 0.0,
                eq_field_dyn_threshold => band.dyn_threshold_db,
                eq_field_dyn_amount => band.dyn_amount_db,
                else => if (eq_mod.usesGain(band.kind)) band.gain_db else @floatFromInt(band.slope),
            };
        },
        .mb_comp => |*m| switch (idx) {
            mb_xover_lo => m.xover_lo_hz,
            mb_xover_hi => m.xover_hi_hz,
            mb_attack => m.attack_ms,
            mb_release => m.release_ms,
            mb_knee => m.knee_db,
            mb_style => if (m.style == .ott) 1.0 else 0.0,
            mb_mix => m.mix,
            else => blk: {
                const bf = mbBandField(idx);
                const band = m.bands[bf.band];
                break :blk switch (bf.field) {
                    0 => band.threshold_db,
                    1 => band.ratio,
                    else => band.makeup_db,
                };
            },
        },
        .comp => |*c| switch (idx) {
            comp_sidechain_idx, comp_sidechain_pad_idx => 0.0,
            else => tableGet(c, &comp_specs, idx),
        },
        .gate => |*g| tableGet(g, &gate_specs, idx),
        .filter => |*f| tableGet(f, &filter_specs, idx),
        .utility => |*u| tableGet(u, &utility_specs, idx),
        .stereo_width => |*w| tableGet(w, &stereo_width_specs, idx),
        .auto_pan => |*a| tableGet(a, &auto_pan_specs, idx),
        .transient_shaper => |*t| tableGet(t, &transient_shaper_specs, idx),
        .sat => |*s| tableGet(s, &sat_specs, idx),
        .crush => |*c| tableGet(c, &crush_specs, idx),
        .chorus => |*c| tableGet(c, &chorus_specs, idx),
        .phaser => |*p2| tableGet(p2, &phaser_specs, idx),
        .flanger => |*fl| tableGet(fl, &flanger_specs, idx),
        .tape => |*t| tableGet(t, &tape_specs, idx),
        .freq_shift => |*f| tableGet(f, &freq_shift_specs, idx),
        .pitch_shift => |*ps| tableGet(ps, &pitch_shift_specs, idx),
        .reverb => |*r| tableGet(r, &reverb_specs, idx),
        .delay => |*d| tableGet(d, &delay_specs, idx),
        .ott => |*o| tableGet(o, &ott_specs, idx),
        .limiter => |*l| tableGet(l, &limiter_specs, idx),
        .expander => |*e| tableGet(e, &expander_specs, idx),
        .clipper => |*c| tableGet(c, &clipper_specs, idx),
        .clap, .vst3 => 0.0,
    };
}

/// [min, max] of param `idx` in a unit of kind `k`. Comp's sidechain rows
/// (6/7) return a dummy range - never hit through `isAutomatable`-gated
/// callers.
pub fn paramRange(p: *const FxPayload, idx: usize) [2]f32 {
    return switch (p.*) {
        .eq => |*e| switch (eqBandField(idx).field) {
            eq_field_kind => .{ 0.0, @floatFromInt(eq_kind_specs.len - 1) },
            eq_field_freq => .{ 20.0, 20000.0 },
            eq_field_q => .{ 0.1, 10.0 },
            eq_field_solo, eq_field_dyn_enabled => .{ 0.0, 1.0 },
            eq_field_stereo_mode => .{ 0.0, @floatFromInt(std.meta.fields(eq_mod.StereoMode).len - 1) },
            eq_field_dyn_threshold => .{ -60.0, 0.0 },
            eq_field_dyn_amount => .{ -18.0, 18.0 },
            else => if (eq_mod.usesGain(e.bands[eqBandField(idx).band].kind))
                [2]f32{ -18.0, 18.0 }
            else
                [2]f32{ 1.0, @floatFromInt(eq_mod.max_slope) },
        },
        .mb_comp => switch (idx) {
            mb_xover_lo, mb_xover_hi => .{ 20.0, 20000.0 },
            mb_attack => .{ 0.1, 500.0 },
            mb_release => .{ 1.0, 2000.0 },
            mb_knee => .{ 0.0, 24.0 },
            mb_style => .{ 0.0, 1.0 },
            mb_mix => .{ 0.0, 1.0 },
            else => switch (mbBandField(idx).field) {
                0 => .{ -60.0, 0.0 }, // threshold
                1 => .{ 1.0, 20.0 }, // ratio
                else => .{ -24.0, 24.0 }, // makeup
            },
        },
        .comp => switch (idx) {
            comp_sidechain_idx, comp_sidechain_pad_idx => .{ 0.0, 0.0 },
            else => tableRange(&comp_specs, idx),
        },
        .gate => tableRange(&gate_specs, idx),
        .filter => tableRange(&filter_specs, idx),
        .utility => tableRange(&utility_specs, idx),
        .stereo_width => tableRange(&stereo_width_specs, idx),
        .auto_pan => tableRange(&auto_pan_specs, idx),
        .transient_shaper => tableRange(&transient_shaper_specs, idx),
        .sat => tableRange(&sat_specs, idx),
        .crush => tableRange(&crush_specs, idx),
        .chorus => tableRange(&chorus_specs, idx),
        .phaser => tableRange(&phaser_specs, idx),
        .flanger => tableRange(&flanger_specs, idx),
        .tape => tableRange(&tape_specs, idx),
        .freq_shift => tableRange(&freq_shift_specs, idx),
        .pitch_shift => tableRange(&pitch_shift_specs, idx),
        .reverb => tableRange(&reverb_specs, idx),
        .delay => tableRange(&delay_specs, idx),
        .ott => tableRange(&ott_specs, idx),
        .limiter => tableRange(&limiter_specs, idx),
        .expander => tableRange(&expander_specs, idx),
        .clipper => tableRange(&clipper_specs, idx),
        .clap => |plugin| blk: {
            const info = plugin.parameterInfo(@intCast(idx)) orelse break :blk .{ 0.0, 1.0 };
            break :blk .{ @floatCast(info.min_value), @floatCast(info.max_value) };
        },
        .vst3 => .{ 0.0, 1.0 },
    };
}

/// Clamped absolute set of param `idx` in `p` - bounds match `paramRange`.
/// Comp's sidechain rows (6/7) and CLAP/VST3 are no-ops here (never hit
/// through `isAutomatable`-gated callers; see ui/editors/fx_editor.zig for
/// the UI paths that do handle them).
pub fn setParamAbsolute(p: *FxPayload, idx: usize, value: f32) void {
    if (!std.math.isFinite(value) or !isAutomatable(std.meta.activeTag(p.*), idx)) return;
    switch (p.*) {
        .eq => |*e| {
            const bf = eqBandField(idx);
            const band = &e.bands[bf.band];
            switch (bf.field) {
                eq_field_kind => {
                    const rounded = std.math.clamp(@round(value), 0.0, @as(f32, @floatFromInt(eq_kind_specs.len - 1)));
                    e.setType(bf.band, @enumFromInt(@as(u8, @intFromFloat(rounded))), band.slope);
                },
                eq_field_freq => e.setFreq(bf.band, value),
                eq_field_q => e.setQ(bf.band, value),
                eq_field_solo => e.setSolo(bf.band, value >= 0.5),
                eq_field_stereo_mode => {
                    const rounded = std.math.clamp(@round(value), 0.0, @as(f32, @floatFromInt(std.meta.fields(eq_mod.StereoMode).len - 1)));
                    e.setStereoMode(bf.band, @enumFromInt(@as(u8, @intFromFloat(rounded))));
                },
                eq_field_dyn_enabled => e.setDynEnabled(bf.band, value >= 0.5),
                eq_field_dyn_threshold => e.setDynThreshold(bf.band, value),
                eq_field_dyn_amount => e.setDynAmount(bf.band, value),
                else => if (eq_mod.usesGain(band.kind))
                    e.setGain(bf.band, value)
                else
                    e.setType(bf.band, band.kind, @intFromFloat(std.math.clamp(@round(value), 1.0, @as(f32, eq_mod.max_slope)))),
            }
        },
        .mb_comp => |*m| switch (idx) {
            mb_xover_lo => m.setXoverLo(value),
            mb_xover_hi => m.setXoverHi(value),
            mb_attack => m.attack_ms = std.math.clamp(value, 0.1, 500.0),
            mb_release => m.release_ms = std.math.clamp(value, 1.0, 2000.0),
            mb_knee => m.knee_db = std.math.clamp(value, 0.0, 24.0),
            mb_style => m.style = if (value >= 0.5) .ott else .classic,
            mb_mix => m.mix = std.math.clamp(value, 0.0, 1.0),
            else => {
                const bf = mbBandField(idx);
                const band = &m.bands[bf.band];
                switch (bf.field) {
                    0 => band.threshold_db = std.math.clamp(value, -60.0, 0.0),
                    1 => band.ratio = std.math.clamp(value, 1.0, 20.0),
                    else => band.makeup_db = std.math.clamp(value, -24.0, 24.0),
                }
            },
        },
        .comp => |*c| switch (idx) {
            comp_sidechain_idx, comp_sidechain_pad_idx => {},
            else => tableSet(c, &comp_specs, idx, value),
        },
        .gate => |*g| tableSet(g, &gate_specs, idx, value),
        .filter => |*f| tableSet(f, &filter_specs, idx, value),
        .utility => |*u| tableSet(u, &utility_specs, idx, value),
        .stereo_width => |*w| tableSet(w, &stereo_width_specs, idx, value),
        .auto_pan => |*a| tableSet(a, &auto_pan_specs, idx, value),
        .transient_shaper => |*t| tableSet(t, &transient_shaper_specs, idx, value),
        .sat => |*s| tableSet(s, &sat_specs, idx, value),
        .crush => |*c| tableSet(c, &crush_specs, idx, value),
        .chorus => |*c| tableSet(c, &chorus_specs, idx, value),
        .phaser => |*p2| tableSet(p2, &phaser_specs, idx, value),
        .flanger => |*fl| tableSet(fl, &flanger_specs, idx, value),
        .tape => |*t| tableSet(t, &tape_specs, idx, value),
        .freq_shift => |*f| tableSet(f, &freq_shift_specs, idx, value),
        .pitch_shift => |*ps| tableSet(ps, &pitch_shift_specs, idx, value),
        .reverb => |*r| tableSet(r, &reverb_specs, idx, value),
        .delay => |*d| tableSet(d, &delay_specs, idx, value),
        .ott => |*o| tableSet(o, &ott_specs, idx, value),
        .limiter => |*l| tableSet(l, &limiter_specs, idx, value),
        .expander => |*e| tableSet(e, &expander_specs, idx, value),
        .clipper => |*c| tableSet(c, &clipper_specs, idx, value),
        .clap, .vst3 => {},
    }
}

/// Nudge step for param `idx` - `coarse` picks the bigger of the two, sized
/// per param so a single press is a musically useful move (1 dB fine / 6 dB
/// coarse for EQ and comp threshold, fractions for the 0..1-ish delay/reverb
/// knobs). `ui/editors/fx_editor.zig` wraps this for the rows it owns
/// (comp sidechain, CLAP ranges).
pub fn paramStep(p: *const FxPayload, idx: usize, coarse: bool) f32 {
    return switch (p.*) {
        .eq => |*e| switch (eqBandField(idx).field) {
            eq_field_kind => 1.0,
            eq_field_freq => if (coarse) @as(f32, 100.0) else 10.0,
            eq_field_q => if (coarse) @as(f32, 0.5) else 0.1,
            eq_field_solo, eq_field_dyn_enabled, eq_field_stereo_mode => 1.0,
            eq_field_dyn_threshold, eq_field_dyn_amount => if (coarse) @as(f32, 6.0) else 1.0,
            // gain steps normally; slope steps whole cascade stages, coarse
            // jumping the full 1..max_slope range in one press.
            else => if (eq_mod.usesGain(e.bands[eqBandField(idx).band].kind))
                (if (coarse) @as(f32, 6.0) else 1.0)
            else
                (if (coarse) @as(f32, eq_mod.max_slope) else 1.0),
        },
        .mb_comp => switch (idx) {
            mb_xover_lo, mb_xover_hi => if (coarse) @as(f32, 100.0) else 10.0,
            mb_attack => if (coarse) @as(f32, 50.0) else 5.0,
            mb_release => if (coarse) @as(f32, 200.0) else 20.0,
            mb_knee => if (coarse) @as(f32, 3.0) else 1.0,
            mb_style => 1.0, // toggle, whole steps only
            mb_mix => if (coarse) @as(f32, 0.2) else 0.05,
            else => switch (mbBandField(idx).field) {
                0 => if (coarse) @as(f32, 6.0) else 1.0, // threshold
                1 => if (coarse) @as(f32, 2.0) else 0.5, // ratio
                else => if (coarse) @as(f32, 3.0) else 0.5, // makeup
            },
        },
        .comp => switch (idx) {
            comp_sidechain_idx, comp_sidechain_pad_idx => 1.0,
            else => tableStep(&comp_specs, idx, coarse),
        },
        .gate => tableStep(&gate_specs, idx, coarse),
        .filter => tableStep(&filter_specs, idx, coarse),
        .utility => tableStep(&utility_specs, idx, coarse),
        .stereo_width => tableStep(&stereo_width_specs, idx, coarse),
        .auto_pan => tableStep(&auto_pan_specs, idx, coarse),
        .transient_shaper => tableStep(&transient_shaper_specs, idx, coarse),
        .sat => tableStep(&sat_specs, idx, coarse),
        .crush => tableStep(&crush_specs, idx, coarse),
        .chorus => tableStep(&chorus_specs, idx, coarse),
        .phaser => tableStep(&phaser_specs, idx, coarse),
        .flanger => tableStep(&flanger_specs, idx, coarse),
        .tape => tableStep(&tape_specs, idx, coarse),
        .freq_shift => tableStep(&freq_shift_specs, idx, coarse),
        .pitch_shift => tableStep(&pitch_shift_specs, idx, coarse),
        .reverb => tableStep(&reverb_specs, idx, coarse),
        .delay => tableStep(&delay_specs, idx, coarse),
        .ott => tableStep(&ott_specs, idx, coarse),
        .limiter => tableStep(&limiter_specs, idx, coarse),
        .expander => tableStep(&expander_specs, idx, coarse),
        .clipper => tableStep(&clipper_specs, idx, coarse),
        .clap, .vst3 => if (coarse) @as(f32, 0.1) else 0.01,
    };
}

test "isAutomatable excludes comp sidechain rows and every clap/vst3 index" {
    try std.testing.expect(!isAutomatable(.comp, comp_sidechain_idx));
    try std.testing.expect(!isAutomatable(.comp, comp_sidechain_pad_idx));
    try std.testing.expect(isAutomatable(.comp, 0));
    try std.testing.expect(!isAutomatable(.clap, 0));
    try std.testing.expect(!isAutomatable(.vst3, 0));
    try std.testing.expect(!isAutomatable(.gate, 99));
}

test "getParam/setParamAbsolute round-trip a plain table-driven param" {
    var payload: FxPayload = .{ .sat = .{} };
    setParamAbsolute(&payload, 0, 12.0);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), getParam(&payload, 0), 1e-6);
    // Clamped to sat_specs[0]'s [0, 36] range.
    setParamAbsolute(&payload, 0, 999.0);
    try std.testing.expectApproxEqAbs(@as(f32, 36.0), getParam(&payload, 0), 1e-6);
}

test "getParam/setParamAbsolute round-trip an eq band field" {
    var payload: FxPayload = .{ .eq = eq_mod.ParametricEq.init(48_000) };
    setParamAbsolute(&payload, eq_field_freq, 5000.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5000.0), getParam(&payload, eq_field_freq), 1e-3);
}

test "setParamAbsolute ignores non-finite values" {
    var table_payload: FxPayload = .{ .sat = .{} };
    const drive = getParam(&table_payload, 0);
    setParamAbsolute(&table_payload, 0, std.math.nan(f32));
    setParamAbsolute(&table_payload, 0, std.math.inf(f32));
    try std.testing.expectEqual(drive, getParam(&table_payload, 0));

    var eq_payload: FxPayload = .{ .eq = eq_mod.ParametricEq.init(48_000) };
    const kind = getParam(&eq_payload, eq_field_kind);
    setParamAbsolute(&eq_payload, eq_field_kind, std.math.nan(f32));
    try std.testing.expectEqual(kind, getParam(&eq_payload, eq_field_kind));
}

test "setParamAbsolute ignores invalid parameter ids" {
    var eq_payload: FxPayload = .{ .eq = eq_mod.ParametricEq.init(48_000) };
    setParamAbsolute(&eq_payload, std.math.maxInt(usize), 1.0);

    var mb_payload: FxPayload = .{ .mb_comp = .{} };
    setParamAbsolute(&mb_payload, std.math.maxInt(usize), 1.0);
}
