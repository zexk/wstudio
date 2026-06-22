//! Step-sequenced multisampler — the drum machine instrument.
//!
//! Eight pads hold mono f32 clips (synthesised by default; replaceable
//! with WAV data).  A 16-step bitmask per pad stores the pattern; each
//! bit is a u32 atomic so the UI thread can flip bits safely while the
//! audio thread reads them.  The sequencer fires on step boundaries
//! derived from the transport, using a monotonic step counter to avoid
//! the double-fire and float-truncation bugs that arise from recomputing
//! the boundary position every block.

const std = @import("std");
const types = @import("../core/types.zig");
const wav = @import("../core/wav.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;

const Sample = types.Sample;

pub const Pad = struct {
    samples: []f32,
    gain: f32 = 1.0,
    name: [8]u8 = [_]u8{' '} ** 8,
};

const Voice = struct {
    active: bool = false,
    sample_pos: u32 = 0,
    /// Frame offset within the current block where this voice starts.
    /// 0 for voices continuing from a previous block.
    block_start: u32 = 0,
};

pub const DrumMachine = struct {
    pub const max_pads: u8 = 8;
    pub const max_steps: u8 = 16;

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
            .step_count = max_steps,
            .voices = [_]Voice{.{}} ** max_pads,
            .next_step_k = 0,
            .current_step = .init(0),
        };
        for (&self.pattern) |*p| p.* = .init(0);

        // Synthesise default pads
        try self.synthKick(0, "kick    ");
        try self.synthSnare(1, "snare   ");
        try self.synthHihat(2, "hihat   ", false);
        try self.synthHihat(3, "open    ", true);
        try self.synthClap(4, "clap    ");
        try self.synthTom(5, "tom-1   ", 150, 60, 0.45);
        try self.synthTom(6, "tom-2   ", 200, 80, 0.35);
        try self.synthRim(7, "rim     ");

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

                const step_idx: u8 = @intCast(step_k % self.step_count);
                for (0..max_pads) |p| {
                    if (self.pads[p] == null) continue;
                    if ((self.pattern[p].load(.acquire) >> @intCast(step_idx)) & 1 == 1) {
                        self.voices[p] = .{
                            .active = true,
                            .sample_pos = 0,
                            .block_start = fire_frame,
                        };
                    }
                }
                self.current_step.store(step_idx, .monotonic);
                step_k += 1;
            }

            self.next_step_k = step_k;
        }

        // Render all active voices
        for (&self.voices, 0..) |*voice, p| {
            if (!voice.active) continue;
            const pad = self.pads[p] orelse continue;
            const start = voice.block_start;
            const avail_frames = frames - start;
            const avail_samples = pad.samples.len - voice.sample_pos;
            const len = @min(avail_frames, avail_samples);
            for (0..len) |i| {
                const s = pad.samples[voice.sample_pos + i] * pad.gain;
                buf[(start + i) * channels] += s;
                buf[(start + i) * channels + 1] += s;
            }
            voice.sample_pos += @intCast(len);
            voice.block_start = 0;
            if (voice.sample_pos >= pad.samples.len) voice.active = false;
        }
    }

    fn triggerPad(self: *DrumMachine, pad_idx: u8) void {
        if (pad_idx >= max_pads or self.pads[pad_idx] == null) return;
        self.voices[pad_idx] = .{ .active = true, .sample_pos = 0, .block_start = 0 };
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
            .note_on => |e| self.triggerPad(e.note % max_pads),
            .note_off => {},
            .all_off => self.resetAll(),
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *DrumMachine = @ptrCast(@alignCast(ptr));
        self.resetAll();
    }

    // -----------------------------------------------------------------------
    // Synthesised default pads

    fn allocFrames(self: *DrumMachine, duration_s: f32) ![]f32 {
        const n: usize = @as(usize, @intFromFloat(
            duration_s * @as(f32, @floatFromInt(self.sample_rate)),
        )) + 1;
        return self.allocator.alloc(f32, n);
    }

    fn setPad(self: *DrumMachine, idx: u8, samples: []f32, name: *const [8]u8) void {
        if (self.pads[idx]) |old| self.allocator.free(old.samples);
        self.pads[idx] = .{ .samples = samples, .name = name.* };
    }

    fn synthKick(self: *DrumMachine, idx: u8, comptime name: *const [8]u8) !void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const buf = try self.allocFrames(0.4);
        var phase: f32 = 0;
        for (buf, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / sr;
            const freq = 170.0 * std.math.exp(-t * 22.0) + 40.0;
            const amp = std.math.exp(-t * 9.0) * 0.9;
            s.* = @sin(2.0 * std.math.pi * phase) * amp;
            phase += freq / sr;
            if (phase >= 1.0) phase -= 1.0;
        }
        self.setPad(idx, buf, name);
    }

    fn synthSnare(self: *DrumMachine, idx: u8, comptime name: *const [8]u8) !void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        var prng = std.Random.DefaultPrng.init(0x1337);
        const rand = prng.random();
        const buf = try self.allocFrames(0.28);
        var phase: f32 = 0;
        for (buf, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / sr;
            const noise = rand.float(f32) * 2.0 - 1.0;
            const tone = @sin(2.0 * std.math.pi * phase) * 0.25;
            s.* = (noise * 0.75 + tone) * std.math.exp(-t * 14.0) * 0.75;
            phase += 180.0 / sr;
            if (phase >= 1.0) phase -= 1.0;
        }
        self.setPad(idx, buf, name);
    }

    fn synthHihat(self: *DrumMachine, idx: u8, comptime name: *const [8]u8, open: bool) !void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        var prng = std.Random.DefaultPrng.init(0x2468);
        const rand = prng.random();
        const duration: f32 = if (open) 0.4 else 0.07;
        const decay: f32 = if (open) 10.0 else 70.0;
        const buf = try self.allocFrames(duration);
        for (buf, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / sr;
            s.* = (rand.float(f32) * 2.0 - 1.0) * std.math.exp(-t * decay) * 0.55;
        }
        self.setPad(idx, buf, name);
    }

    fn synthClap(self: *DrumMachine, idx: u8, comptime name: *const [8]u8) !void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        var prng = std.Random.DefaultPrng.init(0x9ABC);
        const rand = prng.random();
        const buf = try self.allocFrames(0.18);
        for (buf, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / sr;
            const noise = rand.float(f32) * 2.0 - 1.0;
            // Clap texture: fast transient + slower body
            const env = std.math.exp(-t * 80.0) + std.math.exp(-t * 18.0) * 0.35;
            s.* = noise * env * 0.6;
        }
        self.setPad(idx, buf, name);
    }

    fn synthTom(
        self: *DrumMachine,
        idx: u8,
        comptime name: *const [8]u8,
        f_start: f32,
        f_end: f32,
        duration: f32,
    ) !void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const buf = try self.allocFrames(duration);
        const log_ratio = @log(f_end / f_start);
        var phase: f32 = 0;
        for (buf, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / sr;
            const norm = t / duration;
            const freq = f_start * std.math.exp(log_ratio * norm);
            s.* = @sin(2.0 * std.math.pi * phase) * std.math.exp(-t * 7.0) * 0.8;
            phase += freq / sr;
            if (phase >= 1.0) phase -= 1.0;
        }
        self.setPad(idx, buf, name);
    }

    fn synthRim(self: *DrumMachine, idx: u8, comptime name: *const [8]u8) !void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        var prng = std.Random.DefaultPrng.init(0x7777);
        const rand = prng.random();
        const buf = try self.allocFrames(0.14);
        var phase: f32 = 0;
        for (buf, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / sr;
            const noise = rand.float(f32) * 2.0 - 1.0;
            const tone = @sin(2.0 * std.math.pi * phase) * 0.35;
            s.* = (noise * 0.65 + tone) * std.math.exp(-t * 28.0) * 0.65;
            phase += 400.0 / sr;
            if (phase >= 1.0) phase -= 1.0;
        }
        self.setPad(idx, buf, name);
    }
};

// -----------------------------------------------------------------------
// Linear resampler (control-side, allocates)

fn resampleLinear(
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

test "synthesised pads produce non-silent output" {
    var transport: Transport = .{ .sample_rate = 48_000 };
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, &transport);
    defer dm.deinit();

    // All 8 pads should exist and have samples
    for (0..DrumMachine.max_pads) |p| {
        try std.testing.expect(dm.pads[p] != null);
        try std.testing.expect(dm.pads[p].?.samples.len > 0);
    }
    // Kick should have a non-zero peak
    var peak: f32 = 0;
    for (dm.pads[0].?.samples) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);
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

test "resampleLinear preserves amplitude" {
    const src = [_]f32{ 0.0, 0.5, 1.0, 0.5, 0.0 };
    const out = try resampleLinear(std.testing.allocator, &src, 44_100, 48_000);
    defer std.testing.allocator.free(out);
    // Output should be longer and all values in [-1, 1]
    try std.testing.expect(out.len > src.len);
    for (out) |s| try std.testing.expect(@abs(s) <= 1.0 + 1e-6);
}
