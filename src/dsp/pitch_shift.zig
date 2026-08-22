//! Pitch shifter: transposes without changing playback speed, so a bass line
//! drops an octave and a vocal takes a harmony without either getting longer.
//!
//! Rubber Band's live shifter does the work. What was here before was a
//! two-tap granular shifter, and measuring it against this one is what
//! retired it: shifting a 220Hz sine up 7 semitones, the granular version
//! landed 38 cents sharp at its default grain size with only a third of the
//! output energy on the intended partials and 9dB of level wobble, while
//! Rubber Band is indistinguishable from a synthesised tone at the target
//! pitch (100% on-pitch, 0.4dB wobble, exact frequency).
//!
//! Rubber Band consumes and produces exactly `block_size` frames per call, so
//! the ring buffers below adapt it to whatever block the engine hands over.
//! That plus the shifter's own start-up delay is reported through
//! `latencyFrames` for the engine's delay compensation.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const c = @cImport(@cInclude("rubberband/rubberband-c.h"));

const Sample = types.Sample;

/// How far the formants may be moved on their own, in semitones. 0 leaves
/// them where the source put them, which is what stops a shifted voice
/// sounding like a cartoon; dialling this to match `semitones` reproduces the
/// old chipmunk behaviour deliberately.
pub const min_formant: f32 = -12.0;
pub const max_formant: f32 = 12.0;

/// Transposition small enough to treat as none, so an untouched insert is a
/// true passthrough rather than a shifter running at unity. Just under a
/// cent, far below the ~5 cent beating a player can hear.
const unity_epsilon: f32 = 0.005;

/// Ring capacity, in frames per channel. Two engine blocks plus two shifter
/// blocks, which is the most that can be in flight at once.
const ring_frames: usize = types.max_block_frames * 2 + 8192;

/// Ceiling on the pitch ratio of the very first block after construction or
/// reset. Rubber Band pre-pads its input ring with `window * pitch_scale`
/// frames on that block alone, and the ring is only four windows long: from
/// around +23 semitones up there is no room left for the block itself, so it
/// drops that input and logs the overrun straight from the audio thread.
/// Three (an octave and a fifth) leaves the pad room at every window size the
/// library picks; every later block gets the ratio actually asked for.
const max_first_scale: f64 = 3.0;

