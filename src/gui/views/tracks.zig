//! Track overview: one chrome row per track/group plus the pinned master row.

const std = @import("std");
const ws = @import("wstudio");
const format = @import("../../ui/format.zig");
const spectrum_ed = @import("../../ui/editors/spectrum.zig");
const gui_style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const zgui = @import("zgui");

const color = gui_style.color;
const trackColor = gui_style.trackColor;
const legibleOn = gui_style.legibleOn;
const theme = &gui_style.palette;

/// Left number/glyph strip and right info block are fixed-width so they
/// never drift with the panel's width - only the middle (name, FX chips)
/// stretches. This is also what keeps the info block *pinned* to the true
/// right edge instead of the old `width - <magic offset>` scheme, which
/// left a growing dead gap on wide windows.
const strip_w: f32 = 34;
const block_w: f32 = 252;
const block_margin: f32 = 8;

fn blockX0(origin_x: f32, width: f32) f32 {
    return origin_x + width - block_margin - block_w;
}

/// The row's own right edge: `block_margin` in from the content region, the
/// same edge the info block, cursor underlay and cursor outline all end on.
/// Everything row-wide has to use this - a full-`width` background behind
/// them just leaves a strip of bare row tone past the accent block that the
/// cursor never covers.
fn rowRight(origin_x: f32, width: f32) f32 {
    return origin_x + width - block_margin;
}

/// Horizontal padding inside the info block - the gain readout, the trim
/// meter and the badge cluster all breathe from this same inset, so the
/// block's contents sit symmetrically instead of crowding its right corner.
const block_inset: f32 = 16;

/// Mute/solo/arm chips: fixed size, laid out right-to-left from the info
/// block's inner right edge, so slot 0 is the rightmost.
const badge_w: f32 = 18;
const badge_h: f32 = 18;
const badge_pitch: f32 = 22;

fn badgeX(block_x0: f32, slot: f32) f32 {
    return block_x0 + block_w - block_inset - badge_w - slot * badge_pitch;
}

/// Vertical layout of an info block's two stacked lines (controls on top,
/// meter below). The stack is centered on the row, and the gap between the
/// lines opens up to `stack_breath` when the row is tall enough - so the
/// controls ride high and the meter low instead of both hugging the middle.
const stack_breath: f32 = 20;
const meter_bar_h: f32 = 4;
const meter_gap: f32 = 2;

fn stackTops(center_y: f32, height: f32, controls_h: f32, meter_h: f32) struct { controls: f32, meter: f32 } {
    const stack_h = @min(height - 12, controls_h + meter_h + stack_breath);
    const top = center_y - stack_h / 2;
    return .{ .controls = top, .meter = top + stack_h - meter_h };
}

test "info-block stack is centered with its lines pushed apart" {
    const s = stackTops(100, 112, 22, 10);
    try std.testing.expectEqual(@as(f32, 74), s.controls);
    // Equal breathing room above the controls and below the meter.
    try std.testing.expectEqual(100 - s.controls, s.meter + 10 - 100);
    // A short row falls back to whatever gap still fits, still centered.
    const tight = stackTops(100, 52, 22, 10);
    try std.testing.expectEqual(@as(f32, 80), tight.controls);
    try std.testing.expectEqual(@as(f32, 110), tight.meter);
}

/// The mixer row's top line inside the info block: gain, pan, then the
/// badge cluster, each group separated by `group_gap` and the outer two
/// flush against `block_inset` on their own side. Sized so the three add up
/// to the block's inner width with exactly two gaps left over - the whole
/// point is that nothing bunches in the middle with dead space at the edges.
const group_gap: f32 = 10;
const badge_cluster_w: f32 = badge_pitch * 2 + badge_w;
const gain_w: f32 = 76;
const pan_w: f32 = block_w - 2 * block_inset - 2 * group_gap - gain_w - badge_cluster_w;

test "info-block groups fill the inner width without bunching" {
    try std.testing.expectEqual(block_w - 2 * block_inset, gain_w + group_gap + pan_w + group_gap + badge_cluster_w);
    // The badge cluster ends exactly on the right inset, mirroring gain's
    // left one - `badgeX` counts back from the block's right edge.
    try std.testing.expectEqual(block_inset + gain_w + group_gap + pan_w + group_gap, badgeX(0, 2));
}

