//! Piano-roll pattern sequencer.
//!
//! PatternPlayer sits at chain[0] for melodic racks (synth or sampler). Its
//! process() fires note_on / note_off events into the instrument device at
//! chain[1] every block, driven by the transport exactly like the drum
//! machine. Notes are stored in beats (1 beat = 1 quarter note); the view
//! layer converts steps to beats via step / 4.0.
//!
//! The target is a plain `dsp.Device`, so any note-driven instrument can be
//! sequenced - note events go through the same vtable the live keyboard uses.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;
const PolySynth = @import("synth.zig").PolySynth;

pub const max_notes: u16 = 512;

/// What a note lands at when nothing supplies a velocity (step edits, the
/// qwerty piano) - recorded MIDI carries its own.
pub const default_velocity: f32 = 0.85;

// zig fmt: off
pub const Note = struct {
    pitch:         u7,
    start_beat:    f64,
    duration_beat: f64,
    velocity:      f32 = default_velocity,
};
// zig fmt: on

/// A piano-roll range selection: a half-open time window, optionally
/// narrowed to a pitch band. The full-pitch default is what the piano
/// roll's linewise visual mode (`V`) and every whole-pattern command pass,
/// so a caller that doesn't care about the pitch axis just omits it.
pub const Sel = struct {
    lo_beat: f64,
    hi_beat: f64,
    pitch_lo: u7 = 0,
    pitch_hi: u7 = 127,

    pub fn contains(self: Sel, n: Note) bool {
        return n.start_beat >= self.lo_beat and n.start_beat < self.hi_beat and
            n.pitch >= self.pitch_lo and n.pitch <= self.pitch_hi;
    }
};

// zig fmt: off

