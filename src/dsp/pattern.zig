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
const pattern_transforms = @import("pattern_transforms.zig");

pub const max_notes: u16 = 512;
pub const max_midi_events: u16 = 1024;

pub const MidiEvent = struct {
    beat: f64,
    midi_track: u16 = 0,
    channel: u4 = 0,
    data: union(enum) {
        cc: struct { controller: u7, value: u7 },
        program_change: u7,
        channel_pressure: u7,
        poly_pressure: struct { pitch: u7, pressure: u7 },
        pitch_bend: u14,
    },
};

/// What a note lands at when nothing supplies a velocity (step edits, the
/// qwerty piano) - recorded MIDI carries its own.
pub const default_velocity: f32 = 0.85;

/// A step position (already multiplied out to `beats * steps_per_beat`) as
/// the u16 every piano-roll step index uses, saturated instead of cast raw.
/// `length_beats` has no ceiling - a held `+` in the roll adds a bar per
/// press, and a long MIDI import takes whatever the file ends at - so on a
/// fine grid the product runs past 65535 and a bare `@intFromFloat` panics
/// on the next frame drawn. Negatives and NaN land on 0.
pub fn clampStep(steps: f64) u16 {
    if (!(steps > 0.0)) return 0; // false for NaN
    return @intFromFloat(@min(steps, @as(f64, std.math.maxInt(u16))));
}

test "clampStep saturates a loop too long for the step grid" {
    try std.testing.expectEqual(@as(u16, 16), clampStep(16.0));
    try std.testing.expectEqual(@as(u16, 65535), clampStep(65536.0)); // 2048 beats at 1/128
    try std.testing.expectEqual(@as(u16, 65535), clampStep(1e30));
    try std.testing.expectEqual(@as(u16, 0), clampStep(-1.0));
    try std.testing.expectEqual(@as(u16, 0), clampStep(std.math.nan(f64)));
}

// zig fmt: off
pub const Note = struct {
    pitch:         u7,
    start_beat:    f64,
    duration_beat: f64,
    velocity:      f32 = default_velocity,
    channel:       u4 = 0,
    midi_track:    u16 = 0,
    /// Per-note pan/fine-tuning/release - see `dsp.Articulation`. Defaults
    /// are neutral, so a note written before per-note expression existed
    /// (or by a step edit, the qwerty piano, or a MIDI import) plays the
    /// way it always did.
    art:           dsp.Articulation = .neutral,
};
// zig fmt: on

/// The per-note values the piano roll's `<`/`>` can edit, and everything an
/// editor needs to present one. A single table so the TUI's nudge, its
/// status line and the GUI's lane can never disagree about what a field is
/// called, how far it goes, or how it reads - the velocity lane grew all
/// three of those independently and adding pan/fine/release beside it would
/// have tripled the disagreement.
pub const NoteField = enum {
    velocity,
    pan,
    fine,
    release,

    pub const count = @typeInfo(NoteField).@"enum".fields.len;

    pub fn label(self: NoteField) []const u8 {
        return switch (self) {
            .velocity => "velocity",
            .pan => "pan",
            .fine => "fine",
            .release => "release",
        };
    }

    /// Editable range. Velocity stops at 0.05 rather than 0 because a
    /// silent note is indistinguishable from a deleted one.
    pub fn range(self: NoteField) [2]f32 {
        return switch (self) {
            .velocity => .{ 0.05, 1.0 },
            .pan => .{ -1.0, 1.0 },
            .fine => .{ -100.0, 100.0 },
            .release => .{ 0.1, 4.0 },
        };
    }

    /// How far one `<`/`>` press moves - about a tenth of each range, so
    /// every field takes a comparable number of presses end to end.
    pub fn step(self: NoteField) f32 {
        return switch (self) {
            .velocity => 0.1,
            .pan => 0.2,
            .fine => 10.0,
            .release => 0.4,
        };
    }

    pub fn get(self: NoteField, n: Note) f32 {
        return switch (self) {
            .velocity => n.velocity,
            .pan => n.art.pan,
            .fine => n.art.fine_cents,
            .release => n.art.release_scale,
        };
    }

    pub fn set(self: NoteField, n: *Note, value: f32) void {
        const r = self.range();
        const v = std.math.clamp(value, r[0], r[1]);
        switch (self) {
            .velocity => n.velocity = v,
            .pan => n.art.pan = v,
            .fine => n.art.fine_cents = v,
            .release => n.art.release_scale = v,
        }
    }

    /// `value`'s 0..1 position in the field's range - what a lane's bar
    /// height is, and what a lane drag reads back through `set`.
    pub fn norm(self: NoteField, value: f32) f32 {
        const r = self.range();
        return std.math.clamp((value - r[0]) / (r[1] - r[0]), 0.0, 1.0);
    }

    pub fn fromNorm(self: NoteField, t: f32) f32 {
        const r = self.range();
        return r[0] + std.math.clamp(t, 0.0, 1.0) * (r[1] - r[0]);
    }

    /// `value` written the way a user reads this field: velocity as a whole
    /// percentage, fine tuning as whole cents, pan and release as two
    /// decimals. One formatter so the TUI status line, the nudge readout and
    /// the GUI lane all print a field identically - `24 ct` in one place and
    /// `24.00 ct` in another is the kind of drift three call sites invite.
    /// Falls back to the bare number if `buf` is too small (16 bytes is
    /// always enough).
    pub fn format(self: NoteField, value: f32, buf: []u8) []const u8 {
        return switch (self) {
            .velocity => std.fmt.bufPrint(buf, "{d:.0}%", .{value * 100.0}),
            .fine => std.fmt.bufPrint(buf, "{d:.0} ct", .{value}),
            .release => std.fmt.bufPrint(buf, "{d:.2}x", .{value}),
            .pan => std.fmt.bufPrint(buf, "{d:.2}", .{value}),
        } catch self.label();
    }

    pub fn cycle(self: NoteField, delta: i32) NoteField {
        const n: i32 = @intCast(count);
        const cur: i32 = @intFromEnum(self);
        return @enumFromInt(@mod(cur + delta, n));
    }
};