/// Mixer-console pan readout: `C`, or the side plus how far it leans (L100
/// … C … R100). Null-terminated because it is handed to ImGui as a drag's
/// value format - and deliberately without the `%` `ui/format.zig`'s own
/// `panLabel` carries, since a stray `%` in a printf format string is what
/// ImGui would try to expand.
fn panFmt(buf: []u8, pan: f32) [:0]const u8 {
    if (@abs(pan) < format.pan_center_epsilon) return "C";
    return std.fmt.bufPrintZ(buf, "{s}{d:.0}", .{ format.panLetter(pan), @abs(pan) * 100 }) catch "C";
}

test "pan drag reads as a mixer console, not a signed percentage" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("C", panFmt(&buf, 0));
    try std.testing.expectEqualStrings("C", panFmt(&buf, -0.001));
    try std.testing.expectEqualStrings("L100", panFmt(&buf, -1.0));
    try std.testing.expectEqualStrings("R42", panFmt(&buf, 0.42));
}

const MixerDrag = struct {
    id: [:0]const u8,
    x: f32,
    y: f32,
    w: f32,
    value: f32,
    min: f32,
    max: f32,
    /// Units per pixel of horizontal drag.
    speed: f32,
    /// What a right-click or double-click snaps back to.
    default: f32,
    centered_fill: bool = false,
    cfmt: [:0]const u8,
};

const MixerDragResult = struct {
    value: f32,
    changed: bool,
    activated: bool,
    /// The edit is over and worth an undo entry - a released drag, or the
    /// click that reset the control.
    finished: bool,
};

/// One mixer control inside a row's info block. A drag rather than a
/// slider: dragging is what a mixer strip does, and it comes with ImGui's
/// own shift (coarse, 10x) and alt (fine, 1/100) modifiers, which a
/// position-mapped slider cannot have. Right-click or double-click snaps
/// back to `default` - ImGui's own type-a-value box is off (`no_input`)
/// precisely so right-click is free for the reset, which is the gesture
/// people actually reach for on a fader.
fn mixerDrag(args: MixerDrag) MixerDragResult {
    var value = args.value;
    zgui.setCursorScreenPos(.{ args.x, args.y });
    zgui.setNextItemWidth(args.w);
    var changed = zgui.dragFloat(args.id, .{
        .v = &value,
        .speed = args.speed,
        .min = args.min,
        .max = args.max,
        .cfmt = args.cfmt,
        .flags = .{ .always_clamp = true, .no_input = true },
    });
    const hovered = zgui.isItemHovered(.{});
    const wheel = hovered and gui_style.wheel_delta != 0;
    if (wheel) {
        gui_style.wheel_consumed = true;
        const scale: f32 = if (zgui.isKeyDown(.mod_shift)) 10 else if (zgui.isKeyDown(.mod_alt)) 0.01 else 1;
        value = std.math.clamp(value + gui_style.wheel_delta * args.speed * scale, args.min, args.max);
        changed = true;
    }
    const reset = hovered and
        (zgui.isMouseClicked(.right) or zgui.isMouseDoubleClicked(.left));
    if (reset) {
        value = args.default;
        changed = true;
    }
    const t = std.math.clamp((value - args.min) / (args.max - args.min), 0, 1);
    const anchor: f32 = if (args.centered_fill) std.math.clamp((args.default - args.min) / (args.max - args.min), 0, 1) else 0;
    const item_min = zgui.getItemRectMin();
    const item_max = zgui.getItemRectMax();
    zgui.getWindowDrawList().addRectFilled(.{
        .pmin = .{ item_min[0] + args.w * @min(anchor, t), item_max[1] - 3 },
        .pmax = .{ item_min[0] + args.w * @max(anchor, t), item_max[1] },
        .col = color(theme.focus),
        .rounding = gui_style.item_rounding,
    });
    return .{
        .value = value,
        .changed = changed,
        // A right-click reset never activates the drag itself, so it has to
        // open the undo entry it also closes, or the reset isn't undoable.
        .activated = wheel or reset or zgui.isItemActivated(),
        .finished = wheel or reset or zgui.isItemDeactivatedAfterEdit(),
    };
}