pub const PatternPlayer = struct {
    pub const swing_min: f32 = 50.0;
    pub const swing_max: f32 = 75.0;

    /// Instrument fed note events (synth, sampler, …). Stable for the rack's
    /// lifetime because the rack is heap-allocated.
    target:    dsp.Device,
    transport: *const Transport,

    notes_lock: std.atomic.Mutex = .unlocked,
    notes:      [max_notes]Note = undefined,
    // zig fmt: on
    note_count: u16 = 0,
    /// Loop length in beats (default 4 = 1 bar in 4/4).
    length_beats: f64 = 4.0,
    /// Swing percent (see `swing_min`/`swing_max`): every note landing on an
    /// off-beat 16th (odd step, 0.25 beat each) fires late by up to a
    /// quarter of a step (75% = hardest shuffle) - mirrors DrumMachine's
    /// swing exactly, so a melodic track can match a swung drum groove.
    swing: std.atomic.Value(f32) = .init(50.0),

    // ── Song-mode playback ───────────────────────────────────────────────────
    /// When true, process() plays `song_notes` (the arrangement's clips
    /// flattened to absolute beats) instead of the live loop above. Set by the
    // zig fmt: off
    /// control thread via Session.setSongMode; read on the audio thread.
    song_mode:        bool = false,
    /// The lane's clips flattened into one timeline: each note carries its
    /// absolute start_beat (clip start + note offset). Guarded by `notes_lock`.
    song_notes:       [max_notes]Note = undefined,
    song_note_count:  u16 = 0,
    /// Loop length of the whole arrangement in beats. Past this point
    /// process() goes silent instead of wrapping - the arrangement plays
    /// once through, unlike the live loop above.
    song_length_beats: f64 = 0.0,

    // ── Audio-thread-only state ──────────────────────────────────────────────
    /// Which MIDI pitches are currently sounding (audio thread only).
    sounding:        [128]bool = [_]bool{false} ** 128,
    /// Pitches removed by the UI thread before their scheduled note-off.
    pending_note_off: [2]std.atomic.Value(u64) = .{ .init(0), .init(0) },
    // zig fmt: on
    /// Expected transport position at the start of the next block.
    /// 0 = first block or after a reset.
    last_pos_frames: u64 = 0,

    pub fn init(target: dsp.Device, transport: *const Transport) PatternPlayer {
        return .{ .target = target, .transport = transport };
    }

    pub const device = dsp.deviceOf(@This());

    // ── UI-thread note editing ───────────────────────────────────────────────

    fn sanitizeNote(note: Note) Note {
        return .{
            .pitch = note.pitch,
            .start_beat = if (std.math.isFinite(note.start_beat) and note.start_beat >= 0.0) note.start_beat else 0.0,
            .duration_beat = if (std.math.isFinite(note.duration_beat) and note.duration_beat >= 0.0) note.duration_beat else 0.0,
            .velocity = if (std.math.isFinite(note.velocity)) std.math.clamp(note.velocity, 0.0, 1.0) else default_velocity,
        };
    }

    pub fn addNote(self: *PatternPlayer, note: Note) void {
        _ = self.tryAddNote(note);
    }

    /// Add one note and report whether it fit. Interactive callers use the
    /// result to surface the fixed real-time pattern capacity instead of
    /// pretending an edit landed.
    pub fn tryAddNote(self: *PatternPlayer, note: Note) bool {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        if (self.note_count >= max_notes) return false;
        self.notes[self.note_count] = sanitizeNote(note);
        self.note_count += 1;
        return true;
    }

    /// Remove the first note whose pitch and start_beat match (UI thread).
    pub fn removeNote(self: *PatternPlayer, pitch: u7, start_beat: f64) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var i: usize = 0;
        while (i < self.note_count) : (i += 1) {
            const n = self.notes[i];
            if (n.pitch == pitch and @abs(n.start_beat - start_beat) < 1e-9) {
                self.notes[i] = self.notes[self.note_count - 1];
                self.note_count -= 1;
                self.queueNoteOff(pitch);
                return;
            }
        }
    }

    /// Replace the song-mode note timeline (UI thread). `notes` hold absolute
    /// beat positions; `length` is the whole-arrangement loop length in beats.
    /// Taken under the same lock the audio thread tries, so a rebuild never
    /// tears a block that is mid-scan.
    pub fn setSongNotes(self: *PatternPlayer, notes: []const Note, length_beats: f64) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        const count = @min(notes.len, @as(usize, max_notes));
        for (notes[0..count], self.song_notes[0..count]) |n, *dst| dst.* = sanitizeNote(n);
        self.song_note_count = @intCast(count);
        self.song_length_beats = if (std.math.isFinite(length_beats) and length_beats >= 0.0) length_beats else 0.0;
    }

    /// Copy the live notes into `out` (UI thread). Returns the count copied.
    /// The yank half of the pattern clipboard.
    pub fn copyNotes(self: *PatternPlayer, out: []Note) u16 {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        const count: u16 = @intCast(@min(self.note_count, out.len));
        for (self.notes[0..count], out[0..count]) |n, *dst| dst.* = n;
        return count;
    }

    /// Replace the live notes and loop length wholesale (UI thread). The
    /// paste half of the pattern clipboard.
    pub fn setNotes(self: *PatternPlayer, notes: []const Note, length_beats: f64) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        const count = @min(notes.len, @as(usize, max_notes));
        for (notes[0..count], self.notes[0..count]) |n, *dst| dst.* = sanitizeNote(n);
        self.note_count = @intCast(count);
        self.length_beats = if (std.math.isFinite(length_beats)) @max(1.0, length_beats) else 4.0;
    }

    /// Remove every note (UI thread). Used by :clear.
    pub fn clearNotes(self: *PatternPlayer) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        self.note_count = 0;
    }

    /// Copy the notes `sel` covers into `out`, rebased so `sel.lo_beat`
    /// becomes 0 (UI thread). Returns the count copied - the yank half of
    /// the piano roll's visual-mode range clipboard.
    pub fn copyNotesInRange(self: *PatternPlayer, sel: Sel, out: []Note) u16 {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var n: u16 = 0;
        for (self.notes[0..self.note_count]) |note| {
            if (sel.contains(note) and n < out.len) {
                out[n] = note;
                out[n].start_beat -= sel.lo_beat;
                n += 1;
            }
        }
        return n;
    }

    /// Remove every note on one pitch, across the whole pattern (UI
    /// thread). Returns the count removed - the piano roll's `dd`, where a
    /// "line" is the cursor pitch's whole row.
    pub fn removeNotesAtPitch(self: *PatternPlayer, pitch: u7) u16 {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var removed: u16 = 0;
        var i: usize = 0;
        while (i < self.note_count) {
            if (self.notes[i].pitch == pitch) {
                self.notes[i] = self.notes[self.note_count - 1];
                self.note_count -= 1;
                removed += 1;
            } else i += 1;
        }
        if (removed > 0) self.queueNoteOff(pitch);
        return removed;
    }

    /// Remove every note `sel` covers (UI thread). Returns the count removed
    /// - the delete half of the piano roll's visual-mode range selection.
    pub fn removeNotesInRange(self: *PatternPlayer, sel: Sel) u16 {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var removed: u16 = 0;
        var i: usize = 0;
        while (i < self.note_count) {
            const n = self.notes[i];
            if (sel.contains(n)) {
                self.notes[i] = self.notes[self.note_count - 1];
                self.note_count -= 1;
                self.queueNoteOff(n.pitch);
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    /// Move every note `sel` covers by `dpitch` semitones and `dbeat` beats
    /// (UI thread) - the piano roll's visual-mode transpose (`+`/`-`) and
    /// time-slide (`<`/`>`). All-or-nothing: returns null without touching
    /// anything if any note in the range would leave the MIDI pitch range or
    /// the pattern's [0, length) window, so a chord shape can never be
    /// clamped into a cluster. Otherwise returns the count moved.
    pub fn shiftNotesInRange(self: *PatternPlayer, sel: Sel, dpitch: i32, dbeat: f64) ?u16 {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        for (self.notes[0..self.note_count]) |n| {
            if (!sel.contains(n)) continue;
            const p = @as(i32, n.pitch) + dpitch;
            if (p < 0 or p > 127) return null;
            const b = n.start_beat + dbeat;
            if (b < -1e-9 or b >= self.length_beats - 1e-9) return null;
        }
        var moved: u16 = 0;
        for (self.notes[0..self.note_count]) |*n| {
            if (!sel.contains(n.*)) continue;
            // Choke a sounding note before moving it (no-op for silent
            // pitches): a time-slide moves the off boundary too, and if
            // that lands behind the playhead (slide left) the note_off
            // would not fire until the loop wraps - a stuck note for up
            // to a whole loop.
            self.queueNoteOff(n.pitch);
            if (dpitch != 0) n.pitch = @intCast(@as(i32, n.pitch) + dpitch);
            n.start_beat = @max(0.0, n.start_beat + dbeat);
            moved += 1;
        }
        return moved;
    }

    /// Time-mirror (retrograde) every note `sel` covers: a note occupying
    /// [s, s+d) maps to [lo+hi-s-d, lo+hi-s), so it ends where it used to
    /// begin and the figure plays backwards. A note whose tail overhangs the
    /// range clamps to the range start instead of escaping left of it.
    /// Returns the count moved (UI thread).
    pub fn reverseNotesInRange(self: *PatternPlayer, sel: Sel) u16 {
        if (!std.math.isFinite(sel.lo_beat) or !std.math.isFinite(sel.hi_beat) or sel.hi_beat <= sel.lo_beat) return 0;
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var moved: u16 = 0;
        for (self.notes[0..self.note_count]) |*n| {
            if (!sel.contains(n.*)) continue;
            // Same stuck-note hazard as shiftNotesInRange: the off boundary
            // moves too, so choke anything sounding before it goes.
            self.queueNoteOff(n.pitch);
            n.start_beat = @max(sel.lo_beat, sel.lo_beat + sel.hi_beat - n.start_beat - n.duration_beat);
            moved += 1;
        }
        return moved;
    }

    /// Linearly ramp note velocities across [lo_beat, hi_beat): the
    /// earliest note start gets `v0`, the latest `v1`, everything between
    /// interpolates by its start position - a crescendo in one call. Chords
    /// sharing a start share a value; a lone distinct start gets `v1` (the
    /// ramp's target). Velocity-only in-place writes, so no lock is needed
    /// (same contract as `noteAt`). Returns the count touched (UI thread).
    pub fn velocityRamp(self: *PatternPlayer, lo_beat: f64, hi_beat: f64, v0: f32, v1: f32) u16 {
        if (!std.math.isFinite(v0) or !std.math.isFinite(v1)) return 0;
        var first = std.math.inf(f64);
        var last = -std.math.inf(f64);
        for (self.notes[0..self.note_count]) |n| {
            if (n.start_beat < lo_beat or n.start_beat >= hi_beat) continue;
            first = @min(first, n.start_beat);
            last = @max(last, n.start_beat);
        }
        if (first > last) return 0;
        var touched: u16 = 0;
        for (self.notes[0..self.note_count]) |*n| {
            if (n.start_beat < lo_beat or n.start_beat >= hi_beat) continue;
            const t: f32 = if (last > first) @floatCast((n.start_beat - first) / (last - first)) else 1.0;
            n.velocity = std.math.clamp(v0 + (v1 - v0) * t, 0.05, 1.0);
            touched += 1;
        }
        return touched;
    }

    /// Extend every note in [lo_beat, hi_beat) to the next note onset (any
    /// pitch), so a line plays gapless - the classic legato tool. Notes
    /// sharing a start (a chord) all reach the same next onset; the last
    /// onset in range extends to `hi_beat`. Shrinks overlapping tails too,
    /// so the result is exactly-touching, never stacked. Returns the count
    /// whose duration changed (UI thread).
    pub fn legato(self: *PatternPlayer, lo_beat: f64, hi_beat: f64) u16 {
        if (!std.math.isFinite(lo_beat) or !std.math.isFinite(hi_beat) or hi_beat <= lo_beat) return 0;
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var changed: u16 = 0;
        for (self.notes[0..self.note_count]) |*n| {
            if (n.start_beat < lo_beat or n.start_beat >= hi_beat) continue;
            // Next distinct onset after this one, among notes in range.
            var next = hi_beat;
            for (self.notes[0..self.note_count]) |m| {
                if (m.start_beat < lo_beat or m.start_beat >= hi_beat) continue;
                if (m.start_beat > n.start_beat + 1e-9 and m.start_beat < next) next = m.start_beat;
            }
            const dur = next - n.start_beat;
            if (@abs(dur - n.duration_beat) < 1e-9) continue;
            // The off boundary moves; choke a sounding note so a shrunk
            // tail can't strand its note_off (same hazard as
            // shiftNotesInRange).
            self.queueNoteOff(n.pitch);
            n.duration_beat = dur;
            changed += 1;
        }
        return changed;
    }

    /// Stagger every chord (notes sharing the same start_beat, within
    /// epsilon) into a strum: each note in a group is delayed by its rank
    /// times `offset_beats`, one note always staying exactly on the beat -
    /// a lone note is its own one-member group and never moves. A positive
    /// offset ranks low-to-high (bass note on the beat, trailing upward - a
    /// down-strum); negative ranks high-to-low (an up-strum). Delays are
    /// always forward in time regardless of sign, clamped to stay inside
    /// [lo_beat, hi_beat). Only start_beat moves - duration is untouched,
    /// same "nudge, don't choke" contract as humanize/quantize (offsets
    /// here are similarly small, a manual feel pass rather than a
    /// structural edit). Returns the count of notes actually delayed.
    pub fn strum(self: *PatternPlayer, lo_beat: f64, hi_beat: f64, offset_beats: f64) u16 {
        if (!std.math.isFinite(lo_beat) or !std.math.isFinite(hi_beat) or hi_beat <= lo_beat) return 0;
        if (!std.math.isFinite(offset_beats)) return 0;
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();

        const eps = 1e-9;
        const n = self.note_count;
        // Two passes: first work out every note's rank within its chord
        // (by pitch, ascending; index breaks ties) without touching
        // anything, so a note being delayed can't shift another note's
        // rank mid-scan.
        var rank_asc: [max_notes]u16 = undefined;
        var group_size: [max_notes]u16 = undefined;
        for (self.notes[0..n], 0..) |a, i| {
            if (a.start_beat < lo_beat or a.start_beat >= hi_beat) continue;
            var asc: u16 = 0;
            var size: u16 = 1;
            for (self.notes[0..n], 0..) |b, j| {
                if (j == i or @abs(b.start_beat - a.start_beat) >= eps) continue;
                size += 1;
                if (b.pitch < a.pitch or (b.pitch == a.pitch and j < i)) asc += 1;
            }
            rank_asc[i] = asc;
            group_size[i] = size;
        }

        var touched: u16 = 0;
        for (self.notes[0..n], 0..) |*note, i| {
            if (note.start_beat < lo_beat or note.start_beat >= hi_beat) continue;
            const rank: u16 = if (offset_beats >= 0.0) rank_asc[i] else group_size[i] - 1 - rank_asc[i];
            if (rank == 0) continue;
            const delay = @as(f64, @floatFromInt(rank)) * @abs(offset_beats);
            note.start_beat = @min(note.start_beat + delay, hi_beat - eps);
            touched += 1;
        }
        return touched;
    }

    /// Merge notes `sel` covers that share a pitch and touch or overlap into
    /// one long note - FL's glue tool, the inverse of `chop`. A merged note
    /// spans from the earliest start to the latest end of the group and
    /// keeps the surviving note's velocity; a real gap between two notes
    /// leaves them alone, so gluing a whole pattern only welds what was
    /// already contiguous. Returns the count absorbed (UI thread).
    pub fn glue(self: *PatternPlayer, sel: Sel) u16 {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        const eps = 1e-9;
        var merged: u16 = 0;
        var i: usize = 0;
        while (i < self.note_count) : (i += 1) {
            if (!sel.contains(self.notes[i])) continue;
            // Restart the scan after every absorption: the merged note is
            // longer than it was, so it may now reach a note that used to
            // be out of range.
            var absorbing = true;
            while (absorbing) {
                absorbing = false;
                const a = self.notes[i];
                const a_end = a.start_beat + a.duration_beat;
                for (self.notes[0..self.note_count], 0..) |b, j| {
                    if (j == i or b.pitch != a.pitch or !sel.contains(b)) continue;
                    const b_end = b.start_beat + b.duration_beat;
                    if (b.start_beat > a_end + eps or a.start_beat > b_end + eps) continue;
                    const lo = @min(a.start_beat, b.start_beat);
                    self.notes[i].start_beat = lo;
                    self.notes[i].duration_beat = @max(a_end, b_end) - lo;
                    self.queueNoteOff(a.pitch);
                    self.notes[j] = self.notes[self.note_count - 1];
                    self.note_count -= 1;
                    // Swap-remove moves the last note into `j`; if that was
                    // the note being extended, follow it to its new index.
                    if (i == self.note_count) i = j;
                    merged += 1;
                    absorbing = true;
                    break;
                }
            }
        }
        return merged;
    }

    /// Split every note `sel` covers into `step_beats`-long pieces - FL's
    /// chop tool, the inverse of `glue`. The final piece keeps whatever
    /// remainder is left rather than overshooting the original end, and a
    /// note already shorter than one piece is left alone. All-or-nothing on
    /// capacity: returns null without touching anything if the split would
    /// need more than `max_notes`, since half a chopped pattern is worse
    /// than none. Otherwise returns the count of pieces added (UI thread).
    pub fn chop(self: *PatternPlayer, sel: Sel, step_beats: f64) ?u16 {
        if (!std.math.isFinite(step_beats) or step_beats <= 0.0) return 0;
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var extra: usize = 0;
        for (self.notes[0..self.note_count]) |n| {
            if (!sel.contains(n)) continue;
            extra += pieceCount(n.duration_beat, step_beats) - 1;
        }
        if (extra == 0) return 0;
        if (self.note_count + extra > max_notes) return null;

        const original = self.note_count;
        for (self.notes[0..original], 0..) |n, i| {
            if (!sel.contains(n)) continue;
            const pieces = pieceCount(n.duration_beat, step_beats);
            if (pieces == 1) continue;
            const end = n.start_beat + n.duration_beat;
            self.queueNoteOff(n.pitch);
            self.notes[i].duration_beat = step_beats;
            for (1..pieces) |p| {
                const start = n.start_beat + @as(f64, @floatFromInt(p)) * step_beats;
                self.notes[self.note_count] = .{
                    .pitch = n.pitch,
                    .start_beat = start,
                    .duration_beat = @min(step_beats, end - start),
                    .velocity = n.velocity,
                };
                self.note_count += 1;
            }
        }
        return @intCast(extra);
    }

    /// How many `step_beats` pieces `duration_beat` chops into: always at
    /// least one, and capped at the pattern's own capacity so an absurdly
    /// small step can't produce a piece count no pattern could hold anyway.
    fn pieceCount(duration_beat: f64, step_beats: f64) usize {
        if (duration_beat <= step_beats + 1e-9) return 1;
        const n = @ceil(duration_beat / step_beats - 1e-9);
        return @intFromFloat(@max(1.0, @min(n, @as(f64, @floatFromInt(max_notes)))));
    }

    fn queueNoteOff(self: *PatternPlayer, pitch: u7) void {
        const word: usize = pitch / 64;
        const bit = @as(u64, 1) << @intCast(pitch % 64);
        _ = self.pending_note_off[word].fetchOr(bit, .release);
    }

    /// Jitters every live note's timing (±`amount_pct`% of one grid step,
    /// clamped inside the loop) and velocity (±`amount_pct`%, relative,
    /// clamped to (0, 1]) - the `:humanize` command. Unlike `noteAt`'s
    /// callers this moves `start_beat`, so it takes the full lock rather
    /// than mutating in place.
    pub fn humanize(self: *PatternPlayer, amount_pct: f64, step_beats: f64, seed: u64) void {
        if (!std.math.isFinite(amount_pct) or !std.math.isFinite(step_beats) or step_beats <= 0.0) return;
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const frac = std.math.clamp(amount_pct, 0.0, 100.0) / 100.0;
        const max_start = @max(0.0, self.length_beats - step_beats);
        for (self.notes[0..self.note_count]) |*n| {
            const dt = (rand.float(f64) * 2.0 - 1.0) * frac * step_beats;
            n.start_beat = std.math.clamp(n.start_beat + dt, 0.0, max_start);
            const dv = (rand.float(f32) * 2.0 - 1.0) * @as(f32, @floatCast(frac));
            n.velocity = std.math.clamp(n.velocity + dv, 0.05, 1.0);
        }
    }

    /// Pull every live note's start toward the nearest multiple of
    /// `step_beats` by `strength_pct`% (100 = hard-snap to the grid, 0 =
    /// no-op, partial values ease toward it without fully losing the
    /// original feel) - the `:quantize` command, the deliberate counterpart
    /// to `humanize`'s jitter. Same lock/clamp shape as `humanize` since it
    /// moves `start_beat` too.
    pub fn quantize(self: *PatternPlayer, step_beats: f64, strength_pct: f64) void {
        if (!std.math.isFinite(step_beats) or step_beats <= 0.0) return;
        if (!std.math.isFinite(strength_pct)) return;
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        const frac = std.math.clamp(strength_pct, 0.0, 100.0) / 100.0;
        const max_start = @max(0.0, self.length_beats - step_beats);
        for (self.notes[0..self.note_count]) |*n| {
            const nearest = std.math.clamp(@round(n.start_beat / step_beats) * step_beats, 0.0, max_start);
            n.start_beat = n.start_beat + (nearest - n.start_beat) * frac;
        }
    }

    /// Set swing to `pct`, clamped to [swing_min, swing_max] - the
    /// `:swing` command. Audio-thread-safe (atomic store), not undo-tracked:
    /// a mixer-style live param, same as DrumMachine's own swing.
    pub fn setSwing(self: *PatternPlayer, pct: f32) void {
        if (!std.math.isFinite(pct)) return;
        self.swing.store(std.math.clamp(pct, swing_min, swing_max), .monotonic);
    }

    /// Mutable pointer to the note starting at pitch/start_beat, or null.
    /// Caller mutates fields in place (pitch/start_beat unchanged), so no lock
    /// is needed: the audio thread reads a consistent note either way.
    pub fn noteAt(self: *PatternPlayer, pitch: u7, start_beat: f64) ?*Note {
        var i: usize = 0;
        while (i < self.note_count) : (i += 1) {
            const n = &self.notes[i];
            if (n.pitch == pitch and @abs(n.start_beat - start_beat) < 1e-9) return n;
        }
        return null;
    }

    /// True if any note with the given pitch covers beat_pos (for the view).
    pub fn noteCovers(self: *const PatternPlayer, pitch: u7, beat_pos: f64) bool {
        for (self.notes[0..self.note_count]) |n| {
            if (n.pitch != pitch) continue;
            if (beat_pos >= n.start_beat and beat_pos < n.start_beat + n.duration_beat)
                return true;
        }
        return false;
    }

    /// Velocity of the note starting at pitch/beat_pos, or null (for shading).
    pub fn velocityAt(self: *const PatternPlayer, pitch: u7, beat_pos: f64) ?f32 {
        for (self.notes[0..self.note_count]) |n| {
            if (n.pitch != pitch) continue;
            if (@abs(n.start_beat - beat_pos) < 1e-9) return n.velocity;
        }
        return null;
    }

    /// True if any note starts exactly at beat_pos ± epsilon.
    pub fn noteStartsAt(self: *const PatternPlayer, pitch: u7, beat_pos: f64) bool {
        for (self.notes[0..self.note_count]) |n| {
            if (n.pitch != pitch) continue;
            if (@abs(n.start_beat - beat_pos) < 1e-9) return true;
        }
        return false;
    }

    /// Delay `beat` by up to a quarter-step if it lands on an off-beat 16th
    /// (odd step, 0.25 beat each) - same shape as DrumMachine's per-step
    /// `swing_delay`, just expressed in beats instead of frames. Even steps
    /// stay exactly on the grid, so boundary positions stay non-decreasing.
    fn swungBeat(beat: f64, swing_pct: f32) f64 {
        if (swing_pct == 50.0) return beat; // fast path: dead straight
        const step: i64 = @intFromFloat(@floor(beat / 0.25));
        if (@mod(step, 2) == 0) return beat;
        const delay: f64 = 0.25 * @as(f64, swing_pct - 50.0) / 50.0;
        return beat + delay;
    }

    // ── Audio thread ─────────────────────────────────────────────────────────

    /// Fire note_offs then note_ons for notes whose (swung) boundaries fall
    /// in [lo, hi). `lo` and `hi` are beat positions within [0, loop_beats) -
    /// non-wrapping. `swing_pct` shifts a note's start (and, to keep its
    /// audible length exact, its matching note_off) as a single unit - never
    /// the onset alone - so a swung note-off can never land before its own
    /// swung onset.
    pub fn scanRange(
        notes: []const Note,
        loop_beats: f64,
        sounding: *[128]bool,
        target: dsp.Device,
        lo: f64,
        hi: f64,
        swing_pct: f32,
    ) void {
        // note_offs first so same-pitch re-triggers work correctly
        for (notes) |n| {
            const start = @mod(swungBeat(n.start_beat, swing_pct), loop_beats);
            const off = @mod(start + n.duration_beat, loop_beats);
            if (sounding[n.pitch] and off >= lo and off < hi) {
                target.sendEvent(.{ .note_off = .{ .note = n.pitch } });
                sounding[n.pitch] = false;
            }
        }
        for (notes) |n| {
            const start = @mod(swungBeat(n.start_beat, swing_pct), loop_beats);
            if (start >= lo and start < hi) {
                target.sendEvent(.{ .note_on = .{ .note = n.pitch, .velocity = n.velocity } });
                sounding[n.pitch] = true;
            }
        }
    }

    fn releaseSounding(self: *PatternPlayer) void {
        for (&self.sounding, 0..) |*sounding, pitch| {
            if (!sounding.*) continue;
            self.target.sendEvent(.{ .note_off = .{ .note = @intCast(pitch) } });
            sounding.* = false;
        }
    }

    pub fn processBlock(self: *PatternPlayer, buf: []types.Sample) void {
        if (!self.transport.playing) {
            self.releaseSounding();
            self.last_pos_frames = 0;
            return;
        }

        // Non-blocking: skip this block rather than spin-waiting and starving the audio thread.
        if (!self.notes_lock.tryLock()) return;
        defer self.notes_lock.unlock();

        const frames: u64 = @intCast(buf.len / 2);
        const pos = self.transport.position_frames;

        for (&self.pending_note_off, 0..) |*pending, word| {
            var bits = pending.swap(0, .acq_rel);
            while (bits != 0) {
                const bit: u6 = @intCast(@ctz(bits));
                const pitch: u7 = @intCast(word * 64 + bit);
                if (self.sounding[pitch]) {
                    self.target.sendEvent(.{ .note_off = .{ .note = pitch } });
                    self.sounding[pitch] = false;
                }
                bits &= bits - 1;
            }
        }

        // Resync on seek or first play (same technique as DrumMachine).
        if (self.last_pos_frames != 0 and pos != self.last_pos_frames)
            self.releaseSounding();
        self.last_pos_frames = pos + frames;

        // In song mode the arrangement's flattened clips drive playback and the
        // loop length is the whole song; otherwise the live one-bar-ish loop.
        const notes = if (self.song_mode) self.song_notes[0..self.song_note_count] else self.notes[0..self.note_count];
        const loop = if (self.song_mode) self.song_length_beats else self.length_beats;
        if (notes.len == 0 or loop <= 0) {
            self.releaseSounding();
            return;
        }

        const fpb = self.transport.framesPerBeat();
        const start_beat = @as(f64, @floatFromInt(pos)) / fpb;
        const end_beat = @as(f64, @floatFromInt(pos + frames)) / fpb;

        if (self.song_mode and start_beat >= loop) {
            // Past the end of the arrangement: silence anything left
            // sounding and stop - the song plays once through, it doesn't
            // wrap like the live loop does.
            self.releaseSounding();
            return;
        }

        const s = @mod(start_beat, loop);
        const e = s + (end_beat - start_beat);

        const swing_pct = self.swing.load(.monotonic);
        if (self.song_mode) {
            // No wraparound in song mode - clamp to the arrangement's end.
            scanRange(notes, loop, &self.sounding, self.target, s, @min(e, loop), swing_pct);
        } else if (e >= loop) {
            // Block spans the loop boundary: two non-wrapping scans.
            scanRange(notes, loop, &self.sounding, self.target, s, loop, swing_pct);
            scanRange(notes, loop, &self.sounding, self.target, 0.0, @min(e - loop, loop), swing_pct);
        } else {
            scanRange(notes, loop, &self.sounding, self.target, s, e, swing_pct);
        }
    }

    pub fn handleEvent(self: *PatternPlayer, ev: dsp.Event) void {
        switch (ev) {
            // zig fmt: off
            .all_off => @memset(&self.sounding, false),
            else     => {},
            // zig fmt: on
        }
    }

    pub fn reset(self: *PatternPlayer) void {
        self.releaseSounding();
        self.last_pos_frames = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tryAddNote reports the real-time pattern capacity" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);

    for (0..max_notes) |i| try std.testing.expect(pp.tryAddNote(.{
        .pitch = @intCast(i % 128),
        .start_beat = @floatFromInt(i),
        .duration_beat = 0.25,
    }));
    try std.testing.expect(!pp.tryAddNote(.{
        .pitch = 60,
        .start_beat = max_notes,
        .duration_beat = 0.25,
    }));
    try std.testing.expectEqual(max_notes, pp.note_count);
}

test "swing delays a note on an off-beat 16th, mirroring DrumMachine's math" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };

    var pp = PatternPlayer.init(synth.device(), &transport);
    // start_beat 0.25 = step 1 (off-beat 16th). 75% swing delays it by
    // 0.25 * (75-50)/50 = 0.125 beat, landing exactly at 0.375.
    pp.notes[0] = .{ .pitch = 60, .start_beat = 0.25, .duration_beat = 0.25 };
    pp.note_count = 1;
    const loop: f64 = 4.0;

    // Straight (50%): fires right at 0.25, silent afterward.
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.25, 0.375, 50.0);
    try std.testing.expect(pp.sounding[60]);
    pp.sounding[60] = false;

    // 75% swing: silent through the straight boundary (0.25) up to just
    // before the swung one (0.375), then fires exactly there.
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.25, 0.375, 75.0);
    try std.testing.expect(!pp.sounding[60]);
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.375, 0.5, 75.0);
    try std.testing.expect(pp.sounding[60]);

    // Even steps (step 0, start_beat 0.0) stay exactly on the grid regardless
    // of swing - only odd (off-beat) steps shift.
    pp.notes[0] = .{ .pitch = 62, .start_beat = 0.0, .duration_beat = 0.25 };
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.0, 0.1, 75.0);
    try std.testing.expect(pp.sounding[62]);
}