test "NoteField: every field round-trips through norm and reads its own value" {
    var n = Note{ .pitch = 60, .start_beat = 0, .duration_beat = 1 };
    inline for (comptime std.meta.tags(NoteField)) |f| {
        const r = f.range();
        f.set(&n, r[1]);
        try std.testing.expectEqual(r[1], f.get(n));
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), f.norm(f.get(n)), 1e-6);
        f.set(&n, r[0]);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), f.norm(f.get(n)), 1e-6);
        // Out-of-range writes clamp rather than reaching a voice.
        f.set(&n, r[1] * 100.0 + 1.0);
        try std.testing.expectEqual(r[1], f.get(n));
        try std.testing.expectApproxEqAbs(r[0], f.fromNorm(0.0), 1e-4);
    }
    // Cycling wraps both ways and covers every field.
    try std.testing.expectEqual(NoteField.pan, NoteField.velocity.cycle(1));
    try std.testing.expectEqual(NoteField.release, NoteField.velocity.cycle(-1));
    try std.testing.expectEqual(NoteField.velocity, NoteField.velocity.cycle(NoteField.count));
}

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
    midi_events: [max_midi_events]MidiEvent = undefined,
    midi_event_count: u16 = 0,
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
    sounding:        [128]u16 = [_]u16{0} ** 128,
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

    pub fn sanitizeNote(note: Note) Note {
        return .{
            .pitch = note.pitch,
            .start_beat = if (std.math.isFinite(note.start_beat) and note.start_beat >= 0.0) note.start_beat else 0.0,
            .duration_beat = if (std.math.isFinite(note.duration_beat) and note.duration_beat >= 0.0) note.duration_beat else 0.0,
            .velocity = if (std.math.isFinite(note.velocity)) std.math.clamp(note.velocity, 0.0, 1.0) else default_velocity,
            .channel = note.channel,
            .midi_track = note.midi_track,
            .art = note.art.clamped(),
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
        for (self.song_notes[0..self.song_note_count]) |note| self.queueNoteOff(note.pitch);
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
        for (self.notes[0..self.note_count]) |note| self.queueNoteOff(note.pitch);
        const count = @min(notes.len, @as(usize, max_notes));
        for (notes[0..count], self.notes[0..count]) |n, *dst| dst.* = sanitizeNote(n);
        self.note_count = @intCast(count);
        self.length_beats = if (std.math.isFinite(length_beats)) @max(1.0, length_beats) else 4.0;
    }

    pub fn setMidiEvents(self: *PatternPlayer, events: []const MidiEvent) void {
        const count = @min(events.len, @as(usize, max_midi_events));
        @memcpy(self.midi_events[0..count], events[0..count]);
        self.midi_event_count = @intCast(count);
    }

    pub fn copyMidiEvents(self: *const PatternPlayer, out: []MidiEvent) u16 {
        const count: u16 = @intCast(@min(self.midi_event_count, out.len));
        @memcpy(out[0..count], self.midi_events[0..count]);
        return count;
    }

    /// Remove every note (UI thread). Used by :clear.
    pub fn clearNotes(self: *PatternPlayer) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        for (self.notes[0..self.note_count]) |note| self.queueNoteOff(note.pitch);
        self.note_count = 0;
    }

    /// Duplicate the whole pattern after itself and double the loop length -
    /// FL's "double pattern", the fast way to turn a one-bar loop into a
    /// two-bar one whose second half you then vary. All-or-nothing on
    /// capacity like `chop`: returns false untouched when the copy wouldn't
    /// fit `max_notes`, or when there's nothing to copy (UI thread).
    pub fn doubleLength(self: *PatternPlayer) bool {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        const n: usize = self.note_count;
        if (n == 0 or n * 2 > max_notes) return false;
        if (!std.math.isFinite(self.length_beats * 2.0)) return false;
        const shift = self.length_beats;
        for (self.notes[0..n], self.notes[n .. n * 2]) |src, *dst| {
            dst.* = src;
            dst.start_beat += shift;
        }
        self.note_count = @intCast(n * 2);
        self.length_beats = shift * 2.0;
        return true;
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

    /// Scale every velocity `sel` covers so the loudest note lands at full,
    /// keeping the dynamics between notes intact - the rescue for a take
    /// recorded too timid, where `:vel-ramp` would flatten the performance.
    /// Velocity-only in-place writes, so no lock is needed (same contract as
    /// `velocityRamp`). Returns the count touched (UI thread).
    pub fn normalizeVelocity(self: *PatternPlayer, sel: Sel) u16 {
        var peak: f32 = 0.0;
        for (self.notes[0..self.note_count]) |n| {
            if (sel.contains(n)) peak = @max(peak, n.velocity);
        }
        if (peak <= 0.0 or @abs(peak - 1.0) < 1e-6) return 0;
        const gain = 1.0 / peak;
        var touched: u16 = 0;
        for (self.notes[0..self.note_count]) |*n| {
            if (!sel.contains(n.*)) continue;
            n.velocity = std.math.clamp(n.velocity * gain, 0.05, 1.0);
            touched += 1;
        }
        return touched;
    }

    // ── Note-range editing tools (piano-roll commands) ──────────────────────
    // Bodies live in pattern_transforms.zig; re-exported under their own
    // names here so `pp.shiftNotesInRange(...)`-style call sites (18 of
    // them, across piano.zig/commands.zig) keep compiling unchanged.
    pub const shiftNotesInRange = pattern_transforms.shiftNotesInRange;
    pub const shapeNotesInRange = pattern_transforms.shapeNotesInRange;
    pub const reverseNotesInRange = pattern_transforms.reverseNotesInRange;
    pub const invertNotesInRange = pattern_transforms.invertNotesInRange;
    pub const velocityRamp = pattern_transforms.velocityRamp;
    pub const legato = pattern_transforms.legato;
    pub const strum = pattern_transforms.strum;
    pub const glue = pattern_transforms.glue;
    pub const dedupe = pattern_transforms.dedupe;
    pub const chop = pattern_transforms.chop;
    pub const flam = pattern_transforms.flam;
    pub const arpeggiate = pattern_transforms.arpeggiate;
    pub const limitPitch = pattern_transforms.limitPitch;
    pub const remapPitch = pattern_transforms.remapPitch;
    pub const setLengths = pattern_transforms.setLengths;

    /// How many `step_beats` pieces `duration_beat` chops into: always at
    /// least one, and capped at the pattern's own capacity so an absurdly
    /// small step can't produce a piece count no pattern could hold anyway.
    pub fn pieceCount(duration_beat: f64, step_beats: f64) usize {
        if (duration_beat <= step_beats + 1e-9) return 1;
        const n = @ceil(duration_beat / step_beats - 1e-9);
        return @intFromFloat(@max(1.0, @min(n, @as(f64, @floatFromInt(max_notes)))));
    }

    pub fn queueNoteOff(self: *PatternPlayer, pitch: u7) void {
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

    /// Pitch of the pattern's opening note (earliest start, lowest pitch on a
    /// tie), or null when empty - `:invert`'s default mirror axis, so the
    /// phrase starts on the same note it always did and only folds from there.
    pub fn firstNotePitch(self: *const PatternPlayer) ?u7 {
        var best: ?Note = null;
        for (self.notes[0..self.note_count]) |n| {
            const b = best orelse {
                best = n;
                continue;
            };
            const earlier = n.start_beat < b.start_beat - 1e-9;
            const tied_lower = @abs(n.start_beat - b.start_beat) < 1e-9 and n.pitch < b.pitch;
            if (earlier or tied_lower) best = n;
        }
        return if (best) |b| b.pitch else null;
    }

    /// Where the pattern's content actually ends: the latest note-off, 0 when
    /// empty. `:fit` rounds this up to a bar to retune the loop length.
    pub fn contentEndBeat(self: *const PatternPlayer) f64 {
        var end: f64 = 0.0;
        for (self.notes[0..self.note_count]) |n| end = @max(end, n.start_beat + n.duration_beat);
        return end;
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
        return self.noteCovering(pitch, beat_pos) != null;
    }

    /// The note with this pitch covering `beat_pos`, or null - `noteCovers`
    /// with the note itself, for hit-testing a click anywhere along a note
    /// rather than only at its start. Lock-free like `noteAt`/`noteCovers`:
    /// callers act on the (pitch, start_beat) pair they get back, which the
    /// locked edit paths re-look-up anyway.
    pub fn noteCovering(self: *const PatternPlayer, pitch: u7, beat_pos: f64) ?Note {
        for (self.notes[0..self.note_count]) |n| {
            if (n.pitch != pitch) continue;
            if (beat_pos >= n.start_beat and beat_pos < n.start_beat + n.duration_beat) return n;
        }
        return null;
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
        sounding: *[128]u16,
        target: dsp.Device,
        lo: f64,
        hi: f64,
        swing_pct: f32,
    ) void {
        // note_offs first so same-pitch re-triggers work correctly
        for (notes) |n| {
            const start = @mod(swungBeat(n.start_beat, swing_pct), loop_beats);
            const off = @mod(start + n.duration_beat, loop_beats);
            if (sounding[n.pitch] > 0 and off >= lo and off < hi) {
                target.sendEvent(.{ .note_off = .{ .note = n.pitch } });
                sounding[n.pitch] -= 1;
            }
        }
        for (notes) |n| {
            const start = @mod(swungBeat(n.start_beat, swing_pct), loop_beats);
            if (start >= lo and start < hi) {
                target.sendEvent(.{ .note_on = .{ .note = n.pitch, .velocity = n.velocity, .art = n.art } });
                sounding[n.pitch] +|= 1;
            }
        }
    }

    fn releaseSounding(self: *PatternPlayer) void {
        for (&self.sounding, 0..) |*sounding, pitch| {
            while (sounding.* > 0) : (sounding.* -= 1)
                self.target.sendEvent(.{ .note_off = .{ .note = @intCast(pitch) } });
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
        const end_pos = pos +| frames;

        for (&self.pending_note_off, 0..) |*pending, word| {
            var bits = pending.swap(0, .acq_rel);
            while (bits != 0) {
                const bit: u6 = @intCast(@ctz(bits));
                const pitch: u7 = @intCast(word * 64 + bit);
                while (self.sounding[pitch] > 0) : (self.sounding[pitch] -= 1)
                    self.target.sendEvent(.{ .note_off = .{ .note = pitch } });
                bits &= bits - 1;
            }
        }

        // Resync on seek or first play (same technique as DrumMachine).
        if (self.last_pos_frames != 0 and pos != self.last_pos_frames)
            self.releaseSounding();
        self.last_pos_frames = end_pos;

        // In song mode the arrangement's flattened clips drive playback and the
        // loop length is the whole song; otherwise the live one-bar-ish loop.
        const notes = if (self.song_mode) self.song_notes[0..self.song_note_count] else self.notes[0..self.note_count];
        const loop = if (self.song_mode) self.song_length_beats else self.length_beats;
        if (notes.len == 0 or loop <= 0) {
            self.releaseSounding();
            return;
        }

        const start_beat = self.transport.beatsAtFrames(pos);
        const end_beat = self.transport.beatsAtFrames(end_pos);

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
            .all_off => @memset(&self.sounding, 0),
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
    try std.testing.expect(pp.sounding[60] > 0);
    pp.sounding[60] = 0;

    // 75% swing: silent through the straight boundary (0.25) up to just
    // before the swung one (0.375), then fires exactly there.
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.25, 0.375, 75.0);
    try std.testing.expectEqual(@as(u16, 0), pp.sounding[60]);
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.375, 0.5, 75.0);
    try std.testing.expect(pp.sounding[60] > 0);

    // Even steps (step 0, start_beat 0.0) stay exactly on the grid regardless
    // of swing - only odd (off-beat) steps shift.
    pp.notes[0] = .{ .pitch = 62, .start_beat = 0.0, .duration_beat = 0.25 };
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.0, 0.1, 75.0);
    try std.testing.expect(pp.sounding[62] > 0);
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
    try std.testing.expect(pp.sounding[60] > 0);

    // Note off fires at beat 1.0 (start of next scan)
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 1.0, 2.0, 50.0);
    try std.testing.expectEqual(@as(u16, 0), pp.sounding[60]);
}

