//! Transport: playhead position, tempo, and musical time.
//!
//! Owned and mutated exclusively by the audio thread; control threads
//! change it by sending engine commands.

const std = @import("std");
const time_map = @import("time_map.zig");

pub const max_tempo_points = time_map.max_tempo_points;
pub const max_meter_points = time_map.max_meter_points;

pub const TimeSignature = struct {
    beats_per_bar: u8 = 4,
    beat_unit: u8 = 4,
};

pub const BarBeat = struct { bar: u64, beat: u64 };

pub const Transport = struct {
    sample_rate: u32,
    tempo_bpm: f64 = 120.0,
    time_signature: TimeSignature = .{},
    tempo_points: [max_tempo_points]time_map.TempoPoint = undefined,
    tempo_point_count: u8 = 0,
    meter_points: [max_meter_points]time_map.MeterPoint = undefined,
    meter_point_count: u8 = 0,
    playing: bool = false,
    /// Absolute position in frames since project start.
    position_frames: u64 = 0,
    /// A/B loop region in frames. While enabled (and the region is non-empty),
    /// `advance` wraps positions reaching `loop_end_frames` back into the
    /// region - devices resync off the position jump like they do for a seek.
    loop_enabled: bool = false,
    loop_start_frames: u64 = 0,
    loop_end_frames: u64 = 0,

    pub fn framesPerBeat(self: *const Transport) f64 {
        const sample_rate = @max(self.sample_rate, 1);
        const tempo = self.currentTempo();
        return @as(f64, @floatFromInt(sample_rate)) * 60.0 / tempo;
    }

    pub fn framesPerStep(self: *const Transport, steps_per_beat: u8) f64 {
        return @max(1.0, self.framesPerBeat() / @as(f64, @floatFromInt(@max(steps_per_beat, 1))));
    }

    pub fn framesAtBeats(self: *const Transport, beats: f64) u64 {
        const frames = time_map.secondsAtBeat(self.tempoPoints(), self.tempo_bpm, beats) * @as(f64, @floatFromInt(@max(self.sample_rate, 1)));
        if (!std.math.isFinite(frames) or frames >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            return std.math.maxInt(u64);
        return @intFromFloat(frames);
    }

    pub fn positionBeats(self: *const Transport) f64 {
        return self.beatsAtFrames(self.position_frames);
    }

    pub fn beatsAtFrames(self: *const Transport, frames: u64) f64 {
        const seconds = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(@max(self.sample_rate, 1)));
        return time_map.beatAtSeconds(self.tempoPoints(), self.tempo_bpm, seconds);
    }

    pub fn positionSeconds(self: *const Transport) f64 {
        return @as(f64, @floatFromInt(self.position_frames)) / @as(f64, @floatFromInt(@max(self.sample_rate, 1)));
    }

    /// Bar/beat as shown in a position display (zero-based).
    pub fn positionBarBeat(self: *const Transport) BarBeat {
        return self.barBeatAtFrames(self.position_frames);
    }

    pub fn barBeatAtFrames(self: *const Transport, position_frames: u64) BarBeat {
        const target = self.beatsAtFrames(position_frames);
        if (!std.math.isFinite(target)) {
            const beats_per_bar: u64 = @max(self.time_signature.beats_per_bar, 1);
            return .{ .bar = std.math.maxInt(u64) / beats_per_bar, .beat = std.math.maxInt(u64) % beats_per_bar };
        }
        var segment_beat: f64 = 0;
        var bars: u64 = 0;
        var meter = time_map.MeterPoint{ .beat = 0, .numerator = @max(self.time_signature.beats_per_bar, 1), .denominator = @max(self.time_signature.beat_unit, 1) };
        for (self.meterPoints()) |point| {
            if (point.beat > target) break;
            const bar_beats = meter.quarterBeatsPerBar();
            const segment_bars = @max(0.0, @ceil((point.beat - segment_beat) / bar_beats));
            if (segment_bars >= @as(f64, @floatFromInt(std.math.maxInt(u64) - bars))) return .{ .bar = std.math.maxInt(u64), .beat = 0 };
            bars += @intFromFloat(segment_bars);
            segment_beat = point.beat;
            meter = point;
        }
        const bar_beats = meter.quarterBeatsPerBar();
        const within_segment = @max(target - segment_beat, 0.0);
        const segment_bars = @floor(within_segment / bar_beats);
        if (segment_bars >= @as(f64, @floatFromInt(std.math.maxInt(u64) - bars))) return .{ .bar = std.math.maxInt(u64), .beat = 0 };
        bars += @intFromFloat(segment_bars);
        const within_bar = @mod(within_segment, bar_beats);
        const beat_unit_quarters = 4.0 / @as(f64, @floatFromInt(meter.denominator));
        return .{ .bar = bars, .beat = @intFromFloat(@floor(within_bar / beat_unit_quarters)) };
    }

    pub fn tempoPoints(self: *const Transport) []const time_map.TempoPoint {
        return self.tempo_points[0..self.tempo_point_count];
    }

    pub fn meterPoints(self: *const Transport) []const time_map.MeterPoint {
        return self.meter_points[0..self.meter_point_count];
    }

    pub fn currentTempo(self: *const Transport) f64 {
        return time_map.tempoAt(self.tempoPoints(), self.tempo_bpm, self.positionBeats());
    }

    pub fn currentMeter(self: *const Transport) time_map.MeterPoint {
        return time_map.meterAt(self.meterPoints(), .{ .beat = 0, .numerator = @max(self.time_signature.beats_per_bar, 1), .denominator = @max(self.time_signature.beat_unit, 1) }, self.positionBeats());
    }

    pub fn beatAtBar(self: *const Transport, target_bar: u64) f64 {
        var segment_beat: f64 = 0;
        var bars: u64 = 0;
        var meter = time_map.MeterPoint{ .beat = 0, .numerator = @max(self.time_signature.beats_per_bar, 1), .denominator = @max(self.time_signature.beat_unit, 1) };
        for (self.meterPoints()) |point| {
            const bars_f = @ceil(@max(point.beat - segment_beat, 0.0) / meter.quarterBeatsPerBar());
            const segment_bars: u64 = if (bars_f >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) std.math.maxInt(u64) else @intFromFloat(bars_f);
            if (target_bar < bars +| segment_bars) return segment_beat + @as(f64, @floatFromInt(target_bar - bars)) * meter.quarterBeatsPerBar();
            bars +|= segment_bars;
            segment_beat = point.beat;
            meter = point;
        }
        return segment_beat + @as(f64, @floatFromInt(target_bar -| bars)) * meter.quarterBeatsPerBar();
    }

    pub fn setTempoPoint(self: *Transport, point: time_map.TempoPoint) void {
        insertPoint(&self.tempo_points, &self.tempo_point_count, point);
    }

    pub fn setMeterPoint(self: *Transport, point: time_map.MeterPoint) void {
        insertPoint(&self.meter_points, &self.meter_point_count, point);
    }

    /// Insert `point` into a beat-sorted fixed array, replacing whatever
    /// already sits on that exact beat. A full array drops the insert.
    fn insertPoint(points: anytype, count: *u8, point: anytype) void {
        var index: usize = 0;
        while (index < count.* and points[index].beat < point.beat) : (index += 1) {}
        if (index < count.* and points[index].beat == point.beat) {
            points[index] = point;
            return;
        }
        if (count.* == points.len) return;
        var i: usize = count.*;
        while (i > index) : (i -= 1) points[i] = points[i - 1];
        points[index] = point;
        count.* += 1;
    }

    /// Called once per processed block, after rendering it.
    pub fn advance(self: *Transport, frames: u32) void {
        if (!self.playing) return;
        self.position_frames +|= frames;
        if (self.loop_enabled and self.loop_end_frames > self.loop_start_frames and
            self.position_frames >= self.loop_end_frames)
        {
            const span = self.loop_end_frames - self.loop_start_frames;
            self.position_frames = self.loop_start_frames +
                (self.position_frames - self.loop_start_frames) % span;
        }
    }

    pub fn play(self: *Transport) void {
        self.playing = true;
    }

    pub fn stop(self: *Transport) void {
        self.playing = false;
    }

    pub fn seekFrames(self: *Transport, frames: u64) void {
        self.position_frames = frames;
    }
};

