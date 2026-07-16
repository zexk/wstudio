const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../tui/icons.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const patina = &style.palette;

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

    widgets.sectionTitle("SAMPLE", patina.focus);
    drawParam(app, sampler, 0, "Start", "%.3f");
    drawParam(app, sampler, 1, "End", "%.3f");
    drawParam(app, sampler, 2, "Pitch", "%.0f st");
    zgui.spacing();
    widgets.sectionTitle("AMP ENV", patina.rhythm);
    drawParam(app, sampler, 3, "Attack", "%.3f s");
    drawParam(app, sampler, 4, "Decay", "%.3f s");
    drawParam(app, sampler, 5, "Sustain", "%.2f");
    drawParam(app, sampler, 6, "Release", "%.3f s");
    zgui.spacing();
    widgets.sectionTitle("OUT", patina.audio);
    drawParam(app, sampler, 7, "Gain", "%.2f");
    drawParam(app, sampler, 8, "Pan", "%.2f");
    drawToggle(app, sampler, 9, "REVERSE", "FORWARD");
    zgui.spacing();
    widgets.sectionTitle("KEY", patina.rhythm);
    drawParam(app, sampler, 10, "Root note", "%.0f");
    drawToggle(app, sampler, 11, "MONO", "POLY");
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

    drawPadHeader(app, track, kind, index);
    zgui.spacing();
    widgets.sectionTitle("PLAY REGION", patina.audio);
    widgets.waveform("##pad-target-wave", pad.samples);
    zgui.textDisabled("Region {d:.1}-{d:.1}% of {d} samples", .{ pad.start_norm * 100, pad.end_norm * 100, pad.samples.len });
    zgui.spacing();

    widgets.sectionTitle("SAMPLE", patina.focus);
    drawPadParam(app, track, kind, index, pad, 0, "Start", "%.3f");
    drawPadParam(app, track, kind, index, pad, 1, "End", "%.3f");
    drawPadParam(app, track, kind, index, pad, 2, "Pitch", "%.0f st");
    zgui.spacing();
    widgets.sectionTitle("AMP ENV", patina.rhythm);
    drawPadParam(app, track, kind, index, pad, 3, "Attack", "%.3f s");
    drawPadParam(app, track, kind, index, pad, 4, "Decay", "%.3f s");
    drawPadParam(app, track, kind, index, pad, 5, "Sustain", "%.2f");
    drawPadParam(app, track, kind, index, pad, 6, "Release", "%.3f s");
    zgui.spacing();
    widgets.sectionTitle("OUT", patina.audio);
    drawPadParam(app, track, kind, index, pad, 7, "Gain", "%.2f");
    drawPadParam(app, track, kind, index, pad, 8, "Pan", "%.2f");
    drawPadToggle(app, track, kind, index, pad);
}

fn drawPadHeader(app: anytype, track: u16, kind: PadTargetKind, index: u8) void {
    switch (kind) {
        .drum => zgui.textDisabled(icons.drum ++ "  SAMPLER", .{}),
        .slice => zgui.textDisabled(icons.slicer ++ "  SLICE", .{}),
    }
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{app.core.session.project.tracks.items[track].name});
    zgui.sameLine(.{});
    switch (kind) {
        .drum => {
            const drum = &app.core.session.racks.items[track].instrument.drum_machine;
            zgui.textDisabled("pad {d}/{d}", .{ index + 1, ws.dsp.DrumMachine.max_pads });
            zgui.sameLine(.{});
            zgui.textColored(patina.rhythm, "\"{s}\"", .{drum.padName(index)});
        },
        .slice => {
            const slicer = &app.core.session.racks.items[track].instrument.slicer;
            zgui.textDisabled("slice {d}/{d}", .{ index + 1, slicer.slice_count });
            zgui.sameLine(.{});
            zgui.textColored(patina.audio, "\"{s}\"", .{slicer.clipName()});
        },
    }
}

// Slider bounds come from the dsp-side spec table so they can never drift
// from what setParamAbsolute actually clamps to. Pad ids 0-8 are the same
// params the standalone sampler routes to dsp/pad.zig, so one table covers
// both targets; root note (10) is the only continuous id outside it.
fn paramRange(id: u8) [2]f32 {
    if (ws.dsp.Sampler.findAutomatableParam(id)) |param| return param.range;
    if (id == 10) return .{ 0, 127 };
    return .{ 0, 1 };
}

fn padParamId(kind: PadTargetKind, index: u8, param: u8) u16 {
    return if (kind == .drum) ws.dsp.DrumMachine.paramId(index, param) else ws.dsp.Slicer.paramId(index, param);
}

fn drawPadParam(app: anytype, track: u16, kind: PadTargetKind, index: u8, pad: *ws.dsp.Pad, id: u8, label_text: []const u8, format: [:0]const u8) void {
    var value = ws.dsp.pad.paramValue(pad, id) orelse return;
    const range = paramRange(id);
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
    const track = switch (app.core.sampler_target) {
        .sampler => |t| t,
        else => return,
    };
    zgui.textDisabled(icons.sampler ++ "  SAMPLER", .{});
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{app.core.session.project.tracks.items[track].name});
    zgui.sameLine(.{});
    zgui.textColored(patina.focus, "\"{s}\"", .{sampler.clipName()});
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
