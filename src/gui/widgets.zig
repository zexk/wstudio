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

/// A 2D pad for a correlated pair of params (e.g. filter cutoff+resonance):
/// click/drag anywhere in the square to set both at once from the cursor's
/// absolute position, unlike the knob's relative drag (a position in 2D has
/// no ambiguous "starting angle" the way a 1D rotation does).
pub const XYPad = struct {
    x: *f32,
    y: *f32,
    x_range: [2]f32,
    y_range: [2]f32,
    x_cfmt: [:0]const u8 = "%.2f",
    y_cfmt: [:0]const u8 = "%.2f",
    x_logarithmic: bool = false,
    accent: [4]f32,
    focused: bool = false,
    size: f32 = 96,
};

pub fn xyPad(label: [:0]const u8, args: XYPad) KnobResult {
    const patina = &gui_style.palette;
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();

    _ = zgui.invisibleButton(label, .{ .w = args.size, .h = args.size });
    const active = zgui.isItemActive();
    const hovered = zgui.isItemHovered(.{});
    const activated = zgui.isItemActivated();
    var changed = false;

    if (active) {
        const mouse = zgui.getMousePos();
        const tx = std.math.clamp((mouse[0] - origin[0]) / args.size, 0, 1);
        const ty = std.math.clamp((mouse[1] - origin[1]) / args.size, 0, 1);
        const new_x = knobTToValue(args.x_range[0], args.x_range[1], tx, args.x_logarithmic);
        const new_y = knobTToValue(args.y_range[0], args.y_range[1], 1.0 - ty, false);
        if (new_x != args.x.* or new_y != args.y.*) changed = true;
        args.x.* = new_x;
        args.y.* = new_y;
    }

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + args.size, origin[1] + args.size }, .col = gui_style.color(patina.bg2), .rounding = 3 });
    const mid = args.size * 0.5;
    draw_list.addLine(.{ .p1 = .{ origin[0] + mid, origin[1] }, .p2 = .{ origin[0] + mid, origin[1] + args.size }, .col = gui_style.color(patina.line), .thickness = 1 });
    draw_list.addLine(.{ .p1 = .{ origin[0], origin[1] + mid }, .p2 = .{ origin[0] + args.size, origin[1] + mid }, .col = gui_style.color(patina.line), .thickness = 1 });
    draw_list.addRect(.{ .pmin = origin, .pmax = .{ origin[0] + args.size, origin[1] + args.size }, .col = gui_style.color(if (args.focused) args.accent else patina.bg4), .rounding = 3, .thickness = if (args.focused) 2 else 1 });

    const tx = knobValueToT(args.x_range[0], args.x_range[1], args.x.*, args.x_logarithmic);
    const ty = 1.0 - knobValueToT(args.y_range[0], args.y_range[1], args.y.*, false);
    const dot = [2]f32{ origin[0] + tx * args.size, origin[1] + ty * args.size };
    const crosshair = [4]f32{ args.accent[0], args.accent[1], args.accent[2], 0.35 };
    draw_list.addLine(.{ .p1 = .{ origin[0], dot[1] }, .p2 = .{ origin[0] + args.size, dot[1] }, .col = gui_style.color(crosshair), .thickness = 1 });
    draw_list.addLine(.{ .p1 = .{ dot[0], origin[1] }, .p2 = .{ dot[0], origin[1] + args.size }, .col = gui_style.color(crosshair), .thickness = 1 });
    draw_list.addCircleFilled(.{ .p = dot, .r = 6, .col = gui_style.color(if (active or hovered) args.accent else patina.fg1) });
    if (args.focused) draw_list.addCircle(.{ .p = dot, .r = 9, .col = gui_style.color(args.accent), .thickness = 1.5 });

    if (hovered or active) {
        var x_buf: [32]u8 = undefined;
        var y_buf: [32]u8 = undefined;
        _ = zgui.beginTooltip();
        zgui.text("{s}  /  {s}", .{ knobFormatValue(&x_buf, args.x_cfmt, args.x.*), knobFormatValue(&y_buf, args.y_cfmt, args.y.*) });
        zgui.endTooltip();
    }

    return .{ .changed = changed, .activated = activated };
}

