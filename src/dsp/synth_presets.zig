//! Factory synth patches - curated `PolySynth.Patch` values exercising the
//! engine's oscillators, filters, envelopes, mod matrix, internal FX chain,
//! and arpeggiator. Presets cost nothing to ship: they're plain data (no
//! rendered/embedded audio), applied at runtime via `PolySynth.applyPatch`.
//! See `:synth-preset` in commands.zig.
//!
//! All patches are matrix-native: legacy fenv_amount/lfo_depth/lfo_target
//! carriers stay at their defaults and every mod route is an explicit
//! `mod_matrix` row. Dest ids used below (see `automatable_params`):
//! 1 PW A · 4 UNI DET A · 8 PW B · 11 LEVEL B · 15 MOD AMT · 21 CUTOFF ·
//! 22 RES · 34 SUB LVL · 36 NOISE LVL · 42 WARP AMT A · 47 CUTOFF 2 ·
//! 55 LEVEL C · 85 DIST MIX · 89 CRUSH MIX · 94 FLNG MIX · 107 PHSR MIX ·
//! 111 DLY MIX · 115 VRB MIX · 179 CHOR MIX · 182 FRQS SHIFT ·
//! 185 WT POS A · plus the dP/dA virtual pitch/amp dests.
//!
//! Macro convention (all four default to 0, so every patch sounds stock
//! until a knob moves): MACRO 1 = brightness (cutoff; the vowel scan on
//! formant patches), MACRO 2 = timbre motion (FM depth, pulse width, warp,
//! wavetable pos, resonance), MACRO 3 = space (delay/reverb/chorus/phaser
//! mix), MACRO 4 = grit (dist/crush mix). Only routes that fit the sound
//! are wired, but every preset except init carries at least one.

const std = @import("std");
const synth = @import("synth.zig");
const PolySynth = synth.PolySynth;
const Patch = PolySynth.Patch;
const ModRow = PolySynth.ModRow;
const dP = PolySynth.dest_pitch;
const dA = PolySynth.dest_amp;

/// Pad a row list out to a full `mod_matrix` array (comptime only).
fn mods(comptime rows: []const ModRow) [PolySynth.max_mod_rows]ModRow {
    var out = [_]ModRow{.{}} ** PolySynth.max_mod_rows;
    for (rows, 0..) |r, i| out[i] = r;
    return out;
}

/// Pad one `.custom` LFO shape's breakpoints out to a full per-slot array
/// (comptime only) - `mods`'s counterpart for LFO shapes instead of matrix
/// rows. Pair with a matching `lfo_custom_count` entry; an unused slot
/// (that LFO isn't `.custom`) can just be `lfoPoints(&.{})` since its
/// padding is never read.
fn lfoPoints(comptime points: []const synth.LfoShapePoint) [synth.max_lfo_shape_points]synth.LfoShapePoint {
    var out = [_]synth.LfoShapePoint{.{}} ** synth.max_lfo_shape_points;
    for (points, 0..) |p, i| out[i] = p;
    return out;
}

pub const Preset = struct {
    name: []const u8,
    /// Sound role, not genre - e.g. "bass", "lead", "pad".
    category: []const u8,
    /// First tag is always "wstudio"; the rest are genre associations.
    tags: []const []const u8,
    patch: Patch,
};

