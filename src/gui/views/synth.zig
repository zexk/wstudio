//! Synth editor: overview header with oscillator/envelope/filter sketches,
//! MAIN/MOD/FX tab strip, and the comptime-table-driven parameter sections.

const std = @import("std");
const ws = @import("wstudio");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const synth_ed = @import("../../ui/editors/synth.zig");
const synth_layout = @import("../../ui/synth_layout.zig");
const gui_style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const theme = &gui_style.palette;

pub fn draw(app: anytype) void {
    const track = app.core.synth_track;
    if (track >= app.core.session.racks.items.len) return;
    const synth = switch (app.core.session.racks.items[track].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a Synth track.", .{});
            return;
        },
    };
    drawHeader(app, synth);
    zgui.spacing();
    drawTabs(app);
    zgui.spacing();
    switch (app.core.synth_subview) {
        .main => drawSections(app, synth, &synth_layout.main_sections, "synth-main"),
        .mod => drawSections(app, synth, &synth_layout.mod_sections, "synth-mod"),
        .fx => drawFx(app, synth),
    }
}

fn drawTabs(app: anytype) void {
    for (synth_ed.subviews, 0..) |tab, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 5 });
        const active = app.core.synth_subview == tab.subview;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) theme.focus else theme.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else theme.fg2 });
        if (zgui.button(tab.label, .{ .w = 125, .h = 30 })) setSubview(app, tab.subview);
        zgui.popStyleColor(.{ .count = 2 });
    }
}

fn setSubview(app: anytype, subview: synth_ed.Subview) void {
    app.core.synth_subview = subview;
    var candidates_buf: [synth_ed.max_search_candidates]synth_ed.SearchCandidate = undefined;
    for (synth_ed.searchCandidates(&app.core, &candidates_buf)) |candidate| {
        if (candidate.subview == subview) {
            app.core.synth_cursor = candidate.id;
            break;
        }
    }
}

fn drawSections(app: anytype, synth: *ws.dsp.PolySynth, comptime sections: []const synth_layout.SectionDef, comptime child_prefix: []const u8) void {
    const gap: f32 = 12;
    const available_width = zgui.getContentRegionAvail()[0];
    const columns: usize = if (available_width >= 1080) 3 else if (available_width >= 650) 2 else 1;
    // Keeps j/k/{/}/g/G in sync with the column grid actually on screen -
    // synth_layout.numCols buckets the same way from a terminal-width
    // number, so this just maps GUI's own column count onto that bucketing
    // (see App.last_cols's doc comment: it's read back by handleKey, not
    // fed a parameter, so it has to be kept current here every frame).
    app.core.last_cols = if (columns >= 3) 160 else if (columns == 2) 108 else 80;
    const column_w = @max(280, (available_width - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns)));
    for (0..columns) |column| {
        if (column > 0) zgui.sameLine(.{ .spacing = gap });
        var child_buf: [48]u8 = undefined;
        const child_id = std.fmt.bufPrintZ(&child_buf, "{s}-{d}", .{ child_prefix, column }) catch continue;
        zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = theme.bg2 });
        if (zgui.beginChild(child_id, .{
            .w = if (column + 1 == columns) 0 else column_w,
            .h = 0,
            .child_flags = .{ .border = true, .auto_resize_y = true },
            .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
        })) {
            for (sections, 0..) |section, section_index| {
                if (section_index % columns != column) continue;
                widgets.sectionTitle(section.title, sectionColor(section_index));
                for (section.params) |entry| {
                    if (isEnvelopeBase(entry.id)) {
                        drawEnvelope(app, synth, entry.id);
                    } else if (isFilterCutoff(entry.id)) {
                        drawFilterPad(app, synth, entry.id);
                    } else if (!isEnvelopeTail(entry.id) and !isFilterResonance(entry.id)) {
                        for (0..entry.fields) |field| {
                            var label_buf: [48]u8 = undefined;
                            const id: u8 = @intCast(@as(usize, entry.id) + field);
                            drawAnyParam(app, synth, id, synth_ed.paramLabel(id, &label_buf));
                        }
                        if (lfoShapeSlot(entry.id)) |slot| drawLfoCustomCurve(app, synth, slot);
                    }
                }
                zgui.spacing();
            }
        }
        zgui.endChild();
        zgui.popStyleColor(.{});
    }
}

