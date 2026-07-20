//! Shared step-grid math between editors/drum.zig and editors/slicer.zig:
//! cursor clamping, w/b bar jumps, visual-range selection/yank/paste, and
//! the mouse column lookup. Both editors edit an identical (row, step)
//! bitmask-plus-velocity grid over an instrument that duck-types
//! toggleStep/stepActive/stepVel/setStepVel (DrumMachine's pads, Slicer's
//! slices) - this file holds the row-agnostic logic so a fix to the range
//! math (the part most prone to off-by-one bugs) lands in both at once.
//! Key dispatch, undo/status wiring, and view-specific rendering stay in
//! each editor; they differ enough (chop gestures, choke groups, pad
//! rename, ...) that merging them would cost more than it'd save.
//!
//! Step-index types differ between the two: Slicer keeps its original u8
//! (max_steps=64); the drum machine widened to u16 once its own storage
//! ceiling grew past that (see dsp/drum_sampler.zig - the pattern itself
//! is now unbounded, a heap-owned per-pad slice, not a fixed array).
//! Cursor motion (`moveClamped`/`jumpBar`/`operatorBarForward`/
//! `operatorBarBackward`) is generic over that width (`anytype`, dispatched
//! on the pointee's type) so both editors share one implementation with no
//! drift. The visual-mode clipboard now forks in two: Slicer's storage
//! stays capped at `max_steps = 64`, so `SlicerRangeClip` keeps the original
//! fixed 64-bit-wide bitmask and the plain `yankRange`/`pasteRange` below.
//! The drum machine's own step storage is unbounded (heap-owned per-pad
//! slice, see dsp/drum_sampler.zig), so `DrumRangeClip` is heap-allocated
//! and sized to the yanked range's actual width - `yankRangeDyn`/
//! `pasteRangeDyn` do the word-indexed bitset math that needs.
//! `doublePattern`'s cap is an explicit parameter so the drum and slicer
//! call sites can each pass their own.

const std = @import("std");

pub fn StepRange(comptime T: type) type {
    return struct { lo: T, hi: T };
}

/// Selection between the visual/operator anchor and the current cursor
/// step, order-independent.
pub fn selectionRange(comptime T: type, anchor: ?T, cursor: T) StepRange(T) {
    const a = anchor orelse cursor;
    return .{ .lo = @min(a, cursor), .hi = @max(a, cursor) };
}

/// Move a cursor by `delta`, clamped to `[0, count-1]` (or 0 if `count`
/// is 0). Covers moveStep/movePad/moveSlice alike - they differ only in
/// which count they clamp against. `cursor` is `*u8` (Slicer) or `*u16`
/// (drum) - generic over the pointee's width.
pub fn moveClamped(cursor: anytype, delta: i32, count: usize) void {
    if (count == 0) {
        cursor.* = 0;
        return;
    }
    const top: i64 = @intCast(count - 1);
    const target = @as(i64, cursor.*) + delta;
    cursor.* = @intCast(std.math.clamp(target, 0, top));
}

// w/b's jump granularity: 4 steps, matching the grid's own `│` separators
// (drawn every 4 steps regardless of time signature - see the views'
// header-row comments). A full musical bar turned out too coarse in
// practice with a default 16-step pattern, so both grids settled on this
// fixed "decorative bar" width instead.
pub const bar_len: i32 = 4;

/// w/b: jump the step cursor `delta` 4-step groups forward/back - snaps to
/// the nearest group boundary first, then moves whole groups from there.
pub fn jumpBar(cursor: anytype, delta: i32, step_count: anytype) void {
    if (step_count == 0) {
        cursor.* = 0;
        return;
    }
    const cur_bar = @divFloor(@as(i64, cursor.*), bar_len);
    const target = (cur_bar + delta) * bar_len;
    const top = @as(i64, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(target, 0, top));
}

/// dw/yw's range end: the last step of the nth bar forward (inclusive),
/// not w's own landing step (see piano.zig's identical vim dw nuance).
pub fn operatorBarForward(cursor: anytype, n: i32, step_count: anytype) void {
    if (step_count == 0) {
        cursor.* = 0;
        return;
    }
    const cur_bar = @divFloor(@as(i64, cursor.*), bar_len);
    const hi = (cur_bar + n) * bar_len - 1;
    const top = @as(i64, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(hi, 0, top));
}