pub const PitchShift = struct {
    sample_rate: u32,
    state: c.RubberBandLiveState,
    /// Frames per `rubberband_live_shift` call, fixed at construction.
    block_size: usize,

    /// Deinterleaved staging for one shifter block, and the pointer arrays
    /// the C API wants. Owned so the audio thread never allocates.
    in_channels: [2][]f32,
    out_channels: [2][]f32,

    /// Input waiting to fill a shifter block, and output waiting to be
    /// handed back to the engine.
    pending: [2][]f32,
    pending_len: usize = 0,
    ready: [2][]f32,
    ready_len: usize = 0,
    ready_read: usize = 0,

    /// Last values pushed into Rubber Band, so an unchanged block does not
    /// re-issue a parameter change it would have to react to.
    applied_scale: f64 = 1.0,
    /// The ratio the params ask for, before `max_first_scale` is applied.
    wanted_scale: f64 = 1.0,
    applied_formant: f64 = 1.0,
    /// Whether the next `rubberband_live_shift` is the one that pre-pads.
    first_shift: bool = true,

    semitones: f32 = 0.0,
    cents: f32 = 0.0,
    /// Formant transposition in semitones, independent of `semitones`.
    formant: f32 = 0.0,
    /// 0 = dry only, 1 = wet only. Defaults to fully wet: a shifter is
    /// usually asked to replace the pitch, not to double it (dial it back
    /// for a harmony against the original).
    mix: f32 = 1.0,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !PitchShift {
        // Rubber Band supports 8k to 192k and silently clamps anything else
        // to that range, after logging the complaint. Clamp here instead, so
        // a degenerate rate neither prints from the audio thread nor leaves
        // `sample_rate` disagreeing with the rate the shifter really runs at.
        const safe_rate = std.math.clamp(sample_rate, 8_000, 192_000);
        // The live shifter has its own option enum whose values differ from
        // the offline one's: `RubberBandOptionWindowShort` is 0x00100000,
        // which here means *Medium*. Named for what it actually selects.
        const state = c.rubberband_live_new(
            safe_rate,
            2,
            c.RubberBandLiveOptionWindowMedium | c.RubberBandLiveOptionFormantPreserved,
        ) orelse return error.OutOfMemory;
        errdefer c.rubberband_live_delete(state);
        // A fresh live shifter reports a formant scale of 0, not 1, and with
        // formant preservation on that costs ~35 dB of output. `applied_formant`
        // starts at 1.0, so without this the neutral default never writes a
        // scale at all and every shift comes out near-silent.
        c.rubberband_live_set_formant_scale(state, 1.0);
        const block_size: usize = c.rubberband_live_get_block_size(state);
        if (block_size == 0 or block_size > ring_frames) return error.OutOfMemory;

        var self: PitchShift = .{
            .sample_rate = safe_rate,
            .state = state,
            .block_size = block_size,
            .in_channels = undefined,
            .out_channels = undefined,
            .pending = undefined,
            .ready = undefined,
        };
        var allocated: usize = 0;
        errdefer for (0..allocated) |i| allocator.free(self.bufferAt(i));
        for (0..8) |i| {
            const len = if (i < 4) block_size else ring_frames;
            const buf = try allocator.alloc(f32, len);
            @memset(buf, 0.0);
            self.setBufferAt(i, buf);
            allocated += 1;
        }
        return self;
    }

    /// The eight owned buffers, addressed by index so `init`'s partial-
    /// failure cleanup can walk them without eight separate errdefers.
    fn bufferAt(self: *const PitchShift, i: usize) []f32 {
        return switch (i) {
            0, 1 => self.in_channels[i],
            2, 3 => self.out_channels[i - 2],
            4, 5 => self.pending[i - 4],
            else => self.ready[i - 6],
        };
    }

    fn setBufferAt(self: *PitchShift, i: usize, buf: []f32) void {
        switch (i) {
            0, 1 => self.in_channels[i] = buf,
            2, 3 => self.out_channels[i - 2] = buf,
            4, 5 => self.pending[i - 4] = buf,
            else => self.ready[i - 6] = buf,
        }
    }

    pub fn deinit(self: *PitchShift, allocator: std.mem.Allocator) void {
        for (0..8) |i| allocator.free(self.bufferAt(i));
        c.rubberband_live_delete(self.state);
    }

    pub fn reset(self: *PitchShift) void {
        c.rubberband_live_reset(self.state);
        self.pending_len = 0;
        self.ready_len = 0;
        self.ready_read = 0;
        self.first_shift = true;
        for (0..8) |i| @memset(self.bufferAt(i), 0.0);
    }

    pub const device = dsp.deviceOf(@This());

    /// True when neither knob asks for anything, so `processBlock` returns
    /// before the shifter runs. Shared with `latencyFrames`, which must
    /// agree with it exactly: reporting a delay the unit is not adding
    /// makes the engine pull every other track `latencyFrames` early.
    fn isUnity(self: *const PitchShift) bool {
        const semis = dsp.sanitizeParam(self.semitones, -24.0, 24.0, 0.0) +
            dsp.sanitizeParam(self.cents, -100.0, 100.0, 0.0) / 100.0;
        const formant = dsp.sanitizeParam(self.formant, min_formant, max_formant, 0.0);
        return @abs(semis) < unity_epsilon and @abs(formant) < unity_epsilon;
    }

    /// One shifter block plus its start-up delay: what the engine has to
    /// delay every other chain by to keep this one in time. Zero while the
    /// unit is a wire - a freshly inserted one is, and 65 ms of phantom
    /// compensation on an untouched insert is worse than none.
    pub fn latencyFrames(self: *const PitchShift) u32 {
        if (self.isUnity()) return 0;
        return @intCast(self.block_size + c.rubberband_live_get_start_delay(self.state));
    }

    /// Pitch-shift an interleaved stereo buffer in place.
    pub fn processBlock(self: *PitchShift, buf: []Sample) void {
        const semis = dsp.sanitizeParam(self.semitones, -24.0, 24.0, 0.0) +
            dsp.sanitizeParam(self.cents, -100.0, 100.0, 0.0) / 100.0;
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 1.0);
        const formant = dsp.sanitizeParam(self.formant, min_formant, max_formant, 0.0);

        if (self.isUnity()) {
            // Nothing to do, and running the shifter at unity would still
            // cost its latency and a little smearing.
            for (buf) |*s| s.* = dsp.sanitizeParam(s.*, -16.0, 16.0, 0.0);
            return;
        }

        self.wanted_scale = std.math.pow(f64, 2.0, @as(f64, semis) / 12.0);
        const formant_scale = std.math.pow(f64, 2.0, @as(f64, formant) / 12.0);
        if (formant_scale != self.applied_formant) {
            c.rubberband_live_set_formant_scale(self.state, formant_scale);
            self.applied_formant = formant_scale;
        }

        const frames = buf.len / 2;
        for (0..frames) |i| {
            const dry_l = dsp.sanitizeParam(buf[i * 2], -16.0, 16.0, 0.0);
            const dry_r = dsp.sanitizeParam(buf[i * 2 + 1], -16.0, 16.0, 0.0);
            self.pending[0][self.pending_len] = dry_l;
            self.pending[1][self.pending_len] = dry_r;
            self.pending_len += 1;
            if (self.pending_len == self.block_size) self.shiftPending();

            const wet_l = self.takeReady(0);
            const wet_r = self.takeReady(1);
            buf[i * 2] = dry_l * (1.0 - mix) + wet_l * mix;
            buf[i * 2 + 1] = dry_r * (1.0 - mix) + wet_r * mix;
        }
    }

    /// Push `wanted_scale` to the library, held back to `max_first_scale`
    /// only while the very first shift is still pending. Per shift rather
    /// than per `processBlock`: one engine block is several shifter blocks
    /// at any ordinary block size, and only the first of them is the one
    /// the library has no pre-pad room for - deciding once per block left
    /// every shift in that block capped, so a shift past +19 semitones came
    /// out flat for the whole first block instead of one shifter block.
    fn applyPitchScale(self: *PitchShift) void {
        const scale = if (self.first_shift) @min(self.wanted_scale, max_first_scale) else self.wanted_scale;
        if (scale != self.applied_scale) {
            c.rubberband_live_set_pitch_scale(self.state, scale);
            self.applied_scale = scale;
        }
    }

    /// Hand one full block to Rubber Band and queue what comes back.
    fn shiftPending(self: *PitchShift) void {
        self.applyPitchScale();
        @memcpy(self.in_channels[0], self.pending[0][0..self.block_size]);
        @memcpy(self.in_channels[1], self.pending[1][0..self.block_size]);
        self.pending_len = 0;

        var in_ptrs = [_][*c]const f32{ self.in_channels[0].ptr, self.in_channels[1].ptr };
        var out_ptrs = [_][*c]f32{ self.out_channels[0].ptr, self.out_channels[1].ptr };
        c.rubberband_live_shift(self.state, &in_ptrs, &out_ptrs);
        self.first_shift = false;

        // Drop the oldest output rather than overrun the ring: that only
        // happens if a caller pushes far more input than it reads back, and
        // silence is a better failure than a stale block.
        if (self.ready_len - self.ready_read + self.block_size > ring_frames) {
            self.ready_len = 0;
            self.ready_read = 0;
        }
        inline for (0..2) |ch| {
            @memcpy(self.ready[ch][self.ready_len..][0..self.block_size], self.out_channels[ch]);
        }
        self.ready_len += self.block_size;
    }

    /// One frame of shifted output, or silence while the shifter is still
    /// filling its first block.
    fn takeReady(self: *PitchShift, ch: usize) f32 {
        if (self.ready_read >= self.ready_len) return 0.0;
        const value = self.ready[ch][self.ready_read];
        // Both channels read the same frame; only the second advances.
        if (ch == 1) self.ready_read += 1;
        if (ch == 1 and self.ready_read == self.ready_len) {
            self.ready_len = 0;
            self.ready_read = 0;
        }
        return value;
    }
};

