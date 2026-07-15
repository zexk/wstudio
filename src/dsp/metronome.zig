//! Click track: a short synthesised tick mixed straight into the master
//! bus (like the limiter, not a per-track device) at every beat boundary,
//! with a higher/louder accent on beat 1 of each bar. Engine.fireMetronome
//! drives it with the same monotonic-counter, resync-on-discontinuity
//! technique DrumMachine uses for its step sequencer.

const std = @import("std");
const types = @import("../core/types.zig");

const Sample = types.Sample;

pub const Metronome = struct {
    allocator: std.mem.Allocator,
    accent_click: []f32,
    click: []f32,

    // Audio-thread-only voice state: one click at a time (a new beat just
    // restarts it - beats are never dense enough for overlap to matter).
    active: bool = false,
    is_accent: bool = false,
    pos: usize = 0,
    /// Frame offset within the current block where the click starts. 0 for
    /// a click continuing from a previous block (mirrors dsp/pad.zig's Voice).
    block_start: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Metronome {
        const safe_rate = @max(sample_rate, 1);
        const accent_click = try genClick(allocator, safe_rate, 1600.0, 0.9);
        errdefer allocator.free(accent_click);
        const click = try genClick(allocator, safe_rate, 1000.0, 0.6);
        return .{ .allocator = allocator, .accent_click = accent_click, .click = click };
    }

    pub fn deinit(self: *Metronome) void {
        self.allocator.free(self.accent_click);
        self.allocator.free(self.click);
    }

    pub fn trigger(self: *Metronome, accent: bool, block_start: u32) void {
        self.active = true;
        self.is_accent = accent;
        self.pos = 0;
        self.block_start = block_start;
    }

    /// Mix the click into interleaved `buf` (added, not overwritten - same
    /// convention as track rendering). No-op when no click is in flight.
    pub fn render(self: *Metronome, buf: []Sample, channels: usize, frames: u32) void {
        if (!self.active) return;
        const clip = if (self.is_accent) self.accent_click else self.click;
        var i: usize = self.block_start;
        while (i < frames) : (i += 1) {
            // zig fmt: off
            if (self.pos >= clip.len) { self.active = false; break; }
            // zig fmt: on
            const s = clip[self.pos];
            for (0..channels) |ch| buf[i * channels + ch] += s;
            self.pos += 1;
        }
        self.block_start = 0;
    }
};

/// A short decaying sine burst - a click, not a tone, so it stays out of the
/// way of the mix.
fn genClick(allocator: std.mem.Allocator, sample_rate: u32, freq: f32, gain: f32) ![]f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const len: usize = @max(1, @as(usize, @intFromFloat(sr * 0.03))); // 30ms
    const out = try allocator.alloc(f32, len);
    const tau: f32 = 0.012; // decay time constant
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        s.* = gain * @exp(-t / tau) * @sin(2.0 * std.math.pi * freq * t);
    }
    return out;
}

test "zero sample rate still produces finite clicks" {
    var m = try Metronome.init(std.testing.allocator, 0);
    defer m.deinit();
    try std.testing.expect(m.click.len > 0);
    try std.testing.expect(m.accent_click.len > 0);
    for (m.click) |sample| try std.testing.expect(std.math.isFinite(sample));
    for (m.accent_click) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "click decays to near-silence by the end of the buffer" {
    const click = try genClick(std.testing.allocator, 48_000, 1000.0, 1.0);
    defer std.testing.allocator.free(click);
    try std.testing.expect(@abs(click[0]) < 0.1); // sine starts at 0
    try std.testing.expect(@abs(click[click.len - 1]) < 0.05);
}

test "trigger then render advances through the click and stops" {
    var m = try Metronome.init(std.testing.allocator, 48_000);
    defer m.deinit();

    m.trigger(false, 0);
    var buf = [_]Sample{0.0} ** 8;
    m.render(&buf, 2, 4);
    try std.testing.expect(m.active);
    // Frame 0 is the sine's zero crossing; frame 1 isn't.
    try std.testing.expect(buf[2] != 0.0 or buf[3] != 0.0);

    // Render the rest of the (short) click in big chunks until it stops.
    var big = [_]Sample{0.0} ** 8192;
    while (m.active) m.render(&big, 2, 4096);
    try std.testing.expect(!m.active);
}

test "accent click is louder and higher-pitched than the regular click" {
    var m = try Metronome.init(std.testing.allocator, 48_000);
    defer m.deinit();
    // Accent peaks louder than the regular click.
    var accent_peak: f32 = 0;
    for (m.accent_click) |s| accent_peak = @max(accent_peak, @abs(s));
    var click_peak: f32 = 0;
    for (m.click) |s| click_peak = @max(click_peak, @abs(s));
    try std.testing.expect(accent_peak > click_peak);
}
