//! Factory synth patches - curated `PolySynth.Patch` values exercising the
//! engine's oscillators, filters, envelopes, mod matrix, internal FX chain,
//! and arpeggiator. Presets cost nothing to ship: they're plain data (no
//! rendered/embedded audio), applied at runtime via `PolySynth.applyPatch`.
//! See `:synth-preset` in commands.zig.
//!
//! Every mod route is an explicit `mod_matrix` row. Dest ids used below
//! (see `automatable_params`):
//! 4 UNI DET A · 11 LEVEL B · 21 CUTOFF ·
//! 22 RES · 34 SUB LVL · 36 NOISE LVL · 42 WARP AMT A · 47 CUTOFF 2 ·
//! 44 WARP AMT B - the FM index when OSC B warps into A. Not 15, which is
//! OSC C's warp and was mislabelled "MOD AMT" here while every FM preset
//! routed its index at it, modulating an oscillator none of them enable ·
//! 55 LEVEL C · 85 DIST MIX · 89 CRUSH MIX · 94 FLNG MIX · 107 PHSR MIX ·
//! 111 DLY MIX · 115 VRB MIX · 179 CHOR MIX · 182 FRQS SHIFT ·
//! 185 WT POS A · plus the dP/dA virtual pitch/amp dests.
//! There is no pulse-width dest: the synth has no PW param, and a pulse
//! width is set by warping a square with `bend`, whose phase pivot is the
//! same control. Ids 1 and 8 were listed here as "PW A"/"PW B" and match
//! nothing in `param_specs`, so a row aimed at either would have modulated
//! nothing.
//!
//! Macro convention (all four default to 0, so every patch sounds stock
//! until a knob moves): MACRO 1 = brightness (cutoff; on a formant filter
//! the same knob scans the vowel and is labelled "vowel", because past /i/
//! it gets darker, not brighter), MACRO 2 = timbre motion (FM depth,
//! waveform position, warp, wavetable pos, resonance),
//! MACRO 3 = space (delay/reverb/chorus/phaser
//! mix), MACRO 4 = grit (dist/crush mix). Only routes that fit the sound
//! are wired, but every preset except init carries at least one.

const std = @import("std");
const rack = @import("../rack.zig");
const synth = @import("synth.zig");
const PolySynth = synth.PolySynth;
const Patch = PolySynth.Patch;
const ModRow = PolySynth.ModRow;
const dP = PolySynth.dest_pitch;
const dA = PolySynth.dest_amp;

/// Name the four macro knobs (comptime only). An empty string leaves that
/// slot unnamed, which is what an unused macro should be.
fn macros(comptime names: [4][]const u8) [4]synth.MacroLabel {
    @setEvalBranchQuota(50_000);
    var out: [4]synth.MacroLabel = @splat(.{});
    for (names, 0..) |name, i| out[i] = synth.MacroLabel.init(name);
    return out;
}

/// Pad a row list out to a full `mod_matrix` array (comptime only).
fn mods(comptime rows: []const ModRow) [PolySynth.max_mod_rows]ModRow {
    var out = [_]ModRow{.{}} ** PolySynth.max_mod_rows;
    for (rows, 0..) |r, i| out[i] = r;
    return out;
}

/// Pad one drawn LFO shape's breakpoints out to a full per-slot array
/// (comptime only) - `mods`'s counterpart for LFO shapes instead of matrix
/// rows. Pair with a matching `lfo_custom_count` entry; a slot whose shape
/// isn't `.drawn` can just be `lfoPoints(&.{})` since its padding is never
/// read.
fn lfoPoints(comptime points: []const synth.LfoShapePoint) [synth.max_lfo_shape_points]synth.LfoShapePoint {
    var out = [_]synth.LfoShapePoint{.{}} ** synth.max_lfo_shape_points;
    for (points, 0..) |p, i| out[i] = p;
    return out;
}

/// `lfoPoints` by waveform name, for the three slots at once - a patch that
/// just wants a triangle LFO shouldn't have to spell out its breakpoints.
/// Sine is the default shape, so `.sine` is also what an unused slot takes.
fn waves(comptime w: [3]synth.LfoWave) [3][synth.max_lfo_shape_points]synth.LfoShapePoint {
    return .{ synth.lfoWave(w[0]).points, synth.lfoWave(w[1]).points, synth.lfoWave(w[2]).points };
}

/// `waves`' matching `lfo_custom_count` entries.
fn waveCounts(comptime w: [3]synth.LfoWave) [3]u8 {
    return .{ synth.lfoWave(w[0]).count, synth.lfoWave(w[1]).count, synth.lfoWave(w[2]).count };
}

/// One insert a preset wants in its chain, named by rack kind and set by
/// param index rather than by a dedicated `fx_*` Patch field per knob.
///
/// The `fx_*` fields cover fourteen units and cost roughly seven new Patch
/// fields for every unit added, which is why ten of the rack's twenty-five
/// native units were unreachable from a preset - and therefore unreachable
/// from a preset's mod matrix, since a row cannot modulate a unit that was
/// never built. This reaches all of them and costs nothing per unit. The
/// `fx_*` fields stay regardless: they are the CLAP/VST3 parameter surface,
/// not just preset storage.
pub const FxSpec = struct {
    kind: rack.FxKind,
    /// Index into the unit's `fx_params` spec table, and the value to set.
    params: []const Param = &.{},

    pub const Param = struct { idx: u16, value: f32 };
};

pub const Preset = struct {
    name: []const u8,
    /// Sound role, not genre - e.g. "bass", "lead", "pad".
    category: []const u8,
    /// First tag is always "wstudio"; the rest are genre associations.
    tags: []const []const u8,
    patch: Patch,
    /// Inserts appended after whatever the patch's `fx_*` fields build.
    /// A `mod_matrix` row targets one of these by setting `fx_instance_id`
    /// to its 1-based position in this list and `dest` to the unit's param
    /// index; `buildPresetFx` swaps the placeholder for the real instance id
    /// once the unit exists.
    fx: []const FxSpec = &.{},
};

/// Like `find`, but keeps the whole preset - the generic `fx` chain included.
pub fn findPreset(name: []const u8) ?Preset {
    for (presets) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
    }
    return null;
}

