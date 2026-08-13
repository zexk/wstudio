const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const format = @import("../ui/format.zig");
const icons = @import("../ui/icons.zig");
const gui_style = @import("style.zig");
const scroll = @import("scroll.zig");

pub fn focusRing(draw_list: zgui.DrawList, center: [2]f32, radius: f32, accent: [4]f32) void {
    draw_list.addCircle(.{ .p = center, .r = radius + 3, .col = gui_style.color(accent), .thickness = 1.5 });
}

pub fn focusRect(draw_list: zgui.DrawList, pmin: [2]f32, pmax: [2]f32, rounding: f32, accent: [4]f32) void {
    draw_list.addRect(.{ .pmin = pmin, .pmax = pmax, .col = gui_style.color(accent), .rounding = rounding, .thickness = 2 });
}

pub fn accentMark(draw_list: zgui.DrawList, pmin: [2]f32, pmax: [2]f32, accent: [4]f32) void {
    draw_list.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = gui_style.color(accent), .rounding = gui_style.item_rounding });
}

/// A square button carrying a single glyph. The square is the point: ImGui
/// sizes a button to its label's advance width, and these labels come from
/// two fonts with unrelated metrics - the merged Nerd Font icons (see
/// `ui/icons.zig`) and DejaVu's arrows/math symbols - so left to itself the
/// transport row rendered as four buttons of four different widths, and no
/// two toolbars anywhere lined up. Pinning the width to one em box and
/// centring the glyph in it (`button_text_align`, which ImGui otherwise
/// leaves left-aligned) makes any mix of the two fonts read as one strip of
/// controls. `frame_padding.y = 0` keeps the height `smallButton` had.
pub fn iconButton(label: [:0]const u8, tooltip: []const u8) bool {
    const pad_x = zgui.getStyle().frame_padding[0];
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ pad_x, 0 } });
    zgui.pushStyleVar2f(.{ .idx = .button_text_align, .v = .{ 0.5, 0.5 } });
    const clicked = zgui.button(label, .{ .w = zgui.getFontSize() + pad_x * 2, .h = 0 });
    zgui.popStyleVar(.{ .count = 2 });
    if (zgui.isItemHovered(.{})) {
        zgui.setMouseCursor(.hand);
        _ = zgui.beginTooltip();
        zgui.textUnformatted(tooltip);
        zgui.endTooltip();
    }
    return clicked;
}

pub fn viewTitle(comptime fmt: []const u8, args: anytype) void {
    gui_style.pushFont(.display);
    zgui.textDisabled(fmt, args);
    gui_style.popFont();
}

pub fn coloredTitle(col: [4]f32, comptime fmt: []const u8, args: anytype) void {
    gui_style.pushFont(.display);
    zgui.textColored(col, fmt, args);
    gui_style.popFont();
}

/// Compact replacement for persistent shortcut prose. Meaning stays
/// available to mouse users while keyboard users already have status/help.
pub fn hoverHelp(tooltip: []const u8) void {
    zgui.textDisabled(icons.help, .{});
    if (!zgui.isItemHovered(.{})) return;
    zgui.setMouseCursor(.hand);
    _ = zgui.beginTooltip();
    zgui.textUnformatted(tooltip);
    zgui.endTooltip();
}

/// A section header used inside a bordered/tinted card column: a small
/// accent chip (matching the header overview panels' accent bars) plus the
/// label, then a separator and a bit of breathing room before the params.
pub fn sectionTitle(label: []const u8, accent: [4]f32) void {
    _ = sectionTitleGate(label, accent, null);
}

/// The whole section's on/off switch, parked at the right edge of its
/// header strip.
pub const SectionGate = struct {
    id: [:0]const u8,
    on: bool,
    focused: bool = false,
};

/// `sectionTitle` with the section's own on/off switch in the header, the
/// way a hardware panel gates a module from its label strip. As a param row
/// it costs a full line and reads as just another value; up here it reads as
/// what it is - whether the card below does anything. Returns true when the
/// switch was clicked.
pub fn sectionTitleGate(label: []const u8, accent: [4]f32, gate: ?SectionGate) bool {
    const theme = &gui_style.palette;
    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const start_x = zgui.getCursorPos()[0];
    const avail = zgui.getContentRegionAvail()[0];
    draw_list.addRectFilled(.{ .pmin = .{ pos[0], pos[1] + 1 }, .pmax = .{ pos[0] + 3, pos[1] + 15 }, .col = gui_style.color(accent), .rounding = gui_style.item_rounding });
    zgui.indent(.{ .indent_w = 10 });
    gui_style.pushFont(.heading);
    zgui.textColored(accent, "{s}", .{label});
    gui_style.popFont();
    zgui.unindent(.{ .indent_w = 10 });

    var clicked = false;
    if (gate) |g| {
        scroll.noteFocusRow(g.focused, pos[1], zgui.getFontSize() + 8);
        const text: [:0]const u8 = if (g.on) "ON" else "OFF";
        const pill_w = zgui.calcTextSize(text, .{})[0] + 16;
        zgui.sameLine(.{ .spacing = 0 });
        zgui.setCursorPosX(start_x + @max(0, avail - pill_w));
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (g.on) accent else if (g.focused) theme.bg4 else theme.bg3 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (g.on) theme.bg0 else if (g.focused) accent else theme.fg2 });
        var buf: [64]u8 = undefined;
        const btn = std.fmt.bufPrintZ(&buf, "{s}##{s}", .{ text, g.id }) catch text;
        clicked = zgui.smallButton(btn);
        zgui.popStyleColor(.{ .count = 2 });
    }

    zgui.dummy(.{ .w = 0, .h = 1 });
    zgui.separator();
    zgui.dummy(.{ .w = 0, .h = 5 });
    return clicked;
}

/// A pill switch plus its label, laid out as a single row - the drop-in
/// replacement for a labelled `zgui.checkbox`, matching the hand-drawn
/// knob/pad/ADSR look instead of ImGui's default square box. `label`
/// doubles as both the widget id and the displayed text, same convention
/// `zgui.checkbox` itself used at every call site this replaces.
pub fn toggle(label: [:0]const u8, v: *bool) bool {
    const theme = &gui_style.palette;
    const track_w: f32 = 30;
    const track_h: f32 = 16;
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();

    zgui.beginGroup();
    _ = zgui.invisibleButton(label, .{ .w = track_w, .h = track_h });
    const hovered = zgui.isItemHovered(.{});
    if (hovered) zgui.setMouseCursor(.hand);
    var changed = false;
    if (zgui.isItemActivated()) {
        v.* = !v.*;
        changed = true;
    }
    const on = v.*;

    const track_col = if (on) theme.modulation else if (hovered) theme.bg5 else theme.bg4;
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + track_w, origin[1] + track_h }, .col = gui_style.color(track_col), .rounding = track_h * 0.5 });
    const knob_r = track_h * 0.5 - 2;
    const knob_center = [2]f32{
        origin[0] + (if (on) track_w - track_h * 0.5 else track_h * 0.5),
        origin[1] + track_h * 0.5,
    };
    draw_list.addCircleFilled(.{ .p = knob_center, .r = knob_r, .col = gui_style.color(theme.fg0) });

    zgui.sameLine(.{ .spacing = 8 });
    zgui.textColored(if (on) theme.fg0 else theme.fg1, "{s}", .{label});
    zgui.endGroup();
    return changed;
}