// AMP ENV (16-19), FILTER ENV (24-27), and ENV 3 (122-125) each pack
// attack/decay/sustain/release at base_id+0..3 - see synth_layout.zig's
// comment on why engine param ids never move. That fixed layout is what
// lets one drawEnvelope cover all three instead of three near-identical
// knob rows.
fn isEnvelopeBase(id: u8) bool {
    return id == 16 or id == 24 or id == 122;
}

fn isEnvelopeTail(id: u8) bool {
    return switch (id) {
        17, 18, 19, 25, 26, 27, 123, 124, 125 => true,
        else => false,
    };
}

fn isFilterCutoff(id: u8) bool {
    return id == 21 or id == 47;
}

fn isFilterResonance(id: u8) bool {
    return id == 22 or id == 48;
}

fn sendParam(app: anytype, id: u8, value: f32) void {
    _ = app.core.session.engine.setTrackParam(app.core.synth_track, id, value);
}

fn drawEnvelope(app: anytype, synth: *ws.dsp.PolySynth, base_id: u8) void {
    var attack = synth.paramValue(base_id) orelse return;
    var decay = synth.paramValue(base_id + 1) orelse return;
    var sustain = synth.paramValue(base_id + 2) orelse return;
    var release = synth.paramValue(base_id + 3) orelse return;
    const a_range = (ws.dsp.PolySynth.findAutomatableParam(base_id) orelse return).range;
    const d_range = (ws.dsp.PolySynth.findAutomatableParam(base_id + 1) orelse return).range;
    const r_range = (ws.dsp.PolySynth.findAutomatableParam(base_id + 3) orelse return).range;

    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "adsr##gui-synth-{d}", .{base_id}) catch return;
    const cursor = app.core.synth_cursor;
    const focused_stage: ?u2 = if (cursor == base_id) 0 else if (cursor == base_id + 1 or cursor == base_id + 2) 1 else if (cursor == base_id + 3) 2 else null;

    const result = widgets.adsrEditor(label, .{
        .attack = &attack,
        .decay = &decay,
        .sustain = &sustain,
        .release = &release,
        .attack_range = a_range,
        .decay_range = d_range,
        .release_range = r_range,
        .accent = theme.rhythm,
        .focused_stage = focused_stage,
    });
    if (result.changed[0]) sendParam(app, base_id, attack);
    if (result.changed[1]) sendParam(app, base_id + 1, decay);
    if (result.changed[2]) sendParam(app, base_id + 2, sustain);
    if (result.changed[3]) sendParam(app, base_id + 3, release);
    if (result.activated_stage) |stage| app.core.synth_cursor = switch (stage) {
        0 => base_id,
        1 => base_id + 1,
        else => base_id + 3,
    };
    zgui.textDisabled("A {d:.3}s  D {d:.3}s  S {d:.2}  R {d:.3}s", .{ attack, decay, sustain, release });
}

fn drawFilterPad(app: anytype, synth: *ws.dsp.PolySynth, cutoff_id: u8) void {
    const res_id = cutoff_id + 1;
    var cutoff = synth.paramValue(cutoff_id) orelse return;
    var res = synth.paramValue(res_id) orelse return;
    const c_range = (ws.dsp.PolySynth.findAutomatableParam(cutoff_id) orelse return).range;
    const r_range = (ws.dsp.PolySynth.findAutomatableParam(res_id) orelse return).range;

    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "xy##gui-synth-{d}", .{cutoff_id}) catch return;
    const focused = app.core.synth_cursor == cutoff_id or app.core.synth_cursor == res_id;

    zgui.textDisabled("cutoff / res", .{});
    const result = widgets.xyPad(label, .{
        .x = &cutoff,
        .y = &res,
        .x_range = c_range,
        .y_range = r_range,
        .x_cfmt = "%.0f Hz",
        .y_cfmt = "%.2f",
        .x_logarithmic = true,
        .accent = theme.audio,
        .focused = focused,
    });
    if (result.changed) {
        sendParam(app, cutoff_id, cutoff);
        sendParam(app, res_id, res);
    }
    if (result.activated) app.core.synth_cursor = cutoff_id;
}

