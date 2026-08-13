//! Drum machine grid: title strip plus the shared step-grid renderer.

const std = @import("std");
const ws = @import("wstudio");
const icons = @import("../../ui/icons.zig");
const gui_style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const step_grid = @import("step_grid.zig");
const zgui = @import("zgui");

const theme = &gui_style.palette;

pub fn draw(app: anytype) void {
    const track = app.core.drum_track;
    if (track >= app.core.session.racks.items.len) return;
    const rack = app.core.session.racks.items[track];
    const drum = switch (rack.instrument) {
        .drum_machine => |*d| d,
        else => {
            zgui.textDisabled("Select a Drum Machine track.", .{});
            return;
        },
    };
    const snap = app.core.session.engine.uiSnapshot();
    const play_step: ?usize = if (snap.playing) drum.currentStep() else null;
    drawTitle(app, drum);
    zgui.spacing();
    step_grid.draw(
        .drum,
        app,
        drum,
        drum.pads.len,
        drum.step_count,
        app.core.drum_grid.ticks(),
        play_step,
        &app.core.drum_cursor,
        if (app.core.modal.mode == .visual) app.core.drum_visual_anchor else null,
        app.core.drum_visual_pad_anchor,
        &app.core.drum_paint_state,
    );
}

fn drawTitle(app: anytype, drum: *const ws.dsp.DrumMachine) void {
    widgets.viewTitle(icons.drum ++ "  DRUMS", .{});
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{app.core.session.project.tracks.items[app.core.drum_track].name});
    zgui.sameLine(.{});
    zgui.textColored(theme.rhythm, "Pattern {c}", .{'A' + drum.variant});
    zgui.sameLine(.{});
    zgui.textDisabled("Variation {d}/{d}", .{ drum.variant + 1, drum.variant_count });
    zgui.sameLine(.{ .spacing = 8 });
    zgui.beginDisabled(.{ .disabled = drum.variant_count <= 1 });
    if (widgets.iconButton(icons.prev ++ "##drum-variant-prev", "Previous variation  [")) app.core.handleKey(.{ .char = '[' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    zgui.sameLine(.{ .spacing = 4 });
    if (widgets.iconButton(icons.next ++ "##drum-variant-next", "Next variation  ]")) app.core.handleKey(.{ .char = ']' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    zgui.endDisabled();
}
