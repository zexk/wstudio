const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const patina = &style.palette;

pub fn draw(app: anytype) void {
    const track = app.core.soundfont_track;
    if (track >= app.core.session.racks.items.len) return;
    const sf = switch (app.core.session.racks.items[track].instrument) {
        .soundfont => |*s| s,
        else => {
            zgui.textDisabled("Select a SoundFont track.", .{});
            return;
        },
    };

    drawHeader(app, track, sf);
    zgui.spacing();

    if (sf.presetCount() == 0) {
        widgets.sectionTitle("FONT", patina.audio);
        zgui.spacing();
        if (widgets.emptyState(.{
            .id = "soundfont-empty-state",
            .title = "LOAD A SOUNDFONT",
            .explanation = "Choose a .sf2 file to play its presets on this track.",
            .shortcut = ":load",
            .action = "LOAD SOUNDFONT",
            .accent = patina.audio,
        })) widgets.openLoadCommand(app);
        return;
    }

    widgets.sectionTitle("PROGRAM", patina.rhythm);
    drawPresetRow(app, track, sf);
    zgui.spacing();

    widgets.sectionTitle("OUT", patina.focus);
    drawParam(app, track, sf, 0, "Gain", "%.2f");
    drawParam(app, track, sf, 1, "Pan", widgets.pan_cfmt);
    drawParam(app, track, sf, 2, "Transpose", "%.0f st");
}

fn drawHeader(app: anytype, track: u16, sf: *const ws.dsp.SoundfontPlayer) void {
    zgui.textDisabled(icons.soundfont ++ "  SOUNDFONT", .{});
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{app.core.session.project.tracks.items[track].name});
    if (sf.presetCount() > 0) {
        zgui.sameLine(.{});
        zgui.textColored(patina.focus, "\"{s}\"", .{sf.presetName()});
    }
}

fn drawPresetRow(app: anytype, track: u16, sf: *ws.dsp.SoundfontPlayer) void {
    const count = sf.presetCount();
    const idx = sf.preset_index;
    const focused = app.core.soundfont_param == 3;
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (focused) patina.focus else patina.fg2 });
    zgui.text("{s}  ({d}/{d})", .{ sf.presetName(), idx + 1, count });
    zgui.popStyleColor(.{ .count = 1 });
    if (sf.presetBankProgram()) |bp| {
        zgui.textDisabled("bank {d}  prog {d}", .{ bp.bank, bp.program });
        if (sf.presetKeyRange()) |kr| {
            var lo_buf: [5]u8 = undefined;
            var hi_buf: [5]u8 = undefined;
            zgui.sameLine(.{ .spacing = 14 });
            zgui.textDisabled("keys {s}-{s}  ({d} region{s})", .{
                ws.midi.noteName(@intCast(@min(kr.lo, 127)), &lo_buf),
                ws.midi.noteName(@intCast(@min(kr.hi, 127)), &hi_buf),
                kr.region_count,
                if (kr.region_count == 1) "" else "s",
            });
        }
    }
    if (zgui.button("< PREV", .{ .w = 90, .h = 28 })) {
        app.core.soundfont_param = 3;
        const prev: u16 = if (idx == 0) @intCast(count - 1) else idx - 1;
        setParam(app, track, 3, @floatFromInt(prev));
    }
    zgui.sameLine(.{});
    if (zgui.button("NEXT >", .{ .w = 90, .h = 28 })) {
        app.core.soundfont_param = 3;
        const next: u16 = if (idx + 1 >= count) 0 else idx + 1;
        setParam(app, track, 3, @floatFromInt(next));
    }
}

fn setParam(app: anytype, track: u16, id: u8, value: f32) void {
    _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = track, .id = id, .value = value } });
    app.core.dirty = true;
}

fn paramRange(id: u8) [2]f32 {
    if (ws.dsp.SoundfontPlayer.findAutomatableParam(id)) |param| return param.range;
    return .{ 0, 1 };
}

fn drawParam(app: anytype, track: u16, sf: *ws.dsp.SoundfontPlayer, id: u8, label_text: []const u8, format: [:0]const u8) void {
    var value = sf.paramValue(id) orelse return;
    const range = paramRange(id);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##soundfont-{d}", .{ label_text, id }) catch return;
    const focused = app.core.soundfont_param == id;
    const result = widgets.paramKnob(label_text, label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = format, .accent = patina.focus, .focused = focused });
    if (result.changed) setParam(app, track, id, value);
    if (result.activated) app.core.soundfont_param = id;
}
