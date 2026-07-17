const std = @import("std");
const zgui = @import("zgui");
const gui_style = @import("style.zig");

pub fn sectionTitle(label: []const u8, accent: [4]f32) void {
    zgui.textColored(accent, "{s}", .{label});
    zgui.separator();
}

/// A rotary control: drag vertically to change the value, double-click to
/// type an exact one. Angle sweep and drag mapping follow the usual
/// three-quarter-turn knob convention (135deg through the top to 405deg).
pub const Knob = struct {
    v: *f32,
    min: f32,
    max: f32,
    cfmt: [:0]const u8 = "%.3f",
    accent: [4]f32,
    focused: bool = false,
    logarithmic: bool = false,
    diameter: f32 = 30,
};

pub const KnobResult = struct {
    changed: bool = false,
    /// Mirrors `zgui.isItemActivated()` for the drag surface - callers
    /// building a UI cursor from clicks should check this instead, since
    /// `paramKnob` draws label/value text after the dial and would shift
    /// "last item" queries onto the wrong widget.
    activated: bool = false,
};

const knob_angle_min: f32 = std.math.pi * 0.75;
const knob_angle_max: f32 = std.math.pi * 2.25;
const knob_drag_pixels: f32 = 180;

fn knobValueToT(min: f32, max: f32, value: f32, logarithmic: bool) f32 {
    if (logarithmic and min > 0 and max > 0) {
        return std.math.clamp(@log(value / min) / @log(max / min), 0, 1);
    }
    return std.math.clamp((value - min) / (max - min), 0, 1);
}

fn knobTToValue(min: f32, max: f32, t: f32, logarithmic: bool) f32 {
    if (logarithmic and min > 0 and max > 0) return min * std.math.pow(f32, max / min, t);
    return min + (max - min) * t;
}

/// Splits a printf-style `"%.Nf<suffix>"` format (as used by the slider
/// widgets this replaces) into a precision and trailing unit text.
fn knobFormatValue(buf: []u8, cfmt: [:0]const u8, value: f32) []const u8 {
    const at = std.mem.indexOf(u8, cfmt, "%.") orelse return std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "";
    const digit_pos = at + 2;
    if (digit_pos >= cfmt.len) return "";
    const f_pos = std.mem.indexOfScalarPos(u8, cfmt, digit_pos, 'f') orelse return "";
    const suffix = cfmt[f_pos + 1 ..];
    return switch (cfmt[digit_pos]) {
        '0' => std.fmt.bufPrint(buf, "{d:.0}{s}", .{ value, suffix }) catch "",
        '1' => std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, suffix }) catch "",
        '2' => std.fmt.bufPrint(buf, "{d:.2}{s}", .{ value, suffix }) catch "",
        else => std.fmt.bufPrint(buf, "{d:.3}{s}", .{ value, suffix }) catch "",
    };
}

