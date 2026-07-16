const std = @import("std");
const ws = @import("wstudio");
const zgui = @import("zgui");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const step_grid = @import("step_grid.zig");

const color = style.color;
const umbra = style.umbra;

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
    widgets.sectionTitle("SOURCE WAVEFORM", umbra.cyan);
    if (slicer.sample_lock.tryLock()) {
        defer slicer.sample_lock.unlock();
        widgets.waveform("##slicer-wave", slicer.samples);
    }
    zgui.spacing();
    drawSliceState(app, slicer);
    zgui.spacing();
    widgets.sectionTitle("SLICE SEQUENCE", umbra.iris);
    const snap = app.core.session.engine.uiSnapshot();
    const play_step: ?usize = if (snap.playing) slicer.currentStep() else null;
    step_grid.draw(
        .slicer,
        slicer,
        slicer.slice_count,
        slicer.step_count,
        play_step,
        &app.core.slicer_cursor,
        if (app.core.modal.mode == .visual) app.core.slicer_visual_anchor else null,
    );
}

fn drawHeader(app: anytype, slicer: *const ws.dsp.Slicer) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 72;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("slicer-header", .{ .w = width, .h = height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg2), .rounding = 4 });
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(umbra.cyan), .rounding = 3 });
    draw_list.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "SAMPLE SLICER", .{});
    draw_list.addText(.{ origin[0] + 17, origin[1] + 35 }, color(umbra.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.slicer_track].name});
    draw_list.addText(.{ origin[0] + width - 310, origin[1] + 12 }, color(umbra.cyan), "{d} SLICES", .{slicer.slice_count});
    draw_list.addText(.{ origin[0] + width - 190, origin[1] + 12 }, color(umbra.fg1), "{d} STEPS", .{slicer.step_count});
    draw_list.addText(.{ origin[0] + width - 310, origin[1] + 39 }, color(umbra.fg3), "{s}", .{std.mem.trimEnd(u8, &slicer.name, " ")});
    draw_list.addText(.{ origin[0] + width - 190, origin[1] + 39 }, color(umbra.fg3), "{s} {c}  {d:.0}% swing", .{ if (slicer.song_mode) "song" else "pattern", 'A' + slicer.variant, slicer.swing.load(.monotonic) });
}

fn drawSliceState(app: anytype, slicer: *const ws.dsp.Slicer) void {
    if (slicer.slice_count == 0) {
        zgui.textDisabled("No slices. Load audio and create slices from the command palette.", .{});
        return;
    }
    const index = @min(app.core.slicer_cursor[0], slicer.slice_count - 1);
    const slice = slicer.slices[index];
    zgui.textColored(umbra.cyan, "SLICE {d:0>2}", .{index + 1});
    zgui.sameLine(.{ .spacing = 18 });
    zgui.text("region {d:.1}-{d:.1}%   pitch {d:.1} st   gain {d:.2}   pan {d:.2}", .{ slice.start_norm * 100, slice.end_norm * 100, slice.pitch_semitones, slice.gain, slice.pan });
    zgui.sameLine(.{ .spacing = 18 });
    zgui.textColored(if (slice.reverse) umbra.mauve else umbra.fg3, "{s}   choke {d}", .{ if (slice.reverse) "REVERSE" else "FORWARD", slicer.choke_group[index] });
}