/// An attack/decay/sustain/release envelope shape you edit by dragging its
/// own nodes: the attack peak and release tail each move along one axis
/// (they're durations only), the decay/sustain corner moves on both -
/// dragging it sideways is decay time, up/down is sustain level, the same
/// "one gesture, two correlated params" idea as `xyPad`. Segment widths use
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
    accent: [4]f32,
    /// 0=attack, 1=decay/sustain, 2=release - which node (if any) the
    /// external cursor is currently parked on, for the focus ring.
    focused_stage: ?u2 = null,
    height: f32 = 90,
};

pub const AdsrResult = struct {
    /// attack, decay, sustain, release
    changed: [4]bool = .{ false, false, false, false },
    activated_stage: ?u2 = null,
};

const adsr_sustain_frac: f32 = 0.16;
const adsr_drag_pixels: f32 = 140;
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

fn adsrHandle(draw_list: zgui.DrawList, patina: *const gui_style.Palette, p: [2]f32, lit: bool, focused: bool, accent: [4]f32) void {
    draw_list.addCircleFilled(.{ .p = p, .r = adsr_handle_r, .col = gui_style.color(if (lit) accent else patina.fg1) });
    if (focused) draw_list.addCircle(.{ .p = p, .r = adsr_handle_r + 3, .col = gui_style.color(accent), .thickness = 1.5 });
}