pub const EmptyState = struct {
    id: [:0]const u8,
    title: []const u8,
    explanation: []const u8,
    shortcut: []const u8,
    action: [:0]const u8,
    accent: [4]f32,
    width: f32 = 520,
};

/// Shared actionable empty state used by editors with missing source data.
/// The caller owns the action so command routing stays in the view.
pub fn emptyState(args: EmptyState) bool {
    const theme = &gui_style.palette;
    const available = zgui.getContentRegionAvail()[0];
    const width = @min(available, args.width);
    if (available > width) zgui.setCursorPosX(zgui.getCursorPos()[0] + (available - width) * 0.5);
    var clicked = false;
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = theme.bg2 });
    if (zgui.beginChild(args.id, .{ .w = width, .h = 122, .child_flags = .{ .border = true } })) {
        gui_style.pushFont(.heading);
        zgui.textColored(args.accent, "{s}", .{args.title});
        gui_style.popFont();
        zgui.separator();
        gui_style.pushFont(.caption);
        zgui.textDisabled("{s}", .{args.explanation});
        gui_style.popFont();
        zgui.spacing();
        zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.focus_soft });
        clicked = zgui.button(args.action, .{ .h = 32 });
        zgui.popStyleColor(.{});
        zgui.sameLine(.{ .spacing = 12 });
        zgui.textDisabled("{s}", .{args.shortcut});
    }
    zgui.endChild();
    zgui.popStyleColor(.{});
    return clicked;
}

/// Synthesizes a `:load<Enter>` keystroke sequence - the click handler for
/// an `emptyState`'s "LOAD ..." button on sampler/slicer/soundfont's empty
/// states, which all route into the same context-aware `:load` command
/// (see ui/app.zig's `BrowserPurpose`) rather than each view opening the
/// browser directly.
pub fn openLoadCommand(app: anytype) void {
    const now = std.Io.Timestamp.now(app.core.io, .awake).nanoseconds;
    app.core.handleKey(.{ .char = ':' }, now);
    for ("load") |char| app.core.handleKey(.{ .char = char }, now);
    app.core.handleKey(.enter, now);
}

/// A rotary control: drag vertically to change the value, double-click to
/// type an exact one, or scroll while hovered to nudge it a fixed step
/// (**Mod**+scroll = a secondary value when supplied, otherwise a coarser
/// step) - the same convention the TUI's param rows use. Angle sweep and
/// drag mapping follow the usual three-quarter-turn knob convention
/// (135deg through the top to 405deg).
pub const Knob = struct {
    v: *f32,
    /// Secondary value changed by Mod+scroll instead of the dial value.
    modifier_v: ?*f32 = null,
    min: f32,
    max: f32,
    cfmt: [:0]const u8 = "%.3f",
    /// Preformatted readout for params whose display is richer than printf.
    display: ?[]const u8 = null,
    accent: [4]f32,
    focused: bool = false,
    logarithmic: bool = false,
    /// Power curve for ranges containing zero, where a true logarithm is
    /// undefined. Values above 1 reserve more travel for the low end.
    skew: f32 = 1,
    diameter: f32 = 30,
    /// Hover readout. Off for `knobCell`, whose own label line already
    /// swaps to the value on hover - two readouts for one dial is one too
    /// many.
    tooltip: bool = true,
};

pub const KnobResult = struct {
    changed: bool = false,
    modifier_changed: bool = false,
    /// Mirrors `zgui.isItemActivated()` for the drag surface - callers
    /// building a UI cursor from clicks should check this instead, since
    /// `paramKnob` draws label/value text after the dial and would shift
    /// "last item" queries onto the wrong widget.
    activated: bool = false,
    /// Pointer is on the dial or dragging it. Same reasoning as
    /// `activated`: the caller cannot ask `isItemHovered` after the fact,
    /// because the dial is not the last item by then.
    hot: bool = false,
};

const knob_angle_min: f32 = std.math.pi * 0.75;
const knob_angle_max: f32 = std.math.pi * 2.25;

fn knobValueToT(min: f32, max: f32, value: f32, logarithmic: bool, skew: f32) f32 {
    if (logarithmic and min > 0 and max > 0) {
        return std.math.clamp(@log(value / min) / @log(max / min), 0, 1);
    }
    const linear = std.math.clamp((value - min) / (max - min), 0, 1);
    return if (skew > 0 and skew != 1) std.math.pow(f32, linear, 1.0 / skew) else linear;
}

fn knobTToValue(min: f32, max: f32, t: f32, logarithmic: bool, skew: f32) f32 {
    if (logarithmic and min > 0 and max > 0) return min * std.math.pow(f32, max / min, t);
    const shaped = if (skew > 0 and skew != 1) std.math.pow(f32, t, skew) else t;
    return min + (max - min) * shaped;
}

/// Splits a printf-style `"%.Nf<suffix>"` format (as used by the slider
/// widgets this replaces) into a precision and trailing unit text.
/// Strips the leading '-' when a negative value rounds to zero at `digits`
/// decimal places, so e.g. -0.3 formatted with "%.0f" reads "0" not "-0".
fn stripNegativeZero(s: []const u8, digits: u2) []const u8 {
    if (s.len < 2 or s[0] != '-' or s[1] != '0') return s;
    var idx: usize = 2;
    if (digits > 0) {
        if (idx >= s.len or s[idx] != '.') return s;
        idx += 1;
        if (idx + digits > s.len) return s;
        for (s[idx .. idx + digits]) |c| {
            if (c != '0') return s;
        }
    }
    return s[1..];
}

fn knobFormatValue(buf: []u8, cfmt: [:0]const u8, value: f32) []const u8 {
    if (std.mem.eql(u8, cfmt, format.pan_cfmt)) return format.panLabel(buf, value);
    if (std.mem.eql(u8, cfmt, format.filter_cfmt)) return format.filterLabel(buf, value);
    if (std.mem.eql(u8, cfmt, format.note_cfmt)) return format.noteLabel(buf, value);
    const at = std.mem.indexOf(u8, cfmt, "%.") orelse {
        const s = std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch return "";
        return stripNegativeZero(s, 2);
    };
    const digit_pos = at + 2;
    if (digit_pos >= cfmt.len) return "";
    const f_pos = std.mem.indexOfScalarPos(u8, cfmt, digit_pos, 'f') orelse return "";
    const suffix = cfmt[f_pos + 1 ..];
    const digits: u2 = switch (cfmt[digit_pos]) {
        '0' => 0,
        '1' => 1,
        '2' => 2,
        else => 3,
    };
    const s = (switch (digits) {
        0 => std.fmt.bufPrint(buf, "{d:.0}{s}", .{ value, suffix }),
        1 => std.fmt.bufPrint(buf, "{d:.1}{s}", .{ value, suffix }),
        2 => std.fmt.bufPrint(buf, "{d:.2}{s}", .{ value, suffix }),
        else => std.fmt.bufPrint(buf, "{d:.3}{s}", .{ value, suffix }),
    }) catch return "";
    return stripNegativeZero(s, digits);
}

