//! Track overview: one chrome row per track/group plus the pinned master row.

const std = @import("std");
const ws = @import("wstudio");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const gui_style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const icons = @import("../../ui/icons.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const trackColor = gui_style.trackColor;
const legibleOn = gui_style.legibleOn;
const patina = &gui_style.palette;

/// Left number/glyph strip and right info block are fixed-width so they
/// never drift with the panel's width - only the middle (name, FX chips)
/// stretches. This is also what keeps the info block *pinned* to the true
/// right edge instead of the old `width - <magic offset>` scheme, which
/// left a growing dead gap on wide windows.
const strip_w: f32 = 34;
const block_w: f32 = 200;
const block_margin: f32 = 8;

fn blockX0(origin_x: f32, width: f32) f32 {
    return origin_x + width - block_margin - block_w;
}

pub fn draw(app: anytype) void {
    app.core.tracksRowSync();
    zgui.textDisabled("TRACKS", .{});
    zgui.sameLine(.{});
    zgui.textColored(if (app.core.session.song_mode) patina.audio else patina.fg3, "{s}", .{if (app.core.session.song_mode) "SONG" else "PATTERN"});
    zgui.separator();
    const row_count = app.core.trackRows().len + 1;
    const available_height = zgui.getContentRegionAvail()[1];
    const row_height = std.math.clamp((available_height - 154) / @as(f32, @floatFromInt(row_count)), 52, 82);
    for (app.core.trackRows(), 0..) |row, display_row| {
        switch (row) {
            .track => |track_index| drawMixerRow(app, track_index, display_row, row_height),
            .group => |group_index| drawGroupRow(app, group_index, display_row, row_height),
        }
    }
    zgui.separator();
    drawMasterRow(app, @max(row_height, 64));
}

/// Shared chrome for one 44px row in the track overview: hit-test button,
/// state-colored background, cursor/visual outline, click-to-select. The
/// body background is always the neutral row tone now - track/group/master
/// color lives only in the side strip and info block drawn on top of it.
const RowChrome = struct {
    draw: zgui.DrawList,
    origin: [2]f32,
    width: f32,
    selected: bool,
    in_visual: bool,
    hovered: bool,
};

fn drawRowChrome(app: anytype, id: [:0]const u8, display_row: usize, in_visual: bool, height: f32) RowChrome {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    // The mixer row's mute/solo/arm badges sit inside this button's bounds
    // and are submitted after it - allowOverlap lets them still take hover
    // themselves instead of this larger, earlier button eating it first
    // (ImGui's default; see widgets.curveEditor's node buttons for the same
    // fix applied to the same problem).
    zgui.setNextItemAllowOverlap();
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const selected = app.core.track_row == display_row;
    const draw_list = zgui.getWindowDrawList();
    const row_bg = if (selected) patina.bg3 else if (hovered) patina.bg2 else patina.bg1;
    draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height - 2 },
        .col = color(row_bg),
        .rounding = 3,
    });
    if (selected) drawTrackRowCursorUnderlay(draw_list, origin, width, height);
    if (clicked) app.core.setTrackRow(display_row);
    return .{
        .draw = draw_list,
        .origin = origin,
        .width = width,
        .selected = selected,
        .in_visual = in_visual,
        .hovered = hovered,
    };
}

/// The colored left cap: a `strip_w`-wide block flush to the row's left
/// edge, round only on that side (round_corners_left) so it reads as a
/// bookend rather than a chip floating over the body. `legibleOn` picks the
/// text color per swatch since track accents range from near-white to
/// fairly saturated across the 7-color rotation and both light and dark
/// themes - a single hardcoded text color goes illegible on some of them.
fn drawSideStrip(draw_list: zgui.DrawList, origin: [2]f32, height: f32, accent: [4]f32, comptime fmt: []const u8, args: anytype) void {
    draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + strip_w, origin[1] + height - 2 },
        .col = color(accent),
        .rounding = 3,
        .flags = zgui.DrawFlags.round_corners_left,
    });
    var buf: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const size = zgui.calcTextSize(label, .{});
    draw_list.addText(.{ origin[0] + (strip_w - size[0]) / 2, origin[1] + (height - 2 - size[1]) / 2 }, color(legibleOn(accent)), "{s}", .{label});
}

