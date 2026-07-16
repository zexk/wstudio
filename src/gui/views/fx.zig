const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const spectrum_ed = @import("../../tui/editors/spectrum.zig");
const history = @import("../../tui/history.zig");
const style = @import("../style.zig");

const color = style.color;
const rgb = style.rgb;
const trackColor = style.trackColor;
const umbra = style.umbra;

pub fn draw(app: anytype) void {
    const target = spectrum_ed.currentTarget(&app.core);
    const fx = spectrum_ed.fxPtr(&app.core, target) orelse {
        zgui.textDisabled("This FX chain is no longer available.", .{});
        return;
    };
    if (fx.units.items.len > 0) app.core.fx_focus = @min(app.core.fx_focus, fx.units.items.len - 1);

    const snap = app.core.session.engine.uiSnapshot();
    drawHeader(app, target, fx, snap);
    zgui.spacing();
    drawSignalChain(app, target, fx);
    zgui.spacing();

    if (spectrum_ed.focusedUnit(&app.core, fx)) |unit| {
        drawEditor(app, target, unit);
    } else {
        drawEmptyState(app);
    }
}

fn drawHeader(app: anytype, target: spectrum_ed.EqTarget, fx: *const ws.Fx, snap: ws.engine.UiSnapshot) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 94;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("fx-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    const accent = targetAccent(app, target);
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(accent), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "FX RACK", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 31 }, color(umbra.fg0), "{s}", .{targetName(app, target)});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 62 }, color(umbra.fg2), "{d}/{d} UNITS", .{ fx.units.items.len, ws.Fx.max_units });

    const meter_w: f32 = @min(210, width * 0.28);
    const meter_x = origin[0] + width - meter_w - 17;
    draw_list.addText(.{ meter_x, origin[1] + 11 }, color(umbra.fg3), "MASTER OUTPUT", .{});
    drawMeter(draw_list, .{ meter_x, origin[1] + 34 }, meter_w, snap.peak[0], "L");
    drawMeter(draw_list, .{ meter_x, origin[1] + 60 }, meter_w, snap.peak[1], "R");
}

fn drawMeter(draw_list: zgui.DrawList, pos: [2]f32, width: f32, value: f32, label: []const u8) void {
    const meter_x = pos[0] + 18;
    const meter_w = width - 18;
    const level = std.math.clamp(value, 0, 1);
    draw_list.addText(.{ pos[0], pos[1] - 2 }, color(umbra.fg3), "{s}", .{label});
    draw_list.addRectFilled(.{ .pmin = .{ meter_x, pos[1] }, .pmax = .{ meter_x + meter_w, pos[1] + 10 }, .col = color(umbra.bg0), .rounding = 2 });
    draw_list.addRectFilled(.{ .pmin = .{ meter_x, pos[1] }, .pmax = .{ meter_x + meter_w * level, pos[1] + 10 }, .col = color(if (level > 0.9) umbra.red else umbra.cyan), .rounding = 2 });
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

fn targetAccent(app: anytype, target: spectrum_ed.EqTarget) [4]f32 {
    return switch (target) {
        .track => if (app.core.eq_track < app.core.session.project.tracks.items.len)
            trackColor(app.core.session.project.tracks.items[app.core.eq_track].color)
        else
            umbra.iris,
        .master => umbra.mauve,
        .group => umbra.cyan,
    };
}

fn drawSignalChain(app: anytype, target: spectrum_ed.EqTarget, fx: *ws.Fx) void {
    zgui.textDisabled("SIGNAL FLOW", .{});
    zgui.sameLine(.{});
    zgui.textColored(umbra.fg3, "INPUT  >  PROCESSING  >  OUTPUT", .{});

    const gap: f32 = 6;
    const count = fx.units.items.len + @as(usize, if (fx.units.items.len < ws.Fx.max_units) 1 else 0);
    const available = zgui.getContentRegionAvail()[0];
    const slot_w = std.math.clamp((available - gap * @as(f32, @floatFromInt(count -| 1))) / @as(f32, @floatFromInt(@max(count, 1))), 72, 126);
    for (fx.units.items, 0..) |unit, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = gap });
        drawSlot(app, target, unit, i, slot_w);
    }
    if (fx.units.items.len < ws.Fx.max_units) {
        if (fx.units.items.len > 0) zgui.sameLine(.{ .spacing = gap });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = umbra.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = umbra.iris_soft });
        if (zgui.button("+  ADD##fx-chain-add", .{ .w = slot_w, .h = 58 })) app.openPicker(.fx_picker);
        zgui.popStyleColor(.{ .count = 2 });
    }
}

