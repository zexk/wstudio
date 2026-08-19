//! Freeverb-style reverb: parallel damped comb filters into series
//! allpasses, per channel, with a slight delay offset on the right
//! channel for stereo width.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const delay_line = @import("delay_line.zig");

const Sample = types.Sample;

// Classic Freeverb tunings, in frames at 44.1 kHz (scaled at init).
const comb_tunings = [_]usize{ 1116, 1188, 1277, 1356 };
const allpass_tunings = [_]usize{ 556, 441 };
const stereo_spread = 23;
const input_gain = 0.06;

/// Longest predelay a user can dial in - past this, "predelay" reads as a
/// separate slap-delay effect rather than a room's early-reflection gap.
const max_predelay_ms: f32 = 250.0;

/// Sparse early-reflection pattern `impulse` adds ahead of the algorithmic
/// tail, in ms from the predelay onset. File scope, not a literal inside the
/// sample loop, so `init` can size the predelay line off the same table it
/// is read with - the two drifting apart is what clamped every reflection
/// back onto the predelay tap and collapsed all six into one.
const impulse_taps = [6]struct { ms: f32, gain: f32 }{
    .{ .ms = 7.0, .gain = 0.36 },
    .{ .ms = 13.0, .gain = -0.25 },
    .{ .ms = 23.0, .gain = 0.2 },
    .{ .ms = 37.0, .gain = -0.15 },
    .{ .ms = 59.0, .gain = 0.11 },
    .{ .ms = 83.0, .gain = -0.08 },
};

/// The right channel walks each tap one further out than the left, so the
/// last one sits `impulse_taps.len` frames past the nominal delay.
const max_impulse_offset_frames: usize = impulse_taps.len;