test "scanRange tracks overlapping same-pitch notes independently" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.notes[0] = .{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 };
    pp.notes[1] = .{ .pitch = 60, .start_beat = 0.5, .duration_beat = 1.0 };
    pp.note_count = 2;

    PatternPlayer.scanRange(pp.notes[0..2], 4.0, &pp.sounding, synth.device(), 0.0, 0.25, 50.0);
    try std.testing.expectEqual(@as(u16, 1), pp.sounding[60]);
    PatternPlayer.scanRange(pp.notes[0..2], 4.0, &pp.sounding, synth.device(), 0.5, 0.75, 50.0);
    try std.testing.expectEqual(@as(u16, 2), pp.sounding[60]);
    PatternPlayer.scanRange(pp.notes[0..2], 4.0, &pp.sounding, synth.device(), 1.0, 1.25, 50.0);
    try std.testing.expectEqual(@as(u16, 1), pp.sounding[60]);
    PatternPlayer.scanRange(pp.notes[0..2], 4.0, &pp.sounding, synth.device(), 1.5, 1.75, 50.0);
    try std.testing.expectEqual(@as(u16, 0), pp.sounding[60]);
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

test "invertNotesInRange folds pitches around the selection's own midpoint" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 67, .start_beat = 2.0, .duration_beat = 1.0 });

    // Extremes swap (60<->67), the middle folds: 60+67-64 = 63.
    try std.testing.expectEqual(@as(u16, 3), pp.invertNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 4.0 }));
    try std.testing.expectEqual(@as(u7, 67), pp.notes[0].pitch);
    try std.testing.expectEqual(@as(u7, 63), pp.notes[1].pitch);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[2].pitch);

    // Inverting twice restores the original figure.
    _ = pp.invertNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 4.0 });
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);
    try std.testing.expectEqual(@as(u7, 64), pp.notes[1].pitch);
    try std.testing.expectEqual(@as(u7, 67), pp.notes[2].pitch);

    // A partial range mirrors only what it covers, around its own extremes.
    _ = pp.invertNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 2.0 });
    try std.testing.expectEqual(@as(u7, 64), pp.notes[0].pitch);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[1].pitch);
    try std.testing.expectEqual(@as(u7, 67), pp.notes[2].pitch);

    // Empty selection is a no-op, and pitches stay inside the MIDI range
    // even when the figure sits against an edge.
    try std.testing.expectEqual(@as(u16, 0), pp.invertNotesInRange(.{ .lo_beat = 3.0, .hi_beat = 4.0 }));
    pp.clearNotes();
    pp.addNote(.{ .pitch = 0, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 127, .start_beat = 1.0, .duration_beat = 1.0 });
    _ = pp.invertNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 4.0 });
    try std.testing.expectEqual(@as(u7, 127), pp.notes[0].pitch);
    try std.testing.expectEqual(@as(u7, 0), pp.notes[1].pitch);
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

