//! The EQ unit's own editor: the response graph, band strip, and per-band
//! controls. Split out of fx.zig because it's a self-contained rendering
//! subsystem (own coordinate-mapping helpers, own test) called from exactly
//! one place there (`drawEditor`, `if (unit.kind() == .eq) fx_eq.drawEqEditor(...)`).

const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const spectrum_ed = @import("../../ui/editors/fx_editor.zig");
const history = @import("../../ui/history.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const scroll = @import("../scroll.zig");
const fx_view = @import("fx.zig");

const color = style.color;
const theme = &style.palette;

/// The graph yields its height to the band strip/controls under it rather
/// than pushing them off screen (see scroll.PaneFit's doc comment).
var eq_fit: scroll.PaneFit = .{};

const eq_freq_min: f32 = 20.0;
const eq_freq_max: f32 = 20_000.0;
const eq_db_min: f32 = -18.0;
const eq_db_max: f32 = 18.0;

pub fn drawEqEditor(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit) void {
    ensureEqAnalyzer(app, target, unit);
    const selected_band = @min(app.core.fx_param / spectrum_ed.eq_fields_per_band, unit.payload.eq.bands.len - 1);
    drawEqGraph(app, target, unit, selected_band);
    zgui.spacing();
    const below_top = zgui.getCursorPosY();
    drawEqBandStrip(app, unit, selected_band);
    drawEqBandControls(app, target, unit, selected_band);
    // The strip and the controls are the same height for every band, so the
    // graph has one layout to fit into: no key needed.
    eq_fit.settle(below_top, 0);
}

pub fn ensureEqAnalyzer(app: anytype, target: spectrum_ed.EqTarget, unit: ?*ws.FxUnit) void {
    const key: u32 = switch (target) {
        .track => 0x10000 | @as(u32, app.core.eq_track),
        .master => 0x20000,
        .group => 0x30000 | @as(u32, app.core.eq_group),
    };
    if (app.eq_analyzer_key == key) return;
    _ = app.core.session.engine.send(.{
        .set_spectrum_active = .{
            .source = switch (target) {
                .track => .track,
                .master => .master,
                .group => .group,
            },
            .track = if (target == .track) app.core.eq_track else 0,
            .group = if (target == .group) app.core.eq_group else 0,
            // See `dsp.Device.ptr`'s doc comment on `FxUnit.device` - matching
            // on the unit itself is what lets the engine tap pre/post around
            // exactly this EQ instance.
            .target = unit,
        },
    });
    app.eq_analyzer_key = key;
}

fn drawEqGraph(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, selected_band: usize) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = eq_fit.height(100, 238);
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("eq-response-graph", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg0), .rounding = style.panel_rounding });

    const db_ticks = [_]f32{ -18, -12, -6, 0, 6, 12, 18 };
    for (db_ticks) |db| {
        const y = eqDbY(origin[1], height, db);
        draw_list.addLine(.{ .p1 = .{ origin[0], y }, .p2 = .{ origin[0] + width, y }, .col = color(if (db == 0) theme.bg5 else theme.line), .thickness = if (db == 0) 1.5 else 1 });
        if (db != 18 and db != -18) draw_list.addText(.{ origin[0] + 6, y - 9 }, color(theme.fg3), "{d:.0}", .{db});
    }
    const freq_ticks = [_]struct { hz: f32, label: []const u8 }{
        .{ .hz = 20, .label = "20" },     .{ .hz = 50, .label = "50" },     .{ .hz = 100, .label = "100" }, .{ .hz = 200, .label = "200" },
        .{ .hz = 500, .label = "500" },   .{ .hz = 1000, .label = "1k" },   .{ .hz = 2000, .label = "2k" }, .{ .hz = 5000, .label = "5k" },
        .{ .hz = 10000, .label = "10k" }, .{ .hz = 20000, .label = "20k" },
    };
    for (freq_ticks) |tick| {
        const x = eqFreqX(origin[0], width, tick.hz);
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = color(if (tick.hz == 1000) theme.bg5 else theme.line), .thickness = 1 });
        draw_list.addText(.{ x + 4, origin[1] + height - 20 }, color(theme.fg3), "{s}", .{tick.label});
    }

    const spectrum_snap = switch (target) {
        .track => app.core.session.engine.trackSpectrumSnapshot(app.core.eq_track),
        .master => app.core.session.engine.masterSpectrumSnapshot(),
        .group => app.core.session.engine.groupSpectrumSnapshot(app.core.eq_group),
    };
    if (spectrum_snap) |snap| {
        var spectrum_points: [snap.bins.len][2]f32 = undefined;
        for (snap.bins, 0..) |db, i| {
            const x = origin[0] + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(snap.bins.len - 1));
            const norm = std.math.clamp((db + 90.0) / 90.0, 0, 1);
            const y = origin[1] + height * (1.0 - norm);
            spectrum_points[i] = .{ x, y };
        }
        draw_list.pathLineTo(.{ origin[0], origin[1] + height });
        for (spectrum_points) |point| draw_list.pathLineTo(point);
        draw_list.pathLineTo(.{ origin[0] + width, origin[1] + height });
        draw_list.pathFillConcave(color(.{ theme.audio[0], theme.audio[1], theme.audio[2], 0.16 }));
        draw_list.addPolyline(&spectrum_points, .{ .col = color(.{ theme.audio[0], theme.audio[1], theme.audio[2], 0.72 }), .thickness = 1.5 });
    }

    var response_points: [257][2]f32 = undefined;
    for (&response_points, 0..) |*point, i| {
        const norm = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(response_points.len - 1));
        const freq = eq_freq_min * std.math.pow(f32, eq_freq_max / eq_freq_min, norm);
        const db = combinedResponseDb(&unit.payload.eq, freq);
        point.* = .{ origin[0] + norm * width, eqDbY(origin[1], height, db) };
    }
    const fill_color = color(.{ theme.rhythm[0], theme.rhythm[1], theme.rhythm[2], 0.10 });
    const zero_y = eqDbY(origin[1], height, 0);
    for (response_points[0 .. response_points.len - 1], response_points[1..]) |a, b| {
        draw_list.addLine(.{ .p1 = .{ a[0], zero_y }, .p2 = a, .col = fill_color, .thickness = @max(1, b[0] - a[0] + 1) });
    }
    draw_list.addPolyline(&response_points, .{ .col = color(theme.rhythm), .thickness = 2.5 });

    for (unit.payload.eq.bands, 0..) |band, i| {
        const node = eqBandPoint(origin, .{ width, height }, band);
        const accent = if (band.enabled) eqBandColor(i) else theme.fg3;
        const selected = i == selected_band;
        // Collision detection (two engaged bands within an octave, see
        // `spectrum_ed.bandCollides`): a warning ring around both, same
        // "quiet flag, not a block" spirit as the TUI's red freq label.
        if (spectrum_ed.bandCollides(&unit.payload.eq, i)) {
            draw_list.addCircle(.{ .p = node, .r = (if (selected) @as(f32, 12) else 10) + 4, .col = color(theme.danger), .thickness = 1.5 });
        }
        draw_list.addCircleFilled(.{ .p = node, .r = 8, .col = color(if (selected) accent else .{ accent[0], accent[1], accent[2], 0.72 }) });
        draw_list.addCircle(.{ .p = node, .r = 10, .col = color(accent), .thickness = 1 });
        if (selected) widgets.focusRing(draw_list, node, 10, theme.focus);
        draw_list.addText(.{ node[0] - 4, node[1] - 8 }, color(style.legibleOn(accent)), "{d}", .{i + 1});
        if (hovered and std.math.hypot(mouse[0] - node[0], mouse[1] - node[1]) <= 22) zgui.setMouseCursor(.resize_all);
    }

    if (hovered and zgui.isMouseClicked(.left)) {
        var nearest = selected_band;
        var nearest_distance: f32 = 1.0e9;
        for (unit.payload.eq.bands, 0..) |band, i| {
            const node = eqBandPoint(origin, .{ width, height }, band);
            const distance = std.math.hypot(mouse[0] - node[0], mouse[1] - node[1]);
            if (distance < nearest_distance) {
                nearest = i;
                nearest_distance = distance;
            }
        }
        if (nearest_distance <= 22) {
            history.recordFx(&app.core, target);
            app.eq_drag_band = @intCast(nearest);
            app.core.fx_param = nearest * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_freq;
        }
    }
    if (app.eq_drag_band) |drag_band| {
        if (zgui.isMouseDown(.left)) {
            const band_index: usize = drag_band;
            const freq = eqXFreq(origin[0], width, mouse[0]);
            const freq_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_freq;
            spectrum_ed.setParam(&app.core, &unit.payload, freq_idx, freq);
            if (ws.dsp.eq.usesGain(unit.payload.eq.bands[band_index].kind)) {
                const gain_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_gain;
                spectrum_ed.setParam(&app.core, &unit.payload, gain_idx, eqYDb(origin[1], height, mouse[1]));
            }
            if (style.wheel_delta != 0) {
                style.wheel_consumed = true;
                const q_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_q;
                const q = unit.payload.eq.bands[band_index].q * @exp(style.wheel_delta * 0.12);
                spectrum_ed.setParam(&app.core, &unit.payload, q_idx, q);
                app.core.fx_param = q_idx;
            }
            app.core.dirty = true;
            fx_view.syncChain(app, target);
        } else {
            app.eq_drag_band = null;
        }
    }
}