fn drawSlot(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, width: f32) void {
    const origin = zgui.getCursorScreenPos();
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "fx-slot-{d}", .{index}) catch return;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = 58 });
    const hovered = zgui.isItemHovered(.{});
    const selected = app.core.fx_focus == index;
    const draw_list = zgui.getWindowDrawList();
    const accent = if (unit.bypassed) umbra.fg3 else kindAccent(unit.kind());
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 58 }, .col = color(if (selected) umbra.bg4 else if (hovered) umbra.bg3 else umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 3 }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ origin[0] + 9, origin[1] + 10 }, color(umbra.fg3), "{d:0>2}", .{index + 1});
    draw_list.addText(.{ origin[0] + 9, origin[1] + 31 }, color(if (unit.bypassed) umbra.fg3 else umbra.fg0), "{s}", .{spectrum_ed.stripLabel(unit.kind())});
    if (clicked and !selected) spectrum_ed.setFocus(&app.core, target, index);
}

fn kindAccent(kind: ws.FxKind) [4]f32 {
    return switch (kind) {
        .gate, .comp, .mb_comp, .ott => umbra.red,
        .eq => umbra.yellow,
        .sat, .crush, .tape => umbra.mauve,
        .chorus, .flanger, .phaser, .freq_shift => umbra.iris,
        .delay, .reverb => umbra.cyan,
    };
}

fn drawEditor(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit) void {
    const accent = kindAccent(unit.kind());
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("fx-editor-heading", .{ .w = width, .h = 52 });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 52 }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 4, origin[1] + 52 }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ origin[0] + 15, origin[1] + 8 }, color(accent), "{s}", .{spectrum_ed.unitLabel(unit.kind())});
    draw_list.addText(.{ origin[0] + 15, origin[1] + 29 }, color(umbra.fg3), "UNIT {d:0>2}  {s}", .{ app.core.fx_focus + 1, if (unit.bypassed) "BYPASSED" else "ACTIVE" });

    zgui.setCursorScreenPos(.{ origin[0] + width - 282, origin[1] + 11 });
    if (zgui.button(if (unit.bypassed) "ENABLE" else "BYPASS", .{ .w = 78, .h = 30 })) spectrum_ed.toggleBypass(&app.core, target);
    zgui.sameLine(.{ .spacing = 5 });
    if (zgui.button("<##fx-left", .{ .w = 38, .h = 30 })) spectrum_ed.moveFocused(&app.core, target, -1);
    zgui.sameLine(.{ .spacing = 5 });
    if (zgui.button(">##fx-right", .{ .w = 38, .h = 30 })) spectrum_ed.moveFocused(&app.core, target, 1);
    zgui.sameLine(.{ .spacing = 5 });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = umbra.red });
    const removed = zgui.button("REMOVE", .{ .w = 78, .h = 30 });
    if (removed) spectrum_ed.removeFocused(&app.core, target);
    zgui.popStyleColor(.{});
    zgui.setCursorScreenPos(.{ origin[0], origin[1] + 58 });
    if (removed) return;

    if (unit.kind() == .eq) {
        drawEqEditor(app, target, unit);
    } else {
        if (app.eq_analyzer_key != null) {
            _ = app.core.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
            app.eq_analyzer_key = null;
        }
        if (zgui.beginChild("fx-parameters", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
            zgui.textColored(accent, "PARAMETERS", .{});
            zgui.separator();
            const param_count = spectrum_ed.visibleParamCount(&app.core, unit.kind(), &unit.payload);
            const gap: f32 = 18;
            const column_w = @max(240, (zgui.getContentRegionAvail()[0] - gap) / 2);
            if (zgui.beginChild("fx-params-left", .{ .w = column_w, .h = 0 })) {
                for (0..(param_count + 1) / 2) |i| drawParam(app, target, unit, i);
            }
            zgui.endChild();
            zgui.sameLine(.{ .spacing = gap });
            if (zgui.beginChild("fx-params-right", .{ .w = 0, .h = 0 })) {
                for ((param_count + 1) / 2..param_count) |i| drawParam(app, target, unit, i);
            }
            zgui.endChild();
        }
        zgui.endChild();
    }
}

