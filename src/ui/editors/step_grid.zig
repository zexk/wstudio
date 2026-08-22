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
//! `armOperator`/`exitVisual` are the one exception: thin enough (pure
//! App-state, no instrument or undo involvement) that sharing them costs
//! nothing extra to keep in sync.
//!
//! Both machines index steps as u16 over unbounded, heap-owned per-row note
//! slices (see dsp/drum_sampler.zig and dsp/slicer.zig), so everything here
//! is shared outright: cursor motion (`moveClamped`/`jumpBar`/
//! `operatorBarForward`/`operatorBarBackward`) stays generic over the
//! pointee's width, and the visual-mode clipboard is one heap-allocated
//! `StepRangeClip` sized to the yanked range's actual width, filled and
//! replayed by `yankRangeDyn`/`pasteRangeDyn`. `doublePattern`'s cap is
//! still an explicit parameter, since each machine passes its own
//! `max_steps`.

const std = @import("std");

/// Pads/slices per bank - the row-window unit every step grid pages by, in
/// both frontends (the drum editor re-exports it as `pads_per_bank`, the
/// slicer's fixed 8-row pane is the same bank).
pub const rows_per_bank: usize = 8;

/// First row of a window `banks` banks tall containing `cur_row`. The window
/// always starts on a bank boundary so paging groups stay aligned; how many
/// banks fit is the caller's business (terminal row budget in the TUI, panel
/// height in the GUI).
pub fn bankWindow(cur_row: usize, banks: usize) usize {
    const shown = @max(1, banks);
    return (cur_row / rows_per_bank / shown) * shown * rows_per_bank;
}

/// The five velocity bands a step's stored 0-127 velocity reads as. Both
/// frontends classify hits through this: the TUI prints the band's glyph,
/// the GUI picks a fill color and flags `.accent` with a corner marker.
pub const VelocityBand = enum {
    ghost,
    soft,
    mid,
    hard,
    accent,

    pub fn glyph(self: VelocityBand) u8 {
        return switch (self) {
            .ghost => '.',
            .soft => '-',
            .mid => 'o',
            .hard => 'x',
            .accent => 'X',
        };
    }
};

pub fn velocityBand(vel: u8) VelocityBand {
    return switch (vel) {
        102...127 => .accent,
        76...101 => .hard,
        51...75 => .mid,
        26...50 => .soft,
        else => .ghost,
    };
}

/// The brackets around a TUI cell's velocity glyph, carrying the two bits
/// the glyph has no room for: [ ] plain, ( ) tuned, < > modified (chance, a
/// trig condition, a roll, or a timing shift), { } both. The exact values
/// are on the status line - a 3-column cell can't hold "1:2, 70%, x4, -12%".
/// `live` is false for an empty cell, or one past its row's own loop length
/// which never fires, so those read plain whatever they hold.
pub fn stepBrackets(inst: anytype, row: u8, step: u16, live: bool) [2]u8 {
    if (!live) return .{ '[', ']' };
    const tuned = inst.stepTune(row, step) != 0;
    const modified = inst.stepProb(row, step) != 100 or
        inst.stepCond(row, step) != .always or
        inst.stepRetrig(row, step) >= 2 or
        inst.stepMicro(row, step) != 0;
    if (tuned and modified) return .{ '{', '}' };
    if (tuned) return .{ '(', ')' };
    if (modified) return .{ '<', '>' };
    return .{ '[', ']' };
}

pub fn StepRange(comptime T: type) type {
    return struct { lo: T, hi: T };
}

/// Selection between the visual/operator anchor and the current cursor
/// step, order-independent.
pub fn selectionRange(comptime T: type, anchor: ?T, cursor: T) StepRange(T) {
    const a = anchor orelse cursor;
    return .{ .lo = @min(a, cursor), .hi = @max(a, cursor) };
}

/// `selectionRange` for an axis whose cursor names a grid cell rather than a
/// raw step. A cell covers `stride` raw steps, so the range has to run to the
/// end of the cursor's cell: stopping at its first step would quietly drop the
/// rest of the cell, and a selection dragged to the right edge would leave the
/// pattern's tail steps behind. Same widening the arrangement editor does with
/// `r.hi +| arr_grid.ticks()`.
pub fn gridSelectionRange(comptime T: type, anchor: ?T, cursor: T, stride: usize, count: usize) StepRange(T) {
    const r = selectionRange(T, anchor, cursor);
    if (count == 0 or stride <= 1) return r;
    return .{ .lo = r.lo, .hi = @intCast(@min(count - 1, @as(usize, r.hi) + stride - 1)) };
}