fn drawEqBandStrip(app: anytype, unit: *ws.FxUnit, selected_band: usize) void {
    zgui.textDisabled("BANDS   drag node: frequency/gain   hold left + wheel: Q", .{});
    const gap: f32 = 5;
    const available = zgui.getContentRegionAvail()[0];
    const columns: usize = if (available < 600) 4 else 8;
    const width = (available - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    for (unit.payload.eq.bands, 0..) |band, i| {
        if (i % columns != 0) zgui.sameLine(.{ .spacing = gap });
        const selected = i == selected_band;
        const accent = eqBandColor(i);
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (selected) accent else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (selected) style.legibleOn(accent) else accent });
        var freq_buf: [12]u8 = undefined;
        const freq = spectrum_ed.compactHz(&freq_buf, band.freq);
        var label_buf: [48]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{d} {s}\n{s}##eq-band-{d}", .{ i + 1, spectrum_ed.eq_kind_specs[@intFromEnum(band.kind)].short_label, freq, i }) catch continue;
        if (zgui.button(label, .{ .w = width, .h = 44 })) {
            app.core.fx_param = i * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_freq;
            app.core.eq_band_select = false;
        }
        zgui.popStyleColor(.{ .count = 2 });
    }
}

fn drawEqBandControls(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, band_index: usize) void {
    const band = &unit.payload.eq.bands[band_index];
    const accent = eqBandColor(band_index);
    zgui.textColored(accent, "BAND {d}", .{band_index + 1});
    zgui.sameLine(.{});
    zgui.textDisabled("{s}", .{spectrum_ed.eq_kind_specs[@intFromEnum(band.kind)].title});
    zgui.sameLine(.{ .spacing = 16 });
    var enabled = band.enabled;
    if (widgets.toggle("ENABLED", &enabled)) {
        history.recordFx(&app.core, target);
        unit.payload.eq.setEnabled(band_index, enabled);
        app.core.dirty = true;
        fx_view.syncChain(app, target);
    }
    zgui.separator();

    const kind_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_kind;
    for (spectrum_ed.eq_kind_specs, 0..) |entry, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 5 });
        const active = @intFromEnum(band.kind) == i;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) accent else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else theme.fg2 });
        if (zgui.button(entry.action_label, .{ .h = 32 }) and !active) {
            history.noteFxNudge(&app.core, target, app.core.fx_focus, kind_idx);
            spectrum_ed.setParam(&app.core, &unit.payload, kind_idx, @floatFromInt(i));
            app.core.fx_param = kind_idx;
            app.core.dirty = true;
            fx_view.syncChain(app, target);
        }
        zgui.popStyleColor(.{ .count = 2 });
    }
    zgui.spacing();

    const freq_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_freq;
    const q_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_q;
    const gain_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_gain;
    // One strip of three, the way an EQ band's controls sit on hardware.
    // Stacked, they cost three rows the graph above had to give up - and at
    // the smallest window the editor still scrolled.
    drawEqSlider(app, target, unit, freq_idx, "Frequency", "%.0f Hz", true);
    zgui.sameLine(.{ .spacing = 28 });
    drawEqSlider(app, target, unit, q_idx, "Q", "%.2f", true);
    zgui.sameLine(.{ .spacing = 28 });
    if (ws.dsp.eq.usesGain(band.kind))
        drawEqSlider(app, target, unit, gain_idx, "Gain", "%.1f dB", false)
    else
        drawEqSlope(app, target, unit, gain_idx);
    zgui.spacing();

    const solo_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_solo;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (band.solo) theme.rhythm else theme.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (band.solo) theme.bg0 else theme.fg2 });
    if (zgui.button(if (band.solo) "solo: on" else "solo", .{})) {
        history.recordFx(&app.core, target);
        spectrum_ed.setParam(&app.core, &unit.payload, solo_idx, if (band.solo) 0 else 1);
        app.core.fx_param = solo_idx;
        app.core.dirty = true;
    }
    zgui.popStyleColor(.{ .count = 2 });

    const stereo_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_stereo_mode;
    inline for (.{ "stereo", "mid", "side" }, 0..) |name, i| {
        zgui.sameLine(.{ .spacing = 5 });
        const active = @intFromEnum(band.stereo_mode) == i;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) accent else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else theme.fg2 });
        if (zgui.button(name, .{}) and !active) {
            history.recordFx(&app.core, target);
            spectrum_ed.setParam(&app.core, &unit.payload, stereo_idx, @floatFromInt(i));
            app.core.fx_param = stereo_idx;
            app.core.dirty = true;
        }
        zgui.popStyleColor(.{ .count = 2 });
    }

    if (ws.dsp.eq.usesGain(band.kind)) {
        const dyn_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_dyn_enabled;
        zgui.sameLine(.{ .spacing = 16 });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (band.dyn_enabled) theme.rhythm else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (band.dyn_enabled) theme.bg0 else theme.fg2 });
        if (zgui.button(if (band.dyn_enabled) "dynamic: on" else "dynamic", .{})) {
            history.recordFx(&app.core, target);
            spectrum_ed.setParam(&app.core, &unit.payload, dyn_idx, if (band.dyn_enabled) 0 else 1);
            app.core.fx_param = dyn_idx;
            app.core.dirty = true;
        }
        zgui.popStyleColor(.{ .count = 2 });
        if (band.dyn_enabled) {
            const thr_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_dyn_threshold;
            const amt_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_dyn_amount;
            drawEqSlider(app, target, unit, thr_idx, "Dyn Threshold", "%.1f dB", false);
            zgui.sameLine(.{ .spacing = 28 });
            drawEqSlider(app, target, unit, amt_idx, "Dyn Amount", "%.1f dB", false);
        }
    }
}

