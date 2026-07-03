//! Step-sequenced multisampler — the drum machine instrument.
//!
//! Eight pads hold mono f32 clips (synthesised by default; replaceable
//! with WAV data).  Each pad is a small Sampler with its own settings:
//! sample start/end trim, pitch (playback transpose), an amplitude ADSR,
//! gain, pan, and a reverse toggle — the Pad/Voice types and the voice
//! renderer live in pad.zig, shared with the standalone melodic Sampler.
//! A 16-step bitmask per pad stores the
//! pattern; each bit is a u32 atomic so the UI thread can flip bits safely
//! while the audio thread reads them.  Two more bitplanes per pad hold a
//! 2-bit per-step velocity level (100/75/50/25%).  The sequencer fires on
//! step boundaries derived from the transport, using a monotonic step
//! counter to avoid the double-fire and float-truncation bugs that arise
//! from recomputing the boundary position every block; MPC-style swing
//! (50–75%) delays each off-beat 16th within its 8th-note pair.
//!
//! Per-pad params are plain scalar fields read by the audio thread and
//! nudged on the audio thread (via the `set_param` device event, with the
//! pad index encoded in the high nibble of the id) — same race-free path
//! the synth editor uses.  The UI reads them for display without locking,
//! matching the synth editor's convention.

const std = @import("std");
const types = @import("../core/types.zig");
const wav = @import("../core/wav.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;
const pad_mod = @import("pad.zig");

const Sample = types.Sample;
const Pad = pad_mod.Pad;
const Voice = pad_mod.Voice;

/// The shipped 8-pad kit: WAVs embedded from src/assets/kit/ (rendered by the
/// `genkit` build tool from dsp/drum_kit.zig). `data` is raw WAV bytes decoded
/// at init; `gain` is the pad's default mixer level.
const KitSlot = struct { data: []const u8, name: []const u8, gain: f32 };
const default_kit = [_]KitSlot{
    .{ .data = @embedFile("../assets/kit/kick.wav"),  .name = "kick",  .gain = 1.00 },
    .{ .data = @embedFile("../assets/kit/snare.wav"), .name = "snare", .gain = 0.85 },
    .{ .data = @embedFile("../assets/kit/hihat.wav"), .name = "hihat", .gain = 0.50 },
    .{ .data = @embedFile("../assets/kit/open.wav"),  .name = "open",  .gain = 0.50 },
    .{ .data = @embedFile("../assets/kit/clap.wav"),  .name = "clap",  .gain = 0.70 },
    .{ .data = @embedFile("../assets/kit/tom1.wav"),  .name = "tom-1", .gain = 0.80 },
    .{ .data = @embedFile("../assets/kit/tom2.wav"),  .name = "tom-2", .gain = 0.80 },
    .{ .data = @embedFile("../assets/kit/rim.wav"),   .name = "rim",   .gain = 0.65 },
};

pub const DrumMachine = struct {
    pub const max_pads: u8 = 8;
    pub const max_steps: u8 = 32;
    /// Max pattern variants (A..H) one machine can hold.
    pub const max_variants: u8 = 8;
    /// Max clips one lane can hold for song-mode playback (see `song_clips`).
    pub const max_song_clips: u16 = 256;

    /// Swing bounds, MPC-style percent: 50 = straight, 66.7 = triplet feel,
    /// 75 = the hardest shuffle. Position of the off-beat 16th within its
    /// 8th-note pair.
    pub const swing_min: f32 = 50.0;
    pub const swing_max: f32 = 75.0;

    /// Gain for a step's 2-bit velocity level. Level 0 (both plane bits
    /// clear) is full volume, so untouched steps and pre-v4 files play
    /// exactly as before; each level above attenuates by 25%:
    /// 0 → 100%, 1 → 75%, 2 → 50%, 3 → 25%.
    pub fn velGain(level: u2) f32 {
        return 1.0 - 0.25 * @as(f32, @floatFromInt(level));
    }

    /// Display percent for a 2-bit velocity level (100/75/50/25).
    pub fn velPercent(level: u2) u8 {
        return 100 - 25 * @as(u8, level);
    }

    /// One pattern variant: a bank slot for the step grid. The active variant
    /// lives in the atomic `pattern`/`step_count` fields; inactive ones rest
    /// here as plain data (control thread only).
    pub const Variant = struct {
        pattern: [max_pads]u32 = [_]u32{0} ** max_pads,
        /// Per-step velocity bitplanes: bit k holds the low/high bit of
        /// step k's 2-bit level (see `velGain`).
        vel_lo:  [max_pads]u32 = [_]u32{0} ** max_pads,
        vel_hi:  [max_pads]u32 = [_]u32{0} ** max_pads,
        step_count: u8 = 16,
    };

    /// A drum clip flattened onto the arrangement's step timeline. `pattern` is
    /// a plain snapshot of the source bitmask (no atomics — the audio thread
    /// reads it under `pad_lock`). The clip's own `step_count`-long pattern
    /// repeats to fill `span_steps` (its whole-bar length on the timeline).
    pub const SongClip = struct {
        start_step: u32,
        span_steps: u32,
        step_count: u8,
        pattern: [max_pads]u32,
        /// Per-step velocity bitplanes, same encoding as the live grid.
        vel_lo: [max_pads]u32 = [_]u32{0} ** max_pads,
        vel_hi: [max_pads]u32 = [_]u32{0} ** max_pads,
    };
    /// Number of editable params per pad (see `adjustParam`).
    pub const pad_param_count: u8 = 10;
    /// Id-space stride per pad. `set_param` ids are `pad << 4 | param`, so the
    /// stride is a power of two and pad/param decode with shift + mask.
    pub const param_stride: u8 = 16;

    allocator: std.mem.Allocator,
    sample_rate: u32,
    transport: *const Transport,

    /// Guards `pads[]` against concurrent reads (audio thread) and writes
    /// (control thread calling setPadSamples/loadPadWav at runtime).
    pad_lock: std.atomic.Mutex = .unlocked,
    pads: [max_pads]?Pad,
    /// Bitmask: bit k == 1 means step k is active. u32 for atomic compat.
    /// Always mirrors the active variant; edits land here and are synced back
    /// to `variants[variant]` when switching away.
    pattern: [max_pads]std.atomic.Value(u32),
    /// Per-step velocity bitplanes (see `velGain`): bit k of `vel_lo`/`vel_hi`
    /// is the low/high bit of step k's 2-bit level. Atomic for the same
    /// UI-edits-while-audio-reads reason as `pattern`.
    vel_lo: [max_pads]std.atomic.Value(u32),
    vel_hi: [max_pads]std.atomic.Value(u32),
    step_count: u8,
    /// Swing percent (see `swing_min`/`swing_max`): where the off-beat 16th
    /// sits within its 8th-note pair. UI writes, audio thread reads.
    swing: std.atomic.Value(f32) = .init(50.0),

    // ── Pattern variants (control thread only) ──────────────────────────────
    /// Bank slots. Slot `variant` is stale while active — read it through
    /// `variantData`, which pulls the live atomics instead.
    variants: [max_variants]Variant = [_]Variant{.{}} ** max_variants,
    variant_count: u8 = 1,
    /// Index of the active variant (the one in the live `pattern`).
    variant: u8 = 0,

    // ── Song-mode playback (control thread writes, audio thread reads under
    //    pad_lock) ──────────────────────────────────────────────────────────
    /// When true, processBlock fires from `song_clips` under the playhead
    /// instead of the live `pattern`. Set via Session.setSongMode.
    song_mode: bool = false,
    /// The lane's clips placed on the arrangement's step timeline.
    song_clips: [max_song_clips]SongClip = undefined,
    song_clip_count: u16 = 0,
    /// Whole-arrangement length in steps; the song loops at this boundary.
    song_length_steps: u32 = 0,

    // Audio-thread-only state:
    voices: [max_pads]Voice,
    /// Monotonic counter of steps that have fired. Resynced on seek.
    next_step_k: u64,

    /// Current step index, published by the audio thread for UI display.
    current_step: std.atomic.Value(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        transport: *const Transport,
    ) !DrumMachine {
        var self: DrumMachine = .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .transport = transport,
            .pads = [_]?Pad{null} ** max_pads,
            .pattern = undefined,
            .vel_lo = undefined,
            .vel_hi = undefined,
            .step_count = 16, // default 1 bar; user can extend to max_steps with >

            .voices = [_]Voice{.{}} ** max_pads,
            .next_step_k = 0,
            .current_step = .init(0),
        };
        for (&self.pattern) |*p| p.* = .init(0);
        for (&self.vel_lo)  |*p| p.* = .init(0);
        for (&self.vel_hi)  |*p| p.* = .init(0);

        // Load the shipped kit: WAVs rendered from dsp/drum_kit.zig by the
        // `genkit` build tool and embedded in the binary. Per-pad default gains
        // give a balanced out-of-the-box mix (the user can retune each in the
        // sampler editor).
        for (default_kit, 0..) |slot, i| {
            try self.loadPadWav(@intCast(i), slot.data, slot.name);
            if (self.pads[i]) |*p| p.gain = slot.gain;
        }

        // Default groove: 4-on-the-floor house pattern
        self.pattern[0].store(0x1111, .monotonic); // kick: every beat
        self.pattern[1].store((1 << 4) | (1 << 12), .monotonic); // snare: beats 2, 4
        self.pattern[2].store(0x5555, .monotonic); // hihat: every 8th note

        return self;
    }

    pub fn deinit(self: *DrumMachine) void {
        for (&self.pads) |*opt| {
            if (opt.*) |pad| self.allocator.free(pad.samples);
        }
    }

    pub fn device(self: *DrumMachine) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .event = eventOpaque,
        .reset = resetOpaque,
    };

    // -----------------------------------------------------------------------
    // Pattern editing (UI thread)

    /// Bitmask covering steps 0..n — the valid bits for an n-step pattern.
    pub fn stepMask(n: u8) u32 {
        if (n >= 32) return ~@as(u32, 0);
        return (@as(u32, 1) << @intCast(n)) - 1;
    }

    pub fn setStepCount(self: *DrumMachine, n: u8) void {
        self.step_count = std.math.clamp(n, 1, max_steps);
        // Discard bits beyond the new count — otherwise they'd silently
        // survive a shrink, reappear on grow, and be saved to disk.
        const mask = stepMask(self.step_count);
        for (&self.pattern) |*p| _ = p.fetchAnd(mask, .acq_rel);
        for (&self.vel_lo)  |*p| _ = p.fetchAnd(mask, .acq_rel);
        for (&self.vel_hi)  |*p| _ = p.fetchAnd(mask, .acq_rel);
    }

    /// Nudge swing by `delta` percent, clamped to [swing_min, swing_max].
    /// Control thread; the audio thread picks it up next block.
    pub fn adjustSwing(self: *DrumMachine, delta: f32) void {
        const s = std.math.clamp(self.swing.load(.monotonic) + delta, swing_min, swing_max);
        self.swing.store(s, .monotonic);
    }

    // -----------------------------------------------------------------------
    // Pattern variants (control thread)

    /// Sync the live pattern back into its bank slot.
    fn storeActiveVariant(self: *DrumMachine) void {
        const slot = &self.variants[self.variant];
        for (&slot.pattern, &self.pattern) |*bank, *live| bank.* = live.load(.acquire);
        for (&slot.vel_lo,  &self.vel_lo)  |*bank, *live| bank.* = live.load(.acquire);
        for (&slot.vel_hi,  &self.vel_hi)  |*bank, *live| bank.* = live.load(.acquire);
        slot.step_count = self.step_count;
    }

    /// Replace the live pattern with `slot`'s data (control thread). Used to
    /// activate a bank variant and to paste a yanked pattern; setStepCount
    /// masks off any stray bits above the step count.
    pub fn applyVariant(self: *DrumMachine, slot: Variant) void {
        for (&self.pattern, slot.pattern) |*live, bits| live.store(bits, .release);
        for (&self.vel_lo,  slot.vel_lo)  |*live, bits| live.store(bits, .release);
        for (&self.vel_hi,  slot.vel_hi)  |*live, bits| live.store(bits, .release);
        self.setStepCount(slot.step_count);
    }

    /// Load bank slot `v` into the live pattern.
    fn loadVariantLive(self: *DrumMachine, v: u8) void {
        self.applyVariant(self.variants[v]);
    }

    /// Switch the active variant to `v`, saving the live pattern first.
    pub fn selectVariant(self: *DrumMachine, v: u8) void {
        if (v >= self.variant_count or v == self.variant) return;
        self.storeActiveVariant();
        self.variant = v;
        self.loadVariantLive(v);
    }

    /// Step the active variant by `delta`, wrapping within the bank.
    pub fn cycleVariant(self: *DrumMachine, delta: i32) void {
        const n: i32 = self.variant_count;
        if (n <= 1) return;
        self.selectVariant(@intCast(@mod(@as(i32, self.variant) + delta, n)));
    }

    /// Duplicate the active variant into a new slot and switch to it — the
    /// live pattern already matches the copy. False when the bank is full.
    pub fn addVariant(self: *DrumMachine) bool {
        if (self.variant_count >= max_variants) return false;
        self.storeActiveVariant();
        self.variants[self.variant_count] = self.variants[self.variant];
        self.variant = self.variant_count;
        self.variant_count += 1;
        return true;
    }

    /// Remove the active variant, shifting later slots down. The slot that
    /// takes its index (or the new last) becomes active. False when it's the
    /// only one left.
    pub fn removeVariant(self: *DrumMachine) bool {
        if (self.variant_count <= 1) return false;
        var i = self.variant;
        while (i + 1 < self.variant_count) : (i += 1) self.variants[i] = self.variants[i + 1];
        self.variant_count -= 1;
        if (self.variant >= self.variant_count) self.variant = self.variant_count - 1;
        self.loadVariantLive(self.variant);
        return true;
    }

    /// Variant `v`'s pattern data. The active one is read from the live
    /// atomics (its bank slot is stale until the next switch).
    pub fn variantData(self: *const DrumMachine, v: u8) Variant {
        if (v == self.variant) {
            var out: Variant = .{ .step_count = self.step_count };
            for (&out.pattern, &self.pattern) |*dst, *live| dst.* = live.load(.acquire);
            for (&out.vel_lo,  &self.vel_lo)  |*dst, *live| dst.* = live.load(.acquire);
            for (&out.vel_hi,  &self.vel_hi)  |*dst, *live| dst.* = live.load(.acquire);
            return out;
        }
        return self.variants[@min(v, max_variants - 1)];
    }

    /// Display letter for variant `v`: A, B, C, …
    pub fn variantLetter(v: u8) u8 {
        return 'A' + @as(u8, @min(v, max_variants - 1));
    }

    /// Replace the song-mode clip timeline (control thread). Taken under
    /// `pad_lock` so the audio thread never reads a half-written array.
    pub fn setSongClips(self: *DrumMachine, clips: []const SongClip, length_steps: u32) void {
        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        const count = @min(clips.len, @as(usize, max_song_clips));
        for (clips[0..count], self.song_clips[0..count]) |src, *dst| dst.* = src;
        self.song_clip_count = @intCast(count);
        self.song_length_steps = length_steps;
    }

    pub fn toggleStep(self: *DrumMachine, pad: u8, step: u8) void {
        if (pad >= max_pads or step >= max_steps) return;
        const bit = @as(u32, 1) << @intCast(step);
        _ = self.pattern[pad].fetchXor(bit, .acq_rel);
        // A toggled step always (re)starts at full velocity.
        _ = self.vel_lo[pad].fetchAnd(~bit, .acq_rel);
        _ = self.vel_hi[pad].fetchAnd(~bit, .acq_rel);
    }

    pub fn stepActive(self: *const DrumMachine, pad: u8, step: u8) bool {
        if (pad >= max_pads or step >= max_steps) return false;
        return (self.pattern[pad].load(.acquire) >> @intCast(step)) & 1 == 1;
    }

    /// 2-bit velocity level of one step: 0 = full, 3 = quietest (see velGain).
    pub fn stepVel(self: *const DrumMachine, pad: u8, step: u8) u2 {
        if (pad >= max_pads or step >= max_steps) return 0;
        const lo: u2 = @intCast((self.vel_lo[pad].load(.acquire) >> @intCast(step)) & 1);
        const hi: u2 = @intCast((self.vel_hi[pad].load(.acquire) >> @intCast(step)) & 1);
        return (hi << 1) | lo;
    }

    pub fn setStepVel(self: *DrumMachine, pad: u8, step: u8, level: u2) void {
        if (pad >= max_pads or step >= max_steps) return;
        const bit = @as(u32, 1) << @intCast(step);
        if (level & 1 != 0) {
            _ = self.vel_lo[pad].fetchOr(bit, .acq_rel);
        } else {
            _ = self.vel_lo[pad].fetchAnd(~bit, .acq_rel);
        }
        if (level & 2 != 0) {
            _ = self.vel_hi[pad].fetchOr(bit, .acq_rel);
        } else {
            _ = self.vel_hi[pad].fetchAnd(~bit, .acq_rel);
        }
    }

    /// Step one step's velocity down a level, wrapping 100 → 75 → 50 → 25 → 100.
    pub fn cycleStepVel(self: *DrumMachine, pad: u8, step: u8) void {
        self.setStepVel(pad, step, self.stepVel(pad, step) +% 1);
    }

    /// Wipe one pad's row: no steps, all velocities back to full.
    pub fn clearPad(self: *DrumMachine, pad: u8) void {
        if (pad >= max_pads) return;
        self.pattern[pad].store(0, .release);
        self.vel_lo[pad].store(0, .release);
        self.vel_hi[pad].store(0, .release);
    }

    /// Fill one pad's row with full-velocity steps across the active length.
    pub fn fillPad(self: *DrumMachine, pad: u8) void {
        if (pad >= max_pads) return;
        self.pattern[pad].store(stepMask(self.step_count), .release);
        self.vel_lo[pad].store(0, .release);
        self.vel_hi[pad].store(0, .release);
    }

    pub fn padName(self: *const DrumMachine, pad: u8) []const u8 {
        if (self.pads[pad]) |*p| {
            // Trim trailing spaces
            var end: usize = p.name.len;
            while (end > 0 and p.name[end - 1] == ' ') end -= 1;
            return p.name[0..end];
        }
        return "----";
    }

    /// Current sequencer step — read by the UI to highlight the playhead.
    pub fn currentStep(self: *const DrumMachine) u8 {
        return self.current_step.load(.monotonic);
    }

    /// Encode a (pad, param) pair into the `set_param` id space.
    pub fn paramId(pad: u8, param: u8) u8 {
        return (pad << 4) | (param & 0x0F);
    }

    /// Nudge a per-pad sampler param by `steps` (h/l = ±1, H/L = ±10). Runs on
    /// the audio thread via the `set_param` event so it never races the block
    /// reader, mirroring PolySynth.adjustParam. The pad index is the high nibble
    /// of `id`; the param index is the low nibble (see `paramId`).
    pub fn adjustParam(self: *DrumMachine, id: u8, steps: i32) void {
        const pad_idx = id >> 4;
        const param = id & 0x0F;
        if (pad_idx >= max_pads) return;
        const pad = if (self.pads[pad_idx]) |*p| p else return;
        const s: f32 = @floatFromInt(steps);
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

    // -----------------------------------------------------------------------
    // Sample loading (call from control side only, not while audio thread runs)

    /// Replace pad `idx` with external mono f32 samples (must be allocated
    /// with `self.allocator`; DrumMachine takes ownership).
    pub fn setPadSamples(
        self: *DrumMachine,
        idx: u8,
        samples: []f32,
        name: []const u8,
    ) void {
        if (idx >= max_pads) return;
        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();
        if (self.pads[idx]) |old| self.allocator.free(old.samples);
        var n: [8]u8 = [_]u8{' '} ** 8;
        const len = @min(name.len, 8);
        @memcpy(n[0..len], name[0..len]);
        self.pads[idx] = .{ .samples = samples, .gain = 1.0, .name = n };
    }

    /// Parse raw WAV bytes into pad `idx`. Resamples to engine rate if needed.
    pub fn loadPadWav(self: *DrumMachine, idx: u8, wav_data: []const u8, name: []const u8) !void {
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

        self.setPadSamples(idx, samples, name);
    }

    // -----------------------------------------------------------------------
    // Audio thread processing

    fn framesPerStep(self: *const DrumMachine) f64 {
        // One step = sixteenth note (1/4 beat)
        const bpm = @max(self.transport.tempo_bpm, 1.0);
        const fpb = @as(f64, @floatFromInt(self.sample_rate)) * 60.0 / bpm;
        return @max(1.0, fpb / 4.0);
    }

    pub fn processBlock(self: *DrumMachine, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);

        while (!self.pad_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.pad_lock.unlock();

        // Continuing voices begin at the block's first frame
        for (&self.voices) |*v| {
            if (v.active) v.block_start = 0;
        }

        if (self.transport.playing) {
            const pos_f = @as(f64, @floatFromInt(self.transport.position_frames));
            const fps = self.framesPerStep();
            // Swing: off-beat 16ths (odd step_k) fire late by up to half a
            // step (75% = hardest shuffle). Even steps stay on the grid, so
            // the boundary positions remain strictly increasing.
            const swing_pct = self.swing.load(.monotonic);
            const swing_delay: f64 = fps * @as(f64, swing_pct - 50.0) / 50.0;
            var step_k = self.next_step_k;

            // Resync on discontinuity (seek, loop, first play after stop)
            const expected = @as(f64, @floatFromInt(step_k)) * fps;
            if (@abs(expected - pos_f) > fps * 2.0) {
                step_k = @intFromFloat(@ceil(pos_f / fps));
            }

            // Fire every step whose boundary falls inside [pos_f, pos_f+frames)
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

                if (self.song_mode) {
                    self.fireSongStep(step_k, fire_frame);
                } else {
                    const step_idx: u8 = @intCast(step_k % self.step_count);
                    for (0..max_pads) |p| {
                        if (self.pads[p] == null) continue;
                        if ((self.pattern[p].load(.acquire) >> @intCast(step_idx)) & 1 == 1) {
                            self.voices[p] = .{
                                .active = true,
                                .played = 0,
                                .block_start = fire_frame,
                                .vel = velGain(self.stepVel(@intCast(p), step_idx)),
                            };
                        }
                    }
                    self.current_step.store(step_idx, .monotonic);
                }
                step_k += 1;
            }

            self.next_step_k = step_k;
        }

        // Render all active voices
        const sr: f64 = @floatFromInt(self.sample_rate);
        for (&self.voices, 0..) |*voice, p| {
            if (!voice.active) continue;
            const pad = self.pads[p] orelse continue;
            pad_mod.renderVoice(voice, &pad, buf, channels, frames, sr);
        }
    }

    /// Fire pads for absolute step `step_k` from the song timeline. The whole
    /// arrangement loops at `song_length_steps`; the clip covering the wrapped
    /// step drives the pads, repeating its own pattern to fill its span.
    fn fireSongStep(self: *DrumMachine, step_k: u64, fire_frame: u32) void {
        if (self.song_length_steps == 0) return;
        const lk: u32 = @intCast(step_k % self.song_length_steps);
        for (self.song_clips[0..self.song_clip_count]) |*clip| {
            if (lk < clip.start_step or lk >= clip.start_step + clip.span_steps) continue;
            if (clip.step_count == 0) return;
            const local: u32 = (lk - clip.start_step) % clip.step_count;
            for (0..max_pads) |p| {
                if (self.pads[p] == null) continue;
                if ((clip.pattern[p] >> @intCast(local)) & 1 == 1) {
                    const lo: u2 = @intCast((clip.vel_lo[p] >> @intCast(local)) & 1);
                    const hi: u2 = @intCast((clip.vel_hi[p] >> @intCast(local)) & 1);
                    self.voices[p] = .{
                        .active = true, .played = 0, .block_start = fire_frame,
                        .vel = velGain((hi << 1) | lo),
                    };
                }
            }
            self.current_step.store(@intCast(local), .monotonic);
            return; // clips never overlap
        }
        // No clip under the playhead: keep the UI step indicator moving
        // through the gap instead of freezing on the last clip's step.
        self.current_step.store(@intCast(lk % self.step_count), .monotonic);
    }

    fn triggerPad(self: *DrumMachine, pad_idx: u8, vel: f32) void {
        if (pad_idx >= max_pads or self.pads[pad_idx] == null) return;
        self.voices[pad_idx] = .{ .active = true, .played = 0, .block_start = 0, .vel = vel };
    }

    pub fn resetAll(self: *DrumMachine) void {
        for (&self.voices) |*v| v.* = .{};
        self.next_step_k = 0;
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *DrumMachine = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn eventOpaque(ptr: *anyopaque, ev: dsp.Event) void {
        const self: *DrumMachine = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .note_on  => |e| self.triggerPad(e.note % max_pads, e.velocity),
            .set_param => |e| self.adjustParam(e.id, e.steps),
            .note_off, .cc, .pitch_bend => {},
            .all_off  => self.resetAll(),
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *DrumMachine = @ptrCast(@alignCast(ptr));
        self.resetAll();
    }
};

