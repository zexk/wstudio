const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const history = @import("../../ui/history.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const color = style.color;
const rgb = style.rgb;
const theme = &style.palette;

/// The EQ graph and the empty chain's monitor yield their height to the
/// controls under them rather than pushing them off screen (see
/// widgets.PaneFit). One fit each: they never share a frame, and a trim
/// measured for the band controls has nothing to say about an empty state.
/// The effect display sizes itself off `gridFloor` instead, because its param
/// cards stretch - measuring content that grows into whatever the pane gives
/// back would leave the two chasing each other.
var eq_fit: widgets.PaneFit = .{};
var monitor_fit: widgets.PaneFit = .{};

pub fn draw(app: anytype) void {
    const target = spectrum_ed.currentTarget(&app.core);
    const fx = spectrum_ed.fxPtr(&app.core, target) orelse {
        zgui.textDisabled("This FX chain is no longer available.", .{});
        return;
    };
    if (fx.units.items.len > 0) app.core.fx_focus = @min(app.core.fx_focus, fx.units.items.len - 1);

    drawTitle(app, target);
    zgui.spacing();
    drawSignalChain(app, target, fx);
    zgui.spacing();

    if (spectrum_ed.focusedUnit(&app.core, fx)) |unit| {
        drawEditor(app, target, unit);
    } else {
        drawEmptyState(app, target);
    }
}

fn drawTitle(app: anytype, target: spectrum_ed.EqTarget) void {
    zgui.textColored(targetAccent(target), "SPECTRUM / FX CHAIN", .{});
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{targetName(app, target)});
    if (target == .group and app.core.eq_group < ws.engine.max_groups) {
        if (app.core.session.groups[app.core.eq_group]) |group| {
            zgui.sameLine(.{});
            zgui.textDisabled("bus {d:.1}dB", .{group.gain_db});
        }
    }
}

fn targetName(app: anytype, target: spectrum_ed.EqTarget) []const u8 {
    return switch (target) {
        .track => if (app.core.eq_track < app.core.session.project.tracks.items.len)
            app.core.session.project.tracks.items[app.core.eq_track].name
        else
            "Track",
        .master => "Master bus",
        .group => if (app.core.eq_group < ws.engine.max_groups)
            if (app.core.session.groups[app.core.eq_group]) |group| group.name else "Group bus"
        else
            "Group bus",
    };
}

fn targetAccent(target: spectrum_ed.EqTarget) [4]f32 {
    return switch (target) {
        .track => theme.focus,
        .master => theme.modulation,
        .group => theme.audio,
    };
}

fn drawSignalChain(app: anytype, target: spectrum_ed.EqTarget, fx: *ws.Fx) void {
    zgui.textDisabled("IN", .{});
    const gap: f32 = 4;
    const slot_w: f32 = 58;
    for (fx.units.items, 0..) |unit, i| {
        zgui.sameLine(.{ .spacing = gap });
        zgui.textDisabled(">", .{});
        zgui.sameLine(.{ .spacing = gap });
        drawSlot(app, target, unit, i, slot_w);
    }
    if (fx.units.items.len < ws.Fx.max_units) {
        zgui.sameLine(.{ .spacing = gap });
        zgui.textDisabled(">", .{});
        zgui.sameLine(.{ .spacing = gap });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.focus_soft });
        if (zgui.button("+##fx-chain-add", .{ .w = slot_w, .h = 36 })) spectrum_ed.openPicker(&app.core, target);
        zgui.popStyleColor(.{ .count = 2 });
    }
    zgui.sameLine(.{ .spacing = gap });
    zgui.textDisabled("> OUT", .{});

    zgui.textDisabled("a insert   tab select slot   b bypass", .{});
    if (spectrum_ed.focusedUnit(&app.core, fx)) |unit| {
        zgui.sameLine(.{});
        if (unit.kind() == .eq) {
            if (app.core.eq_band_select) {
                zgui.textDisabled("h/l band   enter edit", .{});
            } else {
                zgui.textDisabled("j/k field   h/l adjust", .{});
            }
        } else {
            zgui.textDisabled("j/k parameter   h/l adjust", .{});
        }
    }
}

fn drawSlot(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, width: f32) void {
    const origin = zgui.getCursorScreenPos();
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "fx-slot-{d}", .{index}) catch return;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = 36 });
    const hovered = zgui.isItemHovered(.{});
    const selected = app.core.fx_focus == index;
    const draw_list = zgui.getWindowDrawList();
    const accent = if (unit.bypassed) theme.fg3 else kindAccent(unit.kind());
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 36 }, .col = color(if (selected) theme.bg4 else if (hovered) theme.bg3 else theme.bg2), .rounding = style.item_rounding });
    draw_list.addRect(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 36 }, .col = color(if (selected) theme.focus else theme.line), .rounding = style.item_rounding, .thickness = if (selected) 2 else 1 });
    draw_list.addText(.{ origin[0] + 8, origin[1] + 9 }, color(if (unit.bypassed) theme.fg3 else theme.fg0), "{s}", .{spectrum_ed.stripLabel(unit.kind())});
    draw_list.addCircleFilled(.{ .p = .{ origin[0] + width - 11, origin[1] + 18 }, .r = 3.5, .col = color(accent) });
    if (clicked and !selected) spectrum_ed.setFocus(&app.core, target, index);
}

const kindAccent = style.fxKindAccent;