test "setSwing clamps to [swing_min, swing_max]" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);

    pp.setSwing(1000.0);
    try std.testing.expectApproxEqAbs(PatternPlayer.swing_max, pp.swing.load(.monotonic), 1e-6);
    pp.setSwing(-1000.0);
    try std.testing.expectApproxEqAbs(PatternPlayer.swing_min, pp.swing.load(.monotonic), 1e-6);
    pp.setSwing(62.0);
    try std.testing.expectApproxEqAbs(@as(f32, 62.0), pp.swing.load(.monotonic), 1e-6);
    pp.setSwing(std.math.nan(f32));
    try std.testing.expectApproxEqAbs(@as(f32, 62.0), pp.swing.load(.monotonic), 1e-6);
    pp.setSwing(std.math.inf(f32));
    try std.testing.expectApproxEqAbs(@as(f32, 62.0), pp.swing.load(.monotonic), 1e-6);
}

test "scanRange fires note_on then note_off across loop boundary" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };

    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.notes[0] = .{ .pitch = 60, .start_beat = 0.5, .duration_beat = 0.5 };
    pp.note_count = 1;
    const loop: f64 = 4.0;

    // Note should fire at beat 0.5
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.0, 1.0, 50.0);
    try std.testing.expect(pp.sounding[60]);

    // Note off fires at beat 1.0 (start of next scan)
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 1.0, 2.0, 50.0);
    try std.testing.expect(!pp.sounding[60]);
}

