//! Frontend-facing FX-kind/EQ-band-kind metadata (display labels, picker
//! category, chain-strip label, collision detection): pure lookups against
//! static tables, no `*App` dependency. Split out of ui/editors/fx_editor.zig
//! because both frontends' non-editor views (picker, tracks, status line)
//! and the GUI's EQ editor need these without pulling in the App-coupled FX
//! chain editing logic that file also carries. Lives in dsp/ (not ui/) so
//! src/gui and src/ui/tui can both reach it without one depending on the
//! other's tree.

const std = @import("std");
const rack = @import("../rack.zig");
const FxKind = rack.FxKind;
const eq_mod = @import("eq.zig");
const fx_params = @import("fx_params.zig");

pub const EffectSpec = struct {
    label: []const u8,
    editor_title: []const u8,
    strip_label: []const u8,
    badge_label: []const u8,
    category: []const u8,
    description: []const u8,
    display_label: []const u8,
};

// Order follows FxPayload's tags, making every frontend-facing name for a
// kind reviewable in one row.
// zig fmt: off
pub const effect_specs = [_]EffectSpec{
    .{ .label = "GATE",       .editor_title = "GATE",           .strip_label = "GATE", .badge_label = "gate", .category = "DYNAMICS",   .description = "Tighten noise and transients",             .display_label = "TRANSFER" },
    .{ .label = "COMP",       .editor_title = "COMPRESSOR",     .strip_label = "COMP", .badge_label = "cmp",  .category = "DYNAMICS",   .description = "Control dynamics and sidechain",            .display_label = "TRANSFER" },
    .{ .label = "MB COMP",    .editor_title = "MULTIBAND COMP", .strip_label = "MBCP", .badge_label = "mbc",  .category = "DYNAMICS",   .description = "Shape dynamics across three bands",          .display_label = "BAND GAIN" },
    .{ .label = "OTT",        .editor_title = "OTT",            .strip_label = "OTT",  .badge_label = "ott",  .category = "DYNAMICS",   .description = "Fast upward and downward compression",       .display_label = "BAND GAIN" },
    .{ .label = "LIMITER",    .editor_title = "LIMITER",        .strip_label = "LIM",  .badge_label = "lim",  .category = "DYNAMICS",   .description = "Catch peaks at a fixed ceiling",              .display_label = "TRANSFER" },
    .{ .label = "EXPANDER",   .editor_title = "EXPANDER",       .strip_label = "EXP",  .badge_label = "exp",  .category = "DYNAMICS",   .description = "Push quiet signal further down",              .display_label = "TRANSFER" },
    .{ .label = "CLIPPER",    .editor_title = "CLIPPER",        .strip_label = "CLIP", .badge_label = "cli",  .category = "DYNAMICS",   .description = "Cut peaks off at a hard ceiling",             .display_label = "TRANSFER" },
    .{ .label = "TRANSIENT",  .editor_title = "TRANSIENT SHAPER", .strip_label = "TRNS", .badge_label = "trn", .category = "DYNAMICS", .description = "Shape attack and sustain",                    .display_label = "APPLIED GAIN" },
    .{ .label = "EQ",         .editor_title = "EQ + SPECTRUM",  .strip_label = "EQ",   .badge_label = "eq",   .category = "TONE",       .description = "Eight-band parametric tone shaping",         .display_label = "RESPONSE" },
    .{ .label = "FILTER",     .editor_title = "FILTER",         .strip_label = "FILT", .badge_label = "flt",  .category = "TONE",       .description = "Multimode resonant tone shaping",            .display_label = "RESPONSE" },
    .{ .label = "UTILITY",    .editor_title = "UTILITY",        .strip_label = "UTIL", .badge_label = "utl",  .category = "UTILITY",    .description = "Gain, delay, channels, and test noise",         .display_label = "CHANNELS" },
    .{ .label = "WIDTH",      .editor_title = "STEREO WIDTH",   .strip_label = "WDTH", .badge_label = "wid",  .category = "UTILITY",    .description = "Shape stereo width with mid and side",       .display_label = "STEREO" },
    .{ .label = "AUTO PAN",   .editor_title = "AUTO PAN / TREMOLO", .strip_label = "APAN", .badge_label = "pan", .category = "MODULATION", .description = "Tempo-synced pan or tremolo",               .display_label = "MODULATION" },
    .{ .label = "SAT",        .editor_title = "SATURATOR",      .strip_label = "SAT",  .badge_label = "sat",  .category = "CHARACTER",  .description = "Add harmonic drive and warmth",              .display_label = "SHAPER" },
    .{ .label = "CRUSH",      .editor_title = "CRUSHER",        .strip_label = "CRSH", .badge_label = "crs",  .category = "CHARACTER",  .description = "Reduce bit depth and sample rate",           .display_label = "SHAPER" },
    .{ .label = "CHORUS",     .editor_title = "CHORUS",         .strip_label = "CHOR", .badge_label = "cho",  .category = "MODULATION", .description = "Widen with modulated voices",                .display_label = "MODULATION" },
    .{ .label = "PHASER",     .editor_title = "PHASER",         .strip_label = "PHAS", .badge_label = "pha",  .category = "MODULATION", .description = "Animated phase cancellation",               .display_label = "MODULATION" },
    .{ .label = "FLANGER",    .editor_title = "FLANGER",        .strip_label = "FLNG", .badge_label = "fln",  .category = "MODULATION", .description = "Short swept comb modulation",               .display_label = "MODULATION" },
    .{ .label = "TAPE",       .editor_title = "TAPE",           .strip_label = "TAPE", .badge_label = "tap",  .category = "CHARACTER",  .description = "Soft saturation and movement",              .display_label = "TAPE MOTION" },
    .{ .label = "FREQ SHIFT", .editor_title = "FREQ SHIFT",     .strip_label = "FRQS", .badge_label = "frq",  .category = "MODULATION", .description = "Shift the full frequency spectrum",          .display_label = "FREQ MAP" },
    .{ .label = "PITCH",      .editor_title = "PITCH SHIFT",    .strip_label = "PTCH", .badge_label = "pit",  .category = "MODULATION", .description = "Transpose without changing speed",           .display_label = "FREQ MAP" },
    .{ .label = "DELAY",      .editor_title = "DELAY",          .strip_label = "DLY",  .badge_label = "dly",  .category = "TIME",       .description = "Stereo echoes with feedback",                .display_label = "ECHO DECAY" },
    .{ .label = "REVERB",     .editor_title = "REVERB",         .strip_label = "VERB", .badge_label = "rev",  .category = "TIME",       .description = "Place the sound in a room",                   .display_label = "ROOM DECAY" },
    .{ .label = "CLAP",       .editor_title = "CLAP PLUGIN",    .strip_label = "CLAP", .badge_label = "clp",  .category = "PLUGIN",     .description = "External CLAP audio plugin",                 .display_label = "PLUGIN" },
    .{ .label = "VST3",       .editor_title = "VST3 PLUGIN",    .strip_label = "VST3", .badge_label = "vst",  .category = "PLUGIN",     .description = "External VST3 audio plugin",                 .display_label = "PLUGIN" },
};
// zig fmt: on

