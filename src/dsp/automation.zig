//! Continuous parameter automation: sorted breakpoints, interpolated with a
//! per-segment shape.
//!
//! Clips (arrangement.zig) own their points in clip-relative beats - edited
//! by the user, persisted in the .wsj. `Session.rebuildSongData` flattens
//! every lane's clips into one absolute-beat curve per (track, parameter) and
//! pushes it into the engine's `AutomationCurve` - the same "own it per-clip,
//! flatten for playback" split `PatternPlayer.song_notes` already uses for
//! notes, just for a continuous value instead of discrete events.

const std = @import("std");

/// Shape of the segment *leaving* a point, so the curve between two points
/// is the earlier one's business - the same "a node owns the ramp after it"
/// model LMMS's progression types use, but per point rather than per clip,
/// so one lane can hold a switch flat and then ramp.
pub const Curve = enum {
    /// Straight ramp to the next point.
    linear,
    /// Stay flat, then jump at the next point. What a switch-like parameter
    /// (an FX bypass, a waveform choice) needs - a ramp through the values
    /// in between would sweep settings the user never asked for.
    hold,
    /// Smoothstep: flat at both ends of the segment, steepest in the middle.
    /// Chosen over LMMS's cubic Hermite because it needs no neighbouring
    /// points to derive a tangent from and cannot overshoot the two values
    /// it connects - an overshoot on a clamped parameter is a silent
    /// surprise, not a nicer curve.
    ease,
};

pub const AutomationPoint = struct {
    /// Beat position. Clip-relative when stored on a Clip; absolute song
    /// beat once flattened into an `AutomationCurve`.
    beat: f64,
    value: f32,
    /// Shape of the ramp from here to the next point. Ignored on the last
    /// point, which has no segment after it.
    curve: Curve = .linear,
};

pub const MixTarget = union(enum) {
    master_gain,
    group_gain: u8,
    send_level: struct { track: u16, slot: u8 },
};

pub const MixLane = struct {
    target: MixTarget,
    points: []AutomationPoint = &.{},
};

pub const RecordMode = enum { off, write, touch, latch };

/// Interpolate across `points` (must be sorted ascending by `beat`), each
/// segment shaped by the `curve` of the point it starts from. Holds the
/// first/last value past either edge. `null` means "no points" - distinct
/// from a single flat point, so callers can tell "no automation here" from
/// "automation holding a constant value".
pub fn interpolate(points: []const AutomationPoint, beat: f64) ?f32 {
    if (points.len == 0) return null;
    if (beat <= points[0].beat) return points[0].value;
    const last = points[points.len - 1];
    if (beat >= last.beat) return last.value;
    var i: usize = 1;
    while (i < points.len) : (i += 1) {
        if (points[i].beat >= beat) {
            const a = points[i - 1];
            const b = points[i];
            const span = b.beat - a.beat;
            const t: f64 = if (span <= 0) 1.0 else (beat - a.beat) / span;
            const shaped: f64 = switch (a.curve) {
                .linear => t,
                // Not `0` - a zero-width span lands here with t == 1, and a
                // held segment still has to reach the next value at its end.
                .hold => if (t >= 1.0) 1.0 else 0.0,
                .ease => t * t * (3.0 - 2.0 * t),
            };
            return a.value + (b.value - a.value) * @as(f32, @floatCast(shaped));
        }
    }
    return last.value;
}

pub fn hasPointAt(points: []const AutomationPoint, beat: f64) bool {
    for (points) |point| {
        if (@abs(point.beat - beat) < 1e-9) return true;
    }
    return false;
}

fn lessThanBeat(_: void, a: AutomationPoint, b: AutomationPoint) bool {
    return a.beat < b.beat;
}

