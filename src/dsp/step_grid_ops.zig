//! Step-grid editing shared by `DrumMachine` (pads) and `Slicer` (slices).
//! Both store the identical `[64][]?MidiNote` grid and had a
//! character-for-character copy of these ~20 accessors, differing only in
//! the lane's name. The bodies live here once; each type keeps its own
//! one-line methods so the 200-odd call sites (and their pad/slice
//! vocabulary) are untouched.
//!
//! Only grid editing is shared. Triggering and render genuinely diverge
//! between a drum pad and a slice and are deliberately NOT merged.
//!
//! `midi` is `[]const []?MidiNote` throughout: the outer array is never
//! reshaped here, only the notes inside it, so the same parameter serves
//! the readers and the writers.

const std = @import("std");

const DrumMachine = @import("drum_sampler.zig").DrumMachine;
const MidiNote = DrumMachine.MidiNote;
const Cond = DrumMachine.Cond;
const vel_full = DrumMachine.vel_full;

/// Named preset bands `cycleStepVel`'s quick single-key gesture steps
/// through: 127→95→63→31→127.
const vel_presets = [_]u8{ 127, 95, 63, 31 };

/// Preset chances `cycleStepProb` walks, in the order one key press steps
/// through them - the same "a few useful values beat a continuous range you
/// have to nudge" call `vel_presets` already made.
const prob_presets = [_]u8{ 100, 75, 50, 25, 10 };

/// Roll sizes `cycleStepRetrig` walks: off, then the divisions that stay
/// musical inside one step. 0 renders as a plain single hit.
const retrig_presets = [_]u8{ 0, 2, 3, 4, 6, 8 };

/// The note at `lane`/`step`, or null when either is out of range. Every
/// accessor below routes its bounds check through this.
fn at(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) ?*MidiNote {
    if (lane >= midi.len or step >= step_count) return null;
    return if (midi[lane][step]) |*note| note else null;
}

pub fn stepActive(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) bool {
    return at(midi, step_count, lane, step) != null;
}

/// Toggle a step on (at full velocity) or off. Out of range does nothing.
pub fn toggleStep(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) void {
    if (lane >= midi.len or step >= step_count) return;
    midi[lane][step] = if (midi[lane][step] == null)
        DrumMachine.gridNote(lane, step, vel_full)
    else
        null;
}

/// One step's velocity, 0-127 (127 = full, see velGain). 127 for a step
/// with no note, matching a fresh/toggled-on step's default.
pub fn stepVel(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) u8 {
    const note = at(midi, step_count, lane, step) orelse return vel_full;
    return note.velocity;
}

pub fn setStepVel(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, level: u8) void {
    if (at(midi, step_count, lane, step)) |note| note.velocity = @intCast(@min(level, vel_full));
}

/// Cycle through the named preset bands (127→95→63→31→127) - a quick
/// single-key gesture; `nudgeStepVel` covers the full 1-127 range.
pub fn cycleStepVel(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) void {
    const cur = stepVel(midi, step_count, lane, step);
    var idx: usize = vel_presets.len - 1; // not a preset value -> next lands on preset[0]
    for (vel_presets, 0..) |v, i| {
        // zig fmt: off
        if (v == cur) { idx = i; break; }
        // zig fmt: on
    }
    setStepVel(midi, step_count, lane, step, vel_presets[(idx + 1) % vel_presets.len]);
}

/// Nudge one step's velocity by `delta`, clamped to 1..127 - 0 would be
/// silent; the caller's remove-step key covers zeroing a hit.
pub fn nudgeStepVel(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, delta: i32) void {
    const cur: i32 = stepVel(midi, step_count, lane, step);
    setStepVel(midi, step_count, lane, step, @intCast(std.math.clamp(cur + delta, 1, 127)));
}

/// Fire chance of the step in percent; 100 on an empty step.
pub fn stepProb(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) u8 {
    const note = at(midi, step_count, lane, step) orelse return 100;
    return note.prob;
}

/// Set the chance outright, clamped to 0-100. The keyboard only walks
/// `prob_presets`; scripts (and anything else wanting an exact value) need
/// the direct setter, same split `stepVel` already has.
pub fn setStepProb(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, percent: i32) void {
    if (at(midi, step_count, lane, step)) |note| note.prob = @intCast(std.math.clamp(percent, 0, 100));
}

pub fn cycleStepProb(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) void {
    const note = at(midi, step_count, lane, step) orelse return;
    for (prob_presets, 0..) |p, i| {
        if (note.prob == p) {
            note.prob = prob_presets[(i + 1) % prob_presets.len];
            return;
        }
    }
    note.prob = prob_presets[0];
}