test "limitPitch folds notes into range by octaves, clamps a sub-octave range" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 36, .start_beat = 0.0, .duration_beat = 0.25 }); // two octaves low
    pp.addNote(.{ .pitch = 84, .start_beat = 1.0, .duration_beat = 0.25 }); // an octave high
    pp.addNote(.{ .pitch = 60, .start_beat = 2.0, .duration_beat = 0.25 }); // already in range

    try std.testing.expectEqual(@as(u16, 2), pp.limitPitch(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 48, 72));
    // Folded by the fewest octaves that reach the range, not to its middle.
    try std.testing.expectEqual(@as(u7, 48), pp.notes[0].pitch); // 36 + 12
    try std.testing.expectEqual(@as(u7, 72), pp.notes[1].pitch); // 84 - 12
    try std.testing.expectEqual(@as(u7, 60), pp.notes[2].pitch); // untouched

    // Narrower than an octave: nothing to fold into, so notes clamp.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 40, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 90, .start_beat = 1.0, .duration_beat = 0.25 });
    try std.testing.expectEqual(@as(u16, 2), pp.limitPitch(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 60, 64));
    try std.testing.expectEqual(@as(u7, 64), pp.notes[0].pitch);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[1].pitch);

    // Inverted range is a no-op.
    try std.testing.expectEqual(@as(u16, 0), pp.limitPitch(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 72, 48));
}

