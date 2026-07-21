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
        if (zgui.button("+##fx-chain-add", .{ .w = slot_w, .h = 36 })) app.openPicker(.fx_picker);
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
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 36 }, .col = color(if (selected) theme.bg4 else if (hovered) theme.bg3 else theme.bg2), .rounding = 3 });
    draw_list.addRect(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 36 }, .col = color(if (selected) theme.focus else theme.line), .rounding = 3, .thickness = if (selected) 2 else 1 });
    draw_list.addText(.{ origin[0] + 8, origin[1] + 9 }, color(if (unit.bypassed) theme.fg3 else theme.fg0), "{s}", .{spectrum_ed.stripLabel(unit.kind())});
    draw_list.addCircleFilled(.{ .p = .{ origin[0] + width - 11, origin[1] + 18 }, .r = 3.5, .col = color(accent) });
    if (clicked and !selected) spectrum_ed.setFocus(&app.core, target, index);
}

const kindAccent = style.fxKindAccent;

fn drawEditor(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit) void {
    const accent = kindAccent(unit.kind());
    zgui.textColored(accent, "{s}", .{spectrum_ed.editorTitle(unit.kind())});
    zgui.sameLine(.{});
    zgui.textDisabled("unit {d}  {s}", .{ app.core.fx_focus + 1, if (unit.bypassed) "BYPASSED" else "ACTIVE" });
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
        ensureEqAnalyzer(app, target);
        drawEffectDisplay(app, target, unit);
        zgui.spacing();
        const param_count = spectrum_ed.visibleParamCount(&app.core, unit.kind(), &unit.payload);
        drawParamGrid(app, target, unit, param_count);
        if (unit.bypassed) zgui.textColored(theme.danger, "BYPASSED  (b to re-enable)", .{});
    }
}

fn drawEffectDisplay(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit) void {
    const size = zgui.getContentRegionAvail();
    const height: f32 = std.math.clamp(size[1] * 0.48, 150, 260);
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("fx-effect-display", .{ .w = size[0], .h = height });
    const draw_list = zgui.getWindowDrawList();
    const accent = kindAccent(unit.kind());
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + size[0], origin[1] + height }, .col = color(theme.bg0), .rounding = 4 });
    for (1..4) |i| {
        const x = origin[0] + size[0] * @as(f32, @floatFromInt(i)) / 4;
        const y = origin[1] + height * @as(f32, @floatFromInt(i)) / 4;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = color(theme.line), .thickness = 1 });
        draw_list.addLine(.{ .p1 = .{ origin[0], y }, .p2 = .{ origin[0] + size[0], y }, .col = color(theme.line), .thickness = 1 });
    }

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
            spectrum_points[i] = .{ origin[0] + t * size[0], origin[1] + (1 - level) * height };
        }
        draw_list.addPolyline(&spectrum_points, .{ .col = color(.{ theme.audio[0], theme.audio[1], theme.audio[2], 0.42 }), .thickness = 1.5 });
    }

    var points: [65][2]f32 = undefined;
    const amount = normalizedParam(app, unit, 0);
    const shape = normalizedParam(app, unit, 1);
    for (&points, 0..) |*point, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(points.len - 1));
        const y = effectDisplayValue(unit.kind(), t, amount, shape);
        point.* = .{ origin[0] + t * size[0], origin[1] + (1.0 - y) * height };
    }
    draw_list.addPolyline(&points, .{ .col = color(accent), .thickness = 2.5 });
    draw_list.addText(.{ origin[0] + 10, origin[1] + 8 }, color(theme.fg2), "{s}", .{spectrum_ed.effectSpec(unit.kind()).display_label});
    draw_list.addText(.{ origin[0] + 10, origin[1] + height - 24 }, color(theme.fg3), "IN", .{});
    draw_list.addText(.{ origin[0] + size[0] - 34, origin[1] + 8 }, color(theme.fg3), "OUT", .{});
}

fn normalizedParam(app: anytype, unit: *ws.FxUnit, index: usize) f32 {
    if (index >= spectrum_ed.paramCount(unit.kind())) return 0.5;
    const range = spectrum_ed.paramRange(&app.core, &unit.payload, index);
    if (range[1] <= range[0]) return 0.5;
    return std.math.clamp((spectrum_ed.getParam(&unit.payload, index) - range[0]) / (range[1] - range[0]), 0, 1);
}

fn effectDisplayValue(kind: ws.FxKind, t: f32, amount: f32, shape: f32) f32 {
    return switch (kind) {
        .gate => if (t < amount * 0.8) 0.08 else t,
        .comp, .mb_comp, .ott => if (t < amount) t else amount + (t - amount) * (0.2 + shape * 0.45),
        .sat, .tape, .crush => 0.5 + std.math.atan((t - 0.5) * (2.0 + amount * 10.0)) / std.math.pi,
        .chorus, .flanger, .phaser => std.math.clamp(t + @sin(t * std.math.pi * (4.0 + shape * 8.0)) * (0.05 + amount * 0.12), 0, 1),
        .freq_shift => std.math.clamp(t + (amount - 0.5) * 0.35, 0, 1),
        .delay => std.math.clamp(@exp(-t * (1.5 + shape * 4.0)) * (0.55 + 0.4 * @sin(t * std.math.pi * (6.0 + amount * 10.0))), 0, 1),
        .reverb => std.math.clamp(@exp(-t * (0.8 + (1.0 - amount) * 4.0)) * (0.7 + 0.2 * @sin(t * std.math.pi * 26.0)), 0, 1),
        .eq => t,
        .clap => t,
    };
}