pub const Reverb = struct {
    sample_rate: u32,
    /// 0 = dry only, 1 = wet only.
    mix: f32 = 0.3,
    /// Comb feedback; higher = longer tail.
    room: f32 = 0.84,
    damp: f32 = 0.25,
    /// Silence before the tail starts, in ms - real early reflections take
    /// time to arrive, so this separates the dry attack from the reverb onset.
    predelay_ms: f32 = 0.0,
    /// 0 = mono wet (both channels hear the same tail), 1 = the tail keeps
    /// its full per-channel stereo spread. Freeverb's own M/S width blend.
    width: f32 = 1.0,
    /// One-pole highpass on the wet tail, 0 = off. Freeverb's undamped
    /// comb feedback lets low-end build up into "mud"; this clears it.
    low_cut_hz: f32 = 0.0,
    /// Adds a sparse room impulse ahead of the algorithmic tail.
    impulse: f32 = 0.0,
    /// Shared write position for every channel's predelay line - same
    /// single-index-drives-both-lines shape as Chorus.index.
    predelay_idx: usize = 0,
    channels: [2]Channel,

    const Comb = struct {
        buf: []Sample,
        idx: usize = 0,
        store: f32 = 0.0,
    };

    const Allpass = struct {
        buf: []Sample,
        idx: usize = 0,
    };

    const Channel = struct {
        combs: [comb_tunings.len]Comb,
        allpasses: [allpass_tunings.len]Allpass,
        predelay: []Sample,
        hp_x1: f32 = 0.0,
        hp_y1: f32 = 0.0,
    };

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Reverb {
        const safe_rate = @max(sample_rate, 1);
        var self: Reverb = .{ .sample_rate = safe_rate, .channels = undefined };
        var comb_count: usize = 0;
        var allpass_count: usize = 0;
        var predelay_count: usize = 0;
        errdefer {
            for (0..comb_count) |i| {
                const ch = i / comb_tunings.len;
                allocator.free(self.channels[ch].combs[i % comb_tunings.len].buf);
            }
            for (0..allpass_count) |i| {
                const ch = i / allpass_tunings.len;
                allocator.free(self.channels[ch].allpasses[i % allpass_tunings.len].buf);
            }
            for (0..predelay_count) |i| allocator.free(self.channels[i].predelay);
        }
        const scale = @as(f64, @floatFromInt(safe_rate)) / 44_100.0;
        // Sized for the predelay *plus* the longest early reflection stacked
        // on top of it: the taps read the same line, and a line only long
        // enough for the predelay itself clamped them back under it, so at
        // the top of the knob all six landed on one frame at the onset
        // instead of spreading over 7-83 ms. Plus the widest stereo offset,
        // plus 2 headroom frames for readInterp's cubic tap.
        const line_ms = max_predelay_ms + impulse_taps[impulse_taps.len - 1].ms;
        const predelay_frames = @as(usize, @intFromFloat(line_ms / 1000.0 * @as(f32, @floatFromInt(safe_rate)))) +
            max_impulse_offset_frames + 2;
        for (&self.channels, 0..) |*ch, ch_i| {
            const spread = ch_i * stereo_spread;
            ch.predelay = try allocator.alloc(Sample, predelay_frames);
            @memset(ch.predelay, 0.0);
            predelay_count += 1;
            ch.hp_x1 = 0.0;
            ch.hp_y1 = 0.0;
            for (&ch.combs, comb_tunings) |*comb, tuning| {
                comb.* = .{ .buf = try allocLine(allocator, tuning + spread, scale) };
                comb_count += 1;
            }
            for (&ch.allpasses, allpass_tunings) |*ap, tuning| {
                ap.* = .{ .buf = try allocLine(allocator, tuning + spread, scale) };
                allpass_count += 1;
            }
        }
        return self;
    }

    fn allocLine(allocator: std.mem.Allocator, frames_44k: usize, scale: f64) ![]Sample {
        const n: usize = @intFromFloat(@as(f64, @floatFromInt(frames_44k)) * scale);
        const buf = try allocator.alloc(Sample, @max(n, 1));
        @memset(buf, 0.0);
        return buf;
    }

    pub fn deinit(self: *Reverb, allocator: std.mem.Allocator) void {
        for (&self.channels) |*ch| {
            for (ch.combs) |comb| allocator.free(comb.buf);
            for (ch.allpasses) |ap| allocator.free(ap.buf);
            allocator.free(ch.predelay);
        }
    }

    pub fn reset(self: *Reverb) void {
        self.predelay_idx = 0;
        for (&self.channels) |*ch| {
            for (&ch.combs) |*comb| {
                @memset(comb.buf, 0.0);
                comb.store = 0.0;
            }
            for (&ch.allpasses) |*ap| @memset(ap.buf, 0.0);
            @memset(ch.predelay, 0.0);
            ch.hp_x1 = 0.0;
            ch.hp_y1 = 0.0;
        }
    }

    pub const device = dsp.deviceOf(@This());

    pub fn processBlock(self: *Reverb, buf: []Sample) void {
        // room >= 1 makes each comb's own feedback loop gain >= 1, so
        // energy grows every time a sample cycles back through its delay
        // line instead of decaying.
        const room = dsp.sanitizeParam(self.room, 0.0, 0.98, 0.84);
        const damp = dsp.sanitizeParam(self.damp, 0.0, 1.0, 0.25);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 0.3);
        const predelay_ms = dsp.sanitizeParam(self.predelay_ms, 0.0, max_predelay_ms, 0.0);
        const width = dsp.sanitizeParam(self.width, 0.0, 1.0, 1.0);
        const low_cut_hz = dsp.sanitizeParam(self.low_cut_hz, 0.0, 500.0, 0.0);
        const impulse = dsp.sanitizeParam(self.impulse, 0.0, 1.0, 0.0) >= 0.5;
        const sr_f = @as(f32, @floatFromInt(self.sample_rate));
        const predelay_frames = predelay_ms * 0.001 * sr_f;
        // One-pole highpass: alpha = 1 at low_cut_hz = 0 makes the recurrence
        // telescope to an exact identity (off), rising cutoff pulls it down.
        const hp_alpha = 1.0 / (1.0 + 2.0 * std.math.pi * low_cut_hz / sr_f);
        // Freeverb's own M/S width blend: wet1 keeps a channel's own tail,
        // wet2 bleeds in the other channel's, collapsing to mono at width=0.
        const wet1 = width * 0.5 + 0.5;
        const wet2 = (1.0 - width) * 0.5;

        const frames = buf.len / 2;
        for (0..frames) |i| {
            var wet: [2]f32 = undefined;
            inline for (0..2) |ch_i| {
                const ch = &self.channels[ch_i];
                const dry = buf[i * 2 + ch_i];

                ch.predelay[self.predelay_idx] = dry;
                const delayed = delay_line.readInterp(ch.predelay, self.predelay_idx, predelay_frames);
                const input = delayed * input_gain;

                var w: f32 = 0.0;
                for (&ch.combs) |*comb| {
                    const y = comb.buf[comb.idx];
                    comb.store = y * (1.0 - damp) + comb.store * damp;
                    comb.buf[comb.idx] = input + comb.store * room;
                    comb.idx = (comb.idx + 1) % comb.buf.len;
                    w += y;
                }
                for (&ch.allpasses) |*ap| {
                    const y = ap.buf[ap.idx];
                    ap.buf[ap.idx] = w + y * 0.5;
                    ap.idx = (ap.idx + 1) % ap.buf.len;
                    w = y - w;
                }

                if (impulse) {
                    for (impulse_taps, 0..) |t, tap| {
                        const stereo_offset: f32 = @floatFromInt(ch_i * (tap + 1));
                        // The line is sized to fit this; the clamp is the
                        // belt-and-braces layer, not the shaping.
                        const delay = @min(predelay_frames + t.ms * 0.001 * sr_f + stereo_offset, @as(f32, @floatFromInt(ch.predelay.len - 2)));
                        w += delay_line.readInterp(ch.predelay, self.predelay_idx, delay) * t.gain;
                    }
                }

                const hp_out = hp_alpha * (ch.hp_y1 + w - ch.hp_x1);
                ch.hp_x1 = w;
                ch.hp_y1 = hp_out;
                wet[ch_i] = hp_out;
            }
            self.predelay_idx = (self.predelay_idx + 1) % self.channels[0].predelay.len;

            const wet_l = wet[0] * wet1 + wet[1] * wet2;
            const wet_r = wet[1] * wet1 + wet[0] * wet2;
            buf[i * 2 + 0] = buf[i * 2 + 0] * (1.0 - mix) + wet_l * mix;
            buf[i * 2 + 1] = buf[i * 2 + 1] * (1.0 - mix) + wet_r * mix;
        }
    }
};