test "remapPitch moves only the notes the table changes, and only inside the selection" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 61, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 61, .start_beat = 3.0, .duration_beat = 0.25 }); // outside the selection

    // C major's snap table: every C# lands on C, everything else stays.
    var table: [128]u7 = undefined;
    for (&table, 0..) |*to, p| to.* = if (p % 12 == 1) @intCast(p - 1) else @intCast(p);

    try std.testing.expectEqual(@as(u16, 1), pp.remapPitch(.{ .lo_beat = 0.0, .hi_beat = 2.0 }, &table));
    try std.testing.expectEqual(@as(u7, 60), pp.notes[0].pitch);
    try std.testing.expectEqual(@as(u7, 60), pp.notes[1].pitch); // already on target, not counted
    try std.testing.expectEqual(@as(u7, 61), pp.notes[2].pitch); // out of range, untouched
    // Idempotent: a second pass has nothing left to move.
    try std.testing.expectEqual(@as(u16, 0), pp.remapPitch(.{ .lo_beat = 0.0, .hi_beat = 2.0 }, &table));
}

test "setLengths resets note lengths, reporting only what changed" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 2.0 });
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.25 });

    try std.testing.expectEqual(@as(u16, 1), pp.setLengths(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25));
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pp.notes[0].duration_beat, 1e-9);
    // Running it again changes nothing, so nothing is reported.
    try std.testing.expectEqual(@as(u16, 0), pp.setLengths(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25));
    // Invalid lengths are ignored rather than producing zero-length notes.
    try std.testing.expectEqual(@as(u16, 0), pp.setLengths(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.0));
}

