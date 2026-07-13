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

/// Tunable knobs behind `kick()` — see `kickGen`. Defaults reproduce the
/// original shipped kick exactly.
pub const KickParams = struct {
    /// Pitch sweeps from `freq_end + freq_start_add` down to `freq_end` Hz.
    freq_end: f32 = 58.0,
    freq_start_add: f32 = 130.0,
    pitch_decay: f32 = 55.0,
    body_decay: f32 = 14.0,
    click_decay: f32 = 320.0,
    click_freq: f32 = 1700.0,
    click_mix: f32 = 0.6,
    drive: f32 = 2.6,
    dur_s: f32 = 0.30,
};

/// Layered kick: a pitch-swept sine body (saturated for punch) plus a short
/// noise+click transient at the attack.
fn kickGen(allocator: std.mem.Allocator, sr: u32, p: KickParams) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    // Short buffer — no long sub tail.
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var prng = std.Random.DefaultPrng.init(0x4b1c);
    const rand = prng.random();
    var phase: f32 = 0;
    var click_hp: OnePole = .{};
    const click_a = cutoffAlpha(1200.0, srf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        // Body: fast, deep pitch drop — punch, not a held sub tone.
        const freq = p.freq_end + p.freq_start_add * expEnv(t, p.pitch_decay);
        // Punchy amp env: sharp transient, quick decay (snappy, no ring-out).
        const body = @sin(tau * phase) * expEnv(t, p.body_decay);
        phase += freq / srf;
        if (phase >= 1.0) phase -= 1.0;
        // Click: highpassed noise + bright sine, gone in a few ms.
        const click_env = expEnv(t, p.click_decay);
        const click_raw = (rand.float(f32) * 2.0 - 1.0) * 0.6 + @sin(tau * p.click_freq * t) * 0.4;
        const click = click_hp.hp(click_raw, click_a) * click_env * p.click_mix;
        s.* = saturate(body * p.drive, 1.0) * 0.9 + click;
    }
    normalize(buf, 0.97);
    return buf;
}

fn kick(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{});
}

/// Tunable knobs behind `snare()` — see `snareGen`. Defaults reproduce the
/// original shipped snare exactly.
pub const SnareParams = struct {
    tone1_hz: f32 = 185.0,
    tone2_hz: f32 = 278.0,
    tone_decay: f32 = 24.0,
    noise_decay: f32 = 17.0,
    drive: f32 = 1.4,
    dur_s: f32 = 0.27,
    /// Noise band-pass edges: lower `lp_hz` muffles the crack (tape/lo-fi),
    /// higher opens it up. Defaults reproduce the original hardcoded band.
    lp_hz: f32 = 8500.0,
    hp_hz: f32 = 900.0,
};

/// Tuned two-tone shell plus bandpassed noise for the snares.
fn snareGen(allocator: std.mem.Allocator, sr: u32, p: SnareParams) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var prng = std.Random.DefaultPrng.init(0x51a2);
    const rand = prng.random();
    var p1: f32 = 0;
    var p2: f32 = 0;
    var lp: OnePole = .{};
    var hp: OnePole = .{};
    var mud: OnePole = .{};
    const lp_a = cutoffAlpha(p.lp_hz, srf);
    const hp_a = cutoffAlpha(p.hp_hz, srf);
    const mud_a = cutoffAlpha(170.0, srf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        // Shell: two detuned sines, fast decay.
        const tone = (@sin(tau * p1) * 0.6 + @sin(tau * p2) * 0.4) * expEnv(t, p.tone_decay);
        p1 += p.tone1_hz / srf;
        p2 += p.tone2_hz / srf;
        if (p1 >= 1.0) p1 -= 1.0;
        if (p2 >= 1.0) p2 -= 1.0;
        // Snare buzz: noise band-passed ~0.9–8.5 kHz, slightly longer decay.
        const n = rand.float(f32) * 2.0 - 1.0;
        const noise = hp.hp(lp.lp(n, lp_a), hp_a) * expEnv(t, p.noise_decay);
        const mix = tone * 0.5 + noise * 0.85;
        s.* = saturate(mud.hp(mix, mud_a), p.drive);
    }
    normalize(buf, 0.95);
    return buf;
}

fn snare(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{});
}

/// Tunable knobs behind the hihats — see `metalHat`.
pub const HatParams = struct {
    dur_s: f32 = 0.09,
    decay: f32 = 65.0,
    body_hz: f32 = 6500.0,
    air_hz: f32 = 9000.0,
    air_mix: f32 = 0.3,
};

/// Inharmonic metal cluster (six squares) highpassed to keep only the bright
/// odd harmonics, shaped by `p.decay` and trimmed to `p.dur_s`.
fn metalHat(allocator: std.mem.Allocator, sr: u32, p: HatParams) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var prng = std.Random.DefaultPrng.init(0x4a7e);
    const rand = prng.random();
    // 808-ish inharmonic partials.
    const freqs = [_]f32{ 317.0, 465.0, 540.0, 643.0, 791.0, 957.0 };
    var ph = [_]f32{0} ** 6;
    var body_hp: OnePole = .{};
    var air_hp: OnePole = .{};
    const body_a = cutoffAlpha(p.body_hz, srf);
    const air_a = cutoffAlpha(p.air_hz, srf);
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
        const air = air_hp.hp(rand.float(f32) * 2.0 - 1.0, air_a) * p.air_mix;
        s.* = (metal + air) * expEnv(t, p.decay);
    }
    normalize(buf, 0.85);
    return buf;
}