/// Timing offset of the step as a percent of one step; 0 on an empty one.
pub fn stepMicro(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) i8 {
    const note = at(midi, step_count, lane, step) orelse return 0;
    return note.micro;
}

/// Half a step either way. Past that a hit would cross its neighbour's
/// boundary, which is a different step, not a feel.
pub fn setStepMicro(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, pct: i32) void {
    if (at(midi, step_count, lane, step)) |note| note.micro = @intCast(std.math.clamp(pct, -50, 50));
}

pub fn nudgeStepMicro(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, delta: i32) void {
    setStepMicro(midi, step_count, lane, step, @as(i32, stepMicro(midi, step_count, lane, step)) + delta);
}

/// Hits packed into the step; 0 (a plain single hit) on an empty step.
pub fn stepRetrig(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) u8 {
    const note = at(midi, step_count, lane, step) orelse return 0;
    return note.retrig;
}

/// Set the roll size outright, clamped to 0-8 (the widest `retrig_presets`
/// entry). Direct-setter twin of `cycleStepRetrig`.
pub fn setStepRetrig(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, hits: i32) void {
    if (at(midi, step_count, lane, step)) |note| note.retrig = @intCast(std.math.clamp(hits, 0, 8));
}

pub fn cycleStepRetrig(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) void {
    const note = at(midi, step_count, lane, step) orelse return;
    for (retrig_presets, 0..) |r, i| {
        if (note.retrig == r) {
            note.retrig = retrig_presets[(i + 1) % retrig_presets.len];
            return;
        }
    }
    note.retrig = retrig_presets[0];
}

/// Trig condition on the step; `always` on an empty step.
pub fn stepCond(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) Cond {
    const note = at(midi, step_count, lane, step) orelse return .always;
    return note.cond;
}

/// Set the condition outright. Direct-setter twin of `cycleStepCond`.
pub fn setStepCond(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, cond: Cond) void {
    if (at(midi, step_count, lane, step)) |note| note.cond = cond;
}

/// Walk the condition list by `delta` (wrapping), the keyboard stand-in for
/// the hardware's encoder.
pub fn cycleStepCond(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, delta: i32) void {
    const note = at(midi, step_count, lane, step) orelse return;
    const count: i32 = @typeInfo(Cond).@"enum".fields.len;
    const cur: i32 = @intFromEnum(note.cond);
    note.cond = @enumFromInt(@mod(cur + delta, count));
}

/// Per-step transpose in semitones, 0 on an empty step (nothing to tune).
pub fn stepTune(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16) i8 {
    const note = at(midi, step_count, lane, step) orelse return 0;
    return note.tune;
}

/// Same ±24 semitone range a lane's own pitch param clamps to, so a hit
/// can't be tuned somewhere the lane itself could never reach.
pub fn setStepTune(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, semis: i32) void {
    if (at(midi, step_count, lane, step)) |note| note.tune = @intCast(std.math.clamp(semis, -24, 24));
}

pub fn nudgeStepTune(midi: []const []?MidiNote, step_count: u16, lane: u8, step: u16, delta: i32) void {
    setStepTune(midi, step_count, lane, step, @as(i32, stepTune(midi, step_count, lane, step)) + delta);
}

/// Steps lane `l` actually loops over inside a `pattern_len`-long pattern:
/// its own `lane_len` entry when that's set and fits, else the whole
/// pattern. The audio thread reads this every step boundary, so it stays
/// branch-cheap and never touches storage it doesn't have.
pub fn laneSteps(lane_len: []const u16, lane: u8, pattern_len: u16) u16 {
    if (lane >= lane_len.len or pattern_len == 0) return @max(pattern_len, 1);
    const own = lane_len[lane];
    if (own == 0 or own > pattern_len) return pattern_len;
    return @max(own, 1);
}

/// Set lane `l`'s own loop length; 0 (or anything past the pattern) goes
/// back to following the pattern.
pub fn setLaneLen(lane_len: []u16, step_count: u16, lane: u8, len: u16) void {
    if (lane >= lane_len.len) return;
    lane_len[lane] = if (len >= step_count) 0 else len;
}

/// Nudge lane `l`'s loop length, treating "follows the pattern" as the full
/// length so stepping down from it lands one below rather than jumping to 1.
pub fn nudgeLaneLen(lane_len: []u16, step_count: u16, lane: u8, delta: i32) void {
    if (lane >= lane_len.len) return;
    const cur: i32 = laneSteps(lane_len, lane, step_count);
    setLaneLen(lane_len, step_count, lane, @intCast(std.math.clamp(cur + delta, 1, step_count)));
}