/// The row half of a 2D grid selection - the other axis to `StepRange`.
pub const RowRange = struct {
    lo: usize,
    hi: usize,

    pub fn height(self: RowRange) usize {
        return self.hi - self.lo + 1;
    }
};

pub const StepEdit = enum { velocity, tune, micro, retrig, probability, condition };

/// Apply one per-hit edit across active cells in a visual selection.
pub fn editRange(inst: anytype, rows: RowRange, range: anytype, edit: StepEdit, delta: i32) u32 {
    var changed: u32 = 0;
    var row = rows.lo;
    while (row <= rows.hi) : (row += 1) {
        var step = range.lo;
        while (step <= range.hi) : (step += 1) {
            const r: u8 = @intCast(row);
            const s: u16 = @intCast(step);
            if (!inst.stepActive(r, s)) continue;
            switch (edit) {
                .velocity => inst.nudgeStepVel(r, s, delta),
                .tune => inst.nudgeStepTune(r, s, delta),
                .micro => inst.nudgeStepMicro(r, s, delta),
                .retrig => inst.cycleStepRetrig(r, s),
                .probability => inst.cycleStepProb(r, s),
                .condition => inst.cycleStepCond(r, s, delta),
            }
            changed += 1;
        }
    }
    return changed;
}

/// Vim's visual/visual-line split applied to a (row, step) grid: `V`
/// (linewise) leaves the row anchor null and selects every row, `v`
/// (blockwise) anchors it so the selection is the band between the anchor
/// and the cursor row. A "line" here is one full column of the grid at a
/// step, so linewise means every pad/slice/pitch - which is exactly what
/// visual mode used to do unconditionally, hence null being the wide case.
pub fn rowRange(comptime T: type, anchor: ?T, cursor: T, max_rows: usize) RowRange {
    const top = max_rows -| 1;
    const a = anchor orelse return .{ .lo = 0, .hi = top };
    const lo: usize = @min(@as(usize, a), @as(usize, cursor));
    const hi: usize = @max(@as(usize, a), @as(usize, cursor));
    return .{ .lo = @min(lo, top), .hi = @min(hi, top) };
}