fn hihatClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.09, .decay = 65.0 });
}

fn hihatOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.42, .decay = 8.5 });
}

/// Tunable knobs behind `clap()` — see `clapGen`. Defaults reproduce the
/// original shipped clap exactly.
pub const ClapParams = struct {
    lp_hz: f32 = 3000.0,
    hp_hz: f32 = 1100.0,
    burst_decay: f32 = 220.0,
    tail_decay: f32 = 16.0,
    tail_mix: f32 = 0.5,
    dur_s: f32 = 0.32,
};

/// Multi-burst clap: three tight noise transients spaced ~9 ms apart, then a
/// longer diffuse tail. Noise is band-passed around 1–3 kHz.
fn clapGen(allocator: std.mem.Allocator, sr: u32, p: ClapParams) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var prng = std.Random.DefaultPrng.init(0x0c1a);
    const rand = prng.random();
    var lp: OnePole = .{};
    var hp: OnePole = .{};
    const lp_a = cutoffAlpha(p.lp_hz, srf);
    const hp_a = cutoffAlpha(p.hp_hz, srf);
    const burst_offsets = [_]f32{ 0.0, 0.009, 0.018 };
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        const n = rand.float(f32) * 2.0 - 1.0;
        const band = hp.hp(lp.lp(n, lp_a), hp_a);
        // Three sharp bursts ...
        var env: f32 = 0;
        inline for (burst_offsets) |off| {
            if (t >= off) env = @max(env, expEnv(t - off, p.burst_decay));
        }
        // ... plus a softer room tail.
        env += expEnv(t, p.tail_decay) * p.tail_mix;
        s.* = band * env;
    }
    normalize(buf, 0.92);
    return buf;
}

fn clap(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{});
}

/// Tunable knobs behind the toms — see `tomGen`.
pub const TomParams = struct {
    freq_start: f32,
    freq_end: f32,
    dur_s: f32,
    body_decay: f32 = 6.0,
    attack_decay: f32 = 120.0,
    drive: f32 = 1.6,
    attack_mix: f32 = 0.12,
    seed: u64,
};

/// Pitch-swept tom with a noise attack and saturated body.
fn tomGen(allocator: std.mem.Allocator, sr: u32, p: TomParams) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var prng = std.Random.DefaultPrng.init(p.seed);
    const rand = prng.random();
    const log_ratio = @log(p.freq_end / p.freq_start);
    var phase: f32 = 0;
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        const norm = t / p.dur_s;
        const freq = p.freq_start * std.math.exp(log_ratio * norm);
        const body = @sin(tau * phase) * expEnv(t, p.body_decay);
        phase += freq / srf;
        if (phase >= 1.0) phase -= 1.0;
        const attack = (rand.float(f32) * 2.0 - 1.0) * expEnv(t, p.attack_decay) * p.attack_mix;
        s.* = saturate(body * p.drive, 1.0) * 0.9 + attack;
    }
    normalize(buf, 0.95);
    return buf;
}

fn tom1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{ .freq_start = 220.0, .freq_end = 110.0, .dur_s = 0.42, .seed = 0x701 });
}

fn tom2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{ .freq_start = 160.0, .freq_end = 80.0, .dur_s = 0.5, .seed = 0x702 });
}

/// Tunable knobs behind `rim()` — see `rimGen`. Defaults reproduce the
/// original shipped rim exactly.
pub const RimParams = struct {
    tone1_hz: f32 = 1720.0,
    tone2_hz: f32 = 1130.0,
    tone_decay: f32 = 150.0,
    click_decay: f32 = 320.0,
    drive: f32 = 1.8,
    dur_s: f32 = 0.08,
};

/// Short, bright metallic click: two high sines plus a noise transient, hard
/// saturated for snap.
fn rimGen(allocator: std.mem.Allocator, sr: u32, p: RimParams) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var prng = std.Random.DefaultPrng.init(0x71b0);
    const rand = prng.random();
    var p1: f32 = 0;
    var p2: f32 = 0;
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        const tone = (@sin(tau * p1) * 0.6 + @sin(tau * p2) * 0.4) * expEnv(t, p.tone_decay);
        p1 += p.tone1_hz / srf;
        p2 += p.tone2_hz / srf;
        if (p1 >= 1.0) p1 -= 1.0;
        if (p2 >= 1.0) p2 -= 1.0;
        const click = (rand.float(f32) * 2.0 - 1.0) * expEnv(t, p.click_decay) * 0.5;
        s.* = saturate((tone + click) * p.drive, 1.0);
    }
    normalize(buf, 0.9);
    return buf;
}

fn rim(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{});
}

// ---------------------------------------------------------------------------
// Kit variants — alternate flavours of the same 8 drums, selectable at
// runtime via `:drum-kit <name>` (see tui/commands.zig). Unlike `kit` above,
// these are never rendered to WAV or embedded: picking one calls the
// generators directly into the DrumMachine's pads, so extra kits cost zero
// shipped bytes — just the parameter tables below.

