const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const patina = &style.palette;

/// Which region edge a waveform drag is currently moving. Lives on the GUI
/// App so it survives across frames while the mouse button is held.
pub const RegionHandle = enum { start, end };

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
const Section = struct { title: [:0]const u8, color: *const [4]f32, rows: []const ParamRow, is_adsr: bool = false };
const shared_sections = [_]Section{
    .{ .title = "SAMPLE", .color = &patina.focus, .rows = &.{
        .{ .id = 0, .label = "Start",   .fmt = "%.3f" },
        .{ .id = 1, .label = "End",     .fmt = "%.3f" },
        .{ .id = 2, .label = "Pitch",   .fmt = "%.0f st" },
    } },
    .{ .title = "AMP ENV", .color = &patina.rhythm, .is_adsr = true, .rows = &.{
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
    const available = zgui.getContentRegionAvail()[0];
    const gap: f32 = 10;
    const columns: usize = if (available >= 820) shared_sections.len else 1;
    const column_width = (available - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    for (shared_sections, 0..) |section, index| {
        if (index > 0 and columns > 1) zgui.sameLine(.{ .spacing = gap });
        var child_buf: [32]u8 = undefined;
        const child_id = std.fmt.bufPrintZ(&child_buf, "sampler-module-{d}", .{index}) catch continue;
        if (zgui.beginChild(child_id, .{ .w = if (columns > 1 and index + 1 < columns) column_width else 0, .h = 205, .child_flags = .{ .border = true } })) {
            widgets.sectionTitle(section.title, section.color.*);
            if (section.is_adsr) {
                drawAmpEnvelope(app, target);
            } else {
                for (section.rows) |row| drawParam(app, target, row.id, row.label, row.fmt);
            }
            if (section.rows[section.rows.len - 1].id == 8) {
                drawToggle(app, target, 9, "REVERSE", "FORWARD", if (target == .pad) patina.modulation else patina.focus);
            }
        }
        zgui.endChild();
    }
}

fn drawAmpEnvelope(app: anytype, target: Target) void {
    var attack = target.value(3) orelse return;
    var decay = target.value(4) orelse return;
    var sustain = target.value(5) orelse return;
    var release = target.value(6) orelse return;
    const a_range = paramRange(3);
    const d_range = paramRange(4);
    const r_range = paramRange(6);

    const cursor = app.core.sampler_param;
    const focused_stage: ?u2 = if (cursor == 3) 0 else if (cursor == 4 or cursor == 5) 1 else if (cursor == 6) 2 else null;

    const result = widgets.adsrEditor("adsr##sampler-target-env", .{
        .attack = &attack,
        .decay = &decay,
        .sustain = &sustain,
        .release = &release,
        .attack_range = a_range,
        .decay_range = d_range,
        .release_range = r_range,
        .accent = patina.rhythm,
        .focused_stage = focused_stage,
    });
    if (result.changed[0]) setPadParam(app, target, 3, attack);
    if (result.changed[1]) setPadParam(app, target, 4, decay);
    if (result.changed[2]) setPadParam(app, target, 5, sustain);
    if (result.changed[3]) setPadParam(app, target, 6, release);
    if (result.activated_stage) |stage| app.core.sampler_param = switch (stage) {
        0 => 3,
        1 => 4,
        else => 6,
    };
    zgui.textDisabled("A {d:.3}s  D {d:.3}s  S {d:.2}  R {d:.3}s", .{ attack, decay, sustain, release });
}

fn setPadParam(app: anytype, target: Target, id: u8, value: f32) void {
    _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = target.track(), .id = target.engineId(id), .value = value } });
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
    const target: Target = .{ .standalone = .{ .sampler = sampler, .track = track } };
    widgets.sectionTitle("SAMPLE WAVEFORM", patina.audio);
    var has_sample = false;
    if (sampler.pad_lock.tryLock()) {
        defer sampler.pad_lock.unlock();
        has_sample = sampler.pad.samples.len > 0;
        if (has_sample) drawWaveformRegion(app, target, sampler.pad.samples);
    }
    if (!has_sample) {
        zgui.spacing();
        if (widgets.emptyState(.{
            .id = "sampler-empty-state",
            .title = "LOAD A SAMPLE",
            .explanation = "Choose a WAV file before editing trim, pitch, envelope, or output.",
            .shortcut = ":load",
            .action = "LOAD AUDIO",
            .accent = patina.audio,
        })) openLoadCommand(app);
        return;
    }
    zgui.spacing();

    drawSharedSections(app, target);
    widgets.sectionTitle("KEY", patina.rhythm);
    drawParam(app, target, 10, "Root note", "%.0f");
    drawToggle(app, target, 11, "MONO", "POLY", patina.focus);
}