test "copyNotes/setNotes round-trip a pattern between players" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };

    var src = PatternPlayer.init(synth.device(), &transport);
    src.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    src.addNote(.{ .pitch = 64, .start_beat = 2.0, .duration_beat = 1.0, .velocity = 0.5 });
    src.length_beats = 8.0;

    var buf: [max_notes]Note = undefined;
    const count = src.copyNotes(&buf);
    try std.testing.expectEqual(@as(u16, 2), count);

    var dst = PatternPlayer.init(synth.device(), &transport);
    dst.addNote(.{ .pitch = 30, .start_beat = 1.0, .duration_beat = 1.0 }); // replaced
    dst.setNotes(buf[0..count], src.length_beats);
    try std.testing.expectEqual(@as(u16, 2), dst.note_count);
    try std.testing.expectEqual(@as(u7, 64), dst.notes[1].pitch);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dst.notes[1].velocity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), dst.length_beats, 1e-9);
}

test "note mutation APIs sanitize non-finite playback data" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    const bad = Note{
        .pitch = 60,
        .start_beat = std.math.nan(f64),
        .duration_beat = std.math.inf(f64),
        .velocity = std.math.nan(f32),
    };

    pp.addNote(bad);
    try std.testing.expectEqual(@as(f64, 0.0), pp.notes[0].start_beat);
    try std.testing.expectEqual(@as(f64, 0.0), pp.notes[0].duration_beat);
    try std.testing.expectEqual(default_velocity, pp.notes[0].velocity);

    pp.setNotes(&.{bad}, std.math.nan(f64));
    try std.testing.expectEqual(@as(f64, 4.0), pp.length_beats);
    try std.testing.expect(std.math.isFinite(pp.notes[0].start_beat));

    pp.setSongNotes(&.{bad}, std.math.inf(f64));
    try std.testing.expectEqual(@as(f64, 0.0), pp.song_length_beats);
    try std.testing.expect(std.math.isFinite(pp.song_notes[0].start_beat));
}