/// Draws the dial only (no label/value text). `label` doubles as the
/// widget id, same convention as `zgui.sliderFloat`.
pub fn knob(label: [:0]const u8, args: Knob) KnobResult {
    const theme = &gui_style.palette;
    const radius = args.diameter * 0.5;
    const cursor = zgui.getCursorScreenPos();
    const center = [2]f32{ cursor[0] + radius, cursor[1] + radius };
    const draw_list = zgui.getWindowDrawList();

    _ = zgui.invisibleButton(label, .{ .w = args.diameter, .h = args.diameter });
    // Covers the dial plus the label/value line under it in `knobCell`.
    scroll.noteFocusRow(args.focused, cursor[1], args.diameter + zgui.getFontSize() + 6);
    const active = zgui.isItemActive();
    const hovered = zgui.isItemHovered(.{});
    if (hovered or active) zgui.setMouseCursor(.resize_ns);
    const activated = zgui.isItemActivated();
    var changed = false;

    if (active) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        if (delta[1] != 0) {
            const t0 = knobValueToT(args.min, args.max, args.v.*, args.logarithmic, args.skew);
            const t1 = std.math.clamp(t0 - delta[1] / gui_style.knob_drag_pixels, 0, 1);
            const next = knobTToValue(args.min, args.max, t1, args.logarithmic, args.skew);
            if (next != args.v.*) {
                args.v.* = next;
                changed = true;
            }
            zgui.resetMouseDragDelta(.left);
        }
    }
    var modifier_changed = false;
    if (hovered and gui_style.wheel_delta != 0) {
        gui_style.wheel_consumed = true;
        if (gui_style.modDown() and args.modifier_v != null) {
            const v = args.modifier_v.?;
            const next = std.math.clamp(v.* + gui_style.wheel_delta * 0.05, -1, 1);
            if (next != v.*) {
                v.* = next;
                modifier_changed = true;
            }
        } else {
            const step: f32 = if (gui_style.modDown()) 0.05 else 0.005;
            const t0 = knobValueToT(args.min, args.max, args.v.*, args.logarithmic, args.skew);
            const t1 = std.math.clamp(t0 + gui_style.wheel_delta * step, 0, 1);
            const next = knobTToValue(args.min, args.max, t1, args.logarithmic, args.skew);
            if (next != args.v.*) {
                args.v.* = next;
                changed = true;
            }
        }
    }

    var popup_buf: [80]u8 = undefined;
    const popup_id = std.fmt.bufPrintZ(&popup_buf, "{s}-entry", .{label}) catch label;
    if (hovered and zgui.isMouseDoubleClicked(.left)) zgui.openPopup(popup_id, .{});
    if (zgui.beginPopup(popup_id, .{})) {
        var edit = args.v.*;
        zgui.setNextItemWidth(90);
        zgui.setKeyboardFocusHere(0);
        const sentinel_cfmt = std.mem.eql(u8, args.cfmt, format.pan_cfmt) or
            std.mem.eql(u8, args.cfmt, format.filter_cfmt);
        const edit_cfmt: [:0]const u8 = if (sentinel_cfmt) "%.2f" else args.cfmt;
        _ = zgui.inputFloat("##value", .{ .v = &edit, .cfmt = edit_cfmt });
        if (zgui.isItemDeactivatedAfterEdit()) {
            const next = std.math.clamp(edit, args.min, args.max);
            if (next != args.v.*) {
                args.v.* = next;
                changed = true;
            }
            zgui.closeCurrentPopup();
        }
        zgui.endPopup();
    }

    const t = knobValueToT(args.min, args.max, args.v.*, args.logarithmic, args.skew);
    const angle = knob_angle_min + (knob_angle_max - knob_angle_min) * t;

    draw_list.pathArcTo(.{ .p = center, .r = radius, .amin = knob_angle_min, .amax = knob_angle_max });
    draw_list.pathStroke(.{ .col = gui_style.color(theme.bg4), .thickness = 3 });
    if (t > 0.001) {
        draw_list.pathArcTo(.{ .p = center, .r = radius, .amin = knob_angle_min, .amax = angle });
        draw_list.pathStroke(.{ .col = gui_style.color(args.accent), .thickness = 3 });
    }
    draw_list.addCircleFilled(.{ .p = center, .r = radius - 5, .col = gui_style.color(if (active or hovered) theme.bg4 else theme.bg3) });
    if (args.focused) focusRing(draw_list, center, radius, args.accent);

    const dir = [2]f32{ @cos(angle), @sin(angle) };
    draw_list.addLine(.{
        .p1 = .{ center[0] + dir[0] * radius * 0.25, center[1] + dir[1] * radius * 0.25 },
        .p2 = .{ center[0] + dir[0] * (radius - 6), center[1] + dir[1] * (radius - 6) },
        .col = gui_style.color(theme.fg0),
        .thickness = 2,
    });

    if (args.tooltip and (hovered or active)) {
        var value_buf: [32]u8 = undefined;
        _ = zgui.beginTooltip();
        zgui.textUnformatted(args.display orelse knobFormatValue(&value_buf, args.cfmt, args.v.*));
        if (args.modifier_v) |v| zgui.textDisabled("Mod+scroll: curve {d:.2}", .{v.*});
        zgui.endTooltip();
    }

    return .{ .changed = changed, .modifier_changed = modifier_changed, .activated = activated, .hot = hovered or active };
}

/// A knob plus its label and live value, laid out as a single row - the
/// drop-in replacement for a labelled `zgui.sliderFloat` call.
pub fn paramKnob(label_text: []const u8, id: [:0]const u8, args: Knob) KnobResult {
    const theme = &gui_style.palette;
    const result = knob(id, args);
    zgui.sameLine(.{ .spacing = 8 });
    zgui.beginGroup();
    zgui.textColored(if (args.focused) args.accent else theme.fg1, "{s}", .{label_text});
    var value_buf: [32]u8 = undefined;
    zgui.textDisabled("{s}", .{args.display orelse knobFormatValue(&value_buf, args.cfmt, args.v.*)});
    zgui.endGroup();
    return result;
}