/// Which row a range clipboard's first row pastes onto. A linewise yank
/// (every row) keeps its absolute rows - pasting a whole-grid copy must not
/// slide the pattern down just because the cursor sits on pad 3. A blockwise
/// yank pastes at the cursor row instead, vim's own blockwise-paste rule,
/// clamped so the block stays inside the grid.
pub fn pasteBaseRow(clip: anytype, cursor_row: usize, max_rows: usize) usize {
    const h = @as(usize, clip.row_hi) - @as(usize, clip.row_lo) + 1;
    if (h >= max_rows) return clip.row_lo;
    return @min(cursor_row, max_rows - h);
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

/// Last raw step the grid can actually put a cursor on at `stride`: the start
/// of the final whole cell, not `count - 1`. A pattern is rarely a whole
/// number of cells at a coarse grid, and the leftover tail steps have no
/// column of their own to sit in.
pub fn lastGridStep(stride: usize, count: usize) usize {
    if (count == 0 or stride == 0) return 0;
    return (count - 1) / stride * stride;
}

/// Move a cursor by `delta` **grid cells** when the grid is coarser than the
/// pattern's storage. The cursor is stored in raw steps, so this converts to a
/// cell index, moves, clamps to the last whole cell, and converts back - which
/// snaps the cursor back onto the grid as a side effect.
///
/// `moveClamped` is wrong for this axis even with a pre-multiplied delta: it
/// clamps to `count - 1`, and whenever the pattern is not a whole number of
/// cells that lands the cursor between columns. Every later move then keeps
/// that offset, so hits get stamped on steps the grid never draws and the
/// cursor visibly desyncs from the highlighted column (running the cursor to
/// the right edge and back was the reproducer).
pub fn moveGridClamped(cursor: anytype, delta: i32, stride: usize, count: usize) void {
    if (count == 0 or stride == 0) {
        cursor.* = 0;
        return;
    }
    const s: i64 = @intCast(stride);
    const top_cell: i64 = @intCast((count - 1) / stride);
    const cell = @divFloor(@as(i64, cursor.*), s) + delta;
    cursor.* = @intCast(std.math.clamp(cell, 0, top_cell) * s);
}

/// Steps in one bar of the project's meter. `+`/`-` resize by this, matching
/// the piano roll's own bar-at-a-time loop resize - a step grid used to be one
/// fixed bar of 16, so resizing it by beats made sense; with storage at 32
/// ticks per beat the musical unit the rest of the app edits in is the bar.
pub fn barSteps(quarter_beats_per_bar: f64, steps_per_beat: u8) u16 {
    const n = quarter_beats_per_bar * @as(f64, @floatFromInt(@max(steps_per_beat, 1)));
    if (!(n >= 1.0)) return @max(steps_per_beat, 1); // also catches NaN
    return @intFromFloat(@min(n, @as(f64, std.math.maxInt(u16))));
}

/// Resize a step pattern by `count` whole `unit`s (a bar's worth of steps),
/// without narrowing count-prefix arithmetic before clamping to the pattern's
/// u16 storage range. Shrinking floors at one unit, so `-` can't leave a
/// pattern shorter than the bar the grid draws.
pub fn resizeByUnits(step_count: u16, unit: u16, count: i32, grow: bool) u16 {
    const u: u32 = @max(unit, 1);
    const current: u32 = step_count;
    const amount = u * @as(u32, @intCast(@max(count, 1)));
    return @intCast(if (grow)
        @min(@as(u32, std.math.maxInt(u16)), current + amount)
    else
        @max(u, current -| amount));
}

test "unit resize clamps large count prefixes and floors at one unit" {
    try std.testing.expectEqual(std.math.maxInt(u16), resizeByUnits(16, 128, 4096, true));
    try std.testing.expectEqual(@as(u16, 128), resizeByUnits(256, 128, 4096, false));
    // 4/4 at 32 ticks per beat is a 128-step bar; a meaningless meter falls
    // back to one beat rather than zero.
    try std.testing.expectEqual(@as(u16, 128), barSteps(4.0, 32));
    try std.testing.expectEqual(@as(u16, 32), barSteps(0.0, 32));
}

/// Pull a cursor back onto the grid and inside `count` - for wherever the
/// pattern shrank under it (resize, variant switch, undo). The old
/// `cursor = step_count - 1` idiom predates coarse grids and lands the cursor
/// between columns; see `moveGridClamped`.
pub fn clampToGrid(cursor: anytype, stride: usize, count: usize) void {
    const s = @max(stride, 1);
    cursor.* = @intCast(@min(@as(usize, cursor.*), lastGridStep(s, count)) / s * s);
}

/// w/b: jump the step cursor `delta` groups forward/back, snapping to the
/// nearest group boundary first. Drum and slicer pass their live
/// `steps_per_beat`; piano and automation pass their own grid-derived width.
pub fn jumpBar(cursor: anytype, delta: i32, step_count: anytype, bar_len_arg: anytype) void {
    if (step_count == 0 or bar_len_arg == 0) {
        cursor.* = 0;
        return;
    }
    const bl: i64 = @intCast(bar_len_arg);
    const cur_bar = @divFloor(@as(i64, cursor.*), bl);
    const target = (cur_bar + delta) * bl;
    const top = @as(i64, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(target, 0, top));
}

/// dw/yw's range end: the last step of the nth bar forward (inclusive),
/// not w's own landing step (see piano.zig's identical vim dw nuance).
pub fn operatorBarForward(cursor: anytype, n: i32, step_count: anytype, bar_len_arg: anytype) void {
    if (step_count == 0 or bar_len_arg == 0) {
        cursor.* = 0;
        return;
    }
    const bl: i64 = @intCast(bar_len_arg);
    const cur_bar = @divFloor(@as(i64, cursor.*), bl);
    const hi = (cur_bar + n) * bl - 1;
    const top = @as(i64, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(hi, 0, top));
}

/// db/yb's range start: the first step of the nth bar back.
pub fn operatorBarBackward(cursor: anytype, n: i32, step_count: anytype, bar_len_arg: anytype) void {
    if (step_count == 0 or bar_len_arg == 0) {
        cursor.* = 0;
        return;
    }
    const bl: i64 = @intCast(bar_len_arg);
    const cur_bar = @divFloor(@as(i64, cursor.*), bl);
    const lo = (cur_bar - n + 1) * bl;
    const top = @as(i64, step_count) - 1;
    cursor.* = @intCast(std.math.clamp(lo, 0, top));
}

/// Step index at column `x` within a row, or null if `x` falls in the
/// gutter or past the last visible step. Replays the exact column math the
/// views' render loop uses (starting from `scroll`, then its separators and
/// cells) rather than deriving a closed form.
pub fn stepAt(comptime T: type, gutter: usize, cell_width: usize, scroll: u32, step_count: anytype, steps_per_beat: u8, stride: u32, x: usize) ?T {
    if (x < gutter) return null;
    var col = gutter;
    var s: u32 = scroll;
    while (s < step_count) : (s += @max(stride, 1)) {
        if (s % @max(steps_per_beat, 1) == 0) col += 1;
        if (x < col + cell_width) return if (x < col) null else @intCast(s); // `x < col`: landed on the separator itself
        col += cell_width;
    }
    return null;
}

test "stepAt follows beat separators at the live grid resolution" {
    try std.testing.expectEqual(@as(?u16, null), stepAt(u16, 10, 3, 0, 12, 3, 1, 10));
    try std.testing.expectEqual(@as(?u16, 0), stepAt(u16, 10, 3, 0, 12, 3, 1, 11));
    try std.testing.expectEqual(@as(?u16, 2), stepAt(u16, 10, 3, 0, 12, 3, 1, 17));
    try std.testing.expectEqual(@as(?u16, null), stepAt(u16, 10, 3, 0, 12, 3, 1, 20));
    try std.testing.expectEqual(@as(?u16, 3), stepAt(u16, 10, 3, 0, 12, 3, 1, 21));
}

/// Arms `op` ('d' or 'y') as a pending operator (see the operator-pending
/// block in each editor's `handleKey`): remembers the cursor as the range
/// anchor - same field visual mode's `v` sets, so the eventual delete/yank
/// reuses `selectionRange` as-is - and sets the status line. Shared body of
/// drum.zig's/slicer.zig's `armOperator`, which differ only in field names
/// and the row noun ("pad"/"slice") in the `d` status message.
/// `row_anchor` is cleared: the operator form (`d`/`y` + a motion) is
/// linewise, acting on every row across the range it covers - `v` first is
/// the route to a blockwise operator, exactly as in vim.
pub fn armOperator(app: anytype, anchor: anytype, row_anchor: anytype, cursor: anytype, op_pending: anytype, op: u8, row_noun: []const u8) void {
    anchor.* = cursor.*;
    row_anchor.* = null;
    op_pending.* = op;
    if (op == 'd')
        app.setStatus("d: h/l/H/L/g/G/w/b act on the range, dd clears the cursor {s}'s row", .{row_noun})
    else
        app.setStatus("y: h/l/H/L/g/G/w/b act on the range, yy yanks the whole pattern", .{});
}

/// Leave visual mode, clearing both anchors so the selection can't linger.
/// Shared body of drum.zig's/slicer.zig's `exitVisual`.
pub fn exitVisual(app: anytype, anchor: anytype, row_anchor: anytype) void {
    _ = app.modal.setMode(.normal);
    anchor.* = null;
    row_anchor.* = null;
}

/// `v`/`V`'s shared entry: arm a visual selection on the step axis, with the
/// row axis either anchored to the cursor row (`v`, blockwise) or left open
/// (`V`, linewise - every row). Shared body of the two editors' `v`/`V` arms.
pub fn enterVisual(app: anytype, anchor: anytype, row_anchor: anytype, cursor_step: anytype, cursor_row: anytype, blockwise: bool, row_noun: []const u8) void {
    anchor.* = cursor_step;
    row_anchor.* = if (blockwise) cursor_row else null;
    app.modal.mode = .visual;
    if (blockwise)
        app.setStatus("visual: h/l extend, j/k grow the {s} block, o corner, y/d/p, esc", .{row_noun})
    else
        app.setStatus("visual line: h/l extend (every {s}), o other end, y/d/p, esc", .{row_noun});
}

/// Force one step to a given active/velocity state via the public toggle +
/// velocity API (no direct bitmask poking, so this stays in step with
/// whatever the instrument does internally on toggle). `inst` is a
/// `*DrumMachine` or `*Slicer` - both duck-type the same step API.
pub fn setStep(inst: anytype, row: u8, step: anytype, active: bool, vel: u8) void {
    if (inst.stepActive(row, step) != active) inst.toggleStep(row, step);
    if (active) inst.setStepVel(row, step, vel);
}

/// Double a loop and copy its first half, preserving every MIDI-note field.
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
            const target = old_count + step;
            inst.midi[row][target] = inst.midi[row][step];
            if (inst.midi[row][target]) |*note| note.step = target;
        }
    }
    return true;
}