fn drawEqSlope(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize) void {
    var value = spectrum_ed.getParam(&unit.payload, index);
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    var label_buf: [48]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "slope##eq-control-{d}", .{index}) catch return;
    var display_buf: [24]u8 = undefined;
    const display = std.fmt.bufPrint(&display_buf, "{d:.0} dB/oct", .{value * 12.0}) catch return;
    const focused = !app.core.eq_band_select and app.core.fx_param == index;
    const result = widgets.listStepper("Slope", label, .{ .v = &value, .min = range[0], .max = range[1], .display = display, .accent = eqBandColor(index / spectrum_ed.eq_fields_per_band), .focused = focused });
    applyControl(app, target, unit, index, value, result);
}

fn drawEqSlider(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, label_text: []const u8, format: [:0]const u8, logarithmic: bool) void {
    var value = spectrum_ed.getParam(&unit.payload, index);
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##eq-control-{d}", .{ label_text, index }) catch return;
    const focused = !app.core.eq_band_select and app.core.fx_param == index;
    const accent = eqBandColor(index / spectrum_ed.eq_fields_per_band);
    const result = widgets.paramKnob(label_text, label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format, .accent = accent, .focused = focused, .logarithmic = logarithmic });
    applyControl(app, target, unit, index, value, result);
}