/// Width of one `knobCell`, scaled off the current font so a large
/// `gui_font_size` widens the grid instead of overlapping it.
pub fn knobCellW() f32 {
    return @max(68, zgui.getFontSize() * 5.2);
}

/// Fits `text` inside `max_w` by dropping trailing characters - cell labels
/// are already short, this only guards a font big enough to overflow one.
fn fitText(text: []const u8, max_w: f32) []const u8 {
    var end = text.len;
    while (end > 1 and zgui.calcTextSize(text[0..end], .{})[0] > max_w) : (end -= 1) {}
    return text[0..end];
}

fn cellText(text: []const u8, col: [4]f32, cell_w: f32) void {
    const fitted = fitText(text, cell_w);
    const text_w = zgui.calcTextSize(fitted, .{})[0];
    const x = zgui.getCursorPos()[0];
    zgui.setCursorPosX(x + @max(0, (cell_w - text_w) * 0.5));
    zgui.textColored(col, "{s}", .{fitted});
}

/// A knob as a fixed-width grid cell: dial, one line of text under it.
/// `paramKnob`'s row form (dial left, name+value stacked right) costs a
/// full text line of height per param and can only ever be one param wide,
/// which turned a 12-param oscillator into a 12-row column; every hardware
/// panel and soft-synth instead flows these cells left to right and wraps,
/// so a section reads as a block of controls rather than a list.
///
/// That one line is the param's *name*, and swaps to its value while the
/// dial is hovered, dragged, or under the keyboard cursor - the convention
/// Serum, Vital and the rest use. A permanent second line of numbers reads
/// as noise on a panel of 12 knobs, and the value is never actually lost:
/// the status bar prints the focused param's value with units at all times.
/// `value_text` is passed in (not derived from `cfmt`) so it is that exact
/// same string.
pub fn knobCell(label_text: []const u8, id: [:0]const u8, value_text: []const u8, args: Knob) KnobResult {
    const theme = &gui_style.palette;
    const cell_w = knobCellW();
    zgui.beginGroup();
    const x = zgui.getCursorPos()[0];
    zgui.setCursorPosX(x + @max(0, (cell_w - args.diameter) * 0.5));
    var dial = args;
    dial.tooltip = false;
    const result = knob(id, dial);
    const show_value = result.hot or args.focused;
    var curve_buf: [24]u8 = undefined;
    const shown = if (result.hot and gui_style.modDown() and args.modifier_v != null)
        std.fmt.bufPrint(&curve_buf, "curve {d:.2}", .{args.modifier_v.?.*}) catch value_text
    else
        value_text;
    cellText(
        if (show_value) shown else label_text,
        if (show_value) args.accent else theme.fg1,
        cell_w,
    );
    // Pins the group's width to the cell grid: without it the group is only
    // as wide as its widest line, and a row of cells would creep left of
    // where the caller's flow math expects the next one.
    zgui.dummy(.{ .w = cell_w, .h = 0 });
    zgui.endGroup();
    return result;
}

/// A list-valued param as a grid cell, so enums sit in the same knob grid
/// instead of forcing a full-width `name  -  value  +` row that breaks it
/// (Serum packs its OCT/SEM/FIN/CRS boxes right into the knob block for the
/// same reason). The value box steps on a click - left half down, right
/// half up - or on a scroll while hovered. Returns -1/0/+1 rather than
/// writing a value, since a stepped param's steps belong to the owner (for
/// the synth editor they route through the same `h`/`l` command path a
/// keypress uses, undo included).
pub fn stepperCell(label_text: []const u8, id: [:0]const u8, display: []const u8, accent: [4]f32, focused: bool, width: f32) i8 {
    const theme = &gui_style.palette;
    const cell_w = if (width > 0) width else knobCellW();
    const box_h = zgui.getFontSize() + 8;
    const draw_list = zgui.getWindowDrawList();

    zgui.beginGroup();
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton(id, .{ .w = cell_w, .h = box_h });
    scroll.noteFocusRow(focused, origin[1], box_h + zgui.getFontSize() + 6);
    const hovered = zgui.isItemHovered(.{});
    if (hovered) zgui.setMouseCursor(.hand);
    var delta: i8 = 0;
    if (zgui.isItemActivated()) {
        delta = if (zgui.getMousePos()[0] < origin[0] + cell_w * 0.5) -1 else 1;
    }
    if (hovered and gui_style.wheel_delta != 0) {
        gui_style.wheel_consumed = true;
        delta = if (gui_style.wheel_delta > 0) 1 else -1;
    }

    const box_col = if (hovered) theme.bg4 else theme.bg3;
    draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + cell_w, origin[1] + box_h },
        .col = gui_style.color(box_col),
        .rounding = gui_style.item_rounding,
    });
    if (focused) draw_list.addRect(.{
        .pmin = origin,
        .pmax = .{ origin[0] + cell_w, origin[1] + box_h },
        .col = gui_style.color(accent),
        .rounding = gui_style.item_rounding,
        .thickness = 1.5,
    });
    const fitted = fitText(display, cell_w - 16);
    const text_w = zgui.calcTextSize(fitted, .{})[0];
    draw_list.addText(
        .{ origin[0] + (cell_w - text_w) * 0.5, origin[1] + 4 },
        gui_style.color(if (focused) accent else theme.fg0),
        "{s}",
        .{fitted},
    );
    if (hovered) {
        const arrow_col = gui_style.color(theme.fg2);
        draw_list.addText(.{ origin[0] + 4, origin[1] + 4 }, arrow_col, "\u{2039}", .{});
        draw_list.addText(.{ origin[0] + cell_w - 11, origin[1] + 4 }, arrow_col, "\u{203A}", .{});
    }
    // An empty label is a cell with no caption (a matrix row, where the
    // column position already says which field this is), not a blank line
    // under the box - and with no caption the box itself already pins the
    // group width, so the spacer that does that job is skipped too.
    if (label_text.len > 0) {
        cellText(label_text, if (focused) accent else theme.fg1, cell_w);
        zgui.dummy(.{ .w = cell_w, .h = 0 });
    }
    zgui.endGroup();
    return delta;
}

/// A param whose values name discrete list entries (a track, a pad, a
/// mode) rather than measuring a continuum - a knob's drag-to-scrub and
/// filled-arc both imply "more/less of a quantity", which misreads for
/// "which one of these". Prev/next buttons plus the resolved name (not the
/// raw number a knob would show) read as picking an item instead. Scrolling
/// while hovered also steps it, one entry per tick - unlike the knob, there's
/// no Mod-coarse variant, since "10 items at once" isn't a meaningful step
/// for a short discrete list.
pub const ListStepper = struct {
    v: *f32,
    min: f32,
    max: f32,
    display: []const u8,
    accent: [4]f32,
    focused: bool = false,
};

