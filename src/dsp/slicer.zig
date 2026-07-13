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
    /// Named preset bands `cycleStepVel` steps through — same ladder as
    /// DrumMachine's, so the two grids' `c` key feels identical.
    const vel_presets = [_]u8{ 127, 95, 63, 31 };
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
        // zig fmt: off
        for (&self.voices) |*row| for (row) |*v| { v.* = .{}; };
        for (&self.pattern) |*p| p.* = .init(0);
        for (&self.vel) |*row| for (row) |*p| { p.* = .init(vel_full); };
        // zig fmt: on
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
        // zig fmt: off
        for (&copy.voices) |*row| for (row) |*v| { v.* = .{}; };
        // zig fmt: on
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

    /// Re-chop at detected transients (the MPC "slice at attacks" workflow):
    /// contiguous fresh-params regions, one per onset, first always anchored
    /// at 0. `sensitivity` 1 (only the hardest hits) .. 9 (every flutter),
    /// 5 = default. Returns the new slice count (1 = nothing detected, the
    /// whole clip as one slice).
    pub fn chopTransients(self: *Slicer, sensitivity: u8) u8 {
        var positions: [max_slices]f32 = undefined;
        const n = detectOnsets(self.samples, self.sample_rate, sensitivity, &positions);
        self.chopAt(positions[0..n]);
        return self.slice_count;
    }

    /// Chop into contiguous regions whose starts are `positions` (ascending
    /// fractions of the clip, first entry treated as 0); each region ends
    /// where the next begins, the last at 1.0.
    pub fn chopAt(self: *Slicer, positions: []const f32) void {
        const count: u8 = @intCast(std.math.clamp(positions.len, 1, max_slices));
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (0..count) |i| {
            self.slices[i] = .{
                .samples = self.samples,
                .start_norm = if (i == 0) 0.0 else std.math.clamp(positions[i], 0.0, 1.0),
                .end_norm = if (i + 1 < count) std.math.clamp(positions[i + 1], 0.0, 1.0) else 1.0,
            };
        }
        self.slice_count = count;
    }

    /// Split the cursor slice at its region midpoint: the new right half is
    /// inserted at `idx + 1` (inheriting the left half's params), and every
    /// later slice — including its pattern/velocity rows — shifts down one.
    /// Returns false when full or `idx` is out of range.
    pub fn splitSlice(self: *Slicer, idx: u8) bool {
        if (idx >= self.slice_count or self.slice_count >= max_slices) return false;
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        var i: usize = self.slice_count;
        while (i > idx + 1) : (i -= 1) {
            self.slices[i] = self.slices[i - 1];
            self.pattern[i].store(self.pattern[i - 1].load(.monotonic), .release);
            for (&self.vel[i], &self.vel[i - 1]) |*dst, *src| dst.store(src.load(.monotonic), .release);
        }
        const left = &self.slices[idx];
        const mid = left.start_norm + (left.end_norm - left.start_norm) / 2.0;
        var right = left.*;
        right.start_norm = mid;
        left.end_norm = mid;
        self.slices[idx + 1] = right;
        // The new right half starts silent — it inherited its sound from the
        // left, not its programming.
        self.pattern[idx + 1].store(0, .release);
        for (&self.vel[idx + 1]) |*p| p.store(vel_full, .release);
        self.slice_count += 1;
        self.resetVoicesLocked();
        return true;
    }

    /// Merge the cursor slice with the one after it: the region extends to
    /// the right slice's end, both patterns are OR-combined (max velocity
    /// where they collide), and every later slice shifts up one. Returns
    /// false when `idx` is the last slice or out of range.
    pub fn mergeSliceRight(self: *Slicer, idx: u8) bool {
        if (idx + 1 >= self.slice_count) return false;
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        self.slices[idx].end_norm = self.slices[idx + 1].end_norm;
        const merged = self.pattern[idx].load(.monotonic) | self.pattern[idx + 1].load(.monotonic);
        self.pattern[idx].store(merged, .release);
        for (&self.vel[idx], &self.vel[idx + 1], 0..) |*dst, *src, s| {
            const bit = @as(u64, 1) << @intCast(s);
            if (self.pattern[idx + 1].load(.monotonic) & bit != 0)
                dst.store(@max(dst.load(.monotonic), src.load(.monotonic)), .release);
        }
        var i: usize = idx + 1;
        while (i + 1 < self.slice_count) : (i += 1) {
            self.slices[i] = self.slices[i + 1];
            self.pattern[i].store(self.pattern[i + 1].load(.monotonic), .release);
            for (&self.vel[i], &self.vel[i + 1]) |*dst, *src| dst.store(src.load(.monotonic), .release);
        }
        self.pattern[self.slice_count - 1].store(0, .release);
        for (&self.vel[self.slice_count - 1]) |*p| p.store(vel_full, .release);
        self.slice_count -= 1;
        self.resetVoicesLocked();
        return true;
    }

    /// Kill every voice after a structural slice change (split/merge): the
    /// pools are indexed by slice, so a shifted row's ringing tail would
    /// finish through the wrong slice's params. Caller holds `sample_lock`.
    fn resetVoicesLocked(self: *Slicer) void {
        // zig fmt: off
        for (&self.voices) |*row| for (row) |*v| { v.* = .{}; };
        // zig fmt: on
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
            // zig fmt: off
            1 => pad.end_norm   = std.math.clamp(pad.end_norm   + s * 0.01, pad.start_norm + 0.01, 1.0),
            2 => pad.pitch_semitones = std.math.clamp(pad.pitch_semitones + s * 1.0, -24.0, 24.0),
            3 => pad.attack_s   = std.math.clamp(pad.attack_s   + s * 0.001, 0.0, 5.0),
            4 => pad.decay_s    = std.math.clamp(pad.decay_s    + s * 0.005, 0.0, 5.0),
            5 => pad.sustain    = std.math.clamp(pad.sustain    + s * 0.01, 0.0, 1.0),
            6 => pad.release_s  = std.math.clamp(pad.release_s  + s * 0.005, 0.001, 5.0),
            7 => pad.gain       = std.math.clamp(pad.gain       + s * 0.01, 0.0, 2.0),
            8 => pad.pan        = std.math.clamp(pad.pan        + s * 0.05, -1.0, 1.0),
            9 => if (steps != 0) { pad.reverse = !pad.reverse; },
            // zig fmt: on
            else => {},
        }
    }

    pub fn paramId(slice: u8, param: u8) u16 {
        return (@as(u16, slice) << 4) | (param & 0x0F);
    }

    /// Set slice-encoded param `id` to an absolute value (same clamps as
    /// `adjustParam`'s per-step nudges) — undo's restore half, mirroring
    /// `DrumMachine.setParamAbsolute`.
    pub fn setParamAbsolute(self: *Slicer, id: u16, value: f32) void {
        const slice_idx = id >> 4;
        const param = id & 0x0F;
        if (slice_idx >= max_slices) return;
        const pad = &self.slices[slice_idx];
        switch (param) {
            0 => pad.start_norm = std.math.clamp(value, 0.0, pad.end_norm - 0.01),
            // zig fmt: off
            1 => pad.end_norm   = std.math.clamp(value, pad.start_norm + 0.01, 1.0),
            2 => pad.pitch_semitones = std.math.clamp(value, -24.0, 24.0),
            3 => pad.attack_s   = std.math.clamp(value, 0.0, 5.0),
            4 => pad.decay_s    = std.math.clamp(value, 0.0, 5.0),
            5 => pad.sustain    = std.math.clamp(value, 0.0, 1.0),
            6 => pad.release_s  = std.math.clamp(value, 0.001, 5.0),
            7 => pad.gain       = std.math.clamp(value, 0.0, 2.0),
            8 => pad.pan        = std.math.clamp(value, -1.0, 1.0),
            9 => pad.reverse    = value >= 0.5,
            // zig fmt: on
            else => {},
        }
    }

    /// Current value of slice-encoded param `id`, in `setParamAbsolute`'s
    /// encoding (reverse as 0/1) — undo's capture half. Null past the live
    /// slice count, so undo skips rather than editing an inert slot.
    pub fn paramValue(self: *const Slicer, id: u16) ?f32 {
        const slice_idx = id >> 4;
        const param = id & 0x0F;
        if (slice_idx >= self.slice_count) return null;
        const pad = &self.slices[slice_idx];
        return switch (param) {
            // zig fmt: off
            0 => pad.start_norm,
            1 => pad.end_norm,
            2 => pad.pitch_semitones,
            3 => pad.attack_s,
            4 => pad.decay_s,
            5 => pad.sustain,
            6 => pad.release_s,
            7 => pad.gain,
            8 => pad.pan,
            9 => if (pad.reverse) 1.0 else 0.0,
            // zig fmt: on
            else => null,
        };
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

    /// Step one step's velocity through the named preset bands — same
    /// single-key gesture as `DrumMachine.cycleStepVel`.
    pub fn cycleStepVel(self: *Slicer, slice: u8, step: u8) void {
        const cur = self.stepVel(slice, step);
        var idx: usize = vel_presets.len - 1; // not a preset value -> next lands on preset[0]
        for (vel_presets, 0..) |v, i| {
            // zig fmt: off
            if (v == cur) { idx = i; break; }
            // zig fmt: on
        }
        self.setStepVel(slice, step, vel_presets[(idx + 1) % vel_presets.len]);
    }

    /// Nudge one step's velocity by `delta`, clamped to 1..127 — 0 would be
    /// silent; use x to remove a step instead of zeroing its velocity.
    pub fn nudgeStepVel(self: *Slicer, slice: u8, step: u8, delta: i32) void {
        const cur: i32 = self.stepVel(slice, step);
        const next = std.math.clamp(cur + delta, 1, 127);
        self.setStepVel(slice, step, @intCast(next));
    }

    /// Wipe one slice's row: no steps, all velocities back to full.
    pub fn clearSlice(self: *Slicer, slice: u8) void {
        if (slice >= max_slices) return;
        self.pattern[slice].store(0, .release);
        for (&self.vel[slice]) |*p| p.store(vel_full, .release);
    }

    /// Fill one slice's row with full-velocity steps across the active length.
    pub fn fillSlice(self: *Slicer, slice: u8) void {
        if (slice >= max_slices) return;
        self.pattern[slice].store(stepMask(self.step_count), .release);
        for (&self.vel[slice]) |*p| p.store(vel_full, .release);
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
            // zig fmt: off
            if (!sv.active) { slot = i; break; }
            if (sv.age < oldest_age) { oldest_age = sv.age; slot = i; }
            // zig fmt: on
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
        // zig fmt: off
        for (&self.voices) |*row| for (row) |*sv| { sv.* = .{}; };
        // zig fmt: on
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
            .set_param_abs => |e| self.setParamAbsolute(e.id, e.value),
            .note_off, .cc, .pitch_bend, .set_sidechain_buf, .capture_pad => {},
            .all_off => self.resetAll(),
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *Slicer = @ptrCast(@alignCast(ptr));
        self.resetAll();
    }
};