// -----------------------------------------------------------------------
// Tests

test "embedded kit loads non-silent pads with default gains" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // All 8 kit pads should decode and have samples + their default gain.
    for (0..DrumMachine.max_pads) |p| {
        try std.testing.expect(dm.pads[p] != null);
        try std.testing.expect(dm.pads[p].?.samples.len > 0);
        try std.testing.expect(dm.pads[p].?.gain > 0.0);
    }
    // Kick should have a non-zero peak.
    var peak: f32 = 0;
    for (dm.pads[0].?.samples) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
    // Hihat ships quieter than the kick by default.
    try std.testing.expect(dm.pads[2].?.gain < dm.pads[0].?.gain);
}

test "step sequencer fires pads at correct boundaries" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // Clear all defaults; enable only pad 0 on step 0
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.pattern[0].store(1, .monotonic); // step 0 active

    // At 120bpm, 16th note = 6000 frames. Start playing at frame 0.
    transport.play();
    var buf: [512]Sample = undefined; // 256 frames * 2 channels
    @memset(&buf, 0.0);
    dm.processBlock(&buf);

    // Step 0 fires at frame 0 — pad 0 should be audible
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
    transport.advance(256);

    // Advance far past step 0 boundary (6000 frames); no second fire yet
    while (transport.position_frames < 5900) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        transport.advance(256);
    }

    // Reset voice to isolate the next trigger
    dm.resetAll();
    // Advance through the step-1 boundary (which has no active pad)
    while (transport.position_frames < 6256) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        transport.advance(256);
    }
    // After exactly one bar (16 steps × 6000 = 96000 frames) step 0 fires again
    while (transport.position_frames < 96_000) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        transport.advance(256);
    }
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    peak = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "song mode fires the clip covering the playhead" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // Clear the default groove; song mode reads only song_clips.
    for (&dm.pattern) |*p| p.store(0, .monotonic);

    // Two bars long. A single clip in bar 1 (steps 16..31) fires pad 0 on its
    // first step; bar 0 is empty.
    var pat = [_]u32{0} ** DrumMachine.max_pads;
    pat[0] = 1; // local step 0
    const clips = [_]DrumMachine.SongClip{.{
        .start_step = 16, .span_steps = 16, .step_count = 16, .pattern = pat,
    }};
    dm.setSongClips(&clips, 32);
    dm.song_mode = true;
    transport.play();

    var buf: [512]Sample = undefined; // 256 frames

    // At frame 0 (bar 0) nothing should sound.
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak < 0.01);

    // Jump to bar 1's downbeat: step 16 = 16 * 6000 frames = 96_000.
    dm.resetAll();
    transport.seekFrames(96_000);
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    peak = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "note_on triggers pad directly" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.resetAll();
    const dev = dm.device();
    dev.sendEvent(.{ .note_on = .{ .note = 0, .velocity = 1.0 } });

    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0);
    dm.processBlock(&buf);

    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "step velocity: cycles levels, toggling resets, shrink masks" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.pattern[0].store(0, .monotonic);
    dm.toggleStep(0, 5);
    try std.testing.expectEqual(@as(u2, 0), dm.stepVel(0, 5)); // new steps are full

    // v walks 100 → 75 → 50 → 25 and wraps back to 100.
    dm.cycleStepVel(0, 5);
    try std.testing.expectEqual(@as(u2, 1), dm.stepVel(0, 5));
    dm.cycleStepVel(0, 5);
    dm.cycleStepVel(0, 5);
    try std.testing.expectEqual(@as(u2, 3), dm.stepVel(0, 5));
    dm.cycleStepVel(0, 5);
    try std.testing.expectEqual(@as(u2, 0), dm.stepVel(0, 5));

    // Level → gain mapping.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0),  DrumMachine.velGain(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), DrumMachine.velGain(3), 1e-6);

    // Retoggling a step brings it back at full velocity.
    dm.setStepVel(0, 5, 3);
    dm.toggleStep(0, 5); // off
    dm.toggleStep(0, 5); // on again
    try std.testing.expectEqual(@as(u2, 0), dm.stepVel(0, 5));

    // Velocity bits past a shrink don't survive a re-grow.
    dm.setStepCount(32);
    dm.toggleStep(0, 20);
    dm.setStepVel(0, 20, 2);
    dm.setStepCount(16);
    dm.setStepCount(32);
    try std.testing.expectEqual(@as(u2, 0), dm.stepVel(0, 20));
}

