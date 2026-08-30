const std = @import("std");
const ws = @import("wstudio");
const App = @import("../app.zig").App;
const history = @import("../history.zig");
const spectrum = @import("fx_editor.zig");
const commands = @import("../commands.zig");

fn selectedRegion(app: *App) ?*ws.Clip.AudioRegion {
    if (app.audio_track >= app.session.arrangement.lanes.items.len) return null;
    const clips = app.session.arrangement.lanes.items[app.audio_track].clips.items;
    if (clips.len == 0) return null;
    app.audio_clip = @min(app.audio_clip, clips.len - 1);
    return &clips[app.audio_clip].content.audio;
}

/// Sample-index range (into an interleaved buffer of `channels` channels) a
/// region's frame range covers, clamped to what the source actually holds.
/// Clamping happens in *frame* units before multiplying by `channels` - a
/// hand-edited or corrupt project can carry `source_start_frame` up near
/// u64's max, and multiplying that by channels first overflows u64. Shared
/// by the GUI and TUI audio editors' own waveform slicing, which used to
/// reimplement this same arithmetic (and the same overflow) independently.
pub fn peakSampleRange(source_start_frame: u64, source_length_frames: u64, total_frames: u64, channels: u64) struct { start: usize, end: usize } {
    const start_frame = @min(source_start_frame, total_frames);
    const end_frame = @min(start_frame +| source_length_frames, total_frames);
    return .{ .start = @intCast(start_frame * channels), .end = @intCast(end_frame * channels) };
}

pub fn selectedPeakDb(app: *App) ?f32 {
    const region = selectedRegion(app) orelse return null;
    const source = app.session.project.audioSource(region.source_id) orelse return null;
    const channels: u64 = @max(source.channel_count, 1);
    const range = peakSampleRange(region.source_start_frame, region.source_length_frames, source.samples.len / channels, channels);
    var peak: f32 = 0;
    for (source.samples[range.start..range.end]) |sample| peak = @max(peak, @abs(sample));
    return ws.types.gainToDb(peak) + region.gain_db;
}

fn normalizedGainDb(source_peak_db: f32) f32 {
    return std.math.clamp(-source_peak_db, -60.0, 24.0);
}

pub fn normalizeSelected(app: *App) void {
    const output_peak_db = selectedPeakDb(app) orelse return;
    const region = selectedRegion(app) orelse return;
    const source_peak_db = output_peak_db - region.gain_db;
    const gain_db = normalizedGainDb(source_peak_db);
    if (gain_db == region.gain_db) {
        app.setStatus("region already normalized", .{});
        return;
    }
    history.recordLane(app, app.audio_track);
    region.gain_db = gain_db;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("region normalized to {d:.1} dBFS", .{source_peak_db + gain_db});
}

pub fn reverseSelected(app: *App) void {
    const region = selectedRegion(app) orelse return;
    history.recordLane(app, app.audio_track);
    region.reverse = !region.reverse;
    if (app.session.song_mode) app.session.rebuildSongData();
    app.dirty = true;
    app.setStatus("region reverse: {s}", .{if (region.reverse) "on" else "off"});
}

pub const MouseAction = enum { arrangement, fx, normalize, reverse, arm, import, previous, next };

pub fn mouseAction(right: bool, shift: bool, ctrl: bool, alt: bool) MouseAction {
    if (alt) return if (right) .next else .previous;
    if (ctrl) return if (right) .import else .arm;
    if (shift) return if (right) .reverse else .normalize;
    return if (right) .fx else .arrangement;
}

pub fn runMouseAction(app: *App, action: MouseAction) void {
    switch (action) {
        .arrangement => _ = handleKey(app, .{ .char = 'a' }),
        .fx => _ = handleKey(app, .{ .char = 'x' }),
        .normalize => normalizeSelected(app),
        .reverse => reverseSelected(app),
        .arm => _ = handleKey(app, .{ .char = 'r' }),
        .import => _ = handleKey(app, .{ .char = 'i' }),
        .previous => _ = handleKey(app, .{ .char = 'k' }),
        .next => _ = handleKey(app, .{ .char = 'j' }),
    }
}