/// Clear the `rows` band's steps within `r`.
pub fn clearRange(inst: anytype, rows: RowRange, r: anytype) void {
    for (rows.lo..rows.hi + 1) |row| {
        var s = r.lo;
        while (s <= r.hi) : (s += 1) setStep(inst, @intCast(row), s, false, 0);
    }
}

/// Yank the `rows` band's steps within `r` into a heap-allocated `Clip`
/// whose `notes` fields are per-row slices sized to the range's actual width.
/// See `StepRangeClip`. Rows are stored at their absolute index; the band is
/// recorded as `row_lo`/`row_hi` so paste knows how tall the block is and
/// whether it was linewise (see `pasteBaseRow`). `r` may be any width; the
/// caller owns the result and must free it with `Clip.deinit`.
pub fn yankRangeDyn(comptime Clip: type, allocator: std.mem.Allocator, inst: anytype, rows: RowRange, r: anytype) !Clip {
    const width: u32 = @as(u32, r.hi) - @as(u32, r.lo) + 1;
    var clip: Clip = .{
        .width = @intCast(width),
        .row_lo = @intCast(rows.lo),
        .row_hi = @intCast(rows.hi),
        .notes = undefined,
    };
    // Only the selected band is allocated, so deinit must free exactly that
    // band - hence `row_lo`/`row_hi` living on the clip rather than being
    // recomputed. `row` walks absolute row indices, same as the caller's.
    var row: usize = rows.lo;
    errdefer for (rows.lo..row) |i| {
        allocator.free(clip.notes[i]);
    };
    while (row <= rows.hi) : (row += 1) {
        clip.notes[row] = try allocator.alloc(?@TypeOf(inst.*).MidiNote, width);
        var s = r.lo;
        while (s <= r.hi) : (s += 1) {
            const offset: u32 = @as(u32, s) - @as(u32, r.lo);
            clip.notes[row][offset] = inst.midi[row][s];
        }
    }
    return clip;
}