comptime {
    if (effect_specs.len != std.meta.fields(FxKind).len) @compileError("effect_specs must cover every FxKind");
}

pub fn effectSpec(k: FxKind) EffectSpec {
    return effect_specs[@intFromEnum(k)];
}

pub fn unitLabel(k: FxKind) []const u8 {
    return effectSpec(k).label;
}

pub fn editorTitle(k: FxKind) []const u8 {
    return effectSpec(k).editor_title;
}

pub fn pickerCategory(k: FxKind) []const u8 {
    return effectSpec(k).category;
}

pub fn pickerDescription(k: FxKind) []const u8 {
    return effectSpec(k).description;
}

/// <=4-char label for the chain strip's slot boxes; nine boxes have to
/// share an 80-col row, so each gets a 7-wide box (see the strip geometry
/// constants in fx_editor.zig).
pub fn stripLabel(k: FxKind) []const u8 {
    return effectSpec(k).strip_label;
}

/// 3-char label for the TUI tracks view's row badges, where width is shared
/// with gain/pan and the keybind hint - tighter than `stripLabel`'s 4-char
/// strip boxes, so it's its own hand-picked table, not a truncation of it.
pub fn badgeLabel3(k: FxKind) []const u8 {
    return effectSpec(k).badge_label;
}

/// True if band `i` is meaningfully engaged (a gain-type band pushed at
/// least 1dB, or a filter-type band - a cut point always matters) and sits
/// within an octave of another meaningfully-engaged band - a simple stand-in
/// for Pro-Q's "collision detection": two bands fighting over the same
/// region make the combined curve unpredictable even though each looks fine
/// alone. Shared by the TUI overview row and the GUI curve so they flag the
/// same pairs the same way.
pub fn bandCollides(e: *const eq_mod.ParametricEq, i: usize) bool {
    const a = &e.bands[i];
    if (!a.enabled) return false;
    if (eq_mod.usesGain(a.kind) and @abs(a.gain_db) < 1.0) return false;
    for (&e.bands, 0..) |*b, j| {
        if (j == i or !b.enabled) continue;
        if (eq_mod.usesGain(b.kind) and @abs(b.gain_db) < 1.0) continue;
        if (@abs(std.math.log2(a.freq / b.freq)) < 1.0) return true;
    }
    return false;
}

/// Full-word label for a band's response type - `eq_field_kind`'s value.
pub fn eqKindLabel(kind: eq_mod.BandKind) []const u8 {
    return eq_kind_specs[@intFromEnum(kind)].label;
}

pub const EqKindSpec = fx_params.EqKindSpec;
pub const eq_kind_specs = fx_params.eq_kind_specs;

/// Full-word label for a band's stereo/mid/side target - parallel to
/// `eqKindLabel`.
pub fn eqStereoModeLabel(mode: eq_mod.StereoMode) []const u8 {
    return switch (mode) {
        .stereo => "stereo",
        .mid => "mid",
        .side => "side",
    };
}