fn drawEditor(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit) void {
    const accent = kindAccent(unit.kind());
    zgui.textColored(accent, "{s}", .{spectrum_ed.editorTitle(unit.kind())});
    zgui.sameLine(.{});
    zgui.textDisabled("unit {d}  {s} {s}", .{ app.core.fx_focus + 1, if (unit.bypassed) "\u{25CB}" else "\u{25CF}", if (unit.bypassed) "BYPASSED" else "ACTIVE" });
    zgui.sameLine(.{ .spacing = 18 });
    if (zgui.button(if (unit.bypassed) "enable" else "bypass", .{})) spectrum_ed.toggleBypass(&app.core, target);
    zgui.sameLine(.{ .spacing = 5 });
    if (zgui.button("<##fx-left", .{})) spectrum_ed.moveFocused(&app.core, target, -1);
    zgui.sameLine(.{ .spacing = 5 });
    if (zgui.button(">##fx-right", .{})) spectrum_ed.moveFocused(&app.core, target, 1);
    zgui.sameLine(.{ .spacing = 5 });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.danger });
    const removed = zgui.button("remove", .{});
    if (removed) spectrum_ed.removeFocused(&app.core, target);
    zgui.popStyleColor(.{});
    if (removed) return;
    zgui.separator();

    if (unit.kind() == .eq) {
        drawEqEditor(app, target, unit);
    } else {
        // Only the filter's display puts a spectrum behind its curve, so it is
        // the only non-EQ unit worth running the analyzer for.
        if (unit.kind() == .filter) ensureEqAnalyzer(app, target);
        const param_count = spectrum_ed.visibleParamCount(&app.core, unit.kind(), &unit.payload);
        const grid = paramGrid(param_count);
        // Plus the `spacing()` below, which costs an item spacing twice over
        // (once for the pane itself, once for the spacer) - unreserved, the
        // grid came up exactly that short and clipped its last row.
        drawEffectDisplay(app, target, unit, gridFloor(grid.rows) + 2 * zgui.getStyle().item_spacing[1]);
        zgui.spacing();
        drawParamGrid(app, target, unit, grid);
        if (unit.bypassed) zgui.textColored(theme.danger, "BYPASSED  (b to re-enable)", .{});
    }
}

/// Inset the pane keeps clear on every side, so nothing it draws touches the
/// rounded corners.
const display_pad: f32 = 12;

fn drawEffectDisplay(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, grid_floor: f32) void {
    const size = zgui.getContentRegionAvail();
    // The pane is one box with at most two stacked regions: a plot on top and
    // a strip of live meters under it. They are laid out from the same height
    // so neither can be drawn over the other, and each carries only the chrome
    // its own axes justify - grid and axis labels belong to the plot, and a
    // meter has no axes at all.
    var text_buf: [3][20]u8 = undefined;
    var row_buf: [3]MeterRow = undefined;
    const rows = meterRows(unit, &row_buf, &text_buf);
    const has_plot = showsEffectCurve(unit.kind());
    const title_h = zgui.getTextLineHeight() + 2 * display_pad;
    const meter_h: f32 = if (rows.len == 0) 0 else display_pad + @as(f32, @floatFromInt(rows.len)) * meter_row_h;

    // The cards below are a unit: whatever they need at their shortest is
    // theirs, and the display keeps the rest instead of taking a fixed share
    // and pushing the last row off the window (see the sampler's pane in
    // widgets.PaneFit for the same rule where the panels are content-sized).
    // Only a plot has any use for the leftover: meters and a lone caption are
    // content-sized, and stretching the box around them just floats them in
    // the middle of an empty rectangle.
    const room: f32 = std.math.clamp(size[1] - grid_floor, 100, 260);
    const body_h: f32 = if (rows.len > 0) meter_h else zgui.getTextLineHeight() + display_pad;
    const height: f32 = if (has_plot) room else @min(room, title_h + body_h);
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("fx-effect-display", .{ .w = size[0], .h = height });
    const draw_list = zgui.getWindowDrawList();
    const accent = kindAccent(unit.kind());
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + size[0], origin[1] + height }, .col = color(theme.bg0), .rounding = style.panel_rounding });

    draw_list.addText(.{ origin[0] + display_pad, origin[1] + display_pad }, color(theme.fg2), "{s}", .{spectrum_ed.effectSpec(unit.kind()).display_label});
    // The vertical axis is named on the title row rather than inside the plot:
    // a corner label lands on the curve itself for half the shapes drawn here
    // (a compressor's knee ends top-right, a reverb tail starts there).
    if (has_plot) {
        const y_label = plotAxes(unit.kind()).y;
        const y_w = zgui.calcTextSize(y_label, .{})[0];
        draw_list.addText(.{ origin[0] + size[0] - display_pad - y_w, origin[1] + display_pad }, color(theme.fg3), "{s}", .{y_label});
        const plot = Rect{
            .x = origin[0] + display_pad,
            .y = origin[1] + title_h,
            .w = size[0] - 2 * display_pad,
            .h = height - title_h - meter_h - display_pad,
        };
        if (plot.h > 0 and plot.w > 0) drawEffectPlot(app, target, draw_list, plot, unit, accent);
    }
    if (rows.len > 0) {
        // Meters get the whole pane under the title when there is no plot, so
        // a lone readout sits in the middle of the box instead of hugging the
        // bottom edge of a region that was reserved for a curve that is not
        // there.
        const box = Rect{
            .x = origin[0] + display_pad,
            .y = if (has_plot) origin[1] + height - meter_h else origin[1] + title_h,
            .w = size[0] - 2 * display_pad,
            .h = if (has_plot) meter_h else height - title_h,
        };
        drawMeterStack(draw_list, box, rows, accent);
    }
    if (!has_plot and rows.len == 0) {
        const label = spectrum_ed.effectSpec(unit.kind()).description;
        const text_w = zgui.calcTextSize(label, .{})[0];
        draw_list.addText(.{ origin[0] + (size[0] - text_w) * 0.5, origin[1] + title_h + (height - title_h - zgui.getTextLineHeight()) * 0.5 }, color(theme.fg3), "{s}", .{label});
    }
}

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

