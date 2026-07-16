const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const color = style.color;
const patina = style.patina;

pub fn draw(app: anytype) void {
    switch (app.core.sampler_target) {
        .sampler => drawStandalone(app),
        .drum => |track| drawPadTarget(app, track, .drum),
        .slice => |track| drawPadTarget(app, track, .slice),
    }
}

fn drawStandalone(app: anytype) void {
    const track = app.core.sampler_target.sampler;
    if (track >= app.core.session.racks.items.len) return;
    const sampler = switch (app.core.session.racks.items[track].instrument) {
        .sampler => |*s| s,
        else => {
            zgui.textDisabled("Select a Sampler track.", .{});
            return;
        },
    };
    drawHeader(app, sampler);
    zgui.spacing();
    widgets.sectionTitle("SAMPLE WAVEFORM", patina.audio);
    if (sampler.pad_lock.tryLock()) {
        defer sampler.pad_lock.unlock();
        widgets.waveform("##sampler-wave", sampler.pad.samples);
    }
    zgui.spacing();

    const gap: f32 = 10;
    const column_w = @max(300, (zgui.getContentRegionAvail()[0] - gap) / 2);
    if (zgui.beginChild("sampler-left", .{ .w = column_w, .h = 0, .child_flags = .{ .border = true } })) {
        widgets.sectionTitle("PLAYBACK", patina.focus);
        drawParam(app, sampler, 0, "Start", "%.3f");
        drawParam(app, sampler, 1, "End", "%.3f");
        drawParam(app, sampler, 2, "Pitch", "%.0f st");
        drawParam(app, sampler, 10, "Root note", "%.0f");
        zgui.spacing();
        widgets.sectionTitle("MODE", patina.modulation);
        drawToggle(app, sampler, 9, "REVERSE", "FORWARD");
        zgui.sameLine(.{ .spacing = 6 });
        drawToggle(app, sampler, 11, "MONO", "POLY");
    }
    zgui.endChild();
    zgui.sameLine(.{ .spacing = gap });
    if (zgui.beginChild("sampler-right", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        widgets.sectionTitle("AMPLITUDE ENVELOPE", patina.rhythm);
        drawParam(app, sampler, 3, "Attack", "%.3f s");
        drawParam(app, sampler, 4, "Decay", "%.3f s");
        drawParam(app, sampler, 5, "Sustain", "%.2f");
        drawParam(app, sampler, 6, "Release", "%.3f s");
        zgui.spacing();
        widgets.sectionTitle("OUTPUT", patina.audio);
        drawParam(app, sampler, 7, "Gain", "%.1f dB");
        drawParam(app, sampler, 8, "Pan", "%.2f");
    }
    zgui.endChild();
}

const PadTargetKind = enum { drum, slice };

fn drawPadTarget(app: anytype, track: u16, kind: PadTargetKind) void {
    if (track >= app.core.session.racks.items.len) return;
    const index: u8 = if (kind == .drum) app.core.drum_cursor[0] else app.core.slicer_cursor[0];
    const pad: *ws.dsp.Pad = switch (kind) {
        .drum => blk: {
            const drum = switch (app.core.session.racks.items[track].instrument) {
                .drum_machine => |*d| d,
                else => return,
            };
            if (index >= drum.pads.len or drum.pads[index] == null) {
                zgui.textDisabled("This drum pad has no sample loaded.", .{});
                return;
            }
            break :blk &drum.pads[index].?.pad;
        },
        .slice => blk: {
            const slicer = switch (app.core.session.racks.items[track].instrument) {
                .slicer => |*s| s,
                else => return,
            };
            if (index >= slicer.slice_count) {
                zgui.textDisabled("This slicer has no slice at the selected row.", .{});
                return;
            }
            break :blk &slicer.slices[index];
        },
    };

    drawPadHeader(app, track, kind, index, pad);
    zgui.spacing();
    widgets.sectionTitle("PLAY REGION", patina.audio);
    widgets.waveform("##pad-target-wave", pad.samples);
    zgui.textDisabled("Region {d:.1}-{d:.1}% of {d} samples", .{ pad.start_norm * 100, pad.end_norm * 100, pad.samples.len });
    zgui.spacing();

    const gap: f32 = 10;
    const column_w = @max(300, (zgui.getContentRegionAvail()[0] - gap) / 2);
    if (zgui.beginChild("pad-target-left", .{ .w = column_w, .h = 0, .child_flags = .{ .border = true } })) {
        widgets.sectionTitle("PLAYBACK", patina.focus);
        drawPadParam(app, track, kind, index, pad, 0, "Start", "%.3f");
        drawPadParam(app, track, kind, index, pad, 1, "End", "%.3f");
        drawPadParam(app, track, kind, index, pad, 2, "Pitch", "%.0f st");
        zgui.spacing();
        widgets.sectionTitle("MODE", patina.modulation);
        drawPadToggle(app, track, kind, index, pad);
    }
    zgui.endChild();
    zgui.sameLine(.{ .spacing = gap });
    if (zgui.beginChild("pad-target-right", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        widgets.sectionTitle("AMPLITUDE ENVELOPE", patina.rhythm);
        drawPadParam(app, track, kind, index, pad, 3, "Attack", "%.3f s");
        drawPadParam(app, track, kind, index, pad, 4, "Decay", "%.3f s");
        drawPadParam(app, track, kind, index, pad, 5, "Sustain", "%.2f");
        drawPadParam(app, track, kind, index, pad, 6, "Release", "%.3f s");
        zgui.spacing();
        widgets.sectionTitle("OUTPUT", patina.audio);
        drawPadParam(app, track, kind, index, pad, 7, "Gain", "%.2f");
        drawPadParam(app, track, kind, index, pad, 8, "Pan", "%.2f");
    }
    zgui.endChild();
}

fn drawPadHeader(app: anytype, track: u16, kind: PadTargetKind, index: u8, pad: *const ws.dsp.Pad) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("pad-target-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    const accent = if (kind == .drum) patina.rhythm else patina.audio;
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(accent), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(patina.fg3), "{s} SAMPLER", .{if (kind == .drum) "PAD" else "SLICE"});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(patina.fg0), "{s}", .{app.core.session.project.tracks.items[track].name});
    draw_list.addText(.{ origin[0] + width - 280, origin[1] + 12 }, color(accent), "{s} {d:0>2}", .{ if (kind == .drum) "PAD" else "SLICE", index + 1 });
    draw_list.addText(.{ origin[0] + width - 280, origin[1] + 39 }, color(patina.fg3), "pitch {d:.1} st   {s}", .{ pad.pitch_semitones, if (pad.reverse) "REVERSE" else "FORWARD" });
}

