const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const sampler_ed = @import("../../ui/editors/sampler.zig");
const waveform = @import("../../ui/waveform.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const theme = &style.palette;

/// Which waveform-overlay handle a drag is currently moving - region
/// start/end trim or a fade-in/out width. Lives on the GUI App so it
/// survives across frames while the mouse button is held.
pub const RegionHandle = enum { start, end, fade_in, fade_out };

pub fn draw(app: anytype) void {
    switch (app.core.sampler_target) {
        .sampler => drawStandalone(app),
        .drum => |track| drawPadTarget(app, track, .drum),
        .slice => |track| drawPadTarget(app, track, .slice),
    }
}

const PadTargetKind = enum { drum, slice };

/// The two editable targets this view can point at. Both expose the shared
/// dsp/pad.zig param ids 0-12; they differ in where a value is read from and
/// which engine param id a slider write maps to.
const Target = union(enum) {
    standalone: struct { sampler: *ws.dsp.Sampler, track: u16 },
    pad: struct { pad: *ws.dsp.Pad, track: u16, kind: PadTargetKind, index: u8, sample_rate: u32 },

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

    fn sampleRate(self: Target) u32 {
        return switch (self) {
            .standalone => |t| t.sampler.sample_rate,
            .pad => |t| t.sample_rate,
        };
    }

    fn engineId(self: Target, id: u8) u16 {
        return switch (self) {
            .standalone => id,
            .pad => |t| if (t.kind == .drum) ws.dsp.DrumMachine.paramId(t.index, id) else ws.dsp.Slicer.paramId(t.index, id),
        };
    }
};

fn drawSharedSections(app: anytype, target: Target) void {
    const available = zgui.getContentRegionAvail()[0];
    const gap: f32 = 10;
    // ~270px per section column, same per-column budget the old 3-at-820
    // breakpoint gave before FADE became the fourth section.
    const columns: usize = if (available >= 1080) sampler_ed.pad_sections.len else 1;
    const column_width = (available - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    for (sampler_ed.pad_sections, 0..) |section, index| {
        if (index > 0 and columns > 1) zgui.sameLine(.{ .spacing = gap });
        var child_buf: [32]u8 = undefined;
        const child_id = std.fmt.bufPrintZ(&child_buf, "sampler-module-{d}", .{index}) catch continue;
        if (zgui.beginChild(child_id, .{ .w = if (columns > 1 and index + 1 < columns) column_width else 0, .h = 205, .child_flags = .{ .border = true } })) {
            const section_color = switch (section.kind) {
                .envelope => theme.rhythm,
                .output => theme.audio,
                else => theme.focus,
            };
            widgets.sectionTitle(section.title, section_color);
            if (section.kind == .envelope) {
                drawAmpEnvelope(app, target);
            } else {
                for (section.rows) |row| {
                    if (row.id == 9)
                        drawToggle(app, target, row.id, "REVERSE", "FORWARD", if (target == .pad) theme.modulation else theme.focus)
                    else
                        drawParam(app, target, row.id, row.label, if (row.id == 8) widgets.pan_cfmt else row.gui_format);
                }
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
        .accent = theme.rhythm,
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
    widgets.sectionTitle("SAMPLE WAVEFORM", theme.audio);
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
            .accent = theme.audio,
        })) widgets.openLoadCommand(app);
        return;
    }
    zgui.spacing();

    drawSharedSections(app, target);
    widgets.sectionTitle(sampler_ed.key_section.title, theme.rhythm);
    drawParam(app, target, sampler_ed.key_section.rows[0].id, sampler_ed.key_section.rows[0].label, sampler_ed.key_section.rows[0].gui_format);
    drawToggle(app, target, sampler_ed.key_section.rows[1].id, "MONO", "POLY", theme.focus);
}

fn drawPadTarget(app: anytype, track: u16, kind: PadTargetKind) void {
    if (track >= app.core.session.racks.items.len) return;
    const index: u8 = if (kind == .drum) @intCast(app.core.drum_cursor[0]) else app.core.slicer_cursor[0];
    drawPadHeader(app, track, kind, index);
    zgui.spacing();
    const pad: *ws.dsp.Pad, const sample_rate: u32 = switch (kind) {
        .drum => blk: {
            const drum = switch (app.core.session.racks.items[track].instrument) {
                .drum_machine => |*d| d,
                else => return,
            };
            if (index >= drum.pads.len or drum.pads[index] == null) {
                drawPadEmptyState(app, "LOAD A PAD SAMPLE", "Choose a WAV file for this drum pad.");
                return;
            }
            break :blk .{ &drum.pads[index].?.pad, drum.sample_rate };
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
            break :blk .{ &slicer.slices[index], slicer.sample_rate };
        },
    };

    const target: Target = .{ .pad = .{ .pad = pad, .track = track, .kind = kind, .index = index, .sample_rate = sample_rate } };
    if (pad.samples.len == 0) {
        drawPadEmptyState(app, if (kind == .drum) "LOAD A PAD SAMPLE" else "LOAD AUDIO TO CREATE SLICES", if (kind == .drum) "Choose a WAV file for this drum pad." else "Choose a WAV file before editing slice playback.");
        return;
    }
    widgets.sectionTitle("PLAY REGION", theme.audio);
    drawWaveformRegion(app, target, pad.samples);
    zgui.spacing();

    drawSharedSections(app, target);
}

fn drawPadEmptyState(app: anytype, title: []const u8, explanation: []const u8) void {
    widgets.sectionTitle("PLAY REGION", theme.audio);
    zgui.spacing();
    if (widgets.emptyState(.{
        .id = "sampler-pad-empty-state",
        .title = title,
        .explanation = explanation,
        .shortcut = ":load",
        .action = "LOAD SAMPLE",
        .accent = theme.audio,
    })) widgets.openLoadCommand(app);
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
            zgui.textColored(theme.rhythm, "\"{s}\"", .{drum.padName(index)});
        },
        .slice => {
            const slicer = &app.core.session.racks.items[track].instrument.slicer;
            zgui.textDisabled("slice {d}/{d}", .{ index + 1, slicer.slice_count });
            zgui.sameLine(.{});
            zgui.textColored(theme.audio, "\"{s}\"", .{slicer.clipName()});
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
    zgui.textColored(theme.focus, "\"{s}\"", .{sampler.clipName()});
}

// Slider bounds come from the dsp-side spec table so they can never drift
// from what setParamAbsolute actually clamps to. Pad ids 0-12 are the same
// params the standalone sampler routes to dsp/pad.zig, so one table covers
// both targets; root note (13) is the only continuous id outside it.
fn paramRange(id: u8) [2]f32 {
    if (ws.dsp.Sampler.findAutomatableParam(id)) |param| return param.range;
    if (id == 13) return .{ 0, 127 };
    return .{ 0, 1 };
}

fn drawParam(app: anytype, target: Target, id: u8, label_text: []const u8, format: [:0]const u8) void {
    var value = target.value(id) orelse return;
    const range = paramRange(id);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##sampler-target-{d}", .{ label_text, id }) catch return;
    const focused = app.core.sampler_param == id;
    const result = widgets.paramKnob(label_text, label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format, .accent = theme.focus, .focused = focused });
    if (result.changed) setPadParam(app, target, id, value);
    if (result.activated) app.core.sampler_param = id;
}