fn drawEffectPlot(app: anytype, target: spectrum_ed.EqTarget, draw_list: zgui.DrawList, region: Rect, unit: *ws.FxUnit, accent: [4]f32) void {
    const axes = plotAxes(unit.kind());
    // The horizontal axis gets a strip of its own under the curve, for the
    // same reason the vertical one is named on the title row.
    const label_h = zgui.getTextLineHeight() + 4;
    const plot = Rect{ .x = region.x, .y = region.y, .w = region.w, .h = region.h - label_h };
    if (plot.h <= 0) return;
    draw_list.addText(.{ plot.x, plot.y + plot.h + 4 }, color(theme.fg3), "{s}", .{axes.x_lo});
    if (axes.x_hi.len > 0) {
        const hi_w = zgui.calcTextSize(axes.x_hi, .{})[0];
        draw_list.addText(.{ plot.x + plot.w - hi_w, plot.y + plot.h + 4 }, color(theme.fg3), "{s}", .{axes.x_hi});
    }

    for (1..4) |i| {
        const t = @as(f32, @floatFromInt(i)) / 4;
        draw_list.addLine(.{ .p1 = .{ plot.x + plot.w * t, plot.y }, .p2 = .{ plot.x + plot.w * t, plot.y + plot.h }, .col = color(theme.line), .thickness = 1 });
        draw_list.addLine(.{ .p1 = .{ plot.x, plot.y + plot.h * t }, .p2 = .{ plot.x + plot.w, plot.y + plot.h * t }, .col = color(theme.line), .thickness = 1 });
    }

    // Only the filter reads frequency across, so only the filter can put a
    // spectrum behind its curve. Over a transfer plot the trace shares an axis
    // with nothing and reads as a second, wrong curve.
    if (unit.kind() == .filter) {
        const spectrum = switch (target) {
            .track => app.core.session.engine.trackSpectrumSnapshot(app.core.eq_track),
            .master => app.core.session.engine.masterSpectrumSnapshot(),
            .group => app.core.session.engine.groupSpectrumSnapshot(app.core.eq_group),
        };
        if (spectrum) |snap| {
            var spectrum_points: [snap.bins.len][2]f32 = undefined;
            for (snap.bins, 0..) |db, i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(snap.bins.len - 1));
                const level = std.math.clamp((db + 90) / 90, 0, 1);
                spectrum_points[i] = .{ plot.x + t * plot.w, plot.y + (1 - level) * plot.h };
            }
            draw_list.addPolyline(&spectrum_points, .{ .col = color(.{ theme.audio[0], theme.audio[1], theme.audio[2], 0.42 }), .thickness = 1.5 });
        }
    }

    // Sampled far denser than the curve's own detail: at 65 points the
    // reverb's 26-half-cycle tail aliased into an irregular sawtooth and the
    // crusher's 2^(bits-1) staircase collapsed onto the diagonal, so a
    // default 8-bit crush was drawn as a bypass line.
    var points: [257][2]f32 = undefined;
    const amount = normalizedParam(app, unit, 0);
    const shape = normalizedParam(app, unit, 1);
    for (&points, 0..) |*point, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(points.len - 1));
        const y = if (unit.kind() == .filter) filterDisplayValue(&unit.payload.filter, t) else effectDisplayValue(unit.kind(), t, amount, shape);
        point.* = .{ plot.x + t * plot.w, plot.y + (1.0 - y) * plot.h };
    }
    draw_list.pathLineTo(.{ plot.x, plot.y + plot.h });
    for (points) |point| draw_list.pathLineTo(point);
    draw_list.pathLineTo(.{ plot.x + plot.w, plot.y + plot.h });
    draw_list.pathFillConcave(color(.{ accent[0], accent[1], accent[2], 0.12 }));
    draw_list.addPolyline(&points, .{ .col = color(accent), .thickness = 2.5 });
}

const PlotAxes = struct { x_lo: []const u8, x_hi: []const u8 = "", y: []const u8 };

/// What the plot's two axes actually mean. Every curve used to be labelled
/// IN/OUT, which is only true of the level-domain ones - a delay's tail runs
/// across time, and a filter across frequency.
fn plotAxes(kind: ws.FxKind) PlotAxes {
    return switch (kind) {
        .filter => .{ .x_lo = "20 Hz", .x_hi = "20 kHz", .y = "LEVEL" },
        .delay, .reverb => .{ .x_lo = "TIME", .y = "LEVEL" },
        .chorus, .phaser, .flanger => .{ .x_lo = "TIME", .y = "OFFSET" },
        // A shifter maps frequency to frequency; IN/OUT reads as a level
        // transfer, which is the one thing it does not do.
        .freq_shift => .{ .x_lo = "IN FREQ", .y = "OUT FREQ" },
        else => .{ .x_lo = "IN", .y = "OUT" },
    };
}

fn showsEffectCurve(kind: ws.FxKind) bool {
    return switch (kind) {
        .utility, .stereo_width, .auto_pan, .mb_comp, .ott, .transient_shaper, .tape, .clap, .vst3 => false,
        else => true,
    };
}

fn normalizedParam(app: anytype, unit: *ws.FxUnit, index: usize) f32 {
    if (index >= spectrum_ed.visibleParamCount(&app.core, unit.kind(), &unit.payload)) return 0.5;
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    if (range[1] <= range[0]) return 0.5;
    return std.math.clamp((spectrum_ed.getParam(&unit.payload, index) - range[0]) / (range[1] - range[0]), 0, 1);
}

