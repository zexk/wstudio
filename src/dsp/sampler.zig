//! Single-clip chromatic sampler — the melodic counterpart to the drum
//! machine. One sample is held in a `Pad` and played back polyphonically:
//! each MIDI note triggers a voice pitched by `(note - root_note)` semitones
//! on top of the pad's own transpose. Voices are one-shots (note-off is
//! ignored); the amp ADSR and region trim shape the tail.
//!
//! The heavy lifting — fractional pitched reads, region trim, reverse, ADSR,
//! pan — is shared with the drum machine via `pad.renderVoice`, so a
//! Sampler is effectively a thin shim over the same Pad/Voice engine. Per-clip
//! params are plain scalars nudged on the audio thread via the `set_param`
//! device event (race-free, same path the synth and drum editors use).

const std = @import("std");
const types = @import("../core/types.zig");
const wav = @import("../core/wav.zig");
const dsp = @import("device.zig");
const pad_dsp = @import("pad.zig");
const Pad = pad_dsp.Pad;
const Voice = pad_dsp.Voice;

const Sample = types.Sample;

pub const Sampler = struct {
    pub const max_voices: u8 = 16;
    /// Number of editable params (see `adjustParam`).
    pub const param_count: u8 = 11;

    pub const NoteVoice = struct {
        active: bool = false,
        note: u7 = 0,
        /// Pitch offset from the pad's base transpose, in semitones.
        semis: f32 = 0,
        /// Monotonic trigger order, for oldest-voice stealing.
        age: u64 = 0,
        v: Voice = .{},
    };

    allocator: std.mem.Allocator,
    sample_rate: u32,

    /// Guards `pad.samples` against concurrent reads (audio thread) and writes
    /// (control thread calling loadWav at runtime). Mirrors DrumMachine.
    pad_lock: std.atomic.Mutex = .unlocked,
    /// The clip plus its shared sampler params (gain/pan/pitch/trim/ADSR).
    pad: Pad,
    /// MIDI note at which the clip plays at its native pitch.
    root_note: u7 = 60,

    // Audio-thread-only state:
    voices: [max_voices]NoteVoice,
    /// Monotonic trigger counter for voice-stealing order.
    next_age: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Sampler {
        const samples = try generateDefaultClip(allocator, sample_rate);
        var name: [8]u8 = [_]u8{' '} ** 8;
        @memcpy(name[0..4], "tone");
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .pad = .{ .samples = samples, .name = name },
            .voices = [_]NoteVoice{.{}} ** max_voices,
        };
    }

    pub fn deinit(self: *Sampler) void {
        self.allocator.free(self.pad.samples);
    }

    /// Deep copy for track duplication: the clip audio gets a fresh
    /// allocation so the two samplers share no memory. Voice state resets —
    /// there are no mid-flight notes worth carrying over.
    pub fn dupe(self: *const Sampler) !Sampler {
        var copy = self.*;
        copy.pad.samples = try self.allocator.dupe(f32, self.pad.samples);
        copy.pad_lock = .unlocked;
        copy.voices = [_]NoteVoice{.{}} ** max_voices;
        copy.next_age = 0;
        return copy;
    }

    pub fn device(self: *Sampler) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .event = eventOpaque,
        .reset = resetOpaque,
    };

    pub fn clipName(self: *const Sampler) []const u8 {
        var end: usize = self.pad.name.len;
        while (end > 0 and self.pad.name[end - 1] == ' ') end -= 1;
        return self.pad.name[0..end];
    }

    // -----------------------------------------------------------------------
    // Param editing — `id` is the param index (single pad, no pad nibble).

    /// Nudge param `id` by `steps` (h/l = ±1, H/L = ±10). Runs on the audio
    /// thread via the `set_param` event so it never races the block reader.
    pub fn adjustParam(self: *Sampler, id: u8, steps: i32) void {
        const s: f32 = @floatFromInt(steps);
        const pad = &self.pad;
        switch (id) {
            0 => pad.start_norm = std.math.clamp(pad.start_norm + s * 0.01, 0.0, pad.end_norm - 0.01),
            1 => pad.end_norm   = std.math.clamp(pad.end_norm   + s * 0.01, pad.start_norm + 0.01, 1.0),
            2 => pad.pitch_semitones = std.math.clamp(pad.pitch_semitones + s * 1.0, -24.0, 24.0),
            3 => pad.attack_s   = std.math.clamp(pad.attack_s   + s * 0.001, 0.0, 5.0),
            4 => pad.decay_s    = std.math.clamp(pad.decay_s    + s * 0.005, 0.0, 5.0),
            5 => pad.sustain    = std.math.clamp(pad.sustain    + s * 0.01, 0.0, 1.0),
            6 => pad.release_s  = std.math.clamp(pad.release_s  + s * 0.005, 0.001, 5.0),
            7 => pad.gain       = std.math.clamp(pad.gain       + s * 0.01, 0.0, 2.0),
            8 => pad.pan        = std.math.clamp(pad.pan        + s * 0.05, -1.0, 1.0),
            9 => if (steps != 0) { pad.reverse = !pad.reverse; },
            10 => {
                const r = @as(i32, self.root_note) + steps;
                self.root_note = @intCast(std.math.clamp(r, 0, 127));
            },
            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // Sample loading (call from control side only, not while audio thread runs)

    /// Parse raw WAV bytes into the clip, keeping every other pad param as-is.
    /// Resamples to engine rate if needed.
    pub fn loadWav(self: *Sampler, wav_data: []const u8, name: []const u8) !void {
        const result = try wav.parseAlloc(self.allocator, wav_data);
        errdefer self.allocator.free(result.samples);

        const samples = if (result.sample_rate == self.sample_rate)
            result.samples
        else blk: {
            const resampled = try pad_dsp.resampleLinear(
                self.allocator,
                result.samples,
                result.sample_rate,
                self.sample_rate,
            );
            self.allocator.free(result.samples);
            break :blk resampled;
        };

        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        self.allocator.free(self.pad.samples);
        var n: [8]u8 = [_]u8{' '} ** 8;
        const len = @min(name.len, 8);
        @memcpy(n[0..len], name[0..len]);
        self.pad.samples = samples;
        self.pad.name = n;
    }

    /// Replace the clip with already-decoded samples, resetting every other
    /// pad param to its default (gain 1.0, unity trim, flat ADSR, etc). Used
    /// when a caller wants a clean slate rather than `loadWav`'s in-place swap
    /// — e.g. procedurally generated kit pads.
    pub fn setSamples(self: *Sampler, samples: []f32, name: []const u8) void {
        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        self.allocator.free(self.pad.samples);
        var n: [8]u8 = [_]u8{' '} ** 8;
        const len = @min(name.len, 8);
        @memcpy(n[0..len], name[0..len]);
        self.pad = .{ .samples = samples, .gain = 1.0, .name = n };
    }

    // -----------------------------------------------------------------------
    // Audio thread processing

    /// Trigger a one-shot voice at `note` (chromatic offset from `root_note`),
    /// `vel` (0..1, applied on top of the pad gain) starting `block_start`
    /// frames into the next `processBlock` call. Runs on the audio thread via
    /// the `note_on` device event; also called directly by DrumMachine, whose
    /// pads are plain embedded Samplers.
    pub fn trigger(self: *Sampler, note: u7, vel: f32, block_start: u32) void {
        // Reuse a free voice, else steal the oldest active one.
        var slot: usize = 0;
        var oldest_age: u64 = std.math.maxInt(u64);
        for (&self.voices, 0..) |*nv, i| {
            if (!nv.active) { slot = i; break; }
            if (nv.age < oldest_age) { oldest_age = nv.age; slot = i; }
        }
        self.voices[slot] = .{
            .active = true,
            .note = note,
            .semis = @as(f32, @floatFromInt(@as(i16, note) - @as(i16, self.root_note))),
            .age = self.next_age,
            .v = .{ .active = true, .played = 0, .block_start = block_start, .vel = vel },
        };
        self.next_age +%= 1;
    }

    pub fn processBlock(self: *Sampler, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);
        const sr: f64 = @floatFromInt(self.sample_rate);

        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();

        for (&self.voices) |*nv| {
            if (!nv.active) continue;
            nv.v.block_start = 0;
            // Effective pad: pad params + this voice's chromatic transpose.
            // The value copy shares the `samples` slice (no allocation).
            var eff = self.pad;
            eff.pitch_semitones = std.math.clamp(self.pad.pitch_semitones + nv.semis, -60.0, 60.0);
            pad_dsp.renderVoice(&nv.v, &eff, buf, channels, frames, sr);
            if (!nv.v.active) nv.active = false;
        }
    }

    pub fn resetAll(self: *Sampler) void {
        for (&self.voices) |*nv| nv.* = .{};
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *Sampler = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn eventOpaque(ptr: *anyopaque, ev: dsp.Event) void {
        const self: *Sampler = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .note_on   => |e| self.trigger(e.note, e.velocity, 0),
            .set_param => |e| self.adjustParam(e.id, e.steps),
            .note_off, .cc, .pitch_bend => {},
            .all_off   => self.resetAll(),
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *Sampler = @ptrCast(@alignCast(ptr));
        self.resetAll();
    }
};

/// A short plucked C4 (≈261.6 Hz) tone with exponential decay, so a freshly
/// inserted sampler is immediately audible at root note 60. Replaced by
/// `loadWav`.
fn generateDefaultClip(allocator: std.mem.Allocator, sample_rate: u32) ![]f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const len: usize = @intFromFloat(sr * 0.6);
    const out = try allocator.alloc(f32, len);
    const freq: f32 = 261.6256; // C4
    const tau: f32 = 0.18; // decay time constant
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const env = @exp(-t / tau);
        const phase = 2.0 * std.math.pi * freq * t;
        // Fundamental plus a quieter octave for a little body.
        s.* = env * (0.9 * @sin(phase) + 0.2 * @sin(2.0 * phase));
    }
    return out;
}

