//! Track overview: one chrome row per track/group plus the pinned master row.

const std = @import("std");
const ws = @import("wstudio");
const spectrum_ed = @import("../../tui/editors/spectrum.zig");
const gui_style = @import("../style.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const trackColor = gui_style.trackColor;
const patina = &gui_style.palette;

pub fn draw(app: anytype) void {
    app.core.tracksRowSync();
    zgui.textDisabled("TRACKS", .{});
    zgui.separator();
    for (app.core.trackRows(), 0..) |row, display_row| {
        switch (row) {
            .track => |track_index| drawMixerRow(app, track_index, display_row),
            .group => |group_index| drawGroupRow(app, group_index, display_row),
        }
    }
    zgui.separator();
    drawMasterRow(app);
}

/// Shared chrome for one 44px row in the track overview: hit-test button,
/// state-colored background, cursor/visual outline, click-to-select. The
/// mixer row overrides the background with the track's own color chip.
const RowChrome = struct { draw: zgui.DrawList, origin: [2]f32, width: f32, selected: bool };

fn drawRowChrome(app: anytype, id: [:0]const u8, display_row: usize, in_visual: bool, bg_override: ?[4]f32) RowChrome {
    const height: f32 = 44;
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const selected = app.core.track_row == display_row;
    const draw_list = zgui.getWindowDrawList();
    const row_bg = bg_override orelse if (selected) patina.bg3 else if (hovered) patina.bg2 else patina.bg1;
    draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height - 2 },
        .col = color(row_bg),
        .rounding = 3,
    });
    drawTrackRowCursor(draw_list, origin, width, height, selected, in_visual, hovered);
    if (clicked) app.core.setTrackRow(display_row);
    return .{ .draw = draw_list, .origin = origin, .width = width, .selected = selected };
}

fn drawMixerRow(app: anytype, track_index: u16, display_row: usize) void {
    const track = app.core.session.project.tracks.items[track_index];
    const rack = app.core.session.racks.items[track_index];
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "mixer-row-{d}", .{track_index}) catch return;
    const accent = trackColor(track.color);
    const colored = track.color > 0 and track.color <= ws.track_color_count;
    const chrome = drawRowChrome(app, id, display_row, trackRowInVisual(&app.core, display_row), if (colored) accent else null);
    const draw_list = chrome.draw;
    const origin = chrome.origin;
    const width = chrome.width;
    const selected = chrome.selected;
    const row_fg = if (colored) patina.bg0 else if (selected) patina.fg0 else patina.fg1;
    const row_muted = if (colored)
        [4]f32{ patina.bg0[0], patina.bg0[1], patina.bg0[2], 0.62 }
    else
        patina.fg3;

    const grouped = if (track.group) |group| group < ws.engine.max_groups and app.core.session.groups[group] != null else false;
    const text_x = origin[0] + 13 + @as(f32, if (grouped) 18 else 0);
    const rack_label: []const u8 = if (std.meta.activeTag(rack.instrument) == .empty) "-- empty --" else rack.label;
    draw_list.addText(.{ text_x, origin[1] + 5 }, color(row_fg), "{d:0>2}  {s}", .{ track_index + 1, track.name });
    draw_list.addText(.{ text_x + 28, origin[1] + 23 }, color(row_muted), "[{s}]", .{rack_label});
    drawFxChips(draw_list, &rack.fx, origin[0] + width - 430, origin[1] + 12, origin[0] + width - 215);

    var gain_buf: [24]u8 = undefined;
    const gain = std.fmt.bufPrint(&gain_buf, "{d:.1} dB", .{track.gain_db}) catch "gain";
    var pan_buf: [24]u8 = undefined;
    const pan = if (@abs(track.pan) < 0.005)
        "C"
    else
        std.fmt.bufPrint(&pan_buf, "{c}{d:.2}", .{ if (track.pan < 0) @as(u8, 'L') else 'R', @abs(track.pan) }) catch "pan";
    draw_list.addText(.{ origin[0] + width - 190, origin[1] + 14 }, color(row_fg), "{s}", .{gain});
    draw_list.addText(.{ origin[0] + width - 112, origin[1] + 14 }, color(row_muted), "{s}", .{pan});

    var badge_x = origin[0] + width - 9;
    if (track.soloed) {
        badge_x -= 18;
        drawTrackBadge(draw_list, badge_x, origin[1] + 12, "S", patina.rhythm);
    }
    if (track.muted) {
        badge_x -= 18;
        drawTrackBadge(draw_list, badge_x, origin[1] + 12, "M", patina.danger);
    }
}

