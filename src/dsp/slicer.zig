//! Step-sequenced sample chopper — the "Slicer" instrument. One shared
//! sample buffer is chopped into up to `max_slices` independently-
//! triggerable regions ("slices"), each with its own start/end/pitch/gain/
//! pan/reverse/ADSR — the same per-region params `dsp/sampler.zig`'s
//! standalone Sampler and `dsp/drum_sampler.zig`'s drum pads already carry,
//! sharing `dsp/pad.zig`'s `renderVoice` engine unmodified.
//!
//! Unlike DrumMachine (`max_pads` independent Samplers, each owning its own
//! clip buffer), every slice's `Pad.samples` here aliases the SAME
//! underlying buffer (a slice is just `{ptr, len}`, so this costs nothing) —
//! `sliceInto(n)` just sets each slice's `start_norm`/`end_norm` to an equal
//! 1/n fraction of the one shared clip. That's the whole trick that makes
//! "one sample, N independently playable chops" cheap.
//!
//! Its own step sequencer deliberately does NOT share code with
//! DrumMachine's, despite the conceptual overlap (both fire per-step
//! triggers with swing and per-step velocity) — DrumMachine is the heaviest-
//! tested, most atomics-delicate file in the codebase (see its own doc
//! comment), and entangling a second consumer with its internals is a real
//! risk for a modest amount of shared code. This file mirrors DrumMachine's
//! swing/velocity/step-boundary-firing algorithm independently instead.
//! Deliberately out of scope for this first pass: pattern variants, choke
//! groups, and song-mode/arrangement playback — a slicer track doesn't
//! participate in the arrangement yet (no clip stamping), same as how drum
//! pad banks/variants were added to DrumMachine in later, separate passes.