test "reverseNotesInRange mirrors a figure so it plays backwards" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    // Quarter notes at beats 0, 1, 2 - an ascending run.
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 67, .start_beat = 2.0, .duration_beat = 1.0 });

    // Whole-pattern retrograde: 60 ends at beat 1 -> now ends at 4 (starts 3).
    try std.testing.expectEqual(@as(u16, 3), pp.reverseNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 4.0 }));
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), pp.notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), pp.notes[1].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[2].start_beat, 1e-9);

    // Reversing twice restores the original figure.
    _ = pp.reverseNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 4.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pp.notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), pp.notes[2].start_beat, 1e-9);

    // Partial range only touches notes starting inside it.
    _ = pp.reverseNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 2.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pp.notes[1].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), pp.notes[2].start_beat, 1e-9);

    // A note overhanging the range clamps to the range start.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 3.0 });
    _ = pp.reverseNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 2.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pp.notes[0].start_beat, 1e-9);

    // Degenerate/invalid ranges are no-ops.
    try std.testing.expectEqual(@as(u16, 0), pp.reverseNotesInRange(.{ .lo_beat = 2.0, .hi_beat = 2.0 }));
    try std.testing.expectEqual(@as(u16, 0), pp.reverseNotesInRange(.{ .lo_beat = 0.0, .hi_beat = std.math.nan(f64) }));
}