fn drawGroupRow(app: anytype, group_index: u8, display_row: usize) void {
    const group = &app.core.session.groups[group_index].?;
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "group-row-{d}", .{group_index}) catch return;
    const chrome = drawRowChrome(app, id, display_row, trackRowInVisual(&app.core, display_row), null);
    const draw_list = chrome.draw;
    const origin = chrome.origin;
    const width = chrome.width;
    const selected = chrome.selected;

    var member_count: usize = 0;
    for (app.core.session.project.tracks.items) |track| if (track.group == group_index) {
        member_count += 1;
    };
    draw_list.addText(.{ origin[0] + 13, origin[1] + 5 }, color(if (selected) patina.fg0 else patina.modulation), "{s} {d:0>2}  {s}", .{ if (group.folded) ">" else "v", group_index + 1, group.name });
    draw_list.addText(.{ origin[0] + 41, origin[1] + 23 }, color(patina.fg3), "[group]  {d} track{s}", .{ member_count, if (member_count == 1) "" else "s" });
    drawFxChips(draw_list, &group.fx, origin[0] + width - 430, origin[1] + 12, origin[0] + width - 215);
    draw_list.addText(.{ origin[0] + width - 190, origin[1] + 14 }, color(if (selected) patina.fg0 else patina.fg1), "{d:.1} dB", .{group.gain_db});
}

fn drawMasterRow(app: anytype) void {
    const chrome = drawRowChrome(app, "master-row", app.core.track_rows_len, false, null);
    const draw_list = chrome.draw;
    const origin = chrome.origin;
    const width = chrome.width;
    const selected = chrome.selected;
    draw_list.addText(.{ origin[0] + 13, origin[1] + 5 }, color(if (selected) patina.fg0 else patina.modulation), "MASTER", .{});
    draw_list.addText(.{ origin[0] + 41, origin[1] + 23 }, color(patina.fg3), "[bus]", .{});
    drawFxChips(draw_list, &app.core.session.master_fx, origin[0] + width - 430, origin[1] + 12, origin[0] + width - 215);
    draw_list.addText(.{ origin[0] + width - 190, origin[1] + 14 }, color(if (selected) patina.fg0 else patina.fg1), "{d:.1} dB", .{app.core.master_gain_db});
}

fn trackRowInVisual(core: anytype, display_row: usize) bool {
    if (core.modal.mode != .visual) return false;
    const anchor = core.tracks_visual_anchor orelse core.track_row;
    return display_row >= @min(anchor, core.track_row) and display_row <= @max(anchor, core.track_row);
}

fn drawTrackRowCursor(draw_list: zgui.DrawList, origin: [2]f32, width: f32, height: f32, selected: bool, in_visual: bool, hovered: bool) void {
    if (selected) {
        draw_list.addRectFilled(.{ .pmin = .{ origin[0] + 1, origin[1] + 1 }, .pmax = .{ origin[0] + width - 1, origin[1] + height - 3 }, .col = color(.{ patina.track_cursor[0], patina.track_cursor[1], patina.track_cursor[2], 0.18 }), .rounding = 2 });
        draw_list.addRect(.{ .pmin = .{ origin[0] + 1, origin[1] + 1 }, .pmax = .{ origin[0] + width - 1, origin[1] + height - 3 }, .col = color(patina.track_cursor), .rounding = 2, .thickness = 2 });
    } else if (in_visual or hovered) {
        draw_list.addRect(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height - 2 }, .col = color(if (in_visual) patina.fg0 else patina.focus), .rounding = 2, .thickness = if (in_visual) 2 else 1 });
    }
}

fn drawTrackBadge(draw_list: zgui.DrawList, x: f32, y: f32, label: []const u8, bg: [4]f32) void {
    draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + 15, y + 18 }, .col = color(bg), .rounding = 2 });
    draw_list.addText(.{ x + 4, y + 2 }, color(patina.bg0), "{s}", .{label});
}

fn drawFxChips(draw_list: zgui.DrawList, fx: *const ws.Fx, start_x: f32, y: f32, max_x: f32) void {
    var x = start_x;
    for (fx.units.items, 0..) |unit, index| {
        if (index == 4) {
            draw_list.addText(.{ x, y + 2 }, color(patina.fg3), "+{d}", .{fx.units.items.len - index});
            break;
        }
        const label = spectrum_ed.stripLabel(unit.kind());
        const chip_w = zgui.calcTextSize(label, .{})[0] + 12;
        if (x + chip_w > max_x) break;
        draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + chip_w, y + 20 }, .col = color(patina.bg2), .rounding = 2 });
        draw_list.addText(.{ x + 6, y + 2 }, color(if (unit.bypassed) patina.fg3 else patina.audio), "{s}", .{label});
        x += chip_w + 4;
    }
}