fn testInitAllocationFailures(allocator: std.mem.Allocator) !void {
    var reverb = try Reverb.init(allocator, 48_000);
    defer reverb.deinit(allocator);
}

test "init cleans up every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testInitAllocationFailures, .{});
}

test "impulse produces a decaying tail, not an explosion" {
    var reverb = try Reverb.init(std.testing.allocator, 48_000);
    defer reverb.deinit(std.testing.allocator);
    reverb.mix = 1.0; // wet only so we observe the tail directly

    var buf = [_]Sample{0.0} ** (4096 * 2);
    buf[0] = 1.0;
    buf[1] = 1.0;
    reverb.processBlock(&buf);

    var tail_energy: f32 = 0.0;
    var peak: f32 = 0.0;
    for (buf[2048..]) |s| {
        tail_energy += s * s;
        peak = @max(peak, @abs(s));
    }
    try std.testing.expect(tail_energy > 0.0); // reverb tail exists
    try std.testing.expect(peak < 1.0); // and stays bounded
}

test "invalid parameters cannot trap or poison output" {
    var reverb = try Reverb.init(std.testing.allocator, 48_000);
    defer reverb.deinit(std.testing.allocator);
    reverb.room = std.math.inf(f32);
    reverb.damp = std.math.nan(f32);
    reverb.mix = -std.math.inf(f32);

    var buf = [_]Sample{0.0} ** (2048 * 2);
    buf[0] = 1.0;
    buf[1] = 1.0;
    reverb.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "predelay pushes the tail's onset later" {
    // Even with no predelay, the shortest comb (1116 frames) stays silent
    // until the impulse cycles all the way around its own ring - see
    // "impulse produces a decaying tail" above. 20ms of predelay (960
    // frames) pushes that already-late onset out further still.
    var reverb = try Reverb.init(std.testing.allocator, 48_000);
    defer reverb.deinit(std.testing.allocator);
    reverb.mix = 1.0; // wet only
    reverb.predelay_ms = 20.0; // 960 frames at 48 kHz

    var buf = [_]Sample{0.0} ** (4096 * 2);
    buf[0] = 1.0;
    buf[1] = 1.0;
    reverb.processBlock(&buf);

    var pre_energy: f32 = 0.0;
    for (buf[0 .. 900 * 2]) |s| pre_energy += s * s;
    try std.testing.expectEqual(@as(f32, 0.0), pre_energy); // nothing before the gap

    var post_energy: f32 = 0.0;
    for (buf[2200 * 2 ..]) |s| post_energy += s * s;
    try std.testing.expect(post_energy > 0.0); // tail has arrived
}

test "impulse mode adds early reflections before the algorithmic tail" {
    var reverb = try Reverb.init(std.testing.allocator, 48_000);
    defer reverb.deinit(std.testing.allocator);
    reverb.mix = 1;
    reverb.impulse = 1;
    var buf = [_]Sample{0} ** (1000 * 2);
    buf[0] = 1;
    buf[1] = 1;
    reverb.processBlock(&buf);
    var peak: f32 = 0;
    for (buf[500..]) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.1);
}