// Each variant wrapper's generator params stay grouped on a couple of lines
// (pitch family / decay family / character) so a whole drum reads at a glance.
// zig fmt: off
fn kickAnalog(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 45.0, .freq_start_add = 90.0, .pitch_decay = 30.0, .body_decay = 7.0,
        .click_decay = 380.0, .click_freq = 1500.0, .click_mix = 0.25, .drive = 3.2, .dur_s = 0.55,
    });
}
fn snareAnalog(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 150.0, .tone2_hz = 210.0, .tone_decay = 18.0, .noise_decay = 22.0, .drive = 1.1, .dur_s = 0.3,
    });
}
fn hihatAnalogClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.06, .decay = 90.0, .body_hz = 7000.0, .air_hz = 9500.0, .air_mix = 0.2 });
}
fn hihatAnalogOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.35, .decay = 10.0, .body_hz = 7000.0, .air_hz = 9500.0, .air_mix = 0.2 });
}
fn clapAnalog(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 2500.0, .hp_hz = 1000.0, .burst_decay = 180.0, .tail_decay = 10.0, .tail_mix = 0.7, .dur_s = 0.4,
    });
}
fn tomAnalog1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 180.0, .freq_end = 90.0, .dur_s = 0.6, .body_decay = 4.0,
        .attack_decay = 100.0, .drive = 1.8, .attack_mix = 0.08, .seed = 0x711,
    });
}
fn tomAnalog2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 130.0, .freq_end = 60.0, .dur_s = 0.7, .body_decay = 3.5,
        .attack_decay = 100.0, .drive = 1.8, .attack_mix = 0.08, .seed = 0x712,
    });
}
fn rimAnalog(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 1600.0, .tone2_hz = 1050.0, .tone_decay = 170.0, .click_decay = 350.0, .drive = 1.5, .dur_s = 0.07,
    });
}

fn kickAcoustic(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 62.0, .freq_start_add = 150.0, .pitch_decay = 70.0, .body_decay = 20.0,
        .click_decay = 300.0, .click_freq = 2000.0, .click_mix = 0.8, .drive = 2.2, .dur_s = 0.22,
    });
}
fn snareAcoustic(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 200.0, .tone2_hz = 300.0, .tone_decay = 30.0, .noise_decay = 14.0, .drive = 1.8, .dur_s = 0.22,
    });
}
fn hihatAcousticClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.05, .decay = 110.0, .body_hz = 6000.0, .air_hz = 10_000.0, .air_mix = 0.4 });
}
fn hihatAcousticOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.3, .decay = 11.0, .body_hz = 6000.0, .air_hz = 10_000.0, .air_mix = 0.4 });
}
fn clapAcoustic(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 3500.0, .hp_hz = 1300.0, .burst_decay = 260.0, .tail_decay = 22.0, .tail_mix = 0.35, .dur_s = 0.25,
    });
}
fn tomAcoustic1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 260.0, .freq_end = 140.0, .dur_s = 0.3, .body_decay = 9.0,
        .attack_decay = 140.0, .drive = 1.5, .attack_mix = 0.2, .seed = 0x721,
    });
}
fn tomAcoustic2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 190.0, .freq_end = 100.0, .dur_s = 0.35, .body_decay = 8.0,
        .attack_decay = 140.0, .drive = 1.5, .attack_mix = 0.2, .seed = 0x722,
    });
}
fn rimAcoustic(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 1900.0, .tone2_hz = 1250.0, .tone_decay = 130.0, .click_decay = 280.0, .drive = 2.1, .dur_s = 0.06,
    });
}

fn kickIndustrial(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 50.0, .freq_start_add = 110.0, .pitch_decay = 40.0, .body_decay = 9.0,
        .click_decay = 250.0, .click_freq = 900.0, .click_mix = 0.9, .drive = 4.5, .dur_s = 0.5,
    });
}
fn snareIndustrial(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 140.0, .tone2_hz = 260.0, .tone_decay = 15.0, .noise_decay = 26.0, .drive = 2.4, .dur_s = 0.32,
    });
}
fn hihatIndustrialClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.12, .decay = 45.0, .body_hz = 5500.0, .air_hz = 8500.0, .air_mix = 0.5 });
}
fn hihatIndustrialOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.6, .decay = 5.0, .body_hz = 5500.0, .air_hz = 8500.0, .air_mix = 0.5 });
}
fn clapIndustrial(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 2800.0, .hp_hz = 900.0, .burst_decay = 150.0, .tail_decay = 8.0, .tail_mix = 0.8, .dur_s = 0.45,
    });
}
fn tomIndustrial1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 210.0, .freq_end = 95.0, .dur_s = 0.55, .body_decay = 5.0,
        .attack_decay = 90.0, .drive = 2.4, .attack_mix = 0.25, .seed = 0x731,
    });
}
fn tomIndustrial2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 150.0, .freq_end = 65.0, .dur_s = 0.65, .body_decay = 4.5,
        .attack_decay = 90.0, .drive = 2.4, .attack_mix = 0.25, .seed = 0x732,
    });
}
fn rimIndustrial(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 1500.0, .tone2_hz = 980.0, .tone_decay = 110.0, .click_decay = 220.0, .drive = 3.0, .dur_s = 0.09,
    });
}