pub const presets = [_]Preset{
    .{ .name = "init", .category = "utility", .tags = &.{"wstudio"}, .patch = .{} },

    // zig fmt: off
    // warm-pad - HP'd low end, ensemble chorus + hall, macro 1 as a
    // brightness ride, sub-octave sine for body
    .{ .name = "warm-pad", .category = "pad", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 6, .unison_detune = 18.0, .unison_spread = 0.7,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.0, .osc_c_semi = -12.0, .osc_c_level = 0.35,
        .attack_s = 0.9, .decay_s = 0.6, .sustain = 0.85, .release_s = 1.4, .env_curve = -0.3,
        .filter_type = .lp, .filter_cutoff = 2800.0, .filter_res = 0.12,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 120.0, .filter_routing = .series,
        .lfo_rate_hz = 0.25, .lfo_sync = .n2_1, .lfo_slew_ms = 35.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = 21,  .depth = 0.06 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 5 }, .{ .idx = 2, .value = 0.4 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.75 }, .{ .idx = 1, .value = 0.4 }, .{ .idx = 2, .value = 0.25 } } },
    } },

    // pluck - ladder filter, velocity + keytrack into cutoff, dotted echo
    .{ .name = "pluck", .category = "pluck", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .attack_s = 0.001, .decay_s = 0.18, .sustain = 0.0, .release_s = 0.12, .env_curve = 0.65,
        .filter_type = .ladder, .filter_cutoff = 900.0, .filter_res = 0.15,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.15, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.7,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.8 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.5 },
            .{ .source = .mac1, .dest = 185, .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "echo", "" }),
        .gain = 0.35,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.375 } } },
    } },

    // sub-bass - pure sine kept pure; light drive adds the harmonics small
    // speakers need, keytrack keeps the top of the range from dulling
    .{ .name = "sub-bass", .category = "bass", .tags = &.{ "wstudio", "house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 500.0, .filter_res = 0.0,
        .sub_level = 0.8, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21, .depth = 0.2 },
            .{ .source = .random,   .dest = 21, .depth = 0.015 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.5, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 34,  .depth = 0.3 },
        }),
        .macro_labels = macros(.{ "brightness", "sub", "", "drive" }),
        .gain = 0.44,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 6 }, .{ .idx = 2, .value = 0.15 } } },
    } },

    // acid-bass - diode ladder (the 303-family filter), overdriven, with
    // velocity accent into cutoff like the real box's accent knob
    .{ .name = "acid-bass", .category = "bass", .tags = &.{ "wstudio", "acid" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.04,
        .attack_s = 0.001, .decay_s = 0.25, .sustain = 0.2, .release_s = 0.08,
        .filter_type = .diode, .filter_cutoff = 300.0, .filter_res = 0.75, .filter_drive = 5.5,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.22, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.6,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.875 },
            // Accent on the real thing is not just louder: it opens the filter AND
            // kicks the resonance for that step, which is where the squelch
            // comes from. Velocity carries both.
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .velocity, .dest = 22, .depth = 0.15 },
            .{ .source = .keytrack, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.5 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.25 },
            .{ .source = .mac4,     .dest = 249, .depth = 0.35 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "cutoff", "squelch", "", "drive" }),
        .gain = 1.0,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 10 }, .{ .idx = 2, .value = 0.5 } } },
    } },

    // brass-stab - third osc a sub octave down for weight, velocity opens
    // the filter for played dynamics
    .{ .name = "brass-stab", .category = "stab", .tags = &.{ "wstudio", "house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 8.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 9.0, .osc_b_level = 0.6,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.6666667, .osc_c_semi = -12.0, .osc_c_level = 0.4,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.6, .release_s = 0.2, .env_curve = 0.35,
        .filter_type = .lp, .filter_cutoff = 700.0, .filter_res = 0.1,
        // Filter opening after the level, as on retro-brass.
        .fenv_attack_s = 0.035, .fenv_decay_s = 0.35, .fenv_sustain = 0.3, .fenv_release_s = 0.2, .fenv_curve = 0.4,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.625 },
            .{ .source = .velocity, .dest = 21, .depth = 0.4 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "" }),
        .gain = 0.32,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.55 }, .{ .idx = 1, .value = 0.45 }, .{ .idx = 2, .value = 0.12 } } },
    } },

    // supersaw-lead - HP'd like the JP-8000's stack, macro 1 rides the
    // cutoff, wash of delay + reverb baked in
    .{ .name = "supersaw-lead", .category = "lead", .tags = &.{ "wstudio", "trance" }, .patch = .{
        // Seven, not eight: the JP-8000 super saw is seven saws around a
        // centre one that stays put, and `spread` mode only leaves a voice at
        // centre when the count is odd. An even count detunes every voice off
        // the played pitch, which is why the note itself sat slightly hollow.
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 7, .unison_detune = 22.0, .unison_spread = 0.85,
        .attack_s = 0.01, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 6500.0, .filter_res = 0.15,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 180.0, .filter_routing = .series,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .random, .dest = dP,  .depth = 0.003 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 4,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 2 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "echo", "" }),
        .gain = 0.53,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.375 }, .{ .idx = 1, .value = 0.4 }, .{ .idx = 2, .value = 0.28 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.22 } } },
    } },

    // bell-fm - velocity drives FM depth (hard hits ring brighter), plate
    // reverb tail
    // The two things that make an FM bell a bell, neither of which this had:
    // the modulator sits at a NON-integer ratio (Chowning's original bell is
    // 1:1.4 - a tritone is 1.414, so six semitones shy 15 cents lands on it),
    // and its index decays faster than the note does, so the inharmonic clang
    // is an attack transient over a tone that settles almost pure. An octave
    // up at a fixed index is a harmonic spectrum that never simplifies, which
    // is an FM organ.
    .{ .name = "bell-fm", .category = "keys", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 6.0, .osc_b_detune_cents = -15.0,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 1.2,
        .attack_s = 0.001, .decay_s = 1.2, .sustain = 0.0, .release_s = 1.8, .env_curve = 0.72,
        .filter_type = .lp, .filter_cutoff = 12_000.0, .filter_res = 0.0,
        .env3_attack_s = 0.001, .env3_decay_s = 0.5, .env3_sustain = 0.0, .env3_release_s = 0.4,
        .mod_matrix = mods(&.{
            .{ .source = .env3,     .dest = 44,  .depth = 0.45 },
            .{ .source = .velocity, .dest = 44,  .depth = 0.15 },
            .{ .source = .random,   .dest = 44,  .depth = 0.025 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.25 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "", "bell", "space", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.8 }, .{ .idx = 1, .value = 0.3 } } },
    } },

    // wobble-bass - wavetable osc so the LFO scans timbre in step with the
    // filter wobble; ladder filter + drive for the low-end snarl
    .{ .name = "wobble-bass", .category = "bass", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .wt_table = .spectral, .wt_pos = 0.55, .voice_mode = .mono, .glide_s = 0.02,
        .sub_level = 0.5,
        .attack_s = 0.005, .decay_s = 0.1, .sustain = 1.0, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 400.0, .filter_res = 0.3,
        // .custom, not .triangle: the genre-defining wobble is asymmetric -
        // a fast bite open then a slower, curved close - not a symmetric
        // rise/fall. Fast attack to the peak (10% of the cycle), then a
        // two-stage decay (quick initial drop easing into a slow tail)
        // approximates that curved knee out of straight-line segments.
        .lfo_shape = .drawn, .lfo_rate_hz = 4.5, .lfo_sync = .n1_8, .lfo_retrig = .key,
        .lfo_custom = .{
            lfoPoints(&.{
                .{ .phase = 0.0,  .value = -1.0 },
                .{ .phase = 0.1,  .value = 1.0 },
                .{ .phase = 0.25, .value = 0.6 },
                .{ .phase = 0.5,  .value = 0.0 },
                .{ .phase = 0.85, .value = -0.8 },
                .{ .phase = 1.0,  .value = -1.0 },
            }),
            lfoPoints(&.{}),
            lfoPoints(&.{}),
        },
        .lfo_custom_count = .{ 6, 0, 0 },
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = 185, .depth = 0.3 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 185, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "wobble", "", "drive" }),
        .gain = 0.69,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 2, .value = 0.4 } } },
    } },

    // wind-riser - chaos LFO stirs the bandpass, ENV 3's slow ramp bends
    // pitch upward with the swell, flanger for the jet whoosh
    .{ .name = "wind-riser", .category = "fx", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .noise_level = 0.5, .noise_color = 0.35,
        .attack_s = 2.5, .decay_s = 0.5, .sustain = 0.9, .release_s = 2.0,
        .filter_type = .bp, .filter_cutoff = 1200.0, .filter_res = 0.3,
        .lfo_shape = .chaos, .lfo_rate_hz = 0.5,
        .env3_attack_s = 3.0, .env3_decay_s = 0.5, .env3_sustain = 1.0, .env3_release_s = 1.5, .env3_curve = -0.45,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21, .depth = 0.25 },
            .{ .source = .env3, .dest = dP, .depth = 0.4 },
            .{ .source = .mac1, .dest = 21, .depth = 0.5 },
            .{ .source = .mac3, .dest = 3, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 22,  .depth = 0.25 },
        }),
        .macro_labels = macros(.{ "brightness", "resonance", "flange", "" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .flanger, .params = &.{ .{ .idx = 0, .value = 0.15 }, .{ .idx = 1, .value = 0.9 }, .{ .idx = 2, .value = 0.6 } } },
    } },

    // dusty-pad - bit-crush dust + tape-wobble pitch drift from LFO 2,
    // HP'd so the haze sits above the bassline
    .{ .name = "dusty-pad", .category = "pad", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 4, .unison_detune = 10.0, .unison_spread = 0.5,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.3333333, .osc_b_level = 0.5,
        .noise_level = 0.08, .noise_color = 0.5,
        .attack_s = 1.2, .decay_s = 0.8, .sustain = 0.6, .release_s = 1.6,
        .filter_type = .lp, .filter_cutoff = 1800.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 100.0, .filter_routing = .series,
        .lfo_rate_hz = 0.2,
        .lfo2_rate_hz = 0.7, .lfo2_phase_offset = 0.37, .lfo2_slew_ms = 45.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = 21,  .depth = 0.04 },
            .{ .source = .lfo2, .dest = dP,  .depth = 0.015 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "dust" }),
        .gain = 0.25,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 12 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.25 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.65 }, .{ .idx = 1, .value = 0.55 }, .{ .idx = 2, .value = 0.2 } } },
    } },

    // --- Drum & bass / neurofunk ---
    // reese-bass - third saw widens the beat pattern, ladder filter, macro 1
    // as the DJ-style cutoff ride, macro 2 blurs the detune wider
    .{ .name = "reese-bass", .category = "bass", .tags = &.{ "wstudio", "drum-and-bass" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 16.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_semi = 0.0, .osc_b_detune_cents = 14.0, .osc_b_level = 0.9,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.6666667, .osc_c_semi = 0.0, .osc_c_detune_cents = -11.0, .osc_c_level = 0.7,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.006, .decay_s = 0.2, .sustain = 1.0, .release_s = 0.2,
        .filter_type = .ladder, .filter_cutoff = 700.0, .filter_res = 0.2, .filter_drive = 3.0,
        .lfo_rate_hz = 0.5, .lfo_sync = .n1_2, .lfo_retrig = .key,
        .sub_level = 0.3, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .lfo,  .dest = 21, .depth = 0.125 },
            .{ .source = .mac1, .dest = 21, .depth = 0.6 },
            .{ .source = .mac2, .dest = 4,  .depth = 0.3 },
        }),
        .macro_labels = macros(.{ "brightness", "growl", "", "" }),
        .gain = 1.0,
    }, .fx = &.{
        .{ .kind = .utility, .params = &.{ .{ .idx = 11, .value = 120 } } },
    } },

    // neuro-bass - wavetable osc with sample&hold timbre flicker, formant
    // filter 2 doing the vowel talk, OTT + drive on top
    .{ .name = "neuro-bass", .category = "bass", .tags = &.{ "wstudio", "neurofunk" }, .patch = .{
        .wt_table = .formant, .wt_pos = 0.65, .voice_mode = .mono, .glide_s = 0.01,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 6.0, .osc_b_level = 1.0,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 4.5,
        .attack_s = 0.004, .decay_s = 0.18, .sustain = 0.9, .release_s = 0.12,
        .filter_type = .ladder, .filter_cutoff = 550.0, .filter_res = 0.45, .filter_drive = 4.0,
        .filter2_on = true, .filter2_type = .formant, .filter2_cutoff = 400.0, .filter2_res = 0.4, .filter2_drive = 2.5, .filter_routing = .series,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.2, .fenv_release_s = 0.1,
        .lfo_rate_hz = 5.5, .lfo_sync = .n1_8t, .lfo_retrig = .key,
        .lfo_custom = waves(.{ .triangle, .sine, .sine }), .lfo_custom_count = waveCounts(.{ .triangle, .sine, .sine }),
        .lfo2_shape = .sh, .lfo2_rate_hz = 3.0, .lfo2_sync = .n1_16, .lfo2_retrig = .key, .lfo2_slew_ms = 18.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.5 },
            .{ .source = .lfo,  .dest = 47,  .depth = 0.35 },
            .{ .source = .lfo2, .dest = 185, .depth = 0.2 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 47,  .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "formant", "", "drive" }),
        .gain = 0.21,
    }, .fx = &.{
        .{ .kind = .ott, .params = &.{ .{ .idx = 0, .value = 0.6 }, .{ .idx = 3, .value = -8 } } },
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 14 }, .{ .idx = 2, .value = 0.5 } } },
    } },

    // --- Psytrance / Goa ---
    // psy-lead - diode squelch + fast triplet-ish echo
    .{ .name = "psy-lead", .category = "lead", .tags = &.{ "wstudio", "psytrance" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 3, .unison_detune = 12.0, .unison_spread = 0.5,
        .voice_mode = .mono, .glide_s = 0.03,
        .attack_s = 0.01, .decay_s = 0.25, .sustain = 0.7, .release_s = 0.2,
        .filter_type = .diode, .filter_cutoff = 1400.0, .filter_res = 0.6, .filter_drive = 3.0,
        .fenv_attack_s = 0.02, .fenv_decay_s = 0.3, .fenv_sustain = 0.4, .fenv_release_s = 0.2,
        .lfo_rate_hz = 5.0, .lfo_retrig = .key, .lfo_phase_offset = 0.25,
        // The blip every account of a psy lead starts with: a very fast pitch
        // envelope on the front of the note. A saw through a resonant diode
        // filter was the rest of the recipe already.
        .env3_attack_s = 0.001, .env3_decay_s = 0.03, .env3_sustain = 0.0, .env3_release_s = 0.03, .env3_curve = 0.8,
        .mod_matrix = mods(&.{
            .{ .source = .env3, .dest = dP, .depth = 0.12 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .fenv, .dest = 21,  .depth = 0.7 },
            .{ .source = .lfo,  .dest = dP,  .depth = 0.02 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "echo", "" }),
        .gain = 1.0,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.16 }, .{ .idx = 1, .value = 0.45 }, .{ .idx = 2, .value = 0.3 } } },
    } },

    // --- Techno / Detroit ---
    // detroit-stab - velocity-sensitive filter hit, short room tail
    .{ .name = "detroit-stab", .category = "stab", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 10.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_semi = 7.0, .osc_b_detune_cents = 6.0, .osc_b_level = 0.7,
        .attack_s = 0.008, .decay_s = 0.4, .sustain = 0.0, .release_s = 0.25, .env_curve = 0.55,
        .filter_type = .lp, .filter_cutoff = 2200.0, .filter_res = 0.2,
        .fenv_attack_s = 0.005, .fenv_decay_s = 0.35, .fenv_sustain = 0.0, .fenv_release_s = 0.2, .fenv_curve = 0.6,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.45 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.35 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "grit" }),
        .gain = 0.3,
    }, .fx = &.{
        // The chord stab this genre is named for came off an 8-bit sampler,
        // and that machine's quantisation is part of the sound - a clean saw
        // stab into a room is only half of it. Crush before the reverb, so
        // the room sits around the grit rather than under it.
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 8 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.3 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 0.5 }, .{ .idx = 2, .value = 0.18 } } },
    } },

    // techno-bass - ladder filter + drive for the warehouse thump
    .{ .name = "techno-bass", .category = "bass", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.14, .sustain = 0.0, .release_s = 0.06,
        .filter_type = .ladder, .filter_cutoff = 380.0, .filter_res = 0.3, .filter_drive = 5.0,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .sub_level = 0.5, .sub_shape = .square,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.3 },
            .{ .source = .velocity, .dest = 21, .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac4,     .dest = 249, .depth = 0.3 },
            .{ .source = .mac2, .dest = 22,  .depth = 0.25 },
        }),
        .macro_labels = macros(.{ "cutoff", "resonance", "", "drive" }),
        .gain = 1.0,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 8 }, .{ .idx = 2, .value = 0.3 } } },
    } },

    // --- House / disco / funk ---
    // organ-bass - harmonic-series unison stacks sine drawbars over the
    // square foundation; macro 2 pulls the fifth drawbar in
    .{ .name = "organ-bass", .category = "bass", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_level = 0.5,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.0, .osc_c_semi = 19.0, .osc_c_level = 0.3,
        .attack_s = 0.004, .decay_s = 0.1, .sustain = 0.9, .release_s = 0.1,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.05, .filter_drive = 2.0,
        .sub_level = 0.4, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            // Unlike the jazz organ, this one is not a tonewheel instrument
            // with switch keys - it is the workstation organ deep house took
            // from Robin S, played as stabs whose dynamics carry the groove.
            // So velocity opens it.
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 55, .depth = 0.4 },
        }),
        .macro_labels = macros(.{ "brightness", "drawbar", "", "" }),
        .gain = 0.38,
    } },

    // disco-bass - velocity accents + bus-style compression for the octave
    // bounce
    .{ .name = "disco-bass", .category = "bass", .tags = &.{ "wstudio", "disco" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.004, .decay_s = 0.16, .sustain = 0.5, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 800.0, .filter_res = 0.15,
        .fenv_attack_s = 0.002, .fenv_decay_s = 0.14, .fenv_sustain = 0.2, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.25 },
            .{ .source = .velocity, .dest = 21, .depth = 0.3 },
            .{ .source = .alternate, .dest = 21, .depth = 0.025 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.2 },
        }),
        .macro_labels = macros(.{ "brightness", "resonance", "", "" }),
        .gain = 0.29,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 1, .value = 3 }, .{ .idx = 3, .value = 100 } } },
        // Level pass: this patch measured far off its category's median
        // momentary loudness, and its own chain is nonlinear, so the trim
        // goes after it rather than into the voice gain ahead of it.
        .{ .kind = .utility, .params = &.{ .{ .idx = 0, .value = 5 } } },
    } },

    // funk-clav - the classic clav-through-phaser, velocity + keytrack
    // keep the top end percussive.
    //
    // A clavinet is a struck steel string, and the two envelopes work the
    // opposite way round from a "percussive" preset: measurements of a D6 put
    // the held string's T60 at twenty seconds and more, while releasing the
    // key drops a yarn damper that mutes it at once. So the note rings for a
    // couple of seconds under the hand and stops dead when the hand leaves -
    // not a 0.22 s decay that dies while the key is still down and a 0.12 s
    // release that hangs on after it comes up. The filter envelope keeps its
    // short decay: the highs of a struck string do leave before its
    // fundamental does.
    .{ .name = "funk-clav", .category = "keys", .tags = &.{ "wstudio", "funk" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0,
        .attack_s = 0.002, .decay_s = 2.5, .sustain = 0.0, .release_s = 0.025, .env_curve = 0.72,
        .filter_type = .bp, .filter_cutoff = 1600.0, .filter_res = 0.35,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.2, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.68,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.375 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.4 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 3, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 22,  .depth = 0.25 },
        }),
        .macro_labels = macros(.{ "brightness", "resonance", "phaser", "" }),
        .gain = 0.32,
    }, .fx = &.{
        .{ .kind = .phaser, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 0.8 }, .{ .idx = 3, .value = 0.45 } } },
    } },

    // --- Synthwave / retro 80s ---
    // synthwave-lead - ENV 3 kicks a hard-sync sweep on every attack,
    // LFO 2 supplies the vibrato, outrun delay + chorus sheen
    .{ .name = "synthwave-lead", .category = "lead", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 12.0, .unison_spread = 0.5,
        .warp_mode = .sync, .warp_amount = 0.08,
        .attack_s = 0.06, .decay_s = 0.3, .sustain = 0.8, .release_s = 0.4,
        .filter_type = .lp, .filter_cutoff = 4200.0, .filter_res = 0.1,
        // Sync makes an asymmetric wave, and an asymmetric wave carries DC:
        // measured at half this patch's own RMS, which is headroom spent on
        // nothing audible. A 20 Hz highpass removes it and nothing else.
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 20.0, .filter_routing = .series,
        .lfo2_rate_hz = 5.5, .lfo2_retrig = .key, .lfo2_phase_offset = 0.25,
        .env3_attack_s = 0.001, .env3_decay_s = 0.35, .env3_sustain = 0.0, .env3_release_s = 0.2, .env3_curve = 0.65,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .lfo2, .dest = dP,  .depth = 0.015 },
            .{ .source = .env3, .dest = 42,  .depth = 0.4 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 2 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "echo", "" }),
        .gain = 0.34,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 3.5 }, .{ .idx = 2, .value = 0.3 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.375 }, .{ .idx = 1, .value = 0.4 }, .{ .idx = 2, .value = 0.3 } } },
    } },

    // retro-brass - Juno-style chorus is the whole trick, velocity swells
    // the filter like breath pressure
    .{ .name = "retro-brass", .category = "brass", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 9.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.8,
        .attack_s = 0.08, .decay_s = 0.4, .sustain = 0.75, .release_s = 0.3, .env_curve = -0.25,
        .filter_type = .lp, .filter_cutoff = 3000.0, .filter_res = 0.12,
        // Brass brightens into the note: the filter envelope has to open
        // slower than the level rises, or the patch starts bright and dulls,
        // which is a synth attack, not a horn one. All three of these had it
        // the wrong way round.
        .fenv_attack_s = 0.13, .fenv_decay_s = 0.5, .fenv_sustain = 0.5, .fenv_release_s = 0.3,
        .lfo_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.3 },
            .{ .source = .lfo,      .dest = dP,  .depth = 0.014 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.35 },
            .{ .source = .random,   .dest = dP,  .depth = 0.004 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "chorus", "" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 1, .value = 5 }, .{ .idx = 2, .value = 0.35 } } },
    } },

    // --- Chiptune / video game ---
    // chip-lead - LFO 2 flickers the duty cycle like NES channel swaps,
    // bit-crush for the console DAC grit
    .{ .name = "chip-lead", .category = "lead", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .voice_mode = .mono, .glide_s = 0.0,
        // 25% duty, not the 50% a plain square gives: the NES melody voice is
        // a narrow pulse, and bend pivots the phase so the square flips early.
        .warp_mode = .bend, .warp_amount = 0.51,
        .attack_s = 0.001, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.02,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .lfo_rate_hz = 6.0,
        .lfo2_rate_hz = 2.0, .lfo2_sync = .n1_8, .lfo2_retrig = .key,
        .lfo_custom = waves(.{ .sine, .square, .sine }), .lfo_custom_count = waveCounts(.{ .sine, .square, .sine }),
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP, .depth = 0.03 },
            .{ .source = .lfo2, .dest = 185,  .depth = -0.12 },
            .{ .source = .alternate, .dest = 185, .depth = -0.08 },
            .{ .source = .mac2, .dest = 42,   .depth = 0.45 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 185, .depth = -0.35 },
        }),
        .macro_labels = macros(.{ "", "duty", "", "crush" }),
        .gain = 0.17,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 2, .value = 0.4 } } },
    } },

    // chip-bass - crushed hard toward the NES triangle's 4-bit staircase
    .{ .name = "chip-bass", .category = "bass", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.08, .sustain = 0.9, .release_s = 0.03,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .mod_matrix = mods(&.{
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "", "wave", "", "crush" }),
        .gain = 0.67,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 4 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.5 } } },
    } },

    // chip-arp - the built-in arpeggiator does the work now: hold a chord
    // and it rips through two octaves at 12 Hz
    .{ .name = "chip-arp", .category = "pluck", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .voice_mode = .mono, .glide_s = 0.0,
        // 12.5%, the thinnest of the four the chip offers - what an NES arp
        // uses to stay out of the way of the melody.
        .warp_mode = .bend, .warp_amount = 0.765,
        .attack_s = 0.001, .decay_s = 0.06, .sustain = 0.0, .release_s = 0.02, .env_curve = 0.8,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .arp_on = true, .arp_mode = .up, .arp_octaves = 2, .arp_rate_hz = 12.0, .arp_sync = .n1_16, .arp_gate = 0.6,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2, .dest = 42,   .depth = 0.45 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "", "duty", "", "crush" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 0.3 } } },
    } },

    // --- Ambient / downtempo ---
    // ambient-drone - dual chaos LFOs: one stirs the filter, one drifts
    // the wavetable morph; big HP'd reverb wash
    .{ .name = "ambient-drone", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .wt_table = .analog, .wt_pos = 0.25, .unison = 5, .unison_detune = 14.0, .unison_spread = 0.8,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = -12.0, .osc_b_level = 0.5,
        .attack_s = 3.0, .decay_s = 1.0, .sustain = 0.85, .release_s = 3.5, .env_curve = -0.5,
        .filter_type = .lp, .filter_cutoff = 1600.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 80.0, .filter_routing = .series,
        .lfo_shape = .chaos, .lfo_rate_hz = 0.3, .lfo_slew_ms = 90.0,
        .lfo2_shape = .chaos, .lfo2_rate_hz = 0.11, .lfo2_phase_offset = 0.31, .lfo2_slew_ms = 140.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.12 },
            .{ .source = .lfo2, .dest = 185, .depth = 0.25 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 185, .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "space", "" }),
        .gain = 0.24,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.92 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.45 } } },
    } },

    // glass-pad - velocity glints the FM depth, chorus + hall around it
    .{ .name = "glass-pad", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 19.0, .osc_b_detune_cents = 4.0, .osc_b_level = 0.6,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 1.2,
        .attack_s = 1.5, .decay_s = 1.5, .sustain = 0.6, .release_s = 2.5,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.0,
        .lfo_rate_hz = 0.3,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,      .dest = dA,  .depth = 0.05 },
            .{ .source = .velocity, .dest = 44,  .depth = 0.1 },
            .{ .source = .random,   .dest = 44,  .depth = 0.02 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.2 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "", "glass", "space", "" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.4 }, .{ .idx = 1, .value = 5 }, .{ .idx = 2, .value = 0.3 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.85 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.4 } } },
    } },

    // --- Trap ---
    // trap-808 - ENV 3 gives the 808 pitch knock (starts ~half an octave
    // sharp and drops in), drive adds the speaker-rattle harmonics
    .{ .name = "trap-808", .category = "bass", .tags = &.{ "wstudio", "trap" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.08,
        .attack_s = 0.002, .decay_s = 0.8, .sustain = 0.4, .release_s = 0.6,
        .filter_type = .lp, .filter_cutoff = 400.0, .filter_res = 0.0,
        .sub_level = 0.8, .sub_shape = .sine,
        .env3_attack_s = 0.001, .env3_decay_s = 0.05, .env3_sustain = 0.0, .env3_release_s = 0.05, .env3_curve = 0.8,
        .mod_matrix = mods(&.{
            // The knock at the front of an 808 is a pitch drop, and the amount
            // usually quoted for it is an octave or more inside 40-60 ms.
            // This was two thirds of an octave over 70 ms, which is a slide
            // into the note rather than a hit on it.
            .{ .source = .env3, .dest = dP, .depth = 1.0 },
            .{ .source = .mac1, .dest = 21, .depth = 0.3 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 34,  .depth = 0.3 },
        }),
        .macro_labels = macros(.{ "brightness", "sub", "", "drive" }),
        .gain = 0.45,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 8 }, .{ .idx = 2, .value = 0.2 } } },
    } },

    // --- Acid (open lead voicing) ---
    // acid-lead - diode ladder wide open, screamer-pedal drive, tight echo
    .{ .name = "acid-lead", .category = "lead", .tags = &.{ "wstudio", "acid" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.05,
        .attack_s = 0.001, .decay_s = 0.3, .sustain = 0.4, .release_s = 0.1,
        .filter_type = .diode, .filter_cutoff = 800.0, .filter_res = 0.82, .filter_drive = 6.0,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.28, .fenv_sustain = 0.1, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.75 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.35 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            // Same accent-into-resonance as acid-bass.
            .{ .source = .velocity, .dest = 22,  .depth = 0.12 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2,     .dest = 22,  .depth = 0.25 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "cutoff", "squelch", "echo", "drive" }),
        .gain = 0.69,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 14 }, .{ .idx = 2, .value = 0.5 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.19 }, .{ .idx = 1, .value = 0.4 } } },
    } },

    // --- Industrial / EBM ---
    // ebm-bass - chorused like every classic EBM sequence, drive up front
    .{ .name = "ebm-bass", .category = "bass", .tags = &.{ "wstudio", "ebm" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 12.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 10.0, .osc_b_level = 0.9,
        .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.18, .sustain = 0.7, .release_s = 0.1,
        .filter_type = .lp, .filter_cutoff = 750.0, .filter_res = 0.3, .filter_drive = 3.0,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.2, .fenv_release_s = 0.08,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.45 },
            .{ .source = .velocity, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "chorus", "drive" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 10 }, .{ .idx = 2, .value = 0.45 } } },
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.6 }, .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 0.25 } } },
        .{ .kind = .utility, .params = &.{ .{ .idx = 11, .value = 120 } } },
    } },

    // --- Jazz / soul ---
    // jazz-organ - harmonic-series unison stacks real drawbars, ENV 3 fakes
    // the Hammond's percussion register on the 2nd-harmonic osc; macro 2
    // pulls in the sub drawbar
    .{ .name = "jazz-organ", .category = "keys", .tags = &.{ "wstudio", "jazz" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .unison = 3, .unison_mode = .harmonic, .unison_detune = 100.0,
        // Osc B is the percussion tab, not a drawbar: on a Hammond the plink
        // is the third harmonic, it decays to nothing, and it is not part of
        // the held tone. So B sits 19 semitones up at zero level and exists
        // only for as long as env3 lifts it. It was the octave at a standing
        // 0.4, which is a drawbar the Jimmy Smith 888000000 setting does not
        // pull.
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 19.0, .osc_b_level = 0.0,
        .attack_s = 0.004, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.0,
        .lfo_rate_hz = 6.5,
        .env3_attack_s = 0.001, .env3_decay_s = 0.2, .env3_sustain = 0.0, .env3_release_s = 0.1,
        .sub_level = 0.3, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP, .depth = 0.01 },
            .{ .source = .env3, .dest = 11, .depth = 0.55 },
            .{ .source = .mac1, .dest = 21, .depth = 0.4 },
            .{ .source = .mac2, .dest = 34, .depth = 0.4 },
            // The rotor. A Hammond is never heard without a Leslie, and the
            // swirl is amplitude and pitch together - the horn coming toward
            // you and going away - so the same LFO drives level here and the
            // chorus below smears the pitch after it.
            .{ .source = .lfo,  .dest = dA, .depth = 0.18 },
            .{ .source = .mac3, .dest = 2,  .depth = 0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "drawbar", "rotor", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 4.5 }, .{ .idx = 1, .value = 5.0 }, .{ .idx = 2, .value = 0.35 } } },
    } },

    // === Round 2: fill each genre's remaining core roles ===

    // dubstep - the talking growl finally talks: a real formant filter
    // scanned by the LFO, lowpassed in series to keep it bass; macro 1 is
    // the vowel, not a plain cutoff, on this one
    .{ .name = "growl-bass", .category = "bass", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.01,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.8,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 3.5,
        .attack_s = 0.004, .decay_s = 0.15, .sustain = 1.0, .release_s = 0.12,
        .filter_type = .formant, .filter_cutoff = 300.0, .filter_res = 0.45,
        .filter2_on = true, .filter2_type = .lp, .filter2_cutoff = 2500.0, .filter2_res = 0.2, .filter_routing = .series,
        // .custom, not .square: a square just flips between two vowel
        // extremes on/off, it doesn't "talk". Dwelling briefly at each
        // vowel with a quick transition between (not an instant flip)
        // reads as actual formant speech instead of a switch.
        .lfo_shape = .drawn, .lfo_rate_hz = 6.0, .lfo_sync = .n1_8, .lfo_retrig = .key,
        .lfo_custom = .{
            lfoPoints(&.{
                .{ .phase = 0.0,  .value = -1.0 },
                .{ .phase = 0.15, .value = -1.0 },
                .{ .phase = 0.25, .value = 1.0 },
                .{ .phase = 0.55, .value = 1.0 },
                .{ .phase = 0.7,  .value = -1.0 },
                .{ .phase = 1.0,  .value = -1.0 },
            }),
            lfoPoints(&.{}),
            lfoPoints(&.{}),
        },
        .lfo_custom_count = .{ 6, 0, 0 },
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21, .depth = 0.4 },
            .{ .source = .mac1, .dest = 21, .depth = 0.5 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 44,  .depth = 0.3 },
        }),
        .macro_labels = macros(.{ "vowel", "fm depth", "", "drive" }),
        .gain = 0.18,
    }, .fx = &.{
        .{ .kind = .ott, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 3, .value = -8 } } },
        .{ .kind = .sat, .params = &.{ .{ .idx = 2, .value = 0.5 } } },
    } },

    // hip-hop - the whiny G-funk portamento lead. "The whine" is a slow-
    // opening filter envelope at shallow depth, not vibrato (a reconstructed
    // Dre-era patch has zero pitch-LFO on it); two tight-detuned saws stand
    // in for the real patch's +1/-1 cent pair
    .{ .name = "gfunk-lead", .category = "lead", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 6.0, .unison_spread = 0.4, .detune_cents = -1.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_semi = 0.0, .osc_b_detune_cents = 1.0, .osc_b_level = 0.9,
        // The genre's definition of this lead is "high-pitched portamento":
        // the slide between notes is the sound, and 10 ms is not a slide.
        .voice_mode = .legato, .glide_s = 0.07,
        .attack_s = 0.001, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.02,
        .filter_type = .ladder, .filter_cutoff = 3400.0, .filter_res = 0.15, .filter_drive = 2.0,
        .fenv_attack_s = 2.15, .fenv_decay_s = 0.3, .fenv_sustain = 1.0, .fenv_release_s = 0.2,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .fenv, .dest = 21,  .depth = 0.1 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "echo", "" }),
        .gain = 0.29,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.28 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.2 } } },
    } },

    // neurofunk - screechy resonant FM lead; a small upward frequency shift
    // smears the partials inharmonic for the metallic edge
    .{ .name = "neuro-screech", .category = "lead", .tags = &.{ "wstudio", "neurofunk" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 16.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 12.0, .osc_b_level = 0.7,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 2.5,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.005, .decay_s = 0.25, .sustain = 0.6, .release_s = 0.15,
        .filter_type = .diode, .filter_cutoff = 1800.0, .filter_res = 0.6, .filter_drive = 4.5,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.3, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .lfo_rate_hz = 4.0, .lfo_sync = .n1_16, .lfo_retrig = .key,
        .lfo_custom = waves(.{ .triangle, .sine, .sine }), .lfo_custom_count = waveCounts(.{ .triangle, .sine, .sine }),
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.625 },
            .{ .source = .lfo,  .dest = 21,  .depth = 0.15 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 0, .depth = 0.05, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "metal", "", "drive" }),
        .gain = 0.50,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 2, .value = 0.5 } } },
        .{ .kind = .freq_shift, .params = &.{ .{ .idx = 0, .value = 30 }, .{ .idx = 1, .value = 0.3 } } },
    } },

    // techno - dark hypnotic pluck swimming in dub-techno echo
    .{ .name = "techno-pluck", .category = "pluck", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.14, .sustain = 0.0, .release_s = 0.08, .env_curve = 0.7,
        .filter_type = .lp, .filter_cutoff = 1000.0, .filter_res = 0.3,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.06,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.375 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 22,  .depth = 0.25 },
        }),
        .macro_labels = macros(.{ "brightness", "resonance", "echo", "" }),
        .gain = 0.27,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.375 }, .{ .idx = 1, .value = 0.55 }, .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 0.6 }, .{ .idx = 2, .value = 0.25 } } },
    } },

    // deep-house - warm electric-piano-ish chord
    .{ .name = "deep-chord", .category = "pad", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .unison = 2, .unison_detune = 6.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_detune_cents = 3.0, .osc_b_level = 0.5,
        .attack_s = 0.02, .decay_s = 0.5, .sustain = 0.7, .release_s = 0.6,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.08,
        .lfo_rate_hz = 0.4,
        .mod_matrix = mods(&.{
            .{ .source = .random, .dest = dP,  .depth = 0.0035 },
            .{ .source = .lfo,      .dest = 21,  .depth = 0.04 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "chorus", "" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.6 }, .{ .idx = 2, .value = 0.35 } } },
    } },

    // disco - Solina-style ensemble strings; the chorus is the ensemble.
    //
    // A string machine is a divide-down organ: every note comes off one
    // master oscillator through a chain of dividers, so no two keys can beat
    // against each other and there is nothing to detune. Six unison voices
    // 14 cents apart was a supersaw wearing the name. All of the movement in
    // the real instrument comes from the ensemble after it - three bucket-
    // brigade lines mixed against the dry signal, each on its own free-running
    // LFO, one slow and one fast - and it is deliberately set so you hear the
    // width without hearing the LFOs as vibrato. So: one voice, no detune, no
    // pitch LFO, and two chorus stages standing in for the BBD bank.
    .{ .name = "disco-strings", .category = "pad", .tags = &.{ "wstudio", "disco" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667,
        .attack_s = 0.15, .decay_s = 0.5, .sustain = 0.85, .release_s = 0.7,
        .filter_type = .lp, .filter_cutoff = 4000.0, .filter_res = 0.05,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 200.0, .filter_routing = .series,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 1, .depth = 0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "ensemble", "chorus", "" }),
        .gain = 0.36,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.9 }, .{ .idx = 1, .value = 6 } } },
        // The fast line. The real one runs near 6 Hz; the FX clamps at 5.
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 5.0 }, .{ .idx = 1, .value = 1.5 }, .{ .idx = 2, .value = 0.35 } } },
    } },

    // funk - P-funk mono synth lead; ENV 3 snaps a hard-sync sweep on each
    // note for the squelchy attack
    .{ .name = "funk-lead", .category = "lead", .tags = &.{ "wstudio", "funk" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.04,
        .warp_mode = .sync, .warp_amount = 0.1,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 6.0, .osc_b_level = 0.6,
        .attack_s = 0.008, .decay_s = 0.25, .sustain = 0.7, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 1800.0, .filter_res = 0.4, .filter_drive = 3.2,
        // Same sync-borne DC as synthwave-lead, same 20 Hz cure.
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 20.0, .filter_routing = .series,
        .fenv_attack_s = 0.005, .fenv_decay_s = 0.3, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .lfo_rate_hz = 5.0,
        .env3_attack_s = 0.001, .env3_decay_s = 0.25, .env3_sustain = 0.0, .env3_release_s = 0.15,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .fenv, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = dP,  .depth = 0.018 },
            .{ .source = .env3, .dest = 42,  .depth = 0.35 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2, .dest = 42,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 3, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "sync", "sweep", "" }),
        .gain = 0.72,
    }, .fx = &.{
        .{ .kind = .phaser, .params = &.{ .{ .idx = 1, .value = 0.8 }, .{ .idx = 2, .value = 0.45 }, .{ .idx = 3, .value = 0.35 } } },
    } },

    // dub - reedy melodica with vibrato, sunk into King Tubby tape echo
    .{ .name = "melodica", .category = "keys", .tags = &.{ "wstudio", "dub", "reggae" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .voice_mode = .mono, .glide_s = 0.0,
        .noise_level = 0.05, .noise_color = 0.7,
        .attack_s = 0.03, .decay_s = 0.2, .sustain = 0.7, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.1,
        .lfo_rate_hz = 5.5, .lfo_retrig = .key, .lfo_phase_offset = 0.25,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = dP,  .depth = 0.022 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 185, .depth = -0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "echo", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.33 }, .{ .idx = 1, .value = 0.55 }, .{ .idx = 2, .value = 0.35 } } },
    } },

    // synthwave - driving outrun bass; LFO 2 breathes the B-osc duty cycle
    .{ .name = "outrun-bass", .category = "bass", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.6,
        .attack_s = 0.003, .decay_s = 0.18, .sustain = 0.8, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.15,
        .lfo2_rate_hz = 0.4, .lfo2_sync = .n1_1, .lfo2_retrig = .key,
        .sub_level = 0.5, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .lfo2,     .dest = 186,  .depth = -0.15 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 186,  .depth = -0.2 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "chorus", "" }),
        .gain = 0.27,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 0.3 } } },
        .{ .kind = .utility, .params = &.{ .{ .idx = 0, .value = 4 }, .{ .idx = 11, .value = 120 } } },
    } },

    // chiptune - square pad with basic-waveform motion and light crush
    .{ .name = "chip-pad", .category = "pad", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .unison = 2, .unison_detune = 8.0,
        // Starts at a plain 50% square - a pad wants the body - but the mode
        // has to be on for the duty macro to have anything to move.
        .warp_mode = .bend, .warp_amount = 0.0,
        .attack_s = 0.3, .decay_s = 0.4, .sustain = 0.8, .release_s = 0.5,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .lfo_rate_hz = 3.0,
        .lfo_custom = waves(.{ .triangle, .sine, .sine }), .lfo_custom_count = waveCounts(.{ .triangle, .sine, .sine }),
        .lfo2_rate_hz = 0.5, .lfo2_sync = .n1_2, .lfo2_retrig = .key,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = dP, .depth = 0.02 },
            .{ .source = .lfo2, .dest = 185,  .depth = -0.25 },
            .{ .source = .mac2, .dest = 42,  .depth = 0.45 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "", "duty", "", "crush" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 0.2 } } },
        // Level pass: this patch measured far off its category's median
        // momentary loudness, and its own chain is nonlinear, so the trim
        // goes after it rather than into the voice gain ahead of it.
        .{ .kind = .utility, .params = &.{ .{ .idx = 0, .value = -8 } } },
    } },

    // ambient - the choir finally has vocal cords: a real formant filter
    // parked in the a/e region, slow LFO drifting the vowel, huge hall;
    // macro 1 scans vowels here rather than opening a cutoff
    // Singers in unison are measured 25-30 cents apart (Jers & Ternström), and
    // no two of them drift together - which is the whole reason a choir sounds
    // unlike four synth voices at a fixed 10-cent detune. So: the spread goes
    // up to the measured figure, and `random` scatters each note's pitch by up
    // to a quarter tone on its own, per voice, so repeated notes never stack.
    .{ .name = "choir-pad", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 4, .unison_detune = 27.0, .unison_spread = 0.6,
        .noise_level = 0.04, .noise_color = 0.6,
        .attack_s = 1.0, .decay_s = 1.0, .sustain = 0.8, .release_s = 2.0, .env_curve = -0.35,
        .filter_type = .formant, .filter_cutoff = 80.0, .filter_res = 0.3,
        .lfo_rate_hz = 0.2, .lfo_slew_ms = 45.0,
        .mod_matrix = mods(&.{
            .{ .source = .random, .dest = dP, .depth = 0.02 },
            .{ .source = .lfo,  .dest = 21,  .depth = 0.15 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "vowel", "detune", "space", "" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 5 }, .{ .idx = 2, .value = 0.3 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.88 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.4 } } },
    } },

    // rave - Mentasm-style hoover stab. The Alpha Juno patch it comes from is
    // three things at once: a saw, a pulse whose width an LFO sweeps, and a
    // sub an octave down, with a pitch envelope diving into every note and a
    // fast chorus swarming the result. Osc B is the pulse, so the LFO rides
    // its bend (dest 44 = the phase pivot, which on a square IS pulse width);
    // env3 is the dive; the chorus replaced a phaser that no account of this
    // sound mentions.
    .{ .name = "rave-stab", .category = "stab", .tags = &.{ "wstudio", "rave" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 3, .unison_detune = 18.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 14.0, .osc_b_level = 0.8,
        .osc_b_warp_mode = .bend, .osc_b_warp_amount = 0.45,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.6666667, .osc_c_semi = -12.0, .osc_c_level = 0.5,
        .attack_s = 0.006, .decay_s = 0.3, .sustain = 0.0, .release_s = 0.2, .env_curve = 0.62,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.25,
        // A swept pulse is asymmetric, and an asymmetric wave carries DC -
        // measured at a third of this patch's own RMS before the highpass.
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 20.0, .filter_routing = .series,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.28, .fenv_sustain = 0.0, .fenv_release_s = 0.15, .fenv_curve = 0.55,
        .env3_attack_s = 0.001, .env3_decay_s = 0.14, .env3_sustain = 0.0, .env3_release_s = 0.05, .env3_curve = 0.7,
        .lfo_rate_hz = 5.5,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.375 },
            .{ .source = .env3, .dest = dP,  .depth = 0.3 },
            .{ .source = .lfo,  .dest = 44,  .depth = 0.03 },
            .{ .source = .velocity, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "chorus", "drive" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 9 }, .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 1.1 }, .{ .idx = 1, .value = 5.5 }, .{ .idx = 2, .value = 0.45 } } },
    } },

    // ebm - ratio-mode unison turns the lead into a fifths power-chord
    // stack, driven and echoed
    .{ .name = "ebm-lead", .category = "lead", .tags = &.{ "wstudio", "ebm" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 3, .unison_mode = .ratio, .unison_detune = 100.0, .unison_spread = 0.5,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_semi = -12.0, .osc_b_level = 0.6,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.005, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 2000.0, .filter_res = 0.35, .filter_drive = 3.5,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.25, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.4 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2, .dest = 4,   .depth = -0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "echo", "drive" }),
        .gain = 0.12,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 11 }, .{ .idx = 2, .value = 0.4 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.2 } } },
    } },

    // jazz - breathy sine flute; blowing harder (velocity) adds breath noise
    .{ .name = "jazz-flute", .category = "lead", .tags = &.{ "wstudio", "jazz" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.02,
        .noise_level = 0.06, .noise_color = 0.8,
        .attack_s = 0.05, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 4000.0, .filter_res = 0.05,
        .lfo_rate_hz = 5.0,
        // The chiff: a flute is breathiest at the instant the air hits the
        // edge, not evenly across the note. Env3 puts a burst of noise on
        // the onset over the standing breath level.
        .env3_attack_s = 0.004, .env3_decay_s = 0.09, .env3_sustain = 0.0, .env3_release_s = 0.05, .env3_curve = 0.7,
        .mod_matrix = mods(&.{
            .{ .source = .env3,     .dest = 36,  .depth = 0.18 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,      .dest = dP,  .depth = 0.006 },
            // A flautist vibrates the air, not the tube: the pitch barely
            // moves and the level does. This was all pitch.
            .{ .source = .lfo,      .dest = dA,  .depth = 0.14 },
            .{ .source = .velocity, .dest = 36,  .depth = 0.15 },
            .{ .source = .random,   .dest = 36,  .depth = 0.04 },
            .{ .source = .mac2,     .dest = 36,  .depth = 0.2 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "", "breath", "space", "" }),
        .gain = 0.27,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.6 }, .{ .idx = 1, .value = 0.4 }, .{ .idx = 2, .value = 0.25 } } },
    } },

    // === Round 3: Japanese genres + 90s hip-hop deep dive ===

    // city-pop - glassy FM tine e-piano (the 3:1-ratio DX-style keys under
    // every late-night Tokyo track); the real DX7 EP1 patch's signature is
    // its 14:1 modulator ratio decaying fast on its OWN envelope (bright
    // attack, dull sustain) - fenv->MOD AMT reproduces that per-operator
    // envelope-over-FM-index trick; osc C adds a plain additive body layer
    // under the FM pair
    // The bell attack this patch is named after comes, on the machine that
    // made it famous, from a modulator at 14:1 whose envelope dies almost at
    // once - a tine ping over a body that is nearly a sine. Two things were
    // missing: the ratio sat at 3:1, and the index barely moved, so the ping
    // was a steady partial instead of a transient. The modulator now sits as
    // high as OSC B goes (+24 semitones is a hard 4:1 ceiling, so 14:1 is out
    // of reach) and 40 cents off it, and its index is mostly the filter
    // envelope: loud for 180 ms, then gone.
    .{ .name = "fm-epiano", .category = "keys", .tags = &.{ "wstudio", "city-pop" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 24.0, .osc_b_detune_cents = 40.0, .osc_b_level = 0.8,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.0, .osc_c_semi = 0.0, .osc_c_level = 0.3,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 0.25,
        .attack_s = 0.001, .decay_s = 1.2, .sustain = 0.15, .release_s = 0.5, .env_curve = 0.58,
        .filter_type = .lp, .filter_cutoff = 6500.0, .filter_res = 0.0,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.18, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.7,
        .lfo_rate_hz = 4.5,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 44,  .depth = 0.4 },
            .{ .source = .lfo,      .dest = dA,  .depth = 0.04 },
            .{ .source = .velocity, .dest = 44,  .depth = 0.2 },
            .{ .source = .random,   .dest = 44,  .depth = 0.015 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.25 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "", "tine", "chorus", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 1, .value = 4.5 }, .{ .idx = 2, .value = 0.4 } } },
    } },

    // city-pop - round funky FM knock bass, velocity-aware like a slapped
    // string, compressed tight
    .{ .name = "citypop-bass", .category = "bass", .tags = &.{ "wstudio", "city-pop" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_level = 0.9,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 1.6,
        .attack_s = 0.002, .decay_s = 0.25, .sustain = 0.35, .release_s = 0.1, .env_curve = 0.48,
        .filter_type = .lp, .filter_cutoff = 1100.0, .filter_res = 0.1,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.06, .fenv_curve = 0.62,
        .sub_level = 0.3, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.3 },
            .{ .source = .velocity, .dest = 44, .depth = 0.12 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 44, .depth = 0.2 },
        }),
        .macro_labels = macros(.{ "brightness", "tine", "", "" }),
        .gain = 0.43,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 2, .value = 8 }, .{ .idx = 3, .value = 90 } } },
    } },

    // technopop - tight sequencer-locked analog bass
    .{ .name = "technopop-bass", .category = "bass", .tags = &.{ "wstudio", "technopop" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.09, .sustain = 0.2, .release_s = 0.05,
        .filter_type = .lp, .filter_cutoff = 750.0, .filter_res = 0.25,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.08, .fenv_sustain = 0.0, .fenv_release_s = 0.04, .fenv_curve = 0.72,
        .sub_level = 0.3, .sub_shape = .square,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.35 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .alternate, .dest = 21, .depth = 0.02 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.2 },
        }),
        .macro_labels = macros(.{ "brightness", "resonance", "", "" }),
        .gain = 0.25,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 0, .value = -16 }, .{ .idx = 2, .value = 5 }, .{ .idx = 3, .value = 60 } } },
        // Level pass: this patch measured far off its category's median
        // momentary loudness, and its own chain is nonlinear, so the trim
        // goes after it rather than into the voice gain ahead of it.
        .{ .kind = .utility, .params = &.{ .{ .idx = 0, .value = 5 } } },
    } },

    // eurobeat - bright punchy unison lead, HP'd above 150Hz JP-8000-style
    // so it doesn't fight the bass, top end lifted, echo behind
    .{ .name = "eurobeat-lead", .category = "lead", .tags = &.{ "wstudio", "eurobeat" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 4, .unison_detune = 14.0, .unison_spread = 0.6,
        .attack_s = 0.004, .decay_s = 0.15, .sustain = 0.85, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 150.0, .filter_routing = .series,
        .lfo_rate_hz = 5.5, .lfo_retrig = .key, .lfo_phase_offset = 0.25,
        // The trumpet-like front the genre puts on its brass lead: a pitch
        // envelope with a very fast decay. Nothing else here starts the note
        // anywhere but on it.
        .env3_attack_s = 0.001, .env3_decay_s = 0.025, .env3_sustain = 0.0, .env3_release_s = 0.03, .env3_curve = 0.8,
        .mod_matrix = mods(&.{
            .{ .source = .env3,     .dest = dP,  .depth = 0.2 },
            .{ .source = .lfo,      .dest = dP,  .depth = 0.015 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 2 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "echo", "" }),
        .gain = 0.39,
    }, .fx = &.{
        .{ .kind = .eq, .params = &.{ .{ .idx = 0, .value = 3 }, .{ .idx = 1, .value = 150 }, .{ .idx = 10, .value = 1000 }, .{ .idx = 18, .value = 4 }, .{ .idx = 19, .value = 6000 }, .{ .idx = 21, .value = 3 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 1, .value = 0.3 } } },
    } },

    // anime - twangy koto-style pluck; the comb filter is the string body
    // now, keytracked so the resonance follows the note; macro 2 lengthens
    // the string ring via comb feedback
    .{ .name = "koto-pluck", .category = "pluck", .tags = &.{ "wstudio", "anime" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333,
        .noise_level = 0.1, .noise_color = 0.3,
        .attack_s = 0.001, .decay_s = 0.4, .sustain = 0.0, .release_s = 0.15, .env_curve = 0.76,
        .filter_type = .comb, .filter_cutoff = 800.0, .filter_res = 0.55,
        .filter2_on = true, .filter2_type = .lp, .filter2_cutoff = 3500.0, .filter2_res = 0.1, .filter_routing = .series,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.08, .fenv_sustain = 0.0, .fenv_release_s = 0.05, .fenv_curve = 0.72,
        .mod_matrix = mods(&.{
            // Oshide: the player presses the string left of the bridge after
            // plucking, bending the note up by a half or whole step. That is a
            // gesture, not a setting, so it belongs on the wheel - a whole
            // step at the top of its travel.
            .{ .source = .wheel, .dest = dP, .depth = 0.1667 },
            .{ .source = .keytrack, .dest = 21, .depth = 1.0 },
            // The comb (the string body) already follows the note; the lowpass
            // after it did not, so the patch measured DARKER as it was played
            // up, which is backwards for a plucked string.
            .{ .source = .keytrack, .dest = 47, .depth = 0.7 },
            .{ .source = .fenv,     .dest = 47, .depth = 0.5 },
            .{ .source = .velocity, .dest = 36, .depth = 0.1 },
            .{ .source = .mac1,     .dest = 47, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.3 },
        }),
        .macro_labels = macros(.{ "body", "resonance", "", "" }),
        .gain = 0.32,
    } },

    // g-funk - the high sine whistle lead riding over everything
    .{ .name = "whistle-lead", .category = "lead", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.05,
        .attack_s = 0.02, .decay_s = 0.2, .sustain = 0.9, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 12_000.0, .filter_res = 0.0,
        .lfo_rate_hz = 5.2, .lfo_retrig = .key, .lfo_phase_offset = 0.25,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.028 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2, .dest = 185, .depth = 0.4 },
        }),
        .macro_labels = macros(.{ "", "wave", "space", "" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.2 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.65 }, .{ .idx = 1, .value = 0.4 }, .{ .idx = 2, .value = 0.25 } } },
    } },

    // g-funk - the squelchy resonant portamento worm; ladder filter for the
    // Moog squelch, macro 1 is the wah pedal
    .{ .name = "funky-worm", .category = "lead", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        // Every account of this line - an ARP Pro Soloist, later chased with
        // a Minimoog - describes the same simple thing: a sawtooth, glide,
        // and a filter kept low enough to leave a whine rather than a buzz.
        // It was a triangle, which is the whistle sound one preset over.
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.1,
        .attack_s = 0.005, .decay_s = 0.3, .sustain = 0.7, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 1200.0, .filter_res = 0.55, .filter_drive = 3.0,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.25, .fenv_sustain = 0.4, .fenv_release_s = 0.12,
        .lfo2_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21, .depth = 0.45 },
            .{ .source = .fenv, .dest = 21, .depth = 0.3 },
            .{ .source = .lfo2, .dest = dP, .depth = 0.02 },
            .{ .source = .mac1, .dest = 21, .depth = 0.7 },
            .{ .source = .mac2, .dest = 22, .depth = 0.3 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "cutoff", "squeal", "", "" }),
        .gain = 0.62,
    } },

    // g-funk - deep gliding Moog-style low end, now on the actual ladder
    .{ .name = "gfunk-bass", .category = "bass", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.03,
        .attack_s = 0.004, .decay_s = 0.3, .sustain = 0.6, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 480.0, .filter_res = 0.1, .filter_drive = 2.2,
        .sub_level = 0.6, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.2 },
        }),
        .macro_labels = macros(.{ "cutoff", "squelch", "", "" }),
        .gain = 0.95,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 0, .value = -20 }, .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 12 }, .{ .idx = 3, .value = 110 } } },
    } },

    // g-funk - dark cinematic string layer, ensemble drift from LFO 2
    .{ .name = "westcoast-strings", .category = "pad", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 4, .unison_detune = 10.0, .unison_spread = 0.5,
        .attack_s = 0.05, .decay_s = 0.4, .sustain = 0.6, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 2800.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 150.0, .filter_routing = .series,
        .fenv_attack_s = 0.04, .fenv_decay_s = 0.5, .fenv_sustain = 0.4, .fenv_release_s = 0.3,
        .lfo2_rate_hz = 0.5, .lfo2_phase_offset = 0.25, .lfo2_slew_ms = 25.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .fenv, .dest = 21,  .depth = 0.2 },
            .{ .source = .lfo2, .dest = dP,  .depth = 0.02 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.6 }, .{ .idx = 1, .value = 5 }, .{ .idx = 2, .value = 0.4 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 0.5 } } },
    } },

    // boom-bap - grimy dark minor keys (the QB dungeon-piano sound), put
    // through the sampler: crushed and darkened
    .{ .name = "grimy-keys", .category = "keys", .tags = &.{ "wstudio", "hip-hop", "boom-bap" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .detune_cents = -4.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_level = 0.4,
        .noise_level = 0.03, .noise_color = 0.4,
        .attack_s = 0.002, .decay_s = 0.9, .sustain = 0.1, .release_s = 0.4, .env_curve = 0.55,
        .filter_type = .lp, .filter_cutoff = 2200.0, .filter_res = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "space", "dust" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 11 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.3 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.6 }, .{ .idx = 1, .value = 0.7 }, .{ .idx = 2, .value = 0.25 } } },
    } },

    // boom-bap - warped out-of-tune bell (dusty 36-chambers tape flavor:
    // the detuned FM partial beats against the carrier), crushed to the
    // actual measured SP-1200 spec (12-bit, ~26kHz -> downsample 2 at 48k)
    // rather than a generic heavy crush
    // A struck bell is not a harmonic instrument: its partials sit at 0.5,
    // 1, 1.2, 1.5, 2 of the note (hum, prime, tierce, quint, nominal), and
    // the tierce - a MINOR third over the prime, not a major one - is the
    // interval that makes a bell sound like a bell rather than a chime. So
    // osc C carries the tierce, and the modulator comes off its integer 4:1
    // (which could only ever make harmonics) onto the 3.5 every FM bell
    // recipe reaches for.
    .{ .name = "shaolin-bell", .category = "keys", .tags = &.{ "wstudio", "hip-hop", "boom-bap" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 21.0, .osc_b_detune_cents = 69.0, .osc_b_level = 0.7,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 2.8,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.0, .osc_c_semi = 3.0, .osc_c_level = 0.3,
        .attack_s = 0.001, .decay_s = 1.0, .sustain = 0.0, .release_s = 0.8, .env_curve = 0.7,
        .filter_type = .lp, .filter_cutoff = 5000.0, .filter_res = 0.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 44, .depth = 0.12 },
            .{ .source = .random,   .dest = 44,  .depth = 0.025 },
            .{ .source = .mac2,     .dest = 44, .depth = 0.25 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "", "bell", "space", "crush" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 12 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 0.6 } } },
    } },

    // hip-hop - creepy detuned horror-movie organ (late-90s shock-rap
    // production staple); chaos LFO drifts the pitch just enough to unsettle
    .{ .name = "creep-keys", .category = "keys", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .detune_cents = 5.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 12.0, .osc_b_detune_cents = -8.0, .osc_b_level = 0.5,
        .attack_s = 0.01, .decay_s = 0.2, .sustain = 0.9, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 1500.0, .filter_res = 0.1,
        .lfo_rate_hz = 5.0,
        .lfo2_shape = .chaos, .lfo2_rate_hz = 0.15, .lfo2_slew_ms = 80.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .lfo,  .dest = dA,  .depth = 0.05 },
            .{ .source = .lfo2, .dest = dP,  .depth = 0.02 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 185, .depth = -0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "space", "" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.75 }, .{ .idx = 1, .value = 0.6 }, .{ .idx = 2, .value = 0.35 } } },
    } },

    // hardstyle - the real technique is a formant filter vowel-scan, not a
    // resonant bandpass: heavy 7-voice unison into `.formant` with the LFO
    // sweeping cutoff a->e->i->o for the "talking" shriek, EQ bump at the
    // 500-1kHz growl band ahead of the clip stage, HP'd clean at the tail
    .{ .name = "screech-lead", .category = "lead", .tags = &.{ "wstudio", "hardstyle", "hardcore" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 7, .unison_detune = 32.0, .unison_spread = 0.75,
        .voice_mode = .mono, .glide_s = 0.03,
        .attack_s = 0.004, .decay_s = 0.2, .sustain = 0.55, .release_s = 0.12,
        .filter_type = .formant, .filter_cutoff = 300.0, .filter_res = 0.55,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 200.0, .filter_routing = .series,
        .fenv_attack_s = 0.01, .fenv_decay_s = 0.15, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        // .custom, not .sine: the comment above promises a directional
        // a->e->i->o sweep, but a sine only swings back and forth between
        // two extremes - it can never visit 4 distinct vowel positions in
        // sequence. Four dwell plateaus (a/e/i/o) with quick ramps between
        // actually implements what was already being claimed; the hard
        // snap back to `a` at the phase wrap is the classic aggressive
        // "reset" zap this genre wants, not a bug.
        .lfo_shape = .drawn, .lfo_rate_hz = 3.5, .lfo_sync = .n1_8, .lfo_retrig = .key,
        .lfo_custom = .{
            lfoPoints(&.{
                .{ .phase = 0.0,  .value = -1.0 },
                .{ .phase = 0.2,  .value = -1.0 },
                .{ .phase = 0.25, .value = -0.33 },
                .{ .phase = 0.45, .value = -0.33 },
                .{ .phase = 0.5,  .value = 0.33 },
                .{ .phase = 0.7,  .value = 0.33 },
                .{ .phase = 0.75, .value = 1.0 },
                .{ .phase = 1.0,  .value = 1.0 },
            }),
            lfoPoints(&.{}),
            lfoPoints(&.{}),
        },
        .lfo_custom_count = .{ 8, 0, 0 },
        // The pitch slope a screech is built on. Env3 was unused and the
        // note started flat, which leaves the vowel scan doing all the work.
        .env3_attack_s = 0.001, .env3_decay_s = 0.08, .env3_sustain = 0.0, .env3_release_s = 0.05, .env3_curve = 0.7,
        .mod_matrix = mods(&.{
            .{ .source = .env3, .dest = dP, .depth = 0.25 },
            .{ .source = .lfo,  .dest = 21, .depth = 1.0 },
            .{ .source = .fenv, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1, .dest = 21, .depth = 0.4 },
            .{ .source = .mac2, .dest = 22, .depth = 0.2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 3 },
        }),
        .macro_labels = macros(.{ "vowel", "scream", "echo", "drive" }),
        .gain = 0.06,
    }, .fx = &.{
        .{ .kind = .eq, .params = &.{ .{ .idx = 0, .value = 3 }, .{ .idx = 1, .value = 150 }, .{ .idx = 10, .value = 750 }, .{ .idx = 11, .value = 1 }, .{ .idx = 12, .value = 4 }, .{ .idx = 18, .value = 4 }, .{ .idx = 19, .value = 6000 } } },
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 18 }, .{ .idx = 2, .value = 0.7 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.19 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.2 } } },
        // Level pass: this patch measured far off its category's median
        // momentary loudness, and its own chain is nonlinear, so the trim
        // goes after it rather than into the voice gain ahead of it.
        .{ .kind = .utility, .params = &.{ .{ .idx = 0, .value = -7 } } },
    } },

    // speedcore/terrorcore - FM-driven harsh bass, square carrier torn up by
    // audio-rate sine FM plus mirror-warp foldback; crush + drive finish it
    .{ .name = "distort-bass", .category = "bass", .tags = &.{ "wstudio", "speedcore", "terrorcore" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .voice_mode = .mono, .glide_s = 0.0,
        .warp_mode = .mirror, .warp_amount = 0.35,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 0.0, .osc_b_level = 1.0,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 6.5,
        .attack_s = 0.001, .decay_s = 0.08, .sustain = 0.9, .release_s = 0.05,
        .filter_type = .lp, .filter_cutoff = 1600.0, .filter_res = 0.35, .filter_drive = 5.0,
        .sub_level = 0.4, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .mac1, .dest = 21, .depth = 0.4 },
            .{ .source = .mac2, .dest = 42, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "warp", "", "destroy" }),
        .gain = 0.11,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 20 }, .{ .idx = 2, .value = 0.7 } } },
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 6 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.3 } } },
        // Level pass: this patch measured far off its category's median
        // momentary loudness, and its own chain is nonlinear, so the trim
        // goes after it rather than into the voice gain ahead of it.
        .{ .kind = .utility, .params = &.{ .{ .idx = 0, .value = -7 } } },
    } },

    // happy hardcore/j-core - bright FM bell-piano stab for euphoric build
    // hits, OTT'd bright with a short hall
    .{ .name = "happy-piano", .category = "keys", .tags = &.{ "wstudio", "happy-hardcore", "j-core" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_detune_cents = 5.0,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 2.2,
        .attack_s = 0.001, .decay_s = 0.5, .sustain = 0.05, .release_s = 0.35, .env_curve = 0.7,
        .filter_type = .lp, .filter_cutoff = 9000.0, .filter_res = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 44,  .depth = 0.15 },
            .{ .source = .random,   .dest = 44,  .depth = 0.018 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.25 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "", "tine", "space", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .ott, .params = &.{ .{ .idx = 0, .value = 0.4 }, .{ .idx = 3, .value = -6 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.6 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.22 } } },
        // Level pass: this patch measured far off its category's median
        // momentary loudness, and its own chain is nonlinear, so the trim
        // goes after it rather than into the voice gain ahead of it.
        .{ .kind = .utility, .params = &.{ .{ .idx = 0, .value = 5 } } },
    } },

    // === Round 4: reinforce the least-covered genres ===

    // dnb: a short minor-chord rave hit with velocity bite and wide room
    .{ .name = "dnb-stab", .category = "stab", .tags = &.{ "wstudio", "drum-and-bass", "jungle" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 3, .unison_detune = 12.0, .unison_spread = 0.55,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 3.0, .osc_b_level = 0.55,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.6666667, .osc_c_semi = 7.0, .osc_c_level = 0.45,
        .attack_s = 0.003, .decay_s = 0.22, .sustain = 0.05, .release_s = 0.18, .env_curve = 0.58,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.18,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.18, .fenv_sustain = 0.0, .fenv_release_s = 0.12, .fenv_curve = 0.6,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.45 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.25, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "drive" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 7 }, .{ .idx = 2, .value = 0.12 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.55 }, .{ .idx = 1, .value = 0.5 }, .{ .idx = 2, .value = 0.16 } } },
    } },

    // dnb: airy sampled-choir color for breakdowns and liquid intros
    .{ .name = "jungle-atmos", .category = "pad", .tags = &.{ "wstudio", "drum-and-bass", "jungle" }, .patch = .{
        .wt_table = .analog, .wt_pos = 0.7, .unison = 4, .unison_detune = 9.0, .unison_spread = 0.75,
        .noise_level = 0.08, .noise_color = 0.65,
        .attack_s = 1.1, .decay_s = 0.8, .sustain = 0.75, .release_s = 2.2,
        .filter_type = .formant, .filter_cutoff = 520.0, .filter_res = 0.18,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 170.0, .filter_routing = .series,
        .lfo_rate_hz = 0.17, .lfo_slew_ms = 65.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 185, .depth = 0.12 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2, .dest = 185, .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "vowel", "wave", "space", "" }),
        .gain = 0.24,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.35 }, .{ .idx = 1, .value = 5 }, .{ .idx = 2, .value = 0.3 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.9 }, .{ .idx = 1, .value = 0.45 }, .{ .idx = 2, .value = 0.4 } } },
    } },

    // dubstep: square lead with formant motion and controlled abrasion
    .{ .name = "talkbox-lead", .category = "lead", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .unison = 3, .unison_detune = 15.0, .unison_spread = 0.55, .voice_mode = .mono, .glide_s = 0.035,
        .attack_s = 0.004, .decay_s = 0.2, .sustain = 0.75, .release_s = 0.1,
        .filter_type = .formant, .filter_cutoff = 420.0, .filter_res = 0.5,
        // .custom, not .triangle: a talkbox's mouth motion is asymmetric
        // (open dwells longer than closed) and its own shape distinct from
        // growl-bass's harder vowel-snap above - this one loops seamlessly
        // (the last point matches the first) for a smoother "ah-wah" motion
        // instead of a hard reset each cycle.
        .lfo_shape = .drawn, .lfo_rate_hz = 3.0, .lfo_sync = .n1_8t, .lfo_retrig = .key,
        .lfo_custom = .{
            lfoPoints(&.{
                .{ .phase = 0.0,  .value = 1.0 },
                .{ .phase = 0.35, .value = 1.0 },
                .{ .phase = 0.5,  .value = -1.0 },
                .{ .phase = 0.8,  .value = -1.0 },
                .{ .phase = 1.0,  .value = 1.0 },
            }),
            lfoPoints(&.{}),
            lfoPoints(&.{}),
        },
        .lfo_custom_count = .{ 5, 0, 0 },
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21, .depth = 0.45 },
            .{ .source = .mac1, .dest = 21, .depth = 0.5 },
            .{ .source = .mac2, .dest = 185,  .depth = -0.25 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "vowel", "vowel", "echo", "drive" }),
        .gain = 0.13,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.19 }, .{ .idx = 1, .value = 0.28 }, .{ .idx = 2, .value = 0.16 } } },
    } },

    // dubstep: dark suspended pad that leaves the sub range clear
    .{ .name = "dubstep-void", .category = "pad", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .wt_table = .metallic, .wt_pos = 0.25, .unison = 5, .unison_detune = 20.0, .unison_spread = 0.85,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.3333333, .osc_b_semi = 7.0, .osc_b_level = 0.35,
        .attack_s = 1.6, .decay_s = 0.8, .sustain = 0.8, .release_s = 2.5,
        .filter_type = .lp, .filter_cutoff = 1800.0, .filter_res = 0.2,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 220.0, .filter_routing = .series,
        .lfo2_shape = .chaos, .lfo2_rate_hz = 0.22, .lfo2_phase_offset = 0.41, .lfo2_slew_ms = 90.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo2, .dest = 185, .depth = 0.18 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.25, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "space", "crush" }),
        .gain = 0.23,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 10 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.12 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.9 }, .{ .idx = 1, .value = 0.55 }, .{ .idx = 2, .value = 0.38 } } },
    } },

    // future bass: elastic mono low end with a bright wavetable snap
    .{ .name = "future-bassline", .category = "bass", .tags = &.{ "wstudio", "future-bass" }, .patch = .{
        .wt_table = .spectral, .wt_pos = 0.42, .voice_mode = .mono, .glide_s = 0.025,
        .sub_level = 0.55, .sub_shape = .sine,
        .attack_s = 0.003, .decay_s = 0.16, .sustain = 0.7, .release_s = 0.1,
        .filter_type = .ladder, .filter_cutoff = 720.0, .filter_res = 0.18, .filter_drive = 2.8,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.13, .fenv_sustain = 0.2, .fenv_release_s = 0.08,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.35 },
            .{ .source = .velocity, .dest = 185, .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2,     .dest = 185, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "", "drive" }),
        .gain = 1.0,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 2, .value = 6 } } },
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 8 }, .{ .idx = 2, .value = 0.18 } } },
    } },

    // future bass: breathy vocal bed for wide chords and breakdowns
    .{ .name = "future-vox", .category = "pad", .tags = &.{ "wstudio", "future-bass" }, .patch = .{
        .wt_table = .formant, .wt_pos = 0.62, .unison = 6, .unison_detune = 17.0, .unison_spread = 0.9,
        .attack_s = 0.45, .decay_s = 0.5, .sustain = 0.8, .release_s = 1.4,
        .filter_type = .formant, .filter_cutoff = 650.0, .filter_res = 0.3,
        .lfo_rate_hz = 0.3, .lfo_sync = .n2_1, .lfo_slew_ms = 35.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.16 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2, .dest = 185, .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 3 },
            .{ .source = .mac4, .dest = 2, .depth = 0.2, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "vowel", "wave", "space", "drive" }),
        .gain = 0.22,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 5 }, .{ .idx = 2, .value = 0.08 } } },
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 5.5 }, .{ .idx = 2, .value = 0.42 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.85 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.32 } } },
    } },

    // deep house: muted chord pluck with a soft filter-envelope knock
    .{ .name = "deep-pluck", .category = "pluck", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .unison = 2, .unison_detune = 5.0, .unison_spread = 0.35,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_level = 0.3,
        .attack_s = 0.002, .decay_s = 0.24, .sustain = 0.0, .release_s = 0.18, .env_curve = 0.66,
        .filter_type = .ladder, .filter_cutoff = 780.0, .filter_res = 0.22, .filter_drive = 2.2,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.2, .fenv_sustain = 0.0, .fenv_release_s = 0.12, .fenv_curve = 0.7,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.5 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22,  .depth = 0.2 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "resonance", "echo", "" }),
        .gain = 0.32,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.33 }, .{ .idx = 1, .value = 0.26 }, .{ .idx = 2, .value = 0.14 } } },
    } },

    // deep house: smooth mono lead with restrained glide and chorus
    .{ .name = "deep-lead", .category = "lead", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .unison = 2, .unison_detune = 8.0, .unison_spread = 0.45, .voice_mode = .legato, .glide_s = 0.055,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_level = 0.35,
        .attack_s = 0.015, .decay_s = 0.25, .sustain = 0.75, .release_s = 0.22,
        .filter_type = .lp, .filter_cutoff = 1900.0, .filter_res = 0.2,
        .lfo_rate_hz = 5.0, .lfo_retrig = .key, .lfo_phase_offset = 0.25,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = dP,  .depth = 0.014 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2, .dest = 186,   .depth = -0.22 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "chorus", "" }),
        .gain = 0.31,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.55 }, .{ .idx = 1, .value = 3.5 }, .{ .idx = 2, .value = 0.22 } } },
    } },

    // dub: short minor organ chord made for long feedback-delay throws
    .{ .name = "dub-chord", .category = "stab", .tags = &.{ "wstudio", "dub", "reggae" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 3.0, .osc_b_level = 0.5,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.0, .osc_c_semi = 7.0, .osc_c_level = 0.4,
        .attack_s = 0.004, .decay_s = 0.2, .sustain = 0.0, .release_s = 0.16, .env_curve = 0.62,
        .filter_type = .ladder, .filter_cutoff = 1300.0, .filter_res = 0.28, .filter_drive = 2.5,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2,     .dest = 22,  .depth = 0.2 },
            .{ .source = .mac3, .dest = 2, .depth = 0.55, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.22, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "resonance", "echo", "drive" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 5 }, .{ .idx = 2, .value = 0.1 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 0.58 }, .{ .idx = 2, .value = 0.28 } } },
    } },

    // dub: airy bubble organ with waveform motion and spring-like ambience
    .{ .name = "bubble-organ", .category = "keys", .tags = &.{ "wstudio", "dub", "reggae" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_level = 0.45,
        .attack_s = 0.003, .decay_s = 0.11, .sustain = 0.35, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.12,
        .lfo_rate_hz = 0.8, .lfo_sync = .n1_2, .lfo_retrig = .key,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 185,   .depth = -0.12 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2, .dest = 185,   .depth = -0.25 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "bubble", "space", "" }),
        .gain = 0.32,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.45 }, .{ .idx = 1, .value = 0.65 }, .{ .idx = 2, .value = 0.2 } } },
        // Dub keyboards are not heard dry into a room: the short tape slap
        // with a couple of repeats is as much part of the sound as the
        // organ, and the spring it feeds is already here. Damped, because
        // tape loses the top on every pass.
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.11 }, .{ .idx = 1, .value = 0.38 }, .{ .idx = 2, .value = 0.28 }, .{ .idx = 3, .value = 0.45 } } },
    } },

    // soul: warm electric-piano body with velocity-controlled tine bark
    .{ .name = "soul-epiano", .category = "keys", .tags = &.{ "wstudio", "soul", "neo-soul" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 14.0, .osc_b_level = 0.7,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 0.85,
        .attack_s = 0.003, .decay_s = 1.5, .sustain = 0.3, .release_s = 1.0, .env_curve = 0.5,
        .filter_type = .lp, .filter_cutoff = 4200.0, .filter_res = 0.04,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 44,  .depth = 0.1 },
            .{ .source = .velocity, .dest = 44,  .depth = 0.16 },
            .{ .source = .random,   .dest = 44,  .depth = 0.015 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.25 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 3, .depth = 0.5, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "tine", "chorus", "tremolo" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 3.5 }, .{ .idx = 2, .value = 0.24 } } },
        // The suitcase Rhodes has a stereo tremolo in its own amplifier, and
        // the soul records this patch is named for are that instrument, not
        // the bare tine. Shallow by default, with macro 4 opening it - the
        // grit slot, since nothing in this chain distorts.
        .{ .kind = .auto_pan, .params = &.{ .{ .idx = 0, .value = 5.0 }, .{ .idx = 3, .value = 0.3 } } },
    } },

    // === Round 4: the modern production toolkit ===
    //
    // The library had one FX preset and one brass against twenty basses. These
    // fill the roles a 2020s session reaches for and the factory set could not
    // answer: transitions, the African and Caribbean rhythm exports, drill and
    // phonk, and the club sounds built on effects rather than oscillators.

    // The universal build tool: noise through a resonant lowpass whose cutoff
    // climbs four octaves on the filter envelope, with pitch rising underneath
    // so it lifts even against a static-key track. Audible from the downbeat
    // rather than fading in - a riser that starts silent wastes its first bar.
    .{ .name = "riser-noise", .category = "fx", .tags = &.{ "wstudio", "house", "trance" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 3, .unison_detune = 25.0, .unison_spread = 0.8,
        .noise_level = 0.9, .noise_color = 1.0,
        .attack_s = 0.02, .decay_s = 0.5, .sustain = 1.0, .release_s = 0.4,
        .filter_type = .bp, .filter_cutoff = 300.0, .filter_res = 0.45,
        .fenv_attack_s = 3.6, .fenv_decay_s = 0.5, .fenv_sustain = 1.0, .fenv_release_s = 0.3, .fenv_curve = 0.35,
        .env3_attack_s = 3.6, .env3_decay_s = 0.5, .env3_sustain = 1.0, .env3_release_s = 0.3,
        .lfo_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.9 },
            .{ .source = .env3, .dest = dP,  .depth = 0.5 },
            .{ .source = .lfo,  .dest = 22,  .depth = 0.15 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "sweep", "detune", "space", "" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.85 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.35 } } },
    } },

    // The riser's counterpart, for the bar after the drop: the same noise bed
    // with both envelopes inverted, so cutoff and pitch fall away instead of
    // climbing. Wide stereo and a long tail so it clears the way rather than
    // fighting the groove that follows it.
    .{ .name = "downlifter", .category = "fx", .tags = &.{ "wstudio", "house", "dubstep" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 4, .unison_detune = 30.0, .unison_spread = 1.0,
        .noise_level = 0.8, .noise_color = 0.8,
        .attack_s = 0.004, .decay_s = 2.4, .sustain = 0.0, .release_s = 1.2, .env_curve = 0.4,
        .filter_type = .lp, .filter_cutoff = 9000.0, .filter_res = 0.25,
        .fenv_attack_s = 0.004, .fenv_decay_s = 2.2, .fenv_sustain = 0.0, .fenv_release_s = 1.0, .fenv_curve = 0.5,
        .env3_attack_s = 0.004, .env3_decay_s = 2.0, .env3_sustain = 0.0, .env3_release_s = 1.0, .env3_curve = 0.45,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.75 },
            .{ .source = .env3, .dest = dP,  .depth = -0.6 },
            .{ .source = .mac1, .dest = 21,  .depth = -0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "sweep", "detune", "space", "" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.9 }, .{ .idx = 2, .value = 0.4 } } },
    } },

    // Section marker: a sub sine whose pitch collapses an octave in 120 ms
    // (the boom) under a noise burst (the crack), then a long plate to carry
    // it. Distortion before the reverb so the tail is dense rather than clean.
    .{ .name = "impact-hit", .category = "fx", .tags = &.{ "wstudio", "techno", "trap" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono,
        .sub_level = 0.8, .sub_shape = .sine,
        .noise_level = 0.5, .noise_color = 0.55,
        .attack_s = 0.001, .decay_s = 1.6, .sustain = 0.0, .release_s = 1.4, .env_curve = 0.7,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.1, .filter_drive = 2.0,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.09, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.8,
        .env3_attack_s = 0.001, .env3_decay_s = 0.12, .env3_sustain = 0.0, .env3_release_s = 0.1, .env3_curve = 0.85,
        .mod_matrix = mods(&.{
            .{ .source = .env3,     .dest = dP,  .depth = -1.0 },
            .{ .source = .fenv,     .dest = 36,  .depth = 0.5 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.5, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 34,  .depth = 0.3 },
        }),
        .macro_labels = macros(.{ "", "sub", "boom", "drive" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 10 }, .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.95 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.45 } } },
    } },

    // The breakdown bed melodic techno is built on: air, not notes. Bandpassed
    // noise with two slow LFOs walking the band, so it reads as room tone
    // rather than as a held synth. Every Afterlife-school breakdown has one
    // under it and sounds cheap without it.
    .{ .name = "air-wash", .category = "fx", .tags = &.{ "wstudio", "ambient", "melodic-techno" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0,
        .noise_level = 1.0, .noise_color = 0.75,
        .attack_s = 0.35, .decay_s = 1.0, .sustain = 0.9, .release_s = 2.5,
        .filter_type = .bp, .filter_cutoff = 1400.0, .filter_res = 0.3,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 400.0, .filter_routing = .series,
        .lfo_rate_hz = 0.08, .lfo_slew_ms = 60.0,
        .lfo2_rate_hz = 0.13, .lfo2_phase_offset = 0.25, .lfo2_slew_ms = 60.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo2, .dest = dA,  .depth = -0.25 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 22,  .depth = 0.25 },
        }),
        .macro_labels = macros(.{ "air", "resonance", "space", "" }),
        .gain = 0.16,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.9 }, .{ .idx = 1, .value = 0.5 }, .{ .idx = 2, .value = 0.4 } } },
    } },

    // The transition that costs nothing: one sine falling an octave and a half
    // over two seconds. Trap and dubstep drops are still built on it, and it
    // is the one FX voice that must stay clean - no noise layer, so it lands
    // under a mix instead of on top of it.
    .{ .name = "sub-drop", .category = "fx", .tags = &.{ "wstudio", "trap", "dubstep" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono,
        .sub_level = 0.7, .sub_shape = .sine,
        .attack_s = 0.006, .decay_s = 2.0, .sustain = 0.3, .release_s = 0.6, .env_curve = 0.3,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.05, .filter_drive = 1.6,
        .env3_attack_s = 0.004, .env3_decay_s = 1.8, .env3_sustain = 0.0, .env3_release_s = 0.5, .env3_curve = 0.55,
        .mod_matrix = mods(&.{
            .{ .source = .env3, .dest = dP, .depth = -1.0 },
            .{ .source = .env3, .dest = 21, .depth = -0.3 },
            .{ .source = .mac1, .dest = 21, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 34,  .depth = 0.3 },
        }),
        .macro_labels = macros(.{ "tone", "sub", "", "drive" }),
        .gain = 0.34,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 6 }, .{ .idx = 2, .value = 0.2 } } },
    } },

    // amapiano - the log drum, which is the genre's bassline, its kick and its
    // hook at once. It is a hybrid rather than a bass patch: a sine body with
    // a fast downward pitch envelope for the kick-like thump, a short FM knock
    // on top for the wooden mallet edge, and mono glide, because the punch
    // comes from the slide between notes rather than from level.
    .{ .name = "log-drum", .category = "bass", .tags = &.{ "wstudio", "amapiano" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.07,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 19.0, .osc_b_level = 0.45,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 1.6,
        .sub_level = 0.7, .sub_shape = .sine,
        .attack_s = 0.002, .decay_s = 0.42, .sustain = 0.0, .release_s = 0.2, .env_curve = 0.55,
        .filter_type = .lp, .filter_cutoff = 1400.0, .filter_res = 0.06, .filter_drive = 1.8,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.1, .fenv_sustain = 0.0, .fenv_release_s = 0.08, .fenv_curve = 0.7,
        .env3_attack_s = 0.001, .env3_decay_s = 0.05, .env3_sustain = 0.0, .env3_release_s = 0.05, .env3_curve = 0.85,
        .mod_matrix = mods(&.{
            .{ .source = .env3,     .dest = dP, .depth = 0.25 },
            .{ .source = .fenv,     .dest = 44, .depth = 0.3 },
            .{ .source = .velocity, .dest = 44, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 44, .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "knock", "", "" }),
        .gain = 0.57,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 1, .value = 3.5 }, .{ .idx = 2, .value = 8 }, .{ .idx = 3, .value = 90 } } },
    } },

    // amapiano - the other half of the genre's name: jazzy sevenths on a
    // soft electric piano, deliberately duller and slower to speak than the
    // FM tine pianos so it sits behind the log drum instead of competing with
    // it. Long release and a wide chorus for the airy tail the style leans on.
    .{ .name = "ama-keys", .category = "keys", .tags = &.{ "wstudio", "amapiano", "afro-house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .detune_cents = -3.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_detune_cents = 5.0, .osc_b_level = 0.4,
        .attack_s = 0.03, .decay_s = 1.6, .sustain = 0.25, .release_s = 1.3, .env_curve = 0.35,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.07,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 160.0, .filter_routing = .series,
        .fenv_attack_s = 0.02, .fenv_decay_s = 0.6, .fenv_sustain = 0.15, .fenv_release_s = 0.4,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.3 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.35 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac1, .dest = 185, .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "chorus", "" }),
        // Level pass: 8 dB under the median keys patch. Sitting behind the log
        // drum is what the dull filter and slow attack are for; being quiet is
        // the user's fader, not the preset's.
        .gain = 0.71,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.4 }, .{ .idx = 1, .value = 6 }, .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 0.5 }, .{ .idx = 2, .value = 0.25 } } },
    } },

    // afro house - the mallet line the genre builds its melodies from. A
    // marimba is a struck bar: near-silent attack transient, a strong 4th
    // partial that decays much faster than the fundamental, and nothing
    // sustained. FM at a 4:1 ratio on a fast envelope is that in two
    // oscillators; keytrack shortens the decay upward like a real bar.
    .{ .name = "marimba-pluck", .category = "pluck", .tags = &.{ "wstudio", "afro-house", "amapiano" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 24.0, .osc_b_level = 0.55,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 1.9,
        .attack_s = 0.001, .decay_s = 0.3, .sustain = 0.0, .release_s = 0.12, .env_curve = 0.8,
        .filter_type = .lp, .filter_cutoff = 4600.0, .filter_res = 0.04,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.025, .fenv_sustain = 0.0, .fenv_release_s = 0.05, .fenv_curve = 0.9,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 44,  .depth = 0.6 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.3 },
            .{ .source = .velocity, .dest = 44,  .depth = 0.3 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.35 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "", "mallet", "echo", "" }),
        .gain = 0.32,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.187 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.18 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 0.6 }, .{ .idx = 2, .value = 0.12 } } },
    } },

    // afrobeats - the plucked guitar figure the records are written on, as a
    // synth: a short bright body with a noise pick transient and a fast
    // filter close, played mono with a little glide for the hammer-on slurs.
    // Nylon rather than steel, so the top end stops around 3 kHz.
    .{ .name = "afro-pluck", .category = "pluck", .tags = &.{ "wstudio", "afrobeats", "afro-house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .voice_mode = .mono, .glide_s = 0.015,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_detune_cents = 6.0, .osc_b_level = 0.3,
        .noise_level = 0.12, .noise_color = 0.9,
        .attack_s = 0.002, .decay_s = 0.4, .sustain = 0.08, .release_s = 0.3, .env_curve = 0.6,
        .filter_type = .lp, .filter_cutoff = 2900.0, .filter_res = 0.12,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.07, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.75,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.5 },
            .{ .source = .fenv,     .dest = 36,  .depth = 0.35 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "echo", "" }),
        .gain = 0.32,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.2 } } },
    } },

    // afro house - the horn stab that answers the vocal. Real sections play
    // it short and hard, so the filter envelope opens faster than the
    // amplitude one and velocity drives both: at low velocity it is a muted
    // section, at full it is the whole brass line leaning in.
    .{ .name = "afro-brass", .category = "brass", .tags = &.{ "wstudio", "afro-house", "afrobeats" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 3, .unison_detune = 12.0, .unison_spread = 0.45,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_semi = 12.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.35,
        .attack_s = 0.012, .decay_s = 0.22, .sustain = 0.45, .release_s = 0.18, .env_curve = 0.4,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.15, .filter_drive = 1.8,
        // Filter opening after the level, as on retro-brass.
        .fenv_attack_s = 0.02, .fenv_decay_s = 0.2, .fenv_sustain = 0.2, .fenv_release_s = 0.15, .fenv_curve = 0.5,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .fenv,     .dest = 21,  .depth = 0.5 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 0, .value = -16 }, .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 6 }, .{ .idx = 3, .value = 70 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.55 }, .{ .idx = 1, .value = 0.5 }, .{ .idx = 2, .value = 0.18 } } },
    } },

    // drill - the sliding 808. What separates it from trap-808 is not the
    // tone but the glide: drill basslines slide between pitches instead of
    // holding them, so this is mono with a long portamento and a sustain high
    // enough that the note is still sounding when the slide arrives.
    // Saturated rather than clean, since the slide has to stay audible after
    // the low end is compressed.
    .{ .name = "drill-808", .category = "bass", .tags = &.{ "wstudio", "drill", "trap" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.11,
        .sub_level = 0.9, .sub_shape = .sine,
        .attack_s = 0.004, .decay_s = 0.9, .sustain = 0.55, .release_s = 0.5, .env_curve = 0.35,
        .filter_type = .lp, .filter_cutoff = 700.0, .filter_res = 0.04, .filter_drive = 2.4,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.06, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.8,
        // Drill 808s glide, but they still knock: same pitch drop as trap-808,
        // shorter, since the glide already owns the movement between notes.
        .env3_attack_s = 0.001, .env3_decay_s = 0.04, .env3_sustain = 0.0, .env3_release_s = 0.05, .env3_curve = 0.8,
        .mod_matrix = mods(&.{
            .{ .source = .env3,     .dest = dP, .depth = 0.6 },
            .{ .source = .fenv,     .dest = 21, .depth = 0.4 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.45, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 34,  .depth = 0.3 },
        }),
        .macro_labels = macros(.{ "brightness", "sub", "", "drive" }),
        .gain = 0.49,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 0, .value = -20 }, .{ .idx = 2, .value = 12 }, .{ .idx = 3, .value = 130 } } },
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 9 }, .{ .idx = 2, .value = 0.3 } } },
    } },

    // drill - the sparse bell that carries the hook over the slide. Drill
    // melodies are minimal and dark by design, so this is narrow, quiet and
    // long-tailed: an inharmonic FM pair a semitone-and-a-half sharp of a
    // 3:1 ratio, which is what makes a bell read as uneasy rather than
    // pretty, into a wide plate.
    .{ .name = "drill-bell", .category = "pluck", .tags = &.{ "wstudio", "drill" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 19.0, .osc_b_detune_cents = 22.0, .osc_b_level = 0.6,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 2.2,
        .attack_s = 0.002, .decay_s = 1.4, .sustain = 0.0, .release_s = 1.0, .env_curve = 0.68,
        .filter_type = .lp, .filter_cutoff = 3400.0, .filter_res = 0.05,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.35, .fenv_sustain = 0.0, .fenv_release_s = 0.3, .fenv_curve = 0.6,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 44,  .depth = 0.3 },
            .{ .source = .velocity, .dest = 44,  .depth = 0.2 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "", "bell", "space", "" }),
        .gain = 0.24,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.333 }, .{ .idx = 1, .value = 0.32 }, .{ .idx = 2, .value = 0.2 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.88 }, .{ .idx = 1, .value = 0.4 }, .{ .idx = 2, .value = 0.35 } } },
    } },

    // drill - the other half of the genre's melodic palette, borrowed from
    // film score: low brass swelling under the beat, minor and slow. Third
    // above the root rather than the octave for the diminished colour, and
    // the swell is on the filter, not the amplitude, so it stays present in
    // the mix while it grows.
    .{ .name = "noir-brass", .category = "brass", .tags = &.{ "wstudio", "drill", "trap" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 4, .unison_detune = 16.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_semi = 3.0, .osc_b_detune_cents = -7.0, .osc_b_level = 0.4,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.0, .osc_c_semi = -12.0, .osc_c_level = 0.5,
        .attack_s = 0.35, .decay_s = 0.8, .sustain = 0.7, .release_s = 0.7, .env_curve = -0.2,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.1, .filter_drive = 2.2,
        .fenv_attack_s = 0.9, .fenv_decay_s = 1.2, .fenv_sustain = 0.5, .fenv_release_s = 0.6, .fenv_curve = -0.3,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.55 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .eq, .params = &.{ .{ .idx = 0, .value = 3 }, .{ .idx = 1, .value = 120 }, .{ .idx = 3, .value = 3 }, .{ .idx = 10, .value = 1000 }, .{ .idx = 18, .value = 4 }, .{ .idx = 19, .value = 5000 }, .{ .idx = 21, .value = -4 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.8 }, .{ .idx = 1, .value = 0.55 } } },
    } },

    // phonk - the cowbell melody the whole genre is written on. The 808's
    // cowbell is two square waves a fifth apart through a narrow bandpass
    // with a fast decay; tuned and played as pitches it becomes a lead. Crush
    // and drive for the tape-dub grit rather than a clean digital tone.
    .{ .name = "phonk-cowbell", .category = "pluck", .tags = &.{ "wstudio", "phonk", "hip-hop" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0, .voice_mode = .mono,
        // The 808 cowbell is two square oscillators at 540 and 800 Hz - 681
        // cents apart, a fifth flattened by 19 cents. That not-quite-interval
        // is what beats and reads as metal; a fifth sharpened by 14, which is
        // what this was, beats too but around the wrong centre.
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 7.0, .osc_b_detune_cents = -19.0, .osc_b_level = 0.85,
        .attack_s = 0.001, .decay_s = 0.28, .sustain = 0.0, .release_s = 0.12, .env_curve = 0.75,
        .filter_type = .bp, .filter_cutoff = 2400.0, .filter_res = 0.55, .filter_drive = 2.6,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.08, .fenv_curve = 0.7,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.35 },
            .{ .source = .velocity, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 22,  .depth = 0.25 },
        }),
        .macro_labels = macros(.{ "brightness", "resonance", "", "tape dirt" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 11 }, .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 10 }, .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 0.3 } } },
    } },

    // pluggnb - the glassy bell the style is built on. Bright but soft: a
    // 2:1 FM pair with the index almost static, so it reads as glass rather
    // than as a struck bell, and heavy OTT flattening the envelope into the
    // glossy surface the genre mixes for. Sparkle without a hard transient.
    .{ .name = "plugg-bell", .category = "pluck", .tags = &.{ "wstudio", "pluggnb", "trap" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .detune_cents = 4.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_detune_cents = 6.0, .osc_b_level = 0.7,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 0.8,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.0, .osc_c_semi = 24.0, .osc_c_level = 0.22,
        .attack_s = 0.02, .decay_s = 0.9, .sustain = 0.15, .release_s = 0.8, .env_curve = 0.45,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.03,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 44,  .depth = 0.15 },
            .{ .source = .random,   .dest = 44,  .depth = 0.02 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 3 },
        }),
        .macro_labels = macros(.{ "", "glass", "space", "" }),
        .gain = 0.24,
    }, .fx = &.{
        .{ .kind = .ott, .params = &.{ .{ .idx = 0, .value = 0.65 }, .{ .idx = 3, .value = -7 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.375 }, .{ .idx = 1, .value = 0.38 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.82 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.35 } } },
        // Level pass: this patch measured far off its category's median
        // momentary loudness, and its own chain is nonlinear, so the trim
        // goes after it rather than into the voice gain ahead of it.
        .{ .kind = .utility, .params = &.{ .{ .idx = 0, .value = 9 } } },
    } },

    // uk garage - the organ stab that gives 2-step its skip. Drawbar organ
    // registration (root, octave, twelfth) with no filter movement at all:
    // the bounce is in the envelope, a hard gate closing before the next
    // eighth, not in a sweep. Dub-style short plate, and the third harmonic
    // is what keeps it cutting through a busy shuffle.
    .{ .name = "garage-organ", .category = "stab", .tags = &.{ "wstudio", "uk-garage", "house" }, .patch = .{
        .wt_table = .basic, .wt_pos = 1.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 12.0, .osc_b_level = 0.55,
        .osc_c_on = true, .osc_c_wt_table = .basic, .osc_c_wt_pos = 0.0, .osc_c_semi = 19.0, .osc_c_level = 0.35,
        .attack_s = 0.004, .decay_s = 0.14, .sustain = 0.0, .release_s = 0.08, .env_curve = 0.5,
        .filter_type = .lp, .filter_cutoff = 3800.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 220.0, .filter_routing = .series,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21,  .depth = 0.35 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 185, .depth = -0.35 },
        }),
        .macro_labels = macros(.{ "bite", "wave", "space", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.45 }, .{ .idx = 1, .value = 0.5 }, .{ .idx = 2, .value = 0.22 } } },
    } },

    // hard techno - the rumble. Not an oscillator patch: the sound is a kick
    // sent to a long reverb, distorted, then shelved so only the sub tail
    // survives. Here the reverb is in the voice and the lowpass sits after
    // the drive, so a held note becomes the rolling sub the genre runs on.
    // Slow attack on purpose - a rumble with a transient is a kick.
    .{ .name = "rumble-bass", .category = "bass", .tags = &.{ "wstudio", "hard-techno", "techno" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.02,
        .sub_level = 0.85, .sub_shape = .sine,
        .noise_level = 0.06, .noise_color = 0.25,
        .attack_s = 0.06, .decay_s = 0.5, .sustain = 0.8, .release_s = 0.45,
        .filter_type = .lp, .filter_cutoff = 190.0, .filter_res = 0.08, .filter_drive = 3.2,
        .lfo_rate_hz = 2.0, .lfo_sync = .n1_4, .lfo_retrig = .key, .lfo_slew_ms = 20.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,      .dest = dA, .depth = -0.35 },
            .{ .source = .velocity, .dest = 21, .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.35 },
            .{ .source = .mac4, .dest = 2, .depth = 0.45, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 34,  .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 3 },
        }),
        .macro_labels = macros(.{ "brightness", "sub", "space", "rumble" }),
        .gain = 0.24,
    }, .fx = &.{
        .{ .kind = .eq, .params = &.{ .{ .idx = 0, .value = 3 }, .{ .idx = 1, .value = 150 }, .{ .idx = 10, .value = 1000 }, .{ .idx = 18, .value = 4 }, .{ .idx = 21, .value = -10 } } },
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 15 }, .{ .idx = 2, .value = 0.5 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.95 }, .{ .idx = 1, .value = 0.85 }, .{ .idx = 2, .value = 0.45 } } },
    } },

    // melodic techno - the pluck the genre crystallises around. The patch is
    // almost nothing: a short filtered saw. What makes it the sound is a
    // dotted-eighth delay feeding a long hall, so the notes overlap into
    // their own chord. Macro 3 rides that send, which is how the drop is
    // played in this style - reverb cut to zero on the downbeat.
    .{ .name = "melodic-pluck", .category = "pluck", .tags = &.{ "wstudio", "melodic-techno", "techno" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 2, .unison_detune = 9.0, .unison_spread = 0.4,
        .attack_s = 0.002, .decay_s = 0.35, .sustain = 0.0, .release_s = 0.3, .env_curve = 0.7,
        .filter_type = .ladder, .filter_cutoff = 1800.0, .filter_res = 0.28, .filter_drive = 1.6,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.3, .fenv_sustain = 0.0, .fenv_release_s = 0.2, .fenv_curve = 0.65,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.55 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.3 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac3, .dest = 2, .depth = 0.5, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "hall", "" }),
        // Level pass: this measured 13 dB under the median pluck, which is
        // the widest gap in the library. Its chain is a delay into a hall, both
        // linear, so the voice gain is the right place to fix it.
        .gain = 1,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.281 }, .{ .idx = 1, .value = 0.5 }, .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.92 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.4 } } },
    } },

    // melodic techno - the hypnotic sixteenth arp that carries a set. The
    // library had exactly one arpeggiated preset, all of it chiptune. Gate
    // well under half so each step is a separate event rather than a legato
    // line, two octaves of travel, and the same delay-into-hall treatment
    // the plucks get, because the repeats are the melody here.
    .{ .name = "hypno-arp", .category = "lead", .tags = &.{ "wstudio", "melodic-techno", "trance" }, .patch = .{
        .wt_table = .analog, .wt_pos = 0.35, .unison = 2, .unison_detune = 11.0, .unison_spread = 0.5,
        .arp_on = true, .arp_mode = .updown, .arp_octaves = 2, .arp_sync = .n1_16, .arp_gate = 0.38,
        .attack_s = 0.002, .decay_s = 0.22, .sustain = 0.0, .release_s = 0.15, .env_curve = 0.7,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.22,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.18, .fenv_sustain = 0.0, .fenv_release_s = 0.12, .fenv_curve = 0.6,
        .lfo_rate_hz = 0.12, .lfo_slew_ms = 40.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .fenv, .dest = 21,  .depth = 0.5 },
            .{ .source = .lfo,  .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 185, .depth = 0.4 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "echo", "" }),
        .gain = 0.33,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.375 }, .{ .idx = 1, .value = 0.45 }, .{ .idx = 2, .value = 0.3 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.85 }, .{ .idx = 1, .value = 0.4 } } },
    } },

    // house - the pumping chord bed. Every other pad in the library holds
    // still; this one is shaped by a quarter-note gate on the amp, which is
    // the sidechain-to-the-kick sound as a patch rather than as a mixer
    // routing. Retriggered on key so the pump starts with the chord.
    .{ .name = "pump-chords", .category = "pad", .tags = &.{ "wstudio", "house", "future-bass" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 4, .unison_detune = 14.0, .unison_spread = 0.65,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = -12.0, .osc_b_level = 0.3,
        .attack_s = 0.02, .decay_s = 0.5, .sustain = 0.85, .release_s = 0.5,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 150.0, .filter_routing = .series,
        .lfo_shape = .drawn, .lfo_sync = .n1_4, .lfo_retrig = .key, .lfo_rate_hz = 2.0, .lfo_slew_ms = 8.0,
        .lfo_custom = .{
            lfoPoints(&.{
                .{ .phase = 0.0,  .value = -1.0 },
                .{ .phase = 0.55, .value = 0.9 },
                .{ .phase = 0.9,  .value = 1.0 },
                .{ .phase = 1.0,  .value = 1.0 },
            }),
            lfoPoints(&.{}),
            lfoPoints(&.{}),
        },
        .lfo_custom_count = .{ 4, 0, 0 },
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = dA,  .depth = 0.55 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "space", "" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .ott, .params = &.{ .{ .idx = 0, .value = 0.45 }, .{ .idx = 3, .value = -6 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 0.4 }, .{ .idx = 2, .value = 0.28 } } },
    } },

    // hyperpop - the chord stab, which is a mixing decision more than a
    // patch: a wide supersaw squared off by heavy OTT and hard drive until
    // the envelope is flat and the top end is all edge. Deliberately brighter
    // and more compressed than the trance supersaw it starts from - the
    // genre's whole aesthetic is the plastic surface.
    .{ .name = "hyperpop-stab", .category = "stab", .tags = &.{ "wstudio", "hyperpop", "future-bass" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 7, .unison_detune = 26.0, .unison_spread = 0.9,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 12.0, .osc_b_detune_cents = 12.0, .osc_b_level = 0.45,
        .attack_s = 0.003, .decay_s = 0.5, .sustain = 0.0, .release_s = 0.3, .env_curve = 0.55,
        .filter_type = .lp, .filter_cutoff = 7500.0, .filter_res = 0.12,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 200.0, .filter_routing = .series,
        .fenv_attack_s = 0.002, .fenv_decay_s = 0.4, .fenv_sustain = 0.0, .fenv_release_s = 0.2,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .fenv,     .dest = 21,  .depth = 0.3 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2,     .dest = 4,   .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 4 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "space", "drive" }),
        .gain = 0.24,
    }, .fx = &.{
        .{ .kind = .ott, .params = &.{ .{ .idx = 0, .value = 0.9 }, .{ .idx = 3, .value = -9 } } },
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 8 }, .{ .idx = 2, .value = 0.3 } } },
        // The genre's surface is digital clipping, not just saturation: a
        // soft curve rounds the peaks and a hard one squares them, and the
        // squared one is the sound. Before the reverb, so the room is around
        // a clipped stab rather than itself clipped.
        .{ .kind = .clipper, .params = &.{ .{ .idx = 0, .value = 4 }, .{ .idx = 1, .value = -0.5 }, .{ .idx = 2, .value = 0 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.65 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.22 } } },
    } },

    // hard techno - the metallic percussive stab that carries a hardgroove
    // loop. Ring modulation rather than detuning: an inharmonic partial is
    // what makes a stab read as metal instead of as a chord, and it stays
    // legible at 150 BPM where a detuned saw turns to mush.
    .{ .name = "hardgroove-stab", .category = "stab", .tags = &.{ "wstudio", "hard-techno", "techno" }, .patch = .{
        .wt_table = .metallic, .wt_pos = 0.4, .voice_mode = .mono,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 8.0, .osc_b_level = 0.7,
        .osc_b_warp_mode = .ring_a_b, .osc_b_warp_amount = 0.7,
        .attack_s = 0.001, .decay_s = 0.18, .sustain = 0.0, .release_s = 0.12, .env_curve = 0.8,
        .filter_type = .bp, .filter_cutoff = 1800.0, .filter_res = 0.4, .filter_drive = 2.8,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.14, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.75,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.5 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.35 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2,     .dest = 185, .depth = 0.4 },
            .{ .source = .mac4, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "bite", "metal", "echo", "drive" }),
        .gain = 0.28,
    }, .fx = &.{
        .{ .kind = .sat, .params = &.{ .{ .idx = 2, .value = 0.35 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.14 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.18 } } },
    } },

    // reggaeton - the dembow stab. Short, mid-forward and mono, sitting in
    // the gap the kick-snare pattern leaves rather than filling the bar:
    // a bandpass keeps it out of both the 808's range and the vocal's, which
    // is why the genre's synths sound thin soloed and correct in the mix.
    .{ .name = "dembow-stab", .category = "stab", .tags = &.{ "wstudio", "reggaeton", "trap" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .voice_mode = .mono, .glide_s = 0.008,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 0.0, .osc_b_detune_cents = 11.0, .osc_b_level = 0.6,
        .attack_s = 0.002, .decay_s = 0.22, .sustain = 0.0, .release_s = 0.14, .env_curve = 0.7,
        .filter_type = .bp, .filter_cutoff = 1100.0, .filter_res = 0.35, .filter_drive = 2.0,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.7,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.45 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.35 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .mac2, .dest = 22,  .depth = 0.25 },
        }),
        .macro_labels = macros(.{ "bite", "resonance", "echo", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.21 }, .{ .idx = 1, .value = 0.28 }, .{ .idx = 2, .value = 0.2 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 0.55 }, .{ .idx = 2, .value = 0.16 } } },
    } },

    // house - the piano the genre never stopped using. A real piano's hammer
    // strike is a fast inharmonic burst over a struck string, so the filter
    // envelope opens and shuts in 40 ms while the amplitude rings on; the
    // slight detune between the two oscillators is the unison string pair.
    // Plays as a chord stab or as a full line.
    .{ .name = "house-piano", .category = "keys", .tags = &.{ "wstudio", "house", "uk-garage" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.6666667, .osc_b_detune_cents = -8.0, .osc_b_level = 0.5,
        .attack_s = 0.001, .decay_s = 0.7, .sustain = 0.12, .release_s = 0.35, .env_curve = 0.68,
        .filter_type = .lp, .filter_cutoff = 3000.0, .filter_res = 0.14,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.04, .fenv_sustain = 0.0, .fenv_release_s = 0.06, .fenv_curve = 0.85,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.6 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.4 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 2 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "space", "" }),
        .gain = 0.3,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 8 }, .{ .idx = 3, .value = 90 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.6 }, .{ .idx = 1, .value = 0.45 }, .{ .idx = 2, .value = 0.2 } } },
    } },

    // afro house - the hypnotic analog riff that runs under the percussion
    // for eight bars at a time. Mono with real glide so the line slurs, and
    // a slow unsynced LFO on the cutoff so a repeated figure never lands
    // twice the same way - the movement has to come from the patch when the
    // notes do not change.
    .{ .name = "afro-lead", .category = "lead", .tags = &.{ "wstudio", "afro-house", "deep-house" }, .patch = .{
        .wt_table = .analog, .wt_pos = 0.55, .unison = 2, .unison_detune = 7.0, .unison_spread = 0.4, .voice_mode = .mono, .glide_s = 0.045,
        .osc_b_on = true, .osc_b_wt_table = .analog, .osc_b_wt_pos = 0.2, .osc_b_detune_cents = 9.0, .osc_b_level = 0.5,
        .attack_s = 0.01, .decay_s = 0.4, .sustain = 0.55, .release_s = 0.3,
        .filter_type = .ladder, .filter_cutoff = 1500.0, .filter_res = 0.3, .filter_drive = 1.8,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.3, .fenv_sustain = 0.2, .fenv_release_s = 0.2, .fenv_curve = 0.5,
        .lfo_rate_hz = 0.17, .lfo_slew_ms = 30.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,      .dest = 21,  .depth = 0.25 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.5 },
            .{ .source = .mac1, .dest = 185, .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.4, .fx_instance_id = 1 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2, .dest = 4,   .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "detune", "echo", "" }),
        .gain = 1.0,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.3 }, .{ .idx = 1, .value = 0.4 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.7 }, .{ .idx = 1, .value = 0.45 }, .{ .idx = 2, .value = 0.22 } } },
    } },

    // pop - the bell arpeggio that tops a chorus, and the second arp in a
    // library that had one. Sixteenths up three octaves with a long gate so
    // the tails overlap into a shimmer, FM bell body kept soft: this sits
    // above a vocal rather than competing with it.
    .{ .name = "bell-arp", .category = "lead", .tags = &.{ "wstudio", "j-pop", "future-bass" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .unison = 2, .unison_detune = 5.0, .unison_spread = 0.5,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 19.0, .osc_b_detune_cents = 4.0, .osc_b_level = 0.55,
        .osc_b_warp_mode = .fm_b_to_a, .osc_b_warp_amount = 1.2,
        .arp_on = true, .arp_mode = .up, .arp_octaves = 3, .arp_sync = .n1_16, .arp_gate = 0.85,
        .attack_s = 0.002, .decay_s = 0.5, .sustain = 0.0, .release_s = 0.45, .env_curve = 0.65,
        .filter_type = .lp, .filter_cutoff = 5500.0, .filter_res = 0.04,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.1, .fenv_curve = 0.7,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 44,  .depth = 0.35 },
            .{ .source = .velocity, .dest = 44,  .depth = 0.2 },
            .{ .source = .mac2,     .dest = 44,  .depth = 0.3 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 3 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "", "bell", "space", "" }),
        .gain = 0.31,
    }, .fx = &.{
        .{ .kind = .chorus, .params = &.{ .{ .idx = 0, .value = 0.5 }, .{ .idx = 1, .value = 4.5 }, .{ .idx = 2, .value = 0.28 } } },
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.187 }, .{ .idx = 1, .value = 0.42 }, .{ .idx = 2, .value = 0.28 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.8 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.32 } } },
    } },

    // soul: rounded finger bass with a small upper-harmonic layer
    .{ .name = "soul-bass", .category = "bass", .tags = &.{ "wstudio", "soul", "neo-soul" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .voice_mode = .mono, .glide_s = 0.012,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_level = 0.2,
        .sub_level = 0.5, .sub_shape = .sine,
        .attack_s = 0.006, .decay_s = 0.18, .sustain = 0.72, .release_s = 0.16,
        .filter_type = .ladder, .filter_cutoff = 720.0, .filter_res = 0.08, .filter_drive = 2.0,
        .fenv_attack_s = 0.002, .fenv_decay_s = 0.16, .fenv_sustain = 0.25, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.22 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 11, .depth = 0.55 },
            .{ .source = .mac4, .dest = 2, .depth = 0.2, .fx_instance_id = 2 },
        }),
        .macro_labels = macros(.{ "brightness", "layer", "", "drive" }),
        .gain = 0.89,
    }, .fx = &.{
        .{ .kind = .comp, .params = &.{ .{ .idx = 0, .value = -20 }, .{ .idx = 1, .value = 3 }, .{ .idx = 2, .value = 14 }, .{ .idx = 3, .value = 120 } } },
        .{ .kind = .sat, .params = &.{ .{ .idx = 0, .value = 5 }, .{ .idx = 2, .value = 0.1 } } },
    } },

    // vaporwave: softened electric keys with tape drift and a long tail
    .{ .name = "vapor-keys", .category = "keys", .tags = &.{ "wstudio", "vaporwave" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.3333333, .detune_cents = -5.0,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.0, .osc_b_semi = 12.0, .osc_b_detune_cents = 7.0, .osc_b_level = 0.42,
        .attack_s = 0.008, .decay_s = 1.1, .sustain = 0.18, .release_s = 1.2, .env_curve = 0.48,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.06,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21,  .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.35 },
            .{ .source = .mac1, .dest = 185, .depth = 0.3 },
            .{ .source = .mac2,     .dest = 11,  .depth = 0.22 },
            .{ .source = .mac3, .dest = 2, .depth = 0.45, .fx_instance_id = 3 },
            .{ .source = .mac4, .dest = 2, .depth = 0.28, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "layer", "space", "age" }),
        .gain = 0.26,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 12 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.14 } } },
        .{ .kind = .tape, .params = &.{ .{ .idx = 0, .value = 0.45 }, .{ .idx = 1, .value = 0.28 }, .{ .idx = 2, .value = 6 }, .{ .idx = 3, .value = 0.14 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.9 }, .{ .idx = 1, .value = 0.55 }, .{ .idx = 2, .value = 0.38 } } },
    } },

    // vaporwave: slow rounded bass with degraded sampler edges
    .{ .name = "vapor-bass", .category = "bass", .tags = &.{ "wstudio", "vaporwave" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.0, .voice_mode = .mono, .glide_s = 0.04,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 0.3333333, .osc_b_semi = 0.0, .osc_b_detune_cents = -7.0, .osc_b_level = 0.35,
        .sub_level = 0.5, .sub_shape = .sine,
        .attack_s = 0.012, .decay_s = 0.3, .sustain = 0.82, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 650.0, .filter_res = 0.08,
        .mod_matrix = mods(&.{
            .{ .source = .random,   .dest = dP,  .depth = 0.003 },
            .{ .source = .keytrack, .dest = 21, .depth = 0.18 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.35 },
            .{ .source = .mac2,     .dest = 11, .depth = 0.22 },
            .{ .source = .mac4, .dest = 2, .depth = 0.6, .fx_instance_id = 1 },
            .{ .source = .mac4, .dest = 0, .depth = -0.4, .fx_instance_id = 1 },
        }),
        .macro_labels = macros(.{ "brightness", "layer", "", "age" }),
        .gain = 0.46,
    }, .fx = &.{
        .{ .kind = .crush, .params = &.{ .{ .idx = 0, .value = 12 }, .{ .idx = 1, .value = 2 }, .{ .idx = 2, .value = 0.16 } } },
        .{ .kind = .tape, .params = &.{ .{ .idx = 0, .value = 0.35 }, .{ .idx = 1, .value = 0.2 }, .{ .idx = 2, .value = 5.5 }, .{ .idx = 3, .value = 0.08 } } },
    } },

    // anime: expressive bright lead with portamento and delayed vibrato feel
    .{ .name = "anime-lead", .category = "lead", .tags = &.{ "wstudio", "anime", "j-pop" }, .patch = .{
        .wt_table = .basic, .wt_pos = 0.6666667, .unison = 3, .unison_detune = 10.0, .unison_spread = 0.5, .voice_mode = .legato, .glide_s = 0.045,
        .osc_b_on = true, .osc_b_wt_table = .basic, .osc_b_wt_pos = 1.0, .osc_b_semi = 12.0, .osc_b_level = 0.3,
        .attack_s = 0.008, .decay_s = 0.18, .sustain = 0.82, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 5200.0, .filter_res = 0.14,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 140.0, .filter_routing = .series,
        .lfo_rate_hz = 5.6, .lfo_retrig = .key, .lfo_phase_offset = 0.25,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = dP,  .depth = 0.016 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2, .dest = 186,   .depth = -0.2 },
            .{ .source = .mac3, .dest = 2, .depth = 0.35, .fx_instance_id = 1 },
            .{ .source = .mac3, .dest = 2, .depth = 0.3, .fx_instance_id = 2 },
            .{ .source = .wheel,    .dest = 21,  .depth = 0.35 },
        }),
        .macro_labels = macros(.{ "brightness", "wave", "echo", "" }),
        .gain = 0.42,
    }, .fx = &.{
        .{ .kind = .delay, .params = &.{ .{ .idx = 0, .value = 0.28 }, .{ .idx = 1, .value = 0.3 }, .{ .idx = 2, .value = 0.18 } } },
        .{ .kind = .reverb, .params = &.{ .{ .idx = 0, .value = 0.65 }, .{ .idx = 1, .value = 0.35 }, .{ .idx = 2, .value = 0.18 } } },
    } },

};
// zig fmt: on