test "flam echoes notes at fading velocity, either side of the beat" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 1.0, .velocity = 0.8 });

    try std.testing.expectEqual(@as(?u16, 2), pp.flam(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25, 2));
    try std.testing.expectEqual(@as(u16, 3), pp.note_count);
    const first = pp.noteAt(60, 1.25).?;
    const second = pp.noteAt(60, 1.5).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), first.velocity, 1e-6); // 0.8 * 0.75
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), second.velocity, 1e-6); // 0.8 * 0.5
    // Copies are clipped to the offset so they don't swallow the beat.
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), first.duration_beat, 1e-9);

    // Negative offset = grace notes before the beat; one that would land
    // before the pattern start is dropped, not stacked onto beat 0.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 0.25, .duration_beat = 1.0 });
    try std.testing.expectEqual(@as(?u16, 1), pp.flam(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, -0.25, 2));
    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
    try std.testing.expect(pp.noteAt(60, 0.0) != null);

    // Degenerate arguments and a capacity overflow are quiet/refused.
    try std.testing.expectEqual(@as(?u16, 0), pp.flam(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.0, 1));
    try std.testing.expectEqual(@as(?u16, 0), pp.flam(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25, 0));
    pp.clearNotes();
    for (0..300) |i| pp.addNote(.{ .pitch = 60, .start_beat = @as(f64, @floatFromInt(i)) * 0.01, .duration_beat = 0.1 });
    try std.testing.expectEqual(@as(?u16, null), pp.flam(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25, 1));
    try std.testing.expectEqual(@as(u16, 300), pp.note_count);
}