/// db/yb's range start: the first step of the nth bar back.
pub fn operatorBarBackward(cursor: anytype, n: i32, step_count: anytype) void {
    if (step_count == 0) {
        cursor.* = 0;
        return;
    }
    const cur_bar = @divFloor(@as(i64, cursor.*), bar_len);
    const lo = (cur_bar - n + 1) * bar_len;
    const top = @as(i64, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(lo, 0, top));
}

/// Step index at column `x` within a row, or null if `x` falls in the
/// gutter or past the last visible step. Replays the exact column math the
/// views' render loop uses (starting from `scroll`, a 1-char "│" every 4
/// steps, then a 3-char cell) rather than deriving a closed form.
pub fn stepAt(comptime T: type, gutter: usize, cell_width: usize, scroll: u32, step_count: anytype, x: usize) ?T {
    if (x < gutter) return null;
    var col = gutter;
    var s: u32 = scroll;
    while (s < step_count) : (s += 1) {
        if (s % 4 == 0) col += 1;
        if (x < col + cell_width) return if (x < col) null else @intCast(s); // `x < col`: landed on the separator itself
        col += cell_width;
    }
    return null;
}

/// Force one step to a given active/velocity state via the public toggle +
/// velocity API (no direct bitmask poking, so this stays in step with
/// whatever the instrument does internally on toggle). `inst` is a
/// `*DrumMachine` or `*Slicer` - both duck-type the same step API.
pub fn setStep(inst: anytype, row: u8, step: anytype, active: bool, vel: u8) void {
    if (inst.stepActive(row, step) != active) inst.toggleStep(row, step);
    if (active) inst.setStepVel(row, step, vel);
}

/// Double a loop and copy its first half, preserving every hit's velocity.
/// Returns false when the loop is already too long to double without
/// exceeding the instrument's own step ceiling (`max_steps` - each call
/// site passes its own instrument's constant, since Slicer's and the drum
/// machine's have diverged).
pub fn doublePattern(inst: anytype, max_rows: usize, max_steps: anytype) bool {
    const old_count = inst.step_count;
    if (old_count > @divTrunc(@as(@TypeOf(old_count), @intCast(max_steps)), 2)) return false;
    inst.setStepCount(old_count * 2);
    for (0..max_rows) |row| {
        var step: @TypeOf(old_count) = 0;
        while (step < old_count) : (step += 1) {
            const active = inst.stepActive(@intCast(row), step);
            setStep(inst, @intCast(row), old_count + step, active, inst.stepVel(@intCast(row), step));
        }
    }
    return true;
}

/// Yank every row's steps within `r` into a `Clip` (SlicerRangeClip -
/// duck-types `width`/`active`/`vel` as fixed arrays), rebased so the
/// range's first step is bit 0. `r` can never be more than 64 steps wide
/// here since Slicer's own step indices already top out at `max_steps = 64`.
pub fn yankRange(comptime Clip: type, inst: anytype, max_rows: usize, r: anytype) Clip {
    var clip: Clip = .{ .width = @intCast(@as(u32, r.hi) - @as(u32, r.lo) + 1) };
    for (0..max_rows) |row| {
        var s = r.lo;
        while (s <= r.hi) : (s += 1) {
            if (!inst.stepActive(@intCast(row), s)) continue;
            const offset: u6 = @intCast(@as(u32, s) - @as(u32, r.lo));
            const bit = @as(u64, 1) << offset;
            clip.active[row] |= bit;
            clip.vel[row][offset] = inst.stepVel(@intCast(row), s);
        }
    }
    return clip;
}

/// Clear every row's steps within `r`.
pub fn clearRange(inst: anytype, max_rows: usize, r: anytype) void {
    for (0..max_rows) |row| {
        var s = r.lo;
        while (s <= r.hi) : (s += 1) setStep(inst, @intCast(row), s, false, 0);
    }
}

/// Paste `clip` starting at step `base` (all rows), overwriting whatever
/// already sits at each destination step. Returns how many steps landed
/// before running off the end of the pattern.
pub fn pasteRange(inst: anytype, max_rows: usize, clip: anytype, base: anytype) @TypeOf(base) {
    const T = @TypeOf(base);
    var i: T = 0;
    while (i < clip.width) : (i += 1) {
        const target = base +| i;
        if (target >= inst.step_count) break;
        for (0..max_rows) |row| {
            const bit = @as(u64, 1) << @intCast(i);
            const active = clip.active[row] & bit != 0;
            setStep(inst, @intCast(row), target, active, clip.vel[row][i]);
        }
    }
    return i;
}