fn applyControl(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, value: f32, result: widgets.KnobResult) void {
    if (result.changed) {
        history.noteFxNudge(&app.core, target, app.core.fx_focus, index);
        spectrum_ed.setParam(&app.core, &unit.payload, index, value);
        app.core.fx_param = index;
        app.core.dirty = true;
        fx_view.syncChain(app, target);
    }
    if (result.activated) {
        app.core.fx_param = index;
        app.core.eq_band_select = false;
    }
    if (result.reset) {
        app.core.fx_param = index;
        app.core.eq_band_select = false;
        spectrum_ed.resetMouseParam(&app.core, target);
    }
}

/// Band identity comes from the theme's six pure hues - the bright tier of the
/// track rotation (`tracks[10..16]`), the only slots saturated enough to carry
/// a label and still read as a node on the curve. Eight bands over six hues, so
/// the second lap is tinted toward the text color to keep 7-8 apart from 1-2.
fn eqBandColor(index: usize) [4]f32 {
    const hue = theme.tracks[10 + index % 6];
    return if (index % 12 < 6) hue else style.mixColor(hue, theme.fg0, 0.45);
}

fn eqBandPoint(origin: [2]f32, size: [2]f32, band: anytype) [2]f32 {
    return .{
        eqFreqX(origin[0], size[0], band.freq),
        eqDbY(origin[1], size[1], if (ws.dsp.eq.usesGain(band.kind)) band.gain_db else 0),
    };
}

