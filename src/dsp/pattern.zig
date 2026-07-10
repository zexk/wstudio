//! Piano-roll pattern sequencer.
//!
//! PatternPlayer sits at chain[0] for melodic racks (synth or sampler). Its
//! process() fires note_on / note_off events into the instrument device at
//! chain[1] every block, driven by the transport exactly like the drum
//! machine. Notes are stored in beats (1 beat = 1 quarter note); the view
//! layer converts steps to beats via step / 4.0.
//!
//! The target is a plain `dsp.Device`, so any note-driven instrument can be
//! sequenced — note events go through the same vtable the live keyboard uses.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;
const PolySynth = @import("synth.zig").PolySynth;

pub const max_notes: u16 = 512;

pub const Note = struct {
    pitch:         u7,
    start_beat:    f64,
    duration_beat: f64,
    velocity:      f32 = 0.85,
};

pub const PatternPlayer = struct {
    pub const swing_min: f32 = 50.0;
    pub const swing_max: f32 = 75.0;

    /// Instrument fed note events (synth, sampler, …). Stable for the rack's
    /// lifetime because the rack is heap-allocated.
    target:    dsp.Device,
    transport: *const Transport,

    notes_lock: std.atomic.Mutex = .unlocked,
    notes:      [max_notes]Note = undefined,
    note_count: u16 = 0,
    /// Loop length in beats (default 4 = 1 bar in 4/4).
    length_beats: f64 = 4.0,
    /// Swing percent (see `swing_min`/`swing_max`): every note landing on an
    /// off-beat 16th (odd step, 0.25 beat each) fires late by up to a
    /// quarter of a step (75% = hardest shuffle) — mirrors DrumMachine's
    /// swing exactly, so a melodic track can match a swung drum groove.
    swing: std.atomic.Value(f32) = .init(50.0),

    // ── Song-mode playback ───────────────────────────────────────────────────
    /// When true, process() plays `song_notes` (the arrangement's clips
    /// flattened to absolute beats) instead of the live loop above. Set by the
    /// control thread via Session.setSongMode; read on the audio thread.
    song_mode:        bool = false,
    /// The lane's clips flattened into one timeline: each note carries its
    /// absolute start_beat (clip start + note offset). Guarded by `notes_lock`.
    song_notes:       [max_notes]Note = undefined,
    song_note_count:  u16 = 0,
    /// Loop length of the whole arrangement in beats. Past this point
    /// process() goes silent instead of wrapping — the arrangement plays
    /// once through, unlike the live loop above.
    song_length_beats: f64 = 0.0,

    // ── Audio-thread-only state ──────────────────────────────────────────────
    /// Which MIDI pitches are currently sounding (audio thread only).
    sounding:        [128]bool = [_]bool{false} ** 128,
    /// Expected transport position at the start of the next block.
    /// 0 = first block or after a reset.
    last_pos_frames: u64 = 0,

    pub fn init(target: dsp.Device, transport: *const Transport) PatternPlayer {
        return .{ .target = target, .transport = transport };
    }

    pub fn device(self: *PatternPlayer) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ── UI-thread note editing ───────────────────────────────────────────────

    pub fn addNote(self: *PatternPlayer, note: Note) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        if (self.note_count >= max_notes) return;
        self.notes[self.note_count] = note;
        self.note_count += 1;
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
        for (notes[0..count], self.song_notes[0..count]) |n, *dst| dst.* = n;
        self.song_note_count = @intCast(count);
        self.song_length_beats = length_beats;
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
        for (notes[0..count], self.notes[0..count]) |n, *dst| dst.* = n;
        self.note_count = @intCast(count);
        self.length_beats = @max(1.0, length_beats);
    }

    /// Remove every note (UI thread). Used by :clear.
    pub fn clearNotes(self: *PatternPlayer) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        self.note_count = 0;
    }

    /// Copy notes whose start_beat falls in [lo_beat, hi_beat) into `out`,
    /// rebased so `lo_beat` becomes 0 (UI thread). Returns the count copied —
    /// the yank half of the piano roll's visual-mode range clipboard.
    pub fn copyNotesInRange(self: *PatternPlayer, lo_beat: f64, hi_beat: f64, out: []Note) u16 {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var n: u16 = 0;
        for (self.notes[0..self.note_count]) |note| {
            if (note.start_beat >= lo_beat and note.start_beat < hi_beat and n < out.len) {
                out[n] = note;
                out[n].start_beat -= lo_beat;
                n += 1;
            }
        }
        return n;
    }

    /// Remove every note on one pitch, across the whole pattern (UI
    /// thread). Returns the count removed — the piano roll's `dd`, where a
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
        return removed;
    }

    /// Remove every note whose start_beat falls in [lo_beat, hi_beat) (UI
    /// thread). Returns the count removed — the delete half of the piano
    /// roll's visual-mode range selection.
    pub fn removeNotesInRange(self: *PatternPlayer, lo_beat: f64, hi_beat: f64) u16 {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var removed: u16 = 0;
        var i: usize = 0;
        while (i < self.note_count) {
            const n = self.notes[i];
            if (n.start_beat >= lo_beat and n.start_beat < hi_beat) {
                self.notes[i] = self.notes[self.note_count - 1];
                self.note_count -= 1;
                removed += 1;
            } else i += 1;
        }
        return removed;
    }

    /// Jitters every live note's timing (±`amount_pct`% of one grid step,
    /// clamped inside the loop) and velocity (±`amount_pct`%, relative,
    /// clamped to (0, 1]) — the `:humanize` command. Unlike `noteAt`'s
    /// callers this moves `start_beat`, so it takes the full lock rather
    /// than mutating in place.
    pub fn humanize(self: *PatternPlayer, amount_pct: f64, step_beats: f64, seed: u64) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const frac = amount_pct / 100.0;
        const max_start = @max(0.0, self.length_beats - step_beats);
        for (self.notes[0..self.note_count]) |*n| {
            const dt = (rand.float(f64) * 2.0 - 1.0) * frac * step_beats;
            n.start_beat = std.math.clamp(n.start_beat + dt, 0.0, max_start);
            const dv = (rand.float(f32) * 2.0 - 1.0) * @as(f32, @floatCast(frac));
            n.velocity = std.math.clamp(n.velocity + dv, 0.05, 1.0);
        }
    }

    /// Set swing to `pct`, clamped to [swing_min, swing_max] — the
    /// `:swing` command. Audio-thread-safe (atomic store), not undo-tracked:
    /// a mixer-style live param, same as DrumMachine's own swing.
    pub fn setSwing(self: *PatternPlayer, pct: f32) void {
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
    /// (odd step, 0.25 beat each) — same shape as DrumMachine's per-step
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
    /// in [lo, hi). `lo` and `hi` are beat positions within [0, loop_beats) —
    /// non-wrapping. `swing_pct` shifts a note's start (and, to keep its
    /// audible length exact, its matching note_off) as a single unit — never
    /// the onset alone — so a swung note-off can never land before its own
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

    fn processBlock(self: *PatternPlayer, buf: []types.Sample) void {
        if (!self.transport.playing) {
            // Silence any notes that were left sounding.
            for (0..128) |p| {
                if (self.sounding[p]) {
                    self.target.sendEvent(.{ .note_off = .{ .note = @intCast(p) } });
                    self.sounding[p] = false;
                }
            }
            self.last_pos_frames = 0;
            return;
        }

        // Non-blocking: skip this block rather than spin-waiting and starving the audio thread.
        if (!self.notes_lock.tryLock()) return;
        defer self.notes_lock.unlock();

        const frames: u64 = @intCast(buf.len / 2);
        const pos = self.transport.position_frames;

        // Resync on seek or first play (same technique as DrumMachine).
        if (self.last_pos_frames != 0 and pos != self.last_pos_frames) {
            for (0..128) |p| {
                if (self.sounding[p]) {
                    self.target.sendEvent(.{ .note_off = .{ .note = @intCast(p) } });
                    self.sounding[p] = false;
                }
            }
        }
        self.last_pos_frames = pos + frames;

        // In song mode the arrangement's flattened clips drive playback and the
        // loop length is the whole song; otherwise the live one-bar-ish loop.
        const notes = if (self.song_mode) self.song_notes[0..self.song_note_count] else self.notes[0..self.note_count];
        const loop = if (self.song_mode) self.song_length_beats else self.length_beats;
        if (notes.len == 0 or loop <= 0) return;

        const fpb = self.transport.framesPerBeat();
        const start_beat = @as(f64, @floatFromInt(pos)) / fpb;
        const end_beat = @as(f64, @floatFromInt(pos + frames)) / fpb;

        if (self.song_mode and start_beat >= loop) {
            // Past the end of the arrangement: silence anything left
            // sounding and stop — the song plays once through, it doesn't
            // wrap like the live loop does.
            for (0..128) |p| {
                if (self.sounding[p]) {
                    self.target.sendEvent(.{ .note_off = .{ .note = @intCast(p) } });
                    self.sounding[p] = false;
                }
            }
            return;
        }

        const s = @mod(start_beat, loop);
        const e = s + (end_beat - start_beat);

        const swing_pct = self.swing.load(.monotonic);
        if (self.song_mode) {
            // No wraparound in song mode — clamp to the arrangement's end.
            scanRange(notes, loop, &self.sounding, self.target, s, @min(e, loop), swing_pct);
        } else if (e >= loop) {
            // Block spans the loop boundary: two non-wrapping scans.
            scanRange(notes, loop, &self.sounding, self.target, s, loop, swing_pct);
            scanRange(notes, loop, &self.sounding, self.target, 0.0, @min(e - loop, loop), swing_pct);
        } else {
            scanRange(notes, loop, &self.sounding, self.target, s, e, swing_pct);
        }
    }

    fn processOpaque(ptr: *anyopaque, buf: []types.Sample) void {
        const self: *PatternPlayer = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn eventOpaque(ptr: *anyopaque, ev: dsp.Event) void {
        const self: *PatternPlayer = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .all_off => @memset(&self.sounding, false),
            else     => {},
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *PatternPlayer = @ptrCast(@alignCast(ptr));
        for (0..128) |p| {
            if (self.sounding[p]) {
                self.target.sendEvent(.{ .note_off = .{ .note = @intCast(p) } });
                self.sounding[p] = false;
            }
        }
        self.last_pos_frames = 0;
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .event   = eventOpaque,
        .reset   = resetOpaque,
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "swing delays a note on an off-beat 16th, mirroring DrumMachine's math" {
    var synth = PolySynth.init(48_000);
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
    // of swing — only odd (off-beat) steps shift.
    pp.notes[0] = .{ .pitch = 62, .start_beat = 0.0, .duration_beat = 0.25 };
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.0, 0.1, 75.0);
    try std.testing.expect(pp.sounding[62]);
}

test "setSwing clamps to [swing_min, swing_max]" {
    var synth = PolySynth.init(48_000);
    var transport: Transport = .{ .sample_rate = 48_000 };
    var pp = PatternPlayer.init(synth.device(), &transport);

    pp.setSwing(1000.0);
    try std.testing.expectApproxEqAbs(PatternPlayer.swing_max, pp.swing.load(.monotonic), 1e-6);
    pp.setSwing(-1000.0);
    try std.testing.expectApproxEqAbs(PatternPlayer.swing_min, pp.swing.load(.monotonic), 1e-6);
    pp.setSwing(62.0);
    try std.testing.expectApproxEqAbs(@as(f32, 62.0), pp.swing.load(.monotonic), 1e-6);
}

test "scanRange fires note_on then note_off across loop boundary" {
    var synth = PolySynth.init(48_000);
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
    var synth = PolySynth.init(48_000);
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

test "humanize jitters timing/velocity within bounds; 0% is a no-op" {
    var synth = PolySynth.init(48_000);
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
        pp.notes[0].start_beat != 1.0 or pp.notes[1].start_beat != 2.0 or
        pp.notes[0].velocity != 0.8 or pp.notes[1].velocity != 0.5,
    );
}

test "PatternPlayer sequences note against transport" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    transport.play();

    var synth = PolySynth.init(48_000);
    var pp = PatternPlayer.init(synth.device(), &transport);
    // Quarter-note C4 at beat 0
    pp.addNote(.{ .pitch = 60, .start_beat = 0.0, .duration_beat = 1.0 });

    var scratch: [512]types.Sample = undefined;
    @memset(&scratch, 0.0);

    // PatternPlayer at chain[0] fires note_on; synth at chain[1] renders it.
    pp.processBlock(&scratch);
    synth.processBlock(&scratch);

    var has_signal = false;
    for (scratch) |s| if (@abs(s) > 1e-4) { has_signal = true; break; };
    try std.testing.expect(has_signal);
}