pub fn draw(app: anytype) void {
    app.core.tracksRowSync();
    zgui.textDisabled("TRACKS", .{});
    zgui.sameLine(.{});
    zgui.textColored(if (app.core.session.song_mode) theme.audio else theme.fg3, "{s}", .{if (app.core.session.song_mode) "SONG" else "PATTERN"});
    zgui.separator();
    const row_count = app.core.trackRows().len + 1;
    const available_height = zgui.getContentRegionAvail()[1];
    const row_height = std.math.clamp((available_height - 154) / @as(f32, @floatFromInt(row_count)), 52, 112);
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
    // `j`/`k` past the fold have to bring the viewport with them, or the
    // cursor walks into clipped content and the view looks stuck.
    widgets.noteFocusRow(selected, origin[1], height);
    const draw_list = zgui.getWindowDrawList();
    const row_bg = if (hovered and !selected) theme.bg4 else theme.bg3;
    draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ rowRight(origin[0], width), origin[1] + height - 2 },
        .col = color(row_bg),
        .rounding = gui_style.item_rounding,
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
/// fairly saturated across the 16-color rotation and both light and dark
/// themes - a single hardcoded text color goes illegible on some of them.
fn drawSideStrip(draw_list: zgui.DrawList, origin: [2]f32, height: f32, accent: [4]f32, comptime fmt: []const u8, args: anytype) void {
    draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + strip_w, origin[1] + height - 2 },
        .col = color(accent),
        .rounding = gui_style.item_rounding,
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
        .pmax = .{ rowRight(origin[0], width), origin[1] + height - 2 },
        .col = color(accent),
        .rounding = gui_style.item_rounding,
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
    const row_fg = if (selected) theme.fg0 else theme.fg1;
    const row_muted = theme.fg3;

    drawSideStrip(draw_list, origin, height, accent, "{d:0>2}", .{track_index + 1});

    const grouped = if (track.group) |group| group < ws.engine.max_groups and app.core.session.groups[group] != null else false;
    const text_x = origin[0] + strip_w + 13 + @as(f32, if (grouped) 18 else 0);
    const rack_label: []const u8 = if (std.meta.activeTag(rack.instrument) == .empty) "-- empty --" else rack.label;
    draw_list.addText(.{ text_x, origin[1] + 5 }, color(row_fg), "{s}", .{track.name});
    draw_list.addText(.{ text_x + 28, origin[1] + 23 }, color(row_muted), "[{s}]", .{rack_label});

    const block_x0 = drawInfoBlockBg(draw_list, origin, width, height, accent);
    const block_fg = legibleOn(accent);
    drawFxChips(draw_list, &rack.fx, text_x + 150, origin[1] + 12, block_x0 - 12);
    const center_y = origin[1] + (height - 2) / 2;
    const controls_h = @max(badge_h, zgui.getFrameHeight());
    const stack = stackTops(center_y, height, controls_h, 2 * meter_bar_h + meter_gap);
    const controls_y = stack.controls;
    // Badges are shorter than a drag frame - center them on it so the whole
    // top line reads as one row rather than two heights sharing a baseline.
    const badge_y = controls_y + (controls_h - badge_h) / 2;

    const gain_before = track.gain_db;
    const gain = mixerDrag(.{
        .id = std.fmt.bufPrintZ(&id_buf, "##gain-{d}", .{track_index}) catch "##gain",
        .x = block_x0 + block_inset,
        .y = controls_y,
        .w = gain_w,
        .value = gain_before,
        .min = -60,
        .max = 12,
        .speed = 0.2,
        .default = 0,
        .cfmt = "%.1f dB",
    });
    if (gain.activated) app.beginTrackMixerEdit(track_index, .gain, gain_before);
    if (gain.changed) app.core.apiSetTrackGainDb(track_index, gain.value);
    if (gain.finished) app.finishTrackMixerEdit();

    const pan_before = track.pan;
    var pan_buf: [8]u8 = undefined;
    const pan = mixerDrag(.{
        .id = std.fmt.bufPrintZ(&id_buf, "##pan-{d}", .{track_index}) catch "##pan",
        .x = block_x0 + block_inset + gain_w + group_gap,
        .y = controls_y,
        .w = pan_w,
        .value = pan_before * 100,
        .min = -100,
        .max = 100,
        .speed = 0.5,
        .default = 0,
        .centered_fill = true,
        .cfmt = panFmt(&pan_buf, pan_before),
    });
    if (pan.activated) app.beginTrackMixerEdit(track_index, .pan, pan_before);
    if (pan.changed) app.core.apiSetTrackPan(track_index, pan.value / 100);
    if (pan.finished) app.finishTrackMixerEdit();

    widgets.solidMeterBar(draw_list, .{ block_x0 + block_inset, stack.meter }, app.track_meter_hold_db[track_index], block_w - 2 * block_inset, meter_bar_h, meter_gap, block_fg);

    // Always three fixed slots (unlike the old read-only badges, which only
    // occupied space when already on) so each has a stable, clickable hit
    // zone regardless of state - solo/mute/arm toggle straight through the
    // same index-parameterized setters the Lua API uses, so a click here
    // stays in step with `:track-set`/wstudio.api.track_set and undoes the
    // same way a keyboard toggle does.
    var badge_id_buf: [40]u8 = undefined;
    if (drawTrackBadgeToggle(draw_list, std.fmt.bufPrintZ(&badge_id_buf, "solo-{d}", .{track_index}) catch "solo", badgeX(block_x0, 0), badge_y, "S", track.soloed, theme.rhythm)) {
        app.core.apiSetTrackSoloed(track_index, !track.soloed);
    }
    if (drawTrackBadgeToggle(draw_list, std.fmt.bufPrintZ(&badge_id_buf, "mute-{d}", .{track_index}) catch "mute", badgeX(block_x0, 1), badge_y, "M", track.muted, theme.danger)) {
        app.core.apiSetTrackMuted(track_index, !track.muted);
    }
    if (drawTrackBadgeToggle(draw_list, std.fmt.bufPrintZ(&badge_id_buf, "arm-{d}", .{track_index}) catch "arm", badgeX(block_x0, 2), badge_y, "R", app.core.session.isArmed(track_index), theme.danger)) {
        app.core.apiSetTrackArmed(track_index, !app.core.session.isArmed(track_index));
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
    const accent = theme.modulation;

    drawSideStrip(draw_list, origin, height, accent, "{s}", .{if (group.folded) ">" else "v"});

    var member_count: usize = 0;
    for (app.core.session.project.tracks.items) |track| if (track.group == group_index) {
        member_count += 1;
    };
    const text_x = origin[0] + strip_w + 13;
    draw_list.addText(.{ text_x, origin[1] + 5 }, color(if (selected) theme.fg0 else theme.modulation), "{d:0>2}  {s}", .{ group_index + 1, group.name });
    draw_list.addText(.{ text_x + 28, origin[1] + 23 }, color(theme.fg3), "[group]  {d} track{s}", .{ member_count, if (member_count == 1) "" else "s" });

    const block_x0 = drawInfoBlockBg(draw_list, origin, width, height, accent);
    const block_fg = legibleOn(accent);
    const controls_y = origin[1] + (height - 2 - badge_h) / 2;
    drawFxChips(draw_list, &group.fx, text_x + 150, origin[1] + 12, block_x0 - 12);
    draw_list.addText(.{ block_x0 + block_inset, controls_y + 1 }, color(block_fg), "{d:.1} dB", .{group.gain_db});

    // Same badge slots a track row gets, in the same two positions, acting
    // on every member at once (App.doGroupToggle - the group row's own m/S).
    // A group has no arm state, so the third slot stays empty rather than
    // shifting these two left out of line with the track rows above.
    var badge_id_buf: [40]u8 = undefined;
    const soloed = app.core.groupFlagState(group_index, true).all;
    if (drawTrackBadgeToggle(draw_list, std.fmt.bufPrintZ(&badge_id_buf, "group-solo-{d}", .{group_index}) catch "gsolo", badgeX(block_x0, 0), controls_y, "S", soloed, theme.rhythm)) {
        app.core.doGroupToggle(group_index, true);
    }
    const muted = app.core.groupFlagState(group_index, false).all;
    if (drawTrackBadgeToggle(draw_list, std.fmt.bufPrintZ(&badge_id_buf, "group-mute-{d}", .{group_index}) catch "gmute", badgeX(block_x0, 1), controls_y, "M", muted, theme.danger)) {
        app.core.doGroupToggle(group_index, false);
    }
    drawTrackRowCursorOutline(chrome, height);
    // Matches drawMixerRow: the badges left the auto-layout cursor parked at
    // their own absolute position, so the next row has to be re-anchored or
    // it starts ~30px in and paints over the tail of this one.
    zgui.setCursorScreenPos(.{ origin[0], origin[1] + height });
}