pub const presets = [_]Preset{
    .{ .name = "init", .category = "utility", .tags = &.{"wstudio"}, .patch = .{} },

    // zig fmt: off
    // warm-pad - HP'd low end, ensemble chorus + hall, macro 1 as a
    // brightness ride, sub-octave sine for body
    .{ .name = "warm-pad", .category = "pad", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .saw, .unison = 6, .unison_detune = 18.0, .unison_spread = 0.7,
        .osc_c_on = true, .osc_c_waveform = .sine, .osc_c_semi = -12.0, .osc_c_level = 0.35,
        .attack_s = 0.9, .decay_s = 0.6, .sustain = 0.85, .release_s = 1.4,
        .filter_type = .lp, .filter_cutoff = 2800.0, .filter_res = 0.12,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 120.0, .filter_routing = .series,
        .lfo_shape = .sine, .lfo_rate_hz = 0.25,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.06 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.5, .fx_chorus_depth_ms = 5.0, .fx_chorus_mix = 0.4,
        .fx_reverb_on = true, .fx_reverb_room = 0.75, .fx_reverb_damp = 0.4, .fx_reverb_mix = 0.25,
        .gain = 0.3,
    } },

    // pluck - ladder filter, velocity + keytrack into cutoff, dotted echo
    .{ .name = "pluck", .category = "pluck", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .triangle, .attack_s = 0.001, .decay_s = 0.18, .sustain = 0.0, .release_s = 0.12,
        .filter_type = .ladder, .filter_cutoff = 900.0, .filter_res = 0.15,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.15, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.8 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3,     .dest = 111, .depth = 0.4 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.375, .fx_delay_feedback = 0.35, .fx_delay_mix = 0.25,
        .gain = 0.35,
    } },

    // sub-bass - pure sine kept pure; light drive adds the harmonics small
    // speakers need, keytrack keeps the top of the range from dulling
    .{ .name = "sub-bass", .category = "bass", .tags = &.{ "wstudio", "house" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 500.0, .filter_res = 0.0,
        .sub_level = 0.8, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21, .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4,     .dest = 85, .depth = 0.5 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 6.0, .fx_dist_mix = 0.15,
        .gain = 0.4,
    } },

    // acid-bass - diode ladder (the 303-family filter), overdriven, with
    // velocity accent into cutoff like the real box's accent knob
    .{ .name = "acid-bass", .category = "bass", .tags = &.{ "wstudio", "acid" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.04,
        .attack_s = 0.001, .decay_s = 0.25, .sustain = 0.2, .release_s = 0.08,
        .filter_type = .diode, .filter_cutoff = 300.0, .filter_res = 0.75,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.22, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.875 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.5 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.25 },
            .{ .source = .mac4,     .dest = 85, .depth = 0.4 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 10.0, .fx_dist_mix = 0.5,
        .gain = 0.32,
    } },

    // brass-stab - third osc a sub octave down for weight, velocity opens
    // the filter for played dynamics
    .{ .name = "brass-stab", .category = "stab", .tags = &.{ "wstudio", "house" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 8.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 9.0, .osc_b_level = 0.6,
        .osc_c_on = true, .osc_c_waveform = .saw, .osc_c_semi = -12.0, .osc_c_level = 0.4,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.6, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 700.0, .filter_res = 0.1,
        .fenv_attack_s = 0.015, .fenv_decay_s = 0.35, .fenv_sustain = 0.3, .fenv_release_s = 0.2,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.625 },
            .{ .source = .velocity, .dest = 21, .depth = 0.4 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.5 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.35 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.55, .fx_reverb_damp = 0.45, .fx_reverb_mix = 0.12,
        .gain = 0.32,
    } },

    // supersaw-lead - HP'd like the JP-8000's stack, macro 1 rides the
    // cutoff, wash of delay + reverb baked in
    .{ .name = "supersaw-lead", .category = "lead", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .saw, .unison = 8, .unison_detune = 22.0, .unison_spread = 0.85,
        .attack_s = 0.01, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 6500.0, .filter_res = 0.15,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 180.0, .filter_routing = .series,
        .mod_matrix = mods(&.{
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 111, .depth = 0.4 },
            .{ .source = .mac3, .dest = 115, .depth = 0.35 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.375, .fx_delay_feedback = 0.4, .fx_delay_mix = 0.28,
        .fx_reverb_on = true, .fx_reverb_room = 0.7, .fx_reverb_damp = 0.35, .fx_reverb_mix = 0.22,
        .gain = 0.26,
    } },

    // bell-fm - velocity drives FM depth (hard hits ring brighter), plate
    // reverb tail
    .{ .name = "bell-fm", .category = "keys", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 7.0,
        .mod_mode = .fm_b_to_a, .mod_amount = 3.5,
        .attack_s = 0.001, .decay_s = 1.2, .sustain = 0.0, .release_s = 1.8,
        .filter_type = .lp, .filter_cutoff = 12_000.0, .filter_res = 0.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 15,  .depth = 0.15 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.25 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.8, .fx_reverb_damp = 0.3, .fx_reverb_mix = 0.3,
        .gain = 0.3,
    } },

    // wobble-bass - wavetable osc so the LFO scans timbre in step with the
    // filter wobble; ladder filter + drive for the low-end snarl
    .{ .name = "wobble-bass", .category = "bass", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .waveform = .wavetable, .wt_pos = 0.55, .voice_mode = .mono, .glide_s = 0.02,
        .sub_level = 0.5,
        .attack_s = 0.005, .decay_s = 0.1, .sustain = 1.0, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 400.0, .filter_res = 0.3,
        // .custom, not .triangle: the genre-defining wobble is asymmetric -
        // a fast bite open then a slower, curved close - not a symmetric
        // rise/fall. Fast attack to the peak (10% of the cycle), then a
        // two-stage decay (quick initial drop easing into a slow tail)
        // approximates that curved knee out of straight-line segments.
        .lfo_shape = .custom, .lfo_rate_hz = 4.5,
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
            .{ .source = .mac4, .dest = 85,  .depth = 0.4 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 12.0, .fx_dist_mix = 0.4,
        .gain = 0.34,
    } },

    // wind-riser - chaos LFO stirs the bandpass, ENV 3's slow ramp bends
    // pitch upward with the swell, flanger for the jet whoosh
    .{ .name = "wind-riser", .category = "fx", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .triangle, .noise_level = 0.5, .noise_color = 0.35,
        .attack_s = 2.5, .decay_s = 0.5, .sustain = 0.9, .release_s = 2.0,
        .filter_type = .bp, .filter_cutoff = 1200.0, .filter_res = 0.3,
        .lfo_shape = .chaos, .lfo_rate_hz = 0.5,
        .env3_attack_s = 3.0, .env3_decay_s = 0.5, .env3_sustain = 1.0, .env3_release_s = 1.5,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21, .depth = 0.25 },
            .{ .source = .env3, .dest = dP, .depth = 0.4 },
            .{ .source = .mac1, .dest = 21, .depth = 0.5 },
            .{ .source = .mac3, .dest = 94, .depth = 0.3 },
        }),
        .fx_flanger_on = true, .fx_flanger_rate_hz = 0.15, .fx_flanger_depth = 0.9, .fx_flanger_feedback = 0.6, .fx_flanger_mix = 0.5,
        .gain = 0.28,
    } },

    // rhodes-keys - fenv->MOD AMT gives the tine bark its own fast-decaying
    // envelope (the DX7 EP recipe, same trick as fm-epiano/shaolin-bell -
    // FM index spikes on attack and settles low for sustain, using the
    // engine's default fenv timing which is already attack-fast/decay-fast),
    // chorus like the suitcase's stereo vibrato
    .{ .name = "rhodes-keys", .category = "keys", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 14.0, .osc_b_detune_cents = 3.0,
        .mod_mode = .fm_b_to_a, .mod_amount = 1.0,
        .attack_s = 0.002, .decay_s = 1.4, .sustain = 0.25, .release_s = 0.9,
        .filter_type = .lp, .filter_cutoff = 3800.0, .filter_res = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 15,  .depth = 0.1 },
            .{ .source = .velocity, .dest = 15,  .depth = 0.15 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.25 },
            .{ .source = .mac3,     .dest = 179, .depth = 0.3 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.9, .fx_chorus_depth_ms = 4.0, .fx_chorus_mix = 0.35,
        .gain = 0.3,
    } },

    // upright-bass - finger-thump noise transient, velocity into cutoff,
    // gentle compression to even out the notes
    .{ .name = "upright-bass", .category = "bass", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .waveform = .triangle, .voice_mode = .mono, .glide_s = 0.0,
        .noise_level = 0.04, .noise_color = 0.2,
        .attack_s = 0.005, .decay_s = 0.12, .sustain = 0.6, .release_s = 0.25,
        .filter_type = .ladder, .filter_cutoff = 650.0, .filter_res = 0.05,
        .sub_level = 0.6, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 36, .depth = 0.2 },
        }),
        .fx_comp_on = true, .fx_comp_threshold_db = -20.0, .fx_comp_ratio = 3.0, .fx_comp_attack_ms = 15.0, .fx_comp_release_ms = 120.0,
        .gain = 0.4,
    } },

    // dusty-pad - bit-crush dust + tape-wobble pitch drift from LFO 2,
    // HP'd so the haze sits above the bassline
    .{ .name = "dusty-pad", .category = "pad", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .waveform = .saw, .unison = 4, .unison_detune = 10.0, .unison_spread = 0.5,
        .osc_b_on = true, .osc_b_waveform = .triangle, .osc_b_level = 0.5,
        .noise_level = 0.08, .noise_color = 0.5,
        .attack_s = 1.2, .decay_s = 0.8, .sustain = 0.6, .release_s = 1.6,
        .filter_type = .lp, .filter_cutoff = 1800.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 100.0, .filter_routing = .series,
        .lfo_shape = .sine, .lfo_rate_hz = 0.2,
        .lfo2_shape = .sine, .lfo2_rate_hz = 0.7,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.04 },
            .{ .source = .lfo2, .dest = dP,  .depth = 0.015 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
            .{ .source = .mac4, .dest = 89,  .depth = 0.4 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 12.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.25,
        .fx_reverb_on = true, .fx_reverb_room = 0.65, .fx_reverb_damp = 0.55, .fx_reverb_mix = 0.2,
        .gain = 0.25,
    } },

    // --- Drum & bass / neurofunk ---
    // reese-bass - third saw widens the beat pattern, ladder filter, macro 1
    // as the DJ-style cutoff ride, macro 2 blurs the detune wider
    .{ .name = "reese-bass", .category = "bass", .tags = &.{ "wstudio", "dnb" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 16.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = 0.0, .osc_b_detune_cents = 14.0, .osc_b_level = 0.9,
        .osc_c_on = true, .osc_c_waveform = .saw, .osc_c_semi = 0.0, .osc_c_detune_cents = -11.0, .osc_c_level = 0.7,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.006, .decay_s = 0.2, .sustain = 1.0, .release_s = 0.2,
        .filter_type = .ladder, .filter_cutoff = 700.0, .filter_res = 0.2,
        .lfo_shape = .sine, .lfo_rate_hz = 0.5,
        .sub_level = 0.3, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21, .depth = 0.125 },
            .{ .source = .mac1, .dest = 21, .depth = 0.6 },
            .{ .source = .mac2, .dest = 4,  .depth = 0.3 },
        }),
        .gain = 0.3,
    } },

    // neuro-bass - wavetable osc with sample&hold timbre flicker, formant
    // filter 2 doing the vowel talk, OTT + drive on top
    .{ .name = "neuro-bass", .category = "bass", .tags = &.{ "wstudio", "neurofunk" }, .patch = .{
        .waveform = .wavetable, .wt_pos = 0.65, .voice_mode = .mono, .glide_s = 0.01,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 0.0, .osc_b_detune_cents = 6.0, .osc_b_level = 1.0,
        .mod_mode = .fm_b_to_a, .mod_amount = 4.5,
        .attack_s = 0.004, .decay_s = 0.18, .sustain = 0.9, .release_s = 0.12,
        .filter_type = .ladder, .filter_cutoff = 550.0, .filter_res = 0.45,
        .filter2_on = true, .filter2_type = .formant, .filter2_cutoff = 400.0, .filter2_res = 0.4, .filter_routing = .series,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.2, .fenv_release_s = 0.1,
        .lfo_shape = .triangle, .lfo_rate_hz = 5.5,
        .lfo2_shape = .sh, .lfo2_rate_hz = 3.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.5 },
            .{ .source = .lfo,  .dest = 47,  .depth = 0.35 },
            .{ .source = .lfo2, .dest = 185, .depth = 0.2 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 47,  .depth = 0.4 },
            .{ .source = .mac4, .dest = 85,  .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 14.0, .fx_dist_mix = 0.5,
        .fx_ott_on = true, .fx_ott_depth = 0.6, .fx_ott_gain_out_db = -8.0,
        .gain = 0.3,
    } },

    // --- Psytrance / Goa ---
    // psy-bass - diode filter squelch, velocity + keytrack accents, a hair
    // of drive for the mid presence
    .{ .name = "psy-bass", .category = "bass", .tags = &.{ "wstudio", "psytrance" }, .patch = .{
        .waveform = .triangle, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.11, .sustain = 0.0, .release_s = 0.05,
        .filter_type = .diode, .filter_cutoff = 420.0, .filter_res = 0.15,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.09, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .sub_level = 0.7, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.375 },
            .{ .source = .velocity, .dest = 21, .depth = 0.2 },
            .{ .source = .keytrack, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4,     .dest = 85, .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 8.0, .fx_dist_mix = 0.2,
        .gain = 0.4,
    } },

    // psy-lead - diode squelch + fast triplet-ish echo
    .{ .name = "psy-lead", .category = "lead", .tags = &.{ "wstudio", "psytrance" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 12.0, .unison_spread = 0.5,
        .voice_mode = .mono, .glide_s = 0.03,
        .attack_s = 0.01, .decay_s = 0.25, .sustain = 0.7, .release_s = 0.2,
        .filter_type = .diode, .filter_cutoff = 1400.0, .filter_res = 0.6,
        .fenv_attack_s = 0.02, .fenv_decay_s = 0.3, .fenv_sustain = 0.4, .fenv_release_s = 0.2,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.7 },
            .{ .source = .lfo,  .dest = dP,  .depth = 0.15 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 111, .depth = 0.4 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.16, .fx_delay_feedback = 0.45, .fx_delay_mix = 0.3,
        .gain = 0.28,
    } },

    // --- Techno / Detroit ---
    // detroit-stab - velocity-sensitive filter hit, short room tail
    .{ .name = "detroit-stab", .category = "stab", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 10.0,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = 7.0, .osc_b_detune_cents = 6.0, .osc_b_level = 0.7,
        .attack_s = 0.008, .decay_s = 0.4, .sustain = 0.0, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 2200.0, .filter_res = 0.2,
        .fenv_attack_s = 0.005, .fenv_decay_s = 0.35, .fenv_sustain = 0.0, .fenv_release_s = 0.2,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.45 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.35 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.5, .fx_reverb_damp = 0.5, .fx_reverb_mix = 0.18,
        .gain = 0.3,
    } },

    // techno-bass - ladder filter + drive for the warehouse thump
    .{ .name = "techno-bass", .category = "bass", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.14, .sustain = 0.0, .release_s = 0.06,
        .filter_type = .ladder, .filter_cutoff = 380.0, .filter_res = 0.3,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .sub_level = 0.5, .sub_shape = .square,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.3 },
            .{ .source = .velocity, .dest = 21, .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4,     .dest = 85, .depth = 0.4 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 8.0, .fx_dist_mix = 0.3,
        .gain = 0.38,
    } },

    // --- House / disco / funk ---
    // organ-bass - harmonic-series unison stacks sine drawbars over the
    // square foundation; macro 2 pulls the fifth drawbar in
    .{ .name = "organ-bass", .category = "bass", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .waveform = .square, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.5,
        .osc_c_on = true, .osc_c_waveform = .sine, .osc_c_semi = 19.0, .osc_c_level = 0.3,
        .attack_s = 0.004, .decay_s = 0.1, .sustain = 0.9, .release_s = 0.1,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.05,
        .sub_level = 0.4, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 55, .depth = 0.4 },
        }),
        .gain = 0.34,
    } },

    // disco-bass - velocity accents + bus-style compression for the octave
    // bounce
    .{ .name = "disco-bass", .category = "bass", .tags = &.{ "wstudio", "disco" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.004, .decay_s = 0.16, .sustain = 0.5, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 800.0, .filter_res = 0.15,
        .fenv_attack_s = 0.002, .fenv_decay_s = 0.14, .fenv_sustain = 0.2, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.25 },
            .{ .source = .velocity, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.2 },
        }),
        .fx_comp_on = true, .fx_comp_threshold_db = -18.0, .fx_comp_ratio = 3.0, .fx_comp_attack_ms = 10.0, .fx_comp_release_ms = 100.0,
        .gain = 0.36,
    } },

    // ladder-bass - finally an actual ladder filter behind the name
    .{ .name = "ladder-bass", .category = "bass", .tags = &.{ "wstudio", "funk" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.015,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = -12.0, .osc_b_level = 0.7,
        .attack_s = 0.003, .decay_s = 0.2, .sustain = 0.7, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 600.0, .filter_res = 0.35,
        .fenv_attack_s = 0.002, .fenv_decay_s = 0.25, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.4 },
            .{ .source = .velocity, .dest = 21, .depth = 0.4 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.5 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.3 },
        }),
        .gain = 0.36,
    } },

    // funk-clav - the classic clav-through-phaser, velocity + keytrack
    // keep the top end percussive
    .{ .name = "funk-clav", .category = "keys", .tags = &.{ "wstudio", "funk" }, .patch = .{
        .waveform = .square, .pulse_width = 0.35,
        .attack_s = 0.002, .decay_s = 0.22, .sustain = 0.0, .release_s = 0.12,
        .filter_type = .bp, .filter_cutoff = 1600.0, .filter_res = 0.35,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.2, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.375 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.4 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 107, .depth = 0.3 },
        }),
        .fx_phaser_on = true, .fx_phaser_rate_hz = 0.5, .fx_phaser_depth = 0.8, .fx_phaser_feedback = 0.5, .fx_phaser_mix = 0.45,
        .gain = 0.32,
    } },

    // --- Dub / reggae ---
    // dub-bass - ladder-rounded, a whisper of drive for warmth
    .{ .name = "dub-bass", .category = "bass", .tags = &.{ "wstudio", "dub" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.05,
        .attack_s = 0.01, .decay_s = 0.3, .sustain = 0.9, .release_s = 0.3,
        .filter_type = .ladder, .filter_cutoff = 300.0, .filter_res = 0.1,
        .sub_level = 0.7, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4,     .dest = 85, .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 5.0, .fx_dist_mix = 0.15,
        .gain = 0.42,
    } },

    // --- Synthwave / retro 80s ---
    // synthwave-lead - ENV 3 kicks a hard-sync sweep on every attack,
    // LFO 2 supplies the vibrato, outrun delay + chorus sheen
    .{ .name = "synthwave-lead", .category = "lead", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 12.0, .unison_spread = 0.5,
        .warp_mode = .sync, .warp_amount = 0.08,
        .attack_s = 0.06, .decay_s = 0.3, .sustain = 0.8, .release_s = 0.4,
        .filter_type = .lp, .filter_cutoff = 4200.0, .filter_res = 0.1,
        .lfo2_shape = .sine, .lfo2_rate_hz = 5.5,
        .env3_attack_s = 0.001, .env3_decay_s = 0.35, .env3_sustain = 0.0, .env3_release_s = 0.2,
        .mod_matrix = mods(&.{
            .{ .source = .lfo2, .dest = dP,  .depth = 0.06 },
            .{ .source = .env3, .dest = 42,  .depth = 0.4 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 42,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 111, .depth = 0.35 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.375, .fx_delay_feedback = 0.4, .fx_delay_mix = 0.3,
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.7, .fx_chorus_depth_ms = 3.5, .fx_chorus_mix = 0.3,
        .gain = 0.28,
    } },

    // retro-brass - Juno-style chorus is the whole trick, velocity swells
    // the filter like breath pressure
    .{ .name = "retro-brass", .category = "brass", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 9.0,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.8,
        .attack_s = 0.08, .decay_s = 0.4, .sustain = 0.75, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 3000.0, .filter_res = 0.12,
        .fenv_attack_s = 0.07, .fenv_decay_s = 0.5, .fenv_sustain = 0.5, .fenv_release_s = 0.3,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.3 },
            .{ .source = .lfo,      .dest = dP,  .depth = 0.08 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.35 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 179, .depth = 0.3 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.8, .fx_chorus_depth_ms = 5.0, .fx_chorus_mix = 0.35,
        .gain = 0.28,
    } },

    // pwm-strings - real PWM at last: LFO 2 sweeps the pulse width while
    // the ensemble chorus does the Solina shimmer
    .{ .name = "pwm-strings", .category = "pad", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .waveform = .square, .pulse_width = 0.4, .unison = 4, .unison_detune = 12.0, .unison_spread = 0.6,
        .attack_s = 0.5, .decay_s = 0.6, .sustain = 0.8, .release_s = 1.0,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.08,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 150.0, .filter_routing = .series,
        .lfo_shape = .triangle, .lfo_rate_hz = 0.4,
        .lfo2_shape = .sine, .lfo2_rate_hz = 0.3,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.05 },
            .{ .source = .lfo2, .dest = 1,   .depth = 0.25 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2, .dest = 1,   .depth = 0.3 },
            .{ .source = .mac3, .dest = 179, .depth = 0.3 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.8, .fx_chorus_depth_ms = 6.0, .fx_chorus_mix = 0.5,
        .gain = 0.26,
    } },

    // --- Future bass / EDM ---
    // future-chord - OTT is the genre's whole sound; kept wide and bright
    .{ .name = "future-chord", .category = "stab", .tags = &.{ "wstudio", "future-bass" }, .patch = .{
        .waveform = .saw, .unison = 7, .unison_detune = 20.0, .unison_spread = 0.9,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.85, .release_s = 0.4,
        .filter_type = .lp, .filter_cutoff = 5000.0, .filter_res = 0.12,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.1 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_ott_on = true, .fx_ott_depth = 0.7, .fx_ott_gain_out_db = -12.0,
        .fx_reverb_on = true, .fx_reverb_room = 0.7, .fx_reverb_damp = 0.35, .fx_reverb_mix = 0.25,
        .gain = 0.24,
    } },

    // --- Chiptune / video game ---
    // chip-lead - LFO 2 flickers the duty cycle like NES channel swaps,
    // bit-crush for the console DAC grit
    .{ .name = "chip-lead", .category = "lead", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.02,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 6.0,
        .lfo2_shape = .square, .lfo2_rate_hz = 2.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP, .depth = 0.1 },
            .{ .source = .lfo2, .dest = 1,  .depth = 0.12 },
            .{ .source = .mac2, .dest = 1,  .depth = 0.3 },
            .{ .source = .mac4, .dest = 89, .depth = 0.4 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 8.0, .fx_crush_rate = 4.0, .fx_crush_mix = 0.4,
        .gain = 0.3,
    } },

    // chip-bass - crushed hard toward the NES triangle's 4-bit staircase
    .{ .name = "chip-bass", .category = "bass", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .waveform = .triangle, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.08, .sustain = 0.9, .release_s = 0.03,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .mod_matrix = mods(&.{
            .{ .source = .mac4, .dest = 89, .depth = 0.4 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 4.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.5,
        .gain = 0.38,
    } },

    // chip-arp - the built-in arpeggiator does the work now: hold a chord
    // and it rips through two octaves at 12 Hz
    .{ .name = "chip-arp", .category = "pluck", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .waveform = .square, .pulse_width = 0.25, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.06, .sustain = 0.0, .release_s = 0.02,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .arp_on = true, .arp_mode = .up, .arp_octaves = 2, .arp_rate_hz = 12.0, .arp_gate = 0.6,
        .mod_matrix = mods(&.{
            .{ .source = .mac2, .dest = 1,  .depth = 0.3 },
            .{ .source = .mac4, .dest = 89, .depth = 0.4 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 8.0, .fx_crush_rate = 3.0, .fx_crush_mix = 0.3,
        .gain = 0.3,
    } },

    // --- Ambient / downtempo ---
    // ambient-drone - dual chaos LFOs: one stirs the filter, one drifts
    // the wavetable morph; big HP'd reverb wash
    .{ .name = "ambient-drone", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .waveform = .wavetable, .wt_pos = 0.25, .unison = 5, .unison_detune = 14.0, .unison_spread = 0.8,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = -12.0, .osc_b_level = 0.5,
        .attack_s = 3.0, .decay_s = 1.0, .sustain = 0.85, .release_s = 3.5,
        .filter_type = .lp, .filter_cutoff = 1600.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 80.0, .filter_routing = .series,
        .lfo_shape = .chaos, .lfo_rate_hz = 0.3,
        .lfo2_shape = .chaos, .lfo2_rate_hz = 0.11,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.12 },
            .{ .source = .lfo2, .dest = 185, .depth = 0.25 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 185, .depth = 0.4 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.92, .fx_reverb_damp = 0.35, .fx_reverb_mix = 0.45,
        .gain = 0.24,
    } },

    // glass-pad - velocity glints the FM depth, chorus + hall around it
    .{ .name = "glass-pad", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 19.0, .osc_b_detune_cents = 4.0, .osc_b_level = 0.6,
        .mod_mode = .fm_b_to_a, .mod_amount = 1.2,
        .attack_s = 1.5, .decay_s = 1.5, .sustain = 0.6, .release_s = 2.5,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 0.3,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,      .dest = dA,  .depth = 0.05 },
            .{ .source = .velocity, .dest = 15,  .depth = 0.1 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.2 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.4, .fx_chorus_depth_ms = 5.0, .fx_chorus_mix = 0.3,
        .fx_reverb_on = true, .fx_reverb_room = 0.85, .fx_reverb_damp = 0.3, .fx_reverb_mix = 0.4,
        .gain = 0.26,
    } },

    // --- Trap ---
    // trap-bell - velocity rings the FM brighter, long dark reverb tail
    .{ .name = "trap-bell", .category = "keys", .tags = &.{ "wstudio", "trap" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 4.0, .osc_b_level = 0.9,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.6,
        .voice_mode = .mono, .glide_s = 0.06,
        .attack_s = 0.001, .decay_s = 0.6, .sustain = 0.0, .release_s = 0.5,
        .filter_type = .lp, .filter_cutoff = 9000.0, .filter_res = 0.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 15,  .depth = 0.15 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.25 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.8, .fx_reverb_damp = 0.6, .fx_reverb_mix = 0.35,
        .gain = 0.3,
    } },

    // trap-808 - ENV 3 gives the 808 pitch knock (starts ~half an octave
    // sharp and drops in), drive adds the speaker-rattle harmonics
    .{ .name = "trap-808", .category = "bass", .tags = &.{ "wstudio", "trap" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.08,
        .attack_s = 0.002, .decay_s = 0.8, .sustain = 0.4, .release_s = 0.6,
        .filter_type = .lp, .filter_cutoff = 400.0, .filter_res = 0.0,
        .sub_level = 0.8, .sub_shape = .sine,
        .env3_attack_s = 0.001, .env3_decay_s = 0.07, .env3_sustain = 0.0, .env3_release_s = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .env3, .dest = dP, .depth = 0.55 },
            .{ .source = .mac1, .dest = 21, .depth = 0.3 },
            .{ .source = .mac4, .dest = 85, .depth = 0.4 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 8.0, .fx_dist_mix = 0.2,
        .gain = 0.42,
    } },

    // --- Rave / hardcore ---
    // hoover - ENV 3 does the upward "yoy" pitch scoop the mentasm is
    // known for, third saw an octave down, phaser swirl + grit
    .{ .name = "hoover", .category = "lead", .tags = &.{ "wstudio", "rave" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 16.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_pulse_width = 0.35, .osc_b_semi = 0.0, .osc_b_detune_cents = 12.0, .osc_b_level = 0.8,
        .osc_c_on = true, .osc_c_waveform = .saw, .osc_c_semi = -12.0, .osc_c_level = 0.5,
        .voice_mode = .mono, .glide_s = 0.04,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.8, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.25,
        .lfo_shape = .sine, .lfo_rate_hz = 5.5,
        .env3_attack_s = 0.001, .env3_decay_s = 0.15, .env3_sustain = 0.0, .env3_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.18 },
            .{ .source = .env3, .dest = dP,  .depth = -0.45 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 107, .depth = 0.3 },
            .{ .source = .mac4, .dest = 85,  .depth = 0.3 },
        }),
        .fx_phaser_on = true, .fx_phaser_rate_hz = 0.6, .fx_phaser_depth = 0.8, .fx_phaser_feedback = 0.4, .fx_phaser_mix = 0.4,
        .fx_dist_on = true, .fx_dist_drive_db = 9.0, .fx_dist_mix = 0.3,
        .gain = 0.26,
    } },

    // --- Acid (open lead voicing) ---
    // acid-lead - diode ladder wide open, screamer-pedal drive, tight echo
    .{ .name = "acid-lead", .category = "lead", .tags = &.{ "wstudio", "acid" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.05,
        .attack_s = 0.001, .decay_s = 0.3, .sustain = 0.4, .release_s = 0.1,
        .filter_type = .diode, .filter_cutoff = 800.0, .filter_res = 0.82,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.28, .fenv_sustain = 0.1, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.75 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.35 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2,     .dest = 22,  .depth = 0.25 },
            .{ .source = .mac3,     .dest = 111, .depth = 0.3 },
            .{ .source = .mac4,     .dest = 85,  .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 14.0, .fx_dist_mix = 0.5,
        .fx_delay_on = true, .fx_delay_time_s = 0.19, .fx_delay_feedback = 0.4, .fx_delay_mix = 0.25,
        .gain = 0.3,
    } },

    // --- Industrial / EBM ---
    // ebm-bass - chorused like every classic EBM sequence, drive up front
    .{ .name = "ebm-bass", .category = "bass", .tags = &.{ "wstudio", "ebm" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 12.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 10.0, .osc_b_level = 0.9,
        .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.18, .sustain = 0.7, .release_s = 0.1,
        .filter_type = .lp, .filter_cutoff = 750.0, .filter_res = 0.3,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.2, .fenv_release_s = 0.08,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.45 },
            .{ .source = .velocity, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4,     .dest = 85, .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 10.0, .fx_dist_mix = 0.45,
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.6, .fx_chorus_depth_ms = 3.0, .fx_chorus_mix = 0.25,
        .gain = 0.34,
    } },

    // --- Jazz / soul ---
    // jazz-organ - harmonic-series unison stacks real drawbars, ENV 3 fakes
    // the Hammond's percussion register on the 2nd-harmonic osc; macro 2
    // pulls in the sub drawbar
    .{ .name = "jazz-organ", .category = "keys", .tags = &.{ "wstudio", "jazz" }, .patch = .{
        .waveform = .sine, .unison = 3, .unison_mode = .harmonic, .unison_detune = 100.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.4,
        .attack_s = 0.004, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 6.5,
        .env3_attack_s = 0.001, .env3_decay_s = 0.2, .env3_sustain = 0.0, .env3_release_s = 0.1,
        .sub_level = 0.3, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP, .depth = 0.06 },
            .{ .source = .env3, .dest = 11, .depth = 0.5 },
            .{ .source = .mac1, .dest = 21, .depth = 0.4 },
            .{ .source = .mac2, .dest = 34, .depth = 0.4 },
        }),
        .gain = 0.3,
    } },

    // reed-keys - velocity breathes into the FM depth, light chorus
    .{ .name = "reed-keys", .category = "keys", .tags = &.{ "wstudio", "soul" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 2.0, .osc_b_level = 0.5,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.4,
        .attack_s = 0.002, .decay_s = 1.0, .sustain = 0.2, .release_s = 0.6,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 15,  .depth = 0.12 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.2 },
            .{ .source = .mac3,     .dest = 179, .depth = 0.3 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.7, .fx_chorus_depth_ms = 3.5, .fx_chorus_mix = 0.3,
        .gain = 0.32,
    } },

    // mallet - velocity-bright strikes, small room around the bars
    .{ .name = "mallet", .category = "keys", .tags = &.{ "wstudio", "jazz" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 24.0, .osc_b_detune_cents = 2.0, .osc_b_level = 0.5,
        .mod_mode = .fm_b_to_a, .mod_amount = 1.5,
        .attack_s = 0.001, .decay_s = 0.7, .sustain = 0.0, .release_s = 0.4,
        .filter_type = .lp, .filter_cutoff = 8000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,      .dest = dA,  .depth = 0.075 },
            .{ .source = .velocity, .dest = 15,  .depth = 0.12 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.2 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.55, .fx_reverb_damp = 0.4, .fx_reverb_mix = 0.25,
        .gain = 0.3,
    } },

    // === Round 2: fill each genre's remaining core roles ===

    // trance - a rolling offbeat bass to sit under the pads/leads
    .{ .name = "trance-bass", .category = "bass", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.004, .decay_s = 0.12, .sustain = 0.6, .release_s = 0.08,
        .filter_type = .ladder, .filter_cutoff = 600.0, .filter_res = 0.15,
        .sub_level = 0.4, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.5 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.2 },
        }),
        .fx_comp_on = true, .fx_comp_threshold_db = -18.0, .fx_comp_ratio = 4.0, .fx_comp_attack_ms = 5.0, .fx_comp_release_ms = 80.0,
        .gain = 0.36,
    } },

    // house - the classic stacked-drawbar organ chord stab; harmonic unison
    // supplies the upper drawbars, ENV 3 the key-click percussion
    .{ .name = "house-organ", .category = "stab", .tags = &.{ "wstudio", "house" }, .patch = .{
        .waveform = .sine, .unison = 3, .unison_mode = .harmonic, .unison_detune = 100.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.5,
        .attack_s = 0.005, .decay_s = 0.15, .sustain = 0.8, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 5000.0, .filter_res = 0.0,
        .env3_attack_s = 0.001, .env3_decay_s = 0.12, .env3_sustain = 0.0, .env3_release_s = 0.08,
        .sub_level = 0.5, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .env3, .dest = 11, .depth = 0.4 },
            .{ .source = .mac1, .dest = 21, .depth = 0.4 },
            .{ .source = .mac2, .dest = 34, .depth = 0.4 },
        }),
        .gain = 0.3,
    } },

    // dubstep - the talking growl finally talks: a real formant filter
    // scanned by the LFO, lowpassed in series to keep it bass; macro 1 is
    // the vowel, not a plain cutoff, on this one
    .{ .name = "growl-bass", .category = "bass", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.01,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.8,
        .mod_mode = .fm_b_to_a, .mod_amount = 3.5,
        .attack_s = 0.004, .decay_s = 0.15, .sustain = 1.0, .release_s = 0.12,
        .filter_type = .formant, .filter_cutoff = 300.0, .filter_res = 0.45,
        .filter2_on = true, .filter2_type = .lp, .filter2_cutoff = 2500.0, .filter2_res = 0.2, .filter_routing = .series,
        // .custom, not .square: a square just flips between two vowel
        // extremes on/off, it doesn't "talk". Dwelling briefly at each
        // vowel with a quick transition between (not an instant flip)
        // reads as actual formant speech instead of a switch.
        .lfo_shape = .custom, .lfo_rate_hz = 6.0,
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
            .{ .source = .mac4, .dest = 85, .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 12.0, .fx_dist_mix = 0.5,
        .fx_ott_on = true, .fx_ott_depth = 0.5, .fx_ott_gain_out_db = -8.0,
        .gain = 0.32,
    } },

    // hip-hop - the whiny G-funk portamento lead. "The whine" is a slow-
    // opening filter envelope at shallow depth, not vibrato (a reconstructed
    // Dre-era patch has zero pitch-LFO on it); two tight-detuned saws stand
    // in for the real patch's +1/-1 cent pair
    .{ .name = "gfunk-lead", .category = "lead", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .waveform = .saw, .detune_cents = -1.0,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = 0.0, .osc_b_detune_cents = 1.0, .osc_b_level = 0.9,
        .voice_mode = .legato, .glide_s = 0.01,
        .attack_s = 0.001, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.02,
        .filter_type = .ladder, .filter_cutoff = 3400.0, .filter_res = 0.15,
        .fenv_attack_s = 2.15, .fenv_decay_s = 0.3, .fenv_sustain = 1.0, .fenv_release_s = 0.2,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.1 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 111, .depth = 0.35 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.28, .fx_delay_feedback = 0.3, .fx_delay_mix = 0.2,
        .gain = 0.28,
    } },

    // dnb - lush liquid pad to contrast the reese
    .{ .name = "liquid-pad", .category = "pad", .tags = &.{ "wstudio", "dnb" }, .patch = .{
        .waveform = .saw, .unison = 5, .unison_detune = 12.0, .unison_spread = 0.7,
        .osc_b_on = true, .osc_b_waveform = .triangle, .osc_b_semi = 0.0, .osc_b_level = 0.5,
        .attack_s = 0.8, .decay_s = 0.7, .sustain = 0.8, .release_s = 1.3,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.08,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 120.0, .filter_routing = .series,
        .lfo_shape = .sine, .lfo_rate_hz = 0.3,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.05 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.5, .fx_chorus_depth_ms = 5.0, .fx_chorus_mix = 0.4,
        .fx_reverb_on = true, .fx_reverb_room = 0.8, .fx_reverb_damp = 0.4, .fx_reverb_mix = 0.35,
        .gain = 0.26,
    } },

    // neurofunk - screechy resonant FM lead; a small upward frequency shift
    // smears the partials inharmonic for the metallic edge
    .{ .name = "neuro-screech", .category = "lead", .tags = &.{ "wstudio", "neurofunk" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 16.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 12.0, .osc_b_level = 0.7,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.5,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.005, .decay_s = 0.25, .sustain = 0.6, .release_s = 0.15,
        .filter_type = .diode, .filter_cutoff = 1800.0, .filter_res = 0.6,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.3, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .lfo_shape = .triangle, .lfo_rate_hz = 4.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.625 },
            .{ .source = .lfo,  .dest = 21,  .depth = 0.15 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac2, .dest = 182, .depth = 0.05 },
            .{ .source = .mac4, .dest = 85,  .depth = 0.3 },
        }),
        .fx_freq_shift_on = true, .fx_freq_shift_hz = 30.0, .fx_freq_shift_mix = 0.3,
        .fx_dist_on = true, .fx_dist_drive_db = 12.0, .fx_dist_mix = 0.5,
        .gain = 0.26,
    } },

    // psytrance - tight resonant off-beat pluck, gallop echo baked in
    .{ .name = "psy-pluck", .category = "pluck", .tags = &.{ "wstudio", "psytrance" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.12, .sustain = 0.0, .release_s = 0.06,
        .filter_type = .diode, .filter_cutoff = 1200.0, .filter_res = 0.5,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.11, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.625 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.4 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 111, .depth = 0.4 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.166, .fx_delay_feedback = 0.5, .fx_delay_mix = 0.3,
        .gain = 0.3,
    } },

    // techno - dark hypnotic pluck swimming in dub-techno echo
    .{ .name = "techno-pluck", .category = "pluck", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.14, .sustain = 0.0, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 1000.0, .filter_res = 0.3,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.06,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.375 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 111, .depth = 0.4 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.375, .fx_delay_feedback = 0.55, .fx_delay_mix = 0.35,
        .fx_reverb_on = true, .fx_reverb_room = 0.7, .fx_reverb_damp = 0.6, .fx_reverb_mix = 0.25,
        .gain = 0.3,
    } },

    // deep-house - warm electric-piano-ish chord
    .{ .name = "deep-chord", .category = "pad", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .waveform = .triangle, .unison = 2, .unison_detune = 6.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 3.0, .osc_b_level = 0.5,
        .attack_s = 0.02, .decay_s = 0.5, .sustain = 0.7, .release_s = 0.6,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.08,
        .lfo_shape = .sine, .lfo_rate_hz = 0.4,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,      .dest = 21,  .depth = 0.04 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            .{ .source = .keytrack, .dest = 21,  .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 179, .depth = 0.3 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.6, .fx_chorus_depth_ms = 4.0, .fx_chorus_mix = 0.35,
        .gain = 0.28,
    } },

    // disco - Solina-style ensemble strings; the chorus is the ensemble
    .{ .name = "disco-strings", .category = "pad", .tags = &.{ "wstudio", "disco" }, .patch = .{
        .waveform = .saw, .unison = 6, .unison_detune = 14.0, .unison_spread = 0.7,
        .attack_s = 0.15, .decay_s = 0.5, .sustain = 0.85, .release_s = 0.7,
        .filter_type = .lp, .filter_cutoff = 4000.0, .filter_res = 0.05,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 200.0, .filter_routing = .series,
        .lfo_shape = .triangle, .lfo_rate_hz = 6.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.08 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 179, .depth = 0.3 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.9, .fx_chorus_depth_ms = 6.0, .fx_chorus_mix = 0.5,
        .gain = 0.24,
    } },

    // funk - P-funk mono synth lead; ENV 3 snaps a hard-sync sweep on each
    // note for the squelchy attack
    .{ .name = "funk-lead", .category = "lead", .tags = &.{ "wstudio", "funk" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.04,
        .warp_mode = .sync, .warp_amount = 0.1,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 6.0, .osc_b_level = 0.6,
        .attack_s = 0.008, .decay_s = 0.25, .sustain = 0.7, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 1800.0, .filter_res = 0.4,
        .fenv_attack_s = 0.005, .fenv_decay_s = 0.3, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0,
        .env3_attack_s = 0.001, .env3_decay_s = 0.25, .env3_sustain = 0.0, .env3_release_s = 0.15,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.45 },
            .{ .source = .lfo,  .dest = dP,  .depth = 0.12 },
            .{ .source = .env3, .dest = 42,  .depth = 0.35 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2, .dest = 42,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 107, .depth = 0.3 },
        }),
        .fx_phaser_on = true, .fx_phaser_rate_hz = 0.4, .fx_phaser_depth = 0.8, .fx_phaser_feedback = 0.45, .fx_phaser_mix = 0.35,
        .gain = 0.28,
    } },

    // dub - reedy melodica with vibrato, sunk into King Tubby tape echo
    .{ .name = "melodica", .category = "keys", .tags = &.{ "wstudio", "dub", "reggae" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .voice_mode = .mono, .glide_s = 0.0,
        .noise_level = 0.05, .noise_color = 0.7,
        .attack_s = 0.03, .decay_s = 0.2, .sustain = 0.7, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.1,
        .lfo_shape = .sine, .lfo_rate_hz = 5.5,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.14 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 111, .depth = 0.4 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.33, .fx_delay_feedback = 0.55, .fx_delay_mix = 0.35,
        .gain = 0.3,
    } },

    // synthwave - driving outrun bass; LFO 2 breathes the B-osc duty cycle
    .{ .name = "outrun-bass", .category = "bass", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.6,
        .attack_s = 0.003, .decay_s = 0.18, .sustain = 0.8, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.15,
        .lfo2_shape = .sine, .lfo2_rate_hz = 0.4,
        .sub_level = 0.5, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .lfo2,     .dest = 8,  .depth = 0.15 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 8,  .depth = 0.2 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.7, .fx_chorus_depth_ms = 3.0, .fx_chorus_mix = 0.3,
        .gain = 0.34,
    } },

    // future-bass - bright detuned pluck to top the supersaw chords
    .{ .name = "future-pluck", .category = "pluck", .tags = &.{ "wstudio", "future-bass" }, .patch = .{
        .waveform = .triangle, .unison = 2, .unison_detune = 10.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.5,
        .attack_s = 0.002, .decay_s = 0.3, .sustain = 0.0, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 5000.0, .filter_res = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_ott_on = true, .fx_ott_depth = 0.5, .fx_ott_gain_out_db = -8.0,
        .fx_reverb_on = true, .fx_reverb_room = 0.7, .fx_reverb_damp = 0.35, .fx_reverb_mix = 0.3,
        .gain = 0.3,
    } },

    // chiptune - PWM square pad, LFO 2 on the duty cycle, light crush
    .{ .name = "chip-pad", .category = "pad", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .unison = 2, .unison_detune = 8.0,
        .attack_s = 0.3, .decay_s = 0.4, .sustain = 0.8, .release_s = 0.5,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .lfo_shape = .triangle, .lfo_rate_hz = 3.0,
        .lfo2_shape = .sine, .lfo2_rate_hz = 0.5,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP, .depth = 0.06 },
            .{ .source = .lfo2, .dest = 1,  .depth = 0.25 },
            .{ .source = .mac2, .dest = 1,  .depth = 0.3 },
            .{ .source = .mac4, .dest = 89, .depth = 0.3 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 8.0, .fx_crush_rate = 3.0, .fx_crush_mix = 0.2,
        .gain = 0.26,
    } },

    // ambient - the choir finally has vocal cords: a real formant filter
    // parked in the a/e region, slow LFO drifting the vowel, huge hall;
    // macro 1 scans vowels here rather than opening a cutoff
    .{ .name = "choir-pad", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .waveform = .saw, .unison = 4, .unison_detune = 10.0, .unison_spread = 0.6,
        .noise_level = 0.04, .noise_color = 0.6,
        .attack_s = 1.0, .decay_s = 1.0, .sustain = 0.8, .release_s = 2.0,
        .filter_type = .formant, .filter_cutoff = 80.0, .filter_res = 0.3,
        .lfo_shape = .sine, .lfo_rate_hz = 0.2,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.15 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.5, .fx_chorus_depth_ms = 5.0, .fx_chorus_mix = 0.3,
        .fx_reverb_on = true, .fx_reverb_room = 0.88, .fx_reverb_damp = 0.35, .fx_reverb_mix = 0.4,
        .gain = 0.28,
    } },

    // trap - detuned saw pluck
    .{ .name = "trap-pluck", .category = "pluck", .tags = &.{ "wstudio", "trap" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 14.0, .unison_spread = 0.5,
        .attack_s = 0.002, .decay_s = 0.25, .sustain = 0.0, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 4000.0, .filter_res = 0.12,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.7, .fx_reverb_damp = 0.55, .fx_reverb_mix = 0.25,
        .gain = 0.3,
    } },

    // rave - Mentasm-style detuned hoover stab, sub-octave saw + swirl
    .{ .name = "rave-stab", .category = "stab", .tags = &.{ "wstudio", "rave" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 18.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_pulse_width = 0.4, .osc_b_semi = 0.0, .osc_b_detune_cents = 14.0, .osc_b_level = 0.8,
        .osc_c_on = true, .osc_c_waveform = .saw, .osc_c_semi = -12.0, .osc_c_level = 0.5,
        .attack_s = 0.006, .decay_s = 0.3, .sustain = 0.0, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.25,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.28, .fenv_sustain = 0.0, .fenv_release_s = 0.15,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.375 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 107, .depth = 0.3 },
            .{ .source = .mac4, .dest = 85,  .depth = 0.3 },
        }),
        .fx_phaser_on = true, .fx_phaser_rate_hz = 0.7, .fx_phaser_depth = 0.8, .fx_phaser_feedback = 0.4, .fx_phaser_mix = 0.4,
        .fx_dist_on = true, .fx_dist_drive_db = 9.0, .fx_dist_mix = 0.35,
        .gain = 0.26,
    } },

    // ebm - ratio-mode unison turns the lead into a fifths power-chord
    // stack, driven and echoed
    .{ .name = "ebm-lead", .category = "lead", .tags = &.{ "wstudio", "ebm" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_mode = .ratio, .unison_detune = 100.0,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = -12.0, .osc_b_level = 0.6,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.005, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 2000.0, .filter_res = 0.35,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.25, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.4 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 111, .depth = 0.3 },
            .{ .source = .mac4,     .dest = 85,  .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 11.0, .fx_dist_mix = 0.4,
        .fx_delay_on = true, .fx_delay_time_s = 0.25, .fx_delay_feedback = 0.3, .fx_delay_mix = 0.2,
        .gain = 0.28,
    } },

    // jazz - breathy sine flute; blowing harder (velocity) adds breath noise
    .{ .name = "jazz-flute", .category = "lead", .tags = &.{ "wstudio", "jazz" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.02,
        .noise_level = 0.06, .noise_color = 0.8,
        .attack_s = 0.05, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 4000.0, .filter_res = 0.05,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,      .dest = dP,  .depth = 0.12 },
            .{ .source = .velocity, .dest = 36,  .depth = 0.15 },
            .{ .source = .mac2,     .dest = 36,  .depth = 0.2 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.6, .fx_reverb_damp = 0.4, .fx_reverb_mix = 0.25,
        .gain = 0.3,
    } },

    // soul - Motown horn-section stab, velocity is the section leaning in
    .{ .name = "soul-brass", .category = "brass", .tags = &.{ "wstudio", "soul" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 9.0, .unison_spread = 0.4,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.6, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.1,
        .fenv_attack_s = 0.015, .fenv_decay_s = 0.35, .fenv_sustain = 0.3, .fenv_release_s = 0.2,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.4 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 179, .depth = 0.3 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.6, .fx_chorus_depth_ms = 3.0, .fx_chorus_mix = 0.25,
        .gain = 0.28,
    } },

    // === Round 3: Japanese genres + 90s hip-hop deep dive ===

    // city-pop - glassy FM tine e-piano (the 3:1-ratio DX-style keys under
    // every late-night Tokyo track); the real DX7 EP1 patch's signature is
    // its 14:1 modulator ratio decaying fast on its OWN envelope (bright
    // attack, dull sustain) - fenv->MOD AMT reproduces that per-operator
    // envelope-over-FM-index trick; osc C adds a plain additive body layer
    // under the FM pair
    .{ .name = "fm-epiano", .category = "keys", .tags = &.{ "wstudio", "city-pop" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 19.0, .osc_b_detune_cents = 3.0, .osc_b_level = 0.8,
        .osc_c_on = true, .osc_c_waveform = .sine, .osc_c_semi = 0.0, .osc_c_level = 0.3,
        .mod_mode = .fm_b_to_a, .mod_amount = 0.9,
        .attack_s = 0.001, .decay_s = 1.2, .sustain = 0.15, .release_s = 0.5,
        .filter_type = .lp, .filter_cutoff = 6500.0, .filter_res = 0.0,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.18, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .lfo_shape = .sine, .lfo_rate_hz = 4.5,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 15,  .depth = 0.16 },
            .{ .source = .lfo,      .dest = dA,  .depth = 0.04 },
            .{ .source = .velocity, .dest = 15,  .depth = 0.2 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.25 },
            .{ .source = .mac3,     .dest = 179, .depth = 0.3 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.8, .fx_chorus_depth_ms = 4.5, .fx_chorus_mix = 0.4,
        .gain = 0.3,
    } },

    // city-pop - round funky FM knock bass, velocity-aware like a slapped
    // string, compressed tight
    .{ .name = "citypop-bass", .category = "bass", .tags = &.{ "wstudio", "city-pop" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.9,
        .mod_mode = .fm_b_to_a, .mod_amount = 1.6,
        .attack_s = 0.002, .decay_s = 0.25, .sustain = 0.35, .release_s = 0.1,
        .filter_type = .lp, .filter_cutoff = 1100.0, .filter_res = 0.1,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.06,
        .sub_level = 0.3, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.3 },
            .{ .source = .velocity, .dest = 15, .depth = 0.12 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 15, .depth = 0.2 },
        }),
        .fx_comp_on = true, .fx_comp_threshold_db = -18.0, .fx_comp_ratio = 4.0, .fx_comp_attack_ms = 8.0, .fx_comp_release_ms = 90.0,
        .gain = 0.36,
    } },

    // technopop - piercing pulse lead with fast vibrato (Rydeen-style,
    // halfway between synth and video game); LFO 2 shimmers the duty cycle
    .{ .name = "technopop-lead", .category = "lead", .tags = &.{ "wstudio", "technopop" }, .patch = .{
        .waveform = .square, .pulse_width = 0.3, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.003, .decay_s = 0.1, .sustain = 0.85, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 9000.0, .filter_res = 0.05,
        .lfo_shape = .sine, .lfo_rate_hz = 5.8,
        .lfo2_shape = .sine, .lfo2_rate_hz = 0.9,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.15 },
            .{ .source = .lfo2, .dest = 1,   .depth = 0.12 },
            .{ .source = .mac2, .dest = 1,   .depth = 0.2 },
            .{ .source = .mac3, .dest = 111, .depth = 0.35 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.25, .fx_delay_feedback = 0.3, .fx_delay_mix = 0.25,
        .gain = 0.28,
    } },

    // technopop - tight sequencer-locked analog bass
    .{ .name = "technopop-bass", .category = "bass", .tags = &.{ "wstudio", "technopop" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.09, .sustain = 0.2, .release_s = 0.05,
        .filter_type = .lp, .filter_cutoff = 750.0, .filter_res = 0.25,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.08, .fenv_sustain = 0.0, .fenv_release_s = 0.04,
        .sub_level = 0.3, .sub_shape = .square,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.35 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.2 },
        }),
        .fx_comp_on = true, .fx_comp_threshold_db = -16.0, .fx_comp_ratio = 4.0, .fx_comp_attack_ms = 5.0, .fx_comp_release_ms = 60.0,
        .gain = 0.36,
    } },

    // kawaii future bass - hyper-bright wide supersaw chord, OTT'd to the
    // ceiling like the genre demands
    .{ .name = "kawaii-chord", .category = "stab", .tags = &.{ "wstudio", "kawaii" }, .patch = .{
        .waveform = .saw, .unison = 7, .unison_detune = 24.0, .unison_spread = 0.9,
        .attack_s = 0.01, .decay_s = 0.25, .sustain = 0.9, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 7500.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 150.0, .filter_routing = .series,
        .lfo_shape = .sine, .lfo_rate_hz = 5.5,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.08 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.5 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_ott_on = true, .fx_ott_depth = 0.8, .fx_ott_gain_out_db = -16.0,
        .fx_reverb_on = true, .fx_reverb_room = 0.7, .fx_reverb_damp = 0.3, .fx_reverb_mix = 0.28,
        .gain = 0.22,
    } },

    // kawaii future bass - sparkly bell pluck on top of the chords
    .{ .name = "kawaii-pluck", .category = "pluck", .tags = &.{ "wstudio", "kawaii" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 24.0, .osc_b_detune_cents = 3.0, .osc_b_level = 0.6,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.0,
        .attack_s = 0.001, .decay_s = 0.35, .sustain = 0.0, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 10_000.0, .filter_res = 0.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 15,  .depth = 0.12 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.25 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_ott_on = true, .fx_ott_depth = 0.5, .fx_ott_gain_out_db = -8.0,
        .fx_delay_on = true, .fx_delay_time_s = 0.2, .fx_delay_feedback = 0.35, .fx_delay_mix = 0.25,
        .fx_reverb_on = true, .fx_reverb_room = 0.72, .fx_reverb_damp = 0.3, .fx_reverb_mix = 0.3,
        .gain = 0.3,
    } },

    // vaporwave - slow watery detuned pad; the dedicated tape unit now does
    // the wow+flutter directly instead of the old LFO2-S&H pitch-jitter
    // workaround (that gap closed when the tape FX unit shipped), master
    // lowpass shelf above 15kHz + a near-fully-wet plate for the source
    // material's own "heavy reverb into a wobbly chorus" recipe
    .{ .name = "vapor-pad", .category = "pad", .tags = &.{ "wstudio", "vaporwave" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 10.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_waveform = .triangle, .osc_b_semi = 0.0, .osc_b_detune_cents = 9.0, .osc_b_level = 0.7,
        .attack_s = 2.2, .decay_s = 1.0, .sustain = 0.8, .release_s = 2.8,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.08,
        .lfo_shape = .sine, .lfo_rate_hz = 0.8,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.08 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
            .{ .source = .mac4, .dest = 89,  .depth = 0.3 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 12.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.2,
        .fx_tape_on = true, .fx_tape_wow_rate_hz = 0.6, .fx_tape_wow_depth = 0.35, .fx_tape_flutter_rate_hz = 7.0, .fx_tape_flutter_depth = 0.2, .fx_tape_mix = 1.0,
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.5, .fx_chorus_depth_ms = 6.0, .fx_chorus_mix = 0.45,
        .fx_eq_on = true, .fx_eq_high_freq = 15_000.0, .fx_eq_high_gain_db = -6.0,
        .fx_reverb_on = true, .fx_reverb_room = 0.95, .fx_reverb_damp = 0.3, .fx_reverb_mix = 0.55,
        .gain = 0.24,
    } },

    // eurobeat - bright punchy unison lead, HP'd above 150Hz JP-8000-style
    // so it doesn't fight the bass, top end lifted, echo behind
    .{ .name = "eurobeat-lead", .category = "lead", .tags = &.{ "wstudio", "eurobeat" }, .patch = .{
        .waveform = .saw, .unison = 4, .unison_detune = 14.0, .unison_spread = 0.6,
        .attack_s = 0.004, .decay_s = 0.15, .sustain = 0.85, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 150.0, .filter_routing = .series,
        .lfo_shape = .sine, .lfo_rate_hz = 5.5,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,      .dest = dP,  .depth = 0.08 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3,     .dest = 111, .depth = 0.35 },
        }),
        .fx_eq_on = true, .fx_eq_high_freq = 6000.0, .fx_eq_high_gain_db = 3.0,
        .fx_delay_on = true, .fx_delay_time_s = 0.25, .fx_delay_feedback = 0.3, .fx_delay_mix = 0.25,
        .gain = 0.28,
    } },

    // eurobeat - driving octave-pump bass, compressed to sit dead center
    .{ .name = "eurobeat-bass", .category = "bass", .tags = &.{ "wstudio", "eurobeat" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = -12.0, .osc_b_level = 0.8,
        .attack_s = 0.002, .decay_s = 0.12, .sustain = 0.7, .release_s = 0.06,
        .filter_type = .lp, .filter_cutoff = 1000.0, .filter_res = 0.2,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.1, .fenv_sustain = 0.2, .fenv_release_s = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.25 },
            .{ .source = .velocity, .dest = 21, .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.2 },
        }),
        .fx_comp_on = true, .fx_comp_threshold_db = -16.0, .fx_comp_ratio = 4.0, .fx_comp_attack_ms = 5.0, .fx_comp_release_ms = 70.0,
        .gain = 0.36,
    } },

    // anime - twangy koto-style pluck; the comb filter is the string body
    // now, keytracked so the resonance follows the note; macro 2 lengthens
    // the string ring via comb feedback
    .{ .name = "koto-pluck", .category = "pluck", .tags = &.{ "wstudio", "anime" }, .patch = .{
        .waveform = .triangle,
        .noise_level = 0.1, .noise_color = 0.3,
        .attack_s = 0.001, .decay_s = 0.4, .sustain = 0.0, .release_s = 0.15,
        .filter_type = .comb, .filter_cutoff = 800.0, .filter_res = 0.55,
        .filter2_on = true, .filter2_type = .lp, .filter2_cutoff = 3500.0, .filter2_res = 0.1, .filter_routing = .series,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.08, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21, .depth = 1.0 },
            .{ .source = .fenv,     .dest = 47, .depth = 0.5 },
            .{ .source = .velocity, .dest = 36, .depth = 0.1 },
            .{ .source = .mac1,     .dest = 47, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.3 },
        }),
        .gain = 0.32,
    } },

    // g-funk - the high sine whistle lead riding over everything
    .{ .name = "whistle-lead", .category = "lead", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.05,
        .attack_s = 0.02, .decay_s = 0.2, .sustain = 0.9, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 12_000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 5.2,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.15 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
            .{ .source = .mac3, .dest = 111, .depth = 0.3 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.25, .fx_delay_feedback = 0.3, .fx_delay_mix = 0.2,
        .fx_reverb_on = true, .fx_reverb_room = 0.65, .fx_reverb_damp = 0.4, .fx_reverb_mix = 0.25,
        .gain = 0.28,
    } },

    // g-funk - the squelchy resonant portamento worm; ladder filter for the
    // Moog squelch, macro 1 is the wah pedal
    .{ .name = "funky-worm", .category = "lead", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .waveform = .triangle, .voice_mode = .mono, .glide_s = 0.1,
        .attack_s = 0.005, .decay_s = 0.3, .sustain = 0.7, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 1200.0, .filter_res = 0.55,
        .fenv_attack_s = 0.004, .fenv_decay_s = 0.25, .fenv_sustain = 0.4, .fenv_release_s = 0.12,
        .lfo2_shape = .sine, .lfo2_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21, .depth = 0.3 },
            .{ .source = .lfo2, .dest = dP, .depth = 0.04 },
            .{ .source = .mac1, .dest = 21, .depth = 0.7 },
            .{ .source = .mac2, .dest = 22, .depth = 0.3 },
        }),
        .gain = 0.28,
    } },

    // g-funk - deep gliding Moog-style low end, now on the actual ladder
    .{ .name = "gfunk-bass", .category = "bass", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.03,
        .attack_s = 0.004, .decay_s = 0.3, .sustain = 0.6, .release_s = 0.15,
        .filter_type = .ladder, .filter_cutoff = 480.0, .filter_res = 0.1,
        .sub_level = 0.6, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22, .depth = 0.2 },
        }),
        .fx_comp_on = true, .fx_comp_threshold_db = -20.0, .fx_comp_ratio = 3.0, .fx_comp_attack_ms = 12.0, .fx_comp_release_ms = 110.0,
        .gain = 0.4,
    } },

    // g-funk - dark cinematic string layer, ensemble drift from LFO 2
    .{ .name = "westcoast-strings", .category = "pad", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .patch = .{
        .waveform = .saw, .unison = 4, .unison_detune = 10.0, .unison_spread = 0.5,
        .attack_s = 0.05, .decay_s = 0.4, .sustain = 0.6, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 2800.0, .filter_res = 0.1,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 150.0, .filter_routing = .series,
        .fenv_attack_s = 0.04, .fenv_decay_s = 0.5, .fenv_sustain = 0.4, .fenv_release_s = 0.3,
        .lfo2_shape = .sine, .lfo2_rate_hz = 0.5,
        .mod_matrix = mods(&.{
            .{ .source = .fenv, .dest = 21,  .depth = 0.2 },
            .{ .source = .lfo2, .dest = dP,  .depth = 0.02 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.6, .fx_chorus_depth_ms = 5.0, .fx_chorus_mix = 0.4,
        .fx_reverb_on = true, .fx_reverb_room = 0.7, .fx_reverb_damp = 0.5, .fx_reverb_mix = 0.3,
        .gain = 0.26,
    } },

    // boom-bap - grimy dark minor keys (the QB dungeon-piano sound), put
    // through the sampler: crushed and darkened
    .{ .name = "grimy-keys", .category = "keys", .tags = &.{ "wstudio", "hip-hop", "boom-bap" }, .patch = .{
        .waveform = .triangle, .detune_cents = -4.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.4,
        .noise_level = 0.03, .noise_color = 0.4,
        .attack_s = 0.002, .decay_s = 0.9, .sustain = 0.1, .release_s = 0.4,
        .filter_type = .lp, .filter_cutoff = 2200.0, .filter_res = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac4,     .dest = 89, .depth = 0.3 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 11.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.3,
        .fx_reverb_on = true, .fx_reverb_room = 0.6, .fx_reverb_damp = 0.7, .fx_reverb_mix = 0.25,
        .gain = 0.3,
    } },

    // boom-bap - warped out-of-tune bell (dusty 36-chambers tape flavor:
    // the detuned FM partial beats against the carrier), crushed to the
    // actual measured SP-1200 spec (12-bit, ~26kHz -> downsample 2 at 48k)
    // rather than a generic heavy crush
    .{ .name = "shaolin-bell", .category = "keys", .tags = &.{ "wstudio", "hip-hop", "boom-bap" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 24.0, .osc_b_detune_cents = 18.0, .osc_b_level = 0.7,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.8,
        .attack_s = 0.001, .decay_s = 1.0, .sustain = 0.0, .release_s = 0.8,
        .filter_type = .lp, .filter_cutoff = 5000.0, .filter_res = 0.0,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 15, .depth = 0.12 },
            .{ .source = .mac2,     .dest = 15, .depth = 0.25 },
            .{ .source = .mac4,     .dest = 89, .depth = 0.3 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 12.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.35,
        .fx_reverb_on = true, .fx_reverb_room = 0.7, .fx_reverb_damp = 0.6, .fx_reverb_mix = 0.3,
        .gain = 0.28,
    } },

    // hip-hop - creepy detuned horror-movie organ (late-90s shock-rap
    // production staple); chaos LFO drifts the pitch just enough to unsettle
    .{ .name = "creep-keys", .category = "keys", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .detune_cents = 5.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 12.0, .osc_b_detune_cents = -8.0, .osc_b_level = 0.5,
        .attack_s = 0.01, .decay_s = 0.2, .sustain = 0.9, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 1500.0, .filter_res = 0.1,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0,
        .lfo2_shape = .chaos, .lfo2_rate_hz = 0.15,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dA,  .depth = 0.05 },
            .{ .source = .lfo2, .dest = dP,  .depth = 0.02 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.75, .fx_reverb_damp = 0.6, .fx_reverb_mix = 0.35,
        .gain = 0.28,
    } },

    // j-core/gabber - Mentasm-style hoover. The real Alpha Juno patch's
    // "hoovering" motion is a fast-attack/quick-release PITCH envelope
    // sweeping ~12 semitones, with the filter comparatively static - ENV 3
    // now carries that sweep at max legal depth instead of the filter env
    // doing the morph; a fast triangle LFO into PW B stands in for the
    // heavy PWM swirl on the real 3-oscillator patch
    .{ .name = "hoover-stab", .category = "stab", .tags = &.{ "wstudio", "hardcore", "gabber" }, .patch = .{
        .waveform = .saw, .unison = 4, .unison_detune = 28.0, .unison_spread = 0.85,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_pulse_width = 0.35, .osc_b_semi = 0.0, .osc_b_detune_cents = 20.0, .osc_b_level = 0.75,
        .osc_c_on = true, .osc_c_waveform = .saw, .osc_c_semi = -12.0, .osc_c_level = 0.6,
        .attack_s = 0.008, .decay_s = 0.32, .sustain = 0.15, .release_s = 0.18,
        .filter_type = .lp, .filter_cutoff = 2500.0, .filter_res = 0.4,
        .fenv_attack_s = 0.005, .fenv_decay_s = 0.28, .fenv_sustain = 0.05, .fenv_release_s = 0.15,
        .env3_attack_s = 0.006, .env3_decay_s = 0.22, .env3_sustain = 0.0, .env3_release_s = 0.06,
        .lfo_shape = .triangle, .lfo_rate_hz = 6.5,
        .mod_matrix = mods(&.{
            .{ .source = .env3, .dest = dP, .depth = 1.0 },
            .{ .source = .fenv, .dest = 21, .depth = -0.2 },
            .{ .source = .lfo,  .dest = 8,  .depth = 0.3 },
            .{ .source = .mac1, .dest = 21, .depth = 0.5 },
            .{ .source = .mac4, .dest = 85, .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 14.0, .fx_dist_mix = 0.5,
        .fx_phaser_on = true, .fx_phaser_rate_hz = 0.8, .fx_phaser_depth = 0.7, .fx_phaser_feedback = 0.4, .fx_phaser_mix = 0.35,
        .gain = 0.3,
    } },

    // hardstyle - the real technique is a formant filter vowel-scan, not a
    // resonant bandpass: heavy 7-voice unison into `.formant` with the LFO
    // sweeping cutoff a->e->i->o for the "talking" shriek, EQ bump at the
    // 500-1kHz growl band ahead of the clip stage, HP'd clean at the tail
    .{ .name = "screech-lead", .category = "lead", .tags = &.{ "wstudio", "hardstyle", "hardcore" }, .patch = .{
        .waveform = .saw, .unison = 7, .unison_detune = 32.0, .unison_spread = 0.75,
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
        .lfo_shape = .custom, .lfo_rate_hz = 3.5,
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
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21, .depth = 1.0 },
            .{ .source = .fenv, .dest = 21, .depth = 0.3 },
            .{ .source = .mac1, .dest = 21, .depth = 0.4 },
            .{ .source = .mac2, .dest = 22, .depth = 0.2 },
            .{ .source = .mac4, .dest = 85, .depth = 0.3 },
        }),
        .fx_eq_on = true, .fx_eq_mid_freq = 750.0, .fx_eq_mid_gain_db = 4.0, .fx_eq_mid_q = 1.0,
        .fx_dist_on = true, .fx_dist_drive_db = 18.0, .fx_dist_mix = 0.7,
        .fx_delay_on = true, .fx_delay_time_s = 0.19, .fx_delay_feedback = 0.3, .fx_delay_mix = 0.2,
        .gain = 0.26,
    } },

    // speedcore/terrorcore - FM-driven harsh bass, square carrier torn up by
    // audio-rate sine FM plus mirror-warp foldback; crush + drive finish it
    .{ .name = "distort-bass", .category = "bass", .tags = &.{ "wstudio", "speedcore", "terrorcore" }, .patch = .{
        .waveform = .square, .voice_mode = .mono, .glide_s = 0.0,
        .warp_mode = .mirror, .warp_amount = 0.35,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 0.0, .osc_b_level = 1.0,
        .mod_mode = .fm_b_to_a, .mod_amount = 6.5,
        .attack_s = 0.001, .decay_s = 0.08, .sustain = 0.9, .release_s = 0.05,
        .filter_type = .lp, .filter_cutoff = 1600.0, .filter_res = 0.35,
        .sub_level = 0.4, .sub_shape = .sine,
        .mod_matrix = mods(&.{
            .{ .source = .mac1, .dest = 21, .depth = 0.4 },
            .{ .source = .mac2, .dest = 42, .depth = 0.4 },
            .{ .source = .mac4, .dest = 85, .depth = 0.3 },
            .{ .source = .mac4, .dest = 89, .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 20.0, .fx_dist_mix = 0.7,
        .fx_crush_on = true, .fx_crush_bits = 6.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.3,
        .gain = 0.36,
    } },

    // happy hardcore/j-core - bright FM bell-piano stab for euphoric build
    // hits, OTT'd bright with a short hall
    .{ .name = "happy-piano", .category = "keys", .tags = &.{ "wstudio", "happy-hardcore", "j-core" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 5.0,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.2,
        .attack_s = 0.001, .decay_s = 0.5, .sustain = 0.05, .release_s = 0.35,
        .filter_type = .lp, .filter_cutoff = 9000.0, .filter_res = 0.05,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 15,  .depth = 0.15 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.25 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.4 },
        }),
        .fx_ott_on = true, .fx_ott_depth = 0.4, .fx_ott_gain_out_db = -6.0,
        .fx_reverb_on = true, .fx_reverb_room = 0.6, .fx_reverb_damp = 0.35, .fx_reverb_mix = 0.22,
        .gain = 0.3,
    } },

    // j-core/nerdcore - the arpeggiator now drives the needle-thin square
    // runs itself: hold a chord, it ping-pongs two octaves at 16 Hz
    .{ .name = "square-arp", .category = "pluck", .tags = &.{ "wstudio", "j-core", "nerdcore" }, .patch = .{
        .waveform = .square, .pulse_width = 0.35,
        .attack_s = 0.001, .decay_s = 0.07, .sustain = 0.0, .release_s = 0.04,
        .filter_type = .lp, .filter_cutoff = 12_000.0, .filter_res = 0.15,
        .arp_on = true, .arp_mode = .updown, .arp_octaves = 2, .arp_rate_hz = 16.0, .arp_gate = 0.55,
        .mod_matrix = mods(&.{
            .{ .source = .mac2, .dest = 1,   .depth = 0.2 },
            .{ .source = .mac3, .dest = 111, .depth = 0.3 },
            .{ .source = .mac4, .dest = 89,  .depth = 0.3 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 8.0, .fx_crush_rate = 3.0, .fx_crush_mix = 0.25,
        .fx_delay_on = true, .fx_delay_time_s = 0.18, .fx_delay_feedback = 0.3, .fx_delay_mix = 0.2,
        .gain = 0.26,
    } },

    // === Round 4: reinforce the least-covered genres ===

    // dnb: a short minor-chord rave hit with velocity bite and wide room
    .{ .name = "dnb-stab", .category = "stab", .tags = &.{ "wstudio", "dnb", "jungle" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 12.0, .unison_spread = 0.55,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 3.0, .osc_b_level = 0.55,
        .osc_c_on = true, .osc_c_waveform = .saw, .osc_c_semi = 7.0, .osc_c_level = 0.45,
        .attack_s = 0.003, .decay_s = 0.22, .sustain = 0.05, .release_s = 0.18,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.18,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.18, .fenv_sustain = 0.0, .fenv_release_s = 0.12,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.45 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.35 },
            .{ .source = .mac4,     .dest = 85,  .depth = 0.25 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 7.0, .fx_dist_mix = 0.12,
        .fx_reverb_on = true, .fx_reverb_room = 0.55, .fx_reverb_damp = 0.5, .fx_reverb_mix = 0.16,
        .gain = 0.28,
    } },

    // dnb: airy sampled-choir color for breakdowns and liquid intros
    .{ .name = "jungle-atmos", .category = "pad", .tags = &.{ "wstudio", "dnb", "jungle" }, .patch = .{
        .waveform = .wavetable, .wt_pos = 0.7, .unison = 4, .unison_detune = 9.0, .unison_spread = 0.75,
        .noise_level = 0.08, .noise_color = 0.65,
        .attack_s = 1.1, .decay_s = 0.8, .sustain = 0.75, .release_s = 2.2,
        .filter_type = .formant, .filter_cutoff = 520.0, .filter_res = 0.18,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 170.0, .filter_routing = .series,
        .lfo_shape = .sine, .lfo_rate_hz = 0.17,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 185, .depth = 0.12 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2, .dest = 185, .depth = 0.3 },
            .{ .source = .mac3, .dest = 115, .depth = 0.45 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.35, .fx_chorus_depth_ms = 5.0, .fx_chorus_mix = 0.3,
        .fx_reverb_on = true, .fx_reverb_room = 0.9, .fx_reverb_damp = 0.45, .fx_reverb_mix = 0.4,
        .gain = 0.24,
    } },

    // dubstep: narrow pulse lead with formant motion and controlled abrasion
    .{ .name = "talkbox-lead", .category = "lead", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .waveform = .square, .pulse_width = 0.3, .unison = 3, .unison_detune = 15.0, .voice_mode = .mono, .glide_s = 0.035,
        .attack_s = 0.004, .decay_s = 0.2, .sustain = 0.75, .release_s = 0.1,
        .filter_type = .formant, .filter_cutoff = 420.0, .filter_res = 0.5,
        // .custom, not .triangle: a talkbox's mouth motion is asymmetric
        // (open dwells longer than closed) and its own shape distinct from
        // growl-bass's harder vowel-snap above - this one loops seamlessly
        // (the last point matches the first) for a smoother "ah-wah" motion
        // instead of a hard reset each cycle.
        .lfo_shape = .custom, .lfo_rate_hz = 3.0,
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
            .{ .source = .mac2, .dest = 1,  .depth = 0.25 },
            .{ .source = .mac3, .dest = 111, .depth = 0.3 },
            .{ .source = .mac4, .dest = 85, .depth = 0.35 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 12.0, .fx_dist_mix = 0.35,
        .fx_delay_on = true, .fx_delay_time_s = 0.19, .fx_delay_feedback = 0.28, .fx_delay_mix = 0.16,
        .gain = 0.28,
    } },

    // dubstep: dark suspended pad that leaves the sub range clear
    .{ .name = "dubstep-void", .category = "pad", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .waveform = .wavetable, .wt_pos = 0.25, .unison = 5, .unison_detune = 20.0, .unison_spread = 0.85,
        .osc_b_on = true, .osc_b_waveform = .triangle, .osc_b_semi = 7.0, .osc_b_level = 0.35,
        .attack_s = 1.6, .decay_s = 0.8, .sustain = 0.8, .release_s = 2.5,
        .filter_type = .lp, .filter_cutoff = 1800.0, .filter_res = 0.2,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 220.0, .filter_routing = .series,
        .lfo2_shape = .chaos, .lfo2_rate_hz = 0.22,
        .mod_matrix = mods(&.{
            .{ .source = .lfo2, .dest = 185, .depth = 0.18 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2, .dest = 185, .depth = 0.35 },
            .{ .source = .mac3, .dest = 115, .depth = 0.45 },
            .{ .source = .mac4, .dest = 89,  .depth = 0.25 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 10.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.12,
        .fx_reverb_on = true, .fx_reverb_room = 0.9, .fx_reverb_damp = 0.55, .fx_reverb_mix = 0.38,
        .gain = 0.23,
    } },

    // future bass: elastic mono low end with a bright wavetable snap
    .{ .name = "future-bassline", .category = "bass", .tags = &.{ "wstudio", "future-bass" }, .patch = .{
        .waveform = .wavetable, .wt_pos = 0.42, .voice_mode = .mono, .glide_s = 0.025,
        .sub_level = 0.55, .sub_shape = .sine,
        .attack_s = 0.003, .decay_s = 0.16, .sustain = 0.7, .release_s = 0.1,
        .filter_type = .ladder, .filter_cutoff = 720.0, .filter_res = 0.18,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.13, .fenv_sustain = 0.2, .fenv_release_s = 0.08,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.35 },
            .{ .source = .velocity, .dest = 185, .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2,     .dest = 185, .depth = 0.4 },
            .{ .source = .mac4,     .dest = 85,  .depth = 0.3 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 8.0, .fx_dist_mix = 0.18,
        .fx_comp_on = true, .fx_comp_threshold_db = -18.0, .fx_comp_ratio = 4.0, .fx_comp_attack_ms = 6.0, .fx_comp_release_ms = 80.0,
        .gain = 0.34,
    } },

    // future bass: breathy vocal bed for wide chords and breakdowns
    .{ .name = "future-vox", .category = "pad", .tags = &.{ "wstudio", "future-bass" }, .patch = .{
        .waveform = .wavetable, .wt_pos = 0.62, .unison = 6, .unison_detune = 17.0, .unison_spread = 0.9,
        .attack_s = 0.45, .decay_s = 0.5, .sustain = 0.8, .release_s = 1.4,
        .filter_type = .formant, .filter_cutoff = 650.0, .filter_res = 0.3,
        .lfo_shape = .sine, .lfo_rate_hz = 0.3,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 21,  .depth = 0.16 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2, .dest = 185, .depth = 0.4 },
            .{ .source = .mac3, .dest = 115, .depth = 0.45 },
            .{ .source = .mac4, .dest = 85,  .depth = 0.2 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 5.0, .fx_dist_mix = 0.08,
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.5, .fx_chorus_depth_ms = 5.5, .fx_chorus_mix = 0.42,
        .fx_reverb_on = true, .fx_reverb_room = 0.85, .fx_reverb_damp = 0.35, .fx_reverb_mix = 0.32,
        .gain = 0.22,
    } },

    // deep house: muted chord pluck with a soft filter-envelope knock
    .{ .name = "deep-pluck", .category = "pluck", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .waveform = .triangle, .unison = 2, .unison_detune = 5.0, .unison_spread = 0.35,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.3,
        .attack_s = 0.002, .decay_s = 0.24, .sustain = 0.0, .release_s = 0.18,
        .filter_type = .ladder, .filter_cutoff = 780.0, .filter_res = 0.22,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.2, .fenv_sustain = 0.0, .fenv_release_s = 0.12,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21,  .depth = 0.5 },
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2,     .dest = 22,  .depth = 0.2 },
            .{ .source = .mac3,     .dest = 111, .depth = 0.35 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.33, .fx_delay_feedback = 0.26, .fx_delay_mix = 0.14,
        .gain = 0.32,
    } },

    // deep house: smooth mono lead with restrained glide and chorus
    .{ .name = "deep-lead", .category = "lead", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .waveform = .triangle, .voice_mode = .legato, .glide_s = 0.055,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_pulse_width = 0.42, .osc_b_semi = 0.0, .osc_b_level = 0.35,
        .attack_s = 0.015, .decay_s = 0.25, .sustain = 0.75, .release_s = 0.22,
        .filter_type = .lp, .filter_cutoff = 1900.0, .filter_res = 0.2,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.035 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2, .dest = 8,   .depth = 0.22 },
            .{ .source = .mac3, .dest = 179, .depth = 0.35 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.55, .fx_chorus_depth_ms = 3.5, .fx_chorus_mix = 0.22,
        .gain = 0.3,
    } },

    // dub: short minor organ chord made for long feedback-delay throws
    .{ .name = "dub-chord", .category = "stab", .tags = &.{ "wstudio", "dub", "reggae" }, .patch = .{
        .waveform = .square, .pulse_width = 0.47,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 3.0, .osc_b_level = 0.5,
        .osc_c_on = true, .osc_c_waveform = .sine, .osc_c_semi = 7.0, .osc_c_level = 0.4,
        .attack_s = 0.004, .decay_s = 0.2, .sustain = 0.0, .release_s = 0.16,
        .filter_type = .ladder, .filter_cutoff = 1300.0, .filter_res = 0.28,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21,  .depth = 0.3 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2,     .dest = 22,  .depth = 0.2 },
            .{ .source = .mac3,     .dest = 111, .depth = 0.55 },
            .{ .source = .mac4,     .dest = 85,  .depth = 0.22 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 5.0, .fx_dist_mix = 0.1,
        .fx_delay_on = true, .fx_delay_time_s = 0.5, .fx_delay_feedback = 0.58, .fx_delay_mix = 0.28,
        .gain = 0.3,
    } },

    // dub: airy bubble organ with pulse motion and spring-like ambience
    .{ .name = "bubble-organ", .category = "keys", .tags = &.{ "wstudio", "dub", "reggae" }, .patch = .{
        .waveform = .square, .pulse_width = 0.38,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.45,
        .attack_s = 0.003, .decay_s = 0.11, .sustain = 0.35, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.12,
        .lfo_shape = .sine, .lfo_rate_hz = 0.8,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = 1,   .depth = 0.12 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.4 },
            .{ .source = .mac2, .dest = 1,   .depth = 0.25 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_reverb_on = true, .fx_reverb_room = 0.45, .fx_reverb_damp = 0.65, .fx_reverb_mix = 0.2,
        .gain = 0.32,
    } },

    // soul: warm electric-piano body with velocity-controlled tine bark
    .{ .name = "soul-epiano", .category = "keys", .tags = &.{ "wstudio", "soul", "neo-soul" }, .patch = .{
        .waveform = .sine,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 14.0, .osc_b_level = 0.7,
        .mod_mode = .fm_b_to_a, .mod_amount = 0.85,
        .attack_s = 0.003, .decay_s = 1.5, .sustain = 0.3, .release_s = 1.0,
        .filter_type = .lp, .filter_cutoff = 4200.0, .filter_res = 0.04,
        .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 15,  .depth = 0.1 },
            .{ .source = .velocity, .dest = 15,  .depth = 0.16 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2,     .dest = 15,  .depth = 0.25 },
            .{ .source = .mac3,     .dest = 179, .depth = 0.35 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.7, .fx_chorus_depth_ms = 3.5, .fx_chorus_mix = 0.24,
        .gain = 0.3,
    } },

    // soul: rounded finger bass with a small upper-harmonic layer
    .{ .name = "soul-bass", .category = "bass", .tags = &.{ "wstudio", "soul", "neo-soul" }, .patch = .{
        .waveform = .triangle, .voice_mode = .mono, .glide_s = 0.012,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.2,
        .sub_level = 0.5, .sub_shape = .sine,
        .attack_s = 0.006, .decay_s = 0.18, .sustain = 0.72, .release_s = 0.16,
        .filter_type = .ladder, .filter_cutoff = 720.0, .filter_res = 0.08,
        .fenv_attack_s = 0.002, .fenv_decay_s = 0.16, .fenv_sustain = 0.25, .fenv_release_s = 0.1,
        .mod_matrix = mods(&.{
            .{ .source = .fenv,     .dest = 21, .depth = 0.22 },
            .{ .source = .velocity, .dest = 21, .depth = 0.25 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.4 },
            .{ .source = .mac2,     .dest = 11, .depth = 0.25 },
            .{ .source = .mac4,     .dest = 85, .depth = 0.2 },
        }),
        .fx_dist_on = true, .fx_dist_drive_db = 5.0, .fx_dist_mix = 0.1,
        .fx_comp_on = true, .fx_comp_threshold_db = -20.0, .fx_comp_ratio = 3.0, .fx_comp_attack_ms = 14.0, .fx_comp_release_ms = 120.0,
        .gain = 0.38,
    } },

    // vaporwave: softened electric keys with tape drift and a long tail
    .{ .name = "vapor-keys", .category = "keys", .tags = &.{ "wstudio", "vaporwave" }, .patch = .{
        .waveform = .triangle, .detune_cents = -5.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 7.0, .osc_b_level = 0.42,
        .attack_s = 0.008, .decay_s = 1.1, .sustain = 0.18, .release_s = 1.2,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.06,
        .mod_matrix = mods(&.{
            .{ .source = .velocity, .dest = 21,  .depth = 0.2 },
            .{ .source = .mac1,     .dest = 21,  .depth = 0.35 },
            .{ .source = .mac2,     .dest = 11,  .depth = 0.22 },
            .{ .source = .mac3,     .dest = 115, .depth = 0.45 },
            .{ .source = .mac4,     .dest = 89,  .depth = 0.28 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 12.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.14,
        .fx_tape_on = true, .fx_tape_wow_rate_hz = 0.45, .fx_tape_wow_depth = 0.28, .fx_tape_flutter_rate_hz = 6.0, .fx_tape_flutter_depth = 0.14, .fx_tape_mix = 1.0,
        .fx_reverb_on = true, .fx_reverb_room = 0.9, .fx_reverb_damp = 0.55, .fx_reverb_mix = 0.38,
        .gain = 0.26,
    } },

    // vaporwave: slow rounded bass with degraded sampler edges
    .{ .name = "vapor-bass", .category = "bass", .tags = &.{ "wstudio", "vaporwave" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.04,
        .osc_b_on = true, .osc_b_waveform = .triangle, .osc_b_semi = 0.0, .osc_b_detune_cents = -7.0, .osc_b_level = 0.35,
        .sub_level = 0.5, .sub_shape = .sine,
        .attack_s = 0.012, .decay_s = 0.3, .sustain = 0.82, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 650.0, .filter_res = 0.08,
        .mod_matrix = mods(&.{
            .{ .source = .keytrack, .dest = 21, .depth = 0.18 },
            .{ .source = .mac1,     .dest = 21, .depth = 0.35 },
            .{ .source = .mac2,     .dest = 11, .depth = 0.22 },
            .{ .source = .mac4,     .dest = 89, .depth = 0.3 },
        }),
        .fx_crush_on = true, .fx_crush_bits = 12.0, .fx_crush_rate = 2.0, .fx_crush_mix = 0.16,
        .fx_tape_on = true, .fx_tape_wow_rate_hz = 0.35, .fx_tape_wow_depth = 0.2, .fx_tape_flutter_rate_hz = 5.5, .fx_tape_flutter_depth = 0.08, .fx_tape_mix = 1.0,
        .gain = 0.38,
    } },

    // anime: expressive bright lead with portamento and delayed vibrato feel
    .{ .name = "anime-lead", .category = "lead", .tags = &.{ "wstudio", "anime", "j-pop" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 10.0, .unison_spread = 0.5, .voice_mode = .legato, .glide_s = 0.045,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_pulse_width = 0.4, .osc_b_semi = 12.0, .osc_b_level = 0.3,
        .attack_s = 0.008, .decay_s = 0.18, .sustain = 0.82, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 5200.0, .filter_res = 0.14,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 140.0, .filter_routing = .series,
        .lfo_shape = .sine, .lfo_rate_hz = 5.6,
        .mod_matrix = mods(&.{
            .{ .source = .lfo,  .dest = dP,  .depth = 0.06 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.45 },
            .{ .source = .mac2, .dest = 8,   .depth = 0.2 },
            .{ .source = .mac3, .dest = 111, .depth = 0.35 },
            .{ .source = .mac3, .dest = 115, .depth = 0.3 },
        }),
        .fx_delay_on = true, .fx_delay_time_s = 0.28, .fx_delay_feedback = 0.3, .fx_delay_mix = 0.18,
        .fx_reverb_on = true, .fx_reverb_room = 0.65, .fx_reverb_damp = 0.35, .fx_reverb_mix = 0.18,
        .gain = 0.27,
    } },

    // anime: glossy string ensemble for themes and emotional lifts
    .{ .name = "anime-strings", .category = "pad", .tags = &.{ "wstudio", "anime", "j-pop" }, .patch = .{
        .waveform = .saw, .unison = 5, .unison_detune = 11.0, .unison_spread = 0.78,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_pulse_width = 0.45, .osc_b_semi = 0.0, .osc_b_level = 0.35,
        .attack_s = 0.55, .decay_s = 0.5, .sustain = 0.85, .release_s = 1.5,
        .filter_type = .lp, .filter_cutoff = 3600.0, .filter_res = 0.08,
        .filter2_on = true, .filter2_type = .hp, .filter2_cutoff = 130.0, .filter_routing = .series,
        .lfo2_shape = .sine, .lfo2_rate_hz = 0.32,
        .mod_matrix = mods(&.{
            .{ .source = .lfo2, .dest = 8,   .depth = 0.16 },
            .{ .source = .mac1, .dest = 21,  .depth = 0.42 },
            .{ .source = .mac2, .dest = 8,   .depth = 0.2 },
            .{ .source = .mac3, .dest = 115, .depth = 0.4 },
        }),
        .fx_chorus_on = true, .fx_chorus_rate_hz = 0.45, .fx_chorus_depth_ms = 5.0, .fx_chorus_mix = 0.38,
        .fx_reverb_on = true, .fx_reverb_room = 0.78, .fx_reverb_damp = 0.42, .fx_reverb_mix = 0.28,
        .gain = 0.25,
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

test "factory presets are matrix-native (no legacy mod-route carriers)" {
    for (presets) |p| {
        try std.testing.expectEqual(@as(f32, 0.0), p.patch.fenv_amount);
        try std.testing.expectEqual(@as(f32, 0.0), p.patch.lfo_depth);
        try std.testing.expectEqual(synth.LfoTarget.none, p.patch.lfo_target);
    }
}

test "every preset's matrix rows target legal dests at sane depths" {
    for (presets) |p| {
        for (p.patch.mod_matrix) |row| {
            if (row.source == .none) continue;
            try std.testing.expect(PolySynth.modDestIndex(row.dest) != null);
            try std.testing.expect(@abs(row.depth) <= 1.0);
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
        s.applyPatch(p.patch);
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
        try std.testing.expect(peak < 2.0);
    }
}