/// One of the stepper's two nudge buttons. Greys out at the end of the range
/// it walks toward, so the pair reads as "there is nothing further this way"
/// rather than silently no-opping. True when the value actually moved.
fn stepButton(id: [:0]const u8, args: ListStepper, delta: f32) bool {
    var buf: [48]u8 = undefined;
    const suffix = if (delta < 0) "prev" else "next";
    const glyph = if (delta < 0) "-" else "+";
    const btn_id = std.fmt.bufPrintZ(&buf, "{s}##{s}-{s}", .{ glyph, id, suffix }) catch
        if (delta < 0) "-##prev" else "+##next";
    const at_end = if (delta < 0) args.v.* <= args.min else args.v.* >= args.max;
    zgui.beginDisabled(.{ .disabled = at_end });
    defer zgui.endDisabled();
    if (!zgui.smallButton(btn_id)) return false;
    const next = std.math.clamp(args.v.* + delta, args.min, args.max);
    if (next == args.v.*) return false;
    args.v.* = next;
    return true;
}

pub fn listStepper(label_text: []const u8, id: [:0]const u8, args: ListStepper) KnobResult {
    const theme = &gui_style.palette;
    var changed = false;
    const row_origin = zgui.getCursorScreenPos();
    scroll.noteFocusRow(args.focused, row_origin[1], zgui.getFontSize() * 2 + 12);
    zgui.beginGroup();
    zgui.textColored(if (args.focused) args.accent else theme.fg1, "{s}", .{label_text});
    changed = stepButton(id, args, -1) or changed;
    zgui.sameLine(.{ .spacing = 6 });
    zgui.textColored(if (args.focused) theme.fg0 else theme.fg2, "{s}", .{args.display});
    zgui.sameLine(.{ .spacing = 6 });
    changed = stepButton(id, args, 1) or changed;
    zgui.endGroup();
    // isItemHovered doesn't chain through EndGroup (a well-known ImGui
    // limitation - it only tests the last individual item inside), but
    // EndGroup does compute a correct bounding box, so hit-test that
    // manually instead of trusting isItemHovered here.
    const row_max = zgui.getItemRectMax();
    const mouse = zgui.getMousePos();
    const row_hovered = mouse[0] >= row_origin[0] and mouse[0] < row_max[0] and mouse[1] >= row_origin[1] and mouse[1] < row_max[1];
    if (row_hovered and gui_style.wheel_delta != 0) {
        gui_style.wheel_consumed = true;
        const next = std.math.clamp(args.v.* + (if (gui_style.wheel_delta > 0) @as(f32, 1) else -1), args.min, args.max);
        if (next != args.v.*) {
            args.v.* = next;
            changed = true;
        }
    }
    return .{ .changed = changed, .activated = changed };
}

/// An attack/decay/sustain/release envelope shape you edit by dragging its
/// own nodes, one per parameter. Duration nodes move horizontally; sustain
/// moves vertically. Segment widths use
/// sqrt(duration) so a 5s release doesn't swallow a 5ms attack on screen;
/// this is a visual compromise only, not a to-scale time axis.
pub const Adsr = struct {
    attack: *f32,
    decay: *f32,
    sustain: *f32,
    release: *f32,
    attack_range: [2]f32,
    decay_range: [2]f32,
    release_range: [2]f32,
    curves: [3]*f32,
    accent: [4]f32,
    /// 0=attack, 1=decay, 2=sustain, 3=release - which node (if any) the
    /// external cursor is currently parked on, for the focus ring.
    focused_stage: ?u2 = null,
    height: f32 = 90,
};

pub const AdsrResult = struct {
    /// attack, decay, sustain, release
    changed: [4]bool = .{ false, false, false, false },
    curve_changed: [3]bool = .{ false, false, false },
    activated_stage: ?u2 = null,
};

const adsr_sustain_frac: f32 = 0.16;
const adsr_handle_r: f32 = 5;

fn adsrSegFracs(attack: f32, decay: f32, release: f32) [3]f32 {
    const raw = [3]f32{ @sqrt(@max(attack, 0.001)), @sqrt(@max(decay, 0.001)), @sqrt(@max(release, 0.001)) };
    const sum = raw[0] + raw[1] + raw[2];
    const avail = 1.0 - adsr_sustain_frac;
    return .{ avail * raw[0] / sum, avail * raw[1] / sum, avail * raw[2] / sum };
}

fn adsrStageIs(stage: ?u2, n: u2) bool {
    return stage != null and stage.? == n;
}

/// Exponent-per-wheel-tick for a duration node's scroll nudge (**Mod** =
/// coarser), matched in spirit to the knob's own Mod-coarse step. Only the
/// duration nodes use this.
fn envelopeScrollStep() f32 {
    return if (gui_style.modDown()) 0.2 else 0.05;
}

fn adsrHandle(draw_list: zgui.DrawList, theme: *const gui_style.Palette, p: [2]f32, lit: bool, focused: bool, accent: [4]f32) void {
    draw_list.addCircleFilled(.{ .p = p, .r = adsr_handle_r, .col = gui_style.color(if (lit) accent else theme.fg1) });
    if (focused) focusRing(draw_list, p, adsr_handle_r, accent);
}

fn plotGrid(draw_list: zgui.DrawList, origin: [2]f32, width: f32, height: f32, x_divisions: u8, y_divisions: u8) void {
    for (1..x_divisions) |i| {
        const x = origin[0] + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(x_divisions));
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = gui_style.color(gui_style.palette.line) });
    }
    for (1..y_divisions) |i| {
        const y = origin[1] + height * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(y_divisions));
        draw_list.addLine(.{ .p1 = .{ origin[0], y }, .p2 = .{ origin[0] + width, y }, .col = gui_style.color(gui_style.palette.line) });
    }
}

