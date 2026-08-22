const std = @import("std");
const ws = @import("wstudio");
const gate_mod = ws.dsp.gate;
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const spectrum_ed = @import("../../ui/editors/fx_editor.zig");
const history = @import("../../ui/history.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const scroll = @import("../scroll.zig");
const fx_eq = @import("fx_eq.zig");

const color = style.color;
const rgb = style.rgb;
const theme = &style.palette;

/// The empty chain's monitor yields its height to the controls under it
/// rather than pushing them off screen (see scroll.PaneFit). The EQ editor's
/// own graph has an identical fit in fx_eq.zig - they never share a frame, so
/// a trim measured for one has nothing to say about the other.
/// The effect display sizes itself off `gridFloor` instead, because its param
/// cards stretch - measuring content that grows into whatever the e gives
/// back would leave the two chasing each other.
var monitor_fit: scroll.PaneFit = .{};

pub fn draw(app: anytype) void {
    const target = spectrum_ed.currentTarget(&app.core);
    const fx = spectrum_ed.fxPtr(&app.core, target) orelse {
        zgui.textDisabled("FX chain unavailable", .{});
        return;
    };
    if (fx.units.items.len > 0) app.core.fx_focus = @min(app.core.fx_focus, fx.units.items.len - 1);

    drawSignalChain(app, target, fx);
    zgui.spacing();

    if (spectrum_ed.focusedUnit(&app.core, fx)) |unit| {
        drawEditor(app, target, unit);
    } else {
        drawEmptyState(app, target);
    }
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
    // Room for a four-character strip label (COMP, VERB) plus the bypass dot
    // at the far edge - at 58 the two touched.
    const slot_w: f32 = 68;
    var slot_action: ?SlotAction = null;
    for (fx.units.items, 0..) |unit, i| {
        zgui.sameLine(.{ .spacing = gap });
        zgui.textDisabled(">", .{});
        zgui.sameLine(.{ .spacing = gap });
        slot_action = drawSlot(app, target, unit, i, slot_w) orelse slot_action;
    }
    if (fx.units.items.len < ws.Fx.max_units) {
        zgui.sameLine(.{ .spacing = gap });
        zgui.textDisabled(">", .{});
        zgui.sameLine(.{ .spacing = gap });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.focus_soft });
        if (widgets.iconButton(icons.plus ++ "##fx-chain-add", "Insert effect  a")) spectrum_ed.openPicker(&app.core, target);
        zgui.popStyleColor(.{ .count = 2 });
    }
    zgui.sameLine(.{ .spacing = gap });
    zgui.textDisabled("> OUT", .{});

    if (slot_action) |action| {
        spectrum_ed.setFocus(&app.core, target, action.index);
        switch (action.kind) {
            .bypass => spectrum_ed.toggleBypass(&app.core, target),
            .remove => spectrum_ed.removeFocused(&app.core, target),
        }
    }

    // One badge for the view, like every other view: two identical `?`
    // circles side by side read as a glitch and gave no way to tell which
    // one described the chain and which the parameters.
    const chain_hint = "a insert  tab select slot  b bypass";
    widgets.hoverHelp(if (spectrum_ed.focusedUnit(&app.core, fx)) |unit|
        if (unit.kind() == .eq)
            (if (app.core.eq_band_select)
                chain_hint ++ "  h/l band  enter edit"
            else
                chain_hint ++ "  j/k field  h/l adjust")
        else
            chain_hint ++ "  j/k parameter  h/l adjust"
    else
        chain_hint);
}

const SlotAction = struct { index: usize, kind: enum { bypass, remove } };