test "width 0 collapses both channels to the same mono tail" {
    var reverb = try Reverb.init(std.testing.allocator, 48_000);
    defer reverb.deinit(std.testing.allocator);
    reverb.mix = 1.0;
    reverb.width = 0.0;

    var buf = [_]Sample{0.0} ** (512 * 2);
    buf[0] = 1.0; // left-only impulse, so width=1 would leave L != R

    reverb.processBlock(&buf);

    var i: usize = 0;
    while (i < buf.len) : (i += 2) {
        try std.testing.expectApproxEqAbs(buf[i], buf[i + 1], 1e-6);
    }
}

test "low cut and predelay stay bounded under noise" {
    var reverb = try Reverb.init(std.testing.allocator, 44_100);
    defer reverb.deinit(std.testing.allocator);
    reverb.mix = 1.0;
    reverb.room = 0.98;
    reverb.predelay_ms = max_predelay_ms;
    reverb.width = 0.0;
    reverb.low_cut_hz = 500.0;
    try dsp.expectBoundedUnderNoise(&reverb, 1.0);
}

test "early reflections still spread out at the top of the predelay knob" {
    // The taps read the predelay line, so a line sized for the predelay
    // alone clamped them back under it: at max predelay all six landed on
    // one frame at the onset instead of spreading over 7-83 ms.
    //
    // They are summed after the allpass chain, so `impulse` on minus
    // `impulse` off is exactly the six taps and nothing else - which is
    // what makes "where does their energy sit" a question with an answer.
    const sr = 48_000;
    const frames = sr / 2; // 500 ms: 250 of predelay plus the 83 ms tap
    const render = struct {
        fn f(impulse: f32, out: []Sample) !void {
            var reverb = try Reverb.init(std.testing.allocator, sr);
            defer reverb.deinit(std.testing.allocator);
            reverb.mix = 1.0;
            reverb.predelay_ms = max_predelay_ms;
            reverb.impulse = impulse;
            @memset(out, 0.0);
            out[0] = 1.0;
            out[1] = 1.0;
            reverb.processBlock(out);
        }
    }.f;

    const on = try std.testing.allocator.alloc(Sample, frames * 2);
    defer std.testing.allocator.free(on);
    const off = try std.testing.allocator.alloc(Sample, frames * 2);
    defer std.testing.allocator.free(off);
    try render(1.0, on);
    try render(0.0, off);

    var total: f64 = 0;
    var late: f64 = 0;
    // 50-90 ms past the predelay onset: where only the 59 ms and 83 ms
    // reflections live.
    const from = (sr * 300 / 1000) * 2;
    const to = (sr * 340 / 1000) * 2;
    for (on, off, 0..) |a, b, i| {
        const d = @as(f64, a) - b;
        total += d * d;
        if (i >= from and i < to) late += d * d;
    }
    try std.testing.expect(total > 0.0);
    // Those two taps carry ~7% of the pattern's power; all six collapsed
    // onto the onset leaves the window empty.
    try std.testing.expect(late > total * 0.03);
}