fn drawPadTarget(app: anytype, track: u16, kind: PadTargetKind) void {
    if (track >= app.core.session.racks.items.len) return;
    const index: u8 = if (kind == .drum) app.core.drum_cursor[0] else app.core.slicer_cursor[0];
    drawPadHeader(app, track, kind, index);
    zgui.spacing();
    const pad: *ws.dsp.Pad = switch (kind) {
        .drum => blk: {
            const drum = switch (app.core.session.racks.items[track].instrument) {
                .drum_machine => |*d| d,
                else => return,
            };
            if (index >= drum.pads.len or drum.pads[index] == null) {
                drawPadEmptyState(app, "LOAD A PAD SAMPLE", "Choose a WAV file for this drum pad.");
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
                drawPadEmptyState(app, "NO SLICE SELECTED", "Load and slice audio before editing a slice.");
                return;
            }
            break :blk &slicer.slices[index];
        },
    };

    const target: Target = .{ .pad = .{ .pad = pad, .track = track, .kind = kind, .index = index } };
    if (pad.samples.len == 0) {
        drawPadEmptyState(app, if (kind == .drum) "LOAD A PAD SAMPLE" else "LOAD AUDIO TO CREATE SLICES", if (kind == .drum) "Choose a WAV file for this drum pad." else "Choose a WAV file before editing slice playback.");
        return;
    }
    widgets.sectionTitle("PLAY REGION", patina.audio);
    drawWaveformRegion(app, target, pad.samples);
    zgui.spacing();

    drawSharedSections(app, target);
}

fn drawPadEmptyState(app: anytype, title: []const u8, explanation: []const u8) void {
    widgets.sectionTitle("PLAY REGION", patina.audio);
    zgui.spacing();
    if (widgets.emptyState(.{
        .id = "sampler-pad-empty-state",
        .title = title,
        .explanation = explanation,
        .shortcut = ":load",
        .action = "LOAD SAMPLE",
        .accent = patina.audio,
    })) openLoadCommand(app);
}

fn openLoadCommand(app: anytype) void {
    const now = std.Io.Timestamp.now(app.core.io, .awake).nanoseconds;
    app.core.handleKey(.{ .char = ':' }, now);
    for ("load") |char| app.core.handleKey(.{ .char = char }, now);
    app.core.handleKey(.enter, now);
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
    const result = widgets.paramKnob(label_text, label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format, .accent = patina.focus, .focused = focused });
    if (result.changed) setPadParam(app, target, id, value);
    if (result.activated) app.core.sampler_param = id;
}

fn drawToggle(app: anytype, target: Target, id: u8, on_label: [:0]const u8, off_label: [:0]const u8, active_color: [4]f32) void {
    const value = target.value(id) orelse return;
    const active = value >= 0.5;
    const focused = app.core.sampler_param == id;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) active_color else if (focused) patina.bg4 else patina.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) patina.bg0 else if (focused) patina.focus else patina.fg2 });
    if (zgui.button(if (active) on_label else off_label, .{ .w = 106, .h = 32 })) {
        app.core.sampler_param = id;
        setPadParam(app, target, id, if (active) 0 else 1);
    }
    zgui.popStyleColor(.{ .count = 2 });
}

