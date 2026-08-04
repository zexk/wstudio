const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const gui_style = @import("style.zig");

/// Same red/yellow/green thresholds every meter in the app uses - keep it one
/// place, or two panes drawing the same peak would grade it differently.
const meter_db_min: f32 = -50.0;
const meter_yellow_db: f32 = -6.0;
const meter_red_db: f32 = -1.0;

/// Advances `hold_db` toward `peak` (converted to dB) and lets it decay at
/// `gui_style.meter_decay_db_per_s`. Called once per frame - `meterBar` itself
/// is a pure draw and can be called any number of times off the same
/// already-updated `hold_db` (e.g. once in the transport strip, once again
/// in the tracks view's master row) without re-triggering the decay.
pub fn updateMeterHold(hold_db: *[2]f32, peak: [2]f32, dt: f32) void {
    for (0..2) |ch| {
        const db = ws.types.gainToDb(peak[ch]);
        hold_db[ch] = @max(db, hold_db[ch] - gui_style.meter_decay_db_per_s * dt);
    }
}

pub fn meterBar(draw_list: zgui.DrawList, origin: [2]f32, hold_db: [2]f32, bar_w: f32, bar_h: f32, gap: f32) void {
    const theme = &gui_style.palette;
    for (0..2) |ch| {
        const y = origin[1] + @as(f32, @floatFromInt(ch)) * (bar_h + gap);
        draw_list.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ origin[0] + bar_w, y + bar_h }, .col = gui_style.color(theme.bg2), .rounding = gui_style.item_rounding });
        const norm = std.math.clamp((hold_db[ch] - meter_db_min) / -meter_db_min, 0, 1);
        meterFill(draw_list, origin[0], y, bar_w, bar_h, norm);
    }
}

/// Stereo peak meter for an already-colored surface. The surface's
/// contrast color replaces the transport meter's semantic gradient so the
/// bars remain legible on both light and dark accents.
pub fn solidMeterBar(draw_list: zgui.DrawList, origin: [2]f32, hold_db: [2]f32, bar_w: f32, bar_h: f32, gap: f32, bar_color: [4]f32) void {
    for (0..2) |ch| {
        const y = origin[1] + @as(f32, @floatFromInt(ch)) * (bar_h + gap);
        draw_list.addRectFilled(.{
            .pmin = .{ origin[0], y },
            .pmax = .{ origin[0] + bar_w, y + bar_h },
            .col = gui_style.color(.{ bar_color[0], bar_color[1], bar_color[2], 0.25 }),
            .rounding = gui_style.item_rounding,
        });
        const norm = std.math.clamp((hold_db[ch] - meter_db_min) / -meter_db_min, 0, 1);
        draw_list.addRectFilled(.{
            .pmin = .{ origin[0], y },
            .pmax = .{ origin[0] + bar_w * norm, y + bar_h },
            .col = gui_style.color(bar_color),
            .rounding = gui_style.item_rounding,
        });
    }
}

fn meterFill(draw_list: zgui.DrawList, x: f32, y: f32, w: f32, h: f32, norm: f32) void {
    if (norm <= 0) return;
    const theme = &gui_style.palette;
    const yellow_norm = (meter_yellow_db - meter_db_min) / -meter_db_min;
    const red_norm = (meter_red_db - meter_db_min) / -meter_db_min;
    const fill_w = w * norm;
    const green_w = @min(fill_w, w * yellow_norm);
    draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + green_w, y + h }, .col = gui_style.color(theme.audio), .rounding = gui_style.item_rounding });
    if (fill_w > w * yellow_norm) {
        draw_list.addRectFilled(.{ .pmin = .{ x + w * yellow_norm, y }, .pmax = .{ x + @min(fill_w, w * red_norm), y + h }, .col = gui_style.color(theme.rhythm) });
    }
    if (fill_w > w * red_norm) {
        draw_list.addRectFilled(.{ .pmin = .{ x + w * red_norm, y }, .pmax = .{ x + fill_w, y + h }, .col = gui_style.color(theme.danger) });
    }
}

/// Phase-correlation bar: a horizontal track with a zero-centered fill
/// running toward the left edge for negative (out-of-phase) values and
/// toward the right edge for positive (in-phase) ones - shared by the
/// transport's master PHASE readout, the same way `meterBar` is shared for
/// LEVEL. `value` is -1..1, see `dsp/meter.zig`'s `StereoCorrelation`.
/// Same red/yellow/green thresholds a hardware phase scope uses: fully
/// in-phase and mildly-so both read as safe, only the cancellation-risk
/// half reads as danger. Shared between the bar's fill and the numeric
/// readout beside it so the two never disagree about what "bad" means.
pub fn correlationColor(value: f32) [4]f32 {
    const theme = &gui_style.palette;
    return if (value >= 0.0) theme.audio else if (value >= -0.5) theme.rhythm else theme.danger;
}

pub fn correlationBar(draw_list: zgui.DrawList, origin: [2]f32, value: f32, w: f32, h: f32) void {
    const theme = &gui_style.palette;
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + w, origin[1] + h }, .col = gui_style.color(theme.bg2), .rounding = gui_style.item_rounding });
    const mid = origin[0] + w * 0.5;
    draw_list.addLine(.{ .p1 = .{ mid, origin[1] }, .p2 = .{ mid, origin[1] + h }, .col = gui_style.color(theme.fg3), .thickness = 1 });

    const v = std.math.clamp(value, -1.0, 1.0);
    const fill_x = mid + (w * 0.5) * @min(v, 0.0);
    const fill_w = (w * 0.5) * @abs(v);
    draw_list.addRectFilled(.{ .pmin = .{ fill_x, origin[1] }, .pmax = .{ fill_x + fill_w, origin[1] + h }, .col = gui_style.color(correlationColor(v)), .rounding = gui_style.item_rounding });
}