fn effectDisplayValue(kind: ws.FxKind, t: f32, amount: f32, shape: f32) f32 {
    return switch (kind) {
        .gate => if (t < amount * 0.8) 0.08 else t,
        .comp, .mb_comp, .ott, .limiter, .transient_shaper => if (t < amount) t else amount + (t - amount) * (0.2 + shape * 0.45),
        .sat => 0.5 + 0.5 * std.math.tanh((t * 2.0 - 1.0) * std.math.pow(f32, 10.0, amount * 1.8)) / std.math.tanh(std.math.pow(f32, 10.0, amount * 1.8)),
        .crush => @round(t * std.math.pow(f32, 2.0, amount * 15.0)) / std.math.pow(f32, 2.0, amount * 15.0),
        // An LFO offset swings about a centre - it does not climb. The old
        // `t + sin(...)` baseline drew the same rising ramp a transfer curve
        // wants under a TIME/OFFSET pair of axes, and took its cycle count
        // from the depth knob and its amplitude from the rate knob.
        .chorus, .flanger, .phaser, .auto_pan => 0.5 + @sin(t * std.math.pi * 2.0 * (1.0 + amount * 5.0)) * (0.08 + shape * 0.38),
        .freq_shift => std.math.clamp(t + (amount - 0.5) * 0.35, 0, 1),
        .delay => std.math.clamp(@exp(-t * (1.5 + shape * 4.0)) * (0.55 + 0.4 * @sin(t * std.math.pi * (6.0 + amount * 10.0))), 0, 1),
        .reverb => std.math.clamp(@exp(-t * (0.8 + (1.0 - amount) * 4.0)) * (0.7 + 0.2 * @sin(t * std.math.pi * 26.0)), 0, 1),
        .eq, .filter, .utility, .stereo_width, .tape => t,
        .clap, .vst3 => t,
    };
}

fn filterDisplayValue(filter: anytype, t: f32) f32 {
    const freq = 20.0 * std.math.pow(f32, 1000.0, t);
    const x = freq / std.math.clamp(filter.cutoff_hz, 20, 20_000);
    const q = std.math.clamp(filter.resonance, 0.1, 1.4);
    const magnitude = switch (@as(u2, @intFromFloat(@round(std.math.clamp(filter.mode, 0, 2))))) {
        0 => 1.0 / @sqrt(1.0 + x * x * x * x),
        1 => x * x / @sqrt(1.0 + x * x * x * x),
        else => (x / q) / @sqrt((1.0 - x * x) * (1.0 - x * x) + (x / q) * (x / q)),
    };
    const db = 20.0 * std.math.log10(@max(magnitude, 1e-6));
    return std.math.clamp((db + 48.0) / 54.0, 0, 1);
}

/// One live readout. Every dynamics unit's display is some number of these,
/// built by `meterRows` and drawn by `drawMeterStack` - three helpers laying
/// their own rows out from a fraction of the pane height is what let a band
/// label land on top of the bar above it.
const MeterRow = struct {
    label: []const u8,
    /// 0..1 filled from the left, or -1..1 filled out from the centre when
    /// `bipolar`.
    value: f32,
    bipolar: bool = false,
    text: []const u8 = "",
};

const meter_row_h: f32 = 24;
const meter_bar_h: f32 = 12;
/// Room for the widest row label ("HIGH", "GAIN RED.") and the widest readout
/// ("-12.0 dB"), so every bar in a stack starts and ends on the same x.
const meter_label_w: f32 = 76;
const meter_value_w: f32 = 62;

fn drawMeterStack(draw_list: zgui.DrawList, box: Rect, rows: []const MeterRow, accent: [4]f32) void {
    const lo = box.x + meter_label_w;
    const hi = box.x + box.w - meter_value_w;
    if (hi <= lo) return;
    const stack_h = @as(f32, @floatFromInt(rows.len)) * meter_row_h - (meter_row_h - meter_bar_h);
    const text_offset = (meter_bar_h - zgui.getTextLineHeight()) * 0.5;
    var y = box.y + @max(0, (box.h - stack_h) * 0.5);
    for (rows) |row| {
        draw_list.addText(.{ box.x, y + text_offset }, color(theme.fg2), "{s}", .{row.label});
        draw_list.addRectFilled(.{ .pmin = .{ lo, y }, .pmax = .{ hi, y + meter_bar_h }, .col = color(theme.bg2), .rounding = meter_bar_h * 0.5 });
        const start = if (row.bipolar) (lo + hi) * 0.5 else lo;
        const end = if (row.bipolar)
            start + (hi - lo) * 0.5 * std.math.clamp(row.value, -1, 1)
        else
            lo + (hi - lo) * std.math.clamp(row.value, 0, 1);
        draw_list.addRectFilled(.{ .pmin = .{ @min(start, end), y }, .pmax = .{ @max(start, end), y + meter_bar_h }, .col = color(accent), .rounding = meter_bar_h * 0.5 });
        if (row.bipolar) draw_list.addLine(.{ .p1 = .{ start, y - 2 }, .p2 = .{ start, y + meter_bar_h + 2 }, .col = color(theme.line_soft), .thickness = 1 });
        draw_list.addText(.{ hi + 10, y + text_offset }, color(theme.fg3), "{s}", .{row.text});
        y += meter_row_h;
    }
}