const std = @import("std");
const types = @import("../core/types.zig");
const wav = @import("../core/wav.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;
const pad_mod = @import("pad.zig");
const Pad = pad_mod.Pad;
const Voice = pad_mod.Voice;

const Sample = types.Sample;

pub const Slicer = struct {
    pub const max_slices: u8 = 64;
    pub const max_steps: u8 = 64;
    /// Small per-slice voice pool — slices are short one-shots retriggered
    /// often (stutters, rolls), so a few overlapping voices covers real use
    /// without Sampler's full 16 (a slicer track can have up to 64 of these
    /// pools live at once, unlike Sampler's single pad).
    pub const max_voices_per_slice: u8 = 4;
    /// Editable params per slice (mirrors `Sampler.adjustParam`'s ids 0-8
    /// exactly — start/end/pitch/attack/decay/sustain/release/gain/pan —
    /// minus `root_note`/`mono`, which don't apply to an unpitched one-shot
    /// region triggered by its own slice index, not a MIDI note).
    pub const slice_param_count: u8 = 9;
    /// `set_param`/`set_param_abs` ids are `slice << 4 | param` — same shape
    /// DrumMachine.paramId uses for its own per-pad params.
    pub const param_stride: u16 = 16;

    pub const vel_full: u8 = 127;
    pub fn velGain(level: u8) f32 {
        return @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(vel_full));
    }

    pub const swing_min: f32 = 50.0;
    pub const swing_max: f32 = 75.0;

    const SliceVoice = struct {
        active: bool = false,
        age: u64 = 0,
        v: Voice = .{},
    };

    allocator: std.mem.Allocator,
    sample_rate: u32,
    transport: *const Transport,

    /// Guards `samples` (and every slice's aliasing `Pad.samples`) against
    /// concurrent reads (audio thread) and writes (control thread calling
    /// `loadWav`/`sliceInto`) — mirrors `Sampler.pad_lock`. Ordinary per-slice
    /// param edits (gain, pan, start/end nudge, ...) are plain unlocked
    /// writes, same race-tolerant convention `Sampler.adjustParam`/
    /// `DrumMachine.choke_group` already use — worst case one stale block,
    /// never a crash, since nothing here reallocates.
    sample_lock: std.atomic.Mutex = .unlocked,
    /// The one shared clip every slice's `Pad.samples` aliases.
    samples: []f32,
    name: [8]u8 = [_]u8{' '} ** 8,
    /// True when the audio was loaded by the user (`:load-slice`) — only
    /// user audio is exported to the project's sample sidecar on save, same
    /// convention `Pad.user_sample` documents.
    user_sample: bool = false,

    /// Per-slice params. `slices[i].samples` always aliases `self.samples` —
    /// never independently allocated or freed; `deinit` frees `self.samples`
    /// exactly once. Slots at/past `slice_count` are inert (never triggered,
    /// never rendered) but still point at valid memory, so no branch needs a
    /// null-check the way DrumMachine's lazily-materialized pads do.
    slices: [max_slices]Pad = undefined,
    /// How many of `slices` are actually chopped out. Zero until `:slice`
    /// runs — an unsliced Slicer is silent, nothing to trigger, same as a
    /// never-loaded drum pad.
    slice_count: u8 = 0,
    voices: [max_slices][max_voices_per_slice]SliceVoice = undefined,
    next_age: u64 = 0,

    /// Bitmask per slice, one bit per step (see DrumMachine's identical
    /// field for the atomics rationale).
    pattern: [max_slices]std.atomic.Value(u64) = undefined,
    /// Per-step velocity (0-127; 127 = full), one atomic per step per slice.
    vel: [max_slices][max_steps]std.atomic.Value(u8) = undefined,
    step_count: u8 = 16,
    swing: std.atomic.Value(f32) = .init(50.0),

    // Audio-thread-only state:
    next_step_k: u64 = 0,
    current_step: std.atomic.Value(u8) = .init(0),

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, transport: *const Transport) !Slicer {
        const samples = try generateDefaultClip(allocator, sample_rate);
        var name: [8]u8 = [_]u8{' '} ** 8;
        @memcpy(name[0..5], "slice");
        var self: Slicer = .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .transport = transport,
            .samples = samples,
            .name = name,
        };
        for (&self.slices) |*p| p.* = .{ .samples = samples };
        for (&self.voices) |*row| for (row) |*v| { v.* = .{}; };
        for (&self.pattern) |*p| p.* = .init(0);
        for (&self.vel) |*row| for (row) |*p| { p.* = .init(vel_full); };
        return self;
    }

    pub fn deinit(self: *Slicer) void {
        self.allocator.free(self.samples);
    }

    /// Deep copy for track duplication: the clip audio gets a fresh
    /// allocation so the two slicers share no memory; every slice re-aliases
    /// the NEW buffer. Voice state resets — no mid-flight hit worth carrying.
    pub fn dupe(self: *const Slicer) !Slicer {
        var copy = self.*;
        copy.samples = try self.allocator.dupe(f32, self.samples);
        for (&copy.slices) |*p| p.samples = copy.samples;
        copy.sample_lock = .unlocked;
        for (&copy.voices) |*row| for (row) |*v| { v.* = .{}; };
        copy.next_age = 0;
        copy.next_step_k = 0;
        copy.current_step = .init(0);
        return copy;
    }

    pub fn device(self: *Slicer) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .event = eventOpaque,
        .reset = resetOpaque,
    };

    pub fn clipName(self: *const Slicer) []const u8 {
        var end: usize = self.name.len;
        while (end > 0 and self.name[end - 1] == ' ') end -= 1;
        return self.name[0..end];
    }

    // -----------------------------------------------------------------------
    // Loading + slicing (control thread only, not while audio thread runs)

    /// Parse raw WAV bytes into the shared clip. Resamples to engine rate if
    /// needed. When `reset_slices` is true (the interactive `:load-slice`
    /// path), clears every slice — the old boundaries (fractions of the OLD
    /// clip's length) are meaningless against new audio, so the user
    /// re-chops with `:slice` afterward. `reset_slices = false` is for
    /// restoring a saved project: persist.zig applies each slice's saved
    /// start/end/gain/etc. BEFORE the audio bytes are read back from the
    /// sample sidecar, so this must only re-point every slice's `.samples`
    /// at the fresh buffer without touching `slice_count` or any slice's own
    /// params, or the just-restored slicing would be wiped out from under it.
    pub fn loadWav(self: *Slicer, wav_data: []const u8, name: []const u8, reset_slices: bool) !void {
        const result = try wav.parseAlloc(self.allocator, wav_data);
        errdefer self.allocator.free(result.samples);

        const samples = if (result.sample_rate == self.sample_rate)
            result.samples
        else blk: {
            const resampled = try pad_mod.resampleLinear(
                self.allocator,
                result.samples,
                result.sample_rate,
                self.sample_rate,
            );
            self.allocator.free(result.samples);
            break :blk resampled;
        };

        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        self.allocator.free(self.samples);
        var n: [8]u8 = [_]u8{' '} ** 8;
        const len = @min(name.len, 8);
        @memcpy(n[0..len], name[0..len]);
        self.samples = samples;
        self.name = n;
        self.user_sample = true;
        if (reset_slices) {
            self.slice_count = 0;
            for (&self.slices) |*p| p.* = .{ .samples = samples };
        } else {
            for (&self.slices) |*p| p.samples = samples;
        }
    }

    /// Equal-divide the shared clip into `n` regions (clamped to
    /// `1..=max_slices`), each a fresh default-params slice spanning its own
    /// 1/n fraction. Existing per-slice pattern/velocity data past the new
    /// `n` stays in the atomics (harmless — `processBlock` only ever reads
    /// pattern bits for `slice_idx < slice_count`) so re-slicing to a larger
    /// `n` later doesn't lose earlier programming.
    pub fn sliceInto(self: *Slicer, n: u8) void {
        const count = std.math.clamp(n, 1, max_slices);
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        const step_norm = 1.0 / @as(f32, @floatFromInt(count));
        for (0..count) |i| {
            self.slices[i] = .{
                .samples = self.samples,
                .start_norm = @as(f32, @floatFromInt(i)) * step_norm,
                .end_norm = @as(f32, @floatFromInt(i + 1)) * step_norm,
            };
        }
        self.slice_count = count;
    }

    // -----------------------------------------------------------------------
    // Param editing — `id` is `slice << 4 | param` (see `param_stride`).

    pub fn adjustParam(self: *Slicer, id: u16, steps: i32) void {
        const slice_idx = id >> 4;
        const param = id & 0x0F;
        if (slice_idx >= max_slices) return;
        const s: f32 = @floatFromInt(steps);
        const pad = &self.slices[slice_idx];
        switch (param) {
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
            else => {},
        }
    }

    pub fn paramId(slice: u8, param: u8) u16 {
        return (@as(u16, slice) << 4) | (param & 0x0F);
    }

    // -----------------------------------------------------------------------
    // Step grid (control thread edits; audio thread reads in processBlock)

    pub fn toggleStep(self: *Slicer, slice: u8, step: u8) void {
        if (slice >= max_slices or step >= max_steps) return;
        const bit = @as(u64, 1) << @intCast(step);
        _ = self.pattern[slice].fetchXor(bit, .release);
    }

    pub fn stepActive(self: *const Slicer, slice: u8, step: u8) bool {
        if (slice >= max_slices or step >= max_steps) return false;
        return (self.pattern[slice].load(.monotonic) >> @intCast(step)) & 1 == 1;
    }

    pub fn stepVel(self: *const Slicer, slice: u8, step: u8) u8 {
        if (slice >= max_slices or step >= max_steps) return vel_full;
        return self.vel[slice][step].load(.monotonic);
    }

    pub fn setStepVel(self: *Slicer, slice: u8, step: u8, level: u8) void {
        if (slice >= max_slices or step >= max_steps) return;
        self.vel[slice][step].store(level, .release);
    }

    pub fn setStepCount(self: *Slicer, n: u8) void {
        self.step_count = std.math.clamp(n, 1, max_steps);
    }

    /// Bitmask covering exactly `n` low bits (n >= max_steps = all set).
    /// Mirrors `DrumMachine.stepMask`.
    pub fn stepMask(n: u8) u64 {
        if (n >= max_steps) return ~@as(u64, 0);
        return (@as(u64, 1) << @intCast(n)) - 1;
    }

    pub fn currentStep(self: *const Slicer) u8 {
        return self.current_step.load(.monotonic);
    }

    /// Nudge swing by `delta` percent, clamped to [swing_min, swing_max].
    pub fn adjustSwing(self: *Slicer, delta: f32) void {
        const s = std.math.clamp(self.swing.load(.monotonic) + delta, swing_min, swing_max);
        self.swing.store(s, .monotonic);
    }

    pub fn setSwing(self: *Slicer, pct: f32) void {
        self.swing.store(std.math.clamp(pct, swing_min, swing_max), .monotonic);
    }

    // -----------------------------------------------------------------------
    // Audio thread processing

    /// Trigger `slice` (0-based), stealing the oldest voice in its own small
    /// pool if all are busy — no forced choke-on-retrigger (unlike
    /// DrumMachine's pads): a slice replayed while still ringing is allowed
    /// to overlap, matching the "manipulate chops live" workflow (stutters,
    /// rolls) rather than the drum-kit convention of always cutting the
    /// previous hit.
    pub fn triggerSlice(self: *Slicer, slice: u8, vel: f32, block_start: u32) void {
        if (slice >= self.slice_count) return;
        var pool = &self.voices[slice];
        var slot: usize = 0;
        var oldest_age: u64 = std.math.maxInt(u64);
        for (pool, 0..) |*sv, i| {
            if (!sv.active) { slot = i; break; }
            if (sv.age < oldest_age) { oldest_age = sv.age; slot = i; }
        }
        pool[slot] = .{
            .active = true,
            .age = self.next_age,
            .v = .{ .active = true, .played = 0, .block_start = block_start, .vel = vel },
        };
        self.next_age +%= 1;
    }

    fn framesPerStep(self: *const Slicer) f64 {
        // One step = sixteenth note (1/4 beat) — matches DrumMachine.
        const bpm = @max(self.transport.tempo_bpm, 1.0);
        const fpb = @as(f64, @floatFromInt(self.sample_rate)) * 60.0 / bpm;
        return @max(1.0, fpb / 4.0);
    }

    pub fn processBlock(self: *Slicer, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);
        const sr: f64 = @floatFromInt(self.sample_rate);

        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();

        if (self.transport.playing and self.slice_count > 0) {
            const pos_f = @as(f64, @floatFromInt(self.transport.position_frames));
            const fps = self.framesPerStep();
            const swing_pct = self.swing.load(.monotonic);
            const swing_delay: f64 = fps * @as(f64, swing_pct - 50.0) / 50.0;
            var step_k = self.next_step_k;

            const expected = @as(f64, @floatFromInt(step_k)) * fps;
            if (@abs(expected - pos_f) > fps * 2.0) {
                step_k = @intFromFloat(@ceil(pos_f / fps));
            }

            while (true) {
                var fire_pos = @as(f64, @floatFromInt(step_k)) * fps;
                if (step_k & 1 == 1) fire_pos += swing_delay;
                if (fire_pos >= pos_f + @as(f64, @floatFromInt(frames))) break;

                const fire_frame: u32 = if (fire_pos <= pos_f)
                    0
                else
                    @intCast(@min(
                        @as(u64, @intFromFloat(fire_pos - pos_f)),
                        @as(u64, frames - 1),
                    ));

                const step_idx: u8 = @intCast(step_k % self.step_count);
                for (0..self.slice_count) |s| {
                    if ((self.pattern[s].load(.acquire) >> @intCast(step_idx)) & 1 == 1) {
                        self.triggerSlice(@intCast(s), velGain(self.stepVel(@intCast(s), step_idx)), fire_frame);
                    }
                }
                self.current_step.store(step_idx, .monotonic);
                step_k += 1;
            }

            self.next_step_k = step_k;
        }

        for (self.slices[0..self.slice_count], self.voices[0..self.slice_count]) |*pad, *pool| {
            for (pool) |*sv| {
                if (!sv.active) continue;
                // Keep a mid-block trigger's `block_start` offset for its
                // first render — renderVoice consumes and resets it — same
                // rule as Sampler.processBlock (see its comment there).
                pad_mod.renderVoice(&sv.v, pad, buf, channels, frames, sr);
                if (!sv.v.active) sv.active = false;
            }
        }
    }

    pub fn resetAll(self: *Slicer) void {
        for (&self.voices) |*row| for (row) |*sv| { sv.* = .{}; };
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *Slicer = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn eventOpaque(ptr: *anyopaque, ev: dsp.Event) void {
        const self: *Slicer = @ptrCast(@alignCast(ptr));
        switch (ev) {
            // A qwerty/MIDI note maps onto a slice by index, wrapping modulo
            // the current slice count — same convention DrumMachine.
            // triggerPad's `note % max_pads` uses for pad triggering.
            .note_on => |e| if (self.slice_count > 0) {
                self.triggerSlice(e.note % self.slice_count, e.velocity, 0);
            },
            .set_param => |e| self.adjustParam(e.id, e.steps),
            .note_off, .cc, .pitch_bend, .set_param_abs, .set_sidechain_buf => {},
            .all_off => self.resetAll(),
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *Slicer = @ptrCast(@alignCast(ptr));
        self.resetAll();
    }
};

/// A short plucked C4 tone, same generator `dsp/sampler.zig` uses for its
/// own default clip — so a freshly inserted Slicer has real audio to chop
/// immediately (`:slice 8` works before any WAV is loaded), replaced by
/// `loadWav`.
fn generateDefaultClip(allocator: std.mem.Allocator, sample_rate: u32) ![]f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const len: usize = @intFromFloat(sr * 0.6);
    const out = try allocator.alloc(f32, len);
    const freq: f32 = 261.6256; // C4
    const tau: f32 = 0.18;
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const env = @exp(-t / tau);
        const phase = 2.0 * std.math.pi * freq * t;
        s.* = env * (0.9 * @sin(phase) + 0.2 * @sin(2.0 * phase));
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests

test "sliceInto equal-divides the clip and clamps out-of-range counts" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    s.sliceInto(4);
    try std.testing.expectEqual(@as(u8, 4), s.slice_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[0].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[3].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[3].end_norm, 1e-6);

    s.sliceInto(0); // clamps up to 1
    try std.testing.expectEqual(@as(u8, 1), s.slice_count);
    s.sliceInto(200); // clamps down to max_slices
    try std.testing.expectEqual(Slicer.max_slices, s.slice_count);
}