/// Insert or update (same-beat match within epsilon) a point, keeping the
/// slice sorted by `beat`. `points` is reassigned to the new allocation.
pub fn setPoint(allocator: std.mem.Allocator, points: *[]AutomationPoint, beat: f64, value: f32) !void {
    if (!std.math.isFinite(beat) or !std.math.isFinite(value)) return error.InvalidPoint;
    for (points.*) |*p| {
        if (@abs(p.beat - beat) < 1e-9) {
            p.value = value;
            return;
        }
    }
    const grown = try allocator.alloc(AutomationPoint, points.len + 1);
    @memcpy(grown[0..points.len], points.*);
    grown[points.len] = .{ .beat = beat, .value = value };
    std.mem.sort(AutomationPoint, grown, {}, lessThanBeat);
    allocator.free(points.*);
    points.* = grown;
}

/// The shape of the segment leaving the point at `beat` (within epsilon),
/// or null when no point sits exactly there - the same match `hasPointAt`
/// and `setCurve` use, so callers never need the epsilon themselves.
pub fn curveAt(points: []const AutomationPoint, beat: f64) ?Curve {
    for (points) |p| {
        if (@abs(p.beat - beat) < 1e-9) return p.curve;
    }
    return null;
}

/// Set the shape of the segment leaving the point at `beat` (within
/// epsilon). Returns false when there is no point there. No allocation: the
/// point already exists, only its shape changes.
pub fn setCurve(points: []AutomationPoint, beat: f64, curve: Curve) bool {
    for (points) |*p| {
        if (@abs(p.beat - beat) < 1e-9) {
            p.curve = curve;
            return true;
        }
    }
    return false;
}

/// Remove the point at `beat` (within epsilon). Returns true if one was
/// removed.
pub fn removePoint(allocator: std.mem.Allocator, points: *[]AutomationPoint, beat: f64) !bool {
    for (points.*, 0..) |p, i| {
        if (@abs(p.beat - beat) < 1e-9) {
            const shrunk = try allocator.alloc(AutomationPoint, points.len - 1);
            @memcpy(shrunk[0..i], points.*[0..i]);
            @memcpy(shrunk[i..], points.*[i + 1 ..]);
            allocator.free(points.*);
            points.* = shrunk;
            return true;
        }
    }
    return false;
}

/// One (track, parameter) pair's whole-song curve. `Session.rebuildSongData`
/// (control thread) rebuilds it wholesale via `set` whenever clips change;
/// `Engine.renderTracks` (audio thread) reads it every block via `valueAt`.
/// Same non-blocking-tryLock discipline as `PatternPlayer.notes_lock` - a
/// block that loses the race just falls back to the manual gain/pan (treated
/// the same as "no automation").
pub const AutomationCurve = struct {
    lock: std.atomic.Mutex = .unlocked,
    points: []const AutomationPoint = &.{},

    fn acquire(self: *AutomationCurve) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn deinit(self: *AutomationCurve, allocator: std.mem.Allocator) void {
        self.acquire();
        defer self.lock.unlock();
        if (self.points.len > 0) allocator.free(self.points);
        self.points = &.{};
    }

    /// Exchange owned point buffers while leaving each lock at its stable
    /// address. The audio thread either reads the old curve, the new curve,
    /// or skips one block when its non-blocking lock attempt loses the race.
    pub fn swapPoints(self: *AutomationCurve, other: *AutomationCurve) void {
        self.acquire();
        defer self.lock.unlock();
        other.acquire();
        defer other.lock.unlock();
        std.mem.swap([]const AutomationPoint, &self.points, &other.points);
    }

    /// Replace the curve wholesale (control thread). Empty `points` clears
    /// it - the track falls back to its manual gain/pan.
    pub fn set(self: *AutomationCurve, allocator: std.mem.Allocator, points: []const AutomationPoint) !void {
        const replacement = if (points.len == 0) &.{} else try allocator.dupe(AutomationPoint, points);
        self.acquire();
        defer self.lock.unlock();
        if (self.points.len > 0) allocator.free(self.points);
        self.points = replacement;
    }

    /// Evaluate at `beat` (audio thread). Null means "no override this
    /// block" - either the curve is empty or the control thread is mid-`set`.
    pub fn valueAt(self: *AutomationCurve, beat: f64) ?f32 {
        if (!self.lock.tryLock()) return null;
        defer self.lock.unlock();
        return interpolate(self.points, beat);
    }

    /// Fill one audio block at frame resolution while holding the curve lock
    /// once. Returns false, and fills `fallback`, when no curve is available.
    pub fn fillValues(self: *AutomationCurve, out: []f32, start_beat: f64, beat_step: f64, fallback: f32) bool {
        @memset(out, fallback);
        if (!self.lock.tryLock()) return false;
        defer self.lock.unlock();
        if (self.points.len == 0) return false;

        var segment: usize = 0;
        for (out, 0..) |*value, frame| {
            const beat = start_beat + @as(f64, @floatFromInt(frame)) * beat_step;
            while (segment + 1 < self.points.len and self.points[segment + 1].beat < beat) segment += 1;
            value.* = interpolate(self.points[segment..@min(segment + 2, self.points.len)], beat).?;
        }
        return true;
    }
};