fn drawSlot(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, width: f32) ?SlotAction {
    const origin = zgui.getCursorScreenPos();
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "fx-slot-{d}", .{index}) catch return null;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = 36 });
    const hovered = zgui.isItemHovered(.{});
    const selected = app.core.fx_focus == index;
    const draw_list = zgui.getWindowDrawList();
    const accent = if (unit.bypassed) theme.fg3 else kindAccent(unit.kind());
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 36 }, .col = color(if (selected) theme.bg4 else if (hovered) theme.bg3 else theme.bg2), .rounding = style.item_rounding });
    draw_list.addRect(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 36 }, .col = color(if (selected) theme.focus else theme.line), .rounding = style.item_rounding, .thickness = if (selected) 2 else 1 });
    draw_list.addText(.{ origin[0] + 8, origin[1] + 9 }, color(if (unit.bypassed) theme.fg3 else theme.fg0), "{s}", .{spectrum_ed.stripLabel(unit.kind())});
    widgets.accentMark(draw_list, .{ origin[0] + width - 7, origin[1] + 9 }, .{ origin[0] + width - 4, origin[1] + 27 }, accent);
    if (clicked and !selected) spectrum_ed.setFocus(&app.core, target, index);
    var action: ?SlotAction = null;
    if (zgui.beginPopupContextItem()) {
        if (zgui.menuItem(if (unit.bypassed) "Enable" else "Bypass", .{ .shortcut = "b", .selected = unit.bypassed })) action = .{ .index = index, .kind = .bypass };
        if (zgui.menuItem("Remove", .{ .shortcut = "x" })) action = .{ .index = index, .kind = .remove };
        zgui.endPopup();
    }
    if (zgui.beginDragDropSource(.{})) {
        _ = zgui.setDragDropPayload("WSTUDIO_FX_SLOT", std.mem.asBytes(&index), .once);
        zgui.text("Move {s}", .{spectrum_ed.stripLabel(unit.kind())});
        zgui.endDragDropSource();
    }
    if (zgui.beginDragDropTarget()) {
        if (zgui.acceptDragDropPayload("WSTUDIO_FX_SLOT", .{})) |payload| {
            if (payload.delivery and payload.data_size == @sizeOf(usize)) {
                const bytes = @as([*]const u8, @ptrCast(payload.data.?))[0..@sizeOf(usize)];
                const source = std.mem.bytesToValue(usize, bytes);
                spectrum_ed.setFocus(&app.core, target, source);
                spectrum_ed.moveFocusedTo(&app.core, target, index);
            }
        }
        zgui.endDragDropTarget();
    }
    return action;
}

const kindAccent = style.fxKindAccent;

