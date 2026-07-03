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
    /// Instrument fed note events (synth, sampler, …). Stable for the rack's
    /// lifetime because the rack is heap-allocated.
    target:    dsp.Device,
    transport: *const Transport,

    notes_lock: std.atomic.Mutex = .unlocked,
    notes:      [max_notes]Note = undefined,
    note_count: u16 = 0,
    /// Loop length in beats (default 4 = 1 bar in 4/4).
    length_beats: f64 = 4.0,

    // ── Song-mode playback ───────────────────────────────────────────────────
    /// When true, process() plays `song_notes` (the arrangement's clips
    /// flattened to absolute beats) instead of the live loop above. Set by the
    /// control thread via Session.setSongMode; read on the audio thread.
    song_mode:        bool = false,
    /// The lane's clips flattened into one timeline: each note carries its
    /// absolute start_beat (clip start + note offset). Guarded by `notes_lock`.
    song_notes:       [max_notes]Note = undefined,
    song_note_count:  u16 = 0,
    /// Loop length of the whole arrangement in beats. The song plays through
    /// then repeats, mirroring the live loop's wrap behaviour.
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

    // ── Audio thread ─────────────────────────────────────────────────────────

    /// Fire note_offs then note_ons for notes whose boundaries fall in [lo, hi).
    /// `lo` and `hi` are beat positions within [0, loop_beats) — non-wrapping.
    pub fn scanRange(
        notes: []const Note,
        loop_beats: f64,
        sounding: *[128]bool,
        target: dsp.Device,
        lo: f64,
        hi: f64,
    ) void {
        // note_offs first so same-pitch re-triggers work correctly
        for (notes) |n| {
            const off = @mod(n.start_beat + n.duration_beat, loop_beats);
            if (sounding[n.pitch] and off >= lo and off < hi) {
                target.sendEvent(.{ .note_off = .{ .note = n.pitch } });
                sounding[n.pitch] = false;
            }
        }
        for (notes) |n| {
            if (n.start_beat >= lo and n.start_beat < hi) {
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

        const s = @mod(start_beat, loop);
        const e = s + (end_beat - start_beat);

        if (e >= loop) {
            // Block spans the loop boundary: two non-wrapping scans.
            scanRange(notes, loop, &self.sounding, self.target, s, loop);
            scanRange(notes, loop, &self.sounding, self.target, 0.0, @min(e - loop, loop));
        } else {
            scanRange(notes, loop, &self.sounding, self.target, s, e);
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

test "scanRange fires note_on then note_off across loop boundary" {
    var synth = PolySynth.init(48_000);
    var transport: Transport = .{ .sample_rate = 48_000 };

    var pp = PatternPlayer.init(synth.device(), &transport);
    pp.notes[0] = .{ .pitch = 60, .start_beat = 0.5, .duration_beat = 0.5 };
    pp.note_count = 1;
    const loop: f64 = 4.0;

    // Note should fire at beat 0.5
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 0.0, 1.0);
    try std.testing.expect(pp.sounding[60]);

    // Note off fires at beat 1.0 (start of next scan)
    PatternPlayer.scanRange(pp.notes[0..1], loop, &pp.sounding, synth.device(), 1.0, 2.0);
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