/// Energy-envelope onset detection for `chopTransients`: fills `out` with
/// ascending slice-start positions (fractions of the clip, `out[0]` always
/// 0.0) and returns how many were found (>= 1). An onset is a 10 ms RMS hop
/// that rises `ratio`x above the recent local average — `sensitivity` 1..9
/// maps to ratio 3.7 (only the hardest hits) down to 1.3 (every flutter) —
/// gated by a noise floor relative to the clip's own peak and a 40 ms
/// refractory so one drum hit can't chop twice. The boundary lands one hop
/// early so the attack transient stays inside its own slice.
pub fn detectOnsets(samples: []const f32, sample_rate: u32, sensitivity: u8, out: *[Slicer.max_slices]f32) u8 {
    out[0] = 0.0;
    var count: u8 = 1;
    if (samples.len == 0) return count;

    const hop: usize = @max(sample_rate / 100, 32);
    const hops = samples.len / hop;
    if (hops < 4) return count;

    const hopRms = struct {
        fn f(s: []const f32, h: usize, size: usize) f32 {
            var acc: f32 = 0;
            for (s[h * size ..][0..size]) |x| acc += x * x;
            return @sqrt(acc / @as(f32, @floatFromInt(size)));
        }
    }.f;

    var peak_env: f32 = 1e-9;
    for (0..hops) |h| peak_env = @max(peak_env, hopRms(samples, h, hop));
    const noise_floor = peak_env * 0.04;

    const s = std.math.clamp(sensitivity, 1, 9);
    const ratio = 3.7 - 0.3 * @as(f32, @floatFromInt(s - 1));
    const min_gap_hops: usize = 4; // 40 ms refractory

    // Moving local average over the last `ring.len` hops, seeded with the
    // first hop so a hot open doesn't divide by a zero-energy history.
    var ring = [_]f32{hopRms(samples, 0, hop)} ** 8;
    var ring_i: usize = 0;
    var prev_env = ring[0];
    var last_onset_hop: usize = 0;

    for (1..hops) |h| {
        const env = hopRms(samples, h, hop);
        var avg: f32 = 0;
        for (ring) |r| avg += r;
        avg /= @floatFromInt(ring.len);

        const rising = env > prev_env;
        const loud_enough = env > noise_floor;
        const jumps = env > avg * ratio;
        const spaced = h - last_onset_hop >= min_gap_hops;
        if (rising and loud_enough and jumps and spaced) {
            last_onset_hop = h;
            const pos = @as(f32, @floatFromInt((h - 1) * hop)) / @as(f32, @floatFromInt(samples.len));
            // The head is always slice 0; an onset this close to it is it.
            if (pos > 0.02 and count < Slicer.max_slices) {
                out[count] = pos;
                count += 1;
            }
        }

        ring[ring_i] = env;
        ring_i = (ring_i + 1) % ring.len;
        prev_env = env;
    }
    return count;
}

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