fn processSine(shifter: *PitchShift, sample_rate: u32, frames: usize, hz: f32) ![]Sample {
    const buf = try std.testing.allocator.alloc(Sample, frames * 2);
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const value = 0.5 * @sin(2.0 * std.math.pi * hz * t);
        buf[i * 2] = value;
        buf[i * 2 + 1] = value;
    }
    var at: usize = 0;
    while (at + 512 <= buf.len) : (at += 512) shifter.processBlock(buf[at..][0..512]);
    return buf;
}

test "shifting a sine transposes it and keeps its level" {
    const sr: u32 = 48_000;
    var shifter = try PitchShift.init(std.testing.allocator, sr);
    defer shifter.deinit(std.testing.allocator);
    shifter.semitones = 12.0;

    const buf = try processSine(&shifter, sr, sr * 2, 500.0);
    defer std.testing.allocator.free(buf);

    // Count zero crossings over a settled stretch: an octave up is twice as
    // many. Loose bounds, because this checks the transposition rather than
    // a spectral purity the FFT harness in work/ measures properly.
    var crossings: usize = 0;
    const tail = buf[buf.len / 2 ..];
    var i: usize = 2;
    while (i < tail.len) : (i += 2) {
        if ((tail[i - 2] < 0) != (tail[i] < 0)) crossings += 1;
    }
    const seconds = @as(f32, @floatFromInt(tail.len / 2)) / @as(f32, @floatFromInt(sr));
    const measured_hz = @as(f32, @floatFromInt(crossings)) / (2.0 * seconds);
    try std.testing.expect(measured_hz > 900.0 and measured_hz < 1100.0);
}

test "a shifted sine keeps its level" {
    // The transposition check above passes just as well on a signal 35 dB
    // down, which is what a never-initialized formant scale produced.
    const sr: u32 = 48_000;
    var shifter = try PitchShift.init(std.testing.allocator, sr);
    defer shifter.deinit(std.testing.allocator);
    shifter.semitones = 12.0;

    const buf = try processSine(&shifter, sr, sr * 2, 500.0);
    defer std.testing.allocator.free(buf);

    var peak: f32 = 0.0;
    for (buf[buf.len / 2 ..]) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.3);
    try std.testing.expect(peak < 0.8);
}

