//! FX chain input, shared by a track's view, a group's, and the master
//! bus. The chain strip shows the inserted units in signal-flow order;
//! Tab/]/[ walk slot focus, `a` inserts via the picker, `x` removes,
//! `<`/`>` reorder, `b` bypasses, j/k pick a param and h/l (H/L coarse)
//! nudge it. The spectrum analyzer belongs to an EQ unit's editor and
//! only runs while one has focus.
//!
//! An EQ unit gets its own band-select scheme instead (`app.eq_band_select`,
//! see `moveEqBand`/`cycleParam`): cycling all 32 band-fields with j/k
//! didn't scale, so h/l walk bands until `enter` opens that band's
//! kind/freq/q/gain-or-slope submenu, and `esc` backs out to band-select
//! before leaving the view. The render half lives in views/spectrum.zig.

const std = @import("std");
const ws = @import("wstudio");
const modal_mod = ws.input;
const dsp = ws.dsp.device;
const eq_mod = ws.dsp.eq;
const multiband_comp = ws.dsp.multiband_comp;
const chorus_mod = ws.dsp.chorus;
const DrumMachine = ws.dsp.DrumMachine;
const Fx = ws.Fx;
const FxKind = ws.FxKind;
const FxUnit = ws.FxUnit;
const FxPayload = ws.FxPayload;
const App = @import("../../tui/app.zig").App;
const history = @import("../history.zig");
const fuzzy = @import("../fuzzy.zig");

/// Spectrum-analyzer pane geometry, shared with the TUI render half
/// (views/spectrum.zig) so the mouse row math here and the draw path agree.
pub const spectrum_rows: usize = 18;
pub const spectrum_band_count: usize = 80;

/// The insertable kinds in picker display order (signal-flow-ish: dynamics,
/// tone, character, modulation, time). Parallel to `picker_menu` in
/// views/picker.zig.
pub const picker_kinds = [_]FxKind{
    .gate, .comp, .mb_comp, .ott, .eq, .sat, .crush, .chorus, .flanger, .tape, .phaser, .freq_shift, .delay, .reverb,
};

/// The `/` filter narrowing the FX insert picker right now - same
/// live-while-typing rule `preset_ed.activeFilter` uses.
pub fn activeFilter(app: *App) []const u8 {
    if (app.modal.mode == .search and app.view == .fx_picker)
        return app.modal.cmd_buf[0..app.modal.cmd_len];
    return app.fx_picker_filter_buf[0..app.fx_picker_filter_len];
}

/// `picker_kinds` narrowed by the active filter, matched against each
/// unit's display label.
pub fn filteredPickerKinds(app: *App, buf: *[picker_kinds.len]FxKind) []FxKind {
    const filter = activeFilter(app);
    var n: usize = 0;
    for (picker_kinds) |k| {
        if (filter.len > 0 and !fuzzy.matches(filter, unitLabel(k))) continue;
        buf[n] = k;
        n += 1;
    }
    return buf[0..n];
}

pub fn unitLabel(k: FxKind) []const u8 {
    return switch (k) {
        .gate => "GATE",
        .comp => "COMP",
        .mb_comp => "MB COMP",
        .ott => "OTT",
        .eq => "EQ",
        .sat => "SAT",
        .crush => "CRUSH",
        .chorus => "CHORUS",
        .flanger => "FLANGER",
        .tape => "TAPE",
        .phaser => "PHASER",
        .freq_shift => "FREQ SHIFT",
        .delay => "DELAY",
        .reverb => "REVERB",
    };
}

/// <=4-char label for the chain strip's slot boxes; nine boxes have to
/// share an 80-col row, so each gets a 7-wide box (see the strip geometry
/// constants below).
pub fn stripLabel(k: FxKind) []const u8 {
    return switch (k) {
        .gate => "GATE",
        .comp => "COMP",
        .mb_comp => "MBCP",
        .ott => "OTT",
        .eq => "EQ",
        .sat => "SAT",
        .crush => "CRSH",
        .chorus => "CHOR",
        .flanger => "FLNG",
        .tape => "TAPE",
        .phaser => "PHAS",
        .freq_shift => "FRQS",
        .delay => "DLY",
        .reverb => "VERB",
    };
}

pub fn paramCount(k: FxKind) usize {
    return switch (k) {
        .eq => eq_mod.num_eq_bands * eq_fields_per_band,
        .mb_comp => mb_comp_param_count,
        .comp => comp_specs.len + 2, // + sidechain track + sidechain pad
        .gate => gate_specs.len,
        .sat => sat_specs.len,
        .crush => crush_specs.len,
        .chorus => chorus_specs.len,
        .phaser => phaser_specs.len,
        .flanger => flanger_specs.len,
        .tape => tape_specs.len,
        .freq_shift => freq_shift_specs.len,
        .reverb => reverb_specs.len,
        .delay => delay_specs.len,
        .ott => ott_specs.len,
    };
}

/// True if `track` currently hosts a drum machine - the only instrument
/// with individually addressable pads, so the only one `scpad` (see
/// `visibleParamCount`) makes sense against.
fn trackIsDrumMachine(app: *App, track: u16) bool {
    if (track >= app.session.racks.items.len) return false;
    return std.meta.activeTag(app.session.racks.items[track].instrument) == .drum_machine;
}

/// `paramCount`, narrowed to what this specific unit instance should
/// actually show/cycle through: `comp`'s `scpad` row (idx 6, "which pad on
/// the sidechain track") only makes sense once a sidechain track is picked
/// AND that track is a drum machine - every other instrument has no pad
/// concept. Every other kind (and `comp` itself, absent that condition)
/// falls through to the static `paramCount`.
pub fn visibleParamCount(app: *App, k: FxKind, p: *const FxPayload) usize {
    if (k == .comp) {
        const show_scpad = if (p.comp.sidechain_source) |sc| trackIsDrumMachine(app, sc.track) else false;
        if (!show_scpad) return paramCount(k) - 1;
    }
    return paramCount(k);
}

/// Flat param list for a multiband compressor: 6 shared controls (crossover
/// x2, attack, release, style, mix) followed by 3 fields (thresh/ratio/
/// makeup) per band, low->mid->high - same "one sequential list" shape the
/// EQ's flattened band/field list already uses.
pub const mb_xover_lo = 0;
pub const mb_xover_hi = 1;
pub const mb_attack = 2;
pub const mb_release = 3;
pub const mb_style = 4;
pub const mb_mix = 5;
pub const mb_shared_count = 6;
pub const mb_fields_per_band = 3; // thresh, ratio, makeup
const mb_comp_param_count = mb_shared_count + multiband_comp.num_bands * mb_fields_per_band;