/// Case-insensitive lookup by name.
pub fn find(name: []const u8) ?Patch {
    for (presets) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p.patch;
    }
    return null;
}

test "factory library holds exactly 100 presets" {
    try std.testing.expectEqual(@as(usize, 100), presets.len);
}

test "every preset's matrix rows target legal dests at sane depths" {
    const fx_params = @import("fx_params.zig");
    for (presets) |p| {
        for (p.patch.mod_matrix) |row| {
            if (row.source == .none) continue;
            try std.testing.expect(@abs(row.depth) <= 1.0);
            if (row.fx_instance_id != 0) {
                // An insert route: the id is a 1-based slot in `p.fx` until
                // the chain is built, and the dest is that unit's own param
                // index, so neither is a synth param id to look up.
                errdefer std.debug.print("preset '{s}' row targets slot {d}\n", .{ p.name, row.fx_instance_id });
                try std.testing.expect(row.fx_instance_id <= p.fx.len);
                const kind = p.fx[row.fx_instance_id - 1].kind;
                try std.testing.expect(row.dest < fx_params.paramCount(kind));
                try std.testing.expect(fx_params.isAutomatable(kind, row.dest));
                continue;
            }
            const legacy_fx = if (PolySynth.findAutomatableParam(row.dest)) |param| param.modDestOnly() else false;
            try std.testing.expect(PolySynth.modDestIndex(row.dest) != null or legacy_fx);
        }
    }
}