/// The colored right cap: mirrors `drawSideStrip` on the opposite edge,
/// pinned `block_margin` px from the true right edge regardless of panel
/// width. Callers draw their own content (gain/pan/meter/badges) inside at
/// coordinates relative to the returned x0.
fn drawInfoBlockBg(draw_list: zgui.DrawList, origin: [2]f32, width: f32, height: f32, accent: [4]f32) f32 {
    const x0 = blockX0(origin[0], width);
    draw_list.addRectFilled(.{
        .pmin = .{ x0, origin[1] },
        .pmax = .{ origin[0] + width - block_margin, origin[1] + height - 2 },
        .col = color(accent),
        .rounding = 3,
        .flags = zgui.DrawFlags.round_corners_right,
    });
    return x0;
}

fn drawMixerRow(app: anytype, track_index: u16, display_row: usize, height: f32) void {
    const track = app.core.session.project.tracks.items[track_index];
    const rack = app.core.session.racks.items[track_index];
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "mixer-row-{d}", .{track_index}) catch return;
    const accent = trackColor(track.color);
    const chrome = drawRowChrome(app, id, display_row, trackRowInVisual(&app.core, display_row), height);
    const draw_list = chrome.draw;
    const origin = chrome.origin;
    const width = chrome.width;
    const selected = chrome.selected;
    const row_fg = if (selected) patina.fg0 else patina.fg1;
    const row_muted = patina.fg3;

    drawSideStrip(draw_list, origin, height, accent, "{d:0>2}", .{track_index + 1});

    const grouped = if (track.group) |group| group < ws.engine.max_groups and app.core.session.groups[group] != null else false;
    const text_x = origin[0] + strip_w + 13 + @as(f32, if (grouped) 18 else 0);
    const rack_label: []const u8 = if (std.meta.activeTag(rack.instrument) == .empty) "-- empty --" else rack.label;
    draw_list.addText(.{ text_x, origin[1] + 5 }, color(row_fg), "{s}", .{track.name});
    draw_list.addText(.{ text_x + 28, origin[1] + 23 }, color(row_muted), "[{s}]", .{rack_label});

    const block_x0 = drawInfoBlockBg(draw_list, origin, width, height, accent);
    const block_fg = legibleOn(accent);
    const block_muted = [4]f32{ block_fg[0], block_fg[1], block_fg[2], 0.62 };
    drawFxChips(draw_list, &rack.fx, text_x + 150, origin[1] + 12, block_x0 - 12);

    var gain_buf: [24]u8 = undefined;
    const gain = std.fmt.bufPrint(&gain_buf, "{d:.1} dB", .{track.gain_db}) catch "gain";
    var pan_buf: [24]u8 = undefined;
    const pan = if (track.pan == 0.0)
        "C"
    else
        std.fmt.bufPrint(&pan_buf, "{c}{d}%", .{ if (track.pan < 0) @as(u8, 'L') else 'R', @as(u32, @intFromFloat(@abs(track.pan) * 100.0)) }) catch "pan";
    draw_list.addText(.{ block_x0 + 18, origin[1] + 14 }, color(block_fg), "{s}", .{gain});
    draw_list.addText(.{ block_x0 + 96, origin[1] + 14 }, color(block_muted), "{s}", .{pan});
    drawTrimMeter(draw_list, block_x0 + 3, origin[1] + height - 15, 105, track.gain_db, block_fg);

    // Always three fixed slots (unlike the old read-only badges, which only
    // occupied space when already on) so each has a stable, clickable hit
    // zone regardless of state - solo/mute/arm toggle straight through the
    // same index-parameterized setters the Lua API uses, so a click here
    // stays in step with `:track-set`/wstudio.api.track_set and undoes the
    // same way a keyboard toggle does.
    var badge_x = block_x0 + 181;
    var badge_id_buf: [40]u8 = undefined;
    if (drawTrackBadgeToggle(draw_list, std.fmt.bufPrintZ(&badge_id_buf, "solo-{d}", .{track_index}) catch "solo", badge_x, origin[1] + 12, icons.solo, track.soloed, patina.rhythm)) {
        app.core.apiSetTrackSoloed(track_index, !track.soloed);
    }
    badge_x -= 18;
    if (drawTrackBadgeToggle(draw_list, std.fmt.bufPrintZ(&badge_id_buf, "mute-{d}", .{track_index}) catch "mute", badge_x, origin[1] + 12, icons.mute, track.muted, patina.danger)) {
        app.core.apiSetTrackMuted(track_index, !track.muted);
    }
    badge_x -= 18;
    if (drawTrackBadgeToggle(draw_list, std.fmt.bufPrintZ(&badge_id_buf, "arm-{d}", .{track_index}) catch "arm", badge_x, origin[1] + 12, "R", app.core.session.isArmed(track_index), patina.danger)) {
        app.core.session.toggleArm(track_index);
        app.core.dirty = true;
    }
    drawTrackRowCursorOutline(chrome, height);
    // The badges above each moved the auto-layout cursor to their own small
    // absolute position via setCursorScreenPos, so without this the next
    // row's chrome would start right after the last badge (~30px down)
    // instead of after this row's real `height` - silently overlapping the
    // next row by the difference (its opaque background just painted over
    // the tail end of this one, every row, until the strip/block redesign
    // made the cut visible).
    zgui.setCursorScreenPos(.{ origin[0], origin[1] + height });
}