fn drawToggle(app: anytype, target: Target, id: u8, on_label: [:0]const u8, off_label: [:0]const u8, active_color: [4]f32) void {
    const value = target.value(id) orelse return;
    const active = value >= 0.5;
    const focused = app.core.sampler_param == id;
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) active_color else if (focused) theme.bg4 else theme.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) theme.bg0 else if (focused) theme.focus else theme.fg2 });
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
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = style.color(theme.bg0), .rounding = 3 });

    var overview: [512]f32 = undefined;
    const count = @min(samples.len, overview.len);
    waveform.peakBuckets(samples, overview[0..count]);
    const mid_y = origin[1] + height / 2;
    const start_x = origin[0] + start * width;
    const end_x = origin[0] + end * width;
    for (overview[0..count], 0..) |peak, i| {
        const x = origin[0] + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        const h = @max(1, peak * height / 2 * 0.94);
        const in_region = x >= start_x - 0.5 and x <= end_x + 0.5;
        const line_color = if (in_region) theme.audio else [4]f32{ theme.fg3[0], theme.fg3[1], theme.fg3[2], 0.55 };
        draw_list.addLine(.{ .p1 = .{ x, mid_y - h }, .p2 = .{ x, mid_y + h }, .col = style.color(line_color), .thickness = 1 });
    }
    draw_list.addLine(.{ .p1 = .{ origin[0], mid_y }, .p2 = .{ origin[0] + width, mid_y }, .col = style.color(theme.line), .thickness = 1 });

    if (start > 0) draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ start_x, origin[1] + height }, .col = style.color(.{ theme.bg0[0], theme.bg0[1], theme.bg0[2], 0.6 }) });
    if (end < 1) draw_list.addRectFilled(.{ .pmin = .{ end_x, origin[1] }, .pmax = .{ origin[0] + width, origin[1] + height }, .col = style.color(.{ theme.bg0[0], theme.bg0[1], theme.bg0[2], 0.6 }) });

    // Fade wedges: shade the region between each region edge and the
    // gain-ramp's full-level point, tapering to a point on the center line -
    // the same silent-corner/full-tip shape DAWs draw for a clip fade.
    // fade_in_s/fade_out_s are seconds so they're converted to a fraction
    // of the whole clip via `sample_rate`, same units renderVoice uses.
    const region_frac = @max(0.0, end - start);
    const sample_rate = target.sampleRate();
    const total_f: f32 = @floatFromInt(samples.len);
    var fade_in_x = start_x;
    var fade_out_x = end_x;
    if (sample_rate > 0 and total_f > 0) {
        const fade_in_s = target.value(10) orelse 0;
        const fade_out_s = target.value(11) orelse 0;
        const sr_f: f32 = @floatFromInt(sample_rate);
        const fade_in_frac = std.math.clamp(fade_in_s * sr_f / total_f, 0, region_frac);
        const fade_out_frac = std.math.clamp(fade_out_s * sr_f / total_f, 0, region_frac);
        fade_in_x = origin[0] + (start + fade_in_frac) * width;
        fade_out_x = origin[0] + (end - fade_out_frac) * width;
        drawFadeWedge(draw_list, start_x, fade_in_x, origin[1], mid_y, height, theme.focus, app.waveform_drag == .fade_in);
        drawFadeWedge(draw_list, end_x, fade_out_x, origin[1], mid_y, height, theme.focus, app.waveform_drag == .fade_out);
    }

    drawRegionHandle(draw_list, start_x, origin[1], height, theme.focus, app.waveform_drag == .start);
    drawRegionHandle(draw_list, end_x, origin[1], height, theme.rhythm, app.waveform_drag == .end);

    const near_fade_in = hovered and sample_rate > 0 and @abs(mouse[0] - fade_in_x) <= 8 and @abs(mouse[1] - mid_y) <= 10;
    const near_fade_out = hovered and sample_rate > 0 and @abs(mouse[0] - fade_out_x) <= 8 and @abs(mouse[1] - mid_y) <= 10;
    const near_trim = hovered and (@abs(mouse[0] - start_x) <= 8 or @abs(mouse[0] - end_x) <= 8);
    const near_handle = near_trim or near_fade_in or near_fade_out;
    if (hovered and zgui.isMouseClicked(.left) and near_handle) {
        app.waveform_drag = if (near_fade_in and (!near_fade_out or @abs(mouse[0] - fade_in_x) <= @abs(mouse[0] - fade_out_x)))
            .fade_in
        else if (near_fade_out)
            .fade_out
        else if (@abs(mouse[0] - start_x) <= @abs(mouse[0] - end_x))
            .start
        else
            .end;
    }
    if (app.waveform_drag) |handle| {
        if (zgui.isMouseDown(.left)) {
            const norm = std.math.clamp((mouse[0] - origin[0]) / width, 0, 1);
            switch (handle) {
                .start, .end => {
                    const id: u8 = if (handle == .start) 0 else 1;
                    _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = target.track(), .id = target.engineId(id), .value = norm } });
                    app.core.sampler_param = id;
                },
                .fade_in, .fade_out => if (sample_rate > 0 and total_f > 0) {
                    const sr_f: f32 = @floatFromInt(sample_rate);
                    const pos = std.math.clamp(norm, start, end);
                    const frac = if (handle == .fade_in) pos - start else end - pos;
                    const id: u8 = if (handle == .fade_in) 10 else 11;
                    const seconds = @max(0.0, frac) * total_f / sr_f;
                    _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = target.track(), .id = target.engineId(id), .value = seconds } });
                    app.core.sampler_param = id;
                },
            }
            app.core.dirty = true;
        } else {
            app.waveform_drag = null;
        }
    } else if (near_handle) {
        zgui.setMouseCursor(.resize_ew);
    }

    zgui.textDisabled("drag markers to trim, fade dots to shape fades   region {d:.1}-{d:.1}% of {d} samples", .{ start * 100, end * 100, samples.len });
}