// A terminal can only show region bounds as numbers; dragging the trim
// points against the actual waveform shape is GUI-only. Start/end share
// param ids 0/1 across every target the `Target` union covers, so one
// drag implementation serves the standalone sampler and both pad kinds.
fn drawWaveformRegion(app: anytype, target: Target, samples: []const f32) void {
    if (samples.len == 0) {
        zgui.textDisabled("No sample loaded.", .{});
        return;
    }
    const start = target.value(0) orelse 0;
    const end = target.value(1) orelse 1;

    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = std.math.clamp(zgui.getContentRegionAvail()[1] * 0.42, 180, 300);
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("##waveform-region", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = style.color(patina.bg0), .rounding = 3 });

    var overview: [512]f32 = undefined;
    const count = @min(samples.len, overview.len);
    for (overview[0..count], 0..) |*out, i| {
        const s = i * samples.len / count;
        const e = @max(s + 1, (i + 1) * samples.len / count);
        var peak: f32 = 0;
        for (samples[s..@min(e, samples.len)]) |v| peak = @max(peak, @abs(v));
        out.* = peak;
    }
    const mid_y = origin[1] + height / 2;
    const start_x = origin[0] + start * width;
    const end_x = origin[0] + end * width;
    for (overview[0..count], 0..) |peak, i| {
        const x = origin[0] + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        const h = @max(1, peak * height / 2 * 0.94);
        const in_region = x >= start_x - 0.5 and x <= end_x + 0.5;
        const line_color = if (in_region) patina.audio else [4]f32{ patina.fg3[0], patina.fg3[1], patina.fg3[2], 0.55 };
        draw_list.addLine(.{ .p1 = .{ x, mid_y - h }, .p2 = .{ x, mid_y + h }, .col = style.color(line_color), .thickness = 1 });
    }
    draw_list.addLine(.{ .p1 = .{ origin[0], mid_y }, .p2 = .{ origin[0] + width, mid_y }, .col = style.color(patina.line), .thickness = 1 });

    if (start > 0) draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ start_x, origin[1] + height }, .col = style.color(.{ patina.bg0[0], patina.bg0[1], patina.bg0[2], 0.6 }) });
    if (end < 1) draw_list.addRectFilled(.{ .pmin = .{ end_x, origin[1] }, .pmax = .{ origin[0] + width, origin[1] + height }, .col = style.color(.{ patina.bg0[0], patina.bg0[1], patina.bg0[2], 0.6 }) });

    drawRegionHandle(draw_list, start_x, origin[1], height, patina.focus, app.waveform_drag == .start);
    drawRegionHandle(draw_list, end_x, origin[1], height, patina.rhythm, app.waveform_drag == .end);

    const near_handle = hovered and (@abs(mouse[0] - start_x) <= 8 or @abs(mouse[0] - end_x) <= 8);
    if (hovered and zgui.isMouseClicked(.left) and near_handle) {
        app.waveform_drag = if (@abs(mouse[0] - start_x) <= @abs(mouse[0] - end_x)) .start else .end;
    }
    if (app.waveform_drag) |handle| {
        if (zgui.isMouseDown(.left)) {
            const norm = std.math.clamp((mouse[0] - origin[0]) / width, 0, 1);
            const id: u8 = if (handle == .start) 0 else 1;
            _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = target.track(), .id = target.engineId(id), .value = norm } });
            app.core.sampler_param = id;
            app.core.dirty = true;
        } else {
            app.waveform_drag = null;
        }
    } else if (near_handle) {
        zgui.setMouseCursor(.resize_ew);
    }

    zgui.textDisabled("drag markers to trim   region {d:.1}-{d:.1}% of {d} samples", .{ start * 100, end * 100, samples.len });
}

fn drawRegionHandle(draw_list: zgui.DrawList, x: f32, top: f32, height: f32, accent: [4]f32, active: bool) void {
    const line_color = if (active) accent else [4]f32{ accent[0], accent[1], accent[2], 0.7 };
    draw_list.addLine(.{ .p1 = .{ x, top }, .p2 = .{ x, top + height }, .col = style.color(line_color), .thickness = if (active) 2 else 1.5 });
    draw_list.addTriangleFilled(.{ .p1 = .{ x - 5, top }, .p2 = .{ x + 5, top }, .p3 = .{ x, top + 8 }, .col = style.color(line_color) });
}