/// Which `.custom` LFO slot (0/1/2) a MOD section's "shape" entry drives -
/// see `dsp.synth.lfo_custom_id_base`'s id-layout doc comment. `null` for
/// every other id (rate, matrix rows, ...), so the extra draw call below is
/// a no-op for them.
fn lfoShapeSlot(id: u8) ?usize {
    return switch (id) {
        28 => 0,
        95 => 1,
        97 => 2,
        else => null,
    };
}

/// `.custom` LFO shape's breakpoint editor - drawn right under that LFO's
/// shape/rate rows, only while the shape is actually set to `.custom`
/// (picking any other shape via the +/- cycle above just hides it again).
/// Reuses widgets.curveEditor exactly like the automation view does (see
/// that view's own drawCurve for the fuller-chrome version); this one skips
/// the bar-ruler/axis-label chrome since a single LFO cycle doesn't need
/// them, just the plot.
fn drawLfoCustomCurve(app: anytype, synth: *ws.dsp.PolySynth, slot: usize) void {
    const shape = switch (slot) {
        0 => synth.lfo_shape,
        1 => synth.lfo2_shape,
        else => synth.lfo3_shape,
    };
    if (shape != .custom) return;

    const count = synth.lfo_custom_count[slot];
    var curve_buf: [ws.dsp.synth.max_lfo_shape_points]widgets.CurvePoint = undefined;
    for (synth.lfo_custom[slot][0..count], curve_buf[0..count]) |src, *dst| {
        dst.* = .{ .beat = src.phase, .value = src.value };
    }

    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "lfo-custom##gui-synth-{d}", .{slot}) catch return;
    const base: u8 = ws.dsp.synth.lfo_custom_id_base + @as(u8, @intCast(slot)) * ws.dsp.synth.lfo_custom_ids_per_slot;
    const base_usize: usize = base;
    const count_id: u8 = base + ws.dsp.synth.max_lfo_shape_points * 2;
    const focused_index: ?usize = if (app.core.synth_cursor >= base and app.core.synth_cursor < count_id)
        (app.core.synth_cursor - base) / 2
    else
        null;

    const result = widgets.curveEditor(label, .{
        .points = curve_buf[0..count],
        .beat_hi = 1.0,
        .value_lo = -1.0,
        .value_hi = 1.0,
        .snap_beats = 0,
        .accent = theme.modulation,
        .focused_index = focused_index,
        .x_unit_label = "phase",
        .height = 130,
    });

    if (result.moved) |m| {
        const phase_id: u8 = @intCast(base_usize + m.index * 2);
        sendParam(app, phase_id, @floatCast(m.beat));
        sendParam(app, phase_id + 1, m.value);
    }
    if (result.inserted) |ins| {
        if (count < ws.dsp.synth.max_lfo_shape_points) {
            var k: usize = 0;
            while (k < count and curve_buf[k].beat < ins.beat) : (k += 1) {}
            var i: usize = count;
            while (i > k) : (i -= 1) {
                const src = curve_buf[i - 1];
                const dst_phase_id: u8 = @intCast(base_usize + i * 2);
                sendParam(app, dst_phase_id, @floatCast(src.beat));
                sendParam(app, dst_phase_id + 1, src.value);
            }
            const new_phase_id: u8 = @intCast(base_usize + k * 2);
            sendParam(app, new_phase_id, @floatCast(ins.beat));
            sendParam(app, new_phase_id + 1, ins.value);
            sendParam(app, count_id, @floatFromInt(count + 1));
            app.core.synth_cursor = new_phase_id;
        }
    }
    if (result.removed) |beat| {
        var idx: ?usize = null;
        for (curve_buf[0..count], 0..) |p, i| {
            if (@abs(p.beat - beat) < 1e-6) {
                idx = i;
                break;
            }
        }
        if (idx) |ix| {
            var i: usize = ix;
            while (i + 1 < count) : (i += 1) {
                const src = curve_buf[i + 1];
                const dst_phase_id: u8 = @intCast(base_usize + i * 2);
                sendParam(app, dst_phase_id, @floatCast(src.beat));
                sendParam(app, dst_phase_id + 1, src.value);
            }
            sendParam(app, count_id, @floatFromInt(count - 1));
        }
    }
    if (result.activated_index) |i| app.core.synth_cursor = @intCast(base_usize + i * 2);
}

fn sectionColor(index: usize) [4]f32 {
    return switch (index % 5) {
        0 => theme.focus,
        1 => theme.audio,
        2 => theme.modulation,
        3 => theme.rhythm,
        else => theme.danger,
    };
}