fn drawEditor(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit) void {
    const accent = kindAccent(unit.kind());
    zgui.textColored(accent, "{s}", .{spectrum_ed.editorTitle(unit.kind())});
    zgui.sameLine(.{});
    zgui.textDisabled("unit {d}  {s} {s}", .{ app.core.fx_focus + 1, if (unit.bypassed) "\u{25CB}" else "\u{25CF}", if (unit.bypassed) "BYPASSED" else "ACTIVE" });
    zgui.sameLine(.{ .spacing = 18 });
    if (widgets.activeIconButton(icons.bypass ++ "##fx-bypass", if (unit.bypassed) "Enable  b" else "Bypass  b", unit.bypassed, theme.danger)) spectrum_ed.toggleBypass(&app.core, target);
    zgui.sameLine(.{ .spacing = 5 });
    if (widgets.iconButton(icons.left ++ "##fx-left", "Move left  h")) spectrum_ed.moveFocused(&app.core, target, -1);
    zgui.sameLine(.{ .spacing = 5 });
    if (widgets.iconButton(icons.right ++ "##fx-right", "Move right  l")) spectrum_ed.moveFocused(&app.core, target, 1);
    zgui.sameLine(.{ .spacing = 5 });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.danger });
    const removed = widgets.iconButton(icons.close ++ "##fx-remove", "Remove  x");
    if (removed) spectrum_ed.removeFocused(&app.core, target);
    zgui.popStyleColor(.{});
    if (removed) return;
    zgui.separator();

    if (unit.kind() == .eq) {
        const eq = &unit.payload.eq;
        if (zgui.button(if (eq.auto_gain) "auto gain: on" else "auto gain: off", .{})) spectrum_ed.toggleAutoGain(&app.core, target);
        zgui.sameLine(.{ .spacing = 5 });
        if (zgui.button(if (eq.analog) "bells: analog" else "bells: digital", .{})) spectrum_ed.toggleAnalog(&app.core, target);
        zgui.sameLine(.{ .spacing = 5 });
        if (zgui.button(if (app.core.eq_spectrum_pre) "pre-EQ" else "post-EQ", .{})) spectrum_ed.toggleSpectrumPre(&app.core, target);
        zgui.sameLine(.{ .spacing = 5 });
        if (app.core.eq_spectrum_frozen) zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.rhythm });
        if (zgui.button("freeze", .{})) spectrum_ed.toggleSpectrumFreeze(&app.core, target);
        if (app.core.eq_spectrum_frozen) zgui.popStyleColor(.{});
        zgui.separator();
        fx_eq.drawEqEditor(app, target, unit);
    } else {
        // Only the filter's display puts a spectrum behind its curve, so it is
        // the only non-EQ unit worth running the analyzer for.
        if (unit.kind() == .filter) fx_eq.ensureEqAnalyzer(app, target, unit);
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
    // scroll.PaneFit for the same rule where the panels are content-sized).
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
    for (&points, 0..) |*point, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(points.len - 1));
        const y = switch (unit.kind()) {
            .filter => filterDisplayValue(&unit.payload.filter, t),
            .amp => ampDisplayValue(&unit.payload.amp, t),
            .crossover => crossoverDisplayValue(&unit.payload.crossover, t),
            .chorus => modDisplayValue(unit.payload.chorus.rate_hz, unit.payload.chorus.depth_ms / ws.dsp.chorus.max_depth_ms, t),
            .phaser => modDisplayValue(unit.payload.phaser.rate_hz, unit.payload.phaser.depth, t),
            .flanger => modDisplayValue(unit.payload.flanger.rate_hz, unit.payload.flanger.depth, t),
            .sat => satDisplayValue(&unit.payload.sat, t),
            .clipper => clipperDisplayValue(&unit.payload.clipper, t),
            .comp => compDisplayValue(&unit.payload.comp, t),
            .delay => delayDisplayValue(&unit.payload.delay, t),
            .pitch_shift => pitchShiftDisplayValue(&unit.payload.pitch_shift, t),
            .gate => gateDisplayValue(&unit.payload.gate, t),
            .expander => expanderDisplayValue(&unit.payload.expander, t),
            .limiter => limiterDisplayValue(&unit.payload.limiter, t),
            .crush => crushDisplayValue(&unit.payload.crush, t),
            .reverb => reverbDisplayValue(&unit.payload.reverb, t),
            .freq_shift => freqShiftDisplayValue(&unit.payload.freq_shift, t),
            // Everything else has no curve worth drawing: `showsEffectCurve`
            // keeps it out of this pane entirely, or its display is meters.
            else => t,
        };
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
        .filter, .amp, .crossover => .{ .x_lo = "20 Hz", .x_hi = "20 kHz", .y = "LEVEL" },
        // The dynamics units read dB across and dB up (see `dynInputDb`),
        // which is the shape every compressor plot is drawn in - a linear
        // amplitude axis buries the whole knee in its bottom eighth.
        .comp, .gate, .expander, .limiter => .{ .x_lo = "-60 dB", .x_hi = "+12 dB", .y = "OUT dB" },
        .delay, .reverb => .{ .x_lo = "TIME", .y = "LEVEL" },
        .chorus, .phaser, .flanger => .{ .x_lo = "TIME", .y = "OFFSET" },
        // A shifter maps frequency to frequency; IN/OUT reads as a level
        // transfer, which is the one thing it does not do.
        .freq_shift, .pitch_shift => .{ .x_lo = "IN FREQ", .y = "OUT FREQ" },
        else => .{ .x_lo = "IN", .y = "OUT" },
    };
}