test "arpeggiate deals chords out one step per note, up and down" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 2.0 });
    pp.addNote(.{ .pitch = 67, .start_beat = 0.0, .duration_beat = 2.0 });
    pp.addNote(.{ .pitch = 64, .start_beat = 0.0, .duration_beat = 2.0 });
    pp.addNote(.{ .pitch = 72, .start_beat = 3.0, .duration_beat = 0.5 }); // lone note

    try std.testing.expectEqual(@as(u16, 3), pp.arpeggiate(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.25, false));
    try std.testing.expect(pp.noteAt(60, 0.0) != null);
    try std.testing.expect(pp.noteAt(64, 0.25) != null);
    try std.testing.expect(pp.noteAt(67, 0.5) != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pp.noteAt(67, 0.5).?.duration_beat, 1e-9);
    try std.testing.expect(pp.noteAt(72, 3.0) != null); // lone note never moves

    // Down ranks high-to-low from the same starting beat.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 67, .start_beat = 1.0, .duration_beat = 1.0 });
    try std.testing.expectEqual(@as(u16, 3), pp.arpeggiate(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.5, true));
    try std.testing.expect(pp.noteAt(67, 1.0) != null);
    try std.testing.expect(pp.noteAt(64, 1.5) != null);
    try std.testing.expect(pp.noteAt(60, 2.0) != null);

    // A chord too close to the end stops dealing rather than wrapping.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 3.75, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 64, .start_beat = 3.75, .duration_beat = 0.25 });
    try std.testing.expectEqual(@as(u16, 1), pp.arpeggiate(.{ .lo_beat = 0.0, .hi_beat = 4.0 }, 0.5, false));
    try std.testing.expect(pp.noteAt(64, 3.75) != null);
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

test "PatternPlayer handles final transport frame" {
    var transport: Transport = .{ .sample_rate = 48_000, .position_frames = std.math.maxInt(u64), .playing = true };
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });

    var buf = [_]types.Sample{0.0} ** 2;
    pp.processBlock(&buf);
    try std.testing.expectEqual(std.math.maxInt(u64), pp.last_pos_frames);
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
    try std.testing.expect(pp.sounding[60] > 0);

    pp.clearNotes();
    transport.advance(256);
    pp.processBlock(&buf);
    try std.testing.expectEqual(@as(u16, 0), pp.sounding[60]);
}

test "replacing a nonempty pattern releases old sounding notes" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });

    transport.play();
    var buf = [_]types.Sample{0.0} ** 512;
    pp.processBlock(&buf);
    try std.testing.expect(pp.sounding[60] > 0);

    pp.setNotes(&.{.{ .pitch = 64, .start_beat = 2.0, .duration_beat = 1.0 }}, 4.0);
    transport.advance(256);
    pp.processBlock(&buf);
    try std.testing.expectEqual(@as(u16, 0), pp.sounding[60]);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
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
    try std.testing.expect(pp.sounding[60] > 0);

    pp.removeNote(60, 0.0);
    transport.advance(256);
    pp.processBlock(&buf);
    try std.testing.expectEqual(@as(u16, 0), pp.sounding[60]);
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
}

test "clearing notes releases a sounding note" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });

    transport.play();
    var buf = [_]types.Sample{0.0} ** 512;
    pp.processBlock(&buf);
    try std.testing.expect(pp.sounding[60] > 0);

    pp.clearNotes();
    transport.advance(256);
    pp.processBlock(&buf);
    try std.testing.expectEqual(@as(u16, 0), pp.sounding[60]);
    try std.testing.expectEqual(@as(u16, 0), pp.note_count);
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
    try std.testing.expect(pp.sounding[60] > 0);

    try std.testing.expectEqual(@as(?u16, 1), pp.shiftNotesInRange(.{ .lo_beat = 0.0, .hi_beat = 0.25 }, 0, 0.5));
    transport.advance(256);
    pp.processBlock(&buf);
    try std.testing.expectEqual(@as(u16, 0), pp.sounding[60]);
}