fn drawFx(app: anytype, synth: *ws.dsp.PolySynth) void {
    var order_buf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const order = synth_ed.fxOnOrder(&app.core, &order_buf);
    zgui.textDisabled("SIGNAL FLOW", .{});
    zgui.sameLine(.{ .spacing = 12 });
    zgui.textColored(theme.audio, "IN", .{});
    for (order) |kind| {
        zgui.sameLine(.{ .spacing = 7 });
        zgui.textDisabled(">", .{});
        zgui.sameLine(.{ .spacing = 7 });
        zgui.textColored(theme.fg1, "{s}", .{spectrum_ed.stripLabel(synth_ed.asFxKind(kind))});
    }
    zgui.sameLine(.{ .spacing = 7 });
    zgui.textDisabled(">", .{});
    zgui.sameLine(.{ .spacing = 7 });
    zgui.textColored(theme.audio, "OUT", .{});
    if (order.len == 0) {
        zgui.spacing();
        zgui.textDisabled("No internal effects are enabled. Press a to insert one.", .{});
        return;
    }
    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = theme.bg2 });
    if (zgui.beginChild("synth-fx-params", .{
        .w = 0,
        .h = 0,
        .child_flags = .{ .border = true, .auto_resize_y = true },
        .window_flags = .{ .no_scrollbar = true, .no_scroll_with_mouse = true },
    })) {
        var candidates_buf: [synth_ed.max_search_candidates]synth_ed.SearchCandidate = undefined;
        var previous_kind: ?ws.dsp.synth.FxUnitKind = null;
        for (synth_ed.searchCandidates(&app.core, &candidates_buf)) |candidate| {
            if (candidate.subview != .fx) continue;
            const kind = synth_ed.fxKindOfId(candidate.id) orelse continue;
            if (previous_kind == null or previous_kind.? != kind) {
                if (previous_kind != null) zgui.spacing();
                widgets.sectionTitle(spectrum_ed.unitLabel(synth_ed.asFxKind(kind)), theme.audio);
                previous_kind = kind;
            }
            drawAnyParam(app, synth, candidate.id, synth_ed.fxParamLabel(candidate.id));
        }
    }
    zgui.endChild();
    zgui.popStyleColor(.{});
}

fn drawAnyParam(app: anytype, synth: *ws.dsp.PolySynth, id: u8, label_text: []const u8) void {
    if (ws.dsp.PolySynth.findAutomatableParam(id)) |param| {
        var value = synth.paramValue(id) orelse return;
        var label_buf: [96]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{s}##gui-synth-{d}", .{ label_text, id }) catch return;
        const focused = app.core.synth_cursor == id;
        const result = widgets.paramKnob(label_text, label, .{ .v = &value, .min = param.range[0], .max = param.range[1], .cfmt = "%.3f", .accent = theme.focus, .focused = focused, .diameter = 24 });
        if (result.changed) sendParam(app, id, value);
        if (result.activated) app.core.synth_cursor = id;
        return;
    }
    const value = synth.paramValue(id) orelse return;
    if (ws.dsp.PolySynth.isToggleParam(id)) {
        drawParamToggle(app, id, label_text, value >= 0.5);
        return;
    }
    if (isWaveformParam(id)) {
        drawWaveformParam(app, id, label_text, value);
        return;
    }
    const row_origin = zgui.getCursorScreenPos();
    zgui.beginGroup();
    zgui.text("{s}", .{label_text});
    zgui.sameLine(.{ .spacing = 8 });
    var minus_buf: [32]u8 = undefined;
    const minus = std.fmt.bufPrintZ(&minus_buf, "-##synth-minus-{d}", .{id}) catch return;
    if (zgui.smallButton(minus)) nudgeParam(app, id, 'h');
    zgui.sameLine(.{ .spacing = 5 });
    zgui.textColored(if (app.core.synth_cursor == id) theme.focus else theme.fg1, "{d:.2}", .{value});
    zgui.sameLine(.{ .spacing = 5 });
    var plus_buf: [32]u8 = undefined;
    const plus = std.fmt.bufPrintZ(&plus_buf, "+##synth-plus-{d}", .{id}) catch return;
    if (zgui.smallButton(plus)) nudgeParam(app, id, 'l');
    zgui.endGroup();
    // Scroll while hovering the row steps it, one 'h'/'l' nudge per tick -
    // same manual rect hit-test as widgets.listStepper, since isItemHovered
    // doesn't chain through EndGroup.
    const row_max = zgui.getItemRectMax();
    const mouse = zgui.getMousePos();
    const row_hovered = mouse[0] >= row_origin[0] and mouse[0] < row_max[0] and mouse[1] >= row_origin[1] and mouse[1] < row_max[1];
    if (row_hovered and gui_style.wheel_delta != 0) nudgeParam(app, id, if (gui_style.wheel_delta > 0) 'l' else 'h');
}