/// One ADSR node: an invisible square hit box over the curve point, plus the
/// drag and wheel handling behind it. A duration node (`range` non-null)
/// rides the horizontal axis multiplicatively - its range spans decades, so
/// an additive drag would be unusable at the short end. The sustain node
/// (`range` null) is a plain vertical 0..1 level.
fn adsrNode(
    draw_list: zgui.DrawList,
    theme: *const gui_style.Palette,
    label: [:0]const u8,
    suffix: []const u8,
    p: [2]f32,
    stage: u2,
    args: Adsr,
    value: *f32,
    range: ?[2]f32,
    result: *AdsrResult,
) void {
    zgui.setCursorScreenPos(.{ p[0] - adsr_handle_r, p[1] - adsr_handle_r });
    var id_buf: [96]u8 = undefined;
    const nid = std.fmt.bufPrintZ(&id_buf, "{s}-{s}", .{ label, suffix }) catch label;
    _ = zgui.invisibleButton(nid, .{ .w = adsr_handle_r * 2, .h = adsr_handle_r * 2 });
    const node_active = zgui.isItemActive();
    const node_hovered = zgui.isItemHovered(.{});
    if (node_active or node_hovered) zgui.setMouseCursor(if (range == null) .resize_ns else .resize_ew);
    if (zgui.isItemActivated()) result.activated_stage = stage;
    if (node_active) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        const d = if (range == null) delta[1] else delta[0];
        if (d != 0) {
            value.* = if (range) |r|
                std.math.clamp(value.* * @exp(d / gui_style.envelope_drag_pixels), r[0], r[1])
            else
                std.math.clamp(value.* - d / gui_style.envelope_drag_pixels, 0, 1);
            result.changed[stage] = true;
            zgui.resetMouseDragDelta(.left);
        }
    }
    if (node_hovered and gui_style.wheel_delta != 0) {
        gui_style.wheel_consumed = true;
        if (gui_style.modDown() and range != null) {
            const curve_index: usize = if (stage == 3) 2 else stage;
            args.curves[curve_index].* = std.math.clamp(args.curves[curve_index].* + gui_style.wheel_delta * 0.05, -1, 1);
            result.curve_changed[curve_index] = true;
        } else {
            value.* = if (range) |r|
                std.math.clamp(value.* * @exp(gui_style.wheel_delta * envelopeScrollStep()), r[0], r[1])
            else
                std.math.clamp(value.* + gui_style.wheel_delta * 0.01, 0, 1);
            result.changed[stage] = true;
        }
    }
    adsrHandle(draw_list, theme, p, node_active or node_hovered, adsrStageIs(args.focused_stage, stage), args.accent);
}

pub fn adsrEditor(label: [:0]const u8, args: Adsr) AdsrResult {
    const theme = &gui_style.palette;
    const width = zgui.getContentRegionAvail()[0];
    const height = args.height;
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    scroll.noteFocusRow(args.focused_stage != null, origin[1], height);
    zgui.dummy(.{ .w = width, .h = height });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = gui_style.color(theme.bg1), .rounding = gui_style.panel_rounding });
    plotGrid(draw_list, origin, width, height, 4, 4);

    const fracs = adsrSegFracs(args.attack.*, args.decay.*, args.release.*);
    const xs = [_]f32{
        0,
        fracs[0],
        fracs[0] + fracs[1],
        fracs[0] + fracs[1] + adsr_sustain_frac,
        fracs[0] + fracs[1] + adsr_sustain_frac + fracs[2],
    };
    const sustain_t = std.math.clamp(args.sustain.*, 0, 1);
    const pad: f32 = 10;
    const inner_h = height - pad * 2;
    const at = struct {
        fn f(o: [2]f32, w: f32, h: f32, p2: f32, x: f32, y: f32) [2]f32 {
            return .{ o[0] + x * w, o[1] + p2 + (1.0 - y) * h };
        }
    }.f;
    const points = [_][2]f32{
        at(origin, width, inner_h, pad, xs[0], 0),
        at(origin, width, inner_h, pad, xs[1], 1),
        at(origin, width, inner_h, pad, xs[2], sustain_t),
        at(origin, width, inner_h, pad, xs[3], sustain_t),
        at(origin, width, inner_h, pad, xs[4], 0),
    };

    draw_list.pathClear();
    draw_list.pathLineTo(.{ points[0][0], origin[1] + height - pad });
    draw_list.pathLineTo(points[0]);
    inline for (0..4) |segment| {
        const steps = if (segment == 2) 1 else 16;
        for (1..steps + 1) |step| {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            const shaped = if (segment == 2) t else ws.dsp.synth_math.bendShape(t, args.curves[if (segment == 3) 2 else segment].*);
            draw_list.pathLineTo(.{
                points[segment][0] + (points[segment + 1][0] - points[segment][0]) * t,
                points[segment][1] + (points[segment + 1][1] - points[segment][1]) * shaped,
            });
        }
    }
    draw_list.pathLineTo(.{ points[4][0], origin[1] + height - pad });
    draw_list.pathFillConvex(gui_style.color(.{ args.accent[0], args.accent[1], args.accent[2], 0.18 }));
    inline for (0..4) |segment| {
        const steps = if (segment == 2) 1 else 16;
        var prev = points[segment];
        for (1..steps + 1) |step| {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            const shaped = if (segment == 2) t else ws.dsp.synth_math.bendShape(t, args.curves[if (segment == 3) 2 else segment].*);
            const next = [2]f32{
                points[segment][0] + (points[segment + 1][0] - points[segment][0]) * t,
                points[segment][1] + (points[segment + 1][1] - points[segment][1]) * shaped,
            };
            draw_list.addLine(.{ .p1 = prev, .p2 = next, .col = gui_style.color(args.accent), .thickness = 2 });
            prev = next;
        }
    }

    var result = AdsrResult{};

    // Duration nodes drag horizontally and scale exponentially; sustain is a
    // plain vertical 0..1 level - see `adsrNode`.
    adsrNode(draw_list, theme, label, "a", points[1], 0, args, args.attack, args.attack_range, &result);
    adsrNode(draw_list, theme, label, "d", points[2], 1, args, args.decay, args.decay_range, &result);
    adsrNode(draw_list, theme, label, "s", points[3], 2, args, args.sustain, null, &result);
    adsrNode(draw_list, theme, label, "r", points[4], 3, args, args.release, args.release_range, &result);

    zgui.setCursorScreenPos(.{ origin[0], origin[1] + height });
    return result;
}

/// A multi-point breakpoint curve, `adsrEditor`'s more elastic cousin: any
/// number of points instead of 3 fixed-role ones, both axes draggable
/// instead of duration-only, and points can be created and removed instead
/// of just repositioned. Scrolling while hovering an existing point nudges
/// just its value (**Mod** = coarser) and leaves its beat position alone -
/// unlike a drag, a wheel tick is unambiguous here since only one of the
/// two axes is a natural "nudge a little" quantity. Used by the automation
/// view today; the point/range args carry nothing automation-specific, so
/// an LFO shape editor can reuse it later.
///
/// Allocation-free like every other widget here: point count changes
/// (insert/remove) go through the caller's own storage (e.g.
/// `dsp/automation.zig`'s `setPoint`/`removePoint`), this just reports what
/// the user asked for. A dragged point's beat is clamped between its
/// immediate neighbors (never crosses them) specifically so its index into
/// `args.points` stays stable for the whole drag - `moved` addresses the
/// point by that index, not by beat, so the caller can mutate it in place
/// with no search.
pub const CurvePoint = ws.dsp.automation.AutomationPoint;