test "every slice aliases the same underlying buffer (no duplication)" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(8);
    for (s.slices[0..8]) |slice| {
        try std.testing.expectEqual(s.samples.ptr, slice.samples.ptr);
    }
}

test "triggerSlice renders only within its own region" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(1, 1.0, 0);

    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.001);

    // Slice 1's Voice.played must never exceed its own region length.
    try std.testing.expect(s.voices[1][0].v.played <= @as(f64, @floatFromInt(s.samples.len)) / 2.0 + 1.0);
}

test "triggerSlice past slice_count is a no-op" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(5, 1.0, 0);
    try std.testing.expect(!s.voices[5][0].active);
}

test "step sequencer fires the right slice on schedule" {
    var transport = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    transport.play();
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.toggleStep(2, 0); // slice 2 fires on step 0
    s.setStepCount(16);

    var buf: [64]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expect(s.voices[2][0].active);
    try std.testing.expect(!s.voices[0][0].active);
}

test "note_on wraps a note onto a slice by index" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.device().sendEvent(.{ .note_on = .{ .note = 5, .velocity = 1.0 } }); // 5 % 4 = 1
    try std.testing.expect(s.voices[1][0].active);
}

test "adjustParam edits the addressed slice only" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.adjustParam(Slicer.paramId(2, 7), 10); // slice 2's gain +10 steps of 0.01
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), s.slices[2].gain, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[0].gain, 1e-4);
}

test "all_off clears every slice's voices" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(0, 1.0, 0);
    s.triggerSlice(1, 1.0, 0);
    s.device().sendEvent(.all_off);
    try std.testing.expect(!s.voices[0][0].active);
    try std.testing.expect(!s.voices[1][0].active);
}