pub fn handleMouse(app: *App, ev: ws.input.MouseEvent) void {
    switch (ev.kind) {
        .press => switch (ev.button) {
            .left, .right => runMouseAction(app, mouseAction(ev.button == .right, ev.shift, ev.ctrl, ev.alt)),
            else => {},
        },
        .scroll_up, .scroll_down => {
            const up = ev.kind == .scroll_up;
            const key: u8 = if (ev.ctrl)
                (if (up) '+' else '-')
            else if (ev.shift)
                (if (up) '>' else '<')
            else if (up)
                'k'
            else
                'j';
            _ = handleKey(app, .{ .char = key });
        },
        else => {},
    }
}

test "audio mouse bindings cover both buttons and modifiers" {
    try std.testing.expectEqual(MouseAction.arrangement, mouseAction(false, false, false, false));
    try std.testing.expectEqual(MouseAction.fx, mouseAction(true, false, false, false));
    try std.testing.expectEqual(MouseAction.normalize, mouseAction(false, true, false, false));
    try std.testing.expectEqual(MouseAction.reverse, mouseAction(true, true, false, false));
    try std.testing.expectEqual(MouseAction.arm, mouseAction(false, false, true, false));
    try std.testing.expectEqual(MouseAction.import, mouseAction(true, false, true, false));
    try std.testing.expectEqual(MouseAction.previous, mouseAction(false, false, false, true));
    try std.testing.expectEqual(MouseAction.next, mouseAction(true, false, false, true));
}

pub fn handleKey(app: *App, key: ws.input.Key) bool {
    const clips = if (app.audio_track < app.session.arrangement.lanes.items.len)
        app.session.arrangement.lanes.items[app.audio_track].clips.items
    else
        &.{};
    switch (key) {
        .escape, .tab => {
            app.view = .tracks;
            return true;
        },
        // Empty track has nothing to edit, so enter opens its browser -
        // same convention the slicer/soundfont editors' empty states use.
        .enter => {
            if (clips.len > 0) return false;
            app.openBrowser(.import_audio);
            return true;
        },
        .char => |c| switch (c) {
            'j' => {
                if (clips.len > 0) app.audio_clip = @min(app.audio_clip +| @as(usize, @intCast(app.takeCount())), clips.len - 1);
                return true;
            },
            'k' => {
                app.audio_clip -|= @as(usize, @intCast(app.takeCount()));
                return true;
            },
            'a' => {
                app.cursor = app.audio_track;
                app.view = .arrangement;
                app.autoSongMode(true);
                return true;
            },
            'i' => {
                app.openBrowser(.import_audio);
                return true;
            },
            'n' => {
                normalizeSelected(app);
                return true;
            },
            'v' => {
                reverseSelected(app);
                return true;
            },
            'x' => {
                spectrum.switchToTrack(app, app.audio_track);
                return true;
            },
            'r' => {
                app.doTrackArmToggle(app.audio_track);
                return true;
            },
            's' => {
                commands.run(app, "audio-to-sampler");
                return true;
            },
            'c' => {
                commands.run(app, "audio-to-slicer");
                return true;
            },
            '-' => {
                app.doTrackGainStep(app.audio_track, -1.0);
                return true;
            },
            '+', '=' => {
                app.doTrackGainStep(app.audio_track, 1.0);
                return true;
            },
            '<' => {
                app.doTrackPan(app.audio_track, -0.05);
                return true;
            },
            '>' => {
                app.doTrackPan(app.audio_track, 0.05);
                return true;
            },
            else => {},
        },
        else => {},
    }
    return false;
}

test "normalization gain lifts source peak to zero and respects region limits" {
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), normalizedGainDb(-6.0), 1e-6);
    try std.testing.expectEqual(@as(f32, 24.0), normalizedGainDb(-80.0));
    try std.testing.expectEqual(@as(f32, -6.0), normalizedGainDb(6.0));
}

test "peakSampleRange clamps an out-of-bounds source_start_frame instead of overflowing" {
    // A corrupt/hand-edited .wsj can carry a huge source_start_frame; load.zig
    // copies it through unclamped (unlike gain_db/stretch_ratio). Multiplying
    // it by channels before clamping (the old code) overflows u64 and panics.
    const r = peakSampleRange(std.math.maxInt(u64), 100, 1000, 2);
    try std.testing.expect(r.start <= r.end);
    try std.testing.expectEqual(@as(usize, 2000), r.start);
    try std.testing.expectEqual(@as(usize, 2000), r.end);

    const normal = peakSampleRange(10, 20, 1000, 2);
    try std.testing.expectEqual(@as(usize, 20), normal.start);
    try std.testing.expectEqual(@as(usize, 60), normal.end);
}