test "advance only moves while playing" {
    var t: Transport = .{ .sample_rate = 48_000 };
    t.advance(256);
    try std.testing.expectEqual(@as(u64, 0), t.position_frames);
    t.play();
    t.advance(256);
    try std.testing.expectEqual(@as(u64, 256), t.position_frames);
    t.stop();
    t.advance(256);
    try std.testing.expectEqual(@as(u64, 256), t.position_frames);
}

test "advance wraps inside an enabled loop region" {
    var t: Transport = .{ .sample_rate = 48_000 };
    t.loop_start_frames = 1_000;
    t.loop_end_frames = 2_000;
    t.loop_enabled = true;
    t.play();
    t.seekFrames(1_900);
    t.advance(256); // 2_156 → wraps to 1_000 + 156
    try std.testing.expectEqual(@as(u64, 1_156), t.position_frames);

    // Disabled loop plays straight through.
    t.loop_enabled = false;
    t.seekFrames(1_900);
    t.advance(256);
    try std.testing.expectEqual(@as(u64, 2_156), t.position_frames);
}

test "musical time at 120 bpm" {
    var t: Transport = .{ .sample_rate = 48_000 };
    t.play();
    // 120 bpm => 0.5 s/beat => 24_000 frames/beat
    try std.testing.expectApproxEqAbs(@as(f64, 24_000.0), t.framesPerBeat(), 1e-9);
    t.seekFrames(24_000 * 6); // 6 beats = bar 1, beat 2 in 4/4
    const pos = t.positionBarBeat();
    try std.testing.expectEqual(@as(u64, 1), pos.bar);
    try std.testing.expectEqual(@as(u64, 2), pos.beat);
}