/// `yankRange`'s heap-allocated counterpart for a `Clip` whose `active`/
/// `vel` fields are per-row slices sized to the range's actual width (word
/// `i / 64`, bit `i % 64` of `active[row]` is step `r.lo + i`) rather than a
/// fixed 64-bit shape - see `DrumRangeClip`. `r` may be any width; the
/// caller owns the result and must free it with `Clip.deinit`.
pub fn yankRangeDyn(comptime Clip: type, allocator: std.mem.Allocator, inst: anytype, max_rows: usize, r: anytype) !Clip {
    const width: u32 = @as(u32, r.hi) - @as(u32, r.lo) + 1;
    const words = (width + 63) / 64;
    var clip: Clip = .{ .width = @intCast(width), .active = undefined, .vel = undefined };
    var row: usize = 0;
    errdefer for (0..row) |i| {
        allocator.free(clip.active[i]);
        allocator.free(clip.vel[i]);
    };
    while (row < max_rows) : (row += 1) {
        clip.active[row] = try allocator.alloc(u64, words);
        @memset(clip.active[row], 0);
        clip.vel[row] = allocator.alloc(u8, width) catch |err| {
            allocator.free(clip.active[row]);
            return err;
        };
        var s = r.lo;
        while (s <= r.hi) : (s += 1) {
            const offset: u32 = @as(u32, s) - @as(u32, r.lo);
            clip.vel[row][offset] = inst.stepVel(@intCast(row), s);
            if (!inst.stepActive(@intCast(row), s)) continue;
            clip.active[row][offset / 64] |= @as(u64, 1) << @intCast(offset % 64);
        }
    }
    return clip;
}

/// `pasteRange`'s counterpart for a dynamically-sized `clip` (see
/// `yankRangeDyn`/`DrumRangeClip`).
pub fn pasteRangeDyn(inst: anytype, max_rows: usize, clip: anytype, base: anytype) @TypeOf(base) {
    const T = @TypeOf(base);
    var i: T = 0;
    while (i < clip.width) : (i += 1) {
        const target = base +| i;
        if (target >= inst.step_count) break;
        const idx: usize = i;
        for (0..max_rows) |row| {
            const bit = @as(u64, 1) << @intCast(idx % 64);
            const active = clip.active[row][idx / 64] & bit != 0;
            setStep(inst, @intCast(row), target, active, clip.vel[row][idx]);
        }
    }
    return i;
}

test "cursor motions clamp maximum count prefixes without overflow" {
    var cursor: u8 = 7;
    moveClamped(&cursor, std.math.maxInt(i32), 16);
    try std.testing.expectEqual(@as(u8, 15), cursor);
    moveClamped(&cursor, std.math.minInt(i32), 16);
    try std.testing.expectEqual(@as(u8, 0), cursor);

    jumpBar(&cursor, std.math.maxInt(i32), 16);
    try std.testing.expectEqual(@as(u8, 15), cursor);
    operatorBarForward(&cursor, std.math.maxInt(i32), 16);
    try std.testing.expectEqual(@as(u8, 15), cursor);
    operatorBarBackward(&cursor, std.math.maxInt(i32), 16);
    try std.testing.expectEqual(@as(u8, 0), cursor);
}

test "bar motions handle an empty grid" {
    var cursor: u8 = 12;
    jumpBar(&cursor, 1, 0);
    try std.testing.expectEqual(@as(u8, 0), cursor);
    operatorBarForward(&cursor, 1, 0);
    operatorBarBackward(&cursor, 1, 0);
    try std.testing.expectEqual(@as(u8, 0), cursor);
}

test "cursor motions work at u16 width past the old u8 ceiling" {
    var cursor: u16 = 200;
    moveClamped(&cursor, 100, 1000);
    try std.testing.expectEqual(@as(u16, 300), cursor);
    jumpBar(&cursor, 1, 1000);
    try std.testing.expectEqual(@as(u16, 304), cursor);
    moveClamped(&cursor, std.math.maxInt(i32), 1000);
    try std.testing.expectEqual(@as(u16, 999), cursor);
}