const testing = std.testing;

test "interpolate holds edges and ramps linearly between points" {
    const pts = [_]AutomationPoint{
        .{ .beat = 1.0, .value = 0.0 },
        .{ .beat = 3.0, .value = 2.0 },
    };
    try testing.expect(interpolate(&.{}, 5.0) == null);
    try testing.expectApproxEqAbs(@as(f32, 0.0), interpolate(&pts, 0.0).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), interpolate(&pts, 2.0).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), interpolate(&pts, 10.0).?, 1e-6);
}

test "a segment is shaped by the curve of the point it leaves" {
    // Same two values three ways: only the first point's curve differs, and
    // the last point's curve never matters (no segment follows it).
    const shapes = [_]struct { curve: Curve, mid: f32 }{
        .{ .curve = .linear, .mid = 1.0 },
        .{ .curve = .ease, .mid = 1.0 }, // smoothstep is symmetric: 0.5 at the midpoint
        .{ .curve = .hold, .mid = 0.0 },
    };
    for (shapes) |s| {
        const pts = [_]AutomationPoint{
            .{ .beat = 1.0, .value = 0.0, .curve = s.curve },
            .{ .beat = 3.0, .value = 2.0 },
        };
        try testing.expectApproxEqAbs(@as(f32, 0.0), interpolate(&pts, 1.0).?, 1e-6);
        try testing.expectApproxEqAbs(s.mid, interpolate(&pts, 2.0).?, 1e-6);
        // Every shape still arrives at the next point's value, hold included.
        try testing.expectApproxEqAbs(@as(f32, 2.0), interpolate(&pts, 3.0).?, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 2.0), interpolate(&pts, 9.0).?, 1e-6);
    }

    // Ease is flatter than linear near the ends and steeper in the middle,
    // which is the whole point of offering it.
    const eased = [_]AutomationPoint{
        .{ .beat = 0.0, .value = 0.0, .curve = .ease },
        .{ .beat = 1.0, .value = 1.0 },
    };
    try testing.expect(interpolate(&eased, 0.25).? < 0.25);
    try testing.expect(interpolate(&eased, 0.75).? > 0.75);
}

test "setCurve retargets an existing point and reports a miss" {
    var points: []AutomationPoint = &.{};
    defer testing.allocator.free(points);
    try setPoint(testing.allocator, &points, 0.0, 0.0);
    try setPoint(testing.allocator, &points, 2.0, 1.0);
    try testing.expectEqual(Curve.linear, points[0].curve);

    try testing.expect(setCurve(points, 0.0, .hold));
    try testing.expectEqual(Curve.hold, points[0].curve);
    try testing.expectApproxEqAbs(@as(f32, 0.0), interpolate(points, 1.0).?, 1e-6);

    // Re-setting the value leaves the shape alone - they are independent
    // edits on the same point.
    try setPoint(testing.allocator, &points, 0.0, 0.5);
    try testing.expectEqual(Curve.hold, points[0].curve);

    try testing.expect(!setCurve(points, 7.0, .ease));
}

