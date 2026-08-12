const std = @import("std");

pub const max_tempo_points = 64;
pub const max_meter_points = 64;

pub const TempoPoint = struct {
    beat: f64,
    bpm: f64,
    ramp_to_next: bool = false,
};

pub const MeterPoint = struct {
    beat: f64,
    numerator: u8,
    denominator: u8,

    pub fn quarterBeatsPerBar(self: MeterPoint) f64 {
        return @as(f64, @floatFromInt(self.numerator)) * 4.0 / @as(f64, @floatFromInt(self.denominator));
    }
};

fn safeTempo(bpm: f64) f64 {
    return if (std.math.isFinite(bpm) and bpm > 0) bpm else 120.0;
}

fn segmentSeconds(start_bpm: f64, end_bpm: f64, total_beats: f64, elapsed_beats: f64, ramp: bool) f64 {
    if (!ramp or start_bpm == end_bpm) return elapsed_beats * 60.0 / start_bpm;
    const slope = (end_bpm - start_bpm) / total_beats;
    return 60.0 / slope * @log((start_bpm + slope * elapsed_beats) / start_bpm);
}

pub fn secondsAtBeat(points: []const TempoPoint, default_bpm: f64, target_beat: f64) f64 {
    const target = if (std.math.isNan(target_beat) or target_beat <= 0) 0 else target_beat;
    var beat: f64 = 0;
    var bpm = safeTempo(default_bpm);
    var seconds: f64 = 0;
    for (points, 0..) |point, i| {
        if (point.beat > target) break;
        if (point.beat > beat) seconds += (point.beat - beat) * 60.0 / bpm;
        beat = point.beat;
        bpm = safeTempo(point.bpm);
        const next_beat = if (i + 1 < points.len) points[i + 1].beat else target;
        const end = @min(target, next_beat);
        if (end > beat) {
            const next_bpm = if (i + 1 < points.len) safeTempo(points[i + 1].bpm) else bpm;
            seconds += segmentSeconds(bpm, next_bpm, next_beat - beat, end - beat, point.ramp_to_next and next_beat > beat);
            beat = end;
        }
        if (beat >= target) return seconds;
    }
    return seconds + (target - beat) * 60.0 / bpm;
}

pub fn beatAtSeconds(points: []const TempoPoint, default_bpm: f64, target_seconds: f64) f64 {
    const target = if (std.math.isNan(target_seconds) or target_seconds <= 0) 0 else target_seconds;
    var beat: f64 = 0;
    var bpm = safeTempo(default_bpm);
    var seconds: f64 = 0;
    for (points, 0..) |point, i| {
        if (point.beat > beat) {
            const duration = (point.beat - beat) * 60.0 / bpm;
            if (seconds + duration >= target) return beat + (target - seconds) * bpm / 60.0;
            seconds += duration;
        }
        beat = point.beat;
        bpm = safeTempo(point.bpm);
        if (i + 1 >= points.len) break;
        const next = points[i + 1];
        if (next.beat <= beat) continue;
        const next_bpm = safeTempo(next.bpm);
        const duration = segmentSeconds(bpm, next_bpm, next.beat - beat, next.beat - beat, point.ramp_to_next);
        if (seconds + duration >= target) {
            const elapsed = target - seconds;
            if (!point.ramp_to_next or bpm == next_bpm) return beat + elapsed * bpm / 60.0;
            const slope = (next_bpm - bpm) / (next.beat - beat);
            return beat + bpm * (@exp(elapsed * slope / 60.0) - 1.0) / slope;
        }
        seconds += duration;
        beat = next.beat;
        bpm = next_bpm;
    }
    return beat + (target - seconds) * bpm / 60.0;
}

pub fn meterAt(points: []const MeterPoint, default_meter: MeterPoint, beat: f64) MeterPoint {
    var result = default_meter;
    for (points) |point| {
        if (point.beat > beat) break;
        result = point;
    }
    return result;
}

pub fn tempoAt(points: []const TempoPoint, default_bpm: f64, beat: f64) f64 {
    var bpm = safeTempo(default_bpm);
    for (points, 0..) |point, i| {
        if (point.beat > beat) break;
        bpm = safeTempo(point.bpm);
        if (point.ramp_to_next and i + 1 < points.len and beat < points[i + 1].beat) {
            const fraction = (beat - point.beat) / (points[i + 1].beat - point.beat);
            return bpm + (safeTempo(points[i + 1].bpm) - bpm) * fraction;
        }
    }
    return bpm;
}

test "tempo changes and ramps round-trip beat and seconds" {
    const points = [_]TempoPoint{
        .{ .beat = 4, .bpm = 60, .ramp_to_next = true },
        .{ .beat = 8, .bpm = 120 },
    };
    try std.testing.expectApproxEqAbs(@as(f64, 2), secondsAtBeat(&points, 120, 4), 1e-9);
    const seconds = secondsAtBeat(&points, 120, 7);
    try std.testing.expectApproxEqAbs(@as(f64, 7), beatAtSeconds(&points, 120, seconds), 1e-9);
}

test "invalid positions clamp to the timeline start" {
    try std.testing.expectEqual(@as(f64, 0), secondsAtBeat(&.{}, 120, std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 0), secondsAtBeat(&.{}, 120, -1));
    try std.testing.expectEqual(@as(f64, 0), beatAtSeconds(&.{}, 120, std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 0), beatAtSeconds(&.{}, 120, -1));
}

test "meter denominator changes quarter-note bar length" {
    const meter = MeterPoint{ .beat = 0, .numerator = 6, .denominator = 8 };
    try std.testing.expectApproxEqAbs(@as(f64, 3), meter.quarterBeatsPerBar(), 1e-9);
}
