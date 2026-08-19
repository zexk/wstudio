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
const gate_mod = ws.dsp.gate;
const multiband_comp = ws.dsp.multiband_comp;
const chorus_mod = ws.dsp.chorus;
const amp_mod = ws.dsp.amp;
const sat_mod = ws.dsp.saturator;
const limiter_mod = ws.dsp.limiter;
const DrumMachine = ws.dsp.DrumMachine;
const Fx = ws.Fx;
const FxKind = ws.FxKind;
const FxUnit = ws.FxUnit;
const FxPayload = ws.FxPayload;
const App = @import("../app.zig").App;
const history = @import("../history.zig");
const fuzzy = @import("../fuzzy.zig");
const fx_p = ws.dsp.fx_params;
const fx_meta = ws.dsp.fx_meta;
const automation_ed = @import("automation.zig");

// Frontend-facing FX-kind/EQ-band-kind metadata split out to
// dsp/fx_meta.zig (no `*App` dependency there, unlike the rest of this
// file) - aliased back under their original names so this file's own bare
// call sites (`unitLabel(k)`, `eqKindLabel(...)`, etc.) keep resolving
// unchanged, and so every other frontend file that already does
// `spectrum_ed.unitLabel(...)` keeps compiling too (each of those imports
// gets redirected to fx_meta.zig instead, see the rename's other edits).
pub const EffectSpec = fx_meta.EffectSpec;
pub const effect_specs = fx_meta.effect_specs;
pub const effectSpec = fx_meta.effectSpec;
pub const unitLabel = fx_meta.unitLabel;
pub const editorTitle = fx_meta.editorTitle;
pub const pickerCategory = fx_meta.pickerCategory;
pub const pickerDescription = fx_meta.pickerDescription;
pub const stripLabel = fx_meta.stripLabel;
pub const badgeLabel3 = fx_meta.badgeLabel3;
pub const bandCollides = fx_meta.bandCollides;
pub const EqKindSpec = fx_meta.EqKindSpec;
pub const eq_kind_specs = fx_meta.eq_kind_specs;
pub const eqKindLabel = fx_meta.eqKindLabel;
pub const eqStereoModeLabel = fx_meta.eqStereoModeLabel;

/// Spectrum-analyzer pane geometry, shared with the TUI render half
/// (views/spectrum.zig) so the mouse row math here and the draw path agree.
pub const spectrum_rows: usize = 18;
pub const spectrum_band_count: usize = 80;

/// The insertable kinds in picker display order (signal-flow-ish: dynamics,
/// tone, character, modulation, time).
pub const picker_kinds = [_]FxKind{
    .gate, .comp, .expander, .mb_comp, .ott, .limiter, .clipper, .transient_shaper, .eq, .filter, .crossover, .utility, .stereo_width, .auto_pan, .sat, .amp, .crush, .chorus, .flanger, .tape, .phaser, .freq_shift, .pitch_shift, .delay, .reverb,
};

comptime {
    // Nothing else forces this list to keep up with `FxKind` - a new unit
    // compiles clean and is simply unreachable from the picker, which is how
    // the pitch shifter first shipped invisible. `clap`/`vst3` are inserted
    // by the plugin browser, not from this list.
    std.debug.assert(picker_kinds.len == std.meta.fields(FxKind).len - 2);
}

