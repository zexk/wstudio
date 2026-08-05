//! Note-range editing operations for `PatternPlayer` (piano-roll commands:
//! transpose/slide, retrograde/inversion, velocity ramp/normalize, legato, strum, glue, dedupe,
//! chop, flam, arpeggiate, limit/remap pitch, set lengths). Split out of
//! pattern.zig because these are UI-thread editing tools with no bearing
//! on the audio-thread playback in that file (`scanRange`/`processBlock`).
//! `PatternPlayer` re-exports each of these under its own name (see
//! pattern.zig) so existing `pp.shiftNotesInRange(...)`-style call sites
//! keep compiling unchanged.

const std = @import("std");
const pattern = @import("pattern.zig");
const PatternPlayer = pattern.PatternPlayer;
const Sel = pattern.Sel;
const max_notes = pattern.max_notes;

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

/// Add `delta` to duration and velocity of every selected note. Zero
/// delta leaves that property unchanged. Returns count touched.
pub fn shapeNotesInRange(self: *PatternPlayer, sel: Sel, duration_delta: f64, min_duration: f64, velocity_delta: f32) u16 {
    while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.notes_lock.unlock();
    var changed: u16 = 0;
    for (self.notes[0..self.note_count]) |*n| {
        if (!sel.contains(n.*)) continue;
        if (duration_delta != 0) {
            self.queueNoteOff(n.pitch);
            n.duration_beat = std.math.clamp(n.duration_beat + duration_delta, min_duration, self.length_beats);
        }
        if (velocity_delta != 0) n.velocity = std.math.clamp(n.velocity + velocity_delta, 0.05, 1.0);
        changed += 1;
    }
    return changed;
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

/// Pitch-mirror (melodic inversion) every note `sel` covers, reflecting
/// each pitch around the midpoint of the *selected notes'* own range: the
/// lowest and highest swap, everything between folds across. Mirroring
/// around the notes rather than the selection band keeps the figure where
/// it sits and can never leave the MIDI range (the extremes only trade
/// places), so a second call flips it straight back. Returns the count
/// moved (UI thread).
pub fn invertNotesInRange(self: *PatternPlayer, sel: Sel) u16 {
    while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.notes_lock.unlock();
    var lo: i32 = 128;
    var hi: i32 = -1;
    for (self.notes[0..self.note_count]) |n| {
        if (!sel.contains(n)) continue;
        lo = @min(lo, @as(i32, n.pitch));
        hi = @max(hi, @as(i32, n.pitch));
    }
    if (hi < lo) return 0;
    var moved: u16 = 0;
    for (self.notes[0..self.note_count]) |*n| {
        if (!sel.contains(n.*)) continue;
        // The pitch changes, so anything sounding at the old one would
        // never see its note_off - same hazard as shiftNotesInRange.
        self.queueNoteOff(n.pitch);
        n.pitch = @intCast(lo + hi - @as(i32, n.pitch));
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

/// Drop stacked duplicates: any note `sel` covers that shares a pitch and
/// start with another, keeping the longest (loudest on a length tie).
/// Repeated stamps and layered pastes leave these behind, and they are
/// worse than merely redundant - two note_ons at one instant on one pitch
/// means the first copy's note_off chokes the second, so the survivor
/// plays short. Returns the count removed (UI thread).
pub fn dedupe(self: *PatternPlayer, sel: Sel) u16 {
    while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.notes_lock.unlock();
    var removed: u16 = 0;
    var i: usize = 0;
    outer: while (i < self.note_count) {
        const a = self.notes[i];
        if (sel.contains(a)) {
            for (self.notes[0..self.note_count], 0..) |b, j| {
                if (j == i or !sel.contains(b) or b.pitch != a.pitch) continue;
                if (@abs(b.start_beat - a.start_beat) >= 1e-9) continue;
                // The whole array is scanned, not just the tail, so the
                // winner is the same wherever the pile sits. That makes
                // equal-quality pairs mutual, so index order breaks the
                // tie and exactly one member of each pile survives.
                const tie = @abs(b.duration_beat - a.duration_beat) < 1e-9 and
                    @abs(b.velocity - a.velocity) < 1e-6;
                const better = b.duration_beat > a.duration_beat + 1e-9 or
                    (@abs(b.duration_beat - a.duration_beat) < 1e-9 and b.velocity > a.velocity) or
                    (tie and j > i);
                if (!better) continue;
                self.notes[i] = self.notes[self.note_count - 1];
                self.note_count -= 1;
                removed += 1;
                continue :outer;
            }
        }
        i += 1;
    }
    return removed;
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
        extra += PatternPlayer.pieceCount(n.duration_beat, step_beats) - 1;
    }
    if (extra == 0) return 0;
    if (self.note_count + extra > max_notes) return null;

    const original = self.note_count;
    for (self.notes[0..original], 0..) |n, i| {
        if (!sel.contains(n)) continue;
        const pieces = PatternPlayer.pieceCount(n.duration_beat, step_beats);
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

/// Echo every note `sel` covers `repeats` times at `offset_beats` apart -
/// FL's flam, a drum-roll ornament that also works on pitched material.
/// A positive offset trails the copies after the original, a negative
/// one places them before it (grace notes), and each copy fades by a
/// quarter of the original velocity so the ornament leans on the note
/// it decorates. Copies are clipped to the piece length so they can't
/// swallow the beat, and any that would fall outside [0, length) are
/// dropped rather than piled onto beat 0. All-or-nothing on capacity
/// like `chop`: returns null if the full set of copies wouldn't fit.
pub fn flam(self: *PatternPlayer, sel: Sel, offset_beats: f64, repeats: u8) ?u16 {
    if (!std.math.isFinite(offset_beats) or offset_beats == 0.0 or repeats == 0) return 0;
    while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.notes_lock.unlock();
    var in_range: usize = 0;
    for (self.notes[0..self.note_count]) |n| {
        if (sel.contains(n)) in_range += 1;
    }
    if (in_range == 0) return 0;
    if (self.note_count + in_range * repeats > max_notes) return null;

    const step = @abs(offset_beats);
    const original = self.note_count;
    var added: u16 = 0;
    for (self.notes[0..original]) |n| {
        if (!sel.contains(n)) continue;
        for (1..@as(usize, repeats) + 1) |r| {
            const delta = @as(f64, @floatFromInt(r)) * step;
            const start = if (offset_beats > 0.0) n.start_beat + delta else n.start_beat - delta;
            if (start < 0.0 or start >= self.length_beats) continue;
            const fade = 1.0 - 0.25 * @as(f32, @floatFromInt(r));
            self.notes[self.note_count] = PatternPlayer.sanitizeNote(.{
                .pitch = n.pitch,
                .start_beat = start,
                .duration_beat = @min(n.duration_beat, step),
                .velocity = @max(0.05, n.velocity * fade),
            });
            self.note_count += 1;
            added += 1;
        }
    }
    return added;
}

/// Spread every chord `sel` covers into an arpeggio: the notes sharing a
/// start (within epsilon) are ranked by pitch and re-dealt one
/// `step_beats` apart from where the chord sat, each shortened to one
/// step so the line reads as separate notes. `down` ranks high-to-low.
/// A lone note is its own one-member chord and never moves, and a chord
/// whose tail would run past the pattern stops dealing at the end
/// rather than wrapping. Returns the count moved (UI thread).
pub fn arpeggiate(self: *PatternPlayer, sel: Sel, step_beats: f64, down: bool) u16 {
    if (!std.math.isFinite(step_beats) or step_beats <= 0.0) return 0;
    while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.notes_lock.unlock();
    const eps = 1e-9;
    const n = self.note_count;
    // Rank first, move second: a note that has already been dealt must
    // not look like a member of the chord it was dealt away from.
    var rank: [max_notes]u16 = undefined;
    var size: [max_notes]u16 = undefined;
    for (self.notes[0..n], 0..) |a, i| {
        if (!sel.contains(a)) continue;
        var asc: u16 = 0;
        var group: u16 = 1;
        for (self.notes[0..n], 0..) |b, j| {
            if (j == i or !sel.contains(b) or @abs(b.start_beat - a.start_beat) >= eps) continue;
            group += 1;
            if (b.pitch < a.pitch or (b.pitch == a.pitch and j < i)) asc += 1;
        }
        rank[i] = asc;
        size[i] = group;
    }

    var moved: u16 = 0;
    for (self.notes[0..n], 0..) |*note, i| {
        if (!sel.contains(note.*)) continue;
        if (size[i] < 2) continue;
        const r: u16 = if (down) size[i] - 1 - rank[i] else rank[i];
        const start = note.start_beat + @as(f64, @floatFromInt(r)) * step_beats;
        if (start >= @min(sel.hi_beat, self.length_beats)) continue;
        // The off boundary moves, so choke anything sounding first
        // (same hazard as shiftNotesInRange).
        self.queueNoteOff(note.pitch);
        note.start_beat = start;
        note.duration_beat = @min(note.duration_beat, step_beats);
        moved += 1;
    }
    return moved;
}

/// Fold every note `sel` covers into the pitch range [lo, hi] by whole
/// octaves - FL's limit tool, for pulling a wandering line back into an
/// instrument's playable register without flattening its shape. A range
/// narrower than an octave has no octave to fold into, so notes clamp to
/// the nearest bound instead. Returns the count moved (UI thread).
pub fn limitPitch(self: *PatternPlayer, sel: Sel, lo: u7, hi: u7) u16 {
    if (lo > hi) return 0;
    while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.notes_lock.unlock();
    var moved: u16 = 0;
    for (self.notes[0..self.note_count]) |*n| {
        if (!sel.contains(n.*)) continue;
        var p: i32 = n.pitch;
        while (p < lo and p + 12 <= 127) p += 12;
        while (p > hi and p - 12 >= 0) p -= 12;
        const clamped: u7 = @intCast(std.math.clamp(p, lo, hi));
        if (clamped == n.pitch) continue;
        // The pitch itself changes, so the sounding voice has to go
        // (same reasoning as shiftNotesInRange).
        self.queueNoteOff(n.pitch);
        n.pitch = clamped;
        moved += 1;
    }
    return moved;
}

/// Remap every note `sel` covers through `table` (pitch -> pitch) - the
/// transport for `:snap-scale`, which builds the table from the active
/// `theory.Scale`. Takes a table rather than the scale itself so this
/// layer stays free of music theory, the same way `limitPitch` takes
/// plain bounds. Returns the count whose pitch actually moved (UI thread).
pub fn remapPitch(self: *PatternPlayer, sel: Sel, table: *const [128]u7) u16 {
    while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.notes_lock.unlock();
    var moved: u16 = 0;
    for (self.notes[0..self.note_count]) |*n| {
        if (!sel.contains(n.*)) continue;
        const to = table[n.pitch];
        if (to == n.pitch) continue;
        // The pitch itself changes, so the sounding voice has to go
        // (same reasoning as shiftNotesInRange).
        self.queueNoteOff(n.pitch);
        n.pitch = to;
        moved += 1;
    }
    return moved;
}

/// Set every note `sel` covers to `duration_beat` - FL's "discard note
/// lengths", for throwing away hand-drawn lengths and getting a uniform
/// stab back. Returns the count whose length actually changed (UI
/// thread).
pub fn setLengths(self: *PatternPlayer, sel: Sel, duration_beat: f64) u16 {
    if (!std.math.isFinite(duration_beat) or duration_beat <= 0.0) return 0;
    while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.notes_lock.unlock();
    var changed: u16 = 0;
    for (self.notes[0..self.note_count]) |*n| {
        if (!sel.contains(n.*)) continue;
        if (@abs(n.duration_beat - duration_beat) < 1e-9) continue;
        // The off boundary moves, and a shrunk tail could otherwise
        // strand its note_off (same hazard as legato).
        self.queueNoteOff(n.pitch);
        n.duration_beat = duration_beat;
        changed += 1;
    }
    return changed;
}