fn drawRegionHandle(draw_list: zgui.DrawList, x: f32, top: f32, height: f32, accent: [4]f32, active: bool) void {
    const line_color = if (active) accent else [4]f32{ accent[0], accent[1], accent[2], 0.7 };
    draw_list.addLine(.{ .p1 = .{ x, top }, .p2 = .{ x, top + height }, .col = style.color(line_color), .thickness = if (active) 2 else 1.5 });
    draw_list.addTriangleFilled(.{ .p1 = .{ x - 5, top }, .p2 = .{ x + 5, top }, .p3 = .{ x, top + 8 }, .col = style.color(line_color) });
}

/// Shade the attenuated wedge between a region edge (`corner_x`, full
/// height) and the fade's full-level point (`tip_x`, on the center line),
/// then mark the tip with a draggable dot. `corner_x == tip_x` (fade
/// duration 0) degenerates to a thin sliver, which reads fine.
fn drawFadeWedge(draw_list: zgui.DrawList, corner_x: f32, tip_x: f32, top: f32, mid_y: f32, height: f32, accent: [4]f32, active: bool) void {
    const bottom = top + height;
    const fill = [4]f32{ accent[0], accent[1], accent[2], if (active) 0.30 else 0.18 };
    draw_list.addTriangleFilled(.{ .p1 = .{ corner_x, top }, .p2 = .{ tip_x, mid_y }, .p3 = .{ corner_x, bottom }, .col = style.color(fill) });
    const line_color = if (active) accent else [4]f32{ accent[0], accent[1], accent[2], 0.85 };
    draw_list.addLine(.{ .p1 = .{ corner_x, top }, .p2 = .{ tip_x, mid_y }, .col = style.color(line_color), .thickness = if (active) 2 else 1.5 });
    draw_list.addLine(.{ .p1 = .{ corner_x, bottom }, .p2 = .{ tip_x, mid_y }, .col = style.color(line_color), .thickness = if (active) 2 else 1.5 });
    draw_list.addCircleFilled(.{ .p = .{ tip_x, mid_y }, .r = if (active) 5 else 4, .col = style.color(line_color) });
}