fn drawMasterRow(app: anytype, height: f32) void {
    const chrome = drawRowChrome(app, "master-row", app.core.track_rows_len, false, height);
    const draw_list = chrome.draw;
    const origin = chrome.origin;
    const width = chrome.width;
    const selected = chrome.selected;
    const accent = theme.audio;

    drawSideStrip(draw_list, origin, height, accent, "M", .{});

    const text_x = origin[0] + strip_w + 13;
    draw_list.addText(.{ text_x, origin[1] + 5 }, color(if (selected) theme.fg0 else theme.modulation), "MASTER", .{});
    draw_list.addText(.{ text_x + 28, origin[1] + 23 }, color(theme.fg3), "[bus]", .{});

    const block_x0 = drawInfoBlockBg(draw_list, origin, width, height, accent);
    const block_fg = legibleOn(accent);
    drawFxChips(draw_list, &app.core.session.master_fx, text_x + 150, origin[1] + 12, block_x0 - 12);
    const center_y = origin[1] + (height - 2) / 2;
    // Master's bars are one px fatter than a track's; same centered stack.
    const master_meter_h: f32 = 2 * 5 + 3;
    const stack = stackTops(center_y, height, zgui.getTextLineHeight(), master_meter_h);
    draw_list.addText(.{ block_x0 + block_inset, stack.controls }, color(block_fg), "{d:.1} dB", .{app.core.master_gain_db});
    // meter_hold_db is refreshed once per frame by chrome.zig's transport
    // draw (always runs first, see app.zig's App.draw) - reusing it here
    // keeps this meter in sync with the transport's LEVEL readout instead
    // of re-deriving its own peak-hold state from the raw peak.
    widgets.solidMeterBar(draw_list, .{ block_x0 + block_inset, stack.meter }, app.meter_hold_db, block_w - 2 * block_inset, 5, 3, block_fg);
    drawTrackRowCursorOutline(chrome, height);
}

