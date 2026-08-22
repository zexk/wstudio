const std = @import("std");
const ws = @import("wstudio");
const gui_style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const waveform = @import("../../ui/waveform.zig");
const icons = @import("../../ui/icons.zig");
const audio_ed = @import("../../ui/editors/audio.zig");
const zgui = @import("zgui");

const theme = &gui_style.palette;

pub fn draw(app: anytype) void {
    const core = &app.core;
    if (core.audio_track >= core.session.project.tracks.items.len or core.audio_track >= core.session.arrangement.lanes.items.len) return;
    const clips = core.session.arrangement.lanes.items[core.audio_track].clips.items;
    if (clips.len == 0) {
        zgui.textDisabled("No audio regions. Press i to import audio.", .{});
        return;
    }
    core.audio_clip = @min(core.audio_clip, clips.len - 1);
    const clip = clips[core.audio_clip];
    const region = clip.content.audio;
    const source = core.session.project.audioSource(region.source_id) orelse return;
    const channels: usize = @max(source.channel_count, 1);
    const start: usize = @intCast(@min(region.source_start_frame * channels, source.samples.len));
    const end_frame = @min(region.source_start_frame +| region.source_length_frames, source.samples.len / channels);
    const end: usize = @intCast(end_frame * channels);
    drawWaveform(app, source.samples[start..end]);

    const seconds = @as(f64, @floatFromInt(region.source_length_frames)) / @as(f64, @floatFromInt(@max(source.sample_rate, 1)));
    zgui.text("Region {d}/{d}   {s}", .{ core.audio_clip + 1, clips.len, std.fs.path.basename(source.path) });
    zgui.textDisabled("{d:.2}s   {d} Hz   {d} channels   peak {d:.1} dBFS   gain {s}{d:.1} dB   stretch {d:.2}x   takes {d}", .{ seconds, source.sample_rate, source.channel_count, audio_ed.selectedPeakDb(core) orelse -120, if (region.gain_db >= 0) "+" else "", region.gain_db, region.stretch_ratio, region.takeCount() });
    zgui.spacing();
    if (widgets.iconButton(icons.left ++ "##audio-prev", "Previous region  k")) core.handleKey(.{ .char = 'k' }, core.now_ns);
    zgui.sameLine(.{});
    if (widgets.iconButton(icons.right ++ "##audio-next", "Next region  j")) core.handleKey(.{ .char = 'j' }, core.now_ns);
    zgui.sameLine(.{});
    if (zgui.button("Arrangement", .{})) core.handleKey(.{ .char = 'a' }, core.now_ns);
    zgui.sameLine(.{});
    if (zgui.button("Import audio", .{})) core.handleKey(.{ .char = 'i' }, core.now_ns);
    zgui.sameLine(.{});
    if (zgui.button("Normalize", .{})) audio_ed.normalizeSelected(core);
    zgui.sameLine(.{});
    if (zgui.button(if (region.reverse) "Forward" else "Reverse", .{})) audio_ed.reverseSelected(core);
    zgui.sameLine(.{});
    if (zgui.button("Track FX", .{})) core.handleKey(.{ .char = 'x' }, core.now_ns);
}

const WaveformAction = enum { arrangement, fx, normalize, reverse, arm, import, previous, next };

fn waveformAction(right: bool, shift: bool, ctrl: bool, alt: bool) WaveformAction {
    if (alt) return if (right) .next else .previous;
    if (ctrl) return if (right) .import else .arm;
    if (shift) return if (right) .reverse else .normalize;
    return if (right) .fx else .arrangement;
}

test "audio waveform mouse bindings cover both buttons and modifiers" {
    try std.testing.expectEqual(WaveformAction.arrangement, waveformAction(false, false, false, false));
    try std.testing.expectEqual(WaveformAction.fx, waveformAction(true, false, false, false));
    try std.testing.expectEqual(WaveformAction.normalize, waveformAction(false, true, false, false));
    try std.testing.expectEqual(WaveformAction.reverse, waveformAction(true, true, false, false));
    try std.testing.expectEqual(WaveformAction.arm, waveformAction(false, false, true, false));
    try std.testing.expectEqual(WaveformAction.import, waveformAction(true, false, true, false));
    try std.testing.expectEqual(WaveformAction.previous, waveformAction(false, false, false, true));
    try std.testing.expectEqual(WaveformAction.next, waveformAction(true, false, false, true));
}

fn drawWaveform(app: anytype, samples: []const f32) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 240;
    const origin = zgui.getCursorScreenPos();
    const left_clicked = zgui.invisibleButton("##audio-waveform", .{ .w = width, .h = height, .flags = .{ .mouse_button_left = true, .mouse_button_right = true } });
    const hovered = zgui.isItemHovered(.{});
    const right_clicked = hovered and zgui.isMouseClicked(.right);
    if (hovered) zgui.setMouseCursor(.hand);
    if (left_clicked or right_clicked) switch (waveformAction(
        right_clicked,
        zgui.isKeyDown(.mod_shift),
        zgui.isKeyDown(.mod_ctrl),
        zgui.isKeyDown(.mod_alt),
    )) {
        .arrangement => app.core.handleKey(.{ .char = 'a' }, app.core.now_ns),
        .fx => app.core.handleKey(.{ .char = 'x' }, app.core.now_ns),
        .normalize => audio_ed.normalizeSelected(&app.core),
        .reverse => audio_ed.reverseSelected(&app.core),
        .arm => app.core.handleKey(.{ .char = 'r' }, app.core.now_ns),
        .import => app.core.handleKey(.{ .char = 'i' }, app.core.now_ns),
        .previous => app.core.handleKey(.{ .char = 'k' }, app.core.now_ns),
        .next => app.core.handleKey(.{ .char = 'j' }, app.core.now_ns),
    };
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = gui_style.color(theme.bg0), .rounding = gui_style.panel_rounding });
    if (samples.len == 0) return;
    var peaks: [2048]f32 = undefined;
    const count: usize = @min(@min(samples.len, peaks.len), @as(usize, @intFromFloat(@max(width, 1))));
    waveform.peakBucketsSampled(samples, peaks[0..count], 64);
    var peak: f32 = 0.000001;
    for (peaks[0..count]) |value| peak = @max(peak, value);
    const mid = origin[1] + height / 2;
    for (peaks[0..count], 0..) |value, i| {
        const x = origin[0] + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        const h = value / peak * height * 0.46;
        draw_list.addLine(.{ .p1 = .{ x, mid - h }, .p2 = .{ x, mid + h }, .col = gui_style.color(theme.audio), .thickness = 1 });
    }
}