/// The OTT unit's four params, in display order - the whole point of the
/// kind is that this list stays this short (see dsp/ott.zig).
pub const ott_depth = 0;
pub const ott_time = 1;

pub const MbBandField = struct { band: usize, field: usize };

pub fn mbBandField(idx: usize) MbBandField {
    const rel = idx - mb_shared_count;
    return .{ .band = rel / mb_fields_per_band, .field = rel % mb_fields_per_band };
}

/// EQ params are a flat `band*eq_fields_per_band + field` list (kind, freq,
/// q, gain per band), the same "one sequential param list" shape every
/// other multi-param unit here uses - no separate band/field navigation
/// axis needed. `eq_field_gain`'s row is "gain" for a peak band or "slope"
/// for a lowpass/highpass one (see `paramName`/`getParam`/`setParam`) -
/// the two response families never apply at once (a filter band's gain is
/// stored but the DSP ignores it), so they share the one flat slot instead
/// of needing a fifth per-band field.
pub const eq_field_kind = 0;
pub const eq_field_freq = 1;
pub const eq_field_q = 2;
pub const eq_field_gain = 3;
pub const eq_fields_per_band = 4;

pub fn eqBandField(idx: usize) struct { band: usize, field: usize } {
    return .{ .band = idx / eq_fields_per_band, .field = idx % eq_fields_per_band };
}

/// Full-word label for a band's response type - `eq_field_kind`'s value.
pub fn eqKindLabel(kind: eq_mod.BandKind) []const u8 {
    return switch (kind) {
        .peak => "peak",
        .lowpass => "lowpass",
        .highpass => "highpass",
    };
}

/// [band][field] name table (thresh/ratio/makeup x low/mid/high) - a static
/// lookup instead of building the string at call time, matching every other
/// param-name function here (no allocation). Every label stays <=9 chars -
/// `style.rowHead`'s label column is a fixed 9-wide field; "mid-makeup" (10
/// chars) broke that alignment, so all three makeup labels use "*-mkup".
const mb_band_param_names = [multiband_comp.num_bands][mb_fields_per_band][]const u8{
    .{ "lo-thr", "lo-ratio", "lo-mkup" },
    .{ "mid-thr", "mid-ratio", "mid-mkup" },
    .{ "hi-thr", "hi-ratio", "hi-mkup" },
};

fn mbBandParamName(bf: MbBandField) []const u8 {
    return mb_band_param_names[bf.band][bf.field];
}

/// One row of the per-kind param table driving the 11 "plain" FX kinds
/// below - everything that reduces to reading/writing one f32 field (or,
/// for a couple of clamped/derived params, calling an existing method)
/// against a static range. EQ, multiband comp, and comp's sidechain rows
/// don't fit this shape (banded indexing, cross-field/`app`-derived state)
/// and keep their own switch arms instead.
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

fn tableName(comptime table: []const ParamSpec, idx: usize) []const u8 {
    inline for (table, 0..) |spec, i| if (i == idx) return spec.name;
    return "?";
}

fn tableRange(comptime table: []const ParamSpec, idx: usize) [2]f32 {
    inline for (table, 0..) |spec, i| if (i == idx) return .{ spec.min, spec.max };
    return .{ 0.0, 1.0 };
}

fn tableStep(comptime table: []const ParamSpec, idx: usize, coarse: bool) f32 {
    inline for (table, 0..) |spec, i| if (i == idx) return if (coarse) spec.step_coarse else spec.step_fine;
    return 1.0;
}