/// Four decaying noise bursts at 0/25/50/75% of a one-second clip —
/// a synthetic drum loop for the transient-chop tests.
fn burstClip(allocator: std.mem.Allocator, sample_rate: u32) ![]f32 {
    const len = sample_rate;
    const out = try allocator.alloc(f32, len);
    @memset(out, 0.0);
    var rng = std.Random.DefaultPrng.init(42);
    const burst_len = sample_rate / 20; // 50 ms
    for (0..4) |b| {
        const at = b * (len / 4);
        for (0..burst_len) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(burst_len));
            out[at + i] = (rng.random().float(f32) * 2.0 - 1.0) * (1.0 - t);
        }
    }
    return out;
}

test "chopTransients finds the bursts and anchors slice 0 at the head" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    std.testing.allocator.free(s.samples);
    s.samples = try burstClip(std.testing.allocator, 48_000);
    for (&s.slices) |*p| p.samples = s.samples;

    const n = s.chopTransients(5);
    try std.testing.expectEqual(@as(u8, 4), n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    // Each detected boundary sits within 3% of its burst (one hop early).
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[1].start_norm, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), s.slices[2].start_norm, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[3].start_norm, 0.03);
    // Contiguous: each slice ends where the next begins.
    try std.testing.expectApproxEqAbs(s.slices[1].start_norm, s.slices[0].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[3].end_norm, 1e-6);
}