test "doubleLength copies the pattern after itself and doubles the loop" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 64, .start_beat = 2.5, .duration_beat = 0.5 });

    try std.testing.expect(pp.doubleLength());
    try std.testing.expectEqual(@as(u16, 4), pp.note_count);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), pp.length_beats, 1e-9);
    try std.testing.expect(pp.noteAt(60, 4.0) != null);
    try std.testing.expect(pp.noteAt(64, 6.5) != null);

    // Empty patterns and over-capacity copies leave everything alone.
    pp.clearNotes();
    try std.testing.expect(!pp.doubleLength());
    pp.note_count = max_notes / 2 + 1;
    try std.testing.expect(!pp.doubleLength());
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), pp.length_beats, 1e-9);
}

test "dedupe keeps the longest of each stacked pile" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.25 });
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 64, .start_beat = 0.0, .duration_beat = 0.25 }); // chord, not a dup
    pp.addNote(.{ .pitch = 60, .start_beat = 1.0, .duration_beat = 0.25 }); // later start, not a dup

    const sel: Sel = .{ .lo_beat = 0.0, .hi_beat = 4.0 };
    try std.testing.expectEqual(@as(u16, 2), pp.dedupe(sel));
    try std.testing.expectEqual(@as(u16, 3), pp.note_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), pp.noteAt(60, 0.0).?.duration_beat, 1e-9);
    try std.testing.expect(pp.noteAt(64, 0.0) != null);
    try std.testing.expect(pp.noteAt(60, 1.0) != null);
    try std.testing.expectEqual(@as(u16, 0), pp.dedupe(sel)); // idempotent

    // Exact duplicates collapse to one survivor, never zero.
    pp.clearNotes();
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try std.testing.expectEqual(@as(u16, 2), pp.dedupe(sel));
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
}

test "normalizeVelocity lifts the peak to full, keeping the ratios" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5, .velocity = 0.25 });
    pp.addNote(.{ .pitch = 64, .start_beat = 1.0, .duration_beat = 0.5, .velocity = 0.5 });

    const sel: Sel = .{ .lo_beat = 0.0, .hi_beat = 4.0 };
    try std.testing.expectEqual(@as(u16, 2), pp.normalizeVelocity(sel));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pp.noteAt(60, 0.0).?.velocity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pp.noteAt(64, 1.0).?.velocity, 1e-6);
    try std.testing.expectEqual(@as(u16, 0), pp.normalizeVelocity(sel)); // already peaking
}

test "firstNotePitch and contentEndBeat report the pattern's bounds" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 8.0;
    try std.testing.expectEqual(@as(?u7, null), pp.firstNotePitch());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pp.contentEndBeat(), 1e-9);

    pp.addNote(.{ .pitch = 72, .start_beat = 1.0, .duration_beat = 0.5 });
    pp.addNote(.{ .pitch = 67, .start_beat = 0.0, .duration_beat = 0.5 }); // chord, lower wins
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 0.5 });
    try std.testing.expectEqual(@as(?u7, 60), pp.firstNotePitch());
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), pp.contentEndBeat(), 1e-9);
}

test "chop drops the pieces that would fall past the loop and wrap onto beat 0" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.length_beats = 4.0;
    const whole: Sel = .{ .lo_beat = 0.0, .hi_beat = 4.0 };

    // Held past the loop end: pieces at 2 and 3 are keepable, the ones at 4
    // and 5 would wrap onto the top of the loop (scanRange takes @mod).
    pp.addNote(.{ .pitch = 60, .start_beat = 2.0, .duration_beat = 3.0 });
    try std.testing.expectEqual(@as(?u16, 1), pp.chop(whole, 1.0));
    try std.testing.expectEqual(@as(u16, 2), pp.note_count);
    for (pp.notes[0..pp.note_count]) |n| try std.testing.expect(n.start_beat < pp.length_beats);

    // Nothing keepable past the first piece: the note is left completely
    // alone, because cmdChopNotes throws its undo entry away on a 0 return.
    pp.note_count = 0;
    pp.addNote(.{ .pitch = 64, .start_beat = 3.5, .duration_beat = 2.0 });
    try std.testing.expectEqual(@as(?u16, 0), pp.chop(whole, 0.5));
    try std.testing.expectEqual(@as(u16, 1), pp.note_count);
    try std.testing.expectEqual(@as(f64, 2.0), pp.notes[0].duration_beat);
}