fn eqFreqX(origin_x: f32, width: f32, freq: f32) f32 {
    const norm = std.math.log10(std.math.clamp(freq, eq_freq_min, eq_freq_max) / eq_freq_min) /
        std.math.log10(eq_freq_max / eq_freq_min);
    return origin_x + norm * width;
}

fn eqXFreq(origin_x: f32, width: f32, x: f32) f32 {
    const norm = std.math.clamp((x - origin_x) / width, 0, 1);
    return eq_freq_min * std.math.pow(f32, eq_freq_max / eq_freq_min, norm);
}

fn eqDbY(origin_y: f32, height: f32, db: f32) f32 {
    const norm = (std.math.clamp(db, eq_db_min, eq_db_max) - eq_db_min) / (eq_db_max - eq_db_min);
    return origin_y + (1.0 - norm) * height;
}

fn eqYDb(origin_y: f32, height: f32, y: f32) f32 {
    const norm = 1.0 - std.math.clamp((y - origin_y) / height, 0, 1);
    return eq_db_min + norm * (eq_db_max - eq_db_min);
}

/// Combined curve in dB, delegating each band's magnitude to
/// `eq_mod.bandMagnitude` - the same helper `recomputeAutoGain` uses, so the
/// on-screen curve and the auto-gain estimate can never disagree about what
/// a band's response actually is (this used to be its own hand-rolled copy
/// of the biquad-magnitude math, which had no idea `.tiltshelf` needs two
/// different coefficient sets multiplied together).
fn combinedResponseDb(eq: *const ws.dsp.eq.ParametricEq, freq: f32) f32 {
    var total_mag: f32 = 1.0;
    for (&eq.bands) |*band| if (band.enabled) {
        total_mag *= ws.dsp.eq.bandMagnitude(band, freq, eq.sr);
    };
    return 20.0 * std.math.log10(@max(1.0e-6, total_mag));
}

test "every EQ band gets a distinct color in every theme" {
    // Eight bands over six hues: the tinted second lap is what keeps 7 and 8
    // from being drawn in band 1 and 2's color on the same curve. This also
    // fails if a theme's six hues are not themselves distinct, which is how
    // Dracula's blue was caught duplicating its cyan.
    for (std.meta.tags(ws.theme_identity.Name)) |name| {
        style.selectIdentity(ws.theme_identity.get(name).*);
        var seen: [ws.dsp.eq.num_eq_bands][4]f32 = undefined;
        for (&seen, 0..) |*slot, i| {
            slot.* = eqBandColor(i);
            for (seen[0..i]) |prev| try std.testing.expect(!std.meta.eql(prev, slot.*));
        }
    }
    style.selectIdentity(ws.theme_identity.patina);
}

test "EQ pixel mapping round-trips a frequency and a gain" {
    const testing = std.testing;
    // The curve is log-frequency, linear-dB; a drag reads pixels back through
    // the inverse, so a mapping that is not each other's inverse moves a band
    // under the mouse. 20 Hz sits at the left edge, 20 kHz at the right.
    const origin = [2]f32{ 100, 50 };
    const size = [2]f32{ 800, 300 };
    try testing.expectApproxEqAbs(origin[0], eqFreqX(origin[0], size[0], eq_freq_min), 0.01);
    try testing.expectApproxEqAbs(origin[0] + size[0], eqFreqX(origin[0], size[0], eq_freq_max), 0.01);
    for ([_]f32{ 20, 100, 440, 1000, 5000, 20_000 }) |freq| {
        const back = eqXFreq(origin[0], size[0], eqFreqX(origin[0], size[0], freq));
        try testing.expectApproxEqRel(freq, back, 0.001);
    }
    // 0 dB is the middle line, +18 the top (y grows downward).
    try testing.expectApproxEqAbs(origin[1] + size[1] / 2, eqDbY(origin[1], size[1], 0), 0.01);
    try testing.expectApproxEqAbs(origin[1], eqDbY(origin[1], size[1], eq_db_max), 0.01);
    for ([_]f32{ -18, -6, 0, 6, 18 }) |db| {
        const back = eqYDb(origin[1], size[1], eqDbY(origin[1], size[1], db));
        try testing.expectApproxEqAbs(db, back, 0.01);
    }
    // Out of range clamps to an edge rather than drawing off the curve.
    try testing.expectApproxEqAbs(origin[0], eqFreqX(origin[0], size[0], 1), 0.01);
    try testing.expectApproxEqAbs(origin[1] + size[1], eqDbY(origin[1], size[1], -40), 0.01);
}