const eq_freq_min: f32 = 20.0;
const eq_freq_max: f32 = 20_000.0;
const eq_db_min: f32 = -18.0;
const eq_db_max: f32 = 18.0;

fn drawEqEditor(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit) void {
    ensureEqAnalyzer(app, target);
    if (zgui.beginChild("eq-editor", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        const selected_band = @min(app.core.fx_param / spectrum_ed.eq_fields_per_band, unit.payload.eq.bands.len - 1);
        drawEqGraph(app, target, unit, selected_band);
        zgui.spacing();
        drawEqBandStrip(app, unit, selected_band);
        zgui.spacing();
        drawEqBandControls(app, target, unit, selected_band);
    }
    zgui.endChild();
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
    const height: f32 = 238;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("eq-response-graph", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg0), .rounding = 4 });

    const db_ticks = [_]f32{ -18, -12, -6, 0, 6, 12, 18 };
    for (db_ticks) |db| {
        const y = eqDbY(origin[1], height, db);
        draw_list.addLine(.{ .p1 = .{ origin[0], y }, .p2 = .{ origin[0] + width, y }, .col = color(if (db == 0) umbra.bg5 else umbra.line), .thickness = if (db == 0) 1.5 else 1 });
        if (db != 18 and db != -18) draw_list.addText(.{ origin[0] + 6, y - 9 }, color(umbra.fg3), "{d:.0}", .{db});
    }
    const freq_ticks = [_]struct { hz: f32, label: []const u8 }{
        .{ .hz = 20, .label = "20" },     .{ .hz = 50, .label = "50" },     .{ .hz = 100, .label = "100" }, .{ .hz = 200, .label = "200" },
        .{ .hz = 500, .label = "500" },   .{ .hz = 1000, .label = "1k" },   .{ .hz = 2000, .label = "2k" }, .{ .hz = 5000, .label = "5k" },
        .{ .hz = 10000, .label = "10k" }, .{ .hz = 20000, .label = "20k" },
    };
    for (freq_ticks) |tick| {
        const x = eqFreqX(origin[0], width, tick.hz);
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = color(if (tick.hz == 1000) umbra.bg5 else umbra.line), .thickness = 1 });
        draw_list.addText(.{ x + 4, origin[1] + height - 20 }, color(umbra.fg3), "{s}", .{tick.label});
    }

    const spectrum_snap = switch (target) {
        .track => app.core.session.engine.trackSpectrumSnapshot(app.core.eq_track),
        .master => app.core.session.engine.masterSpectrumSnapshot(),
        .group => app.core.session.engine.groupSpectrumSnapshot(app.core.eq_group),
    };
    if (spectrum_snap) |snap| {
        const spectrum_color = color(.{ umbra.cyan[0], umbra.cyan[1], umbra.cyan[2], 0.22 });
        for (snap.bins, 0..) |db, i| {
            const x = origin[0] + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(snap.bins.len - 1));
            const norm = std.math.clamp((db + 90.0) / 90.0, 0, 1);
            const y = origin[1] + height * (1.0 - norm);
            draw_list.addLine(.{ .p1 = .{ x, origin[1] + height }, .p2 = .{ x, y }, .col = spectrum_color, .thickness = @max(1, width / @as(f32, @floatFromInt(snap.bins.len))) });
        }
    }

    var response_points: [257][2]f32 = undefined;
    for (&response_points, 0..) |*point, i| {
        const norm = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(response_points.len - 1));
        const freq = eq_freq_min * std.math.pow(f32, eq_freq_max / eq_freq_min, norm);
        const db = combinedResponseDb(&unit.payload.eq, freq);
        point.* = .{ origin[0] + norm * width, eqDbY(origin[1], height, db) };
    }
    const fill_color = color(.{ umbra.yellow[0], umbra.yellow[1], umbra.yellow[2], 0.10 });
    const zero_y = eqDbY(origin[1], height, 0);
    for (response_points[0 .. response_points.len - 1], response_points[1..]) |a, b| {
        draw_list.addLine(.{ .p1 = .{ a[0], zero_y }, .p2 = a, .col = fill_color, .thickness = @max(1, b[0] - a[0] + 1) });
    }
    draw_list.addPolyline(&response_points, .{ .col = color(umbra.yellow), .thickness = 2.5 });

    for (unit.payload.eq.bands, 0..) |band, i| {
        const node = eqBandPoint(origin, .{ width, height }, band);
        const accent = eqBandColor(i);
        const selected = i == selected_band;
        draw_list.addCircleFilled(.{ .p = node, .r = if (selected) 10 else 8, .col = color(if (selected) accent else .{ accent[0], accent[1], accent[2], 0.72 }) });
        draw_list.addCircle(.{ .p = node, .r = if (selected) 12 else 10, .col = color(if (selected) umbra.fg0 else accent), .thickness = if (selected) 2 else 1 });
        draw_list.addText(.{ node[0] - 4, node[1] - 8 }, color(umbra.bg0), "{d}", .{i + 1});
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
            if (unit.payload.eq.bands[band_index].kind == .peak) {
                const gain_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_gain;
                spectrum_ed.setParam(&app.core, &unit.payload, gain_idx, eqYDb(origin[1], height, mouse[1]));
            }
            app.core.dirty = true;
            syncChain(app, target);
        } else {
            app.eq_drag_band = null;
        }
    }
}