test "voice velocity scales the rendered level" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    var buf: [512]Sample = undefined;

    dm.voices[0] = .{ .active = true, .played = 0, .block_start = 0, .vel = 1.0 };
    @memset(&buf, 0.0);
    pad_mod.renderVoice(&dm.voices[0], &dm.pads[0].?, &buf, 2, 256, 48_000.0);
    var peak_full: f32 = 0;
    for (buf) |s| peak_full = @max(peak_full, @abs(s));

    dm.voices[0] = .{ .active = true, .played = 0, .block_start = 0, .vel = 0.25 };
    @memset(&buf, 0.0);
    pad_mod.renderVoice(&dm.voices[0], &dm.pads[0].?, &buf, 2, 256, 48_000.0);
    var peak_quiet: f32 = 0;
    for (buf) |s| peak_quiet = @max(peak_quiet, @abs(s));

    try std.testing.expect(peak_full > 0.01);
    try std.testing.expectApproxEqAbs(peak_full * 0.25, peak_quiet, 1e-4);
}

test "swing delays the off-beat step" {
    var transport: Transport = .{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // Only pad 0 on step 1 (an off-beat 16th). At 120bpm a step is 6000
    // frames; swing 75% pushes step 1's hit from 6000 to 9000.
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.pattern[0].store(1 << 1, .monotonic);
    dm.adjustSwing(100.0); // clamps at swing_max = 75
    try std.testing.expectApproxEqAbs(DrumMachine.swing_max, dm.swing.load(.monotonic), 1e-6);

    transport.play();
    var buf: [512]Sample = undefined; // 256 frames

    // Silent through the straight boundary (6000) up to just before 9000.
    while (transport.position_frames < 8960) {
        @memset(&buf, 0.0);
        dm.processBlock(&buf);
        var peak: f32 = 0;
        for (buf) |s| peak = @max(peak, @abs(s));
        try std.testing.expect(peak < 0.01);
        transport.advance(256);
    }
    // The block covering frame 9000 fires the swung step.
    @memset(&buf, 0.0);
    dm.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
}

test "variants keep per-step velocity" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.toggleStep(0, 0);
    dm.setStepVel(0, 0, 2); // variant A: 50%

    _ = dm.addVariant(); // B copies A, then diverges
    try std.testing.expectEqual(@as(u2, 2), dm.stepVel(0, 0));
    dm.setStepVel(0, 0, 3);

    dm.selectVariant(0);
    try std.testing.expectEqual(@as(u2, 2), dm.stepVel(0, 0));
    dm.selectVariant(1);
    try std.testing.expectEqual(@as(u2, 3), dm.stepVel(0, 0));
}