test "chopTransients on silence falls back to one whole-clip slice" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    std.testing.allocator.free(s.samples);
    s.samples = try std.testing.allocator.alloc(f32, 48_000);
    @memset(s.samples, 0.0);
    for (&s.slices) |*p| p.samples = s.samples;

    try std.testing.expectEqual(@as(u8, 1), s.chopTransients(9));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[0].end_norm, 1e-6);
}

test "splitSlice halves the region and shifts later pattern rows down" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(3);
    s.toggleStep(2, 5); // will belong to slice 3 after the split
    s.slices[1].pitch_semitones = -12.0;

    try std.testing.expect(s.splitSlice(1));
    try std.testing.expectEqual(@as(u8, 4), s.slice_count);
    // Old slice 1 spanned 1/3..2/3; halves meet at 1/2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.slices[1].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.slices[2].start_norm, 1e-6);
    // The right half inherits params but starts silent.
    try std.testing.expectApproxEqAbs(@as(f32, -12.0), s.slices[2].pitch_semitones, 1e-6);
    try std.testing.expect(!s.stepActive(2, 5));
    // Old slice 2's programming followed it to row 3.
    try std.testing.expect(s.stepActive(3, 5));
}

test "mergeSliceRight ORs patterns and shifts later rows up" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.toggleStep(1, 0);
    s.setStepVel(1, 0, 40);
    s.toggleStep(2, 0);
    s.setStepVel(2, 0, 90);
    s.toggleStep(2, 7);
    s.toggleStep(3, 3);

    try std.testing.expect(s.mergeSliceRight(1));
    try std.testing.expectEqual(@as(u8, 3), s.slice_count);
    // Region 1 now spans old 1+2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[1].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[1].end_norm, 1e-6);
    // Colliding step keeps the louder velocity; disjoint steps both survive.
    try std.testing.expect(s.stepActive(1, 0));
    try std.testing.expectEqual(@as(u8, 90), s.stepVel(1, 0));
    try std.testing.expect(s.stepActive(1, 7));
    // Old slice 3 shifted up to row 2.
    try std.testing.expect(s.stepActive(2, 3));
    try std.testing.expect(!s.mergeSliceRight(2)); // last slice: nothing to its right
}

test "setParamAbsolute/paramValue roundtrip, null past slice_count" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.setParamAbsolute(Slicer.paramId(1, 2), -7.0);
    try std.testing.expectApproxEqAbs(@as(f32, -7.0), s.paramValue(Slicer.paramId(1, 2)).?, 1e-6);
    s.setParamAbsolute(Slicer.paramId(1, 9), 1.0);
    try std.testing.expect(s.slices[1].reverse);
    try std.testing.expectEqual(@as(?f32, null), s.paramValue(Slicer.paramId(2, 0)));
}

test "cycleStepVel walks the preset ladder; nudge clamps at 1" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(1);
    try std.testing.expectEqual(@as(u8, 127), s.stepVel(0, 0));
    s.cycleStepVel(0, 0);
    try std.testing.expectEqual(@as(u8, 95), s.stepVel(0, 0));
    s.nudgeStepVel(0, 0, -200);
    try std.testing.expectEqual(@as(u8, 1), s.stepVel(0, 0));
}

test "fillSlice/clearSlice cover exactly the active step range" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.setStepCount(12);
    s.fillSlice(0);
    try std.testing.expect(s.stepActive(0, 11));
    try std.testing.expect(!s.stepActive(0, 12));
    s.clearSlice(0);
    try std.testing.expect(!s.stepActive(0, 0));
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
