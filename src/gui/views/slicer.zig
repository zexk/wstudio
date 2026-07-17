const ws = @import("wstudio");
const zgui = @import("zgui");
const icons = @import("../../ui/icons.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const step_grid = @import("step_grid.zig");

const patina = &style.palette;

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
    widgets.sectionTitle("SOURCE WAVEFORM", patina.audio);
    if (slicer.sample_lock.tryLock()) {
        defer slicer.sample_lock.unlock();
        widgets.waveform("##slicer-wave", slicer.samples);
    }
    zgui.spacing();
    drawSliceState(app, slicer);
    zgui.spacing();
    widgets.sectionTitle("SLICE SEQUENCE", patina.focus);
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
    const slices_per_bank = 8;
    const bank_count = if (slicer.slice_count == 0) 1 else (slicer.slice_count + slices_per_bank - 1) / slices_per_bank;
    zgui.textDisabled(icons.slicer ++ "  SLICER", .{});
    zgui.sameLine(.{});
    zgui.text("\"{s}\"", .{app.core.session.project.tracks.items[app.core.slicer_track].name});
    zgui.sameLine(.{});
    zgui.textDisabled("\"{s}\"  slices {d}", .{ slicer.clipName(), slicer.slice_count });
    zgui.sameLine(.{});
    zgui.textColored(patina.audio, "pat {c}", .{'A' + slicer.variant});
    if (slicer.variant_count > 1) {
        zgui.sameLine(.{});
        zgui.textDisabled("{d}/{d}", .{ slicer.variant + 1, slicer.variant_count });
    }
    if (bank_count > 1) {
        zgui.sameLine(.{});
        zgui.textDisabled("bank {d}/{d}", .{ app.core.slicer_cursor[0] / slices_per_bank + 1, bank_count });
    }
}

fn drawSliceState(app: anytype, slicer: *const ws.dsp.Slicer) void {
    if (slicer.slice_count == 0) {
        zgui.textDisabled("No slices. Load audio and create slices from the command palette.", .{});
        return;
    }
    const index = @min(app.core.slicer_cursor[0], slicer.slice_count - 1);
    const slice = slicer.slices[index];
    zgui.textColored(patina.audio, "SLICE {d:0>2}", .{index + 1});
    zgui.sameLine(.{ .spacing = 18 });
    zgui.text("region {d:.1}-{d:.1}%   pitch {d:.1} st   gain {d:.2}   pan {d:.2}", .{ slice.start_norm * 100, slice.end_norm * 100, slice.pitch_semitones, slice.gain, slice.pan });
    zgui.sameLine(.{ .spacing = 18 });
    zgui.textColored(if (slice.reverse) patina.modulation else patina.fg3, "{s}   choke {d}", .{ if (slice.reverse) "REVERSE" else "FORWARD", slicer.choke_group[index] });
}
