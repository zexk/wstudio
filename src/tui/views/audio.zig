const std = @import("std");
const ws = @import("wstudio");
const style = @import("../style.zig");
const waveform = @import("../../ui/waveform.zig");

const max_width = 160;

pub fn drawAudioEditor(app: anytype, w: *std.Io.Writer, rows: usize, cols: usize) !void {
    const body = rows -| 4;
    const track = app.session.project.tracks.items[app.audio_track];
    const lane = app.session.arrangement.lanes.items[app.audio_track];
    const selected = if (lane.clips.items.len == 0) null else &lane.clips.items[@min(app.audio_clip, lane.clips.items.len - 1)];

    try w.print(style.bcyn ++ style.bold ++ " AUDIO  " ++ style.rst ++ style.acc ++ "\"{s}\"" ++ style.rst ++ "  {d} region{s}", .{ track.name, lane.clips.items.len, if (lane.clips.items.len == 1) "" else "s" });
    try style.endLine(w);
    var written: usize = 1;

    if (selected) |clip| {
        const region = clip.content.audio;
        const source = app.session.project.audioSource(region.source_id);
        if (source) |src| {
            const channels: usize = @max(src.channel_count, 1);
            const start: usize = @intCast(@min(region.source_start_frame * channels, src.samples.len));
            const end_frame = @min(region.source_start_frame +| region.source_length_frames, src.samples.len / channels);
            const end: usize = @intCast(end_frame * channels);
            const width: usize = @min(cols -| 4, max_width);
            var peaks: [max_width]f32 = undefined;
            waveform.peakBucketsSampled(src.samples[start..end], peaks[0..width], 64);
            var peak: f32 = 0.000001;
            for (peaks[0..width]) |value| peak = @max(peak, value);
            for (0..@min(body -| 5, 8)) |row| {
                try w.writeAll("  ");
                const height: f32 = @floatFromInt(@min(body -| 5, 8));
                const center = height / 2.0;
                for (peaks[0..width]) |value| {
                    const distance = @abs(@as(f32, @floatFromInt(row)) + 0.5 - center);
                    try w.writeAll(if (distance <= value / peak * center) style.bcyn ++ "█" ++ style.rst else if (distance < 0.6) style.dim ++ "─" ++ style.rst else " ");
                }
                try style.endLine(w);
                written += 1;
            }
            const seconds = @as(f64, @floatFromInt(region.source_length_frames)) / @as(f64, @floatFromInt(@max(src.sample_rate, 1)));
            try w.print("  region {d}/{d}  {d:.2}s  {d} Hz  {d} ch  {s}", .{ @min(app.audio_clip, lane.clips.items.len - 1) + 1, lane.clips.items.len, seconds, src.sample_rate, src.channel_count, std.fs.path.basename(src.path) });
            try style.endLine(w);
            written += 1;
            const fade_in = @as(f64, @floatFromInt(region.fade_in_frames)) / @as(f64, @floatFromInt(@max(app.session.project.sample_rate, 1)));
            const fade_out = @as(f64, @floatFromInt(region.fade_out_frames)) / @as(f64, @floatFromInt(@max(app.session.project.sample_rate, 1)));
            try w.print("  gain {s}{d:.1} dB  stretch {d:.2}x  fade {d:.3}/{d:.3}s  reverse {s}  takes {d}", .{ if (region.gain_db >= 0) "+" else "", region.gain_db, region.stretch_ratio, fade_in, fade_out, if (region.reverse) "on" else "off", region.takeCount() });
            try style.endLine(w);
            written += 1;
        }
    } else {
        try w.writeAll(style.dim ++ "  NO AUDIO REGIONS" ++ style.rst);
        try style.endLine(w);
        written += 1;
    }
    const pan = if (@abs(track.pan) < 0.005) "C" else if (track.pan < 0) "L" else "R";
    try w.print("  track  gain {s}{d:.1} dB  pan {s}{d:.0}  mute {s}  solo {s}  arm {s}", .{ if (track.gain_db >= 0) "+" else "", track.gain_db, pan, @abs(track.pan) * 100, if (track.muted) "on" else "off", if (track.soloed) "on" else "off", if (app.session.isArmed(app.audio_track)) "on" else "off" });
    try style.endLine(w);
    written += 1;
    while (written < body) : (written += 1) try style.endLine(w);
}