fn kickBoombap(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 52.0, .freq_start_add = 70.0, .pitch_decay = 45.0, .body_decay = 10.0,
        .click_decay = 500.0, .click_freq = 1200.0, .click_mix = 0.15, .drive = 3.0, .dur_s = 0.4,
    });
}
fn snareBoombap(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 165.0, .tone2_hz = 245.0, .tone_decay = 20.0, .noise_decay = 13.0, .drive = 2.0, .dur_s = 0.24,
    });
}
fn hihatBoombapClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.045, .decay = 140.0, .body_hz = 5800.0, .air_hz = 8000.0, .air_mix = 0.15 });
}
fn hihatBoombapOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.28, .decay = 12.0, .body_hz = 5800.0, .air_hz = 8000.0, .air_mix = 0.15 });
}
fn clapBoombap(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 2600.0, .hp_hz = 1000.0, .burst_decay = 200.0, .tail_decay = 14.0, .tail_mix = 0.4, .dur_s = 0.28,
    });
}
fn tomBoombap1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 200.0, .freq_end = 100.0, .dur_s = 0.35, .body_decay = 7.0,
        .attack_decay = 110.0, .drive = 2.0, .attack_mix = 0.15, .seed = 0x741,
    });
}
fn tomBoombap2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 140.0, .freq_end = 70.0, .dur_s = 0.42, .body_decay = 6.0,
        .attack_decay = 110.0, .drive = 2.0, .attack_mix = 0.15, .seed = 0x742,
    });
}
fn rimBoombap(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 1550.0, .tone2_hz = 1000.0, .tone_decay = 140.0, .click_decay = 280.0, .drive = 2.2, .dur_s = 0.07,
    });
}

// G-funk: long analog boom kick, dry cracking snare, tight crisp hats, a
// snap-forward clap. The low end sustains; everything above it stays short.
fn kickGfunk(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 46.0, .freq_start_add = 75.0, .pitch_decay = 35.0, .body_decay = 4.5,
        .click_decay = 420.0, .click_freq = 1400.0, .click_mix = 0.2, .drive = 3.4, .dur_s = 0.7,
    });
}
fn snareGfunk(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 175.0, .tone2_hz = 250.0, .tone_decay = 22.0, .noise_decay = 15.0,
        .drive = 1.9, .dur_s = 0.25, .lp_hz = 7000.0, .hp_hz = 1000.0,
    });
}
fn hihatGfunkClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.05, .decay = 120.0, .body_hz = 6200.0, .air_hz = 8500.0, .air_mix = 0.2 });
}
fn hihatGfunkOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.3, .decay = 11.0, .body_hz = 6200.0, .air_hz = 8500.0, .air_mix = 0.2 });
}
fn clapGfunk(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 2800.0, .hp_hz = 1100.0, .burst_decay = 210.0, .tail_decay = 15.0, .tail_mix = 0.45, .dur_s = 0.3,
    });
}
fn tomGfunk1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 170.0, .freq_end = 85.0, .dur_s = 0.55, .body_decay = 4.5,
        .attack_decay = 110.0, .drive = 2.0, .attack_mix = 0.1, .seed = 0x751,
    });
}
fn tomGfunk2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 120.0, .freq_end = 60.0, .dur_s = 0.65, .body_decay = 4.0,
        .attack_decay = 110.0, .drive = 2.0, .attack_mix = 0.1, .seed = 0x752,
    });
}
fn rimGfunk(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 1650.0, .tone2_hz = 1080.0, .tone_decay = 150.0, .click_decay = 300.0, .drive = 2.0, .dur_s = 0.07,
    });
}

// City-pop: dry late-70s/80s studio character — punchy definite kick, a fat
// snare cut short as if gated, clean hats, tight room clap, disco-ish toms.
fn kickCitypop(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 60.0, .freq_start_add = 140.0, .pitch_decay = 65.0, .body_decay = 16.0,
        .click_decay = 320.0, .click_freq = 1800.0, .click_mix = 0.7, .drive = 2.0, .dur_s = 0.25,
    });
}
fn snareCitypop(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 195.0, .tone2_hz = 285.0, .tone_decay = 26.0, .noise_decay = 12.0,
        .drive = 1.6, .dur_s = 0.2, .lp_hz = 7500.0, .hp_hz = 950.0,
    });
}
fn hihatCitypopClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.055, .decay = 100.0, .body_hz = 6800.0, .air_hz = 9500.0, .air_mix = 0.35 });
}
fn hihatCitypopOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.32, .decay = 10.0, .body_hz = 6800.0, .air_hz = 9500.0, .air_mix = 0.35 });
}
fn clapCitypop(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 3200.0, .hp_hz = 1200.0, .burst_decay = 240.0, .tail_decay = 20.0, .tail_mix = 0.3, .dur_s = 0.24,
    });
}
fn tomCitypop1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 240.0, .freq_end = 130.0, .dur_s = 0.32, .body_decay = 8.0,
        .attack_decay = 130.0, .drive = 1.6, .attack_mix = 0.15, .seed = 0x761,
    });
}
fn tomCitypop2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 175.0, .freq_end = 95.0, .dur_s = 0.38, .body_decay = 7.0,
        .attack_decay = 130.0, .drive = 1.6, .attack_mix = 0.15, .seed = 0x762,
    });
}
fn rimCitypop(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 1850.0, .tone2_hz = 1200.0, .tone_decay = 140.0, .click_decay = 300.0, .drive = 1.9, .dur_s = 0.06,
    });
}

