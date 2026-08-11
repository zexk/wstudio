//! Step-grid editing shared by `DrumMachine` (pads) and `Slicer` (slices).
//! Both store the identical `[64][]?MidiNote` grid and had a
//! character-for-character copy of these ~20 accessors, differing only in
//! the lane's name. The bodies live here once; each type keeps its own
//! one-line methods so the 200-odd call sites (and their pad/slice
//! vocabulary) are untouched.
//!
//! Grid editing and step *scheduling* are shared (the two types carry the
//! same `song_mode`/`swing`/`next_step_k`/`song_clips` state under the same
//! names, so `scanBlock` takes them as `anytype`). Voice allocation and
//! render genuinely diverge between a drum pad and a slice and stay in
//! their own files.
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

// ---------------------------------------------------------------------------
// Step scheduling (audio thread)
// ---------------------------------------------------------------------------

/// Does `note` fire on this pass? Probability and condition are ANDed,
/// Elektron-style: a `1:4` note at 70% fires on every fourth pass, and then
/// only seven times in ten.
///
/// `pass` counts completed loops through the lane that owns the note, so a
/// lane with its own shorter length counts its own repeats rather than the
/// pattern's. `step_k` is the absolute step, which is what makes the dice
/// roll vary from one pass to the next.
pub fn trigFires(note: MidiNote, lane: u8, step_k: u64, pass: u64, fill_on: bool) bool {
    if (!note.cond.holds(pass, fill_on)) return false;
    if (note.prob >= 100) return true;
    if (note.prob == 0) return false;
    return rollPercent(step_k, lane) < note.prob;
}

/// A 0-99 roll from the absolute step and the lane. SplitMix64's finalizer
/// over the two: no state to carry on the audio thread, and replaying the
/// same stretch of transport gives the same pattern back rather than a
/// different one every time the UI redraws.
fn rollPercent(step_k: u64, lane: u8) u8 {
    var z: u64 = step_k *% 0x9E3779B97F4A7C15 +% (@as(u64, lane) *% 0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= z >> 31;
    return @intCast(z % 100);
}

/// Schedules every step that could place a hit inside the next `frames`, then
/// drains the rolls those steps queued. `self` is a `*DrumMachine` or a
/// `*Slicer`; only the lane vocabulary differs between them, and that arrives
/// as `lane_len`/`lane_count`. The caller holds the type's own sample lock.
pub fn scanBlock(self: anytype, lane_len: []const u16, lane_count: usize, frames: u32) void {
    const pos_f = @as(f64, @floatFromInt(self.transport.position_frames));
    const fps = self.transport.framesPerStep(if (self.song_mode) self.song_steps_per_beat else self.steps_per_beat);
    // Swing: off-beat 16ths (odd step_k) fire late by up to half a step
    // (75% = hardest shuffle). Even steps stay on the grid, so the boundary
    // positions remain strictly increasing.
    const swing_pct = self.swing.load(.monotonic);
    var step_k = self.next_step_k;

    // Resync on discontinuity (seek, loop, first play after stop).
    const expected = @as(f64, @floatFromInt(step_k)) * fps;
    const resync_steps: u8 = if (self.song_mode) @max(2, self.song_steps_per_beat / 2) else 2;
    if (@abs(expected - pos_f) > fps * @as(f64, @floatFromInt(resync_steps))) {
        step_k = @intFromFloat(@ceil(pos_f / fps));
    }

    // "Could" rather than "does": a step's own `micro` can pull a hit up to
    // half a step ahead of its boundary, so a step whose boundary is still in
    // the future has to be considered early. The hits themselves are emitted
    // by `drainRolls` once their real positions land in a block.
    const max_early = fps * 0.5;
    while (true) {
        var fire_pos = @as(f64, @floatFromInt(step_k)) * fps;
        if (self.song_mode) {
            const ticks_per_sixteenth = @max(@as(u8, 1), self.song_steps_per_beat / 4);
            if (step_k % ticks_per_sixteenth == 0 and
                (step_k / ticks_per_sixteenth) & 1 == 1)
            {
                fire_pos += fps * ticks_per_sixteenth *
                    @as(f64, swing_pct - 50.0) / 50.0;
            }
        } else if (step_k & 1 == 1) {
            fire_pos += fps * @as(f64, swing_pct - 50.0) / 50.0;
        }
        if (fire_pos - max_early >= pos_f + @as(f64, @floatFromInt(frames))) break;

        if (self.song_mode) {
            fireSongStep(self, lane_len, lane_count, step_k, fire_pos, fps);
        } else {
            // Each lane wraps at its own length, so rows can run out of phase
            // with each other; the UI playhead still follows the pattern's
            // own length.
            const fill_on = self.fill_on.load(.monotonic);
            for (0..lane_count) |l| {
                const len = laneSteps(lane_len, @intCast(l), self.step_count);
                const idx: u16 = @intCast(step_k % len);
                const note = self.midi[l][idx] orelse continue;
                if (!trigFires(note, @intCast(l), step_k, step_k / len, fill_on)) continue;
                self.scheduleNote(@intCast(l), note, fire_pos, fps);
            }
            self.current_step.store(@intCast(step_k % self.step_count), .monotonic);
        }
        step_k += 1;
    }

    self.next_step_k = step_k;
    // After the step scan, so a roll started by a step in this very block
    // still gets its tail hits considered here.
    self.drainRolls(pos_f, frames);
}

/// Fire lanes for absolute step `step_k` from the song timeline. Past
/// `song_length_steps` this goes silent instead of wrapping - the arrangement
/// plays once through, not on a loop.
fn fireSongStep(self: anytype, lane_len: []const u16, lane_count: usize, step_k: u64, fire_pos: f64, tick_frames: f64) void {
    if (self.song_length_steps == 0 or step_k >= self.song_length_steps) return;
    const lk: u32 = @intCast(step_k);
    for (self.song_clips[0..self.song_clip_count]) |*clip| {
        if (lk < clip.start_step or lk >= clip.start_step + clip.span_steps) continue;
        if (clip.step_count == 0) return;
        const elapsed = lk - clip.start_step;
        const scaled = elapsed * clip.steps_per_beat;
        if (scaled % self.song_steps_per_beat != 0) continue;
        const local: u32 = scaled / self.song_steps_per_beat;
        const fill_on = self.fill_on.load(.monotonic);
        // The song timeline ticks finer than the clip's own grid, so a roll
        // has to be spaced across a *clip* step, not a song tick.
        const step_frames = tick_frames *
            @as(f64, @floatFromInt(self.song_steps_per_beat)) /
            @as(f64, @floatFromInt(@max(clip.steps_per_beat, 1)));
        for (0..lane_count) |l| {
            const len = laneSteps(lane_len, @intCast(l), clip.step_count);
            const idx: u16 = @intCast(local % len);
            const note = clip.midi[l][idx] orelse continue;
            if (!trigFires(note, @intCast(l), step_k, local / len, fill_on)) continue;
            self.scheduleNote(@intCast(l), note, fire_pos, step_frames);
        }
        self.current_step.store(@intCast(local % clip.step_count), .monotonic);
        return; // clips never overlap
    }
    // No clip under the playhead: keep the UI step indicator moving through
    // the gap instead of freezing on the last clip's step.
    self.current_step.store(@intCast(lk % self.step_count), .monotonic);
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