fn drawGroupRow(app: anytype, group_index: u8, display_row: usize, height: f32) void {
    const group = &app.core.session.groups[group_index].?;
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "group-row-{d}", .{group_index}) catch return;
    const chrome = drawRowChrome(app, id, display_row, trackRowInVisual(&app.core, display_row), height);
    const draw_list = chrome.draw;
    const origin = chrome.origin;
    const width = chrome.width;
    const selected = chrome.selected;
    const accent = patina.modulation;

    drawSideStrip(draw_list, origin, height, accent, "{s}", .{if (group.folded) ">" else "v"});

    var member_count: usize = 0;
    for (app.core.session.project.tracks.items) |track| if (track.group == group_index) {
        member_count += 1;
    };
    const text_x = origin[0] + strip_w + 13;
    draw_list.addText(.{ text_x, origin[1] + 5 }, color(if (selected) patina.fg0 else patina.modulation), "{d:0>2}  {s}", .{ group_index + 1, group.name });
    draw_list.addText(.{ text_x + 28, origin[1] + 23 }, color(patina.fg3), "[group]  {d} track{s}", .{ member_count, if (member_count == 1) "" else "s" });

    const block_x0 = drawInfoBlockBg(draw_list, origin, width, height, accent);
    const block_fg = legibleOn(accent);
    drawFxChips(draw_list, &group.fx, text_x + 150, origin[1] + 12, block_x0 - 12);
    draw_list.addText(.{ block_x0 + 18, origin[1] + 14 }, color(block_fg), "{d:.1} dB", .{group.gain_db});
    drawTrimMeter(draw_list, block_x0 + 3, origin[1] + height - 15, 105, group.gain_db, block_fg);
    drawTrackRowCursorOutline(chrome, height);
}

fn drawMasterRow(app: anytype, height: f32) void {
    const chrome = drawRowChrome(app, "master-row", app.core.track_rows_len, false, height);
    const draw_list = chrome.draw;
    const origin = chrome.origin;
    const width = chrome.width;
    const selected = chrome.selected;
    const accent = patina.audio;

    drawSideStrip(draw_list, origin, height, accent, "M", .{});

    const text_x = origin[0] + strip_w + 13;
    draw_list.addText(.{ text_x, origin[1] + 5 }, color(if (selected) patina.fg0 else patina.modulation), "MASTER", .{});
    draw_list.addText(.{ text_x + 28, origin[1] + 23 }, color(patina.fg3), "[bus]", .{});

    const block_x0 = drawInfoBlockBg(draw_list, origin, width, height, accent);
    const block_fg = legibleOn(accent);
    drawFxChips(draw_list, &app.core.session.master_fx, text_x + 150, origin[1] + 12, block_x0 - 12);
    draw_list.addText(.{ block_x0 + 18, origin[1] + 14 }, color(block_fg), "{d:.1} dB", .{app.core.master_gain_db});
    // meter_hold_db is refreshed once per frame by chrome.zig's transport
    // draw (always runs first, see app.zig's App.draw) - reusing it here
    // keeps this meter in sync with the transport's LEVEL readout instead
    // of re-deriving its own peak-hold state from the raw peak.
    widgets.solidMeterBar(draw_list, .{ block_x0 + 3, origin[1] + height - 21 }, app.meter_hold_db, 170, 5, 3, block_fg);
    drawTrackRowCursorOutline(chrome, height);
}