// Technopop: precise early-machine minimalism — short clicky kick, thin
// noise-forward snare, needle-fine hats, synthetic disco-tom sweeps.
fn kickTechnopop(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 55.0, .freq_start_add = 120.0, .pitch_decay = 80.0, .body_decay = 18.0,
        .click_decay = 300.0, .click_freq = 2400.0, .click_mix = 0.9, .drive = 1.8, .dur_s = 0.18,
    });
}
fn snareTechnopop(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 180.0, .tone2_hz = 320.0, .tone_decay = 35.0, .noise_decay = 20.0,
        .drive = 1.3, .dur_s = 0.18, .lp_hz = 9000.0, .hp_hz = 1100.0,
    });
}
fn hihatTechnopopClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.04, .decay = 150.0, .body_hz = 7500.0, .air_hz = 10_500.0, .air_mix = 0.25 });
}
fn hihatTechnopopOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.25, .decay = 14.0, .body_hz = 7500.0, .air_hz = 10_500.0, .air_mix = 0.25 });
}
fn clapTechnopop(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 3400.0, .hp_hz = 1400.0, .burst_decay = 280.0, .tail_decay = 24.0, .tail_mix = 0.3, .dur_s = 0.2,
    });
}
fn tomTechnopop1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 300.0, .freq_end = 150.0, .dur_s = 0.25, .body_decay = 10.0,
        .attack_decay = 150.0, .drive = 1.4, .attack_mix = 0.08, .seed = 0x771,
    });
}
fn tomTechnopop2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 220.0, .freq_end = 110.0, .dur_s = 0.3, .body_decay = 9.0,
        .attack_decay = 150.0, .drive = 1.4, .attack_mix = 0.08, .seed = 0x772,
    });
}
fn rimTechnopop(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 2000.0, .tone2_hz = 1300.0, .tone_decay = 160.0, .click_decay = 320.0, .drive = 1.7, .dur_s = 0.05,
    });
}

// Kawaii: everything tuned up and cut tight — bouncy mid-weight kick, bright
// snappy snare, sparkly airy hats, cute high toms.
fn kickKawaii(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 68.0, .freq_start_add = 160.0, .pitch_decay = 75.0, .body_decay = 17.0,
        .click_decay = 340.0, .click_freq = 2100.0, .click_mix = 0.55, .drive = 2.3, .dur_s = 0.22,
    });
}
fn snareKawaii(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 220.0, .tone2_hz = 330.0, .tone_decay = 30.0, .noise_decay = 16.0,
        .drive = 1.7, .dur_s = 0.2, .lp_hz = 10_000.0, .hp_hz = 1200.0,
    });
}
fn hihatKawaiiClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.04, .decay = 140.0, .body_hz = 8000.0, .air_hz = 11_000.0, .air_mix = 0.45 });
}
fn hihatKawaiiOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.24, .decay = 13.0, .body_hz = 8000.0, .air_hz = 11_000.0, .air_mix = 0.45 });
}
fn clapKawaii(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 3800.0, .hp_hz = 1400.0, .burst_decay = 260.0, .tail_decay = 18.0, .tail_mix = 0.45, .dur_s = 0.26,
    });
}
fn tomKawaii1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 340.0, .freq_end = 190.0, .dur_s = 0.22, .body_decay = 11.0,
        .attack_decay = 140.0, .drive = 1.6, .attack_mix = 0.12, .seed = 0x781,
    });
}
fn tomKawaii2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 260.0, .freq_end = 140.0, .dur_s = 0.26, .body_decay = 10.0,
        .attack_decay = 140.0, .drive = 1.6, .attack_mix = 0.12, .seed = 0x782,
    });
}
fn rimKawaii(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 2100.0, .tone2_hz = 1400.0, .tone_decay = 170.0, .click_decay = 340.0, .drive = 1.9, .dur_s = 0.05,
    });
}

// Vaporwave: everything behind a closed door — round clickless kick, muffled
// lazy snare, dull hats with a long wash, roomy clap that's mostly tail.
fn kickVaporwave(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 50.0, .freq_start_add = 60.0, .pitch_decay = 28.0, .body_decay = 8.0,
        .click_decay = 500.0, .click_freq = 900.0, .click_mix = 0.08, .drive = 2.0, .dur_s = 0.5,
    });
}
fn snareVaporwave(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 155.0, .tone2_hz = 225.0, .tone_decay = 16.0, .noise_decay = 10.0,
        .drive = 1.2, .dur_s = 0.35, .lp_hz = 4500.0, .hp_hz = 600.0,
    });
}
fn hihatVaporwaveClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.07, .decay = 80.0, .body_hz = 4800.0, .air_hz = 7000.0, .air_mix = 0.15 });
}
fn hihatVaporwaveOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.5, .decay = 6.0, .body_hz = 4800.0, .air_hz = 7000.0, .air_mix = 0.15 });
}
fn clapVaporwave(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 2200.0, .hp_hz = 800.0, .burst_decay = 160.0, .tail_decay = 9.0, .tail_mix = 0.75, .dur_s = 0.5,
    });
}
fn tomVaporwave1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 190.0, .freq_end = 95.0, .dur_s = 0.5, .body_decay = 4.5,
        .attack_decay = 90.0, .drive = 1.4, .attack_mix = 0.06, .seed = 0x791,
    });
}
fn tomVaporwave2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 140.0, .freq_end = 70.0, .dur_s = 0.6, .body_decay = 4.0,
        .attack_decay = 90.0, .drive = 1.4, .attack_mix = 0.06, .seed = 0x792,
    });
}
fn rimVaporwave(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 1400.0, .tone2_hz = 900.0, .tone_decay = 100.0, .click_decay = 200.0, .drive = 1.4, .dur_s = 0.08,
    });
}