fn meterRows(unit: *ws.FxUnit, rows: *[3]MeterRow, text: *[3][20]u8) []const MeterRow {
    switch (unit.payload) {
        .gate => |*gate| {
            rows[0] = .{ .label = "OPEN", .value = gate.gain, .text = fmtPercent(&text[0], gate.gain) };
            return rows[0..1];
        },
        .comp => |*comp| {
            rows[0] = .{ .label = "GAIN RED.", .value = -comp.gain_reduction_db / 24.0, .text = fmtDb(&text[0], comp.gain_reduction_db) };
            return rows[0..1];
        },
        .limiter => |*lim| {
            // Same dB-over-24 deflection the compressor's row uses: a bar off
            // the raw gain put -6dB of limiting at half scale next to -6dB of
            // compression at a quarter, under the same label.
            const reduction_db = 20.0 * std.math.log10(@max(lim.gain, 1e-4));
            rows[0] = .{ .label = "GAIN RED.", .value = -reduction_db / 24.0, .text = fmtDb(&text[0], reduction_db) };
            return rows[0..1];
        },
        .mb_comp => |*comp| return bandGainRows(rows, text, comp.gain_db),
        .ott => |*ott| return bandGainRows(rows, text, ott.mb.gain_db),
        .transient_shaper => |*shaper| {
            rows[0] = .{ .label = "GAIN", .value = shaper.applied_gain_db / gain_meter_scale, .bipolar = true, .text = fmtDb(&text[0], shaper.applied_gain_db) };
            return rows[0..1];
        },
        .stereo_width => |*width| {
            rows[0] = .{ .label = "CORR", .value = width.correlation, .bipolar = true, .text = fmtSigned(&text[0], width.correlation) };
            return rows[0..1];
        },
        .auto_pan => |*pan| {
            const depth = std.math.clamp(pan.depth, 0, 1);
            const is_pan = pan.phase >= 0.5;
            const left = 1.0 - depth * (pan.lfo.sine(0) + 1.0) * 0.5;
            const right = 1.0 - depth * (pan.lfo.sine(if (is_pan) 0.5 else 0) + 1.0) * 0.5;
            rows[0] = .{ .label = "LEFT", .value = left, .text = fmtPercent(&text[0], left) };
            rows[1] = .{ .label = "RIGHT", .value = right, .text = fmtPercent(&text[1], right) };
            return rows[0..2];
        },
        .tape => |*tape| {
            const wow = tape.lfo_wow.sine(0) * tape.wow_depth;
            rows[0] = .{ .label = "WOW", .value = wow, .bipolar = true, .text = fmtSigned(&text[0], wow) };
            return rows[0..1];
        },
        else => return rows[0..0],
    }
}

/// Full-scale deflection every bipolar dB meter here reads against: the
/// multiband upward stage's own 24dB range plus makeup, which OTT's fixed
/// tuning spends 9dB of. A 24dB scale pinned all three band bars the moment
/// the unit idled, and the transient shaper's own 12dB scale pinned on any
/// output trim past -12dB (its applied gain spans -36..+24).
const gain_meter_scale: f32 = 36.0;

fn bandGainRows(rows: *[3]MeterRow, text: *[3][20]u8, gains: [3]f32) []const MeterRow {
    const labels = [3][]const u8{ "LOW", "MID", "HIGH" };
    for (gains, labels, 0..) |gain, label, i| {
        rows[i] = .{ .label = label, .value = gain / gain_meter_scale, .bipolar = true, .text = fmtDb(&text[i], gain) };
    }
    return rows[0..3];
}

/// Zig's formatter has no forced-sign flag, and a bipolar readout that only
/// ever shows a sign when it is negative reads as an absolute value.
fn fmtDb(buf: []u8, db: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d:.1} dB", .{ if (db > 0) "+" else "", db }) catch "";
}

fn fmtSigned(buf: []u8, value: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d:.2}", .{ if (value > 0) "+" else "", value }) catch "";
}

fn fmtPercent(buf: []u8, value: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.0}%", .{std.math.clamp(value, 0, 1) * 100}) catch "";
}

/// Shortest and tallest a param card is allowed to be, and the gap drawn
/// between rows of them.
const param_row_min: f32 = 82;
const param_row_max: f32 = 150;
const param_row_gap: f32 = 8;

/// How the cards pack at the width the editor draws them in. Both the grid
/// and the display pane above it read this, so they agree on the shape before
/// either is drawn.
fn paramGrid(param_count: usize) spectrum_ed.ParamGrid {
    const available = zgui.getContentRegionAvail()[0];
    const max_columns: usize = @intFromFloat(@max(1, @floor((available + param_row_gap) / 210)));
    return spectrum_ed.paramGrid(param_count, @min(max_columns, 4));
}

/// Vertical cost of getting from one row of cards to the next: the gap dummy
/// plus the item spacing ImGui adds after both it and the row. Left out of
/// the row height, the grid overflowed the window by exactly this per row and
/// the last row of knobs was cut in half.
fn rowGapCost() f32 {
    return param_row_gap + 2 * zgui.getStyle().item_spacing[1];
}

/// Least height the grid can be drawn in - what the display pane above it
/// must leave over.
fn gridFloor(rows: usize) f32 {
    if (rows == 0) return 0;
    const count: f32 = @floatFromInt(rows);
    return count * param_row_min + (count - 1) * rowGapCost();
}

fn drawParamGrid(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, grid: spectrum_ed.ParamGrid) void {
    const available = zgui.getContentRegionAvail()[0];
    const gap: f32 = param_row_gap;
    const available_height = zgui.getContentRegionAvail()[1] - rowGapCost() * @as(f32, @floatFromInt(grid.rows -| 1));
    const row_height = std.math.clamp(
        available_height / @as(f32, @floatFromInt(@max(grid.rows, 1))),
        param_row_min,
        param_row_max,
    );
    const knob_diameter = std.math.clamp(row_height - 44, 38, 64);

    for (0..grid.rows) |row| {
        const row_columns = grid.columnsInRow(row);
        const width = (available - gap * @as(f32, @floatFromInt(row_columns -| 1))) / @as(f32, @floatFromInt(row_columns));
        for (0..row_columns) |column| {
            const index = grid.index(row, column) orelse continue;
            if (column > 0) zgui.sameLine(.{ .spacing = gap });
            var id_buf: [40]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "fx-param-card-{d}", .{index}) catch continue;
            const selected = app.core.fx_param == index;
            zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = if (selected) theme.bg3 else theme.bg1 });
            zgui.pushStyleColor4f(.{ .idx = .border, .c = if (selected) kindAccent(unit.kind()) else theme.line });
            if (zgui.beginChild(id, .{ .w = if (column + 1 == row_columns) 0 else width, .h = row_height, .child_flags = .{ .border = true } })) {
                drawParam(app, target, unit, index, knob_diameter);
            }
            zgui.endChild();
            zgui.popStyleColor(.{ .count = 2 });
        }
        if (row + 1 < grid.rows) zgui.dummy(.{ .w = 0, .h = gap });
    }
}

