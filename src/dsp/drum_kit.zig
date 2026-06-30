//! Drum-kit synthesis — the factory that generates the shipped sample kit.
//!
//! These generators are richer than the first-iteration one-shots: layered
//! transients, inharmonic metal clusters, multi-burst claps, tuned bodies and
//! soft saturation. They are run once by the `genkit` build tool to render the
//! WAVs under `assets/kit/`, which the engine then ships via @embedFile. Keep
//! them allocation-light and deterministic so the committed kit is reproducible.

const std = @import("std");

/// A kit slot: display name, output filename (under assets/kit/), the generator
/// that renders it, and a sensible default mixer gain for the pad.
pub const PadDef = struct {
    name: []const u8,
    file: []const u8,
    gen: *const fn (std.mem.Allocator, u32) std.mem.Allocator.Error![]f32,
    gain: f32,
};

pub const kit = [_]PadDef{
    .{ .name = "kick", .file = "kick.wav", .gen = kick, .gain = 1.00 },
    .{ .name = "snare", .file = "snare.wav", .gen = snare, .gain = 0.85 },
    .{ .name = "hihat", .file = "hihat.wav", .gen = hihatClosed, .gain = 0.50 },
    .{ .name = "open", .file = "open.wav", .gen = hihatOpen, .gain = 0.50 },
    .{ .name = "clap", .file = "clap.wav", .gen = clap, .gain = 0.70 },
    .{ .name = "tom-1", .file = "tom1.wav", .gen = tom1, .gain = 0.80 },
    .{ .name = "tom-2", .file = "tom2.wav", .gen = tom2, .gain = 0.80 },
    .{ .name = "rim", .file = "rim.wav", .gen = rim, .gain = 0.65 },
};

// ---------------------------------------------------------------------------
// Small DSP toolkit (allocation-free, sample-at-a-time)

const tau = 2.0 * std.math.pi;

/// One-pole low-pass with a high-pass complement.
const OnePole = struct {
    y: f32 = 0,
    fn lp(self: *OnePole, x: f32, alpha: f32) f32 {
        self.y += alpha * (x - self.y);
        return self.y;
    }
    /// High-pass = input minus the low-passed component.
    fn hp(self: *OnePole, x: f32, alpha: f32) f32 {
        return x - self.lp(x, alpha);
    }
};

/// Map a cutoff in Hz to a one-pole coefficient at sample rate `sr`.
fn cutoffAlpha(hz: f32, sr: f32) f32 {
    const c = tau * hz / sr;
    return std.math.clamp(c / (c + 1.0), 0.0, 1.0);
}

fn expEnv(t: f32, rate: f32) f32 {
    return std.math.exp(-t * rate);
}

/// Symmetric soft clip; `drive` > 1 adds harmonics and glues transients.
fn saturate(x: f32, drive: f32) f32 {
    return std.math.tanh(x * drive);
}

/// Square wave from a normalised phase (0..1).
fn square(phase: f32) f32 {
    return if (phase - @floor(phase) < 0.5) 1.0 else -1.0;
}

fn frames(sr: u32, seconds: f32) usize {
    return @as(usize, @intFromFloat(seconds * @as(f32, @floatFromInt(sr)))) + 1;
}

/// Scale the buffer so its peak sits at `target` (no-op for silence). Keeps the
/// rendered kit at a consistent, near-full-scale level; per-pad balance is then
/// the pad's mixer gain (see `PadDef.gain`).
fn normalize(buf: []f32, target: f32) void {
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    if (peak <= 1e-9) return;
    const g = target / peak;
    for (buf) |*s| s.* *= g;
}

// ---------------------------------------------------------------------------
// Generators

/// Layered kick: a pitch-swept sine body (saturated for punch) plus a short
/// noise+click transient at the attack.
fn kick(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, 0.55));
    var prng = std.Random.DefaultPrng.init(0x4b1c);
    const rand = prng.random();
    var phase: f32 = 0;
    var click_hp: OnePole = .{};
    const click_a = cutoffAlpha(1200.0, srf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        // Body: fast exponential pitch drop 153 → 48 Hz.
        const freq = 48.0 + 105.0 * expEnv(t, 36.0);
        const body = @sin(tau * phase) * expEnv(t, 6.5);
        phase += freq / srf;
        if (phase >= 1.0) phase -= 1.0;
        // Click: highpassed noise + bright sine, gone in a few ms.
        const click_env = expEnv(t, 320.0);
        const click_raw = (rand.float(f32) * 2.0 - 1.0) * 0.6 + @sin(tau * 1700.0 * t) * 0.4;
        const click = click_hp.hp(click_raw, click_a) * click_env * 0.45;
        s.* = saturate(body * 2.2, 1.0) * 0.9 + click;
    }
    normalize(buf, 0.97);
    return buf;
}

/// Tuned two-tone shell plus bandpassed noise for the snares.
fn snare(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, 0.27));
    var prng = std.Random.DefaultPrng.init(0x51a2);
    const rand = prng.random();
    var p1: f32 = 0;
    var p2: f32 = 0;
    var lp: OnePole = .{};
    var hp: OnePole = .{};
    var mud: OnePole = .{};
    const lp_a = cutoffAlpha(8500.0, srf);
    const hp_a = cutoffAlpha(900.0, srf);
    const mud_a = cutoffAlpha(170.0, srf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        // Shell: two detuned sines, fast decay.
        const tone = (@sin(tau * p1) * 0.6 + @sin(tau * p2) * 0.4) * expEnv(t, 24.0);
        p1 += 185.0 / srf;
        p2 += 278.0 / srf;
        if (p1 >= 1.0) p1 -= 1.0;
        if (p2 >= 1.0) p2 -= 1.0;
        // Snare buzz: noise band-passed ~0.9–8.5 kHz, slightly longer decay.
        const n = rand.float(f32) * 2.0 - 1.0;
        const noise = hp.hp(lp.lp(n, lp_a), hp_a) * expEnv(t, 17.0);
        const mix = tone * 0.5 + noise * 0.85;
        s.* = saturate(mud.hp(mix, mud_a), 1.4);
    }
    normalize(buf, 0.95);
    return buf;
}