test "toggleStep flips pattern bit" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.pattern[0].store(0, .monotonic);
    dm.toggleStep(0, 3);
    try std.testing.expect(dm.stepActive(0, 3));
    dm.toggleStep(0, 3);
    try std.testing.expect(!dm.stepActive(0, 3));
}

test "variants: add copies, edits stay isolated, select round-trips" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.toggleStep(0, 0); // variant A: pad 0 step 0

    // New variant starts as a copy of A, then diverges.
    try std.testing.expect(dm.addVariant());
    try std.testing.expectEqual(@as(u8, 1), dm.variant);
    try std.testing.expect(dm.stepActive(0, 0));
    dm.toggleStep(0, 0);
    dm.toggleStep(1, 4); // variant B: pad 1 step 4 only

    // Back to A: the original pattern, untouched by B's edits.
    dm.selectVariant(0);
    try std.testing.expect(dm.stepActive(0, 0));
    try std.testing.expect(!dm.stepActive(1, 4));

    // Forward to B again: its own edits survived the switch.
    dm.selectVariant(1);
    try std.testing.expect(!dm.stepActive(0, 0));
    try std.testing.expect(dm.stepActive(1, 4));
}

test "variants: step count is per-variant" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    try std.testing.expect(dm.addVariant());
    dm.setStepCount(32);
    dm.selectVariant(0);
    try std.testing.expectEqual(@as(u8, 16), dm.step_count);
    dm.selectVariant(1);
    try std.testing.expectEqual(@as(u8, 32), dm.step_count);
}