test "an empty step reads back its neutral default and ignores every setter" {
    var row = [_]?MidiNote{null} ** 4;
    var grid = [_][]?MidiNote{&row};

    try std.testing.expect(!stepActive(&grid, 4, 0, 0));
    try std.testing.expectEqual(@as(u8, vel_full), stepVel(&grid, 4, 0, 0));
    try std.testing.expectEqual(@as(u8, 100), stepProb(&grid, 4, 0, 0));
    try std.testing.expectEqual(@as(i8, 0), stepMicro(&grid, 4, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), stepRetrig(&grid, 4, 0, 0));
    try std.testing.expectEqual(Cond.always, stepCond(&grid, 4, 0, 0));
    try std.testing.expectEqual(@as(i8, 0), stepTune(&grid, 4, 0, 0));

    // Nothing to edit on an empty step: every setter is a no-op rather than
    // materialising a note out of a parameter change.
    setStepVel(&grid, 4, 0, 0, 64);
    setStepProb(&grid, 4, 0, 0, 25);
    cycleStepRetrig(&grid, 4, 0, 0);
    cycleStepCond(&grid, 4, 0, 0, 1);
    try std.testing.expect(!stepActive(&grid, 4, 0, 0));
}

test "step edits clamp to their range and cycles wrap" {
    var row = [_]?MidiNote{null} ** 4;
    var grid = [_][]?MidiNote{&row};

    toggleStep(&grid, 4, 0, 1);
    try std.testing.expect(stepActive(&grid, 4, 0, 1));
    try std.testing.expectEqual(@as(u8, vel_full), stepVel(&grid, 4, 0, 1));

    setStepVel(&grid, 4, 0, 1, 200);
    try std.testing.expectEqual(@as(u8, vel_full), stepVel(&grid, 4, 0, 1));
    nudgeStepVel(&grid, 4, 0, 1, -500);
    try std.testing.expectEqual(@as(u8, 1), stepVel(&grid, 4, 0, 1));

    setStepProb(&grid, 4, 0, 1, 500);
    try std.testing.expectEqual(@as(u8, 100), stepProb(&grid, 4, 0, 1));
    cycleStepProb(&grid, 4, 0, 1);
    try std.testing.expectEqual(@as(u8, 75), stepProb(&grid, 4, 0, 1));

    nudgeStepMicro(&grid, 4, 0, 1, -900);
    try std.testing.expectEqual(@as(i8, -50), stepMicro(&grid, 4, 0, 1));
    nudgeStepTune(&grid, 4, 0, 1, 900);
    try std.testing.expectEqual(@as(i8, 24), stepTune(&grid, 4, 0, 1));
    setStepRetrig(&grid, 4, 0, 1, 99);
    try std.testing.expectEqual(@as(u8, 8), stepRetrig(&grid, 4, 0, 1));

    // Walking the condition list backwards from `always` wraps to the last
    // entry rather than going negative.
    cycleStepCond(&grid, 4, 0, 1, -1);
    const last: Cond = @enumFromInt(@typeInfo(Cond).@"enum".fields.len - 1);
    try std.testing.expectEqual(last, stepCond(&grid, 4, 0, 1));

    toggleStep(&grid, 4, 0, 1);
    try std.testing.expect(!stepActive(&grid, 4, 0, 1));

    // Out-of-range lanes and steps are silently ignored, not clamped onto a
    // neighbouring cell.
    toggleStep(&grid, 4, 9, 0);
    toggleStep(&grid, 4, 0, 99);
    try std.testing.expect(!stepActive(&grid, 4, 0, 0));
}

test "a lane loop length of 0 or past the pattern follows the pattern" {
    var lens = [_]u16{ 0, 4, 32 };

    try std.testing.expectEqual(@as(u16, 16), laneSteps(&lens, 0, 16));
    try std.testing.expectEqual(@as(u16, 4), laneSteps(&lens, 1, 16));
    try std.testing.expectEqual(@as(u16, 16), laneSteps(&lens, 2, 16));
    try std.testing.expectEqual(@as(u16, 16), laneSteps(&lens, 9, 16));

    // Setting the full pattern length means "follow the pattern", stored as 0.
    setLaneLen(&lens, 16, 1, 16);
    try std.testing.expectEqual(@as(u16, 0), lens[1]);

    // Nudging down from "follows the pattern" lands one below the full
    // length instead of jumping to 1.
    nudgeLaneLen(&lens, 16, 1, -1);
    try std.testing.expectEqual(@as(u16, 15), lens[1]);
}