/// Inharmonic metal cluster (six squares) highpassed to keep only the bright
/// odd harmonics, shaped by `decay` and trimmed to `dur`.
fn metalHat(allocator: std.mem.Allocator, sr: u32, dur: f32, decay: f32) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, dur));
    var prng = std.Random.DefaultPrng.init(0x4a7e);
    const rand = prng.random();
    // 808-ish inharmonic partials.
    const freqs = [_]f32{ 317.0, 465.0, 540.0, 643.0, 791.0, 957.0 };
    var ph = [_]f32{0} ** 6;
    var body_hp: OnePole = .{};
    var air_hp: OnePole = .{};
    const body_a = cutoffAlpha(6500.0, srf);
    const air_a = cutoffAlpha(9000.0, srf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        var cluster: f32 = 0;
        inline for (0..6) |k| {
            cluster += square(ph[k]);
            ph[k] += freqs[k] / srf;
            if (ph[k] >= 1.0) ph[k] -= 1.0;
        }
        cluster /= 6.0;
        const metal = body_hp.hp(cluster, body_a);
        const air = air_hp.hp(rand.float(f32) * 2.0 - 1.0, air_a) * 0.3;
        s.* = (metal + air) * expEnv(t, decay);
    }
    normalize(buf, 0.85);
    return buf;
}

fn hihatClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, 0.09, 65.0);
}

fn hihatOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, 0.42, 8.5);
}

/// Multi-burst clap: three tight noise transients spaced ~9 ms apart, then a
/// longer diffuse tail. Noise is band-passed around 1–3 kHz.
fn clap(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, 0.32));
    var prng = std.Random.DefaultPrng.init(0x0c1a);
    const rand = prng.random();
    var lp: OnePole = .{};
    var hp: OnePole = .{};
    const lp_a = cutoffAlpha(3000.0, srf);
    const hp_a = cutoffAlpha(1100.0, srf);
    const burst_offsets = [_]f32{ 0.0, 0.009, 0.018 };
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        const n = rand.float(f32) * 2.0 - 1.0;
        const band = hp.hp(lp.lp(n, lp_a), hp_a);
        // Three sharp bursts ...
        var env: f32 = 0;
        inline for (burst_offsets) |off| {
            if (t >= off) env = @max(env, expEnv(t - off, 220.0));
        }
        // ... plus a softer room tail.
        env += expEnv(t, 16.0) * 0.5;
        s.* = band * env;
    }
    normalize(buf, 0.92);
    return buf;
}

/// Pitch-swept tom with a noise attack and saturated body.
fn tomGen(allocator: std.mem.Allocator, sr: u32, f_start: f32, f_end: f32, dur: f32, seed: u64) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, dur));
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const log_ratio = @log(f_end / f_start);
    var phase: f32 = 0;
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        const norm = t / dur;
        const freq = f_start * std.math.exp(log_ratio * norm);
        const body = @sin(tau * phase) * expEnv(t, 6.0);
        phase += freq / srf;
        if (phase >= 1.0) phase -= 1.0;
        const attack = (rand.float(f32) * 2.0 - 1.0) * expEnv(t, 120.0) * 0.12;
        s.* = saturate(body * 1.6, 1.0) * 0.9 + attack;
    }
    normalize(buf, 0.95);
    return buf;
}

fn tom1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, 220.0, 110.0, 0.42, 0x701);
}

fn tom2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, 160.0, 80.0, 0.5, 0x702);
}

/// Short, bright metallic click: two high sines plus a noise transient, hard
/// saturated for snap.
fn rim(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, 0.08));
    var prng = std.Random.DefaultPrng.init(0x71b0);
    const rand = prng.random();
    var p1: f32 = 0;
    var p2: f32 = 0;
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        const tone = (@sin(tau * p1) * 0.6 + @sin(tau * p2) * 0.4) * expEnv(t, 150.0);
        p1 += 1720.0 / srf;
        p2 += 1130.0 / srf;
        if (p1 >= 1.0) p1 -= 1.0;
        if (p2 >= 1.0) p2 -= 1.0;
        const click = (rand.float(f32) * 2.0 - 1.0) * expEnv(t, 320.0) * 0.5;
        s.* = saturate((tone + click) * 1.8, 1.0);
    }
    normalize(buf, 0.9);
    return buf;
}

// ---------------------------------------------------------------------------
// Tests

test "every kit generator produces audible, finite, normalised output" {
    for (kit) |def| {
        const buf = try def.gen(std.testing.allocator, 48_000);
        defer std.testing.allocator.free(buf);
        try std.testing.expect(buf.len > 0);
        var peak: f32 = 0;
        for (buf) |s| {
            try std.testing.expect(std.math.isFinite(s));
            peak = @max(peak, @abs(s));
        }
        try std.testing.expect(peak > 0.1); // clearly audible
        try std.testing.expect(peak <= 1.0); // never clips the 16-bit WAV
    }
}