/// A boolean param rendered as a single on/off button - `nudgeParam`'s
/// h-step flips a toggle just like it would any other stepped value, so
/// clicking it reuses the same command path an `h`/`l` keypress would.
fn drawParamToggle(app: anytype, id: u8, label_text: []const u8, active: bool) void {
    const focused = app.core.synth_cursor == id;
    zgui.text("{s}", .{label_text});
    zgui.sameLine(.{ .spacing = 8 });
    var btn_buf: [48]u8 = undefined;
    const btn_id = std.fmt.bufPrintZ(&btn_buf, "{s}##synth-toggle-{d}", .{ if (active) "ON" else "OFF", id }) catch return;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) theme.focus else if (focused) theme.bg4 else theme.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else if (focused) theme.focus else theme.fg2 });
    if (zgui.smallButton(btn_id)) nudgeParam(app, id, 'h');
    zgui.popStyleColor(.{ .count = 2 });
}

/// OSC A/B/C's waveform param ids - the only `param_specs` cycle rows with
/// an obvious icon per option, so `widgets.waveformPicker` covers just
/// these three rather than every enum-valued param (filter type, LFO
/// shape, ... still fall through to the generic -/+ stepper below).
fn isWaveformParam(id: u8) bool {
    return id == 0 or id == 7 or id == 51;
}

fn drawWaveformParam(app: anytype, id: u8, label_text: []const u8, value: f32) void {
    const focused = app.core.synth_cursor == id;
    zgui.text("{s}", .{label_text});
    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "##synth-wave-{d}", .{id}) catch return;
    const current = ws.dsp.synth.enumFromValue(ws.dsp.synth.Waveform, value);
    if (widgets.waveformPicker(label, current, theme.focus, focused)) |picked| {
        app.core.synth_cursor = id;
        sendParam(app, id, ws.dsp.synth.enumToValue(picked));
    }
}

fn nudgeParam(app: anytype, id: u8, key: u8) void {
    app.core.synth_cursor = id;
    app.core.handleKey(.{ .char = key }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
}

fn drawHeader(app: anytype, synth: *ws.dsp.PolySynth) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 156;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("synth-overview", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(theme.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(theme.focus), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(theme.fg3), "POLYPHONIC SYNTH", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 31 }, color(theme.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.synth_track].name});

    const panel_y = origin[1] + 59;
    const panel_h: f32 = 80;
    const panel_gap: f32 = 9;
    const panel_w = (width - 43 - panel_gap * 2) / 3;
    drawOverviewPanel(draw_list, .{ origin[0] + 17, panel_y }, .{ panel_w, panel_h }, "OSCILLATOR", theme.focus);
    drawOverviewPanel(draw_list, .{ origin[0] + 17 + panel_w + panel_gap, panel_y }, .{ panel_w, panel_h }, "ENVELOPE", theme.rhythm);
    drawOverviewPanel(draw_list, .{ origin[0] + 17 + (panel_w + panel_gap) * 2, panel_y }, .{ panel_w, panel_h }, "FILTER", theme.audio);
    drawOscillatorShape(draw_list, .{ origin[0] + 29, panel_y + 31 }, .{ panel_w - 24, 35 }, synth.waveform);
    drawEnvelopeShape(draw_list, .{ origin[0] + 29 + panel_w + panel_gap, panel_y + 31 }, .{ panel_w - 24, 35 }, synth);
    drawFilterShape(draw_list, .{ origin[0] + 29 + (panel_w + panel_gap) * 2, panel_y + 31 }, .{ panel_w - 24, 35 }, synth);
}