fn drawEqBandStrip(app: anytype, unit: *ws.FxUnit, selected_band: usize) void {
    zgui.textDisabled("BANDS", .{});
    zgui.sameLine(.{});
    zgui.textColored(umbra.fg3, "DRAG NODES TO SET FREQUENCY AND GAIN", .{});
    const gap: f32 = 5;
    const available = zgui.getContentRegionAvail()[0];
    const columns: usize = if (available < 600) 4 else 8;
    const width = (available - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    for (unit.payload.eq.bands, 0..) |band, i| {
        if (i % columns != 0) zgui.sameLine(.{ .spacing = gap });
        const selected = i == selected_band;
        const accent = eqBandColor(i);
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (selected) accent else umbra.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (selected) umbra.bg0 else accent });
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{d}  {s}##eq-band-{d}", .{ i + 1, eqBandKindShort(band.kind), i }) catch continue;
        if (zgui.button(label, .{ .w = width, .h = 34 })) {
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
    zgui.textDisabled("{s}", .{eqBandKindLabel(band.kind)});
    zgui.separator();

    const types = [_]struct { label: [:0]const u8, value: f32 }{
        .{ .label = "BELL", .value = 0 },
        .{ .label = "HIGH CUT", .value = 1 },
        .{ .label = "LOW CUT", .value = 2 },
    };
    const kind_idx = band_index * spectrum_ed.eq_fields_per_band + spectrum_ed.eq_field_kind;
    for (types, 0..) |entry, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 5 });
        const active = @as(u8, @intFromEnum(band.kind)) == @as(u8, @intFromFloat(entry.value));
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) accent else umbra.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) umbra.bg0 else umbra.fg2 });
        if (zgui.button(entry.label, .{ .h = 32 }) and !active) {
            history.noteFxNudge(&app.core, target, app.core.fx_focus, kind_idx);
            spectrum_ed.setParam(&app.core, &unit.payload, kind_idx, entry.value);
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
    drawEqSlider(app, target, unit, freq_idx, "Frequency", "%.0f Hz", true);
    drawEqSlider(app, target, unit, q_idx, "Q", "%.2f", true);
    drawEqSlider(app, target, unit, gain_idx, if (band.kind == .peak) "Gain" else "Slope", if (band.kind == .peak) "%.1f dB" else "%.0f x12 dB/oct", false);
}