pub fn adsrEditor(label: [:0]const u8, args: Adsr) AdsrResult {
    const patina = &gui_style.palette;
    const width = zgui.getContentRegionAvail()[0];
    const height = args.height;
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    zgui.dummy(.{ .w = width, .h = height });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = gui_style.color(patina.bg2), .rounding = 3 });

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
    for (points) |p| draw_list.pathLineTo(p);
    draw_list.pathLineTo(.{ points[4][0], origin[1] + height - pad });
    draw_list.pathFillConvex(gui_style.color(.{ args.accent[0], args.accent[1], args.accent[2], 0.18 }));
    for (0..points.len - 1) |i| draw_list.addLine(.{ .p1 = points[i], .p2 = points[i + 1], .col = gui_style.color(args.accent), .thickness = 2 });

    var result = AdsrResult{};

    // Attack node: horizontal drag only (duration).
    {
        const p = points[1];
        zgui.setCursorScreenPos(.{ p[0] - adsr_handle_r, p[1] - adsr_handle_r });
        var id_buf: [96]u8 = undefined;
        const nid = std.fmt.bufPrintZ(&id_buf, "{s}-a", .{label}) catch label;
        _ = zgui.invisibleButton(nid, .{ .w = adsr_handle_r * 2, .h = adsr_handle_r * 2 });
        const node_active = zgui.isItemActive();
        const node_hovered = zgui.isItemHovered(.{});
        if (zgui.isItemActivated()) result.activated_stage = 0;
        if (node_active) {
            const delta = zgui.getMouseDragDelta(.left, .{});
            if (delta[0] != 0) {
                args.attack.* = std.math.clamp(args.attack.* * @exp(delta[0] / adsr_drag_pixels), args.attack_range[0], args.attack_range[1]);
                result.changed[0] = true;
                zgui.resetMouseDragDelta(.left);
            }
        }
        adsrHandle(draw_list, patina, p, node_active or node_hovered, adsrStageIs(args.focused_stage, 0), args.accent);
    }

    // Decay/sustain corner: horizontal drag is decay time, vertical is
    // sustain level - one gesture, two params, same idea as `xyPad`.
    {
        const p = points[2];
        zgui.setCursorScreenPos(.{ p[0] - adsr_handle_r, p[1] - adsr_handle_r });
        var id_buf: [96]u8 = undefined;
        const nid = std.fmt.bufPrintZ(&id_buf, "{s}-ds", .{label}) catch label;
        _ = zgui.invisibleButton(nid, .{ .w = adsr_handle_r * 2, .h = adsr_handle_r * 2 });
        const node_active = zgui.isItemActive();
        const node_hovered = zgui.isItemHovered(.{});
        if (zgui.isItemActivated()) result.activated_stage = 1;
        if (node_active) {
            const delta = zgui.getMouseDragDelta(.left, .{});
            if (delta[0] != 0) {
                args.decay.* = std.math.clamp(args.decay.* * @exp(delta[0] / adsr_drag_pixels), args.decay_range[0], args.decay_range[1]);
                result.changed[1] = true;
            }
            if (delta[1] != 0) {
                args.sustain.* = std.math.clamp(args.sustain.* - delta[1] / adsr_drag_pixels, 0, 1);
                result.changed[2] = true;
            }
            if (delta[0] != 0 or delta[1] != 0) zgui.resetMouseDragDelta(.left);
        }
        adsrHandle(draw_list, patina, p, node_active or node_hovered, adsrStageIs(args.focused_stage, 1), args.accent);
    }

    // Release node: horizontal drag only (duration).
    {
        const p = points[4];
        zgui.setCursorScreenPos(.{ p[0] - adsr_handle_r, p[1] - adsr_handle_r });
        var id_buf: [96]u8 = undefined;
        const nid = std.fmt.bufPrintZ(&id_buf, "{s}-r", .{label}) catch label;
        _ = zgui.invisibleButton(nid, .{ .w = adsr_handle_r * 2, .h = adsr_handle_r * 2 });
        const node_active = zgui.isItemActive();
        const node_hovered = zgui.isItemHovered(.{});
        if (zgui.isItemActivated()) result.activated_stage = 2;
        if (node_active) {
            const delta = zgui.getMouseDragDelta(.left, .{});
            if (delta[0] != 0) {
                args.release.* = std.math.clamp(args.release.* * @exp(delta[0] / adsr_drag_pixels), args.release_range[0], args.release_range[1]);
                result.changed[3] = true;
                zgui.resetMouseDragDelta(.left);
            }
        }
        adsrHandle(draw_list, patina, p, node_active or node_hovered, adsrStageIs(args.focused_stage, 2), args.accent);
    }

    zgui.setCursorScreenPos(.{ origin[0], origin[1] + height });
    return result;
}

/// A multi-point breakpoint curve, `adsrEditor`'s more elastic cousin: any
/// number of points instead of 3 fixed-role ones, both axes draggable
/// instead of duration-only, and points can be created and removed instead
/// of just repositioned. Used by the automation view today; the point/range
/// args carry nothing automation-specific, so an LFO shape editor can reuse
/// it later the same way `xyPad` serves both filter cutoff and other
/// correlated pairs.
///
/// Allocation-free like every other widget here: point count changes
/// (insert/remove) go through the caller's own storage (e.g.
/// `dsp/automation.zig`'s `setPoint`/`removePoint`), this just reports what
/// the user asked for. A dragged point's beat is clamped between its
/// immediate neighbors (never crosses them) specifically so its index into
/// `args.points` stays stable for the whole drag - `moved` addresses the
/// point by that index, not by beat, so the caller can mutate it in place
/// with no search.
pub const CurvePoint = struct { beat: f64, value: f32 };

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
    accent: [4]f32,
    /// Which point (if any) the external cursor is currently parked on,
    /// for the focus ring - mirrors `Adsr.focused_stage`.
    focused_index: ?usize = null,
    /// Unit name for the hover tooltip's x-axis reading (e.g. "0.40
    /// beats"). Override for a non-timeline x-axis - the LFO shape editor
    /// passes "phase" since its x-axis is a 0..1 cycle fraction, not a
    /// musical beat position.
    x_unit_label: []const u8 = "beats",
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