pub const Curve = struct {
    points: []const CurvePoint,
    /// Visible beat span, `[0, beat_hi]` - clips are always clip-relative
    /// from beat 0, so there's no separate lower bound to carry.
    beat_hi: f64,
    value_lo: f32,
    value_hi: f32,
    /// Grid line spacing and drag/insert snap increment, in beats. 0
    /// disables both the grid and snapping.
    snap_beats: f64 = 0.25,
    /// Display-only subdivisions. Independent from snapping so editors can
    /// preview a useful grid before quantized editing exists.
    grid_divisions: u8 = 0,
    fill: bool = false,
    accent: [4]f32,
    /// Which point (if any) the external cursor is currently parked on,
    /// for the focus ring - mirrors `Adsr.focused_stage`.
    focused_index: ?usize = null,
    /// Unit name for the hover tooltip's x-axis reading (e.g. "0.40
    /// beats"). Override for a non-timeline x-axis - the LFO shape editor
    /// passes "phase" since its x-axis is a 0..1 cycle fraction, not a
    /// musical beat position.
    x_unit_label: []const u8 = "beats",
    /// Continuous per-point segment bends (parallel to `points`), for
    /// callers whose curve isn't automation's three-way `Curve` enum - the
    /// LFO shape editor passes `LfoShapePoint.curve`. When set, it replaces
    /// each point's enum shape for drawing.
    bends: ?[]const f32 = null,
    /// Defaults to the rest of the content region, like every other widget
    /// here - override to inset the plot within a caller's own chrome
    /// (axis labels, ruler, ...) instead of owning the full width.
    width: ?f32 = null,
    height: f32 = 220,
};

pub const CurveResult = struct {
    /// An existing point was dragged - apply as `points[index] = .{beat,
    /// value}` (safe in place: see the neighbor-clamp note above).
    moved: ?struct { index: usize, beat: f64, value: f32 } = null,
    /// A click on empty plot area - insert a new point here.
    inserted: ?struct { beat: f64, value: f32 } = null,
    /// A double-click on an existing point - remove whatever sits at this
    /// exact beat.
    removed: ?f64 = null,
    activated_index: ?usize = null,
};

fn curveToScreen(origin: [2]f32, w: f32, h: f32, beat_hi: f64, vlo: f32, vhi: f32, beat: f64, value: f32) [2]f32 {
    const tx: f32 = if (beat_hi > 0) @floatCast(std.math.clamp(beat / beat_hi, 0, 1)) else 0;
    const vspan = vhi - vlo;
    const ty: f32 = if (vspan != 0) std.math.clamp((value - vlo) / vspan, 0, 1) else 0;
    return .{ origin[0] + tx * w, origin[1] + (1.0 - ty) * h };
}

fn snappedCurveBeat(raw: f64, fallback: f64, lo: f64, hi: f64, snap: f64) f64 {
    if (lo > hi) return fallback;
    var beat = std.math.clamp(raw, lo, hi);
    if (snap > 0) beat = @round(beat / snap) * snap;
    return std.math.clamp(beat, lo, hi);
}

fn curveGridStep(beat_hi: f64, snap: f64, width: f32) f64 {
    const max_lines = @max(1, @as(u32, @intFromFloat(@floor(@max(width, 1) / 4))));
    return snap * @max(1, @ceil(beat_hi / snap / @as(f64, @floatFromInt(max_lines))));
}

/// One segment between two points, shaped by the point it leaves. A plain
/// straight line here would draw a hold or an ease as a ramp - a picture of
/// a curve the engine is not playing.
fn drawCurveSegment(draw_list: anytype, a: [2]f32, b: [2]f32, shape: ws.dsp.automation.Curve, col: u32) void {
    switch (shape) {
        .linear => draw_list.addLine(.{ .p1 = a, .p2 = b, .col = col, .thickness = 2 }),
        .hold => {
            const corner = [2]f32{ b[0], a[1] };
            draw_list.addLine(.{ .p1 = a, .p2 = corner, .col = col, .thickness = 2 });
            draw_list.addLine(.{ .p1 = corner, .p2 = b, .col = col, .thickness = 2 });
        },
        // Enough chords that the S reads as a curve at any plot width a
        // clip lane gets; the value axis follows smoothstep, matching
        // `automation.interpolate`, while x stays even.
        .ease => {
            const chords = 16;
            var from = a;
            for (1..chords + 1) |i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, chords);
                const eased = t * t * (3.0 - 2.0 * t);
                const to = [2]f32{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * eased };
                draw_list.addLine(.{ .p1 = from, .p2 = to, .col = col, .thickness = 2 });
                from = to;
            }
        },
    }
}

/// `drawCurveSegment`'s counterpart for a continuous bend (see
/// `Curve.bends`), chorded the same way `.ease` is so the two look alike.
fn drawBentSegment(draw_list: anytype, a: [2]f32, b: [2]f32, bend: f32, col: u32, fill_col: ?u32, bottom: f32) void {
    if (fill_col) |fill| {
        const pixels: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(b[0] - a[0])))));
        for (0..pixels + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pixels));
            const shaped = if (bend == 0) t else ws.dsp.synth.bendShape(t, bend);
            const p = [2]f32{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * shaped };
            draw_list.addLine(.{ .p1 = p, .p2 = .{ p[0], bottom }, .col = fill, .thickness = 1.1 });
        }
    }
    const chords = 16;
    var from = a;
    for (1..chords + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, chords);
        const shaped = if (bend == 0) t else ws.dsp.synth.bendShape(t, bend);
        const to = [2]f32{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * shaped };
        draw_list.addLine(.{ .p1 = from, .p2 = to, .col = col, .thickness = 2 });
        from = to;
    }
}