test "setPoint inserts sorted and updates in place" {
    var points: []AutomationPoint = &.{};
    defer testing.allocator.free(points);
    try setPoint(testing.allocator, &points, 2.0, 1.0);
    try setPoint(testing.allocator, &points, 0.0, 0.0);
    try setPoint(testing.allocator, &points, 1.0, 0.5);
    try testing.expectEqual(@as(usize, 3), points.len);
    try testing.expectApproxEqAbs(@as(f64, 0.0), points[0].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), points[1].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0), points[2].beat, 1e-9);

    try setPoint(testing.allocator, &points, 1.0, 0.9);
    try testing.expectEqual(@as(usize, 3), points.len);
    try testing.expectApproxEqAbs(@as(f32, 0.9), points[1].value, 1e-6);
}

test "setPoint rejects non-finite coordinates without changing the curve" {
    var points: []AutomationPoint = &.{};
    defer testing.allocator.free(points);
    try setPoint(testing.allocator, &points, 1.0, 0.5);

    try testing.expectError(error.InvalidPoint, setPoint(testing.allocator, &points, std.math.nan(f64), 1.0));
    try testing.expectError(error.InvalidPoint, setPoint(testing.allocator, &points, 2.0, std.math.inf(f32)));
    try testing.expectEqual(@as(usize, 1), points.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), points[0].beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 0.5), points[0].value, 1e-6);
}

test "removePoint drops the matching point" {
    var points: []AutomationPoint = &.{};
    try setPoint(testing.allocator, &points, 0.0, 0.0);
    try setPoint(testing.allocator, &points, 1.0, 1.0);
    try testing.expect(try removePoint(testing.allocator, &points, 0.0));
    defer testing.allocator.free(points);
    try testing.expectEqual(@as(usize, 1), points.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), points[0].beat, 1e-9);
    try testing.expect(!try removePoint(testing.allocator, &points, 5.0));
}

test "removePoint preserves the curve when shrinking runs out of memory" {
    var points = try testing.allocator.dupe(AutomationPoint, &.{
        .{ .beat = 0.0, .value = 0.0 },
        .{ .beat = 1.0, .value = 1.0 },
    });
    defer testing.allocator.free(points);
    var empty: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&empty);

    try testing.expectError(error.OutOfMemory, removePoint(failing.allocator(), &points, 0.0));
    try testing.expectEqual(@as(usize, 2), points.len);
    try testing.expectApproxEqAbs(@as(f64, 0.0), points[0].beat, 1e-9);
}

test "AutomationCurve.set/valueAt round-trip" {
    var curve: AutomationCurve = .{};
    defer curve.deinit(testing.allocator);
    try testing.expect(curve.valueAt(0.0) == null);
    try curve.set(testing.allocator, &.{
        .{ .beat = 0.0, .value = 1.0 },
        .{ .beat = 4.0, .value = 0.0 },
    });
    try testing.expectApproxEqAbs(@as(f32, 0.5), curve.valueAt(2.0).?, 1e-6);
    try curve.set(testing.allocator, &.{});
    try testing.expect(curve.valueAt(2.0) == null);
}

test "AutomationCurve fills sample-accurate block values" {
    var curve: AutomationCurve = .{};
    defer curve.deinit(testing.allocator);
    try curve.set(testing.allocator, &.{
        .{ .beat = 0.0, .value = 0.0 },
        .{ .beat = 1.0, .value = 1.0 },
    });
    var values: [5]f32 = undefined;

    try testing.expect(curve.fillValues(&values, 0.0, 0.25, 9.0));
    try testing.expectEqualSlices(f32, &.{ 0.0, 0.25, 0.5, 0.75, 1.0 }, &values);
}

test "AutomationCurve preserves long song curves without truncation" {
    var curve: AutomationCurve = .{};
    defer curve.deinit(testing.allocator);
    var points: [1_000]AutomationPoint = undefined;
    for (&points, 0..) |*point, i| point.* = .{
        .beat = @floatFromInt(i),
        .value = @floatFromInt(i),
    };

    try curve.set(testing.allocator, &points);

    try testing.expectEqual(@as(usize, points.len), curve.points.len);
    try testing.expectApproxEqAbs(@as(f32, 999.0), curve.valueAt(999.0).?, 1e-6);
}
