//! Step-sequenced multisampler — the drum machine instrument.
//!
//! Eight pads hold mono f32 clips (synthesised by default; replaceable
//! with WAV data).  Each pad is a small Sampler with its own settings:
//! sample start/end trim, pitch (playback transpose), an amplitude ADSR,
//! gain, pan, and a reverse toggle.  A 16-step bitmask per pad stores the
//! pattern; each bit is a u32 atomic so the UI thread can flip bits safely
//! while the audio thread reads them.  The sequencer fires on step
//! boundaries derived from the transport, using a monotonic step counter
//! to avoid the double-fire and float-truncation bugs that arise from
//! recomputing the boundary position every block.
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

const Sample = types.Sample;

pub const Pad = struct {
    samples: []f32,
    name: [8]u8 = [_]u8{' '} ** 8,

    // ── Sampler params (audio-thread reads; nudged via adjustParam) ──────────
    /// Output level multiplier (0..2). 1.0 = unity.
    gain: f32 = 1.0,
    /// Stereo balance: -1 hard left, 0 center, +1 hard right.
    pan: f32 = 0.0,
    /// Playback transpose in semitones (-24..+24). rate = 2^(semi/12).
    pitch_semitones: f32 = 0.0,
    /// Region start as a fraction of the clip (0..1).
    start_norm: f32 = 0.0,
    /// Region end as a fraction of the clip (0..1). Must exceed start_norm.
    end_norm: f32 = 1.0,
    /// Play the region back to front when true.
    reverse: bool = false,
    // Amplitude ADSR. For one-shots (no note-off) attack/decay/sustain shape
    // the body and `release_s` fades the tail at the region end (see Voice
    // rendering). Defaults reproduce an unshaped, instant-on one-shot.
    attack_s: f32 = 0.001,
    decay_s: f32 = 0.0,
    sustain: f32 = 1.0,
    release_s: f32 = 0.005,
};