pub fn curveEditor(label: [:0]const u8, args: Curve) CurveResult {
    const theme = &gui_style.palette;
    const width = args.width orelse zgui.getContentRegionAvail()[0];
    const height = args.height;
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    var result = CurveResult{};
    scroll.noteFocusRow(args.focused_index != null, origin[1], height);

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = gui_style.color(theme.bg1), .rounding = gui_style.panel_rounding });
    if (args.grid_divisions > 1) plotGrid(draw_list, origin, width, height, args.grid_divisions, args.grid_divisions);
    if (args.snap_beats > 0 and args.beat_hi > 0) {
        const grid_step = curveGridStep(args.beat_hi, args.snap_beats, width);
        var b: f64 = 0;
        while (b <= args.beat_hi) : (b += grid_step) {
            const x = origin[0] + @as(f32, @floatCast(b / args.beat_hi)) * width;
            draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = gui_style.color(theme.line), .thickness = 1 });
        }
    }

    // Background hit-region first so the per-node buttons below (submitted
    // later) can still be interacted with despite overlapping it - a click
    // that lands outside every node's small circle falls through to this
    // and inserts a new point there. allowOverlap is required: imgui's
    // default is the opposite (an earlier, larger item blocks hover to
    // anything under it), so without this the nodes would never see clicks.
    zgui.setCursorScreenPos(origin);
    zgui.setNextItemAllowOverlap();
    _ = zgui.invisibleButton(label, .{ .w = width, .h = height });
    const bg_activated = zgui.isItemActivated();
    const bg_mouse = zgui.getMousePos();

    if (args.points.len > 0) {
        const first = curveToScreen(origin, width, height, args.beat_hi, args.value_lo, args.value_hi, 0, args.points[0].value);
        const fill_col: ?u32 = if (args.fill) gui_style.color(.{
            theme.bg1[0] * 0.82 + args.accent[0] * 0.18,
            theme.bg1[1] * 0.82 + args.accent[1] * 0.18,
            theme.bg1[2] * 0.82 + args.accent[2] * 0.18,
            1,
        }) else null;
        draw_list.addLine(.{ .p1 = .{ origin[0], first[1] }, .p2 = first, .col = gui_style.color(args.accent), .thickness = 2 });
        var prev = first;
        // The lead-in above is flat, so the shape of the run into the first
        // point never matters; from there on a segment is shaped by the
        // point it leaves.
        var prev_shape: ws.dsp.automation.Curve = .linear;
        var prev_bend: f32 = 0;
        for (args.points, 0..) |p, i| {
            const cur = curveToScreen(origin, width, height, args.beat_hi, args.value_lo, args.value_hi, p.beat, p.value);
            if (args.bends) |bends| {
                drawBentSegment(draw_list, prev, cur, prev_bend, gui_style.color(args.accent), fill_col, origin[1] + height);
                prev_bend = if (i < bends.len) bends[i] else 0;
            } else {
                drawCurveSegment(draw_list, prev, cur, prev_shape, gui_style.color(args.accent));
                prev_shape = p.curve;
            }
            prev = cur;
        }
        const last = args.points[args.points.len - 1];
        const last_screen = curveToScreen(origin, width, height, args.beat_hi, args.value_lo, args.value_hi, last.beat, last.value);
        draw_list.addLine(.{ .p1 = last_screen, .p2 = .{ origin[0] + width, last_screen[1] }, .col = gui_style.color(args.accent), .thickness = 2 });
    }

    const handle_r: f32 = 6;
    for (args.points, 0..) |p, i| {
        const center = curveToScreen(origin, width, height, args.beat_hi, args.value_lo, args.value_hi, p.beat, p.value);
        zgui.setCursorScreenPos(.{ center[0] - handle_r, center[1] - handle_r });
        var id_buf: [96]u8 = undefined;
        const nid = std.fmt.bufPrintZ(&id_buf, "{s}-{d}", .{ label, i }) catch label;
        _ = zgui.invisibleButton(nid, .{ .w = handle_r * 2, .h = handle_r * 2 });
        const node_active = zgui.isItemActive();
        const node_hovered = zgui.isItemHovered(.{});
        if (node_active or node_hovered) zgui.setMouseCursor(.resize_all);
        if (zgui.isItemActivated()) result.activated_index = i;
        if (node_hovered and zgui.isMouseDoubleClicked(.left)) result.removed = p.beat;
        if (node_active and result.removed == null) {
            const mouse = zgui.getMousePos();
            const lo_beat: f64 = if (i == 0) 0 else args.points[i - 1].beat + args.snap_beats;
            const hi_beat: f64 = if (i + 1 == args.points.len) args.beat_hi else args.points[i + 1].beat - args.snap_beats;
            const raw_beat: f64 = if (args.beat_hi > 0) @as(f64, (mouse[0] - origin[0]) / width) * args.beat_hi else p.beat;
            const new_beat = snappedCurveBeat(raw_beat, p.beat, lo_beat, hi_beat, args.snap_beats);
            const norm = 1.0 - std.math.clamp((mouse[1] - origin[1]) / height, 0, 1);
            const new_value = args.value_lo + norm * (args.value_hi - args.value_lo);
            if (new_beat != p.beat or new_value != p.value) result.moved = .{ .index = i, .beat = new_beat, .value = new_value };
        }
        if (node_hovered and result.moved == null and gui_style.wheel_delta != 0) {
            gui_style.wheel_consumed = true;
            const step_frac: f32 = if (gui_style.modDown()) 0.05 else 0.005;
            const step: f32 = step_frac * (args.value_hi - args.value_lo);
            const new_value = std.math.clamp(p.value + gui_style.wheel_delta * step, args.value_lo, args.value_hi);
            if (new_value != p.value) result.moved = .{ .index = i, .beat = p.beat, .value = new_value };
        }
        if (node_active or node_hovered) {
            var buf: [32]u8 = undefined;
            _ = zgui.beginTooltip();
            zgui.text("{d:.2} {s}  /  {s}", .{ p.beat, args.x_unit_label, knobFormatValue(&buf, "%.2f", p.value) });
            zgui.endTooltip();
        }
        draw_list.addCircleFilled(.{ .p = center, .r = handle_r - 1, .col = gui_style.color(if (node_active or node_hovered) args.accent else theme.fg1) });
        if (args.focused_index != null and args.focused_index.? == i) focusRing(draw_list, center, handle_r, args.accent);
    }

    if (bg_activated and result.moved == null and result.removed == null and result.activated_index == null) {
        const raw_beat: f64 = if (args.beat_hi > 0) @as(f64, (bg_mouse[0] - origin[0]) / width) * args.beat_hi else 0;
        const beat = snappedCurveBeat(raw_beat, 0, 0, args.beat_hi, args.snap_beats);
        const norm = 1.0 - std.math.clamp((bg_mouse[1] - origin[1]) / height, 0, 1);
        const value = args.value_lo + norm * (args.value_hi - args.value_lo);
        result.inserted = .{ .beat = beat, .value = value };
    }

    draw_list.addRect(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = gui_style.color(theme.bg4), .rounding = gui_style.panel_rounding, .thickness = 1 });
    zgui.setCursorScreenPos(.{ origin[0], origin[1] + height });
    return result;
}

test "curve beat snapping preserves ordering and bounds" {
    try std.testing.expectEqual(@as(f64, 0.5), snappedCurveBeat(0.9, 0.5, 0.65, 0.25, 0.25));
    try std.testing.expectEqual(@as(f64, 1.2), snappedCurveBeat(1.2, 0.0, 0.0, 1.2, 0.7));
    try std.testing.expectEqual(@as(f64, 0.3), snappedCurveBeat(0.26, 0.0, 0.3, 0.8, 0.25));
}

test "curve grid bounds work while preserving snap intervals" {
    try std.testing.expectEqual(@as(f64, 0.25), curveGridStep(16, 0.25, 800));
    try std.testing.expectEqual(@as(f64, 4000), curveGridStep(1_000_000, 0.25, 1000));
}

test "knob mappings preserve values while expanding useful low ranges" {
    const testing = std.testing;
    const log_mid = knobTToValue(0.001, 10, 0.5, true, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.1), log_mid, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), knobValueToT(0.001, 10, log_mid, true, 1), 1e-6);

    const skew_mid = knobTToValue(0, 10, 0.5, false, 3);
    try testing.expectApproxEqAbs(@as(f32, 1.25), skew_mid, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), knobValueToT(0, 10, skew_mid, false, 3), 1e-6);
    try testing.expectEqual(@as(f32, 0), knobTToValue(0, 10, 0, false, 3));
}
