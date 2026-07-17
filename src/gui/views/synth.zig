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
const patina = &gui_style.palette;

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
    const tabs = [_]struct { label: [:0]const u8, subview: synth_ed.Subview }{
        .{ .label = "MAIN", .subview = .main },
        .{ .label = "MODULATION", .subview = .mod },
        .{ .label = "INTERNAL FX", .subview = .fx },
    };
    for (tabs, 0..) |tab, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 5 });
        const active = app.core.synth_subview == tab.subview;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) patina.focus else patina.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) patina.bg0 else patina.fg2 });
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
    const gap: f32 = 10;
    const column_w = @max(300, (zgui.getContentRegionAvail()[0] - gap) / 2);
    inline for (0..2) |column| {
        if (column > 0) zgui.sameLine(.{ .spacing = gap });
        const child_id = child_prefix ++ if (column == 0) "-left" else "-right";
        if (zgui.beginChild(child_id, .{ .w = if (column == 0) column_w else 0, .h = 0, .child_flags = .{ .border = true } })) {
            inline for (sections, 0..) |section, section_index| {
                if (section_index % 2 != column) continue;
                widgets.sectionTitle(section.title, sectionColor(section_index));
                inline for (section.params) |entry| {
                    inline for (0..entry.fields) |field| {
                        var label_buf: [48]u8 = undefined;
                        const id = entry.id + field;
                        drawAnyParam(app, synth, id, synth_ed.paramLabel(id, &label_buf));
                    }
                }
                zgui.spacing();
            }
        }
        zgui.endChild();
    }
}

fn sectionColor(index: usize) [4]f32 {
    return switch (index % 5) {
        0 => patina.focus,
        1 => patina.audio,
        2 => patina.modulation,
        3 => patina.rhythm,
        else => patina.danger,
    };
}

fn drawFx(app: anytype, synth: *ws.dsp.PolySynth) void {
    var order_buf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const order = synth_ed.fxOnOrder(&app.core, &order_buf);
    zgui.textDisabled("SIGNAL FLOW", .{});
    zgui.sameLine(.{ .spacing = 12 });
    zgui.textColored(patina.audio, "IN", .{});
    for (order) |kind| {
        zgui.sameLine(.{ .spacing = 7 });
        zgui.textDisabled(">", .{});
        zgui.sameLine(.{ .spacing = 7 });
        zgui.textColored(patina.fg1, "{s}", .{spectrum_ed.stripLabel(synth_ed.asFxKind(kind))});
    }
    zgui.sameLine(.{ .spacing = 7 });
    zgui.textDisabled(">", .{});
    zgui.sameLine(.{ .spacing = 7 });
    zgui.textColored(patina.audio, "OUT", .{});
    if (order.len == 0) {
        zgui.spacing();
        zgui.textDisabled("No internal effects are enabled. Press i to insert one.", .{});
        return;
    }
    zgui.spacing();
    if (zgui.beginChild("synth-fx-params", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        var candidates_buf: [synth_ed.max_search_candidates]synth_ed.SearchCandidate = undefined;
        var previous_kind: ?ws.dsp.synth.FxUnitKind = null;
        for (synth_ed.searchCandidates(&app.core, &candidates_buf)) |candidate| {
            if (candidate.subview != .fx) continue;
            const kind = synth_ed.fxKindOfId(candidate.id) orelse continue;
            if (previous_kind == null or previous_kind.? != kind) {
                if (previous_kind != null) zgui.spacing();
                widgets.sectionTitle(spectrum_ed.unitLabel(synth_ed.asFxKind(kind)), patina.audio);
                previous_kind = kind;
            }
            drawAnyParam(app, synth, candidate.id, synth_ed.fxParamLabel(candidate.id));
        }
    }
    zgui.endChild();
}

fn drawAnyParam(app: anytype, synth: *ws.dsp.PolySynth, id: u8, label_text: []const u8) void {
    if (ws.dsp.PolySynth.findAutomatableParam(id)) |param| {
        var value = synth.paramValue(id) orelse return;
        var label_buf: [96]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{s}##gui-synth-{d}", .{ label_text, id }) catch return;
        const focused = app.core.synth_cursor == id;
        const result = widgets.paramKnob(label_text, label, .{ .v = &value, .min = param.range[0], .max = param.range[1], .cfmt = "%.3f", .accent = patina.focus, .focused = focused });
        if (result.changed) {
            _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = app.core.synth_track, .id = id, .value = value } });
        }
        if (result.activated) app.core.synth_cursor = id;
        return;
    }
    const value = synth.paramValue(id) orelse return;
    zgui.text("{s}", .{label_text});
    zgui.sameLine(.{ .spacing = 8 });
    var minus_buf: [32]u8 = undefined;
    const minus = std.fmt.bufPrintZ(&minus_buf, "-##synth-minus-{d}", .{id}) catch return;
    if (zgui.smallButton(minus)) nudgeParam(app, id, 'h');
    zgui.sameLine(.{ .spacing = 5 });
    zgui.textColored(if (app.core.synth_cursor == id) patina.focus else patina.fg1, "{d:.2}", .{value});
    zgui.sameLine(.{ .spacing = 5 });
    var plus_buf: [32]u8 = undefined;
    const plus = std.fmt.bufPrintZ(&plus_buf, "+##synth-plus-{d}", .{id}) catch return;
    if (zgui.smallButton(plus)) nudgeParam(app, id, 'l');
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
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(patina.focus), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(patina.fg3), "POLYPHONIC SYNTH", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 31 }, color(patina.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.synth_track].name});

    const panel_y = origin[1] + 59;
    const panel_h: f32 = 80;
    const panel_gap: f32 = 9;
    const panel_w = (width - 43 - panel_gap * 2) / 3;
    drawOverviewPanel(draw_list, .{ origin[0] + 17, panel_y }, .{ panel_w, panel_h }, "OSCILLATOR", patina.focus);
    drawOverviewPanel(draw_list, .{ origin[0] + 17 + panel_w + panel_gap, panel_y }, .{ panel_w, panel_h }, "ENVELOPE", patina.rhythm);
    drawOverviewPanel(draw_list, .{ origin[0] + 17 + (panel_w + panel_gap) * 2, panel_y }, .{ panel_w, panel_h }, "FILTER", patina.audio);
    drawOscillatorShape(draw_list, .{ origin[0] + 29, panel_y + 31 }, .{ panel_w - 24, 35 }, synth.waveform);
    drawEnvelopeShape(draw_list, .{ origin[0] + 29 + panel_w + panel_gap, panel_y + 31 }, .{ panel_w - 24, 35 }, synth);
    drawFilterShape(draw_list, .{ origin[0] + 29 + (panel_w + panel_gap) * 2, panel_y + 31 }, .{ panel_w - 24, 35 }, synth);
}

