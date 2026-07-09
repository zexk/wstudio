//! Factory synth patches — curated `PolySynth.Patch` values exercising the
//! engine's oscillators, filter, envelopes, and mod matrix. Presets cost
//! nothing to ship: they're plain data (no rendered/embedded audio), applied
//! at runtime via `PolySynth.applyPatch`. See `:synth-preset` in commands.zig.

const std = @import("std");
const synth = @import("synth.zig");
const Patch = synth.PolySynth.Patch;

pub const Preset = struct {
    name: []const u8,
    /// Sound role, not genre — e.g. "bass", "lead", "pad".
    category: []const u8,
    /// First tag is always "wstudio"; the rest are genre associations.
    tags: []const []const u8,
    patch: Patch,
};

pub const presets = [_]Preset{
    .{ .name = "init", .category = "utility", .tags = &.{"wstudio"}, .patch = .{} },

    .{ .name = "warm-pad", .category = "pad", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .saw, .unison = 6, .unison_detune = 18.0, .unison_spread = 0.7,
        .attack_s = 0.9, .decay_s = 0.6, .sustain = 0.85, .release_s = 1.4,
        .filter_type = .lp, .filter_cutoff = 2800.0, .filter_res = 0.12,
        .lfo_shape = .sine, .lfo_rate_hz = 0.25, .lfo_depth = 0.12, .lfo_target = .filter,
        .gain = 0.3,
    } },

    .{ .name = "pluck", .category = "pluck", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .triangle, .attack_s = 0.001, .decay_s = 0.18, .sustain = 0.0, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.2,
        .fenv_amount = 3.2, .fenv_attack_s = 0.001, .fenv_decay_s = 0.15, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .gain = 0.35,
    } },

    .{ .name = "sub-bass", .category = "bass", .tags = &.{ "wstudio", "house" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 500.0, .filter_res = 0.0,
        .sub_level = 0.8, .sub_shape = .sine,
        .gain = 0.4,
    } },

    .{ .name = "acid-bass", .category = "bass", .tags = &.{ "wstudio", "acid" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.04,
        .attack_s = 0.001, .decay_s = 0.25, .sustain = 0.2, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 300.0, .filter_res = 0.75,
        .fenv_amount = 3.5, .fenv_attack_s = 0.001, .fenv_decay_s = 0.22, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .gain = 0.32,
    } },

    .{ .name = "brass-stab", .category = "stab", .tags = &.{ "wstudio", "house" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 8.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 9.0, .osc_b_level = 0.6,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.6, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 700.0, .filter_res = 0.1,
        .fenv_amount = 2.5, .fenv_attack_s = 0.015, .fenv_decay_s = 0.35, .fenv_sustain = 0.3, .fenv_release_s = 0.2,
        .gain = 0.32,
    } },

    .{ .name = "supersaw-lead", .category = "lead", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .saw, .unison = 8, .unison_detune = 22.0, .unison_spread = 0.85,
        .attack_s = 0.01, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 6500.0, .filter_res = 0.15,
        .gain = 0.26,
    } },

    .{ .name = "bell-fm", .category = "keys", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 7.0,
        .mod_mode = .fm_b_to_a, .mod_amount = 3.5,
        .attack_s = 0.001, .decay_s = 1.2, .sustain = 0.0, .release_s = 1.8,
        .filter_type = .lp, .filter_cutoff = 12_000.0, .filter_res = 0.0,
        .gain = 0.3,
    } },

    .{ .name = "wobble-bass", .category = "bass", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.02,
        .sub_level = 0.5,
        .attack_s = 0.005, .decay_s = 0.1, .sustain = 1.0, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 400.0, .filter_res = 0.4,
        .lfo_shape = .triangle, .lfo_rate_hz = 4.5, .lfo_depth = 0.9, .lfo_target = .filter,
        .gain = 0.34,
    } },

    .{ .name = "wind-riser", .category = "fx", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .triangle, .noise_level = 0.5, .noise_color = 0.35,
        .attack_s = 2.5, .decay_s = 0.5, .sustain = 0.9, .release_s = 2.0,
        .filter_type = .bp, .filter_cutoff = 1200.0, .filter_res = 0.3,
        .lfo_shape = .sine, .lfo_rate_hz = 0.15, .lfo_depth = 0.5, .lfo_target = .filter,
        .gain = 0.28,
    } },

    .{ .name = "rhodes-keys", .category = "keys", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 14.0, .osc_b_detune_cents = 3.0,
        .mod_mode = .fm_b_to_a, .mod_amount = 1.8,
        .attack_s = 0.002, .decay_s = 1.4, .sustain = 0.25, .release_s = 0.9,
        .filter_type = .lp, .filter_cutoff = 3800.0, .filter_res = 0.05,
        .gain = 0.3,
    } },

    .{ .name = "upright-bass", .category = "bass", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .waveform = .triangle, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.005, .decay_s = 0.12, .sustain = 0.6, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 650.0, .filter_res = 0.05,
        .sub_level = 0.6, .sub_shape = .sine,
        .gain = 0.4,
    } },

    .{ .name = "dusty-pad", .category = "pad", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .waveform = .saw, .unison = 4, .unison_detune = 10.0, .unison_spread = 0.5,
        .osc_b_on = true, .osc_b_waveform = .triangle, .osc_b_level = 0.5,
        .noise_level = 0.08, .noise_color = 0.5,
        .attack_s = 1.2, .decay_s = 0.8, .sustain = 0.6, .release_s = 1.6,
        .filter_type = .lp, .filter_cutoff = 1800.0, .filter_res = 0.1,
        .lfo_shape = .sine, .lfo_rate_hz = 0.2, .lfo_depth = 0.08, .lfo_target = .filter,
        .gain = 0.25,
    } },

    // --- Drum & bass / neurofunk ---
    .{ .name = "reese-bass", .category = "bass", .tags = &.{ "wstudio", "dnb" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 16.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = 0.0, .osc_b_detune_cents = 14.0, .osc_b_level = 0.9,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.006, .decay_s = 0.2, .sustain = 1.0, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 700.0, .filter_res = 0.2,
        .lfo_shape = .sine, .lfo_rate_hz = 0.5, .lfo_depth = 0.25, .lfo_target = .filter,
        .sub_level = 0.3, .sub_shape = .sine,
        .gain = 0.3,
    } },

    .{ .name = "neuro-bass", .category = "bass", .tags = &.{ "wstudio", "neurofunk" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.01,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 0.0, .osc_b_detune_cents = 6.0, .osc_b_level = 1.0,
        .mod_mode = .fm_b_to_a, .mod_amount = 4.5,
        .attack_s = 0.004, .decay_s = 0.18, .sustain = 0.9, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 550.0, .filter_res = 0.6,
        .fenv_amount = 2.0, .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.2, .fenv_release_s = 0.1,
        .lfo_shape = .triangle, .lfo_rate_hz = 5.5, .lfo_depth = 0.5, .lfo_target = .filter,
        .gain = 0.3,
    } },

    // --- Psytrance / Goa ---
    .{ .name = "psy-bass", .category = "bass", .tags = &.{ "wstudio", "psytrance" }, .patch = .{
        .waveform = .triangle, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.11, .sustain = 0.0, .release_s = 0.05,
        .filter_type = .lp, .filter_cutoff = 420.0, .filter_res = 0.15,
        .fenv_amount = 1.5, .fenv_attack_s = 0.001, .fenv_decay_s = 0.09, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .sub_level = 0.7, .sub_shape = .sine,
        .gain = 0.4,
    } },

    .{ .name = "psy-lead", .category = "lead", .tags = &.{ "wstudio", "psytrance" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 12.0, .unison_spread = 0.5,
        .voice_mode = .mono, .glide_s = 0.03,
        .attack_s = 0.01, .decay_s = 0.25, .sustain = 0.7, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 1400.0, .filter_res = 0.7,
        .fenv_amount = 2.8, .fenv_attack_s = 0.02, .fenv_decay_s = 0.3, .fenv_sustain = 0.4, .fenv_release_s = 0.2,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0, .lfo_depth = 0.15, .lfo_target = .pitch,
        .gain = 0.28,
    } },

    // --- Techno / Detroit ---
    .{ .name = "detroit-stab", .category = "stab", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 10.0,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = 7.0, .osc_b_detune_cents = 6.0, .osc_b_level = 0.7,
        .attack_s = 0.008, .decay_s = 0.4, .sustain = 0.0, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 2200.0, .filter_res = 0.2,
        .fenv_amount = 1.8, .fenv_attack_s = 0.005, .fenv_decay_s = 0.35, .fenv_sustain = 0.0, .fenv_release_s = 0.2,
        .gain = 0.3,
    } },

    .{ .name = "techno-bass", .category = "bass", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.14, .sustain = 0.0, .release_s = 0.06,
        .filter_type = .lp, .filter_cutoff = 380.0, .filter_res = 0.3,
        .fenv_amount = 1.2, .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .sub_level = 0.5, .sub_shape = .square,
        .gain = 0.38,
    } },

    // --- House / disco / funk ---
    .{ .name = "organ-bass", .category = "bass", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .waveform = .square, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.5,
        .attack_s = 0.004, .decay_s = 0.1, .sustain = 0.9, .release_s = 0.1,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.05,
        .sub_level = 0.4, .sub_shape = .sine,
        .gain = 0.34,
    } },

    .{ .name = "disco-bass", .category = "bass", .tags = &.{ "wstudio", "disco" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.004, .decay_s = 0.16, .sustain = 0.5, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 800.0, .filter_res = 0.15,
        .fenv_amount = 1.0, .fenv_attack_s = 0.002, .fenv_decay_s = 0.14, .fenv_sustain = 0.2, .fenv_release_s = 0.1,
        .gain = 0.36,
    } },

    .{ .name = "moog-bass", .category = "bass", .tags = &.{ "wstudio", "funk" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.015,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = -12.0, .osc_b_level = 0.7,
        .attack_s = 0.003, .decay_s = 0.2, .sustain = 0.7, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 600.0, .filter_res = 0.35,
        .fenv_amount = 1.6, .fenv_attack_s = 0.002, .fenv_decay_s = 0.25, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .gain = 0.36,
    } },

    .{ .name = "funk-clav", .category = "keys", .tags = &.{ "wstudio", "funk" }, .patch = .{
        .waveform = .square, .pulse_width = 0.35,
        .attack_s = 0.002, .decay_s = 0.22, .sustain = 0.0, .release_s = 0.12,
        .filter_type = .bp, .filter_cutoff = 1600.0, .filter_res = 0.35,
        .fenv_amount = 1.5, .fenv_attack_s = 0.001, .fenv_decay_s = 0.2, .fenv_sustain = 0.0, .fenv_release_s = 0.1,
        .gain = 0.32,
    } },

    // --- Dub / reggae ---
    .{ .name = "dub-bass", .category = "bass", .tags = &.{ "wstudio", "dub" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.05,
        .attack_s = 0.01, .decay_s = 0.3, .sustain = 0.9, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 300.0, .filter_res = 0.1,
        .sub_level = 0.7, .sub_shape = .sine,
        .gain = 0.42,
    } },

    // --- Synthwave / retro 80s ---
    .{ .name = "synthwave-lead", .category = "lead", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 12.0, .unison_spread = 0.5,
        .attack_s = 0.06, .decay_s = 0.3, .sustain = 0.8, .release_s = 0.4,
        .filter_type = .lp, .filter_cutoff = 4200.0, .filter_res = 0.1,
        .lfo_shape = .sine, .lfo_rate_hz = 5.5, .lfo_depth = 0.12, .lfo_target = .pitch,
        .gain = 0.28,
    } },

    .{ .name = "retro-brass", .category = "brass", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 9.0,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.8,
        .attack_s = 0.08, .decay_s = 0.4, .sustain = 0.75, .release_s = 0.3,
        .filter_type = .lp, .filter_cutoff = 3000.0, .filter_res = 0.12,
        .fenv_amount = 1.2, .fenv_attack_s = 0.07, .fenv_decay_s = 0.5, .fenv_sustain = 0.5, .fenv_release_s = 0.3,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0, .lfo_depth = 0.08, .lfo_target = .pitch,
        .gain = 0.28,
    } },

    .{ .name = "pwm-strings", .category = "pad", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .waveform = .square, .pulse_width = 0.4, .unison = 4, .unison_detune = 12.0, .unison_spread = 0.6,
        .attack_s = 0.5, .decay_s = 0.6, .sustain = 0.8, .release_s = 1.0,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.08,
        .lfo_shape = .triangle, .lfo_rate_hz = 0.4, .lfo_depth = 0.1, .lfo_target = .filter,
        .gain = 0.26,
    } },

    // --- Future bass / EDM ---
    .{ .name = "future-chord", .category = "stab", .tags = &.{ "wstudio", "future-bass" }, .patch = .{
        .waveform = .saw, .unison = 7, .unison_detune = 20.0, .unison_spread = 0.9,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.85, .release_s = 0.4,
        .filter_type = .lp, .filter_cutoff = 5000.0, .filter_res = 0.12,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0, .lfo_depth = 0.12, .lfo_target = .pitch,
        .gain = 0.24,
    } },

    // --- Chiptune / video game ---
    .{ .name = "chip-lead", .category = "lead", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.02,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 6.0, .lfo_depth = 0.1, .lfo_target = .pitch,
        .gain = 0.3,
    } },

    .{ .name = "chip-bass", .category = "bass", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .waveform = .triangle, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.08, .sustain = 0.9, .release_s = 0.03,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .gain = 0.38,
    } },

    .{ .name = "chip-arp", .category = "pluck", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .waveform = .square, .pulse_width = 0.25, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.06, .sustain = 0.0, .release_s = 0.02,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .gain = 0.3,
    } },

    // --- Ambient / downtempo ---
    .{ .name = "ambient-drone", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .waveform = .saw, .unison = 5, .unison_detune = 14.0, .unison_spread = 0.8,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = -12.0, .osc_b_level = 0.5,
        .attack_s = 3.0, .decay_s = 1.0, .sustain = 0.85, .release_s = 3.5,
        .filter_type = .lp, .filter_cutoff = 1600.0, .filter_res = 0.1,
        .lfo_shape = .sine, .lfo_rate_hz = 0.1, .lfo_depth = 0.15, .lfo_target = .filter,
        .gain = 0.24,
    } },

    .{ .name = "glass-pad", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 19.0, .osc_b_detune_cents = 4.0, .osc_b_level = 0.6,
        .mod_mode = .fm_b_to_a, .mod_amount = 1.2,
        .attack_s = 1.5, .decay_s = 1.5, .sustain = 0.6, .release_s = 2.5,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 0.3, .lfo_depth = 0.1, .lfo_target = .amp,
        .gain = 0.26,
    } },

    // --- Trap ---
    .{ .name = "trap-bell", .category = "keys", .tags = &.{ "wstudio", "trap" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 4.0, .osc_b_level = 0.9,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.6,
        .voice_mode = .mono, .glide_s = 0.06,
        .attack_s = 0.001, .decay_s = 0.6, .sustain = 0.0, .release_s = 0.5,
        .filter_type = .lp, .filter_cutoff = 9000.0, .filter_res = 0.0,
        .gain = 0.3,
    } },

    .{ .name = "trap-808", .category = "bass", .tags = &.{ "wstudio", "trap" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.08,
        .attack_s = 0.002, .decay_s = 0.8, .sustain = 0.4, .release_s = 0.6,
        .filter_type = .lp, .filter_cutoff = 400.0, .filter_res = 0.0,
        .fenv_amount = 0.8, .fenv_attack_s = 0.001, .fenv_decay_s = 0.05, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .sub_level = 0.8, .sub_shape = .sine,
        .gain = 0.42,
    } },

    // --- Rave / hardcore ---
    .{ .name = "hoover", .category = "lead", .tags = &.{ "wstudio", "rave" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 16.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_pulse_width = 0.35, .osc_b_semi = 0.0, .osc_b_detune_cents = 12.0, .osc_b_level = 0.8,
        .voice_mode = .mono, .glide_s = 0.04,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.8, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.25,
        .lfo_shape = .sine, .lfo_rate_hz = 5.5, .lfo_depth = 0.2, .lfo_target = .pitch,
        .gain = 0.26,
    } },

    // --- Acid (open lead voicing) ---
    .{ .name = "acid-lead", .category = "lead", .tags = &.{ "wstudio", "acid" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.05,
        .attack_s = 0.001, .decay_s = 0.3, .sustain = 0.4, .release_s = 0.1,
        .filter_type = .lp, .filter_cutoff = 800.0, .filter_res = 0.82,
        .fenv_amount = 3.0, .fenv_attack_s = 0.001, .fenv_decay_s = 0.28, .fenv_sustain = 0.1, .fenv_release_s = 0.1,
        .gain = 0.3,
    } },

    // --- Industrial / EBM ---
    .{ .name = "ebm-bass", .category = "bass", .tags = &.{ "wstudio", "ebm" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 12.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 10.0, .osc_b_level = 0.9,
        .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.002, .decay_s = 0.18, .sustain = 0.7, .release_s = 0.1,
        .filter_type = .lp, .filter_cutoff = 750.0, .filter_res = 0.3,
        .fenv_amount = 1.8, .fenv_attack_s = 0.001, .fenv_decay_s = 0.16, .fenv_sustain = 0.2, .fenv_release_s = 0.08,
        .gain = 0.34,
    } },

    // --- Jazz / soul ---
    .{ .name = "jazz-organ", .category = "keys", .tags = &.{ "wstudio", "jazz" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.7,
        .attack_s = 0.004, .decay_s = 0.05, .sustain = 1.0, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 6000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 6.5, .lfo_depth = 0.06, .lfo_target = .pitch,
        .sub_level = 0.3, .sub_shape = .sine,
        .gain = 0.3,
    } },

    .{ .name = "wurli", .category = "keys", .tags = &.{ "wstudio", "soul" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 2.0, .osc_b_level = 0.5,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.4,
        .attack_s = 0.002, .decay_s = 1.0, .sustain = 0.2, .release_s = 0.6,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.05,
        .gain = 0.32,
    } },

    .{ .name = "mallet", .category = "keys", .tags = &.{ "wstudio", "jazz" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 24.0, .osc_b_detune_cents = 2.0, .osc_b_level = 0.5,
        .mod_mode = .fm_b_to_a, .mod_amount = 1.5,
        .attack_s = 0.001, .decay_s = 0.7, .sustain = 0.0, .release_s = 0.4,
        .filter_type = .lp, .filter_cutoff = 8000.0, .filter_res = 0.0,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0, .lfo_depth = 0.15, .lfo_target = .amp,
        .gain = 0.3,
    } },

    // === Round 2: fill each genre's remaining core roles ===

    // trance — a rolling offbeat bass to sit under the pads/leads
    .{ .name = "trance-bass", .category = "bass", .tags = &.{ "wstudio", "trance" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.004, .decay_s = 0.12, .sustain = 0.6, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 600.0, .filter_res = 0.15,
        .sub_level = 0.4, .sub_shape = .sine,
        .gain = 0.36,
    } },

    // house — the classic stacked-drawbar organ chord stab
    .{ .name = "house-organ", .category = "stab", .tags = &.{ "wstudio", "house" }, .patch = .{
        .waveform = .sine, .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.7,
        .attack_s = 0.005, .decay_s = 0.15, .sustain = 0.8, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 5000.0, .filter_res = 0.0,
        .sub_level = 0.5, .sub_shape = .sine,
        .gain = 0.3,
    } },

    // dubstep — the talking/formant growl to pair with wobble-bass
    .{ .name = "growl-bass", .category = "bass", .tags = &.{ "wstudio", "dubstep" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.01,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.8,
        .mod_mode = .fm_b_to_a, .mod_amount = 3.5,
        .attack_s = 0.004, .decay_s = 0.15, .sustain = 1.0, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 500.0, .filter_res = 0.55,
        .lfo_shape = .square, .lfo_rate_hz = 6.0, .lfo_depth = 0.7, .lfo_target = .filter,
        .gain = 0.32,
    } },

    // hip-hop — the whiny G-funk portamento lead
    .{ .name = "gfunk-lead", .category = "lead", .tags = &.{ "wstudio", "hip-hop" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.06,
        .attack_s = 0.01, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 3500.0, .filter_res = 0.2,
        .lfo_shape = .sine, .lfo_rate_hz = 5.5, .lfo_depth = 0.18, .lfo_target = .pitch,
        .gain = 0.28,
    } },

    // dnb — lush liquid pad to contrast the reese
    .{ .name = "liquid-pad", .category = "pad", .tags = &.{ "wstudio", "dnb" }, .patch = .{
        .waveform = .saw, .unison = 5, .unison_detune = 12.0, .unison_spread = 0.7,
        .osc_b_on = true, .osc_b_waveform = .triangle, .osc_b_semi = 0.0, .osc_b_level = 0.5,
        .attack_s = 0.8, .decay_s = 0.7, .sustain = 0.8, .release_s = 1.3,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.08,
        .lfo_shape = .sine, .lfo_rate_hz = 0.3, .lfo_depth = 0.1, .lfo_target = .filter,
        .gain = 0.26,
    } },

    // neurofunk — screechy resonant FM lead
    .{ .name = "neuro-screech", .category = "lead", .tags = &.{ "wstudio", "neurofunk" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 16.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 12.0, .osc_b_level = 0.7,
        .mod_mode = .fm_b_to_a, .mod_amount = 2.5,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.005, .decay_s = 0.25, .sustain = 0.6, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 1800.0, .filter_res = 0.6,
        .fenv_amount = 2.5, .fenv_attack_s = 0.004, .fenv_decay_s = 0.3, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .lfo_shape = .triangle, .lfo_rate_hz = 4.0, .lfo_depth = 0.3, .lfo_target = .filter,
        .gain = 0.26,
    } },

    // psytrance — tight resonant off-beat pluck
    .{ .name = "psy-pluck", .category = "pluck", .tags = &.{ "wstudio", "psytrance" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.12, .sustain = 0.0, .release_s = 0.06,
        .filter_type = .lp, .filter_cutoff = 1200.0, .filter_res = 0.6,
        .fenv_amount = 2.5, .fenv_attack_s = 0.001, .fenv_decay_s = 0.11, .fenv_sustain = 0.0, .fenv_release_s = 0.05,
        .gain = 0.3,
    } },

    // techno — dark hypnotic pluck
    .{ .name = "techno-pluck", .category = "pluck", .tags = &.{ "wstudio", "techno" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .voice_mode = .mono, .glide_s = 0.0,
        .attack_s = 0.001, .decay_s = 0.14, .sustain = 0.0, .release_s = 0.08,
        .filter_type = .lp, .filter_cutoff = 1000.0, .filter_res = 0.3,
        .fenv_amount = 1.5, .fenv_attack_s = 0.001, .fenv_decay_s = 0.12, .fenv_sustain = 0.0, .fenv_release_s = 0.06,
        .gain = 0.3,
    } },

    // deep-house — warm electric-piano-ish chord
    .{ .name = "deep-chord", .category = "pad", .tags = &.{ "wstudio", "deep-house" }, .patch = .{
        .waveform = .triangle, .unison = 2, .unison_detune = 6.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_detune_cents = 3.0, .osc_b_level = 0.5,
        .attack_s = 0.02, .decay_s = 0.5, .sustain = 0.7, .release_s = 0.6,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.08,
        .lfo_shape = .sine, .lfo_rate_hz = 0.4, .lfo_depth = 0.08, .lfo_target = .filter,
        .gain = 0.28,
    } },

    // disco — Solina-style ensemble strings
    .{ .name = "disco-strings", .category = "pad", .tags = &.{ "wstudio", "disco" }, .patch = .{
        .waveform = .saw, .unison = 6, .unison_detune = 14.0, .unison_spread = 0.7,
        .attack_s = 0.15, .decay_s = 0.5, .sustain = 0.85, .release_s = 0.7,
        .filter_type = .lp, .filter_cutoff = 4000.0, .filter_res = 0.05,
        .lfo_shape = .triangle, .lfo_rate_hz = 6.0, .lfo_depth = 0.08, .lfo_target = .pitch,
        .gain = 0.24,
    } },

    // funk — P-funk mono synth lead
    .{ .name = "funk-lead", .category = "lead", .tags = &.{ "wstudio", "funk" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.04,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 6.0, .osc_b_level = 0.6,
        .attack_s = 0.008, .decay_s = 0.25, .sustain = 0.7, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 1800.0, .filter_res = 0.4,
        .fenv_amount = 1.8, .fenv_attack_s = 0.005, .fenv_decay_s = 0.3, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0, .lfo_depth = 0.12, .lfo_target = .pitch,
        .gain = 0.28,
    } },

    // dub — reedy melodica with vibrato (Augustus Pablo staple)
    .{ .name = "melodica", .category = "keys", .tags = &.{ "wstudio", "dub" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .voice_mode = .mono, .glide_s = 0.0,
        .noise_level = 0.05, .noise_color = 0.7,
        .attack_s = 0.03, .decay_s = 0.2, .sustain = 0.7, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 2400.0, .filter_res = 0.1,
        .lfo_shape = .sine, .lfo_rate_hz = 5.5, .lfo_depth = 0.14, .lfo_target = .pitch,
        .gain = 0.3,
    } },

    // synthwave — driving outrun bass
    .{ .name = "outrun-bass", .category = "bass", .tags = &.{ "wstudio", "synthwave" }, .patch = .{
        .waveform = .saw, .voice_mode = .mono, .glide_s = 0.0,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_semi = 0.0, .osc_b_detune_cents = 8.0, .osc_b_level = 0.6,
        .attack_s = 0.003, .decay_s = 0.18, .sustain = 0.8, .release_s = 0.12,
        .filter_type = .lp, .filter_cutoff = 900.0, .filter_res = 0.15,
        .sub_level = 0.5, .sub_shape = .sine,
        .gain = 0.34,
    } },

    // future-bass — bright detuned pluck to top the supersaw chords
    .{ .name = "future-pluck", .category = "pluck", .tags = &.{ "wstudio", "future-bass" }, .patch = .{
        .waveform = .triangle, .unison = 2, .unison_detune = 10.0,
        .osc_b_on = true, .osc_b_waveform = .sine, .osc_b_semi = 12.0, .osc_b_level = 0.5,
        .attack_s = 0.002, .decay_s = 0.3, .sustain = 0.0, .release_s = 0.25,
        .filter_type = .lp, .filter_cutoff = 5000.0, .filter_res = 0.1,
        .gain = 0.3,
    } },

    // chiptune — PWM square pad
    .{ .name = "chip-pad", .category = "pad", .tags = &.{ "wstudio", "chiptune" }, .patch = .{
        .waveform = .square, .pulse_width = 0.5, .unison = 2, .unison_detune = 8.0,
        .attack_s = 0.3, .decay_s = 0.4, .sustain = 0.8, .release_s = 0.5,
        .filter_type = .lp, .filter_cutoff = 18_000.0, .filter_res = 0.0,
        .lfo_shape = .triangle, .lfo_rate_hz = 3.0, .lfo_depth = 0.06, .lfo_target = .pitch,
        .gain = 0.26,
    } },

    // ambient — voice-like formant choir pad
    .{ .name = "choir-pad", .category = "pad", .tags = &.{ "wstudio", "ambient" }, .patch = .{
        .waveform = .saw, .unison = 4, .unison_detune = 10.0, .unison_spread = 0.6,
        .noise_level = 0.04, .noise_color = 0.6,
        .attack_s = 1.0, .decay_s = 1.0, .sustain = 0.8, .release_s = 2.0,
        .filter_type = .bp, .filter_cutoff = 1000.0, .filter_res = 0.35,
        .lfo_shape = .sine, .lfo_rate_hz = 4.5, .lfo_depth = 0.1, .lfo_target = .pitch,
        .gain = 0.26,
    } },

    // trap — detuned saw pluck
    .{ .name = "trap-pluck", .category = "pluck", .tags = &.{ "wstudio", "trap" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 14.0, .unison_spread = 0.5,
        .attack_s = 0.002, .decay_s = 0.25, .sustain = 0.0, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 4000.0, .filter_res = 0.12,
        .gain = 0.3,
    } },

    // rave — Mentasm-style detuned hoover stab
    .{ .name = "rave-stab", .category = "stab", .tags = &.{ "wstudio", "rave" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 18.0, .unison_spread = 0.6,
        .osc_b_on = true, .osc_b_waveform = .square, .osc_b_pulse_width = 0.4, .osc_b_semi = 0.0, .osc_b_detune_cents = 14.0, .osc_b_level = 0.8,
        .attack_s = 0.006, .decay_s = 0.3, .sustain = 0.0, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 2600.0, .filter_res = 0.25,
        .fenv_amount = 1.5, .fenv_attack_s = 0.004, .fenv_decay_s = 0.28, .fenv_sustain = 0.0, .fenv_release_s = 0.15,
        .gain = 0.26,
    } },

    // ebm — hard detuned saw lead
    .{ .name = "ebm-lead", .category = "lead", .tags = &.{ "wstudio", "ebm" }, .patch = .{
        .waveform = .saw, .unison = 2, .unison_detune = 14.0,
        .osc_b_on = true, .osc_b_waveform = .saw, .osc_b_semi = -12.0, .osc_b_level = 0.6,
        .voice_mode = .mono, .glide_s = 0.02,
        .attack_s = 0.005, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.15,
        .filter_type = .lp, .filter_cutoff = 2000.0, .filter_res = 0.35,
        .fenv_amount = 1.6, .fenv_attack_s = 0.004, .fenv_decay_s = 0.25, .fenv_sustain = 0.3, .fenv_release_s = 0.15,
        .gain = 0.28,
    } },

    // jazz — breathy sine flute
    .{ .name = "jazz-flute", .category = "lead", .tags = &.{ "wstudio", "jazz" }, .patch = .{
        .waveform = .sine, .voice_mode = .mono, .glide_s = 0.02,
        .noise_level = 0.06, .noise_color = 0.8,
        .attack_s = 0.05, .decay_s = 0.2, .sustain = 0.8, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 4000.0, .filter_res = 0.05,
        .lfo_shape = .sine, .lfo_rate_hz = 5.0, .lfo_depth = 0.12, .lfo_target = .pitch,
        .gain = 0.3,
    } },

    // soul — Motown horn-section stab
    .{ .name = "soul-brass", .category = "brass", .tags = &.{ "wstudio", "soul" }, .patch = .{
        .waveform = .saw, .unison = 3, .unison_detune = 9.0, .unison_spread = 0.4,
        .attack_s = 0.02, .decay_s = 0.3, .sustain = 0.6, .release_s = 0.2,
        .filter_type = .lp, .filter_cutoff = 3200.0, .filter_res = 0.1,
        .fenv_amount = 1.6, .fenv_attack_s = 0.015, .fenv_decay_s = 0.35, .fenv_sustain = 0.3, .fenv_release_s = 0.2,
        .gain = 0.28,
    } },
};

/// Case-insensitive lookup by name.
pub fn find(name: []const u8) ?Patch {
    for (presets) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p.patch;
    }
    return null;
}