// Eurobeat: full-throttle dance floor — hard four-on-the-floor kick, big
// driven snare, loud sustained open hat for the offbeats, energetic clap.
fn kickEurobeat(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 52.0, .freq_start_add = 145.0, .pitch_decay = 58.0, .body_decay = 12.0,
        .click_decay = 300.0, .click_freq = 1900.0, .click_mix = 0.65, .drive = 3.0, .dur_s = 0.3,
    });
}
fn snareEurobeat(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 190.0, .tone2_hz = 280.0, .tone_decay = 25.0, .noise_decay = 18.0,
        .drive = 2.0, .dur_s = 0.26, .lp_hz = 9500.0, .hp_hz = 1000.0,
    });
}
fn hihatEurobeatClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.05, .decay = 110.0, .body_hz = 7200.0, .air_hz = 10_000.0, .air_mix = 0.35 });
}
fn hihatEurobeatOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.4, .decay = 7.5, .body_hz = 7200.0, .air_hz = 10_000.0, .air_mix = 0.35 });
}
fn clapEurobeat(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 3000.0, .hp_hz = 1100.0, .burst_decay = 220.0, .tail_decay = 13.0, .tail_mix = 0.55, .dur_s = 0.34,
    });
}
fn tomEurobeat1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 230.0, .freq_end = 115.0, .dur_s = 0.35, .body_decay = 7.0,
        .attack_decay = 120.0, .drive = 1.9, .attack_mix = 0.14, .seed = 0x7a1,
    });
}
fn tomEurobeat2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 165.0, .freq_end = 85.0, .dur_s = 0.42, .body_decay = 6.0,
        .attack_decay = 120.0, .drive = 1.9, .attack_mix = 0.14, .seed = 0x7a2,
    });
}
fn rimEurobeat(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 1700.0, .tone2_hz = 1150.0, .tone_decay = 150.0, .click_decay = 300.0, .drive = 2.0, .dur_s = 0.06,
    });
}

// Hardcore/j-core: gabber-style hard-clipped kick with a fast pitch drop and
// a bright screaming click, everything else short and needle-sharp to keep
// up at 170+ BPM.
fn kickHardcore(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return kickGen(allocator, sr, .{
        .freq_end = 58.0, .freq_start_add = 220.0, .pitch_decay = 95.0, .body_decay = 9.0,
        .click_decay = 180.0, .click_freq = 2400.0, .click_mix = 0.85, .drive = 7.5, .dur_s = 0.22,
    });
}
fn snareHardcore(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return snareGen(allocator, sr, .{
        .tone1_hz = 215.0, .tone2_hz = 320.0, .tone_decay = 22.0, .noise_decay = 22.0,
        .drive = 3.4, .dur_s = 0.2, .lp_hz = 10_000.0, .hp_hz = 1300.0,
    });
}
fn hihatHardcoreClosed(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.032, .decay = 170.0, .body_hz = 8200.0, .air_hz = 11_500.0, .air_mix = 0.4 });
}
fn hihatHardcoreOpen(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return metalHat(allocator, sr, .{ .dur_s = 0.2, .decay = 16.0, .body_hz = 8200.0, .air_hz = 11_500.0, .air_mix = 0.4 });
}
fn clapHardcore(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return clapGen(allocator, sr, .{
        .lp_hz = 3600.0, .hp_hz = 1500.0, .burst_decay = 280.0, .tail_decay = 20.0, .tail_mix = 0.3, .dur_s = 0.2,
    });
}
fn tomHardcore1(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 280.0, .freq_end = 150.0, .dur_s = 0.24, .body_decay = 10.0,
        .attack_decay = 150.0, .drive = 3.2, .attack_mix = 0.2, .seed = 0x7b1,
    });
}
fn tomHardcore2(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return tomGen(allocator, sr, .{
        .freq_start = 200.0, .freq_end = 100.0, .dur_s = 0.28, .body_decay = 9.0,
        .attack_decay = 150.0, .drive = 3.2, .attack_mix = 0.2, .seed = 0x7b2,
    });
}
fn rimHardcore(allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return rimGen(allocator, sr, .{
        .tone1_hz = 2000.0, .tone2_hz = 1350.0, .tone_decay = 170.0, .click_decay = 280.0, .drive = 3.5, .dur_s = 0.045,
    });
}
// zig fmt: on

/// One pad slot in a runtime kit variant: display name, generator, and
/// default mixer gain — the same shape as `PadDef` minus the WAV filename
/// (these are never written to disk).
pub const VariantSlot = struct {
    name: []const u8,
    gen: *const fn (std.mem.Allocator, u32) std.mem.Allocator.Error![]f32,
    gain: f32,
};

pub const KitVariant = struct {
    name: []const u8,
    /// Sound character, not genre — mirrors `synth_presets.Preset.category`.
    category: []const u8,
    /// First tag is always "wstudio"; the rest are genre associations.
    tags: []const []const u8,
    pads: [8]VariantSlot,
};