fn trackRowInVisual(core: anytype, display_row: usize) bool {
    if (core.modal.mode != .visual) return false;
    const anchor = core.tracks_visual_anchor orelse core.track_row;
    return display_row >= @min(anchor, core.track_row) and display_row <= @max(anchor, core.track_row);
}

fn drawTrackRowCursorUnderlay(draw_list: zgui.DrawList, origin: [2]f32, width: f32, height: f32) void {
    draw_list.addRectFilled(.{
        .pmin = .{ origin[0] + 1, origin[1] + 1 },
        .pmax = .{ rowRight(origin[0], width) - 1, origin[1] + height - 3 },
        .col = color(.{ theme.track_cursor[0], theme.track_cursor[1], theme.track_cursor[2], 0.18 }),
        .rounding = gui_style.item_rounding,
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
            rowRight(chrome.origin[0], chrome.width) - inset,
            chrome.origin[1] + height - 2 - inset,
        },
        .col = color(if (chrome.selected) theme.track_cursor else if (chrome.in_visual) theme.fg0 else theme.focus),
        .rounding = gui_style.item_rounding,
        .thickness = if (chrome.selected or chrome.in_visual) 2 else 1,
    });
}

/// A fixed-position 15x18 badge that's always present (unlike the old
/// state-gated one), dim when off and lit with `active_bg` when on -
/// clicking it toggles, returning whether this frame's click did.
fn drawTrackBadgeToggle(draw_list: zgui.DrawList, id: [:0]const u8, x: f32, y: f32, label: []const u8, active: bool, active_bg: [4]f32) bool {
    zgui.setCursorScreenPos(.{ x, y });
    _ = zgui.invisibleButton(id, .{ .w = badge_w, .h = badge_h });
    const activated = zgui.isItemActivated();
    const hovered = zgui.isItemHovered(.{});
    const bg = if (active) active_bg else if (hovered) theme.bg4 else theme.bg2;
    const fg = if (active) legibleOn(active_bg) else if (hovered) theme.fg1 else theme.fg3;
    draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + badge_w, y + badge_h }, .col = color(bg), .rounding = gui_style.item_rounding });
    const label_size = zgui.calcTextSize(label, .{});
    draw_list.addText(.{
        x + (badge_w - label_size[0]) / 2,
        y + (badge_h - label_size[1]) / 2,
    }, color(fg), "{s}", .{label});
    return activated;
}

fn drawFxChips(draw_list: zgui.DrawList, fx: *const ws.Fx, start_x: f32, y: f32, max_x: f32) void {
    var x = start_x;
    for (fx.units.items, 0..) |unit, index| {
        if (index == 4) {
            draw_list.addText(.{ x, y + 2 }, color(theme.fg3), "+{d}", .{fx.units.items.len - index});
            break;
        }
        const label = spectrum_ed.stripLabel(unit.kind());
        const chip_w = zgui.calcTextSize(label, .{})[0] + 12;
        if (x + chip_w > max_x) break;
        draw_list.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + chip_w, y + 20 }, .col = color(theme.bg2), .rounding = gui_style.item_rounding });
        draw_list.addText(.{ x + 6, y + 2 }, color(if (unit.bypassed) theme.fg3 else theme.audio), "{s}", .{label});
        x += chip_w + 4;
    }
}