// -----------------------------------------------------------------------
// Tests

test "default sampler is audible at root note" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();

    const dev = s.device();
    dev.sendEvent(.{ .note_on = .{ .note = 60, .velocity = 1.0 } });

    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0);
    dev.process(&buf);

    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.01);
}

test "higher note plays back faster (chromatic transpose)" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();

    // An octave up consumes the region twice as fast, so its voice deactivates
    // in fewer blocks than the root note.
    const blocks_to_finish = struct {
        fn run(smp: *Sampler, note: u7) usize {
            smp.resetAll();
            smp.trigger(note, 1.0, 0);
            var buf: [512]Sample = undefined;
            var n: usize = 0;
            while (smp.voices[0].active and n < 10_000) : (n += 1) {
                @memset(&buf, 0.0);
                smp.processBlock(&buf);
            }
            return n;
        }
    }.run;

    const root_blocks = blocks_to_finish(&s, 60);
    const oct_blocks = blocks_to_finish(&s, 72);
    try std.testing.expect(oct_blocks < root_blocks);
}

test "all_off clears voices" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.trigger(64, 1.0, 0);
    try std.testing.expect(s.voices[0].active);
    s.device().sendEvent(.all_off);
    try std.testing.expect(!s.voices[0].active);
}

test "adjustParam edits clip params and root note" {
    var s = try Sampler.init(std.testing.allocator, 48_000);
    defer s.deinit();
    s.adjustParam(2, 5); // pitch +5 semis
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), s.pad.pitch_semitones, 1e-4);
    s.adjustParam(10, -12); // root down an octave
    try std.testing.expectEqual(@as(u7, 48), s.root_note);
    s.adjustParam(9, 1); // reverse toggle
    try std.testing.expect(s.pad.reverse);
}