/// The `/` filter narrowing the FX insert picker right now - same
/// live-while-typing rule `preset_ed.activeFilter` uses.
pub fn activeFilter(app: *App) []const u8 {
    return app.pickerFilterText(.fx_picker, &app.fx_picker_filter_buf, app.fx_picker_filter_len);
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

pub fn externalPickerCount(app: *App) usize {
    const filter = activeFilter(app);
    var count: usize = 0;
    for (app.external_plugins.plugins.items) |plugin| {
        if (plugin.role != .effect) continue;
        if (filter.len > 0 and !fuzzy.matches(filter, plugin.name)) continue;
        count += 1;
    }
    return count;
}

pub fn externalPickerAt(app: *App, ordinal: usize) ?*const ws.plugin_catalog.Plugin {
    const filter = activeFilter(app);
    var index: usize = 0;
    for (app.external_plugins.plugins.items) |*plugin| {
        if (plugin.role != .effect) continue;
        if (filter.len > 0 and !fuzzy.matches(filter, plugin.name)) continue;
        if (index == ordinal) return plugin;
        index += 1;
    }
    return null;
}

/// Compact frequency label for an EQ band's freq row/readout: "823", "1.2k",
/// "16k" - shared by the TUI FX view and GUI FX view.
pub fn compactHz(buf: []u8, hz: f32) []const u8 {
    if (hz >= 1000.0) {
        const k = hz / 1000.0;
        if (@abs(k - @round(k)) < 0.05) {
            return std.fmt.bufPrint(buf, "{d:.0}k", .{k}) catch "?";
        }
        return std.fmt.bufPrint(buf, "{d:.1}k", .{k}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.0}", .{hz}) catch "?";
}

pub const paramCount = fx_p.paramCount;

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
    if (k == .clap) return @intCast(p.clap.parameterCount());
    if (k == .vst3) return p.vst3.parameterCount();
    if (k == .comp) {
        const show_scpad = if (p.comp.sidechain_source) |sc| trackIsDrumMachine(app, sc.track) else false;
        if (!show_scpad) return paramCount(k) - 1;
    }
    return paramCount(k);
}

pub const ParamGrid = struct {
    count: usize,
    columns: usize,
    rows: usize,

    pub fn index(self: ParamGrid, row: usize, column: usize) ?usize {
        const i = row * self.columns + column;
        return if (row < self.rows and column < self.columns and i < self.count) i else null;
    }

    pub fn columnsInRow(self: ParamGrid, row: usize) usize {
        if (row >= self.rows) return 0;
        return @min(self.columns, self.count - row * self.columns);
    }
};

/// Row-major parameter layout. Frontends choose their own column ceiling
/// from available space, while sequential navigation and visual reading
/// order remain identical.
pub fn paramGrid(count: usize, max_columns: usize) ParamGrid {
    const columns = @min(count, @max(max_columns, 1));
    return .{
        .count = count,
        .columns = columns,
        .rows = if (columns == 0) 0 else (count + columns - 1) / columns,
    };
}

test "parameter grid follows sequential navigation order" {
    const grid = paramGrid(7, 3);
    try std.testing.expectEqual(@as(usize, 3), grid.columns);
    try std.testing.expectEqual(@as(usize, 3), grid.rows);
    try std.testing.expectEqual(@as(usize, 1), grid.columnsInRow(2));
    for (0..7) |i| try std.testing.expectEqual(i, grid.index(i / grid.columns, i % grid.columns).?);
    try std.testing.expectEqual(@as(?usize, null), grid.index(2, 1));
}

// Flat param-index layout for the multiband comp and the EQ, plus the
// band/field split helpers - defined in dsp/fx_params.zig (the audio thread
// addresses the same indices) and aliased here under their original names.
pub const mb_xover_lo = fx_p.mb_xover_lo;
pub const mb_xover_hi = fx_p.mb_xover_hi;
pub const mb_attack = fx_p.mb_attack;
pub const mb_release = fx_p.mb_release;
pub const mb_knee = fx_p.mb_knee;
pub const mb_style = fx_p.mb_style;
pub const mb_mix = fx_p.mb_mix;
pub const mb_shared_count = fx_p.mb_shared_count;
pub const mb_fields_per_band = fx_p.mb_fields_per_band;
pub const MbBandField = fx_p.MbBandField;
pub const mbBandField = fx_p.mbBandField;
pub const eq_field_kind = fx_p.eq_field_kind;
pub const eq_field_freq = fx_p.eq_field_freq;
pub const eq_field_q = fx_p.eq_field_q;
pub const eq_field_gain = fx_p.eq_field_gain;
pub const eq_field_solo = fx_p.eq_field_solo;
pub const eq_field_stereo_mode = fx_p.eq_field_stereo_mode;
pub const eq_field_dyn_enabled = fx_p.eq_field_dyn_enabled;
pub const eq_field_dyn_threshold = fx_p.eq_field_dyn_threshold;
pub const eq_field_dyn_amount = fx_p.eq_field_dyn_amount;
pub const eq_fields_per_band = fx_p.eq_fields_per_band;
pub const eqBandField = fx_p.eqBandField;

/// The OTT unit's four params, in display order - the whole point of the
/// kind is that this list stays this short (see dsp/ott.zig).
pub const ott_depth = 0;
pub const ott_time = 1;

// The ParamSpec table machinery and every plain-kind spec table live in
// dsp/fx_params.zig so the audio thread can reach them; aliased back here
// under their original names so this file's switches read unchanged.
const tableName = fx_p.tableName;
const tableRange = fx_p.tableRange;
const tableStep = fx_p.tableStep;
const tableGet = fx_p.tableGet;
const tableSet = fx_p.tableSet;
const gate_specs = fx_p.gate_specs;
const filter_specs = fx_p.filter_specs;
const utility_specs = fx_p.utility_specs;
const stereo_width_specs = fx_p.stereo_width_specs;
const auto_pan_specs = fx_p.auto_pan_specs;
const transient_shaper_specs = fx_p.transient_shaper_specs;
const sat_specs = fx_p.sat_specs;
const crush_specs = fx_p.crush_specs;
const chorus_specs = fx_p.chorus_specs;
const phaser_specs = fx_p.phaser_specs;
const flanger_specs = fx_p.flanger_specs;
const tape_specs = fx_p.tape_specs;
const freq_shift_specs = fx_p.freq_shift_specs;
const reverb_specs = fx_p.reverb_specs;
const delay_specs = fx_p.delay_specs;
const ott_specs = fx_p.ott_specs;
const limiter_specs = fx_p.limiter_specs;
const comp_specs = fx_p.comp_specs;
const sc_idx = fx_p.comp_sidechain_idx;
const sc_pad_idx = fx_p.comp_sidechain_pad_idx;

/// Param name at `idx` in `p` - bounds match `paramCount`.
pub const paramName = fx_p.paramName;

/// Parameter label copied into `buf` for external runtime metadata, or the
/// static built-in label. The returned slice remains valid for the caller's
/// rendering operation.
pub fn formatParamName(buf: []u8, p: *const FxPayload, idx: usize) []const u8 {
    return switch (p.*) {
        .clap => |plugin| plugin.parameterName(@intCast(idx), buf) orelse
            std.fmt.bufPrint(buf, "param {d}", .{idx + 1}) catch "param",
        .vst3 => |plugin| plugin.parameterName(idx, buf) orelse
            std.fmt.bufPrint(buf, "param {d}", .{idx + 1}) catch "param",
        else => paramName(p, idx),
    };
}

fn clapRange(min_value: f64, max_value: f64) ?[2]f32 {
    if (!std.math.isFinite(min_value) or !std.math.isFinite(max_value) or min_value >= max_value) return null;
    const limit = std.math.floatMax(f32);
    if (min_value < -limit or max_value > limit or max_value - min_value > limit) return null;
    return .{ @floatCast(min_value), @floatCast(max_value) };
}

fn clapValue(value: f64, default_value: f64, range: [2]f32) f32 {
    const chosen = if (std.math.isFinite(value)) value else default_value;
    if (!std.math.isFinite(chosen) or chosen < -std.math.floatMax(f32) or chosen > std.math.floatMax(f32)) return range[0];
    return std.math.clamp(@as(f32, @floatCast(chosen)), range[0], range[1]);
}

test "invalid CLAP parameter metadata has safe UI fallbacks" {
    try std.testing.expectEqual(@as(?[2]f32, null), clapRange(std.math.nan(f64), 1));
    try std.testing.expectEqual(@as(?[2]f32, null), clapRange(2, 1));
    try std.testing.expectEqual(@as(?[2]f32, null), clapRange(-std.math.floatMax(f32), std.math.floatMax(f32)));
    try std.testing.expectEqual([2]f32{ -2, 4 }, clapRange(-2, 4).?);
    try std.testing.expectEqual(@as(f32, -2), clapValue(std.math.nan(f64), std.math.inf(f64), .{ -2, 4 }));
    try std.testing.expectEqual(@as(f32, 4), clapValue(9, 0, .{ -2, 4 }));
}

/// Current value of param `idx` in `p` - bounds match `paramCount`. Only
/// the rows `fx_params.getParam` can't reach (comp's sidechain pair, live
/// plugin values) are handled here.
pub fn getParam(p: *const FxPayload, idx: usize) f32 {
    return switch (p.*) {
        .comp => |c| switch (idx) {
            // Sidechain source, encoded as 0 = none, positive N = 1-based
            // track index (matches the tracks view's own 1-based row
            // numbering), negative -N = 1-based group bus index (see
            // `paramRange`/`setParam`/`formatValue`'s matching branches) -
            // lets this slot share the same float-valued get/set/range/step
            // shape every other param here uses instead of a separate enum
            // path.
            sc_idx => if (c.sidechain_source) |s| (if (s.is_group)
                -(@as(f32, @floatFromInt(s.track)) + 1.0)
            else
                @as(f32, @floatFromInt(s.track)) + 1.0) else 0.0,
            // Sidechain pad, same 0=none/N=1-based encoding as idx 6 - only
            // meaningful once a track is picked there; see `setParam`.
            sc_pad_idx => if (c.sidechain_source) |s| (if (s.pad) |pd| @as(f32, @floatFromInt(pd)) + 1.0 else 0.0) else 0.0,
            else => fx_p.getParam(p, idx),
        },
        .clap => |plugin| blk: {
            const info = plugin.parameterInfo(@intCast(idx)) orelse break :blk 0;
            const range = clapRange(info.min_value, info.max_value) orelse break :blk 0;
            const value: f64 = plugin.parameterValue(info.id) orelse info.default_value;
            break :blk clapValue(value, info.default_value, range);
        },
        .vst3 => |plugin| blk: {
            const info = plugin.parameterInfo(idx) orelse break :blk 0;
            break :blk @floatCast(plugin.parameterValue(info.id) orelse info.default_normalized_value);
        },
        else => fx_p.getParam(p, idx),
    };
}

/// [min, max] of param `idx` in `p` - the same bounds `setParam` clamps to,
/// exported so the view can draw each param as a filled bar (barRow wants a
/// 0..1-ish normalised value). `app` is only needed by comp's sidechain
/// rows, whose bounds are "how many tracks/groups the session has".
pub fn paramRange(app: *App, p: *const FxPayload, idx: usize) [2]f32 {
    return switch (p.*) {
        .comp => switch (idx) {
            // Negative half of the range is group buses (see `getParam`'s
            // doc comment for the encoding), positive half is tracks.
            sc_idx => .{ -@as(f32, @floatFromInt(ws.engine.max_groups)), @floatFromInt(app.session.project.tracks.items.len) },
            sc_pad_idx => .{ 0.0, @floatFromInt(DrumMachine.max_pads) },
            else => fx_p.paramRange(p, idx),
        },
        .clap => |plugin| blk: {
            const info = plugin.parameterInfo(@intCast(idx)) orelse break :blk .{ 0, 1 };
            break :blk clapRange(info.min_value, info.max_value) orelse .{ 0, 1 };
        },
        .vst3 => .{ 0, 1 },
        else => fx_p.paramRange(p, idx),
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
        .eq => switch (eqBandField(idx).field) {
            eq_field_solo => .{ "off", "solo" },
            eq_field_dyn_enabled => .{ "static", "dynamic" },
            else => null,
        },
        .mb_comp => if (idx == mb_style) .{ "classic", "OTT" } else null,
        .comp => switch (idx) {
            7 => .{ "down", "up" },
            9 => .{ "peak", "RMS" },
            else => null,
        },
        .limiter => switch (idx) {
            3 => .{ "sample", "true" },
            4 => .{ "off", "on" },
            else => null,
        },
        .amp => if (idx == 6) .{ "direct", "cabinet" } else null,
        .clipper => if (idx == 3) .{ "off", "on" } else null,
        .gate, .expander => if (idx == 6) .{ "peak", "RMS" } else null,
        .crossover => if (idx >= 5) .{ "off", "solo" } else null,
        .reverb => if (idx == 6) .{ "off", "on" } else null,
        .utility => switch (idx) {
            1 => .{ "normal", "invert" },
            2 => .{ "stereo", "mono" },
            4 => .{ "normal", "swap" },
            6, 9 => .{ "off", "on" },
            else => null,
        },
        .auto_pan => switch (idx) {
            1 => .{ "free", "sync" },
            4 => .{ "tremolo", "pan" },
            else => null,
        },
        else => null,
    };
}

/// True for params whose value names a list entry - a track, a pad - rather
/// than measuring a quantity. The TUI's bar-row rendering already reads
/// fine either way (it shows the resolved name via `formatValue` regardless
/// of what the bar fill implies), but a GUI knob's drag-to-scrub and filled
/// arc are a "more/less" affordance that misreads for "which one of these";
/// `views/fx.zig`'s `drawParam` checks this to draw a prev/next stepper
/// instead, same reasoning as `paramToggleNames` above for 2-state params.
pub fn isListParam(k: FxKind, idx: usize) bool {
    return switch (k) {
        .comp => idx == sc_idx or idx == sc_pad_idx,
        // The amp's MODEL: three named voicings, not a quantity to scrub.
        .amp => idx == 8,
        // Five named curves, not a percentage.
        .sat => idx == 3,
        // Three named knees.
        .clipper => idx == 2,
        // Utility's channel picker and noise colour: named choices.
        .utility => idx == 3 or idx == 7,
        // Three named responses, not a sweep from low-pass to band-pass.
        .filter => idx == 0,
        else => false,
    };
}

/// Clamped absolute set of param `idx` in `p` - bounds match `paramRange`.
/// Delegates to `fx_params.setParamAbsolute` for every param that is just a
/// DSP field; the rows below need `app` (comp's sidechain source resolves
/// against the session's tracks) or the engine command queue.
pub fn setParam(app: *App, p: *FxPayload, idx: usize, value: f32) void {
    switch (p.*) {
        .comp => |*c| {
            switch (idx) {
                sc_idx => {
                    const rounded = std.math.clamp(
                        @round(value),
                        -@as(f32, @floatFromInt(ws.engine.max_groups)),
                        @as(f32, @floatFromInt(app.session.project.tracks.items.len)),
                    );
                    if (@abs(rounded) < 0.5) {
                        c.sidechain_source = null;
                    } else if (rounded < 0.0) {
                        const group: u16 = @intFromFloat(-rounded - 1.0);
                        c.sidechain_source = .{ .track = group, .pad = null, .is_group = true };
                    } else {
                        const track: u16 = @intFromFloat(rounded - 1.0);
                        const pad = if (c.sidechain_source) |sc| (if (sc.is_group) null else sc.pad) else null;
                        c.sidechain_source = .{ .track = track, .pad = pad, .is_group = false };
                    }
                },
                // Only meaningful once a TRACK is picked at idx 6 (a group
                // source has no pad concept) - a no-op otherwise, same as
                // before a source existed at all.
                sc_pad_idx => if (c.sidechain_source) |sc| if (!sc.is_group) {
                    const rounded = std.math.clamp(@round(value), 0.0, @as(f32, @floatFromInt(DrumMachine.max_pads)));
                    c.sidechain_source = .{
                        .track = sc.track,
                        .pad = if (rounded < 0.5) null else @intFromFloat(rounded - 1.0),
                        .is_group = false,
                    };
                },
                else => fx_p.setParamAbsolute(p, idx, value),
            }
            if (idx == sc_idx) if (c.sidechain_source) |source| {
                const consumer: ws.Session.SidechainConsumer = switch (currentTarget(app)) {
                    .track => .{ .track = app.eq_track },
                    .group => .{ .group = app.eq_group },
                    .master => .master,
                };
                if (app.session.sidechainWouldCycle(consumer, source)) {
                    c.sidechain_source = null;
                    app.setStatus("sidechain cycle rejected", .{});
                }
            };
        },
        // Routed through the engine command queue, not a direct
        // `plugin.setParameter` call: that mutates the plugin's own
        // fixed-size pending-event buffer with no synchronization, and
        // `processBlock` reads/resets that same buffer from the audio
        // thread every block - a UI-thread knob nudge or drag racing a
        // live block is a real, silent-corruption hazard, not a
        // theoretical one (see `ClapPlugin.setParameter`'s own doc
        // comment). `_any` broadcasts rather than routing to one track's
        // chain, since this editor is shared by track/group/master FX.
        .clap => |plugin| if (plugin.parameterInfo(@intCast(idx))) |info| {
            const range = clapRange(info.min_value, info.max_value) orelse return;
            _ = app.session.engine.send(.{ .set_clap_param_any = .{
                .target = plugin,
                .id = info.id,
                .cookie = info.cookie,
                .value = clapValue(value, info.default_value, range),
            } });
        },
        .vst3 => |plugin| if (plugin.parameterInfo(idx)) |info| {
            _ = app.session.engine.send(.{ .set_vst3_param_any = .{
                .target = plugin,
                .id = info.id,
                .value = value,
            } });
        },
        else => fx_p.setParamAbsolute(p, idx, value),
    }
}
/// Nudge step for `j`/`k` (`coarse` = `J`/`K`). Only CLAP needs the
/// plugin's own range to size a step; everything else comes from the shared
/// table, except comp's sidechain-track row, which steps whole track
/// indices.
fn paramStep(p: *const FxPayload, idx: usize, coarse: bool) f32 {
    return switch (p.*) {
        .comp => if (idx == sc_idx and coarse) 5.0 else fx_p.paramStep(p, idx, coarse),
        .clap => |plugin| blk: {
            const info = plugin.parameterInfo(@intCast(idx)) orelse break :blk 0;
            const range = clapRange(info.min_value, info.max_value) orelse break :blk 0;
            const span = range[1] - range[0];
            break :blk @max(if (coarse) span / 10.0 else span / 100.0, std.math.floatEps(f32));
        },
        else => fx_p.paramStep(p, idx, coarse),
    };
}

fn perceptualNudge(p: *const FxPayload, idx: usize) bool {
    switch (p.*) {
        .clap, .vst3 => return false,
        else => {},
    }
    const name = paramName(p, idx);
    inline for (.{ "attack", "release", "time", "rate", "cutoff", "freq" }) |part| {
        if (std.mem.indexOf(u8, name, part) != null) return true;
    }
    return std.mem.eql(u8, name, "q");
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
    history.recordGroupGain(app, app.eq_group, cur);
    app.setStatus("bus gain: {d:.1}dB", .{app.session.groups[app.eq_group].?.gain_db});
}

pub const EqTarget = enum { track, master, group };

/// Derive the current target from `app.view` - `.track_spectrum` ->
/// `.track`, `.group_spectrum` -> `.group`, everything else (including
/// `.master_spectrum`) -> `.master`. While the FX picker is up the chain
/// view is only suspended, not left, so read through its return view: the
/// GUI keeps drawing that chain underneath the picker overlay.
pub fn currentTarget(app: *App) EqTarget {
    const view = if (app.view == .fx_picker) app.fx_picker_return else app.view;
    return switch (view) {
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

/// `A`: add (or jump to) an automation lane for the focused unit's focused
/// param (`app.fx_param`) - see `automation_ed.addFxParamLane`'s doc comment
/// for why this is a separate entry point from the instrument param picker.
/// Master/group chains have no clip to attach a lane to, so this only fires
/// for a track's own chain; comp's sidechain rows aren't automatable.
fn addFocusedFxParamLane(app: *App, target: EqTarget) void {
    if (target != .track) {
        app.setStatus("FX automation is per-track only", .{});
        return;
    }
    const fx = fxPtr(app, target) orelse return;
    const unit = focusedUnit(app, fx) orelse return;
    if (!fx_p.isPayloadAutomatable(&unit.payload, app.fx_param)) {
        app.setStatus("this param can't be automated", .{});
        return;
    }
    automation_ed.addFxParamLane(app, app.eq_track, unit.instance_id, @intCast(app.fx_param));
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
    const focused: ?*FxUnit = if (fxPtr(app, target)) |fx| blk: {
        const u = focusedUnit(app, fx) orelse break :blk null;
        break :blk if (u.kind() == .eq) u else null;
    } else null;
    if (focused) |u| {
        _ = app.session.engine.send(.{ .set_spectrum_active = .{
            .source = switch (target) { .track => .track, .master => .master, .group => .group },
            .track = if (target == .track) app.eq_track else 0,
            .group = if (target == .group) app.eq_group else 0,
            // `dsp.Device.ptr` for any FX slot is the owning `*FxUnit`, not
            // its payload sub-object - see `FxUnit.device`. Matching on `u`
            // itself is what lets the engine tap pre/post around exactly
            // this EQ instance in `Engine.processChainWithSidechain`.
            .target = u,
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
pub fn openPicker(app: *App, target: EqTarget) void {
    const fx = fxPtr(app, target) orelse return;
    if (fx.units.items.len >= Fx.max_units) {
        app.setStatus("chain full ({d} units)", .{Fx.max_units});
        return;
    }
    _ = app.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
    app.fx_picker_return = app.view;
    app.fx_picker_cursor = 0;
    app.fx_picker_scroll = 0;
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
            error.ClapPluginRequiresPath => app.setStatus("choose CLAP plugins from the plugin picker", .{}),
            error.Vst3PluginRequiresPath => app.setStatus("choose VST3 plugins from the plugin picker", .{}),
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

pub fn insertExternalFromPicker(app: *App, plugin: *const ws.plugin_catalog.Plugin) void {
    app.view = app.fx_picker_return;
    const target = currentTarget(app);
    const fx = fxPtr(app, target) orelse return;
    const pos = if (fx.units.items.len == 0) 0 else @min(app.fx_focus + 1, fx.units.items.len);
    history.flushFxNudge(app);
    const before = history.captureFx(app, target);
    const loaded = switch (plugin.format) {
        .clap => fx.insertClap(app.session.allocator, pos, plugin.path, plugin.id, app.session.project.sample_rate),
        .vst3 => fx.insertVst3(app.session.allocator, pos, plugin.path, plugin.id, app.session.project.sample_rate),
    };
    _ = loaded catch |err| {
        history.pushFxIfOk(app, before, false);
        std.log.err("failed to load {s}: {s}", .{ plugin.name, @errorName(err) });
        app.setStatus("{s}: {s}", .{ plugin.name, @errorName(err) });
        syncAnalyzer(app, target);
        return;
    };
    history.pushFxIfOk(app, before, true);
    setFocus(app, target, pos);
    app.dirty = true;
    syncChain(app, target);
    app.setStatus("{s} inserted  {s}", .{ plugin.name, @tagName(plugin.format) });
}

/// Picker dismissed: back to the chain view, nothing inserted.
pub fn cancelPicker(app: *App) void {
    app.view = app.fx_picker_return;
    syncAnalyzer(app, currentTarget(app));
}

pub fn removeFocused(app: *App, target: EqTarget) void {
    const fx = fxPtr(app, target) orelse return;
    if (app.fx_focus >= fx.units.items.len) return;
    // Reserve retirement space before mutating anything, mirroring
    // Session.deleteTrack - a failed reservation must leave the chain
    // untouched rather than orphan the unit after it's already unlinked.
    app.session.retired_fx.ensureUnusedCapacity(app.session.allocator, 1) catch {
        app.setStatus("out of memory", .{});
        return;
    };
    history.recordFx(app, target);
    // Unlink and push the shortened chain to the audio thread, then retire
    // (not free) the unit - ChainBank.set's atomic buffer flip only
    // guarantees a whole-chain-consistent read, not that the audio thread
    // has finished calling process() on a unit that was in the chain it
    // read just before the flip. Freeing here immediately would be a
    // crash-capable use-after-free race; retired_fx is freed at session
    // deinit instead, same policy as retired_racks.
    const unit = fx.units.orderedRemove(app.fx_focus);
    syncChain(app, target);
    const label = unitLabel(unit.kind());
    app.session.retired_fx.appendAssumeCapacity(.{ .unit = unit, .block = app.session.engine.blocksDone() });
    if (app.fx_focus > 0 and app.fx_focus >= fx.units.items.len) app.fx_focus -= 1;
    app.fx_param = 0;
    app.dirty = true;
    syncAnalyzer(app, target);
    app.setStatus("{s} removed", .{label});
}

fn yankFocused(app: *App, target: EqTarget) void {
    const fx = fxPtr(app, target) orelse return;
    const source = focusedUnit(app, fx) orelse return;
    const copy = app.allocator.create(FxUnit) catch {
        app.setStatus("yank failed (out of memory)", .{});
        return;
    };
    copy.* = .{ .payload = source.payload.dupe(app.allocator, app.session.project.sample_rate) catch {
        app.allocator.destroy(copy);
        app.setStatus("yank failed", .{});
        return;
    }, .instance_id = 0 };
    copy.setBypassed(source.bypassed);
    if (app.fx_clip) |old| {
        old.payload.deinit(app.allocator);
        app.allocator.destroy(old);
    }
    app.fx_clip = copy;
    app.setStatus("{s} yanked", .{unitLabel(copy.kind())});
}

fn pasteFx(app: *App, target: EqTarget) void {
    const source = app.fx_clip orelse {
        app.setStatus("nothing yanked - y copies an FX unit", .{});
        return;
    };
    const fx = fxPtr(app, target) orelse return;
    const pos = if (fx.units.items.len == 0) 0 else @min(app.fx_focus + 1, fx.units.items.len);
    history.flushFxNudge(app);
    const before = history.captureFx(app, target);
    _ = fx.insertDupe(app.session.allocator, pos, source, app.session.project.sample_rate) catch |err| {
        history.pushFxIfOk(app, before, false);
        app.setStatus("paste failed: {s}", .{@errorName(err)});
        return;
    };
    history.pushFxIfOk(app, before, true);
    setFocus(app, target, pos);
    app.dirty = true;
    syncChain(app, target);
    app.setStatus("{s} pasted", .{unitLabel(source.kind())});
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

/// Move focused unit directly to one slot, recording one undo entry even
/// when it crosses several neighbors. GUI drag/drop lands here once.
pub fn moveFocusedTo(app: *App, target: EqTarget, destination: usize) void {
    const fx = fxPtr(app, target) orelse return;
    if (focusedUnit(app, fx) == null or destination >= fx.units.items.len or destination == app.fx_focus) return;
    history.recordFx(app, target);
    while (app.fx_focus < destination) {
        fx.swap(app.fx_focus, app.fx_focus + 1);
        app.fx_focus += 1;
    }
    while (app.fx_focus > destination) {
        fx.swap(app.fx_focus, app.fx_focus - 1);
        app.fx_focus -= 1;
    }
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

/// Unit-level auto-gain, same "outside the param grid, own keybind" shape
/// as `toggleBypass` - see `ParametricEq.setAutoGain`.
pub fn toggleAutoGain(app: *App, target: EqTarget) void {
    const u = focusedEq(app, target) orelse return;
    const e = &u.payload.eq;
    history.recordFx(app, target);
    e.setAutoGain(!e.auto_gain);
    app.dirty = true;
    app.setStatus("auto gain {s}", .{if (e.auto_gain) "on" else "off"});
}

/// Unit-level filter-design switch, same shape as `toggleAutoGain` - see
/// `ParametricEq.setAnalog`.
pub fn toggleAnalog(app: *App, target: EqTarget) void {
    const u = focusedEq(app, target) orelse return;
    const e = &u.payload.eq;
    history.recordFx(app, target);
    e.setAnalog(!e.analog);
    app.dirty = true;
    app.setStatus("analog bells {s}", .{if (e.analog) "on" else "off"});
}

/// Flips which side of the focused EQ the analyzer taps - see
/// `Engine.set_spectrum_pre`. Not undo-tracked (a view preference, not
/// session data, same as freeze below).
pub fn toggleSpectrumPre(app: *App, target: EqTarget) void {
    if (focusedEq(app, target) == null) return;
    app.eq_spectrum_pre = !app.eq_spectrum_pre;
    _ = app.session.engine.send(.{ .set_spectrum_pre = app.eq_spectrum_pre });
    app.setStatus("spectrum: {s}", .{if (app.eq_spectrum_pre) "pre-EQ" else "post-EQ"});
}

/// Freeze is pure view state - the render side just stops asking the engine
/// for a fresh snapshot and keeps drawing the last one it got (see
/// `views/spectrum.zig`), so there's nothing to send the engine here.
pub fn toggleSpectrumFreeze(app: *App, target: EqTarget) void {
    if (focusedEq(app, target) == null) return;
    app.eq_spectrum_frozen = !app.eq_spectrum_frozen;
    app.setStatus("spectrum: {s}", .{if (app.eq_spectrum_frozen) "frozen" else "live"});
}

fn nudge(app: *App, target: EqTarget, key: u8) void {
    const fx = fxPtr(app, target) orelse return;
    const u = focusedUnit(app, fx) orelse return;
    history.noteFxNudge(app, target, app.fx_focus, app.fx_param);
    const dir: f32 = if (key == 'h' or key == 'H') -1.0 else 1.0;
    const coarse = (key == 'H' or key == 'L');
    const cnt: f32 = @floatFromInt(app.takeCount());
    const cur = getParam(&u.payload, app.fx_param);
    const next = if (perceptualNudge(&u.payload, app.fx_param) and cur > 0)
        cur * std.math.pow(f32, 2.0, dir * cnt * (if (coarse) @as(f32, 12) else 1) / 12.0)
    else
        cur + dir * cnt * paramStep(&u.payload, app.fx_param, coarse);
    setParam(app, &u.payload, app.fx_param, next);
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
    if (n == 0) return;
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
            if (sc.pad != null and !sc.is_group and !trackIsDrumMachine(app, sc.track))
                c.sidechain_source = .{ .track = sc.track, .pad = null, .is_group = sc.is_group };
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
            // Block insert mode - piano keys conflict with param navigation.
            'i' => return true,
            '[' => {
                if (len > 0) setFocus(app, target, (app.fx_focus + len - 1) % len);
                return true;
            },
            ']' => {
                if (len > 0) setFocus(app, target, (app.fx_focus + 1) % len);
                return true;
            },
            'a' => { openPicker(app, target); return true; },
            'A' => { addFocusedFxParamLane(app, target); return true; },
            'y' => { yankFocused(app, target); return true; },
            'P' => { pasteFx(app, target); return true; },
            'x' => { removeFocused(app, target); return true; },
            '<' => { moveFocused(app, target, -1); return true; },
            '>' => { moveFocused(app, target, 1); return true; },
            'b' => { toggleBypass(app, target); return true; },
            'g' => { toggleAutoGain(app, target); return true; },
            'z' => { toggleAnalog(app, target); return true; },
            'p' => { toggleSpectrumPre(app, target); return true; },
            'f' => { toggleSpectrumFreeze(app, target); return true; },
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
/// (glyph + freq), a "BAND N" header divider, then `eq_fields_per_band`
/// detail rows for the focused band alone (kind/freq/q/gain-or-slope/solo/
/// stereo/dyn-on/dyn-threshold/dyn-amount) - an EQ unit in focus always
/// exists, chains only hold inserted units.
pub const eq_band_rows: usize = eq_overview_rows + eq_header_rows + eq_fields_per_band;
const eq_overview_rows: usize = 2;
const eq_header_rows: usize = 1;

/// How many rows the EQ's live spectrum graph gets, given the view's total
/// row budget - shared by the render side (`tui/views/spectrum.zig`'s
/// `drawFxView`) and the click side (`handleMouse`, below) so they can
/// never drift out of sync again: they used to carry independent copies of
/// this formula, and a render-side retune (dropping a removed divider row
/// from the flat offset) never reached the click-side copy, leaving every
/// click on the EQ body 2 rows off from what was actually drawn on any
/// terminal short enough to hit the `rows -| ...` clamp (ordinary sizes -
/// the two only agreed once both saturated at `spectrum_rows`).
pub fn eqVisualRows(rows: usize, compact: bool, bands: usize) usize {
    // Header + strip + hint + section (6; 3 in compact mode) + graph + hz
    // label + band rows must fit in rows-3 (the caller's header/transport/
    // status - no separate hr() rule rows).
    return @min(spectrum_rows, rows -| ((if (compact) @as(usize, 7) else 10) + bands));
}

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

fn resetMouseParam(app: *App, target: EqTarget) void {
    const fx = fxPtr(app, target) orelse return;
    const unit = focusedUnit(app, fx) orelse return;
    const value = switch (unit.payload) {
        .clap => |plugin| if (plugin.parameterInfo(@intCast(app.fx_param))) |info| @as(f32, @floatCast(info.default_value)) else return,
        .vst3 => |plugin| if (plugin.parameterInfo(app.fx_param)) |info| @as(f32, @floatCast(info.default_normalized_value)) else return,
        else => blk: {
            var fresh = ws.Fx.initPayload(app.allocator, unit.kind(), app.session.project.sample_rate) catch return;
            defer fresh.deinit(app.allocator);
            break :blk getParam(&fresh, app.fx_param);
        },
    };
    history.noteFxNudge(app, target, app.fx_focus, app.fx_param);
    setParam(app, &unit.payload, app.fx_param, value);
    history.flushFxNudge(app);
    syncChain(app, target);
}

/// Click a chain-strip slot box to focus it (the trailing "+" opens the
/// picker). **Shift**+drag reorders; middle-click bypasses; right-click
/// removes. Click an EQ band or param row to select it; scroll nudges it.
pub fn handleMouse(app: *App, ev: modal_mod.MouseEvent, row: usize, cols: u16, view_rows: usize) void {
    _ = cols; // slot/band/param columns here are fixed-width, not terminal-width-dependent
    const target = currentTarget(app);
    const fx = fxPtr(app, target) orelse return;
    const compact = compactLayout(view_rows);

    if (ev.kind == .release) app.fx_drag_slot = null;
    if (row >= strip_rows_start and row <= (if (compact) strip_rows_start else strip_rows_end)) {
        const len = fx.units.items.len;
        const i = slotAt(ev.x, len) orelse return;
        switch (ev.kind) {
            .press => {
                if (i == len) {
                    if (ev.button == .left) openPicker(app, target);
                    return;
                }
                setFocus(app, target, i);
                if (ev.button == .right) {
                    removeFocused(app, target);
                } else if (ev.button == .middle) {
                    toggleBypass(app, target);
                } else if (ev.shift) {
                    app.fx_drag_slot = i;
                }
            },
            .drag => if (app.fx_drag_slot != null and i < len) {
                moveFocusedTo(app, target, i);
                app.fx_drag_slot = app.fx_focus;
            },
            else => {},
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
        const visual_rows: usize = eqVisualRows(view_rows, compact, eq_band_rows);
        const overview_row0 = visual_rows + 1;
        const detail_row0 = overview_row0 + eq_overview_rows + eq_header_rows;
        if (rel >= overview_row0 and rel < overview_row0 + eq_overview_rows) {
            const band = eqBandAt(ev.x) orelse return;
            const idx = band * eq_fields_per_band + eqBandField(app.fx_param).field;
            switch (ev.kind) {
                // Picking a band from the overview is band-select, same as
                // h/l - it doesn't imply editing a field yet.
                .press => { history.flushFxNudge(app); app.fx_param = idx; app.eq_band_select = true; if (ev.button == .middle) resetMouseParam(app, target); },
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
            .press => { history.flushFxNudge(app); app.fx_param = idx; app.eq_band_select = false; if (ev.button == .middle) resetMouseParam(app, target); },
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
        .press => { history.flushFxNudge(app); app.fx_param = rel; if (ev.button == .middle) resetMouseParam(app, target); },
        .scroll_up, .scroll_down => {
            app.fx_param = rel;
            nudgeMouse(app, target, ev);
        },
        else => {},
    }
}
// zig fmt: on
/// Percent of the param's own range rather than of 1.0, for the params the
/// DSP caps below 1.0 (reverb room, delay feedback) - a knob turned to its
/// ceiling should read 100%, not 98%.
fn formatRangePercent(buf: []u8, p: *const ws.FxPayload, idx: usize, v: f32) []const u8 {
    const r = fx_p.paramRange(p, idx);
    const span = r[1] - r[0];
    const pct = if (span > 0.0) (v - r[0]) / span * 100.0 else 0.0;
    return std.fmt.bufPrint(buf, "{d:.0}%", .{pct}) catch "?";
}

pub fn formatValue(app: anytype, buf: []u8, p: *const ws.FxPayload, idx: usize) []const u8 {
    const v = getParam(p, idx);
    return switch (p.*) {
        .eq => |*e| blk: {
            const bf = eqBandField(idx);
            break :blk switch (bf.field) {
                eq_field_kind => eqKindLabel(e.bands[bf.band].kind),
                eq_field_freq => std.fmt.bufPrint(buf, "{d:.0}Hz", .{v}) catch "?",
                eq_field_q => std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "?",
                eq_field_solo => if (v >= 0.5) "solo" else "off",
                eq_field_stereo_mode => eqStereoModeLabel(e.bands[bf.band].stereo_mode),
                eq_field_dyn_enabled => if (v >= 0.5) "dynamic" else "static",
                eq_field_dyn_threshold => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
                eq_field_dyn_amount => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
                // Gain for a peak band; a filter band's "slope" instead,
                // stored as a stage count (1..max_slope) - show it in
                // dB/oct (12 per cascade stage) since that's the unit a
                // user actually thinks in.
                else => if (eq_mod.usesGain(e.bands[bf.band].kind))
                    std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?"
                else
                    std.fmt.bufPrint(buf, "{d:.0}dB/oct", .{v * 12.0}) catch "?",
            };
        },
        .comp => switch (idx) {
            0, 4, 5 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            1 => std.fmt.bufPrint(buf, "{d:.1}:1", .{v}) catch "?",
            2, 3, 6 => std.fmt.bufPrint(buf, "{d:.0}ms", .{v}) catch "?",
            7 => if (v >= 0.5) "up" else "down",
            8 => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
            9 => if (v >= 0.5) "RMS" else "peak",
            // 0 is off for both detector filters, which reads better than 0Hz.
            10, 11 => if (v < 20.0) "off" else std.fmt.bufPrint(buf, "{d:.0}Hz", .{v}) catch "?",
            // Include the track/group name so changing this routing does
            // not require memorizing which numbered row holds the kick.
            // Keep the number too, since that is what h/l is cycling
            // through. Negative v is a group bus (see `getParam`'s doc
            // comment for the encoding).
            sc_idx => if (@abs(v) < 0.5) "none" else if (v < 0.0) blk: {
                const group: usize = @intFromFloat(-v - 1.0);
                if (group >= app.session.groups.len or app.session.groups[group] == null)
                    break :blk std.fmt.bufPrint(buf, "bus {d:.0}", .{-v}) catch "?";
                const name = app.session.groups[group].?.name;
                break :blk std.fmt.bufPrint(buf, "bus {d:.0}:{s}", .{ -v, name[0..@min(name.len, 9)] }) catch "?";
            } else blk: {
                const track: usize = @intFromFloat(v - 1.0);
                if (track >= app.session.project.tracks.items.len)
                    break :blk std.fmt.bufPrint(buf, "trk {d:.0}", .{v}) catch "?";
                const name = app.session.project.tracks.items[track].name;
                break :blk std.fmt.bufPrint(buf, "{d:.0}:{s}", .{ v, name[0..@min(name.len, 9)] }) catch "?";
            },
            // As with the track picker, keep the number visible while
            // adding the name users actually recognize from the drum grid.
            // A group source has no pad concept (see `setParam`'s idx-7
            // no-op branch).
            sc_pad_idx => if (v < 0.5) "-" else blk: {
                const source = p.comp.sidechain_source orelse
                    break :blk std.fmt.bufPrint(buf, "pad {d:.0}", .{v}) catch "?";
                if (source.is_group) break :blk "-";
                if (source.track >= app.session.racks.items.len)
                    break :blk std.fmt.bufPrint(buf, "pad {d:.0}", .{v}) catch "?";
                const rack = app.session.racks.items[source.track];
                const name = switch (rack.instrument) {
                    .drum_machine => |*dm| dm.padName(@intFromFloat(v - 1.0)),
                    else => break :blk std.fmt.bufPrint(buf, "pad {d:.0}", .{v}) catch "?",
                };
                break :blk std.fmt.bufPrint(buf, "{d:.0}:{s}", .{ v, name[0..@min(name.len, 9)] }) catch "?";
            },
            else => "?",
        },
        .mb_comp => switch (idx) {
            mb_xover_lo, mb_xover_hi => std.fmt.bufPrint(buf, "{d:.0}Hz", .{v}) catch "?",
            mb_attack, mb_release => std.fmt.bufPrint(buf, "{d:.0}ms", .{v}) catch "?",
            mb_knee => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            mb_style => if (v < 0.5) "classic" else "OTT",
            mb_mix => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
            else => switch (mbBandField(idx).field) {
                0 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?", // threshold
                1 => std.fmt.bufPrint(buf, "{d:.1}:1", .{v}) catch "?", // ratio
                else => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?", // makeup
            },
        },
        .ott => switch (idx) {
            ott_depth => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
            ott_time => std.fmt.bufPrint(buf, "{d:.2}x", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?", // in/out gain
        },
        .limiter => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.2}dB", .{20.0 * std.math.log10(v)}) catch "?",
            3 => if (v >= 0.5) "true" else "sample",
            4 => if (v < 0.5) "off" else "on",
            5 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}ms", .{v}) catch "?",
        },
        .delay => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.0}ms", .{v * 1000.0}) catch "?",
            1 => formatRangePercent(buf, p, idx, v), // feedback, capped at 0.95
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .reverb => switch (idx) {
            0 => formatRangePercent(buf, p, idx, v), // room, capped at 0.98
            3 => std.fmt.bufPrint(buf, "{d:.0}ms", .{v}) catch "?", // predelay
            5 => std.fmt.bufPrint(buf, "{d:.0}Hz", .{v}) catch "?", // low cut
            6 => if (v < 0.5) "off" else "on", // early reflections
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?", // damp, mix, width
        },
        .gate => switch (idx) {
            0, 4 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            6 => if (v < 0.5) "peak" else "RMS",
            // Range bottoms out at full mute rather than reading -80dB.
            5 => if (v <= gate_mod.mute_range_db) "mute" else std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}ms", .{v}) catch "?",
        },
        .filter => switch (idx) {
            0 => switch (@as(u2, @intFromFloat(v))) {
                0 => "low-pass",
                1 => "high-pass",
                else => "band-pass",
            },
            1 => std.fmt.bufPrint(buf, "{d:.0}Hz", .{v}) catch "?",
            2 => std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "?",
            3 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .utility => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            1 => if (v < 0.5) "normal" else "invert",
            2 => if (v < 0.5) "stereo" else "mono",
            3 => switch (@as(u2, @intFromFloat(v))) {
                0 => "stereo",
                1 => "left",
                else => "right",
            },
            4 => if (v < 0.5) "normal" else "swap",
            5 => std.fmt.bufPrint(buf, "{d:.0} samples", .{v}) catch "?",
            6, 9 => if (v < 0.5) "off" else "on",
            7 => switch (@as(u3, @intFromFloat(v))) {
                1 => "pink",
                2 => "brown",
                3 => "blue",
                4 => "violet",
                else => "white",
            },
            8, 10 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            // Bass mono-ing is off at 0 rather than "mono below 0 Hz".
            11 => if (v < 20.0) "off" else std.fmt.bufPrint(buf, "{d:.0}Hz", .{v}) catch "?",
            else => "?",
        },
        .crossover => switch (idx) {
            0, 1 => std.fmt.bufPrint(buf, "{d:.0}Hz", .{v}) catch "?",
            2, 3, 4 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            else => if (v < 0.5) "off" else "solo",
        },
        .stereo_width => if (idx == 0)
            std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?"
        else
            std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
        .auto_pan => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.2}Hz", .{v}) catch "?",
            1 => if (v < 0.5) "free" else "sync",
            2 => std.fmt.bufPrint(buf, "{d:.2} beats", .{v}) catch "?",
            3 => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100}) catch "?",
            else => if (v < 0.5) "tremolo" else "pan",
        },
        .transient_shaper => if (idx < 2)
            std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100}) catch "?"
        else
            std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
        .expander => switch (idx) {
            1 => std.fmt.bufPrint(buf, "{d:.1}:1", .{v}) catch "?",
            2, 3 => std.fmt.bufPrint(buf, "{d:.1}ms", .{v}) catch "?",
            6 => if (v < 0.5) "peak" else "RMS",
            7, 8 => if (v < 20.0) "off" else std.fmt.bufPrint(buf, "{d:.0}Hz", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
        },
        .clipper => switch (idx) {
            2 => switch (@as(u3, @intFromFloat(@max(v, 0.0)))) {
                1 => "soft",
                2 => "medium",
                else => "hard",
            },
            3 => if (v < 0.5) "off" else "on",
            else => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
        },
        .sat => switch (idx) {
            0, 1 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            3 => sat_mod.shape_names[@min(@as(usize, @intFromFloat(@max(v, 0.0))), sat_mod.shape_names.len - 1)],
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .amp => switch (idx) {
            0, 5, 7 => std.fmt.bufPrint(buf, "{d:.1}dB", .{v}) catch "?",
            6 => if (v < 0.5) "direct" else "cabinet",
            8 => amp_mod.model_names[@min(@as(usize, @intFromFloat(@max(v, 0.0))), amp_mod.model_names.len - 1)],
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .crush => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.0}bit", .{v}) catch "?",
            1 => std.fmt.bufPrint(buf, "{d:.0}x", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .chorus => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.2}Hz", .{v}) catch "?",
            1 => std.fmt.bufPrint(buf, "{d:.1}ms", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .phaser => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.2}Hz", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .flanger => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{d:.2}Hz", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .tape => switch (idx) {
            0, 2 => std.fmt.bufPrint(buf, "{d:.2}Hz", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .freq_shift => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{s}{d:.0}Hz", .{ if (v >= 0.0) "+" else "", v }) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .pitch_shift => switch (idx) {
            0 => std.fmt.bufPrint(buf, "{s}{d:.0}st", .{ if (v >= 0.0) "+" else "", v }) catch "?",
            1 => std.fmt.bufPrint(buf, "{s}{d:.0}c", .{ if (v >= 0.0) "+" else "", v }) catch "?",
            2 => std.fmt.bufPrint(buf, "{d:.0}ms", .{v}) catch "?",
            else => std.fmt.bufPrint(buf, "{d:.0}%", .{v * 100.0}) catch "?",
        },
        .clap => |plugin| blk: {
            const info = plugin.parameterInfo(@intCast(idx)) orelse break :blk "?";
            const range = clapRange(info.min_value, info.max_value) orelse break :blk "?";
            const value = clapValue(plugin.parameterValue(info.id) orelse info.default_value, info.default_value, range);
            break :blk plugin.formatParameter(info.id, value, buf) orelse
                std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch "?";
        },
        .vst3 => |plugin| blk: {
            const info = plugin.parameterInfo(idx) orelse break :blk "?";
            const value = plugin.parameterValue(info.id) orelse info.default_normalized_value;
            break :blk plugin.formatParameter(info.id, value, buf) orelse
                std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch "?";
        },
    };
}