const eq_freq_min: f32 = 20.0;
const eq_freq_max: f32 = 20_000.0;
const eq_db_min: f32 = -18.0;
const eq_db_max: f32 = 18.0;

fn drawEqEditor(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit) void {
    ensureEqAnalyzer(app, target);
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

fn ensureEqAnalyzer(app: anytype, target: spectrum_ed.EqTarget) void {
    const key: u32 = switch (target) {
        .track => 0x10000 | @as(u32, app.core.eq_track),
        .master => 0x20000,
        .group => 0x30000 | @as(u32, app.core.eq_group),
    };
    if (app.eq_analyzer_key == key) return;
    _ = app.core.session.engine.send(.{ .set_spectrum_active = .{
        .source = switch (target) {
            .track => .track,
            .master => .master,
            .group => .group,
        },
        .track = if (target == .track) app.core.eq_track else 0,
        .group = if (target == .group) app.core.eq_group else 0,
    } });
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
        const accent = eqBandColor(i);
        const selected = i == selected_band;
        draw_list.addCircleFilled(.{ .p = node, .r = if (selected) 10 else 8, .col = color(if (selected) accent else .{ accent[0], accent[1], accent[2], 0.72 }) });
        draw_list.addCircle(.{ .p = node, .r = if (selected) 12 else 10, .col = color(if (selected) theme.fg0 else accent), .thickness = if (selected) 2 else 1 });
        draw_list.addText(.{ node[0] - 4, node[1] - 8 }, color(theme.bg0), "{d}", .{i + 1});
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
            syncChain(app, target);
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
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (selected) theme.bg0 else accent });
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
            syncChain(app, target);
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
    if (result.changed) {
        history.noteFxNudge(&app.core, target, app.core.fx_focus, index);
        spectrum_ed.setParam(&app.core, &unit.payload, index, value);
        app.core.fx_param = index;
        app.core.dirty = true;
        syncChain(app, target);
    }
    if (result.activated) {
        app.core.fx_param = index;
        app.core.eq_band_select = false;
    }
}

fn drawEqSlider(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, label_text: []const u8, format: [:0]const u8, logarithmic: bool) void {
    var value = spectrum_ed.getParam(&unit.payload, index);
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##eq-control-{d}", .{ label_text, index }) catch return;
    const focused = !app.core.eq_band_select and app.core.fx_param == index;
    const accent = eqBandColor(index / spectrum_ed.eq_fields_per_band);
    const result = widgets.paramKnob(label_text, label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format, .accent = accent, .focused = focused, .logarithmic = logarithmic });
    if (result.changed) {
        history.noteFxNudge(&app.core, target, app.core.fx_focus, index);
        spectrum_ed.setParam(&app.core, &unit.payload, index, value);
        app.core.fx_param = index;
        app.core.dirty = true;
        syncChain(app, target);
    }
    if (result.activated) {
        app.core.fx_param = index;
        app.core.eq_band_select = false;
    }
}