test "every preset's declared inserts set params that exist" {
    const fx_params = @import("fx_params.zig");
    for (presets) |p| {
        for (p.fx) |spec| {
            for (spec.params) |param| {
                errdefer std.debug.print("preset '{s}' {s} param {d}\n", .{ p.name, @tagName(spec.kind), param.idx });
                try std.testing.expect(param.idx < fx_params.paramCount(spec.kind));
            }
        }
    }
}

test "every preset except init wires at least one performance macro" {
    for (presets) |p| {
        if (std.mem.eql(u8, p.name, "init")) continue;
        var has_macro = false;
        for (p.patch.mod_matrix) |row| {
            switch (row.source) {
                .mac1, .mac2, .mac3, .mac4 => has_macro = true,
                else => {},
            }
        }
        errdefer std.debug.print("preset '{s}' has no macro row\n", .{p.name});
        try std.testing.expect(has_macro);
    }
}

test "every preset renders finite, audible, bounded output" {
    for (presets) |p| {
        var s = try PolySynth.init(std.testing.allocator, 48_000);
        defer s.deinit();
        try s.applyPatchWithWavetables(p.patch);
        s.noteOn(48, 1.0);
        var buf: [512]f32 = undefined;
        var peak: f32 = 0.0;
        for (0..40) |_| {
            @memset(&buf, 0.0);
            s.processBlock(&buf);
            for (buf) |x| {
                try std.testing.expect(std.math.isFinite(x));
                peak = @max(peak, @abs(x));
            }
        }
        errdefer std.debug.print("preset '{s}' peak {d}\n", .{ p.name, peak });
        try std.testing.expect(peak > 0.005);
        try std.testing.expect(peak < 4.0);
    }
}