fn showsEffectCurve(kind: ws.FxKind) bool {
    return switch (kind) {
        .utility, .stereo_width, .auto_pan, .mb_comp, .ott, .transient_shaper, .tape, .clap, .vst3 => false,
        else => true,
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

/// The amp's own frequency response - coupling caps, tone stack, presence
/// and cabinet - rather than a transfer curve. Its clipping stages have no
/// curve worth plotting (a tanh is a tanh), while the four things MODEL and
/// the tone controls move are all visible here.
fn ampDisplayValue(amp: anytype, t: f32) f32 {
    const db = amp.responseDb(20.0 * std.math.pow(f32, 1000.0, t));
    // Wider window than the filter's: the tone stack's make-up puts the
    // passband above 0 dB and the cabinet takes 10 kHz far below it.
    return std.math.clamp((db + 48.0) / 60.0, 0, 1);
}

/// How many seconds of LFO the modulation units draw. Fixed, so RATE reads
/// as real cycles per second across all three of them - the old sketch took
/// its cycle count from the knob's normalized position, which made 5 Hz on
/// a phaser and 5 Hz on a chorus draw the same picture only by coincidence.
const mod_window_s: f32 = 2.0;

fn modDisplayValue(rate_hz: f32, depth: f32, t: f32) f32 {
    const cycles = std.math.clamp(rate_hz, 0.05, 20.0) * mod_window_s;
    const swing = 0.08 + 0.38 * std.math.clamp(depth, 0, 1);
    return 0.5 + @sin(t * std.math.pi * 2.0 * cycles) * swing;
}

/// The crusher's quantisation staircase at the bit depth actually set.
/// Sample-rate reduction is a time-domain effect and has no place on a
/// level transfer plot.
fn crushDisplayValue(crush: anytype, t: f32) f32 {
    const bits = std.math.clamp(@round(crush.bits), 1, 16);
    const steps = std.math.pow(f32, 2.0, bits - 1.0);
    return @round(t * steps) / steps;
}

/// A reverb tail across the same two-second window the delay draws: silence
/// through PREDELAY, then a decay whose length is ROOM, with the early
/// reflections IMPULSE adds in front of it. Predelay and the impulse switch
/// never reached the old sketch, which started every tail at time zero.
fn reverbDisplayValue(reverb: anytype, t: f32) f32 {
    const predelay_s = std.math.clamp(reverb.predelay_ms, 0, 250) / 1000.0;
    const pos = t * mod_window_s;
    if (pos < predelay_s) return 0;
    const age = pos - predelay_s;
    const room = std.math.clamp(reverb.room, 0, 0.98);
    const tail = @exp(-age * (0.8 + (1.0 - room) * 5.0)) * (0.7 + 0.2 * @sin(age * std.math.pi * 26.0));
    // Early reflections are discrete and land in the first ~120 ms; the
    // algorithmic tail behind them is unchanged.
    const early: f32 = if (reverb.impulse >= 0.5 and age < 0.12)
        0.3 * @exp(-@mod(age * 40.0, 1.0) * 6.0)
    else
        0;
    return std.math.clamp(tail + early, 0, 1);
}

/// A frequency shift is the identity line moved bodily up or down - not
/// tilted, which is what separates it from a transposition. Drawn against a
/// 20 kHz axis, so the full +-2 kHz range is a tenth of the pane.
fn freqShiftDisplayValue(shifter: anytype, t: f32) f32 {
    return std.math.clamp(t + std.math.clamp(shifter.shift_hz, -2000, 2000) / 20_000.0, 0, 1);
}
/// The crossover's own response: two split points, three band gains, and
/// whatever a solo has muted. It used to draw nothing at all - no curve and
/// no meters, so its display box held a one-line description of itself.
fn crossoverDisplayValue(xover: anytype, t: f32) f32 {
    const db = xover.responseDb(20.0 * std.math.pow(f32, 1000.0, t));
    // Band gains run -60..+24 dB, so the window is wider than the filter's.
    return std.math.clamp((db + 48.0) / 72.0, 0, 1);
}

/// The saturator's actual selected curve, run through the same shaping the
/// audio path uses. The generic tanh this used to draw looked the same for
/// all five shapes, so the one param that picks between them was invisible.
fn satDisplayValue(sat: anytype, t: f32) f32 {
    return std.math.clamp(0.5 + 0.5 * sat.transfer(t * 2.0 - 1.0), 0, 1);
}

/// The clipper's real curve: DRIVE into the selected knee against the
/// ceiling. The generic compressor knee it borrowed before read its "shape"
/// off the CEILING knob and never showed the ceiling itself.
fn clipperDisplayValue(clip: anytype, t: f32) f32 {
    return std.math.clamp(0.5 + 0.5 * clip.transfer(t * 2.0 - 1.0), 0, 1);
}
/// Dynamics units plot in dB across both axes, not in linear amplitude: at a
/// -18 dBFS threshold the entire knee sits in the bottom eighth of a linear
/// axis, which is exactly why these four used to draw an invented curve that
/// at least filled the pane.
///
/// The window runs past full scale because that is where a limiter works: a
/// -0.4 dB ceiling has nothing to show inside -60..0, where the curve is the
/// identity line right up to the last pixel.
const dyn_floor_db: f32 = -60.0;
const dyn_ceil_db: f32 = 12.0;

fn dynInputDb(t: f32) f32 {
    return dyn_floor_db + t * (dyn_ceil_db - dyn_floor_db);
}

fn dynOutput(in_db: f32, gain_db: f32) f32 {
    return std.math.clamp((in_db + gain_db - dyn_floor_db) / (dyn_ceil_db - dyn_floor_db), 0, 1);
}

/// The gate's static curve: everything under the threshold is pulled down
/// by RANGE, everything over it passes. The old drawing used a hardcoded
/// floor, so RANGE - the difference between a gate and a mute - never
/// showed. Hysteresis has no place on a static plot: it is a decision about
/// which way the level is moving, not a level-to-level mapping.
fn gateDisplayValue(gate: anytype, t: f32) f32 {
    const in_db = dynInputDb(t);
    const thresh_db = std.math.clamp(gate.threshold_db, -80.0, 0.0);
    const range_db = std.math.clamp(gate.range_db, gate_mod.mute_range_db, 0.0);
    return dynOutput(in_db, if (in_db < thresh_db) range_db else 0.0);
}

/// The expander's static curve, through the same `expansionDb` the audio
/// path uses - so RATIO, KNEE and RANGE are all visible, where the old
/// drawing read a flat scale factor off RATIO alone.
fn expanderDisplayValue(exp: anytype, t: f32) f32 {
    const in_db = dynInputDb(t);
    const under_db = std.math.clamp(exp.threshold_db, -80.0, 0.0) - in_db;
    return dynOutput(in_db, ws.dsp.expander.Expander.expansionDb(
        under_db,
        std.math.clamp(exp.ratio, 1.0, 20.0),
        std.math.clamp(exp.knee_db, 0.0, 24.0),
        std.math.clamp(exp.range_db, ws.dsp.expander.max_reduction_db, 0.0),
    ));
}

/// The compressor's static curve, through the same gain computer the audio
/// path calls - so RATIO, KNEE, MAKEUP and the up/down MODE are all in the
/// drawing. The generic knee it shared with four other units bent at a
/// fixed slope and could not show a soft knee or an upward mode at all.
fn compDisplayValue(comp: anytype, t: f32) f32 {
    const Comp = ws.dsp.Compressor;
    const in_db = dynInputDb(t);
    const over_db = in_db - std.math.clamp(comp.threshold_db, -60.0, 0.0);
    const ratio = std.math.clamp(comp.ratio, 1.0, 20.0);
    const knee_db = std.math.clamp(comp.knee_db, 0.0, 24.0);
    const gain_db = if (std.math.clamp(comp.mode, 0.0, 1.0) >= 0.5)
        Comp.upwardBoostDb(over_db, ratio, knee_db)
    else
        Comp.downwardReductionDb(over_db, ratio, knee_db);
    return dynOutput(in_db, gain_db + std.math.clamp(comp.makeup_db, -24.0, 24.0));
}

/// A limiter is its ceiling: everything above it lands on it. ALR moves the
/// release, not the curve, so it has nothing to draw here.
fn limiterDisplayValue(lim: anytype, t: f32) f32 {
    const in_db = dynInputDb(t);
    const ceiling_db = ws.types.gainToDb(std.math.clamp(lim.ceiling, 0.25, 1.0));
    return dynOutput(in_db, @min(0.0, ceiling_db - in_db));
}

/// A delay tail as it actually decays: one tap every TIME seconds, each
/// FEEDBACK of the one before, across the two seconds TIME itself tops out
/// at. The old sketch ran both knobs backwards - more feedback decayed
/// faster, and a longer time drew more echoes into the same window.
fn delayDisplayValue(delay: anytype, t: f32) f32 {
    const time_s = std.math.clamp(delay.time_s, 0.01, 2.0);
    const feedback = std.math.clamp(delay.feedback, 0.0, 0.95);
    const tap = t * 2.0 / time_s;
    const whole = @floor(tap);
    // `pow(0, 0)` is 1, which is what a feedback of zero should draw: the
    // first tap and nothing after it.
    const level = std.math.pow(f32, feedback, whole);
    // Each tap is an impulse, not a swell - shape it steeply so the plot
    // reads as discrete repeats.
    return std.math.clamp(level * @exp(-(tap - whole) * 10.0), 0, 1);
}

/// A transposition is a straight line through frequency, and its slope is
/// the pitch ratio - `2^(semitones/12)`, not the shift knob's position on
/// its own scale, which drew a 24-semitone drop as a gentle 0.4x tilt.
fn pitchShiftDisplayValue(shift: anytype, t: f32) f32 {
    const semis = std.math.clamp(shift.semitones, -24.0, 24.0) +
        std.math.clamp(shift.cents, -100.0, 100.0) / 100.0;
    return std.math.clamp(t * std.math.pow(f32, 2.0, semis / 12.0), 0, 1);
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
        // Only while AUTOGAIN is on: the loudness meter is fed inside that
        // branch, so with it off there is nothing measured to show and the
        // pane falls back to the unit description.
        .utility => |*util| {
            if (util.autogain_on < 0.5) return rows[0..0];
            const lufs = util.loudness.shortTerm();
            rows[0] = .{ .label = "LUFS", .value = (lufs + 36.0) / 36.0, .text = fmtLufs(&text[0], lufs) };
            rows[1] = .{ .label = "AUTO GAIN", .value = util.autogain_db / gain_meter_scale, .bipolar = true, .text = fmtDb(&text[1], util.autogain_db) };
            return rows[0..2];
        },
        .stereo_width => |*width| {
            rows[0] = .{ .label = "CORR", .value = width.correlation, .bipolar = true, .text = fmtSigned(&text[0], width.correlation) };
            return rows[0..1];
        },
        .auto_pan => |*pan| {
            const gains = pan.gains();
            rows[0] = .{ .label = "LEFT", .value = gains[0], .text = fmtPercent(&text[0], gains[0]) };
            rows[1] = .{ .label = "RIGHT", .value = gains[1], .text = fmtPercent(&text[1], gains[1]) };
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
/// The loudness meter reads down to -120 LUFS on silence, which is not a
/// number worth printing under a bar that starts at -36.
fn fmtLufs(buf: []u8, lufs: f32) []const u8 {
    if (lufs <= -36.0) return "-inf";
    return std.fmt.bufPrint(buf, "{d:.1} LUFS", .{lufs}) catch "";
}

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
    const width = (available - gap * @as(f32, @floatFromInt(grid.columns -| 1))) / @as(f32, @floatFromInt(@max(grid.columns, 1)));
    const available_height = zgui.getContentRegionAvail()[1] - rowGapCost() * @as(f32, @floatFromInt(grid.rows -| 1));
    const row_height = std.math.clamp(
        available_height / @as(f32, @floatFromInt(@max(grid.rows, 1))),
        param_row_min,
        param_row_max,
    );
    const knob_diameter = std.math.clamp(row_height - 44, 38, 64);

    for (0..grid.rows) |row| {
        const row_columns = grid.columnsInRow(row);
        for (0..row_columns) |column| {
            const index = grid.index(row, column) orelse continue;
            if (column > 0) zgui.sameLine(.{ .spacing = gap });
            var id_buf: [40]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "fx-param-card-{d}", .{index}) catch continue;
            const selected = app.core.fx_param == index;
            zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = if (selected) theme.bg3 else theme.bg1 });
            zgui.pushStyleColor4f(.{ .idx = .border, .c = if (selected) kindAccent(unit.kind()) else theme.line });
            // Before `beginChild`: a card entirely off the fold is skipped
            // wholesale, so the knob inside it never gets to mark itself as
            // the focused row - the one case cursor-following exists for.
            scroll.noteFocusRow(selected, zgui.getCursorScreenPos()[1], row_height);
            if (zgui.beginChild(id, .{ .w = width, .h = row_height, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true } })) {
                drawParam(app, target, unit, index, knob_diameter);
            }
            zgui.endChild();
            zgui.popStyleColor(.{ .count = 2 });
        }
        if (row + 1 < grid.rows) zgui.dummy(.{ .w = 0, .h = gap });
    }
}