test "variants: cycle wraps and remove shifts the bank down" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    try std.testing.expect(!dm.removeVariant()); // can't drop the only one
    dm.cycleVariant(1); // single variant: no-op
    try std.testing.expectEqual(@as(u8, 0), dm.variant);

    _ = dm.addVariant(); // B
    _ = dm.addVariant(); // C — mark it
    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.toggleStep(7, 7);

    dm.cycleVariant(1); // wraps C → A
    try std.testing.expectEqual(@as(u8, 0), dm.variant);
    dm.cycleVariant(-1); // wraps A → C
    try std.testing.expectEqual(@as(u8, 2), dm.variant);

    // Remove B: C shifts into slot 1 and stays findable.
    dm.selectVariant(1);
    try std.testing.expect(dm.removeVariant());
    try std.testing.expectEqual(@as(u8, 2), dm.variant_count);
    dm.selectVariant(1);
    try std.testing.expect(dm.stepActive(7, 7));
}

test "variants: bank fills at max_variants" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    var added: u8 = 0;
    while (dm.addVariant()) added += 1;
    try std.testing.expectEqual(DrumMachine.max_variants - 1, added);
    try std.testing.expectEqual(DrumMachine.max_variants, dm.variant_count);
}

test "variantData reads the active variant from the live atomics" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    for (&dm.pattern) |*p| p.store(0, .monotonic);
    dm.toggleStep(3, 9); // edit after the bank slot was last synced
    const active = dm.variantData(dm.variant);
    try std.testing.expectEqual(@as(u32, 1 << 9), active.pattern[3]);
}