pub fn curveEditor(label: [:0]const u8, args: Curve) CurveResult {
    const patina = &gui_style.palette;
    const width = args.width orelse zgui.getContentRegionAvail()[0];
    const height = args.height;
    const origin = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    var result = CurveResult{};

    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = gui_style.color(patina.bg1), .rounding = 3 });
    if (args.snap_beats > 0 and args.beat_hi > 0) {
        var b: f64 = 0;
        while (b <= args.beat_hi) : (b += args.snap_beats) {
            const x = origin[0] + @as(f32, @floatCast(b / args.beat_hi)) * width;
            draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = gui_style.color(patina.line), .thickness = 1 });
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
        draw_list.addLine(.{ .p1 = .{ origin[0], first[1] }, .p2 = first, .col = gui_style.color(args.accent), .thickness = 2 });
        var prev = first;
        for (args.points) |p| {
            const cur = curveToScreen(origin, width, height, args.beat_hi, args.value_lo, args.value_hi, p.beat, p.value);
            draw_list.addLine(.{ .p1 = prev, .p2 = cur, .col = gui_style.color(args.accent), .thickness = 2 });
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
        if (zgui.isItemActivated()) result.activated_index = i;
        if (node_hovered and zgui.isMouseDoubleClicked(.left)) result.removed = p.beat;
        if (node_active and result.removed == null) {
            const mouse = zgui.getMousePos();
            const lo_beat: f64 = if (i == 0) 0 else args.points[i - 1].beat + args.snap_beats;
            const hi_beat: f64 = if (i + 1 == args.points.len) args.beat_hi else args.points[i + 1].beat - args.snap_beats;
            const raw_beat: f64 = if (args.beat_hi > 0) @as(f64, (mouse[0] - origin[0]) / width) * args.beat_hi else p.beat;
            var new_beat = std.math.clamp(raw_beat, @min(lo_beat, hi_beat), @max(lo_beat, hi_beat));
            if (args.snap_beats > 0) new_beat = @round(new_beat / args.snap_beats) * args.snap_beats;
            const norm = 1.0 - std.math.clamp((mouse[1] - origin[1]) / height, 0, 1);
            const new_value = args.value_lo + norm * (args.value_hi - args.value_lo);
            if (new_beat != p.beat or new_value != p.value) result.moved = .{ .index = i, .beat = new_beat, .value = new_value };
        }
        if (node_active or node_hovered) {
            var buf: [32]u8 = undefined;
            _ = zgui.beginTooltip();
            zgui.text("{d:.2} {s}  /  {s}", .{ p.beat, args.x_unit_label, knobFormatValue(&buf, "%.2f", p.value) });
            zgui.endTooltip();
        }
        draw_list.addCircleFilled(.{ .p = center, .r = handle_r - 1, .col = gui_style.color(if (node_active or node_hovered) args.accent else patina.fg1) });
        if (args.focused_index != null and args.focused_index.? == i) draw_list.addCircle(.{ .p = center, .r = handle_r + 3, .col = gui_style.color(args.accent), .thickness = 1.5 });
    }

    if (bg_activated and result.moved == null and result.removed == null and result.activated_index == null) {
        const raw_beat: f64 = if (args.beat_hi > 0) @as(f64, (bg_mouse[0] - origin[0]) / width) * args.beat_hi else 0;
        var beat = std.math.clamp(raw_beat, 0, args.beat_hi);
        if (args.snap_beats > 0) beat = @round(beat / args.snap_beats) * args.snap_beats;
        const norm = 1.0 - std.math.clamp((bg_mouse[1] - origin[1]) / height, 0, 1);
        const value = args.value_lo + norm * (args.value_hi - args.value_lo);
        result.inserted = .{ .beat = beat, .value = value };
    }

    draw_list.addRect(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = gui_style.color(patina.bg4), .rounding = 3, .thickness = 1 });
    zgui.setCursorScreenPos(.{ origin[0], origin[1] + height });
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