fn drawOverviewPanel(draw_list: zgui.DrawList, pos: [2]f32, size: [2]f32, label: []const u8, accent: [4]f32) void {
    draw_list.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + size[0], pos[1] + size[1] }, .col = color(theme.bg1), .rounding = 3 });
    draw_list.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + 3, pos[1] + size[1] }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ pos[0] + 12, pos[1] + 8 }, color(theme.fg3), "{s}", .{label});
}

fn drawOscillatorShape(draw_list: zgui.DrawList, pos: [2]f32, size: [2]f32, waveform: ws.dsp.synth.Waveform) void {
    var prev = pos;
    for (1..49) |i| {
        const phase = @as(f32, @floatFromInt(i)) / 48.0 * 2.0;
        const sample: f32 = switch (waveform) {
            .sine => @sin(phase * std.math.pi * 2.0),
            .saw, .wavetable => phase - @floor(phase) * 2.0 - 1.0,
            .triangle => 1.0 - 4.0 * @abs(@round(phase) - phase),
            .square => if (@mod(phase, 1.0) < 0.5) 1.0 else -1.0,
        };
        const point = [2]f32{ pos[0] + size[0] * @as(f32, @floatFromInt(i)) / 48.0, pos[1] + size[1] * (0.5 - sample * 0.42) };
        if (i > 1) draw_list.addLine(.{ .p1 = prev, .p2 = point, .col = color(theme.focus), .thickness = 2 });
        prev = point;
    }
}

fn drawEnvelopeShape(draw_list: zgui.DrawList, pos: [2]f32, size: [2]f32, synth: *const ws.dsp.PolySynth) void {
    const ad_total = @max(0.01, synth.attack_s + synth.decay_s);
    const attack_x = pos[0] + size[0] * 0.55 * synth.attack_s / ad_total;
    const decay_x = pos[0] + size[0] * 0.55;
    const release_x = pos[0] + size[0] * 0.78;
    const sustain_y = pos[1] + size[1] * (1.0 - synth.sustain);
    const points = [_][2]f32{ .{ pos[0], pos[1] + size[1] }, .{ attack_x, pos[1] }, .{ decay_x, sustain_y }, .{ release_x, sustain_y }, .{ pos[0] + size[0], pos[1] + size[1] } };
    for (0..points.len - 1) |i| draw_list.addLine(.{ .p1 = points[i], .p2 = points[i + 1], .col = color(theme.rhythm), .thickness = 2 });
}

fn drawFilterShape(draw_list: zgui.DrawList, pos: [2]f32, size: [2]f32, synth: *const ws.dsp.PolySynth) void {
    const cutoff = std.math.clamp(@log10(synth.filter_cutoff / 20.0) / 3.0, 0, 1);
    const knee_x = pos[0] + size[0] * cutoff;
    const peak_y = pos[1] + size[1] * (0.45 - synth.filter_res * 0.35);
    const left = [2]f32{ pos[0], pos[1] + size[1] * 0.45 };
    const right = [2]f32{ pos[0] + size[0], pos[1] + size[1] * 0.45 };
    const bottom_left = [2]f32{ pos[0], pos[1] + size[1] };
    const bottom_right = [2]f32{ pos[0] + size[0], pos[1] + size[1] };
    switch (synth.filter_type) {
        .lp, .ladder, .diode => {
            draw_list.addLine(.{ .p1 = left, .p2 = .{ knee_x, peak_y }, .col = color(theme.audio), .thickness = 2 });
            draw_list.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = bottom_right, .col = color(theme.audio), .thickness = 2 });
        },
        .hp => {
            draw_list.addLine(.{ .p1 = bottom_left, .p2 = .{ knee_x, peak_y }, .col = color(theme.audio), .thickness = 2 });
            draw_list.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = right, .col = color(theme.audio), .thickness = 2 });
        },
        .bp, .formant => {
            draw_list.addLine(.{ .p1 = bottom_left, .p2 = .{ knee_x, peak_y }, .col = color(theme.audio), .thickness = 2 });
            draw_list.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = bottom_right, .col = color(theme.audio), .thickness = 2 });
        },
        .notch, .comb => {
            draw_list.addLine(.{ .p1 = left, .p2 = .{ knee_x, pos[1] + size[1] * 0.85 }, .col = color(theme.audio), .thickness = 2 });
            draw_list.addLine(.{ .p1 = .{ knee_x, pos[1] + size[1] * 0.85 }, .p2 = right, .col = color(theme.audio), .thickness = 2 });
        },
    }
}