pub const variants = [_]KitVariant{
    .{ .name = "default", .category = "digital", .tags = &.{ "wstudio", "house" }, .pads = .{
        .{ .name = "kick", .gen = kick, .gain = 1.00 },
        .{ .name = "snare", .gen = snare, .gain = 0.85 },
        .{ .name = "hihat", .gen = hihatClosed, .gain = 0.50 },
        .{ .name = "open", .gen = hihatOpen, .gain = 0.50 },
        .{ .name = "clap", .gen = clap, .gain = 0.70 },
        .{ .name = "tom-1", .gen = tom1, .gain = 0.80 },
        .{ .name = "tom-2", .gen = tom2, .gain = 0.80 },
        .{ .name = "rim", .gen = rim, .gain = 0.65 },
    } },
    .{ .name = "analog", .category = "analog", .tags = &.{ "wstudio", "techno" }, .pads = .{
        .{ .name = "kick", .gen = kickAnalog, .gain = 1.00 },
        .{ .name = "snare", .gen = snareAnalog, .gain = 0.80 },
        .{ .name = "hihat", .gen = hihatAnalogClosed, .gain = 0.45 },
        .{ .name = "open", .gen = hihatAnalogOpen, .gain = 0.45 },
        .{ .name = "clap", .gen = clapAnalog, .gain = 0.65 },
        .{ .name = "tom-1", .gen = tomAnalog1, .gain = 0.85 },
        .{ .name = "tom-2", .gen = tomAnalog2, .gain = 0.85 },
        .{ .name = "rim", .gen = rimAnalog, .gain = 0.60 },
    } },
    .{ .name = "acoustic", .category = "acoustic", .tags = &.{ "wstudio", "rock" }, .pads = .{
        .{ .name = "kick", .gen = kickAcoustic, .gain = 1.00 },
        .{ .name = "snare", .gen = snareAcoustic, .gain = 0.90 },
        .{ .name = "hihat", .gen = hihatAcousticClosed, .gain = 0.55 },
        .{ .name = "open", .gen = hihatAcousticOpen, .gain = 0.55 },
        .{ .name = "clap", .gen = clapAcoustic, .gain = 0.65 },
        .{ .name = "tom-1", .gen = tomAcoustic1, .gain = 0.80 },
        .{ .name = "tom-2", .gen = tomAcoustic2, .gain = 0.80 },
        .{ .name = "rim", .gen = rimAcoustic, .gain = 0.70 },
    } },
    .{ .name = "industrial", .category = "industrial", .tags = &.{ "wstudio", "techno" }, .pads = .{
        .{ .name = "kick", .gen = kickIndustrial, .gain = 1.00 },
        .{ .name = "snare", .gen = snareIndustrial, .gain = 0.85 },
        .{ .name = "hihat", .gen = hihatIndustrialClosed, .gain = 0.50 },
        .{ .name = "open", .gen = hihatIndustrialOpen, .gain = 0.50 },
        .{ .name = "clap", .gen = clapIndustrial, .gain = 0.70 },
        .{ .name = "tom-1", .gen = tomIndustrial1, .gain = 0.85 },
        .{ .name = "tom-2", .gen = tomIndustrial2, .gain = 0.85 },
        .{ .name = "rim", .gen = rimIndustrial, .gain = 0.65 },
    } },
    .{ .name = "boombap", .category = "vinyl", .tags = &.{ "wstudio", "hip-hop", "boom-bap" }, .pads = .{
        .{ .name = "kick", .gen = kickBoombap, .gain = 1.00 },
        .{ .name = "snare", .gen = snareBoombap, .gain = 0.85 },
        .{ .name = "hihat", .gen = hihatBoombapClosed, .gain = 0.45 },
        .{ .name = "open", .gen = hihatBoombapOpen, .gain = 0.45 },
        .{ .name = "clap", .gen = clapBoombap, .gain = 0.65 },
        .{ .name = "tom-1", .gen = tomBoombap1, .gain = 0.80 },
        .{ .name = "tom-2", .gen = tomBoombap2, .gain = 0.80 },
        .{ .name = "rim", .gen = rimBoombap, .gain = 0.60 },
    } },
    .{ .name = "gfunk", .category = "analog", .tags = &.{ "wstudio", "hip-hop", "g-funk" }, .pads = .{
        .{ .name = "kick", .gen = kickGfunk, .gain = 1.00 },
        .{ .name = "snare", .gen = snareGfunk, .gain = 0.88 },
        .{ .name = "hihat", .gen = hihatGfunkClosed, .gain = 0.45 },
        .{ .name = "open", .gen = hihatGfunkOpen, .gain = 0.45 },
        .{ .name = "clap", .gen = clapGfunk, .gain = 0.75 },
        .{ .name = "tom-1", .gen = tomGfunk1, .gain = 0.80 },
        .{ .name = "tom-2", .gen = tomGfunk2, .gain = 0.80 },
        .{ .name = "rim", .gen = rimGfunk, .gain = 0.60 },
    } },
    .{ .name = "citypop", .category = "digital", .tags = &.{ "wstudio", "city-pop", "funk" }, .pads = .{
        .{ .name = "kick", .gen = kickCitypop, .gain = 1.00 },
        .{ .name = "snare", .gen = snareCitypop, .gain = 0.90 },
        .{ .name = "hihat", .gen = hihatCitypopClosed, .gain = 0.50 },
        .{ .name = "open", .gen = hihatCitypopOpen, .gain = 0.50 },
        .{ .name = "clap", .gen = clapCitypop, .gain = 0.60 },
        .{ .name = "tom-1", .gen = tomCitypop1, .gain = 0.85 },
        .{ .name = "tom-2", .gen = tomCitypop2, .gain = 0.85 },
        .{ .name = "rim", .gen = rimCitypop, .gain = 0.70 },
    } },
    .{ .name = "technopop", .category = "digital", .tags = &.{ "wstudio", "technopop", "synth-pop" }, .pads = .{
        .{ .name = "kick", .gen = kickTechnopop, .gain = 1.00 },
        .{ .name = "snare", .gen = snareTechnopop, .gain = 0.85 },
        .{ .name = "hihat", .gen = hihatTechnopopClosed, .gain = 0.50 },
        .{ .name = "open", .gen = hihatTechnopopOpen, .gain = 0.50 },
        .{ .name = "clap", .gen = clapTechnopop, .gain = 0.65 },
        .{ .name = "tom-1", .gen = tomTechnopop1, .gain = 0.80 },
        .{ .name = "tom-2", .gen = tomTechnopop2, .gain = 0.80 },
        .{ .name = "rim", .gen = rimTechnopop, .gain = 0.65 },
    } },
    .{ .name = "kawaii", .category = "digital", .tags = &.{ "wstudio", "kawaii", "pop" }, .pads = .{
        .{ .name = "kick", .gen = kickKawaii, .gain = 1.00 },
        .{ .name = "snare", .gen = snareKawaii, .gain = 0.85 },
        .{ .name = "hihat", .gen = hihatKawaiiClosed, .gain = 0.50 },
        .{ .name = "open", .gen = hihatKawaiiOpen, .gain = 0.50 },
        .{ .name = "clap", .gen = clapKawaii, .gain = 0.70 },
        .{ .name = "tom-1", .gen = tomKawaii1, .gain = 0.80 },
        .{ .name = "tom-2", .gen = tomKawaii2, .gain = 0.80 },
        .{ .name = "rim", .gen = rimKawaii, .gain = 0.65 },
    } },
    .{ .name = "vaporwave", .category = "tape", .tags = &.{ "wstudio", "vaporwave", "chill" }, .pads = .{
        .{ .name = "kick", .gen = kickVaporwave, .gain = 1.00 },
        .{ .name = "snare", .gen = snareVaporwave, .gain = 0.80 },
        .{ .name = "hihat", .gen = hihatVaporwaveClosed, .gain = 0.40 },
        .{ .name = "open", .gen = hihatVaporwaveOpen, .gain = 0.40 },
        .{ .name = "clap", .gen = clapVaporwave, .gain = 0.60 },
        .{ .name = "tom-1", .gen = tomVaporwave1, .gain = 0.75 },
        .{ .name = "tom-2", .gen = tomVaporwave2, .gain = 0.75 },
        .{ .name = "rim", .gen = rimVaporwave, .gain = 0.55 },
    } },
    .{ .name = "eurobeat", .category = "digital", .tags = &.{ "wstudio", "eurobeat", "dance" }, .pads = .{
        .{ .name = "kick", .gen = kickEurobeat, .gain = 1.00 },
        .{ .name = "snare", .gen = snareEurobeat, .gain = 0.88 },
        .{ .name = "hihat", .gen = hihatEurobeatClosed, .gain = 0.50 },
        .{ .name = "open", .gen = hihatEurobeatOpen, .gain = 0.55 },
        .{ .name = "clap", .gen = clapEurobeat, .gain = 0.70 },
        .{ .name = "tom-1", .gen = tomEurobeat1, .gain = 0.80 },
        .{ .name = "tom-2", .gen = tomEurobeat2, .gain = 0.80 },
        .{ .name = "rim", .gen = rimEurobeat, .gain = 0.65 },
    } },
    .{ .name = "hardcore", .category = "distorted", .tags = &.{ "wstudio", "j-core", "hardcore" }, .pads = .{
        .{ .name = "kick", .gen = kickHardcore, .gain = 1.00 },
        .{ .name = "snare", .gen = snareHardcore, .gain = 0.85 },
        .{ .name = "hihat", .gen = hihatHardcoreClosed, .gain = 0.45 },
        .{ .name = "open", .gen = hihatHardcoreOpen, .gain = 0.45 },
        .{ .name = "clap", .gen = clapHardcore, .gain = 0.70 },
        .{ .name = "tom-1", .gen = tomHardcore1, .gain = 0.80 },
        .{ .name = "tom-2", .gen = tomHardcore2, .gain = 0.80 },
        .{ .name = "rim", .gen = rimHardcore, .gain = 0.60 },
    } },
};

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

test "every kit variant's pads produce audible, finite output" {
    for (variants) |variant| {
        for (variant.pads) |slot| {
            const buf = try slot.gen(std.testing.allocator, 48_000);
            defer std.testing.allocator.free(buf);
            try std.testing.expect(buf.len > 0);
            var peak: f32 = 0;
            for (buf) |s| {
                try std.testing.expect(std.math.isFinite(s));
                peak = @max(peak, @abs(s));
            }
            try std.testing.expect(peak > 0.05);
        }
    }
}