fn tableGet(self: anytype, comptime table: []const ParamSpec, idx: usize) f32 {
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
/// straight into the field. The clamp always runs even when a setter also
/// clamps internally (e.g. `Ott.setDepth`): harmless double-clamp there,
/// load-bearing for `StereoDelay.setTime`, whose `seconds` param underflows
/// `usize` on a negative input.
fn tableSet(self: anytype, comptime table: []const ParamSpec, idx: usize, value: f32) void {
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

const gate_specs = [_]ParamSpec{
    .{ .name = "thresh", .field = "threshold_db", .min = -80.0, .max = 0.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "attack", .field = "attack_ms", .min = 0.1, .max = 50.0, .step_fine = 0.5, .step_coarse = 5.0 },
    .{ .name = "release", .field = "release_ms", .min = 5.0, .max = 1000.0, .step_fine = 10.0, .step_coarse = 100.0 },
};

const sat_specs = [_]ParamSpec{
    .{ .name = "drive", .field = "drive_db", .min = 0.0, .max = 36.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "output", .field = "out_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

const crush_specs = [_]ParamSpec{
    .{ .name = "bits", .field = "bits", .min = 1.0, .max = 16.0, .step_fine = 1.0, .step_coarse = 4.0, .round = true },
    .{ .name = "downsmp", .field = "downsample", .min = 1.0, .max = 32.0, .step_fine = 1.0, .step_coarse = 4.0, .round = true },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

const chorus_specs = [_]ParamSpec{
    .{ .name = "rate", .field = "rate_hz", .min = 0.05, .max = 5.0, .step_fine = 0.05, .step_coarse = 0.5 },
    .{ .name = "depth", .field = "depth_ms", .min = 0.0, .max = chorus_mod.max_depth_ms, .step_fine = 0.5, .step_coarse = 2.0 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

const phaser_specs = [_]ParamSpec{
    .{ .name = "rate", .field = "rate_hz", .min = 0.05, .max = 5.0, .step_fine = 0.05, .step_coarse = 0.5 },
    .{ .name = "depth", .field = "depth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "feedback", .field = "feedback", .min = 0.0, .max = 0.9, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

/// Flanger's controls are the same shape as phaser's (mechanical copy when
/// the unit was added - see docs/ FX chain notes).
const flanger_specs = phaser_specs;

const tape_specs = [_]ParamSpec{
    .{ .name = "wow rate", .field = "wow_rate_hz", .min = 0.05, .max = 3.0, .step_fine = 0.05, .step_coarse = 0.3 },
    .{ .name = "wow depth", .field = "wow_depth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "flutter rate", .field = "flutter_rate_hz", .min = 3.0, .max = 15.0, .step_fine = 0.5, .step_coarse = 2.0 },
    .{ .name = "flutter depth", .field = "flutter_depth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

const freq_shift_specs = [_]ParamSpec{
    .{ .name = "shift", .field = "shift_hz", .min = -2000.0, .max = 2000.0, .step_fine = 10.0, .step_coarse = 100.0 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

const reverb_specs = [_]ParamSpec{
    .{ .name = "room", .field = "room", .min = 0.0, .max = 0.98, .step_fine = 0.02, .step_coarse = 0.1 },
    .{ .name = "damp", .field = "damp", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

/// `time`'s range matches the 2.0s line `StereoDelay.init` allocates at
/// every call site; the clamp is also what keeps a stray negative seconds
/// value from underflowing `setTime`'s `usize` frame count (see `tableSet`).
const delay_specs = [_]ParamSpec{
    .{ .name = "time", .getter = "timeSeconds", .setter = "setTime", .min = 0.01, .max = 2.0, .step_fine = 0.01, .step_coarse = 0.1 },
    .{ .name = "feedback", .field = "feedback", .min = 0.0, .max = 0.95, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "mix", .field = "mix", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
};

const ott_specs = [_]ParamSpec{
    .{ .name = "depth", .getter = "depth", .setter = "setDepth", .min = 0.0, .max = 1.0, .step_fine = 0.05, .step_coarse = 0.2 },
    .{ .name = "time", .field = "time", .setter = "setTime", .min = 0.25, .max = 4.0, .step_fine = 0.05, .step_coarse = 0.5 },
    .{ .name = "in", .field = "gain_in_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
    .{ .name = "out", .field = "gain_out_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
};

/// `comp`'s first 5 params only - idx 5/6 are the sidechain track/pad
/// spinners, which need `app` and cross-field state the table shape can't
/// express, so they stay hand-written in every switch below.
const comp_specs = [_]ParamSpec{
    .{ .name = "thresh", .field = "threshold_db", .min = -60.0, .max = 0.0, .step_fine = 1.0, .step_coarse = 6.0 },
    .{ .name = "ratio", .field = "ratio", .min = 1.0, .max = 20.0, .step_fine = 0.5, .step_coarse = 2.0 },
    .{ .name = "attack", .field = "attack_ms", .min = 0.1, .max = 500.0, .step_fine = 5.0, .step_coarse = 50.0 },
    .{ .name = "release", .field = "release_ms", .min = 1.0, .max = 2000.0, .step_fine = 20.0, .step_coarse = 200.0 },
    .{ .name = "makeup", .field = "makeup_db", .min = -24.0, .max = 24.0, .step_fine = 0.5, .step_coarse = 3.0 },
};

/// Param name at `idx` in `p` - bounds match `paramCount`.
pub fn paramName(p: *const FxPayload, idx: usize) []const u8 {
    return switch (p.*) {
        .eq => |*e| blk: {
            const bf = eqBandField(idx);
            break :blk switch (bf.field) {
                eq_field_kind => "kind",
                eq_field_freq => "freq",
                eq_field_q => "q",
                else => if (e.bands[bf.band].kind == .peak) "gain" else "slope",
            };
        },
        .mb_comp => switch (idx) {
            mb_xover_lo => "xover-lo",
            mb_xover_hi => "xover-hi",
            mb_attack => "attack",
            mb_release => "release",
            mb_style => "style",
            mb_mix => "mix",
            else => mbBandParamName(mbBandField(idx)),
        },
        .comp => switch (idx) {
            5 => "sidechain",
            6 => "scpad",
            else => tableName(&comp_specs, idx),
        },
        .gate => tableName(&gate_specs, idx),
        .sat => tableName(&sat_specs, idx),
        .crush => tableName(&crush_specs, idx),
        .chorus => tableName(&chorus_specs, idx),
        .phaser => tableName(&phaser_specs, idx),
        .flanger => tableName(&flanger_specs, idx),
        .tape => tableName(&tape_specs, idx),
        .freq_shift => tableName(&freq_shift_specs, idx),
        .reverb => tableName(&reverb_specs, idx),
        .delay => tableName(&delay_specs, idx),
        .ott => tableName(&ott_specs, idx),
    };
}

/// Current value of param `idx` in `p` - bounds match `paramCount`.
pub fn getParam(p: *const FxPayload, idx: usize) f32 {
    return switch (p.*) {
        .eq => |*e| blk: {
            const bf = eqBandField(idx);
            const band = &e.bands[bf.band];
            break :blk switch (bf.field) {
                eq_field_kind => @floatFromInt(@intFromEnum(band.kind)),
                eq_field_freq => band.freq,
                eq_field_q => band.q,
                else => if (band.kind == .peak) band.gain_db else @floatFromInt(band.slope),
            };
        },
        .mb_comp => |*m| switch (idx) {
            mb_xover_lo => m.xover_lo_hz,
            mb_xover_hi => m.xover_hi_hz,
            mb_attack => m.attack_ms,
            mb_release => m.release_ms,
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
            // Sidechain source, encoded as 0 = none, N = 1-based track index
            // (matches the tracks view's own 1-based row numbering) - lets
            // this slot share the same float-valued get/set/range/step shape
            // every other param here uses instead of a separate enum path.
            5 => if (c.sidechain_source) |s| @as(f32, @floatFromInt(s.track)) + 1.0 else 0.0,
            // Sidechain pad, same 0=none/N=1-based encoding as idx 5 - only
            // meaningful once a track is picked there; see `setParam`.
            6 => if (c.sidechain_source) |s| (if (s.pad) |pd| @as(f32, @floatFromInt(pd)) + 1.0 else 0.0) else 0.0,
            else => tableGet(c, &comp_specs, idx),
        },
        .gate => |*g| tableGet(g, &gate_specs, idx),
        .sat => |*s| tableGet(s, &sat_specs, idx),
        .crush => |*c| tableGet(c, &crush_specs, idx),
        .chorus => |*c| tableGet(c, &chorus_specs, idx),
        .phaser => |*p2| tableGet(p2, &phaser_specs, idx),
        .flanger => |*fl| tableGet(fl, &flanger_specs, idx),
        .tape => |*t| tableGet(t, &tape_specs, idx),
        .freq_shift => |*f| tableGet(f, &freq_shift_specs, idx),
        .reverb => |*r| tableGet(r, &reverb_specs, idx),
        .delay => |*d| tableGet(d, &delay_specs, idx),
        .ott => |*o| tableGet(o, &ott_specs, idx),
    };
}

/// [min, max] of param `idx` in a unit of kind `k` - the same bounds
/// `setParam` clamps to, exported so the view can draw each param as a
/// filled bar (barRow wants a 0..1-ish normalised value).
pub fn paramRange(app: *App, p: *const FxPayload, idx: usize) [2]f32 {
    return switch (p.*) {
        .eq => |*e| switch (eqBandField(idx).field) {
            eq_field_kind => .{ 0.0, 2.0 },
            eq_field_freq => .{ 20.0, 20000.0 },
            eq_field_q => .{ 0.1, 10.0 },
            else => if (e.bands[eqBandField(idx).band].kind == .peak)
                [2]f32{ -18.0, 18.0 }
            else
                [2]f32{ 1.0, @floatFromInt(eq_mod.max_slope) },
        },
        .mb_comp => switch (idx) {
            mb_xover_lo, mb_xover_hi => .{ 20.0, 20000.0 },
            mb_attack => .{ 0.1, 500.0 },
            mb_release => .{ 1.0, 2000.0 },
            mb_style => .{ 0.0, 1.0 },
            mb_mix => .{ 0.0, 1.0 },
            else => switch (mbBandField(idx).field) {
                0 => .{ -60.0, 0.0 }, // threshold
                1 => .{ 1.0, 20.0 }, // ratio
                else => .{ -24.0, 24.0 }, // makeup
            },
        },
        .comp => switch (idx) {
            5 => .{ 0.0, @floatFromInt(app.session.project.tracks.items.len) },
            6 => .{ 0.0, @floatFromInt(DrumMachine.max_pads) },
            else => tableRange(&comp_specs, idx),
        },
        .gate => tableRange(&gate_specs, idx),
        .sat => tableRange(&sat_specs, idx),
        .crush => tableRange(&crush_specs, idx),
        .chorus => tableRange(&chorus_specs, idx),
        .phaser => tableRange(&phaser_specs, idx),
        .flanger => tableRange(&flanger_specs, idx),
        .tape => tableRange(&tape_specs, idx),
        .freq_shift => tableRange(&freq_shift_specs, idx),
        .reverb => tableRange(&reverb_specs, idx),
        .delay => tableRange(&delay_specs, idx),
        .ott => tableRange(&ott_specs, idx),
    };
}

/// Two-name label pair for a genuine on/off-style param - `views/spectrum.zig`
/// draws these with `style.enumRow` (bracketed, discrete) instead of
/// `barRow`'s filled slider, same as the synth/sampler editors already do
/// for their own booleans (osc-b on/off, sampler reverse/mono-poly). A
/// slider implies a continuum to scrub through; a 2-state switch reads
/// clearer as the bracket-pair widget every other toggle in the app already
/// uses. Null for every param that's actually continuous (or has more than
/// two states, like `comp`'s sidechain-source spinner, which keeps its bar
/// since "which of up to 64 tracks" doesn't fit two brackets).
pub fn paramToggleNames(k: FxKind, idx: usize) ?[2][]const u8 {
    return switch (k) {
        .mb_comp => if (idx == mb_style) .{ "classic", "OTT" } else null,
        else => null,
    };
}

// zig fmt: off
/// Clamped absolute set of param `idx` in `p` - bounds match `paramRange`.
pub fn setParam(app: *App, p: *FxPayload, idx: usize, value: f32) void {
    switch (p.*) {
        .eq => |*e| {
            const bf = eqBandField(idx);
            const band = &e.bands[bf.band];
            switch (bf.field) {
                eq_field_kind => {
                    const rounded = std.math.clamp(@round(value), 0.0, 2.0);
                    e.setType(bf.band, @enumFromInt(@as(u8, @intFromFloat(rounded))), band.slope);
                },
                eq_field_freq => e.setFreq(bf.band, value),
                eq_field_q => e.setQ(bf.band, value),
                else => if (band.kind == .peak)
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
            5 => {
                const rounded = std.math.clamp(@round(value), 0.0, @as(f32, @floatFromInt(app.session.project.tracks.items.len)));
                if (rounded < 0.5) {
                    c.sidechain_source = null;
                } else {
                    const track: u16 = @intFromFloat(rounded - 1.0);
                    const pad = if (c.sidechain_source) |sc| sc.pad else null;
                    c.sidechain_source = .{ .track = track, .pad = pad };
                }
            },
            // Only meaningful once a track is picked at idx 5 - a no-op
            // otherwise, since there's nothing to attach a pad to.
            6 => if (c.sidechain_source) |sc| {
                const rounded = std.math.clamp(@round(value), 0.0, @as(f32, @floatFromInt(DrumMachine.max_pads)));
                c.sidechain_source = .{
                    .track = sc.track,
                    .pad = if (rounded < 0.5) null else @intFromFloat(rounded - 1.0),
                };
            },
            else => tableSet(c, &comp_specs, idx, value),
        },
        .gate => |*g| tableSet(g, &gate_specs, idx, value),
        .sat => |*s| tableSet(s, &sat_specs, idx, value),
        .crush => |*c| tableSet(c, &crush_specs, idx, value),
        .chorus => |*c| tableSet(c, &chorus_specs, idx, value),
        .phaser => |*p2| tableSet(p2, &phaser_specs, idx, value),
        .flanger => |*fl| tableSet(fl, &flanger_specs, idx, value),
        .tape => |*t| tableSet(t, &tape_specs, idx, value),
        .freq_shift => |*f| tableSet(f, &freq_shift_specs, idx, value),
        .reverb => |*r| tableSet(r, &reverb_specs, idx, value),
        .delay => |*d| tableSet(d, &delay_specs, idx, value),
        .ott => |*o| tableSet(o, &ott_specs, idx, value),
    }
}
// zig fmt: on

/// Nudge step for `j`/`k` (`coarse` = `J`/`K`) - sized per param so a single
/// press is a musically useful move (e.g. 1dB fine / 6dB coarse for EQ and
/// comp threshold, fractions for the 0..1-ish delay/reverb knobs).
fn paramStep(p: *const FxPayload, idx: usize, coarse: bool) f32 {
    return switch (p.*) {
        .eq => |*e| switch (eqBandField(idx).field) {
            eq_field_kind => 1.0, // 3 discrete states - same nudge whether fine or coarse
            eq_field_freq => if (coarse) @as(f32, 100.0) else 10.0,
            eq_field_q => if (coarse) @as(f32, 0.5) else 0.1,
            // gain steps normally; slope steps whole cascade stages, coarse
            // jumping the full 1..max_slope range in one press.
            else => if (e.bands[eqBandField(idx).band].kind == .peak)
                (if (coarse) @as(f32, 6.0) else 1.0)
            else
                (if (coarse) @as(f32, eq_mod.max_slope) else 1.0),
        },
        .mb_comp => switch (idx) {
            mb_xover_lo, mb_xover_hi => if (coarse) @as(f32, 100.0) else 10.0,
            mb_attack => if (coarse) @as(f32, 50.0) else 5.0,
            mb_release => if (coarse) @as(f32, 200.0) else 20.0,
            mb_style => 1.0, // toggle, whole steps only
            mb_mix => if (coarse) @as(f32, 0.2) else 0.05,
            else => switch (mbBandField(idx).field) {
                0 => if (coarse) @as(f32, 6.0) else 1.0, // threshold
                1 => if (coarse) @as(f32, 2.0) else 0.5, // ratio
                else => if (coarse) @as(f32, 3.0) else 0.5, // makeup
            },
        },
        .comp => switch (idx) {
            5 => if (coarse) @as(f32, 5.0) else 1.0, // step whole track indices
            6 => 1.0,
            else => tableStep(&comp_specs, idx, coarse),
        },
        .gate => tableStep(&gate_specs, idx, coarse),
        .sat => tableStep(&sat_specs, idx, coarse),
        .crush => tableStep(&crush_specs, idx, coarse),
        .chorus => tableStep(&chorus_specs, idx, coarse),
        .phaser => tableStep(&phaser_specs, idx, coarse),
        .flanger => tableStep(&flanger_specs, idx, coarse),
        .tape => tableStep(&tape_specs, idx, coarse),
        .freq_shift => tableStep(&freq_shift_specs, idx, coarse),
        .reverb => tableStep(&reverb_specs, idx, coarse),
        .delay => tableStep(&delay_specs, idx, coarse),
        .ott => tableStep(&ott_specs, idx, coarse),
    };
}

/// Which chain is in view: a track's rack, the master bus, or a group
/// submix bus (see `Session.Group`). One shared FX-chain editor/view for
/// all three - group chains build/edit exactly like a track's or the
/// master's.
/// Nudge the viewed group's bus fader by `delta` dB (see Session.setGroupGain
/// for the clamp) and echo the new level.
fn adjustGroupGain(app: *App, delta: f32) void {
    if (app.eq_group >= ws.engine.max_groups) return;
    const cur = (app.session.groups[app.eq_group] orelse return).gain_db;
    app.session.setGroupGain(app.eq_group, cur + delta);
    app.dirty = true;
    app.setStatus("bus gain: {d:.1}dB", .{app.session.groups[app.eq_group].?.gain_db});
}

pub const EqTarget = enum { track, master, group };

/// Derive the current target from `app.view` - `.track_spectrum` ->
/// `.track`, `.group_spectrum` -> `.group`, everything else (including
/// `.master_spectrum`) -> `.master`.
pub fn currentTarget(app: *App) EqTarget {
    return switch (app.view) {
        .track_spectrum => .track,
        .group_spectrum => .group,
        else => .master,
    };
}

/// The Fx chain currently in view. Null if `app.eq_track`/`app.eq_group`
/// fell out of range (e.g. its track was deleted, or its group was deleted,
/// from under an open chain view).
pub fn fxPtr(app: *App, target: EqTarget) ?*Fx {
    return switch (target) {
        .track => if (app.eq_track >= app.session.racks.items.len)
            null
        else
            &app.session.racks.items[app.eq_track].fx,
        .master => &app.session.master_fx,
        .group => if (app.eq_group >= ws.engine.max_groups)
            null
        else if (app.session.groups[app.eq_group]) |*g| &g.fx else null,
    };
}

/// The unit under `app.fx_focus`, or null while the chain is empty (the
/// focus index is clamped by every mutation, so out-of-range means empty).
pub fn focusedUnit(app: *App, fx: *const Fx) ?*FxUnit {
    if (app.fx_focus >= fx.units.items.len) return null;
    return fx.units.items[app.fx_focus];
}

fn syncChain(app: *App, target: EqTarget) void {
    switch (target) {
        .track => {
            if (app.eq_track >= app.session.racks.items.len) return;
            const rack = app.session.racks.items[app.eq_track];
            app.session.syncTrackChain(app.eq_track, rack);
        },
        .master => app.session.syncMasterChain(),
        .group => app.session.syncGroupChain(app.eq_group),
    }
}

// zig fmt: off
/// The spectrum analyzer belongs to an EQ unit's editor: run it only while
/// one has focus, park it otherwise (and on leaving the view) so the engine
/// skips FFT work nobody is looking at.
fn syncAnalyzer(app: *App, target: EqTarget) void {
    const focused_eq = if (fxPtr(app, target)) |fx| blk: {
        const u = focusedUnit(app, fx) orelse break :blk false;
        break :blk u.kind() == .eq;
    } else false;
    if (focused_eq) {
        _ = app.session.engine.send(.{ .set_spectrum_active = .{
            .source = switch (target) { .track => .track, .master => .master, .group => .group },
            .track = if (target == .track) app.eq_track else 0,
            .group = if (target == .group) app.eq_group else 0,
        } });
    } else {
        _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
    }
}
// zig fmt: on

/// Change chain-slot focus - every focus change (Tab/[/]/picker-insert/
/// switching which chain is in view) ends any open FX param-nudge batch,
/// since a batch is scoped to one (target, unit, param) triple.
pub fn setFocus(app: *App, target: EqTarget, idx: usize) void {
    history.flushFxNudge(app);
    app.fx_focus = idx;
    app.fx_param = 0;
    app.eq_band_select = true;
    syncAnalyzer(app, target);
}

pub fn switchToTrack(app: *App, track: u16) void {
    app.prev_view = app.view;
    app.view = .track_spectrum;
    app.eq_track = track;
    setFocus(app, .track, 0);
}

pub fn switchToMaster(app: *App) void {
    app.prev_view = app.view;
    app.view = .master_spectrum;
    setFocus(app, .master, 0);
}

/// Open group `idx`'s FX chain - same entry-point shape as
/// `switchToTrack`/`switchToMaster`. No-op if the slot is unused (the
/// caller - the tracks view's group-open key - checks first, this is just
/// a safety net against a stale index).
pub fn switchToGroup(app: *App, idx: u8) void {
    if (idx >= ws.engine.max_groups or app.session.groups[idx] == null) return;
    app.prev_view = app.view;
    app.view = .group_spectrum;
    app.eq_group = idx;
    setFocus(app, .group, 0);
}

/// Open the FX picker for the chain in view. Inserting lands after the
/// focused slot (at the front while the chain is empty). Parks the analyzer
/// - the picker replaces the whole view, so nobody is watching it.
fn openPicker(app: *App, target: EqTarget) void {
    const fx = fxPtr(app, target) orelse return;
    if (fx.units.items.len >= Fx.max_units) {
        app.setStatus("chain full ({d} units)", .{Fx.max_units});
        return;
    }
    _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
    app.fx_picker_return = app.view;
    app.fx_picker_cursor = 0;
    app.fx_picker_filter_len = 0;
    app.view = .fx_picker;
}

/// Picker accepted: back to the chain view, insert after the focused slot,
/// focus the new unit. Called by App.handleFxPickerKey.
pub fn insertFromPicker(app: *App, k: FxKind) void {
    app.view = app.fx_picker_return;
    const target = currentTarget(app);
    const fx = fxPtr(app, target) orelse return;
    const pos = if (fx.units.items.len == 0) 0 else @min(app.fx_focus + 1, fx.units.items.len);
    // Captured before the attempt (not via history.recordFx) since insert
    // can fail - a failed insert must not leave a spurious no-op undo step.
    history.flushFxNudge(app);
    const before = history.captureFx(app, target);
    _ = fx.insert(app.session.allocator, pos, k, app.session.project.sample_rate) catch |err| {
        history.pushFxIfOk(app, before, false);
        switch (err) {
            error.ChainFull => app.setStatus("chain full ({d} units)", .{Fx.max_units}),
            error.OutOfMemory => app.setStatus("{s}: out of memory", .{unitLabel(k)}),
        }
        syncAnalyzer(app, target);
        return;
    };
    history.pushFxIfOk(app, before, true);
    setFocus(app, target, pos);
    app.dirty = true;
    syncChain(app, target);
    app.setStatus("{s} inserted", .{unitLabel(k)});
}

/// Picker dismissed: back to the chain view, nothing inserted.
pub fn cancelPicker(app: *App) void {
    app.view = app.fx_picker_return;
    syncAnalyzer(app, currentTarget(app));
}

pub fn removeFocused(app: *App, target: EqTarget) void {
    const fx = fxPtr(app, target) orelse return;
    if (app.fx_focus >= fx.units.items.len) return;
    history.recordFx(app, target);
    // Unlink and push the shortened chain to the audio thread *before*
    // freeing the unit, so a delay/reverb line can't be torn down while a
    // freshly-fetched chain still points at it.
    const unit = fx.units.orderedRemove(app.fx_focus);
    syncChain(app, target);
    const label = unitLabel(unit.kind());
    unit.payload.deinit(app.session.allocator);
    app.session.allocator.destroy(unit);
    if (app.fx_focus > 0 and app.fx_focus >= fx.units.items.len) app.fx_focus -= 1;
    app.fx_param = 0;
    app.dirty = true;
    syncAnalyzer(app, target);
    app.setStatus("{s} removed", .{label});
}

/// Move the focused unit one slot along the chain; focus follows it.
pub fn moveFocused(app: *App, target: EqTarget, dir: i2) void {
    const fx = fxPtr(app, target) orelse return;
    if (focusedUnit(app, fx) == null) return;
    const other = if (dir < 0) app.fx_focus -% 1 else app.fx_focus + 1;
    if (other >= fx.units.items.len) return; // already at that end (wraps on 0-%1)
    history.recordFx(app, target);
    fx.swap(app.fx_focus, other);
    app.fx_focus = other;
    app.dirty = true;
    syncChain(app, target);
}

pub fn toggleBypass(app: *App, target: EqTarget) void {
    const fx = fxPtr(app, target) orelse return;
    const u = focusedUnit(app, fx) orelse return;
    history.recordFx(app, target);
    u.bypassed = !u.bypassed;
    app.dirty = true;
    syncChain(app, target);
    app.setStatus("{s} {s}", .{ unitLabel(u.kind()), if (u.bypassed) "bypassed" else "active" });
}

fn nudge(app: *App, target: EqTarget, key: u8) void {
    const fx = fxPtr(app, target) orelse return;
    const u = focusedUnit(app, fx) orelse return;
    history.noteFxNudge(app, target, app.fx_focus, app.fx_param);
    const dir: f32 = if (key == 'h' or key == 'H') -1.0 else 1.0;
    const coarse = (key == 'H' or key == 'L');
    const cnt: f32 = @floatFromInt(app.takeCount());
    const cur = getParam(&u.payload, app.fx_param);
    setParam(app, &u.payload, app.fx_param, cur + dir * cnt * paramStep(&u.payload, app.fx_param, coarse));
    clearStaleSidechainPad(app, &u.payload);
    app.dirty = true;
    syncChain(app, target);
}

/// The focused unit, but only if it's an EQ - every EQ-specific key branch
/// below gates on this instead of every other kind's flat param list.
fn focusedEq(app: *App, target: EqTarget) ?*FxUnit {
    const fx = fxPtr(app, target) orelse return null;
    const u = focusedUnit(app, fx) orelse return null;
    return if (u.kind() == .eq) u else null;
}

/// h/l (H/L coarse) in EQ band-select mode: which of the 8 bands the
/// overview/detail rows point at, wrapping like every other cycle here.
/// Coarse jumps half the band count so a single press crosses the spectrum
/// fast. Keeps `fx_param`'s field component untouched so re-entering a
/// band's submenu (enter) lands back on the same field you left it on.
fn moveEqBand(app: *App, key: u8) void {
    const bf = eqBandField(app.fx_param);
    const n: i32 = @intCast(eq_mod.num_eq_bands);
    const dir: i32 = if (key == 'h' or key == 'H') -1 else 1;
    const coarse = (key == 'H' or key == 'L');
    const step: i32 = (if (coarse) @divTrunc(n, 2) else 1) * app.takeCount();
    const band: usize = @intCast(@mod(@as(i32, @intCast(bf.band)) + dir * step, n));
    app.fx_param = band * eq_fields_per_band + bf.field;
}

/// j/k: pick which param row is selected, wrapping with a vim count prefix
/// (3k, 4j, …). For every unit this walks its full flat param list; for an
/// EQ unit in field-edit submode it's instead scoped to the current band's
/// 4 fields (kind/freq/q/gain-or-slope) so it can't wander into another
/// band's rows - band-select mode ignores j/k entirely, since h/l owns
/// band navigation there (see `moveEqBand`).
fn cycleParam(app: *App, target: EqTarget, dir: i2) void {
    if (focusedEq(app, target)) |_| {
        if (app.eq_band_select) return;
        const cnt: usize = @intCast(app.takeCount());
        history.flushFxNudge(app);
        const bf = eqBandField(app.fx_param);
        const step = cnt % eq_fields_per_band;
        const field = if (dir < 0)
            (bf.field + eq_fields_per_band - step) % eq_fields_per_band
        else
            (bf.field + step) % eq_fields_per_band;
        app.fx_param = bf.band * eq_fields_per_band + field;
        return;
    }
    const fx = fxPtr(app, target) orelse return;
    const u = focusedUnit(app, fx) orelse return;
    const n = visibleParamCount(app, u.kind(), &u.payload);
    const cnt: usize = @intCast(app.takeCount());
    history.flushFxNudge(app);
    app.fx_param = if (dir < 0) (app.fx_param + n - (cnt % n)) % n else (app.fx_param + cnt) % n;
}

/// Drops a `comp`'s `scpad` selection the moment its sidechain track (idx
/// 5) stops being a drum machine - e.g. nudging the track picker off a
/// drum track, or onto one that's since had its instrument swapped out
/// from under it. Left alone, a stale non-null `pad` silently breaks the
/// detector instead of falling back to whole-track sidechain: the engine
/// zeroes the per-pad capture buffer and only a `DrumMachine` device ever
/// fills it back in (`Event.capture_pad` is a no-op on every other
/// instrument), so the compressor would read permanent silence and never
/// trigger - invisibly, since `visibleParamCount` also hides the row that
/// would let the user notice and fix it. A no-op whenever `pad` is already
/// null or the track is still a drum machine.
pub fn clearStaleSidechainPad(app: *App, p: *FxPayload) void {
    switch (p.*) {
        .comp => |*c| if (c.sidechain_source) |sc| {
            if (sc.pad != null and !trackIsDrumMachine(app, sc.track))
                c.sidechain_source = .{ .track = sc.track, .pad = null };
        },
        else => {},
    }
}

// zig fmt: off
pub fn handleKey(app: *App, key: modal_mod.Key) bool {
    const target = currentTarget(app);
    const len = if (fxPtr(app, target)) |fx| fx.units.items.len else 0;
    switch (key) {
        .escape => {
            // An EQ's field-edit submenu backs out to band-select first -
            // esc/enter are a symmetric pair, and closing the whole chain
            // view on the first esc would undo two levels at once.
            if (focusedEq(app, target) != null and !app.eq_band_select) {
                history.flushFxNudge(app);
                app.eq_band_select = true;
                return true;
            }
            history.flushFxNudge(app);
            _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
            app.view = app.prev_view;
            return true;
        },
        .enter => {
            // Opens the focused band's field submenu - resets to its
            // "kind" row, the top of the detail section on screen.
            if (focusedEq(app, target) != null and app.eq_band_select) {
                app.eq_band_select = false;
                app.fx_param = eqBandField(app.fx_param).band * eq_fields_per_band + eq_field_kind;
                return true;
            }
            return false;
        },
        .ctrl_r => { history.doRedo(app); return true; },
        .tab => {
            if (len > 0) setFocus(app, target, (app.fx_focus + 1) % len);
            return true;
        },
        .char => |c| switch (c) {
            '[' => {
                if (len > 0) setFocus(app, target, (app.fx_focus + len - 1) % len);
                return true;
            },
            ']' => {
                if (len > 0) setFocus(app, target, (app.fx_focus + 1) % len);
                return true;
            },
            'a' => { openPicker(app, target); return true; },
            'x' => { removeFocused(app, target); return true; },
            '<' => { moveFocused(app, target, -1); return true; },
            '>' => { moveFocused(app, target, 1); return true; },
            'b' => { toggleBypass(app, target); return true; },
            // -/+ ride the group's bus fader from inside its chain view
            // (1 dB per press, count-scaled) - a mixer move like track
            // gain, so deliberately not undo-tracked. Track/master chains
            // have their faders in the tracks view already.
            '-' => { if (target == .group) { adjustGroupGain(app, -1.0 * @as(f32, @floatFromInt(app.takeCount()))); return true; } return false; },
            '+', '=' => { if (target == .group) { adjustGroupGain(app, 1.0 * @as(f32, @floatFromInt(app.takeCount()))); return true; } return false; },
            'u' => { history.doUndo(app); return true; },
            'U' => { history.doRedo(app); return true; },
            'k' => { cycleParam(app, target, -1); return true; },
            'j' => { cycleParam(app, target, 1); return true; },
            // Normally nudges the selected param's value; in an EQ's
            // band-select mode (not yet drilled into a band's submenu via
            // enter) h/l instead walks which band is selected.
            'h', 'H', 'l', 'L' => {
                if (focusedEq(app, target) != null and app.eq_band_select) {
                    moveEqBand(app, c);
                } else {
                    nudge(app, target, c);
                }
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}
// zig fmt: on

// Row layout mirrors views/spectrum.zig's drawFxView exactly: title, the
// 3-row chain strip, a key-hint row, the focused slot's section divider,
// then its editor body. For an EQ unit the body is `visual_rows` spectrum
// rows + an Hz-label row + the band rows; for the other units it's one
// barRow per param (or a single hint row while the chain is empty).

// zig fmt: off
// Chain strip geometry, middle row: an "IN▶" gutter, then up to nine 7-wide
// slot boxes ("┃GATE●┃") joined by 1-wide "▶" arrows; slot i starts at
// column strip_x0 + i*(strip_box_w + strip_gap_w). A trailing "+" box (the
// insert affordance) occupies the next slot position while there's room.
// Nine boxes + "▶OUT" total 78 cols, inside an 80-col terminal.
pub const strip_x0: usize = 3;
pub const strip_box_w: usize = 7;
pub const strip_gap_w: usize = 1;
pub const strip_rows_start: usize = 1; // first row after the title
pub const strip_rows_end: usize = 3;   // inclusive
pub const body_row0: usize = 6;        // title + strip(3) + hint + section
// zig fmt: on

/// Short terminals can't fit the boxed strip + hint + the biggest editor
/// body (comp's 5 rows) inside the rows-5 content budget, so below this
/// the strip collapses to its middle row and the hint line is dropped -
/// keeping the app header pinned down to 13 rows, same floor as before
/// the rack revamp. Uniform per-height (not per-focus) so the layout
/// doesn't jump while tabbing between slots.
pub fn compactLayout(rows: usize) bool {
    return rows < 16;
}

/// First body row below the title/strip/hint/section prelude.
pub fn bodyRow0(compact: bool) usize {
    return if (compact) 3 else body_row0;
}

/// Which strip slot a click at column `x` lands in, if any. `len` is the
/// unit count; index `len` means the trailing "+" box (only drawn while
/// the chain has room, so callers gate on that).
fn slotAt(x: usize, len: usize) ?usize {
    if (x < strip_x0) return null;
    const pitch = strip_box_w + strip_gap_w;
    const i = (x - strip_x0) / pitch;
    if ((x - strip_x0) % pitch >= strip_box_w) return null; // the arrow gap
    if (i > len or i >= Fx.max_units) return null;
    return i;
}

/// EQ-body row count below the graph+Hz-label: 2 all-band overview rows
/// (glyph + freq), a "BAND N" header divider, then 4 detail rows for the
/// focused band alone (kind/freq/q/gain-or-slope) - an EQ unit in focus
/// always exists, chains only hold inserted units.
pub const eq_band_rows: usize = 7;
const eq_overview_rows: usize = 2;
const eq_header_rows: usize = 1;

// EQ overview row: a 3-char gutter, then a 5-char cell per band
// (bracket/glyph/bracket on the glyph row; a 5-wide centered field on the
// freq row) - see drawFxView's EQ branch.
const eq_gutter: usize = 3;
const eq_band_w: usize = 5;

fn eqBandAt(x: usize) ?usize {
    if (x < eq_gutter) return null;
    const col = (x - eq_gutter) / eq_band_w;
    if (col >= eq_mod.num_eq_bands) return null;
    return col;
}

/// Nudge the current param one wheel-notch (**ctrl** = coarse), reusing the
/// same `nudge` the keyboard's j/J/k/K use - scroll up = increase (k/K),
/// scroll down = decrease (j/J).
fn nudgeMouse(app: *App, target: EqTarget, ev: modal_mod.MouseEvent) void {
    const up = ev.kind == .scroll_up;
    const key: u8 = if (up) (if (ev.ctrl) @as(u8, 'K') else 'k') else (if (ev.ctrl) @as(u8, 'J') else 'j');
    nudge(app, target, key);
}

/// Click a chain-strip slot box to focus it (the trailing "+" box opens the
/// picker); click an EQ band or a param row to select it; scroll over
/// either nudges it (**ctrl**+scroll = coarse).
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16, view_rows: usize) void {
    _ = cols; // slot/band/param columns here are fixed-width, not terminal-width-dependent
    const target = currentTarget(app);
    const fx = fxPtr(app, target) orelse return;
    const compact = compactLayout(view_rows);

    if (row >= strip_rows_start and row <= (if (compact) strip_rows_start else strip_rows_end)) {
        if (ev.kind == .press) {
            const len = fx.units.items.len;
            const i = slotAt(ev.x, len) orelse return;
            if (i == len) openPicker(app, target) else setFocus(app, target, i);
        }
        return;
    }
    const body0 = bodyRow0(compact);
    if (row < body0) return; // title / hint / section rows - not interactive
    const rel = row - body0;

    // zig fmt: off
    const unit = focusedUnit(app, fx) orelse return;
    if (unit.kind() == .eq) {
        // Same sizing as drawFxView: spectrum graph, then the Hz-label row,
        // then the overview rows (glyph + freq, all bands - clicking either
        // re-targets which band the detail rows below show) and the header
        // + detail rows for the focused band alone (kind/freq/q/gain-or-
        // slope, one per row like every other unit's body).
        const visual_rows: usize = @min(spectrum_rows, view_rows -| ((if (compact) @as(usize, 9) else 12) + eq_band_rows));
        const overview_row0 = visual_rows + 1;
        const detail_row0 = overview_row0 + eq_overview_rows + eq_header_rows;
        if (rel >= overview_row0 and rel < overview_row0 + eq_overview_rows) {
            const band = eqBandAt(ev.x) orelse return;
            const idx = band * eq_fields_per_band + eqBandField(app.fx_param).field;
            switch (ev.kind) {
                // Picking a band from the overview is band-select, same as
                // h/l - it doesn't imply editing a field yet.
                .press => { history.flushFxNudge(app); app.fx_param = idx; app.eq_band_select = true; },
                .scroll_up, .scroll_down => {
                    app.fx_param = idx;
                    nudgeMouse(app, target, ev);
                },
                else => {},
            }
            return;
        }
        if (rel < detail_row0 or rel >= detail_row0 + eq_fields_per_band) return;
        const cur_band = eqBandField(app.fx_param).band;
        const idx = cur_band * eq_fields_per_band + (rel - detail_row0);
        switch (ev.kind) {
            // Clicking a specific field row is the mouse equivalent of
            // enter - it goes straight into that field's submenu.
            .press => { history.flushFxNudge(app); app.fx_param = idx; app.eq_band_select = false; },
            .scroll_up, .scroll_down => {
                app.fx_param = idx;
                nudgeMouse(app, target, ev);
            },
            else => {},
        }
        return;
    }

    if (rel >= visibleParamCount(app, unit.kind(), &unit.payload)) return;
    switch (ev.kind) {
        .press => { history.flushFxNudge(app); app.fx_param = rel; },
        .scroll_up, .scroll_down => {
            app.fx_param = rel;
            nudgeMouse(app, target, ev);
        },
        else => {},
    }
}
// zig fmt: on
