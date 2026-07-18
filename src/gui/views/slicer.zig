const std = @import("std");
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
    var has_audio = true;
    if (slicer.sample_lock.tryLock()) {
        has_audio = slicer.samples.len > 0;
        slicer.sample_lock.unlock();
    }
    if (!has_audio) {
        drawEmptyState();
        return;
    }
    widgets.sectionTitle("SOURCE WAVEFORM", patina.audio);
    if (slicer.sample_lock.tryLock()) {
        defer slicer.sample_lock.unlock();
        drawSourceWaveform(app, slicer);
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

fn drawEmptyState() void {
    const available = zgui.getContentRegionAvail();
    const panel_width = @min(available[0], 520);
    const panel_height: f32 = 172;
    zgui.setCursorPos(.{
        zgui.getCursorPos()[0] + @max(0, (available[0] - panel_width) * 0.5),
        zgui.getCursorPos()[1] + @max(24, (available[1] - panel_height) * 0.36),
    });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = patina.bg2 });
    if (zgui.beginChild("slicer-empty-state", .{ .w = panel_width, .h = panel_height, .child_flags = .{ .border = true } })) {
        zgui.textColored(patina.audio, "LOAD AUDIO TO START SLICING", .{});
        zgui.separator();
        zgui.textDisabled("Choose a WAV file, then divide it into playable slices.", .{});
        zgui.spacing();
        zgui.textColored(patina.focus, ":load", .{});
        zgui.sameLine(.{ .spacing = 12 });
        zgui.text("open the audio browser", .{});
        zgui.spacing();
        zgui.textColored(patina.rhythm, ":slice <n>", .{});
        zgui.sameLine(.{ .spacing = 12 });
        zgui.text("create 1-64 equal slices", .{});
    }
    zgui.endChild();
    zgui.popStyleColor(.{});
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

// Terminal slicer views can only list slice bounds as numbers; drawing the
// actual waveform with every slice boundary overlaid, and letting a click
// jump the cursor to the slice under the mouse, is GUI-only.
fn drawSourceWaveform(app: anytype, slicer: *const ws.dsp.Slicer) void {
    if (slicer.samples.len == 0) {
        zgui.textDisabled("No sample loaded.", .{});
        return;
    }
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = std.math.clamp(zgui.getContentRegionAvail()[1] * 0.42, 180, 300);
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("##slicer-source-wave", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = style.color(patina.bg0), .rounding = 3 });

    var overview: [512]f32 = undefined;
    const count = @min(slicer.samples.len, overview.len);
    for (overview[0..count], 0..) |*out, i| {
        const s = i * slicer.samples.len / count;
        const e = @max(s + 1, (i + 1) * slicer.samples.len / count);
        var peak: f32 = 0;
        for (slicer.samples[s..@min(e, slicer.samples.len)]) |v| peak = @max(peak, @abs(v));
        out.* = peak;
    }
    const mid_y = origin[1] + height / 2;
    const selected: ?u8 = if (slicer.slice_count == 0) null else @min(app.core.slicer_cursor[0], slicer.slice_count - 1);

    if (selected) |index| {
        const slice = slicer.slices[index];
        draw_list.addRectFilled(.{
            .pmin = .{ origin[0] + slice.start_norm * width, origin[1] },
            .pmax = .{ origin[0] + slice.end_norm * width, origin[1] + height },
            .col = style.color(.{ patina.focus[0], patina.focus[1], patina.focus[2], 0.16 }),
        });
    }

    for (overview[0..count], 0..) |peak, i| {
        const x = origin[0] + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        const h = @max(1, peak * height / 2 * 0.94);
        draw_list.addLine(.{ .p1 = .{ x, mid_y - h }, .p2 = .{ x, mid_y + h }, .col = style.color(patina.audio), .thickness = 1 });
    }
    draw_list.addLine(.{ .p1 = .{ origin[0], mid_y }, .p2 = .{ origin[0] + width, mid_y }, .col = style.color(patina.line), .thickness = 1 });

    for (slicer.slices[0..slicer.slice_count], 0..) |slice, i| {
        const active = selected != null and selected.? == i;
        const x = origin[0] + slice.start_norm * width;
        draw_list.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + height }, .col = style.color(if (active) patina.focus else patina.rhythm), .thickness = if (active) 2 else 1 });
    }
    if (slicer.slice_count > 0) {
        const end_x = origin[0] + slicer.slices[slicer.slice_count - 1].end_norm * width;
        draw_list.addLine(.{ .p1 = .{ end_x, origin[1] }, .p2 = .{ end_x, origin[1] + height }, .col = style.color(patina.rhythm), .thickness = 1 });
    }

    if (hovered and zgui.isMouseClicked(.left)) {
        const norm = std.math.clamp((mouse[0] - origin[0]) / width, 0, 1);
        for (slicer.slices[0..slicer.slice_count], 0..) |slice, i| {
            if (norm >= slice.start_norm and norm < slice.end_norm) {
                app.core.slicer_cursor[0] = @intCast(i);
                break;
            }
        }
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