test "velocityRamp interpolates by note position, endpoints exact" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 62, .start_beat = 1.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 64, .start_beat = 2.0, .duration_beat = 0.5 });

    try std.testing.expectEqual(@as(u16, 3), pp.velocityRamp(0.0, 4.0, 0.2, 1.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), pp.notes[0].velocity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), pp.notes[1].velocity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pp.notes[2].velocity, 1e-6);

    // A lone note in range gets the ramp's target; 0 floors to audible.
    try std.testing.expectEqual(@as(u16, 1), pp.velocityRamp(1.0, 2.0, 0.0, 0.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), pp.notes[1].velocity, 1e-6);

    // Empty range touches nothing.
    try std.testing.expectEqual(@as(u16, 0), pp.velocityRamp(3.0, 4.0, 0.2, 1.0));
}

test "legato extends notes to the next onset, gapless" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    // Three staccato quarter notes with gaps: [0,0.25) [1,1.25) [2,2.25).
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 62, .start_beat = 1.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 64, .start_beat = 2.0, .duration_beat = 0.25 });

    try std.testing.expectEqual(@as(u16, 3), pp.legato(0.0, 4.0));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[0].duration_beat, 1e-9); // 0 -> 1
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[1].duration_beat, 1e-9); // 1 -> 2
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), pp.notes[2].duration_beat, 1e-9); // 2 -> hi_beat (4)

    // A chord (shared start) all reach the same next onset.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 64, .start_beat = 0.0, .duration_beat = 0.1 });
    pp.addNote(.{ .pitch = 67, .start_beat = 1.0, .duration_beat = 0.25 });
    try std.testing.expectEqual(@as(u16, 3), pp.legato(0.0, 4.0));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[0].duration_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[1].duration_beat, 1e-9);

    // Already-touching notes are a no-op (nothing "changed").
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 62, .start_beat = 1.0, .duration_beat = 3.0 });
    try std.testing.expectEqual(@as(u16, 0), pp.legato(0.0, 4.0));

    // Degenerate range is a no-op.
    try std.testing.expectEqual(@as(u16, 0), pp.legato(2.0, 2.0));
}

