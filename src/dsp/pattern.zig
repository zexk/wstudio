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

    /// Remove every note (UI thread). Used by :clear.
    pub fn clearNotes(self: *PatternPlayer) void {
        while (!self.notes_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.notes_lock.unlock();
        self.note_count = 0;
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

        if (self.note_count == 0) return;

        const fpb = self.transport.framesPerBeat();
        const start_beat = @as(f64, @floatFromInt(pos)) / fpb;
        const end_beat = @as(f64, @floatFromInt(pos + frames)) / fpb;

        const loop = self.length_beats;
        const s = @mod(start_beat, loop);
        const e = s + (end_beat - start_beat);

        if (e >= loop) {
            // Block spans the loop boundary: two non-wrapping scans.
            scanRange(self.notes[0..self.note_count], loop, &self.sounding, self.target, s, loop);
            scanRange(self.notes[0..self.note_count], loop, &self.sounding, self.target, 0.0, @min(e - loop, loop));
        } else {
            scanRange(self.notes[0..self.note_count], loop, &self.sounding, self.target, s, e);
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