/// Draws the dial only (no label/value text). `label` doubles as the
/// widget id, same convention as `zgui.sliderFloat`.
pub fn knob(label: [:0]const u8, args: Knob) KnobResult {
    const patina = &gui_style.palette;
    const radius = args.diameter * 0.5;
    const cursor = zgui.getCursorScreenPos();
    const center = [2]f32{ cursor[0] + radius, cursor[1] + radius };
    const draw_list = zgui.getWindowDrawList();

    _ = zgui.invisibleButton(label, .{ .w = args.diameter, .h = args.diameter });
    const active = zgui.isItemActive();
    const hovered = zgui.isItemHovered(.{});
    const activated = zgui.isItemActivated();
    var changed = false;

    if (active) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        if (delta[1] != 0) {
            const t0 = knobValueToT(args.min, args.max, args.v.*, args.logarithmic);
            const t1 = std.math.clamp(t0 - delta[1] / knob_drag_pixels, 0, 1);
            args.v.* = knobTToValue(args.min, args.max, t1, args.logarithmic);
            changed = true;
            zgui.resetMouseDragDelta(.left);
        }
    }

    var popup_buf: [80]u8 = undefined;
    const popup_id = std.fmt.bufPrintZ(&popup_buf, "{s}-entry", .{label}) catch label;
    if (hovered and zgui.isMouseDoubleClicked(.left)) zgui.openPopup(popup_id, .{});
    if (zgui.beginPopup(popup_id, .{})) {
        var edit = args.v.*;
        zgui.setNextItemWidth(90);
        zgui.setKeyboardFocusHere(0);
        if (zgui.inputFloat("##value", .{ .v = &edit, .cfmt = args.cfmt, .flags = .{ .enter_returns_true = true } })) {
            args.v.* = std.math.clamp(edit, args.min, args.max);
            changed = true;
            zgui.closeCurrentPopup();
        }
        zgui.endPopup();
    }

    const t = knobValueToT(args.min, args.max, args.v.*, args.logarithmic);
    const angle = knob_angle_min + (knob_angle_max - knob_angle_min) * t;

    draw_list.pathArcTo(.{ .p = center, .r = radius, .amin = knob_angle_min, .amax = knob_angle_max });
    draw_list.pathStroke(.{ .col = gui_style.color(patina.bg4), .thickness = 3 });
    if (t > 0.001) {
        draw_list.pathArcTo(.{ .p = center, .r = radius, .amin = knob_angle_min, .amax = angle });
        draw_list.pathStroke(.{ .col = gui_style.color(args.accent), .thickness = 3 });
    }
    draw_list.addCircleFilled(.{ .p = center, .r = radius - 5, .col = gui_style.color(if (active or hovered) patina.bg4 else patina.bg3) });
    if (args.focused) draw_list.addCircle(.{ .p = center, .r = radius + 2, .col = gui_style.color(args.accent), .thickness = 1.5 });

    const dir = [2]f32{ @cos(angle), @sin(angle) };
    draw_list.addLine(.{
        .p1 = .{ center[0] + dir[0] * radius * 0.25, center[1] + dir[1] * radius * 0.25 },
        .p2 = .{ center[0] + dir[0] * (radius - 6), center[1] + dir[1] * (radius - 6) },
        .col = gui_style.color(patina.fg0),
        .thickness = 2,
    });

    if (hovered or active) {
        var value_buf: [32]u8 = undefined;
        _ = zgui.beginTooltip();
        zgui.textUnformatted(knobFormatValue(&value_buf, args.cfmt, args.v.*));
        zgui.endTooltip();
    }

    return .{ .changed = changed, .activated = activated };
}

/// A knob plus its label and live value, laid out as a single row - the
/// drop-in replacement for a labelled `zgui.sliderFloat` call.
pub fn paramKnob(label_text: []const u8, id: [:0]const u8, args: Knob) KnobResult {
    const patina = &gui_style.palette;
    const result = knob(id, args);
    zgui.sameLine(.{ .spacing = 8 });
    zgui.beginGroup();
    zgui.textColored(if (args.focused) args.accent else patina.fg1, "{s}", .{label_text});
    var value_buf: [32]u8 = undefined;
    zgui.textDisabled("{s}", .{knobFormatValue(&value_buf, args.cfmt, args.v.*)});
    zgui.endGroup();
    return result;
}

pub fn waveform(label: [:0]const u8, samples: []const f32) void {
    if (samples.len == 0) {
        zgui.textDisabled("No sample loaded.", .{});
        return;
    }
    var overview: [1024]f32 = undefined;
    const count = @min(samples.len, overview.len);
    for (overview[0..count], 0..) |*out, i| {
        const start = i * samples.len / count;
        const end = @max(start + 1, (i + 1) * samples.len / count);
        var peak: f32 = 0;
        for (samples[start..@min(end, samples.len)]) |sample| if (@abs(sample) > @abs(peak)) {
            peak = sample;
        };
        out.* = peak;
    }
    if (zgui.plot.beginPlot(label, .{ .h = 150, .flags = .canvas_only })) {
        zgui.plot.setupAxis(.x1, .{ .flags = .no_decorations });
        zgui.plot.setupAxis(.y1, .{ .flags = .no_decorations });
        zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = @floatFromInt(count), .cond = .always });
        zgui.plot.setupAxisLimits(.y1, .{ .min = -1, .max = 1, .cond = .always });
        zgui.plot.plotLineValues("wave", f32, .{ .v = overview[0..count] });
        zgui.plot.endPlot();
    }
}