fn drawParamGrid(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, param_count: usize) void {
    const available = zgui.getContentRegionAvail()[0];
    const max_columns: usize = @intFromFloat(@max(1, @floor((available + 8) / 210)));
    const grid = spectrum_ed.paramGrid(param_count, @min(max_columns, 4));
    const gap: f32 = 8;
    const available_height = zgui.getContentRegionAvail()[1];
    const row_height = std.math.clamp(
        (available_height - gap * @as(f32, @floatFromInt(grid.rows -| 1))) / @as(f32, @floatFromInt(@max(grid.rows, 1))),
        82,
        150,
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
            if (zgui.beginChild(id, .{ .w = if (column + 1 == row_columns) 0 else width, .h = row_height, .child_flags = .{ .border = true } })) {
                drawParam(app, target, unit, index, knob_diameter);
            }
            zgui.endChild();
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
    drawEqBandStrip(app, unit, selected_band);
    zgui.spacing();
    drawEqBandControls(app, target, unit, selected_band);
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
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg0), .rounding = 4 });

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
    zgui.textDisabled("BANDS   h/l select   enter edit   drag graph nodes for frequency/gain", .{});
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

fn drawParam(app: anytype, target: spectrum_ed.EqTarget, unit: *ws.FxUnit, index: usize, knob_diameter: f32) void {
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
    var label_buf: [80]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##gui-fx-{d}", .{ spectrum_ed.paramName(&unit.payload, index), index }) catch return;
    const focused = app.core.fx_param == index;
    const control_width = knob_diameter + 120;
    const spare = zgui.getContentRegionAvail()[0] - control_width;
    if (spare > 0) zgui.setCursorPosX(zgui.getCursorPosX() + spare * 0.5);
    const result = widgets.paramKnob(spectrum_ed.paramName(&unit.payload, index), label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format, .accent = kindAccent(unit.kind()), .focused = focused, .diameter = knob_diameter });
    if (result.changed) {
        spectrum_ed.setParam(&app.core, &unit.payload, index, value);
        spectrum_ed.clearStaleSidechainPad(&app.core, &unit.payload);
        app.core.fx_param = index;
        app.core.dirty = true;
        syncChain(app, target);
    }
    if (result.activated) app.core.fx_param = index;
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
    zgui.textColored(if (focused) accent else theme.fg1, "{s}", .{spectrum_ed.paramName(&unit.payload, index)});
    for (names, 0..) |name, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 5 });
        const active = (value >= 0.5) == (i == 1);
        var btn_buf: [40]u8 = undefined;
        const btn_id = std.fmt.bufPrintZ(&btn_buf, "{s}##gui-fx-{d}-{d}", .{ name, index, i }) catch continue;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) accent else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else theme.fg2 });
        if (zgui.button(btn_id, .{ .h = 26 }) and !active) {
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
    var label_buf: [80]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##gui-fx-{d}", .{ spectrum_ed.paramName(&unit.payload, index), index }) catch return;
    var value_buf: [32]u8 = undefined;
    const display = spectrum_ed.formatValue(&app.core, &value_buf, &unit.payload, index);
    const focused = app.core.fx_param == index;
    const spare = zgui.getContentRegionAvail()[0] - 190;
    if (spare > 0) zgui.setCursorPosX(zgui.getCursorPosX() + spare * 0.5);
    const result = widgets.listStepper(spectrum_ed.paramName(&unit.payload, index), label, .{ .v = &value, .min = range[0], .max = range[1], .display = display, .accent = kindAccent(unit.kind()), .focused = focused });
    if (result.changed) {
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
    var explanation_buf: [96]u8 = undefined;
    const explanation = std.fmt.bufPrint(&explanation_buf, "Insert an effect to shape this {s}.", .{targetRole(target)}) catch "Insert an effect.";
    if (widgets.emptyState(.{
        .id = "empty-fx-chain",
        .title = "BUILD THE SIGNAL CHAIN",
        .explanation = explanation,
        .shortcut = "a",
        .action = "ADD EFFECT",
        .accent = targetAccent(target),
    })) app.openPicker(.fx_picker);
}

fn drawBusMonitor(app: anytype, target: spectrum_ed.EqTarget) void {
    const available = zgui.getContentRegionAvail();
    const height = std.math.clamp(available[1] * 0.62, 190, 330);
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("empty-chain-monitor", .{ .w = available[0], .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + available[0], origin[1] + height }, .col = color(theme.bg0), .rounding = 4 });
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