/// `bar_color` is the block's own contrast text color, not the track's raw
/// accent - the meter now sits on top of a block already filled with that
/// accent, where the accent itself would be invisible against its own
/// background.
fn drawTrimMeter(draw_list: zgui.DrawList, x: f32, y: f32, width: f32, gain_db: f32, bar_color: [4]f32) void {
    const level = std.math.clamp((gain_db + 60) / 72, 0, 1);
    draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + width, y + 5 }, .col = color(.{ bar_color[0], bar_color[1], bar_color[2], 0.25 }), .rounding = 2 });
    draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + width * level, y + 5 }, .col = color(bar_color), .rounding = 2 });
}

fn trackRowInVisual(core: anytype, display_row: usize) bool {
    if (core.modal.mode != .visual) return false;
    const anchor = core.tracks_visual_anchor orelse core.track_row;
    return display_row >= @min(anchor, core.track_row) and display_row <= @max(anchor, core.track_row);
}

fn drawTrackRowCursorUnderlay(draw_list: zgui.DrawList, origin: [2]f32, width: f32, height: f32) void {
    draw_list.addRectFilled(.{
        .pmin = .{ origin[0] + 1, origin[1] + 1 },
        .pmax = .{ origin[0] + width - block_margin - 1, origin[1] + height - 3 },
        .col = color(.{ patina.track_cursor[0], patina.track_cursor[1], patina.track_cursor[2], 0.18 }),
        .rounding = 2,
    });
}

/// Drawn after every row's content so the cursor remains visible across the
/// colored side strip and info block instead of being painted over by them.
fn drawTrackRowCursorOutline(chrome: RowChrome, height: f32) void {
    if (!chrome.selected and !chrome.in_visual and !chrome.hovered) return;
    const inset: f32 = if (chrome.selected) 1 else 0;
    chrome.draw.addRect(.{
        .pmin = .{ chrome.origin[0] + inset, chrome.origin[1] + inset },
        .pmax = .{
            chrome.origin[0] + chrome.width - block_margin - inset,
            chrome.origin[1] + height - 2 - inset,
        },
        .col = color(if (chrome.selected) patina.track_cursor else if (chrome.in_visual) patina.fg0 else patina.focus),
        .rounding = 2,
        .thickness = if (chrome.selected or chrome.in_visual) 2 else 1,
    });
}

/// A fixed-position 15x18 badge that's always present (unlike the old
/// state-gated one), dim when off and lit with `active_bg` when on -
/// clicking it toggles, returning whether this frame's click did.
fn drawTrackBadgeToggle(draw_list: zgui.DrawList, id: [:0]const u8, x: f32, y: f32, label: []const u8, active: bool, active_bg: [4]f32) bool {
    zgui.setCursorScreenPos(.{ x, y });
    _ = zgui.invisibleButton(id, .{ .w = 15, .h = 18 });
    const activated = zgui.isItemActivated();
    const hovered = zgui.isItemHovered(.{});
    const bg = if (active) active_bg else if (hovered) patina.bg4 else patina.bg2;
    const fg = if (active) legibleOn(active_bg) else if (hovered) patina.fg1 else patina.fg3;
    draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + 15, y + 18 }, .col = color(bg), .rounding = 2 });
    const label_size = zgui.calcTextSize(label, .{});
    draw_list.addText(.{
        x + (15 - label_size[0]) / 2,
        y + (18 - label_size[1]) / 2,
    }, color(fg), "{s}", .{label});
    return activated;
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
