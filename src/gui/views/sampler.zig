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

const PadTargetKind = enum { drum, slice };

/// The two editable targets this view can point at. Both expose the shared
/// dsp/pad.zig param ids 0-9; they differ in where a value is read from and
/// which engine param id a slider write maps to.
const Target = union(enum) {
    standalone: struct { sampler: *ws.dsp.Sampler, track: u16 },
    pad: struct { pad: *ws.dsp.Pad, track: u16, kind: PadTargetKind, index: u8 },

    fn value(self: Target, id: u8) ?f32 {
        return switch (self) {
            .standalone => |t| t.sampler.paramValue(id),
            .pad => |t| ws.dsp.pad.paramValue(t.pad, id),
        };
    }

    fn track(self: Target) u16 {
        return switch (self) {
            .standalone => |t| t.track,
            .pad => |t| t.track,
        };
    }

    fn engineId(self: Target, id: u8) u16 {
        return switch (self) {
            .standalone => id,
            .pad => |t| if (t.kind == .drum) ws.dsp.DrumMachine.paramId(t.index, id) else ws.dsp.Slicer.paramId(t.index, id),
        };
    }
};

// The param sections both targets share (dsp/pad.zig ids); the standalone
// sampler appends its KEY section (root note, voice mode) after these.
// zig fmt: off
const ParamRow = struct { id: u8, label: []const u8, fmt: [:0]const u8 };
const Section = struct { title: [:0]const u8, color: *const [4]f32, rows: []const ParamRow };
const shared_sections = [_]Section{
    .{ .title = "SAMPLE", .color = &patina.focus, .rows = &.{
        .{ .id = 0, .label = "Start",   .fmt = "%.3f" },
        .{ .id = 1, .label = "End",     .fmt = "%.3f" },
        .{ .id = 2, .label = "Pitch",   .fmt = "%.0f st" },
    } },
    .{ .title = "AMP ENV", .color = &patina.rhythm, .rows = &.{
        .{ .id = 3, .label = "Attack",  .fmt = "%.3f s" },
        .{ .id = 4, .label = "Decay",   .fmt = "%.3f s" },
        .{ .id = 5, .label = "Sustain", .fmt = "%.2f" },
        .{ .id = 6, .label = "Release", .fmt = "%.3f s" },
    } },
    .{ .title = "OUT", .color = &patina.audio, .rows = &.{
        .{ .id = 7, .label = "Gain",    .fmt = "%.2f" },
        .{ .id = 8, .label = "Pan",     .fmt = "%.2f" },
    } },
};
// zig fmt: on

fn drawSharedSections(app: anytype, target: Target) void {
    for (shared_sections) |section| {
        widgets.sectionTitle(section.title, section.color.*);
        for (section.rows) |row| drawParam(app, target, row.id, row.label, row.fmt);
        if (section.rows[section.rows.len - 1].id == 8) {
            drawToggle(app, target, 9, "REVERSE", "FORWARD", if (target == .pad) patina.modulation else patina.focus);
        }
        zgui.spacing();
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

    const target: Target = .{ .standalone = .{ .sampler = sampler, .track = track } };
    drawSharedSections(app, target);
    widgets.sectionTitle("KEY", patina.rhythm);
    drawParam(app, target, 10, "Root note", "%.0f");
    drawToggle(app, target, 11, "MONO", "POLY", patina.focus);
}

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

    drawSharedSections(app, .{ .pad = .{ .pad = pad, .track = track, .kind = kind, .index = index } });
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

// Slider bounds come from the dsp-side spec table so they can never drift
// from what setParamAbsolute actually clamps to. Pad ids 0-8 are the same
// params the standalone sampler routes to dsp/pad.zig, so one table covers
// both targets; root note (10) is the only continuous id outside it.
fn paramRange(id: u8) [2]f32 {
    if (ws.dsp.Sampler.findAutomatableParam(id)) |param| return param.range;
    if (id == 10) return .{ 0, 127 };
    return .{ 0, 1 };
}

fn drawParam(app: anytype, target: Target, id: u8, label_text: []const u8, format: [:0]const u8) void {
    var value = target.value(id) orelse return;
    const range = paramRange(id);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##sampler-target-{d}", .{ label_text, id }) catch return;
    const focused = app.core.sampler_param == id;
    style.pushControlFocus(focused, patina.focus);
    defer style.popControlFocus(focused);
    if (zgui.sliderFloat(label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format })) {
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = target.track(), .id = target.engineId(id), .value = value } });
    }
    if (zgui.isItemActivated()) app.core.sampler_param = id;
}

fn drawToggle(app: anytype, target: Target, id: u8, on_label: [:0]const u8, off_label: [:0]const u8, active_color: [4]f32) void {
    const value = target.value(id) orelse return;
    const active = value >= 0.5;
    const focused = app.core.sampler_param == id;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) active_color else if (focused) patina.bg4 else patina.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) patina.bg0 else if (focused) patina.focus else patina.fg2 });
    if (zgui.button(if (active) on_label else off_label, .{ .w = 106, .h = 32 })) {
        app.core.sampler_param = id;
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = target.track(), .id = target.engineId(id), .value = if (active) 0 else 1 } });
    }
    zgui.popStyleColor(.{ .count = 2 });
}
