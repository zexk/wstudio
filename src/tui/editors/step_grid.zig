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

const std = @import("std");

pub const StepRange = struct { lo: u8, hi: u8 };

/// Selection between the visual/operator anchor and the current cursor
/// step, order-independent.
pub fn selectionRange(anchor: ?u8, cursor: u8) StepRange {
    const a = anchor orelse cursor;
    return .{ .lo = @min(a, cursor), .hi = @max(a, cursor) };
}

/// Move a cursor by `delta`, clamped to `[0, count-1]` (or 0 if `count`
/// is 0). Covers moveStep/movePad/moveSlice alike - they differ only in
/// which count they clamp against.
pub fn moveClamped(cursor: *u8, delta: i32, count: usize) void {
    if (count == 0) {
        cursor.* = 0;
        return;
    }
    const top: i32 = @intCast(count - 1);
    cursor.* = @intCast(std.math.clamp(@as(i32, cursor.*) + delta, 0, top));
}

// w/b's jump granularity: 4 steps, matching the grid's own `│` separators
// (drawn every 4 steps regardless of time signature - see the views'
// header-row comments). A full musical bar turned out too coarse in
// practice with a default 16-step pattern, so both grids settled on this
// fixed "decorative bar" width instead.
const bar_len: i32 = 4;

/// w/b: jump the step cursor `delta` 4-step groups forward/back - snaps to
/// the nearest group boundary first, then moves whole groups from there.
pub fn jumpBar(cursor: *u8, delta: i32, step_count: u8) void {
    const cur_bar = @divFloor(@as(i32, cursor.*), bar_len);
    const target = (cur_bar + delta) * bar_len;
    const top = @as(i32, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(target, 0, top));
}

/// dw/yw's range end: the last step of the nth bar forward (inclusive),
/// not w's own landing step (see piano.zig's identical vim dw nuance).
pub fn operatorBarForward(cursor: *u8, n: i32, step_count: u8) void {
    const cur_bar = @divFloor(@as(i32, cursor.*), bar_len);
    const hi = (cur_bar + n) * bar_len - 1;
    const top = @as(i32, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(hi, 0, top));
}

/// db/yb's range start: the first step of the nth bar back.
pub fn operatorBarBackward(cursor: *u8, n: i32, step_count: u8) void {
    const cur_bar = @divFloor(@as(i32, cursor.*), bar_len);
    const lo = (cur_bar - n + 1) * bar_len;
    const top = @as(i32, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(lo, 0, top));
}

/// Step index at column `x` within a row, or null if `x` falls in the
/// gutter or past the last visible step. Replays the exact column math the
/// views' render loop uses (starting from `scroll`, a 1-char "│" every 4
/// steps, then a 3-char cell) rather than deriving a closed form.
pub fn stepAt(gutter: usize, cell_width: usize, scroll: u32, step_count: u8, x: usize) ?u8 {
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
pub fn setStep(inst: anytype, row: u8, step: u8, active: bool, vel: u8) void {
    if (inst.stepActive(row, step) != active) inst.toggleStep(row, step);
    if (active) inst.setStepVel(row, step, vel);
}

/// Yank every row's steps within `r` into a `Clip` (DrumRangeClip or
/// SlicerRangeClip - both duck-type `width`/`active`/`vel`), rebased so the
/// range's first step is bit 0.
pub fn yankRange(comptime Clip: type, inst: anytype, max_rows: usize, r: StepRange) Clip {
    var clip: Clip = .{ .width = r.hi - r.lo + 1 };
    for (0..max_rows) |row| {
        var s: u8 = r.lo;
        while (s <= r.hi) : (s += 1) {
            if (!inst.stepActive(@intCast(row), s)) continue;
            const bit = @as(u64, 1) << @intCast(s - r.lo);
            clip.active[row] |= bit;
            clip.vel[row][s - r.lo] = inst.stepVel(@intCast(row), s);
        }
    }
    return clip;
}

/// Clear every row's steps within `r`.
pub fn clearRange(inst: anytype, max_rows: usize, r: StepRange) void {
    for (0..max_rows) |row| {
        var s: u8 = r.lo;
        while (s <= r.hi) : (s += 1) setStep(inst, @intCast(row), s, false, 0);
    }
}

/// Paste `clip` starting at step `base` (all rows), overwriting whatever
/// already sits at each destination step. Returns how many steps landed
/// before running off the end of the pattern.
pub fn pasteRange(inst: anytype, max_rows: usize, clip: anytype, base: u8) u8 {
    var i: u8 = 0;
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