fn drawOverviewPanel(draw_list: zgui.DrawList, pos: [2]f32, size: [2]f32, label: []const u8, accent: [4]f32) void {
    draw_list.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + size[0], pos[1] + size[1] }, .col = color(patina.bg1), .rounding = 3 });
    draw_list.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + 3, pos[1] + size[1] }, .col = color(accent), .rounding = 2 });
    draw_list.addText(.{ pos[0] + 12, pos[1] + 8 }, color(patina.fg3), "{s}", .{label});
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
        if (i > 1) draw_list.addLine(.{ .p1 = prev, .p2 = point, .col = color(patina.focus), .thickness = 2 });
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
    for (0..points.len - 1) |i| draw_list.addLine(.{ .p1 = points[i], .p2 = points[i + 1], .col = color(patina.rhythm), .thickness = 2 });
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
            draw_list.addLine(.{ .p1 = left, .p2 = .{ knee_x, peak_y }, .col = color(patina.audio), .thickness = 2 });
            draw_list.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = bottom_right, .col = color(patina.audio), .thickness = 2 });
        },
        .hp => {
            draw_list.addLine(.{ .p1 = bottom_left, .p2 = .{ knee_x, peak_y }, .col = color(patina.audio), .thickness = 2 });
            draw_list.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = right, .col = color(patina.audio), .thickness = 2 });
        },
        .bp, .formant => {
            draw_list.addLine(.{ .p1 = bottom_left, .p2 = .{ knee_x, peak_y }, .col = color(patina.audio), .thickness = 2 });
            draw_list.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = bottom_right, .col = color(patina.audio), .thickness = 2 });
        },
        .notch, .comb => {
            draw_list.addLine(.{ .p1 = left, .p2 = .{ knee_x, pos[1] + size[1] * 0.85 }, .col = color(patina.audio), .thickness = 2 });
            draw_list.addLine(.{ .p1 = .{ knee_x, pos[1] + size[1] * 0.85 }, .p2 = right, .col = color(patina.audio), .thickness = 2 });
        },
    }
}