test "glue welds touching same-pitch notes, leaves gaps and other pitches alone" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    // Three touching 60s, a 64 on top of them, and a 60 after a real gap.
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 60, .start_beat = 0.5, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 64, .start_beat = 0.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 60, .start_beat = 3.0, .duration_beat = 0.5 });

    try std.testing.expectEqual(@as(u16, 2), pp.glue(.{ .lo_beat = 0.0, .hi_beat = 4.0 }));
    try std.testing.expectEqual(@as(u16, 3), pp.note_count);
    const welded = pp.noteAt(60, 0.0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), welded.duration_beat, 1e-9);
    try std.testing.expect(pp.noteAt(64, 0.0) != null); // different pitch, untouched
    try std.testing.expect(pp.noteAt(60, 3.0) != null); // across a gap, untouched

    // Overlapping notes glue to the outer span, not the sum of durations.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 2.0 });
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.5 });
    try std.testing.expectEqual(@as(u16, 1), pp.glue(.{ .lo_beat = 0.0, .hi_beat = 4.0 }));
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pp.notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), pp.notes[0].duration_beat, 1e-9);

    // A pitch band that excludes a note leaves it out of the weld.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 1.0 });
    try std.testing.expectEqual(@as(u16, 0), pp.glue(.{ .lo_beat = 0.0, .hi_beat = 0.5 }));
    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
}

test "chop splits notes into grid pieces, refuses when it would overflow" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0, .velocity = 0.4 });
    pp.addNote(.{ .pitch = 64, .start_beat = 2.0, .duration_beat = 0.25 }); // already one piece

    try std.testing.expectEqual(@as(?u16, 3), pp.chop(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25));
    try std.testing.expectEqual(@as(u16, 5), pp.note_count);
    for ([_]f64{ 0.0, 0.25, 0.5, 0.75 }) |start| {
        const piece = pp.noteAt(60, start) orelse return error.MissingPiece;
        try std.testing.expectApproxEqAbs(@as(f64, 0.25), piece.duration_beat, 1e-9);
        try std.testing.expectApproxEqAbs(@as(f32, 0.4), piece.velocity, 1e-6); // velocity rides along
    }

    // A ragged tail keeps its remainder instead of overshooting the end.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.6 });
    try std.testing.expectEqual(@as(?u16, 2), pp.chop(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), pp.noteAt(60, 0.5).?.duration_beat, 1e-9);

    // Nothing to split, and invalid steps, are quiet no-ops.
    try std.testing.expectEqual(@as(?u16, 0), pp.chop(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 1.0));
    try std.testing.expectEqual(@as(?u16, 0), pp.chop(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.0));

    // Overflow refuses outright, leaving the pattern exactly as it was.
    pp.clearNotes();
    for (0..300) |i| pp.addNote(.{ .pitch = 60, .start_beat = @as(f64, @floatFromInt(i)) * 0.01, .duration_beat = 1.0 });
    try std.testing.expectEqual(@as(?u16, null), pp.chop(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25));
    try std.testing.expectEqual(@as(u16, 300), pp.note_count);
}