/// `pasteRange`'s counterpart for a dynamically-sized `clip` (see
/// `yankRangeDyn`/`StepRangeClip`).
pub fn pasteRangeDyn(inst: anytype, max_rows: usize, clip: anytype, base: anytype, base_row: usize) @TypeOf(base) {
    const T = @TypeOf(base);
    var i: T = 0;
    while (i < clip.width) : (i += 1) {
        const target = base +| i;
        if (target >= inst.step_count) break;
        const idx: usize = i;
        for (clip.row_lo..@as(usize, clip.row_hi) + 1) |row| {
            const dest = base_row + (row - clip.row_lo);
            if (dest >= max_rows) break;
            inst.midi[dest][target] = clip.notes[row][idx];
            if (inst.midi[dest][target]) |*note| {
                note.pitch = @intCast(dest);
                note.step = target;
            }
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

    jumpBar(&cursor, std.math.maxInt(i32), 16, 4);
    try std.testing.expectEqual(@as(u8, 15), cursor);
    operatorBarForward(&cursor, std.math.maxInt(i32), 16, 4);
    try std.testing.expectEqual(@as(u8, 15), cursor);
    operatorBarBackward(&cursor, std.math.maxInt(i32), 16, 4);
    try std.testing.expectEqual(@as(u8, 0), cursor);
}

test "bar motions handle an empty grid" {
    var cursor: u8 = 12;
    jumpBar(&cursor, 1, 0, 4);
    try std.testing.expectEqual(@as(u8, 0), cursor);
    operatorBarForward(&cursor, 1, 0, 4);
    operatorBarBackward(&cursor, 1, 0, 4);
    try std.testing.expectEqual(@as(u8, 0), cursor);
}

test "bar motions handle a zero-length bar (dynamic piano bar_len edge case)" {
    var cursor: u16 = 12;
    jumpBar(&cursor, 1, 16, @as(u16, 0));
    try std.testing.expectEqual(@as(u16, 0), cursor);
}

test "cursor motions work at u16 width past the old u8 ceiling" {
    var cursor: u16 = 200;
    moveClamped(&cursor, 100, 1000);
    try std.testing.expectEqual(@as(u16, 300), cursor);
    jumpBar(&cursor, 1, 1000, 4);
    try std.testing.expectEqual(@as(u16, 304), cursor);
    moveClamped(&cursor, std.math.maxInt(i32), 1000);
    try std.testing.expectEqual(@as(u16, 999), cursor);
}
