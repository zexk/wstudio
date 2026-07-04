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
};

/// Case-insensitive lookup by name.
pub fn find(name: []const u8) ?Patch {
    for (presets) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p.patch;
    }
    return null;
}