fn drawParam(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, knob_diameter: f32) void {
    const disabled = spectrum_ed.paramDisabled(&unit.payload, index);
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
    applyParamResult(app, target, unit, index, value, result);
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
    applyParamResult(app, target, unit, index, value, result);
}

fn applyParamResult(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, value: f32, result: widgets.KnobResult) void {
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

pub fn syncChain(app: anytype, target: spectrum_ed.EqTarget) void {
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
    fx_eq.ensureEqAnalyzer(app, target, null);
    drawBusMonitor(app, target);
    zgui.spacing();
    const below_top = zgui.getCursorPosY();
    if (widgets.emptyState(.{
        .id = "empty-fx-chain",
        // Worded like the TUI's empty chain (tui/views/spectrum.zig).
        .title = "EMPTY CHAIN",
        .explanation = "IN feeds OUT unchanged. Try EQ, Compressor, or Reverb.",
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

fn targetMonitorLabel(target: spectrum_ed.EqTarget) []const u8 {
    return switch (target) {
        .track => "TRACK SPECTRUM",
        .master => "MASTER SPECTRUM",
        .group => "GROUP SPECTRUM",
    };
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

test "effect display uses truthful curve types" {
    try std.testing.expect(!showsEffectCurve(.mb_comp));
    try std.testing.expect(!showsEffectCurve(.tape));
    try std.testing.expect(showsEffectCurve(.sat));
    // 3-bit crush: 2^2 = 4 steps, so 0.3 lands on 0.25.
    var crush = ws.dsp.Crusher{ .bits = 3 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), crushDisplayValue(&crush, 0.3), 1e-6);
}