fn eqBandColor(index: usize) [4]f32 {
    const palette = [_][4]f32{
        rgb(0xc57b89), rgb(0xc29370), rgb(0xb6aa72), rgb(0x83ad82),
        rgb(0x72aaa8), rgb(0x759bc2), rgb(0x967fc0), rgb(0xbb7fae),
    };
    return palette[index % palette.len];
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

fn combinedResponseDb(eq: *const ws.dsp.eq.ParametricEq, freq: f32) f32 {
    var total: f32 = 0;
    for (eq.bands) |band| total += bandResponseDb(band, eq.sr, freq);
    return total;
}

fn bandResponseDb(band: anytype, sample_rate: f32, freq: f32) f32 {
    const omega = 2.0 * std.math.pi * freq / sample_rate;
    const cos_1 = std.math.cos(omega);
    const sin_1 = std.math.sin(omega);
    const cos_2 = std.math.cos(omega * 2.0);
    const sin_2 = std.math.sin(omega * 2.0);
    const num_re = band.b0 + band.b1 * cos_1 + band.b2 * cos_2;
    const num_im = -(band.b1 * sin_1 + band.b2 * sin_2);
    const den_re = 1.0 + band.a1 * cos_1 + band.a2 * cos_2;
    const den_im = -(band.a1 * sin_1 + band.a2 * sin_2);
    const magnitude_sq = @max(1.0e-12, (num_re * num_re + num_im * num_im) / @max(1.0e-12, den_re * den_re + den_im * den_im));
    const stages: f32 = @floatFromInt(if (ws.dsp.eq.usesSlope(band.kind)) band.slope else @as(u8, 1));
    return 10.0 * std.math.log10(magnitude_sq) * stages;
}

fn drawParam(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, knob_diameter: f32) void {
    const disabled = autoPanParamDisabled(&unit.payload, index);
    zgui.beginDisabled(.{ .disabled = disabled });
    defer zgui.endDisabled();
    if (spectrum_ed.paramToggleNames(unit.kind(), index)) |names| {
        drawParamToggle(app, target, unit, index, names);
        return;
    }
    if (spectrum_ed.isListParam(unit.kind(), index)) {
        drawParamList(app, target, unit, index);
        return;
    }
    var value = spectrum_ed.getParam(&unit.payload, index);
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    const format: [:0]const u8 = if (range[1] >= 100) "%.0f" else "%.2f";
    var value_buf: [32]u8 = undefined;
    const display = spectrum_ed.formatValue(&app.core, &value_buf, &unit.payload, index);
    var name_buf: [64]u8 = undefined;
    const name = spectrum_ed.formatParamName(&name_buf, &unit.payload, index);
    var label_buf: [80]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##gui-fx-{d}", .{ name, index }) catch return;
    const focused = app.core.fx_param == index;
    const control_width = knob_diameter + 120;
    const spare = zgui.getContentRegionAvail()[0] - control_width;
    if (spare > 0) zgui.setCursorPosX(zgui.getCursorPosX() + spare * 0.5);
    const result = widgets.paramKnob(name, label, .{
        .v = &value,
        .min = range[0],
        .max = range[1],
        .cfmt = format,
        .display = display,
        .accent = kindAccent(unit.kind()),
        .focused = focused,
        .diameter = knob_diameter,
        .logarithmic = perceptualParam(name, range),
    });
    if (result.changed) {
        history.noteFxNudge(&app.core, target, app.core.fx_focus, index);
        spectrum_ed.setParam(&app.core, &unit.payload, index, value);
        spectrum_ed.clearStaleSidechainPad(&app.core, &unit.payload);
        app.core.fx_param = index;
        app.core.dirty = true;
        syncChain(app, target);
    }
    if (result.activated) app.core.fx_param = index;
}

fn autoPanParamDisabled(payload: *const ws.FxPayload, index: usize) bool {
    return switch (payload.*) {
        .auto_pan => |pan| (index == 0 and pan.sync >= 0.5) or (index == 2 and pan.sync < 0.5),
        else => false,
    };
}

fn perceptualParam(name: []const u8, range: [2]f32) bool {
    if (!(range[0] > 0 and range[1] > range[0])) return false;
    inline for (.{ "attack", "release", "time", "rate", "cutoff", "freq", " q" }) |part| {
        if (std.mem.indexOf(u8, name, part) != null) return true;
    }
    return std.mem.eql(u8, name, "q");
}

/// Two-option list param (`paramToggleNames`, e.g. multiband comp's
/// classic/OTT style) as a highlighted button pair instead of a knob - the
/// same bracket-pair idiom `synth.zig`/`sampler.zig` already use for their
/// own booleans.
fn drawParamToggle(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, names: [2][]const u8) void {
    const value = spectrum_ed.getParam(&unit.payload, index);
    const focused = app.core.fx_param == index;
    const accent = kindAccent(unit.kind());
    const spare = zgui.getContentRegionAvail()[0] - 180;
    if (spare > 0) zgui.setCursorPosX(zgui.getCursorPosX() + spare * 0.5);
    var name_buf: [64]u8 = undefined;
    zgui.textColored(if (focused) accent else theme.fg1, "{s}", .{spectrum_ed.formatParamName(&name_buf, &unit.payload, index)});
    for (names, 0..) |name, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 5 });
        const active = (value >= 0.5) == (i == 1);
        var btn_buf: [40]u8 = undefined;
        const btn_id = std.fmt.bufPrintZ(&btn_buf, "{s}##gui-fx-{d}-{d}", .{ name, index, i }) catch continue;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) accent else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else theme.fg2 });
        if (zgui.button(btn_id, .{ .h = 26 }) and !active) {
            history.noteFxNudge(&app.core, target, app.core.fx_focus, index);
            spectrum_ed.setParam(&app.core, &unit.payload, index, if (i == 1) 1.0 else 0.0);
            app.core.fx_param = index;
            app.core.dirty = true;
            syncChain(app, target);
        }
        zgui.popStyleColor(.{ .count = 2 });
    }
}

/// List-entry param (`isListParam`, e.g. the compressor's sidechain
/// track/pad) as a prev/next stepper showing the resolved name instead of a
/// knob - see `widgets.listStepper`.
fn drawParamList(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize) void {
    var value = spectrum_ed.getParam(&unit.payload, index);
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    var name_buf: [64]u8 = undefined;
    const name = spectrum_ed.formatParamName(&name_buf, &unit.payload, index);
    var label_buf: [80]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##gui-fx-{d}", .{ name, index }) catch return;
    var value_buf: [32]u8 = undefined;
    const display = spectrum_ed.formatValue(&app.core, &value_buf, &unit.payload, index);
    const focused = app.core.fx_param == index;
    const spare = zgui.getContentRegionAvail()[0] - 190;
    if (spare > 0) zgui.setCursorPosX(zgui.getCursorPosX() + spare * 0.5);
    const result = widgets.listStepper(name, label, .{ .v = &value, .min = range[0], .max = range[1], .display = display, .accent = kindAccent(unit.kind()), .focused = focused });
    if (result.changed) {
        history.noteFxNudge(&app.core, target, app.core.fx_focus, index);
        spectrum_ed.setParam(&app.core, &unit.payload, index, value);
        spectrum_ed.clearStaleSidechainPad(&app.core, &unit.payload);
        app.core.fx_param = index;
        app.core.dirty = true;
        syncChain(app, target);
    }
    if (result.activated) app.core.fx_param = index;
}