test "a macro label survives the patch round-trip and truncates rather than refusing" {
    var s = try PolySynth.init(std.testing.allocator, 48_000);
    defer s.deinit();
    var patch: Patch = .{};
    patch.macro_labels = macros(.{ "brightness", "", "space", "a name far past the column" });
    s.applyPatch(patch);

    try std.testing.expectEqualStrings("brightness", s.macroLabel(0).?);
    try std.testing.expect(s.macroLabel(1) == null); // empty stays unnamed
    try std.testing.expectEqualStrings("space", s.macroLabel(2).?);
    try std.testing.expectEqualStrings("a name far past", s.macroLabel(3).?);

    // And back out again, so saving a hand-tuned sound keeps the names.
    const round = s.toPatch();
    try std.testing.expectEqualStrings("brightness", round.macro_labels[0].slice());
    try std.testing.expectEqual(@as(u16, 0), PolySynth.macroSlot(99).?);
    try std.testing.expectEqual(@as(u16, 3), PolySynth.macroSlot(102).?);
    try std.testing.expect(PolySynth.macroSlot(98) == null);
}

test "every macro that does something is named, and no name sits on a dead knob" {
    for (presets) |p| {
        var wired: [4]bool = @splat(false);
        for (p.patch.mod_matrix) |row| {
            const slot: usize = switch (row.source) {
                .mac1 => 0,
                .mac2 => 1,
                .mac3 => 2,
                .mac4 => 3,
                else => continue,
            };
            if (row.depth != 0) wired[slot] = true;
        }
        for (wired, p.patch.macro_labels, 0..) |on, label, i| {
            errdefer std.debug.print("preset '{s}' macro {d}\n", .{ p.name, i + 1 });
            // A knob with routes must say what it does; a knob with none
            // must not claim to, or the name is a promise the patch cannot
            // keep. `init` is deliberately blank on both counts.
            try std.testing.expectEqual(on, label.slice().len > 0);
        }
    }
}

test "no preset cuts a sounding note fast enough to click" {
    // An amp release shorter than a few milliseconds ends the note wherever
    // the waveform happens to be, and a step from mid-cycle to zero is a
    // click - the loudest thing a quiet patch can do. Only matters when the
    // patch is still sounding at note-off, which is what sustain says.
    for (presets) |p| {
        if (p.patch.sustain <= 0.2) continue;
        errdefer std.debug.print(
            "preset '{s}' sustains at {d:.2} but releases in {d:.3}s\n",
            .{ p.name, p.patch.sustain, p.patch.release_s },
        );
        try std.testing.expect(p.patch.release_s >= 0.02);
    }
}
