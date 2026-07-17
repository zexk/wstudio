//! Continuous parameter automation: sorted breakpoints, linearly interpolated.
//!
//! Clips (arrangement.zig) own their points in clip-relative beats - edited
//! by the user, persisted in the .wsj. `Session.rebuildSongData` flattens
//! every lane's clips into one absolute-beat curve per (track, parameter) and
//! pushes it into the engine's `AutomationCurve` - the same "own it per-clip,
//! flatten for playback" split `PatternPlayer.song_notes` already uses for
//! notes, just for a continuous value instead of discrete events.

const std = @import("std");

pub const AutomationPoint = struct {
    /// Beat position. Clip-relative when stored on a Clip; absolute song
    /// beat once flattened into an `AutomationCurve`.
    beat: f64,
    value: f32,
};

/// Linear interpolation across `points` (must be sorted ascending by `beat`).
/// Holds the first/last value past either edge. `null` means "no points" -
/// distinct from a single flat point, so callers can tell "no automation
/// here" from "automation holding a constant value".
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
            return a.value + (b.value - a.value) * @as(f32, @floatCast(t));
        }
    }
    return last.value;
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

/// Remove the point at `beat` (within epsilon). Returns true if one was
/// removed.
pub fn removePoint(allocator: std.mem.Allocator, points: *[]AutomationPoint, beat: f64) bool {
    for (points.*, 0..) |p, i| {
        if (@abs(p.beat - beat) < 1e-9) {
            const shrunk = allocator.alloc(AutomationPoint, points.len - 1) catch return false;
            @memcpy(shrunk[0..i], points.*[0..i]);
            @memcpy(shrunk[i..], points.*[i + 1 ..]);
            allocator.free(points.*);
            points.* = shrunk;
            return true;
        }
    }
    return false;
}

/// Fixed-capacity flattened curve, live on the audio thread. One of these
/// exists per track slot in the engine (see `audio/engine.zig`'s
/// `AutomationPair`, heap-allocated separately so this doesn't get
/// multiplied into every one of `max_tracks` (8192) in-struct track slots) -
/// keep this modest. Still generous for a whole song's worth of gain/pan
/// breakpoints across every clip on a lane.
pub const max_points: u16 = 64;

/// One (track, parameter) pair's whole-song curve. `Session.rebuildSongData`
/// (control thread) rebuilds it wholesale via `set` whenever clips change;
/// `Engine.renderTracks` (audio thread) reads it every block via `valueAt`.
/// Same non-blocking-tryLock discipline as `PatternPlayer.notes_lock` - a
/// block that loses the race just falls back to the manual gain/pan (treated
/// the same as "no automation").
pub const AutomationCurve = struct {
    lock: std.atomic.Mutex = .unlocked,
    points: [max_points]AutomationPoint = undefined,
    count: u16 = 0,

    /// Replace the curve wholesale (control thread). Empty `points` clears
    /// it - the track falls back to its manual gain/pan.
    pub fn set(self: *AutomationCurve, points: []const AutomationPoint) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        const n = @min(points.len, @as(usize, max_points));
        for (points[0..n], self.points[0..n]) |p, *dst| dst.* = p;
        self.count = @intCast(n);
    }

    /// Evaluate at `beat` (audio thread). Null means "no override this
    /// block" - either the curve is empty or the control thread is mid-`set`.
    pub fn valueAt(self: *AutomationCurve, beat: f64) ?f32 {
        if (!self.lock.tryLock()) return null;
        defer self.lock.unlock();
        return interpolate(self.points[0..self.count], beat);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
    try testing.expect(removePoint(testing.allocator, &points, 0.0));
    defer testing.allocator.free(points);
    try testing.expectEqual(@as(usize, 1), points.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), points[0].beat, 1e-9);
    try testing.expect(!removePoint(testing.allocator, &points, 5.0));
}

test "AutomationCurve.set/valueAt round-trip" {
    var curve: AutomationCurve = .{};
    try testing.expect(curve.valueAt(0.0) == null);
    curve.set(&.{
        .{ .beat = 0.0, .value = 1.0 },
        .{ .beat = 4.0, .value = 0.0 },
    });
    try testing.expectApproxEqAbs(@as(f32, 0.5), curve.valueAt(2.0).?, 1e-6);
    curve.set(&.{});
    try testing.expect(curve.valueAt(2.0) == null);
}