fn drawEqSlider(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, label_text: []const u8, format: [:0]const u8, logarithmic: bool) void {
    var value = spectrum_ed.getParam(&unit.payload, index);
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##eq-control-{d}", .{ label_text, index }) catch return;
    const focused = !app.core.eq_band_select and app.core.fx_param == index;
    style.pushControlFocus(focused, eqBandColor(index / spectrum_ed.eq_fields_per_band));
    defer style.popControlFocus(focused);
    if (zgui.sliderFloat(label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format, .flags = .{ .logarithmic = logarithmic } })) {
        history.noteFxNudge(&app.core, target, app.core.fx_focus, index);
        spectrum_ed.setParam(&app.core, &unit.payload, index, value);
        app.core.fx_param = index;
        app.core.dirty = true;
        syncChain(app, target);
    }
    if (zgui.isItemActivated()) {
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

fn eqBandKindShort(kind: ws.dsp.eq.BandKind) []const u8 {
    return switch (kind) {
        .peak => "BELL",
        .lowpass => "HC",
        .highpass => "LC",
    };
}

fn eqBandKindLabel(kind: ws.dsp.eq.BandKind) []const u8 {
    return switch (kind) {
        .peak => "BELL FILTER",
        .lowpass => "HIGH CUT FILTER",
        .highpass => "LOW CUT FILTER",
    };
}

fn eqBandPoint(origin: [2]f32, size: [2]f32, band: anytype) [2]f32 {
    return .{
        eqFreqX(origin[0], size[0], band.freq),
        eqDbY(origin[1], size[1], if (band.kind == .peak) band.gain_db else 0),
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
    const stages: f32 = @floatFromInt(if (band.kind == .peak) @as(u8, 1) else band.slope);
    return 10.0 * std.math.log10(magnitude_sq) * stages;
}

fn drawParam(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize) void {
    var value = spectrum_ed.getParam(&unit.payload, index);
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    const format: [:0]const u8 = if (range[1] >= 100) "%.0f" else "%.2f";
    var label_buf: [80]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##gui-fx-{d}", .{ spectrum_ed.paramName(&unit.payload, index), index }) catch return;
    const focused = app.core.fx_param == index;
    style.pushControlFocus(focused, kindAccent(unit.kind()));
    defer style.popControlFocus(focused);
    if (zgui.sliderFloat(label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format })) {
        spectrum_ed.setParam(&app.core, &unit.payload, index, value);
        spectrum_ed.clearStaleSidechainPad(&app.core, &unit.payload);
        app.core.fx_param = index;
        app.core.dirty = true;
        syncChain(app, target);
    }
    if (zgui.isItemActivated()) app.core.fx_param = index;
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

fn drawEmptyState(app: anytype) void {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("fx-empty-state", .{ .w = width, .h = 180 });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 180 }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addText(.{ origin[0] + 22, origin[1] + 28 }, color(umbra.fg0), "Build your signal chain", .{});
    draw_list.addText(.{ origin[0] + 22, origin[1] + 55 }, color(umbra.fg3), "Add dynamics, tone, modulation, and space in series.", .{});
    zgui.setCursorScreenPos(.{ origin[0] + 22, origin[1] + 96 });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = umbra.iris_soft });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = umbra.iris });
    if (zgui.button("+  ADD FIRST EFFECT", .{ .w = 190, .h = 36 })) app.openPicker(.fx_picker);
    zgui.popStyleColor(.{ .count = 2 });
    zgui.setCursorScreenPos(.{ origin[0], origin[1] + 180 });
}