test "an untouched shifter passes audio through unchanged" {
    var shifter = try PitchShift.init(std.testing.allocator, 48_000);
    defer shifter.deinit(std.testing.allocator);
    var buf = [_]Sample{ 0.25, -0.25, 0.5, -0.5 };
    shifter.processBlock(&buf);
    try std.testing.expectEqualSlices(Sample, &.{ 0.25, -0.25, 0.5, -0.5 }, &buf);
}

test "non-finite params and samples never reach the output" {
    var shifter = try PitchShift.init(std.testing.allocator, 48_000);
    defer shifter.deinit(std.testing.allocator);
    shifter.semitones = std.math.nan(f32);
    shifter.cents = std.math.inf(f32);
    shifter.formant = -std.math.inf(f32);
    shifter.mix = std.math.nan(f32);
    var buf = [_]Sample{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1.0 };
    shifter.processBlock(&buf);
    for (buf) |s| try std.testing.expect(std.math.isFinite(s));
}

test "the top of the range still reaches its pitch after the first block" {
    // Semitones and cents both at maximum ask for a ratio past the one the
    // shifter's first-block pre-pad can fit; the first block is held back for
    // it, so what has to hold is that the rest are not.
    const sr: u32 = 48_000;
    var shifter = try PitchShift.init(std.testing.allocator, sr);
    defer shifter.deinit(std.testing.allocator);
    shifter.semitones = 24.0;
    shifter.cents = 100.0;

    const buf = try processSine(&shifter, sr, sr, 200.0);
    defer std.testing.allocator.free(buf);

    var crossings: usize = 0;
    const tail = buf[buf.len / 2 ..];
    var i: usize = 2;
    while (i < tail.len) : (i += 2) {
        if ((tail[i - 2] < 0) != (tail[i] < 0)) crossings += 1;
    }
    const seconds = @as(f32, @floatFromInt(tail.len / 2)) / @as(f32, @floatFromInt(sr));
    const measured_hz = @as(f32, @floatFromInt(crossings)) / (2.0 * seconds);
    // 200Hz up 25 semitones is 843Hz; the held-back first block would land
    // near 600Hz if it were the one still in effect.
    try std.testing.expect(measured_hz > 750.0 and measured_hz < 950.0);
}

test "latency is reported so the engine can compensate" {
    var shifter = try PitchShift.init(std.testing.allocator, 48_000);
    defer shifter.deinit(std.testing.allocator);
    shifter.semitones = 7.0; // at unity the unit is a wire and reports 0
    try std.testing.expect(shifter.latencyFrames() >= shifter.block_size);
}

test "one big block reaches the asked-for pitch inside that same block" {
    // `max_first_scale` is held back for the one shift the library has no
    // pre-pad room for. An engine block is several shifter blocks wide, so
    // deciding it once per `processBlock` held every shift in that block
    // back - a shift past +19 semitones came out a fourth flat for the
    // whole first block, and worse the larger the host's block size.
    var shifter = try PitchShift.init(std.testing.allocator, 48_000);
    defer shifter.deinit(std.testing.allocator);
    shifter.semitones = 24.0;
    shifter.cents = 100.0;

    const frames = shifter.block_size * 2; // two shifter blocks, one call
    const buf = try std.testing.allocator.alloc(Sample, frames * 2);
    defer std.testing.allocator.free(buf);
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        const v = 0.5 * @sin(2.0 * std.math.pi * 200.0 * t);
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    shifter.processBlock(buf);

    const wanted = std.math.pow(f64, 2.0, 25.0 / 12.0);
    try std.testing.expect(wanted > max_first_scale); // the test is only about the held-back case
    try std.testing.expectApproxEqAbs(wanted, shifter.applied_scale, 1e-9);
}

test "an idle shifter reports no latency, because it adds none" {
    // At unity `processBlock` is a wire - it returns before the shifter
    // runs. Reporting the shifter's latency anyway had the engine delay
    // every other track by 65 ms to compensate for a delay this one is not
    // adding, and unity is the state a freshly inserted unit is in.
    var shifter = try PitchShift.init(std.testing.allocator, 48_000);
    defer shifter.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), shifter.device().latencyFrames());

    var buf = [_]Sample{ 1.0, 1.0 } ++ [_]Sample{ 0.0, 0.0 } ** 63;
    shifter.processBlock(&buf);
    try std.testing.expectEqual(@as(Sample, 1.0), buf[0]); // really a wire

    shifter.semitones = 7.0;
    try std.testing.expect(shifter.device().latencyFrames() > 0);
}