test "setStepCount discards bits beyond the new count" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    dm.setStepCount(32);
    dm.pattern[0].store(1 << 20, .monotonic);
    dm.setStepCount(16); // shrink: bit 20 must not survive
    dm.setStepCount(32); // grow back
    try std.testing.expect(!dm.stepActive(0, 20));
}

test "adjustParam decodes pad/param and clamps" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // pad 2, param 2 = pitch; +3 semitones
    dm.adjustParam(DrumMachine.paramId(2, 2), 3);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), dm.pads[2].?.pitch_semitones, 1e-4);

    // start never crosses end
    dm.adjustParam(DrumMachine.paramId(0, 0), 1000); // start up hard
    try std.testing.expect(dm.pads[0].?.start_norm < dm.pads[0].?.end_norm);

    // reverse toggles on any nonzero step
    const before = dm.pads[1].?.reverse;
    dm.adjustParam(DrumMachine.paramId(1, 9), 1);
    try std.testing.expectEqual(!before, dm.pads[1].?.reverse);
}

test "region trim shortens the voice" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // Trim pad 0 to the first 10% of the clip, then trigger it.
    dm.pads[0].?.end_norm = 0.1;
    const region = dm.pads[0].?.samples.len / 10;

    dm.resetAll();
    dm.voices[0] = .{ .active = true, .played = 0, .block_start = 0 };
    var buf: [4096]Sample = undefined;
    // Render enough frames to exceed the trimmed region; the voice must end.
    var rendered: usize = 0;
    while (dm.voices[0].active and rendered < dm.pads[0].?.samples.len) : (rendered += buf.len / 2) {
        @memset(&buf, 0.0);
        pad_mod.renderVoice(&dm.voices[0], &dm.pads[0].?, &buf, 2, buf.len / 2, 48_000.0);
    }
    try std.testing.expect(!dm.voices[0].active);
    // It stopped near the region length, well before the full clip.
    try std.testing.expect(rendered < dm.pads[0].?.samples.len);
    try std.testing.expect(region < dm.pads[0].?.samples.len);
}

test "pitch up plays the region faster" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    var buf: [256]Sample = undefined;

    // Baseline: count active frames at unity pitch.
    dm.pads[0].?.pitch_semitones = 0.0;
    dm.voices[0] = .{ .active = true, .played = 0, .block_start = 0 };
    var unity_frames: usize = 0;
    while (dm.voices[0].active and unity_frames < 1_000_000) : (unity_frames += 128) {
        @memset(&buf, 0.0);
        pad_mod.renderVoice(&dm.voices[0], &dm.pads[0].?, &buf, 2, 128, 48_000.0);
    }

    // Pitched up an octave should consume the region in roughly half the frames.
    dm.pads[0].?.pitch_semitones = 12.0;
    dm.voices[0] = .{ .active = true, .played = 0, .block_start = 0 };
    var fast_frames: usize = 0;
    while (dm.voices[0].active and fast_frames < 1_000_000) : (fast_frames += 128) {
        @memset(&buf, 0.0);
        pad_mod.renderVoice(&dm.voices[0], &dm.pads[0].?, &buf, 2, 128, 48_000.0);
    }
    try std.testing.expect(fast_frames < unity_frames);
}