test "strum staggers a chord low-to-high for a positive offset" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 8.0;
    // A C major triad stacked at beat 1, added out of pitch order to
    // exercise the index tie-break.
    pp.addNote(.{ .pitch = 67, .start_beat = 1.0, .duration_beat = 1.0 }); // G
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 1.0 }); // C (lowest)
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 1.0 }); // E

    try std.testing.expectEqual(@as(u16, 2), pp.strum(0.0, 8.0, 0.1));
    // Lowest pitch (60) is the anchor and never moves.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[1].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), pp.notes[2].start_beat, 1e-9); // E: rank 1
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), pp.notes[0].start_beat, 1e-9); // G: rank 2
    // Duration is untouched.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[0].duration_beat, 1e-9);
}

test "strum reverses rank order for a negative offset, still only moving forward" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 8.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 67, .start_beat = 1.0, .duration_beat = 1.0 });

    try std.testing.expectEqual(@as(u16, 2), pp.strum(0.0, 8.0, -0.1));
    // Highest pitch (67) is now the anchor.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[2].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), pp.notes[0].start_beat, 1e-9); // C: furthest, rank 2
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), pp.notes[1].start_beat, 1e-9); // E: rank 1
}

test "strum leaves a lone note untouched and clamps into the range" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 0.5 });

    // A lone note has no chord partners to stagger against.
    try std.testing.expectEqual(@as(u16, 0), pp.strum(0.0, 4.0, 0.25));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[0].start_beat, 1e-9);

    // A chord near the range's end clamps rather than spilling past it.
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5 });
    try std.testing.expectEqual(@as(u16, 1), pp.strum(0.0, 1.05, 1.0));
    try std.testing.expect(pp.notes[1].start_beat < 1.05);

    // Degenerate/invalid parameters are no-ops.
    try std.testing.expectEqual(@as(u16, 0), pp.strum(2.0, 2.0, 0.1));
    try std.testing.expectEqual(@as(u16, 0), pp.strum(0.0, 4.0, std.math.nan(f64)));
}

test "humanize jitters timing/velocity within bounds; 0% is a no-op" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.8 });
    pp.addNote(.{ .pitch = 64, .start_beat = 2.0, .duration_beat = 0.5, .velocity = 0.5 });

    pp.humanize(0.0, 0.25, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), pp.notes[0].velocity, 1e-6);

    pp.humanize(50.0, 0.25, 42);
    for (pp.notes[0..pp.note_count]) |n| {
        try std.testing.expect(n.start_beat >= 0.0 and n.start_beat <= pp.length_beats);
        try std.testing.expect(n.velocity > 0.0 and n.velocity <= 1.0);
    }
    // At least one of the two notes actually moved/changed velocity.
    try std.testing.expect(
        // zig fmt: off
        pp.notes[0].start_beat != 1.0 or pp.notes[1].start_beat != 2.0 or
        pp.notes[0].velocity != 0.8 or pp.notes[1].velocity != 0.5,
        // zig fmt: on
    );
}

test "humanize ignores invalid parameters" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.8 });
    const original = pp.notes[0];

    pp.humanize(std.math.nan(f64), 0.25, 1);
    pp.humanize(50.0, std.math.inf(f64), 1);
    pp.humanize(50.0, 0.0, 1);
    try std.testing.expectEqualDeep(original, pp.notes[0]);
}

test "quantize snaps to grid at 100%, eases proportionally below, no-op at 0%" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    // 0.05 beats off the nearest 16th-note line (step_beats = 0.25).
    pp.addNote(.{ .pitch = 60, .start_beat = 0.30, .duration_beat = 0.25 });

    pp.quantize(0.25, 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), pp.notes[0].start_beat, 1e-9);

    pp.quantize(0.25, 50.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.275), pp.notes[0].start_beat, 1e-9);

    pp.quantize(0.25, 100.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pp.notes[0].start_beat, 1e-9);

    // A note past the last full grid line clamps into the loop rather than
    // snapping past its end.
    pp.notes[0].start_beat = 3.95;
    pp.quantize(0.25, 100.0);
    try std.testing.expectApproxEqAbs(@as(f64, 3.75), pp.notes[0].start_beat, 1e-9);
}

test "quantize ignores invalid parameters" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.addNote(.{ .pitch = 60, .start_beat = 1.1, .duration_beat = 0.5, .velocity = 0.8 });
    const original = pp.notes[0];

    pp.quantize(std.math.nan(f64), 100.0);
    pp.quantize(0.0, 100.0);
    pp.quantize(0.25, std.math.nan(f64));
    try std.testing.expectEqualDeep(original, pp.notes[0]);
}

test "PatternPlayer sequences note against transport" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    transport.play();

    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var pp = PatternPlayer.init(synth.device(), &transport);
    // Quarter-note C4 at beat 0
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });

    var scratch: [512]types.Sample = undefined;
    @memset(&scratch, 0.0);

    // PatternPlayer at chain[0] fires note_on; synth at chain[1] renders it.
    pp.processBlock(&scratch);
    synth.processBlock(&scratch);

    // zig fmt: off
    var has_signal = false;
    for (scratch) |s| if (@abs(s) > 1e-4) { has_signal = true; break; };
    // zig fmt: on
    try std.testing.expect(has_signal);
}

test "clearing the active pattern releases sounding notes" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });

    transport.play();
    var buf = [_]types.Sample{0.0} ** 512;
    pp.processBlock(&buf);
    try std.testing.expect(pp.sounding[60]);

    pp.clearNotes();
    transport.advance(256);
    pp.processBlock(&buf);
    try std.testing.expect(!pp.sounding[60]);
}

test "deleting a sounding note releases it when other notes remain" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 64, .start_beat = 2.0, .duration_beat = 1.0 });

    transport.play();
    var buf = [_]types.Sample{0.0} ** 512;
    pp.processBlock(&buf);
    try std.testing.expect(pp.sounding[60]);

    pp.removeNote(60, 0.0);
    transport.advance(256);
    pp.processBlock(&buf);
    try std.testing.expect(!pp.sounding[60]);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
}

test "time-sliding a sounding note chokes it instead of stranding its note_off" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });

    transport.play();
    var buf = [_]types.Sample{0.0} ** 512;
    pp.processBlock(&buf);
    try std.testing.expect(pp.sounding[60]);

    try std.testing.expectEqual(@as(?u16, 1), pp.shiftNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 0.25 }, 0, 0.5));
    transport.advance(256);
    pp.processBlock(&buf);
    try std.testing.expect(!pp.sounding[60]);
}