pub const Voice = struct {
    active: bool = false,
    /// Source frames consumed since the trigger, as a fractional count that
    /// advances by the pitch rate each output frame. Read position within the
    /// clip is derived from this plus the pad's region start (or end, reversed).
    played: f64 = 0,
    /// Frame offset within the current block where this voice starts.
    /// 0 for voices continuing from a previous block.
    block_start: u32 = 0,
};

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
    /// Max clips one lane can hold for song-mode playback (see `song_clips`).
    pub const max_song_clips: u16 = 256;

    /// A drum clip flattened onto the arrangement's step timeline. `pattern` is
    /// a plain snapshot of the source bitmask (no atomics — the audio thread
    /// reads it under `pad_lock`). The clip's own `step_count`-long pattern
    /// repeats to fill `span_steps` (its whole-bar length on the timeline).
    pub const SongClip = struct {
        start_step: u32,
        span_steps: u32,
        step_count: u8,
        pattern: [max_pads]u32,
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
    pattern: [max_pads]std.atomic.Value(u32),
    step_count: u8,

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
            .step_count = 16, // default 1 bar; user can extend to max_steps with >

            .voices = [_]Voice{.{}} ** max_pads,
            .next_step_k = 0,
            .current_step = .init(0),
        };
        for (&self.pattern) |*p| p.* = .init(0);

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

    pub fn setStepCount(self: *DrumMachine, n: u8) void {
        self.step_count = std.math.clamp(n, 1, max_steps);
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
        _ = self.pattern[pad].fetchXor(@as(u32, 1) << @intCast(step), .acq_rel);
    }

    pub fn stepActive(self: *const DrumMachine, pad: u8, step: u8) bool {
        if (pad >= max_pads or step >= max_steps) return false;
        return (self.pattern[pad].load(.acquire) >> @intCast(step)) & 1 == 1;
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
            const resampled = try resampleLinear(
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
            var step_k = self.next_step_k;

            // Resync on discontinuity (seek, loop, first play after stop)
            const expected = @as(f64, @floatFromInt(step_k)) * fps;
            if (@abs(expected - pos_f) > fps * 2.0) {
                step_k = @intFromFloat(@ceil(pos_f / fps));
            }

            // Fire every step whose boundary falls inside [pos_f, pos_f+frames)
            while (true) {
                const fire_pos = @as(f64, @floatFromInt(step_k)) * fps;
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
            renderVoice(voice, &pad, buf, channels, frames, sr);
        }
    }

    /// Play one pad voice into `buf`: fractional pitched read with linear
    /// interpolation, region trim, optional reverse, amp ADSR + release fade,
    /// and a linear pan law (center = unity in both channels).
    pub fn renderVoice(
        voice: *Voice,
        pad: *const Pad,
        buf: []Sample,
        channels: usize,
        frames: u32,
        sr: f64,
    ) void {
        const len = pad.samples.len;
        if (len == 0) { voice.active = false; return; }
        const len_f: f64 = @floatFromInt(len);

        // Resolve the play region in source frames. Guard against an inverted
        // or empty selection.
        const lo = std.math.clamp(@as(f64, pad.start_norm), 0.0, 1.0) * len_f;
        const hi = std.math.clamp(@as(f64, pad.end_norm), 0.0, 1.0) * len_f;
        const region_len = hi - lo;
        if (region_len <= 1.0) { voice.active = false; return; }

        const rate: f64 = std.math.pow(f64, 2.0, @as(f64, pad.pitch_semitones) / 12.0);

        // Linear pan: center keeps unity in both channels (matches the prior
        // mono-to-both behaviour at pan = 0).
        const gl: f32 = pad.gain * @min(1.0, 1.0 - pad.pan);
        const gr: f32 = pad.gain * @min(1.0, 1.0 + pad.pan);

        const start = voice.block_start;
        var i: usize = start;
        while (i < frames) : (i += 1) {
            if (voice.played >= region_len) { voice.active = false; break; }

            // Read position within the clip for this voice's progress.
            const rp: f64 = if (pad.reverse) (hi - 1.0 - voice.played) else (lo + voice.played);
            const s = sampleAt(pad.samples, rp);

            // Envelope (output time): attack/decay/sustain on the body, plus a
            // release fade over the final `release_s` of the region.
            const t_out = voice.played / rate / sr;
            const left_out = (region_len - voice.played) / rate / sr;
            const env = adsrLevel(t_out, pad.attack_s, pad.decay_s, pad.sustain) *
                releaseFade(left_out, pad.release_s);

            const v = s * env;
            buf[i * channels] += v * gl;
            buf[i * channels + 1] += v * gr;

            voice.played += rate;
        }
        voice.block_start = 0;
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
                    self.voices[p] = .{ .active = true, .played = 0, .block_start = fire_frame };
                }
            }
            self.current_step.store(@intCast(local), .monotonic);
            return; // clips never overlap
        }
    }

    fn triggerPad(self: *DrumMachine, pad_idx: u8) void {
        if (pad_idx >= max_pads or self.pads[pad_idx] == null) return;
        self.voices[pad_idx] = .{ .active = true, .played = 0, .block_start = 0 };
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
            .note_on  => |e| self.triggerPad(e.note % max_pads),
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
// Voice-render math (audio thread, allocation-free)

/// Linearly interpolate `samples` at fractional position `p`. Returns 0 past
/// the ends so a voice fades out cleanly rather than reading garbage.
fn sampleAt(samples: []const f32, p: f64) f32 {
    if (p < 0.0) return 0.0;
    const idx: usize = @intFromFloat(p);
    if (idx + 1 < samples.len) {
        const frac: f32 = @floatCast(p - @as(f64, @floatFromInt(idx)));
        return samples[idx] * (1.0 - frac) + samples[idx + 1] * frac;
    }
    if (idx < samples.len) return samples[idx];
    return 0.0;
}

/// Attack → decay → sustain level at output time `t` seconds. With the default
/// params (attack≈0, decay 0, sustain 1) this is unity after the first sample.
fn adsrLevel(t: f64, attack_s: f32, decay_s: f32, sustain: f32) f32 {
    const a: f64 = @floatCast(attack_s);
    const d: f64 = @floatCast(decay_s);
    const sus: f64 = @floatCast(sustain);
    if (a > 0.0 and t < a) return @floatCast(t / a);
    const td = t - a;
    if (d > 0.0 and td < d) return @floatCast(1.0 - (1.0 - sus) * (td / d));
    return @floatCast(sus);
}

/// Release fade in the final `release_s` seconds of the region. `left` is the
/// remaining output time. Returns 1 outside the release window.
fn releaseFade(left: f64, release_s: f32) f32 {
    const r: f64 = @floatCast(release_s);
    if (r <= 0.0 or left >= r) return 1.0;
    return @floatCast(std.math.clamp(left / r, 0.0, 1.0));
}

// -----------------------------------------------------------------------
// Linear resampler (control-side, allocates)

pub fn resampleLinear(
    allocator: std.mem.Allocator,
    src: []const f32,
    src_rate: u32,
    dst_rate: u32,
) ![]f32 {
    if (src_rate == dst_rate) return allocator.dupe(f32, src);
    const ratio: f64 = @as(f64, @floatFromInt(src_rate)) / @as(f64, @floatFromInt(dst_rate));
    const dst_len: usize = @as(usize, @intFromFloat(
        @ceil(@as(f64, @floatFromInt(src.len)) / ratio),
    ));
    const out = try allocator.alloc(f32, dst_len);
    for (out, 0..) |*s, i| {
        const sp: f64 = @as(f64, @floatFromInt(i)) * ratio;
        const si: usize = @intFromFloat(sp);
        const frac: f32 = @floatCast(sp - @as(f64, @floatFromInt(si)));
        if (si + 1 < src.len) {
            s.* = src[si] * (1.0 - frac) + src[si + 1] * frac;
        } else if (si < src.len) {
            s.* = src[si];
        } else {
            s.* = 0.0;
        }
    }
    return out;
}

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
        DrumMachine.renderVoice(&dm.voices[0], &dm.pads[0].?, &buf, 2, buf.len / 2, 48_000.0);
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
        DrumMachine.renderVoice(&dm.voices[0], &dm.pads[0].?, &buf, 2, 128, 48_000.0);
    }

    // Pitched up an octave should consume the region in roughly half the frames.
    dm.pads[0].?.pitch_semitones = 12.0;
    dm.voices[0] = .{ .active = true, .played = 0, .block_start = 0 };
    var fast_frames: usize = 0;
    while (dm.voices[0].active and fast_frames < 1_000_000) : (fast_frames += 128) {
        @memset(&buf, 0.0);
        DrumMachine.renderVoice(&dm.voices[0], &dm.pads[0].?, &buf, 2, 128, 48_000.0);
    }
    try std.testing.expect(fast_frames < unity_frames);
}

test "resampleLinear preserves amplitude" {
    const src = [_]f32{ 0.0, 0.5, 1.0, 0.5, 0.0 };
    const out = try resampleLinear(std.testing.allocator, &src, 44_100, 48_000);
    defer std.testing.allocator.free(out);
    // Output should be longer and all values in [-1, 1]
    try std.testing.expect(out.len > src.len);
    for (out) |s| try std.testing.expect(@abs(s) <= 1.0 + 1e-6);
}
