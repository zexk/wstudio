const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const format = @import("../../ui/format.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const theme = &style.palette;

pub fn draw(app: anytype) void {
    const track = app.core.soundfont_track;
    if (track >= app.core.session.racks.items.len) return;
    const is_acoustic = app.core.session.racks.items[track].instrument == .acoustic;
    const sf = switch (app.core.session.racks.items[track].instrument) {
        .soundfont, .acoustic => |*s| s,
        else => {
            zgui.textDisabled("Select a SoundFont track", .{});
            return;
        },
    };

    if (sf.presetCount() == 0) {
        // Acoustic only reaches this state when the bundled asset directory
        // couldn't be read, so it points at the bank picker, not a browser.
        widgets.sectionTitle(if (is_acoustic) icons.soundfont ++ "  BANK" else icons.soundfont ++ "  FONT", theme.audio);
        zgui.spacing();
        if (is_acoustic) {
            _ = widgets.emptyState(.{
                .id = "acoustic-empty-state",
                .title = "NO BANK LOADED",
                .explanation = "The bundled instrument library could not be read from disk.",
                .shortcut = "f",
                .action = "",
                .accent = theme.audio,
            });
            return;
        }
        if (widgets.emptyState(.{
            .id = "soundfont-empty-state",
            .title = "NO SOUNDFONT LOADED",
            .explanation = "Choose a .sf2 file to play its presets on this track.",
            .shortcut = ":load",
            .action = "LOAD SOUNDFONT",
            .accent = theme.audio,
        })) widgets.openLoadCommand(app);
        return;
    }

    const available = zgui.getContentRegionAvail()[0];
    const panel_width = @min(available, 900);
    zgui.setCursorPosX(zgui.getCursorPos()[0] + @max(0, (available - panel_width) * 0.5));
    if (zgui.beginChild("soundfont-panel", .{ .w = panel_width, .h = 0, .child_flags = .{ .border = true, .auto_resize_y = true }, .window_flags = .{ .no_scrollbar = true } })) {
        // OUT before PROGRAM: the same order the TUI draws, which is also
        // the order `soundfont_param` steps through under j/k (gain, pan,
        // transpose, then preset).
        widgets.sectionTitle(icons.audio ++ "  OUT", theme.focus);
        drawParam(app, track, sf, 0, "Gain", "%.2f");
        zgui.sameLine(.{ .spacing = 28 });
        drawParam(app, track, sf, 1, "Pan", format.pan_cfmt);
        zgui.sameLine(.{ .spacing = 28 });
        drawParam(app, track, sf, 2, "Transpose", "%.0f st");
        zgui.spacing();

        widgets.sectionTitle(icons.instrument ++ "  PROGRAM", theme.rhythm);
        drawPresetRow(app, track, sf);
        zgui.spacing();
    }
    zgui.endChild();
}

fn drawPresetRow(app: anytype, track: u16, sf: *ws.dsp.SoundfontPlayer) void {
    const count = sf.presetCount();
    const idx = sf.preset_index;
    const focused = app.core.soundfont_param == 3;
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (focused) theme.focus else theme.fg2 });
    widgets.valueText("{s}  ({d}/{d})", .{ sf.presetName(), idx + 1, count });
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
    if (widgets.iconButton(icons.prev ++ "##soundfont-preset-prev", "Previous preset  h")) {
        app.core.soundfont_param = 3;
        const prev: u16 = if (idx == 0) @intCast(count - 1) else idx - 1;
        setParam(app, track, 3, @floatFromInt(prev));
    }
    zgui.sameLine(.{});
    if (widgets.iconButton(icons.next ++ "##soundfont-preset-next", "Next preset  l")) {
        app.core.soundfont_param = 3;
        const next: u16 = if (idx + 1 >= count) 0 else idx + 1;
        setParam(app, track, 3, @floatFromInt(next));
    }
    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.button("Browse presets", .{})) app.core.handleKey(.{ .char = 'f' }, app.core.now_ns);
    zgui.sameLine(.{ .spacing = 8 });
    if (widgets.iconButton(icons.play ++ "##soundfont-preview", "Preview preset  a")) {
        app.core.handleKey(.{ .char = 'a' }, app.core.now_ns);
    }
}

fn setParam(app: anytype, track: u16, id: u8, value: f32) void {
    app.recordInstrumentEdit(track, id);
    _ = app.core.session.engine.setTrackParam(track, id, value);
    app.core.dirty = true;
}

fn paramRange(id: u8) [2]f32 {
    if (ws.dsp.SoundfontPlayer.findAutomatableParam(id)) |param| return param.range;
    return .{ 0, 1 };
}

fn drawParam(app: anytype, track: u16, sf: *ws.dsp.SoundfontPlayer, id: u8, label_text: []const u8, cfmt: [:0]const u8) void {
    var value = sf.paramValue(id) orelse return;
    const range = paramRange(id);
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##soundfont-{d}", .{ label_text, id }) catch return;
    const focused = app.core.soundfont_param == id;
    const result = widgets.paramKnob(label_text, label, .{ .v = &value, .min = range[0], .max = range[1], .cfmt = cfmt, .accent = theme.focus, .focused = focused });
    if (result.changed) setParam(app, track, id, value);
    if (result.activated) app.core.soundfont_param = id;
}
