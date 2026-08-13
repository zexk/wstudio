const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const step_grid = @import("step_grid.zig");
const commands = @import("../../ui/commands.zig");

const theme = &style.palette;

pub fn draw(app: anytype) void {
    const track = app.core.slicer_track;
    if (track >= app.core.session.racks.items.len) return;
    const rack = app.core.session.racks.items[track];
    const slicer = switch (rack.instrument) {
        .slicer => |*s| s,
        else => {
            zgui.textDisabled("Select a Slicer track.", .{});
            return;
        },
    };
    drawHeader(app, slicer);
    zgui.spacing();
    if (!slicer.hasAudio()) {
        drawEmptyState(app);
        return;
    }
    drawSliceState(app, slicer);
    zgui.spacing();
    widgets.sectionTitle("SLICE SEQUENCE", theme.focus);
    const snap = app.core.session.engine.uiSnapshot();
    const play_step: ?usize = if (snap.playing) slicer.currentStep() else null;
    step_grid.draw(
        .slicer,
        app,
        slicer,
        slicer.slice_count,
        slicer.step_count,
        app.core.slicer_grid.ticks(),
        play_step,
        &app.core.slicer_cursor,
        if (app.core.modal.mode == .visual) app.core.slicer_visual_anchor else null,
        app.core.slicer_visual_slice_anchor,
        &app.core.slicer_paint_state,
    );
}

fn drawEmptyState(app: anytype) void {
    const available = zgui.getContentRegionAvail();
    zgui.setCursorPos(.{
        zgui.getCursorPos()[0],
        zgui.getCursorPos()[1] + @max(24, (available[1] - 122) * 0.36),
    });
    if (widgets.emptyState(.{
        .id = "slicer-empty-state",
        .title = "LOAD AUDIO TO START SLICING",
        .explanation = "Choose a WAV file, then divide it into playable slices.",
        .shortcut = ":load",
        .action = "LOAD AUDIO",
        .accent = theme.audio,
    })) widgets.openLoadCommand(app);
}

fn drawHeader(app: anytype, slicer: *const ws.dsp.Slicer) void {
    widgets.viewTitle(icons.slicer ++ "  SLICER", .{});
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{app.core.session.project.tracks.items[app.core.slicer_track].name});
    zgui.sameLine(.{});
    zgui.textDisabled("\"{s}\"  slices {d}", .{ slicer.clipName(), slicer.slice_count });
    zgui.sameLine(.{});
    zgui.textColored(theme.audio, "pat {c}", .{'A' + slicer.variant});
    if (slicer.variant_count > 1) {
        zgui.sameLine(.{});
        zgui.textDisabled("{d}/{d}", .{ slicer.variant + 1, slicer.variant_count });
        zgui.sameLine(.{ .spacing = 8 });
        if (widgets.iconButton(icons.prev ++ "##slicer-variant-prev", "Previous pattern  [")) app.core.handleKey(.{ .char = '[' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
        zgui.sameLine(.{ .spacing = 4 });
        if (widgets.iconButton(icons.next ++ "##slicer-variant-next", "Next pattern  ]")) app.core.handleKey(.{ .char = ']' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
}

fn drawSliceState(app: anytype, slicer: *const ws.dsp.Slicer) void {
    if (slicer.slice_count == 0) {
        zgui.textDisabled("No slices yet.", .{});
        zgui.sameLine(.{ .spacing = 12 });
        if (zgui.button("8 EQUAL SLICES", .{})) commands.run(&app.core, "slice 8");
        zgui.sameLine(.{ .spacing = 6 });
        if (zgui.button("DETECT TRANSIENTS", .{})) commands.run(&app.core, "chop");
        return;
    }
    const index = @min(app.core.slicer_cursor[0], slicer.slice_count - 1);
    const slice = slicer.slices[index];
    widgets.coloredValue(theme.audio, "SLICE {d:0>2}", .{index + 1});
    zgui.sameLine(.{ .spacing = 18 });
    zgui.text("region {d:.1}-{d:.1}%   pitch {d:.1} st   stretch {d:.2}x   gain {d:.2}   pan {d:.2}", .{ slice.start_norm * 100, slice.end_norm * 100, slice.pitch_semitones, slice.stretch_ratio, slice.gain, slice.pan });
    zgui.sameLine(.{ .spacing = 18 });
    zgui.textColored(if (slice.reverse) theme.modulation else theme.fg3, "{s}   choke {d}", .{ if (slice.reverse) "REVERSE" else "FORWARD", slicer.choke_group[index] });
}