fn syncChain(app: anytype, target: spectrum_ed.EqTarget) void {
    switch (target) {
        .track => if (app.core.eq_track < app.core.session.racks.items.len) {
            const rack = app.core.session.racks.items[app.core.eq_track];
            app.core.session.syncTrackChain(app.core.eq_track, rack);
        },
        .master => app.core.session.syncMasterChain(),
        .group => app.core.session.syncGroupChain(app.core.eq_group),
    }
}

fn drawEmptyState(app: anytype, target: spectrum_ed.EqTarget) void {
    ensureEqAnalyzer(app, target);
    drawBusMonitor(app, target);
    zgui.spacing();
    const below_top = zgui.getCursorPosY();
    var explanation_buf: [96]u8 = undefined;
    const explanation = std.fmt.bufPrint(&explanation_buf, "Insert an effect to shape this {s}.", .{targetRole(target)}) catch "Insert an effect.";
    if (widgets.emptyState(.{
        .id = "empty-fx-chain",
        .title = "BUILD THE SIGNAL CHAIN",
        .explanation = explanation,
        .shortcut = "a",
        .action = "ADD EFFECT",
        .accent = targetAccent(target),
    })) spectrum_ed.openPicker(&app.core, target);
    // The empty-state card is one fixed size whatever the bus is.
    monitor_fit.settle(below_top, 0);
}

fn drawBusMonitor(app: anytype, target: spectrum_ed.EqTarget) void {
    const available = zgui.getContentRegionAvail();
    const height = monitor_fit.height(120, 330);
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("empty-chain-monitor", .{ .w = available[0], .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + available[0], origin[1] + height }, .col = color(theme.bg0), .rounding = style.panel_rounding });
    draw_list.addText(.{ origin[0] + 12, origin[1] + 10 }, color(targetAccent(target)), "{s} MONITOR", .{targetMonitorLabel(target)});

    for (1..6) |i| {
        const x = origin[0] + available[0] * @as(f32, @floatFromInt(i)) / 6;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] + 36 }, .p2 = .{ x, origin[1] + height - 28 }, .col = color(theme.line), .thickness = 1 });
    }
    for (1..4) |i| {
        const y = origin[1] + 36 + (height - 64) * @as(f32, @floatFromInt(i)) / 4;
        draw_list.addLine(.{ .p1 = .{ origin[0], y }, .p2 = .{ origin[0] + available[0], y }, .col = color(theme.line), .thickness = 1 });
    }

    const snap = switch (target) {
        .track => app.core.session.engine.trackSpectrumSnapshot(app.core.eq_track),
        .master => app.core.session.engine.masterSpectrumSnapshot(),
        .group => app.core.session.engine.groupSpectrumSnapshot(app.core.eq_group),
    };
    const playing = app.core.session.engine.uiSnapshot().playing;
    if (snap) |spectrum| {
        var points: [spectrum.bins.len][2]f32 = undefined;
        for (spectrum.bins, 0..) |db, i| {
            const x = origin[0] + available[0] * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(spectrum.bins.len - 1));
            const norm = std.math.clamp((db + 90) / 90, 0, 1);
            points[i] = .{ x, origin[1] + 36 + (height - 64) * (1 - norm) };
        }
        draw_list.addPolyline(&points, .{ .col = color(targetAccent(target)), .thickness = 2 });
    }
    if (!playing or snap == null) {
        const message = "Play the transport to monitor audio";
        const text_size = zgui.calcTextSize(message, .{});
        draw_list.addText(.{
            origin[0] + (available[0] - text_size[0]) * 0.5,
            origin[1] + height * 0.5 - text_size[1] * 0.5,
        }, color(theme.fg3), "{s}", .{message});
    }
    draw_list.addText(.{ origin[0] + 12, origin[1] + height - 24 }, color(theme.fg3), "20 Hz", .{});
    draw_list.addText(.{ origin[0] + available[0] - 52, origin[1] + height - 24 }, color(theme.fg3), "20 kHz", .{});
}

fn targetRole(target: spectrum_ed.EqTarget) []const u8 {
    return switch (target) {
        .track => "track",
        .master => "master output",
        .group => "group bus",
    };
}

fn targetMonitorLabel(target: spectrum_ed.EqTarget) []const u8 {
    return switch (target) {
        .track => "TRACK SPECTRUM",
        .master => "MASTER SPECTRUM",
        .group => "GROUP SPECTRUM",
    };
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

test "filter display follows selected response mode" {
    var payload = ws.FxPayload{ .filter = .{ .sample_rate = 48_000, .cutoff_hz = 1000 } };
    payload.filter.mode = 0;
    try std.testing.expect(filterDisplayValue(&payload.filter, 0.1) > filterDisplayValue(&payload.filter, 0.9));
    payload.filter.mode = 1;
    try std.testing.expect(filterDisplayValue(&payload.filter, 0.1) < filterDisplayValue(&payload.filter, 0.9));
    payload.filter.mode = 2;
    try std.testing.expect(filterDisplayValue(&payload.filter, 0.5) > filterDisplayValue(&payload.filter, 0.1));
}

test "auto-pan timing disables only inactive source" {
    var payload = ws.FxPayload{ .auto_pan = .{ .sample_rate = 48_000 } };
    try std.testing.expect(autoPanParamDisabled(&payload, 0));
    try std.testing.expect(!autoPanParamDisabled(&payload, 2));
    payload.auto_pan.sync = 0;
    try std.testing.expect(!autoPanParamDisabled(&payload, 0));
    try std.testing.expect(autoPanParamDisabled(&payload, 2));
}

test "effect display uses truthful curve types" {
    try std.testing.expect(!showsEffectCurve(.mb_comp));
    try std.testing.expect(!showsEffectCurve(.tape));
    try std.testing.expect(showsEffectCurve(.sat));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), effectDisplayValue(.crush, 0.3, 2.0 / 15.0, 0), 1e-6);
}