test "beat conversion saturates extreme lengths" {
    const t: Transport = .{ .sample_rate = 48_000 };
    try std.testing.expectEqual(@as(u64, 24_000), t.framesAtBeats(1));
    try std.testing.expectEqual(std.math.maxInt(u64), t.framesAtBeats(std.math.floatMax(f64)));
}

test "invalid timing fields retain finite position calculations" {
    var t: Transport = .{ .sample_rate = 0, .tempo_bpm = std.math.nan(f64) };
    t.time_signature.beats_per_bar = 0;
    t.position_frames = 48_000;
    try std.testing.expect(std.math.isFinite(t.framesPerBeat()));
    try std.testing.expect(std.math.isFinite(t.framesPerStep(0)));
    try std.testing.expect(std.math.isFinite(t.positionBeats()));
    try std.testing.expect(std.math.isFinite(t.positionSeconds()));
    const pos = t.positionBarBeat();
    try std.testing.expectEqual(@as(u64, 96_000), pos.bar);
    try std.testing.expectEqual(@as(u64, 0), pos.beat);
}

test "position display saturates when beat count exceeds u64" {
    var t: Transport = .{
        .sample_rate = 1,
        .tempo_bpm = std.math.floatMax(f64),
        .position_frames = std.math.maxInt(u64),
    };
    const pos = t.positionBarBeat();
    try std.testing.expectEqual(std.math.maxInt(u64) / 4, pos.bar);
    try std.testing.expectEqual(std.math.maxInt(u64) % 4, pos.beat);

    const external = t.barBeatAtFrames(std.math.maxInt(u64));
    try std.testing.expectEqual(pos, external);
}

test "advance saturates at the frame counter limit" {
    var t: Transport = .{ .sample_rate = 48_000, .playing = true };
    t.position_frames = std.math.maxInt(u64) - 10;
    t.advance(256);
    try std.testing.expectEqual(std.math.maxInt(u64), t.position_frames);
}

test "far-future meter point does not overflow bar conversion" {
    var t: Transport = .{ .sample_rate = 48_000 };
    t.setMeterPoint(.{ .beat = std.math.floatMax(f64), .numerator = 3, .denominator = 4 });
    try std.testing.expectEqual(@as(f64, 4), t.beatAtBar(1));
}