fn padParamRange(id: u8) [2]f32 {
    return switch (id) {
        0, 1, 5 => .{ 0, 1 },
        2 => .{ -24, 24 },
        3, 4, 6 => .{ 0, 5 },
        7 => .{ 0, 2 },
        8 => .{ -1, 1 },
        else => .{ 0, 1 },
    };
}

fn padParamId(kind: PadTargetKind, index: u8, param: u8) u16 {
    return if (kind == .drum) ws.dsp.DrumMachine.paramId(index, param) else ws.dsp.Slicer.paramId(index, param);
}

fn drawPadParam(app: anytype, track: u16, kind: PadTargetKind, index: u8, pad: *ws.dsp.Pad, id: u8, label_text: []const u8, format: [:0]const u8) void {
    var value = ws.dsp.pad.paramValue(pad, id) orelse return;
    const range = padParamRange(id);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##pad-target-{d}", .{ label_text, id }) catch return;
    const focused = app.core.sampler_param == id;
    style.pushControlFocus(focused, patina.focus);
    defer style.popControlFocus(focused);
    if (zgui.sliderFloat(label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format })) {
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = track, .id = padParamId(kind, index, id), .value = value } });
    }
    if (zgui.isItemActivated()) app.core.sampler_param = id;
}

fn drawPadToggle(app: anytype, track: u16, kind: PadTargetKind, index: u8, pad: *ws.dsp.Pad) void {
    const focused = app.core.sampler_param == 9;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (pad.reverse) patina.modulation else if (focused) patina.bg4 else patina.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (pad.reverse) patina.bg0 else if (focused) patina.focus else patina.fg2 });
    if (zgui.button(if (pad.reverse) "REVERSE" else "FORWARD", .{ .w = 106, .h = 32 })) {
        app.core.sampler_param = 9;
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = track, .id = padParamId(kind, index, 9), .value = if (pad.reverse) 0 else 1 } });
    }
    zgui.popStyleColor(.{ .count = 2 });
}

fn drawHeader(app: anytype, sampler: *const ws.dsp.Sampler) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("sampler-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(patina.focus), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(patina.fg3), "SAMPLER", .{});
    const track = switch (app.core.sampler_target) {
        .sampler => |t| t,
        else => return,
    };
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(patina.fg0), "{s}", .{app.core.session.project.tracks.items[track].name});
    draw_list.addText(.{ origin[0] + width - 310, origin[1] + 12 }, color(patina.focus), "{s}", .{sampler.clipName()});
    draw_list.addText(.{ origin[0] + width - 310, origin[1] + 39 }, color(patina.fg3), "{d} SAMPLES  ROOT {d}", .{ sampler.pad.samples.len, sampler.root_note });
}

fn paramRange(id: u8) [2]f32 {
    return switch (id) {
        0, 1, 5, 8, 9, 11 => .{ 0, 1 },
        2 => .{ -48, 48 },
        3, 4 => .{ 0, 5 },
        6 => .{ 0, 10 },
        7 => .{ -60, 12 },
        10 => .{ 0, 127 },
        else => .{ 0, 1 },
    };
}

fn drawParam(app: anytype, sampler: *ws.dsp.Sampler, id: u8, label_text: []const u8, format: [:0]const u8) void {
    var value = sampler.paramValue(id) orelse return;
    const range = paramRange(id);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##sampler-{d}", .{ label_text, id }) catch return;
    const focused = app.core.sampler_param == id;
    style.pushControlFocus(focused, patina.focus);
    defer style.popControlFocus(focused);
    if (zgui.sliderFloat(label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format })) {
        const track = switch (app.core.sampler_target) {
            .sampler => |t| t,
            else => return,
        };
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = track, .id = id, .value = value } });
    }
    if (zgui.isItemActivated()) app.core.sampler_param = id;
}

fn drawToggle(app: anytype, sampler: *ws.dsp.Sampler, id: u8, on_label: [:0]const u8, off_label: [:0]const u8) void {
    const value = sampler.paramValue(id) orelse return;
    const active = value >= 0.5;
    const focused = app.core.sampler_param == id;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) patina.focus else if (focused) patina.bg4 else patina.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) patina.bg0 else if (focused) patina.focus else patina.fg2 });
    if (zgui.button(if (active) on_label else off_label, .{ .w = 106, .h = 32 })) {
        app.core.sampler_param = id;
        const track = switch (app.core.sampler_target) {
            .sampler => |t| t,
            else => return,
        };
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = track, .id = id, .value = if (active) 0 else 1 } });
    }
    zgui.popStyleColor(.{ .count = 2 });
}
