//! Drum-kit synthesis - the generators behind every factory kit flavour.
//!
//! These generators are richer than the first-iteration one-shots: layered
//! transients, inharmonic metal clusters, multi-burst claps, tuned bodies and
//! soft saturation. They run straight into pad buffers when the user picks a
//! kit (see `variants` and `DrumMachine.loadKitVariant`) - nothing is embedded
//! or read from disk. Keep them allocation-light and deterministic.
//!
//! `chipGen` is the deliberate exception and is poorer on purpose: it is a
//! console sound chip's three voices, quantised the way the hardware
//! quantises, because for that kit the limits are the instrument.

const std = @import("std");

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
/// the pad's mixer gain (see `VariantSlot.gain`).
fn normalize(buf: []f32, target: f32) void {
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    if (peak <= 1e-9) return;
    const g = target / peak;
    for (buf) |*s| s.* *= g;
}

// ---------------------------------------------------------------------------
// Generators

/// Tunable knobs behind `kick()` - see `kickGen`. Defaults reproduce the
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
    // Short buffer - no long sub tail.
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var prng = std.Random.DefaultPrng.init(0x4b1c);
    const rand = prng.random();
    var phase: f32 = 0;
    var click_hp: OnePole = .{};
    const click_a = cutoffAlpha(1200.0, srf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        // Body: fast, deep pitch drop - punch, not a held sub tone.
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

/// Tunable knobs behind `snare()` - see `snareGen`. Defaults reproduce the
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

/// Two-detuned-sine "shell" tone, exponentially decaying - shared by
/// snareGen and rimGen. Advances and wraps the caller's own phase
/// accumulators (`p1`/`p2`) in place.
///
/// `decay2` is the upper partial's own rate. On anything struck, the higher
/// mode is damped harder and dies first, which is why a drum reads as a drum
/// and not as a two-note chime; passing the same rate for both (what every
/// caller did before percussion needed otherwise) keeps the old behaviour.
fn twoToneBody(p1: *f32, p2: *f32, hz1: f32, hz2: f32, srf: f32, t: f32, decay: f32, decay2: f32) f32 {
    const tone = @sin(tau * p1.*) * 0.6 * expEnv(t, decay) + @sin(tau * p2.*) * 0.4 * expEnv(t, decay2);
    p1.* += hz1 / srf;
    p2.* += hz2 / srf;
    if (p1.* >= 1.0) p1.* -= 1.0;
    if (p2.* >= 1.0) p2.* -= 1.0;
    return tone;
}

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
        const tone = twoToneBody(&p1, &p2, p.tone1_hz, p.tone2_hz, srf, t, p.tone_decay, p.tone_decay);
        // Snare buzz: noise band-passed ~0.9–8.5 kHz, slightly longer decay.
        const n = rand.float(f32) * 2.0 - 1.0;
        const noise = hp.hp(lp.lp(n, lp_a), hp_a) * expEnv(t, p.noise_decay);
        const mix = tone * 0.5 + noise * 0.85;
        s.* = saturate(mud.hp(mix, mud_a), p.drive);
    }
    normalize(buf, 0.95);
    return buf;
}

/// Tunable knobs behind the hihats - see `metalHat`.
pub const HatParams = struct {
    dur_s: f32 = 0.09,
    decay: f32 = 65.0,
    body_hz: f32 = 6500.0,
    air_hz: f32 = 9000.0,
    air_mix: f32 = 0.3,
    /// Stick-hit layer, on top of the wash. A closed hat is already all
    /// transient, so this stays off (mix 0) there and only the long, slow
    /// crashes switch it on - see `metalHat`.
    attack_decay: f32 = 240.0,
    attack_mix: f32 = 0.0,
    /// Teeth per second, for the one instrument here that is scraped rather
    /// than shaken or struck. A guiro's sound is not a wash: it is a train of
    /// separate clicks as the pua crosses the ridges, and the rate of that
    /// train is what tells a long scrape from a short one. 0 leaves the wash
    /// continuous, which is every other pad.
    ratchet_hz: f32 = 0.0,
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
    var hit_hp: OnePole = .{};
    var tooth_phase: f32 = 0.0;
    const body_a = cutoffAlpha(p.body_hz, srf);
    const air_a = cutoffAlpha(p.air_hz, srf);
    const hit_a = cutoffAlpha(1500.0, srf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        var cluster: f32 = 0;
        inline for (0..6) |k| {
            cluster += square(ph[k]);
            ph[k] += freqs[k] / srf;
            if (ph[k] >= 1.0) ph[k] -= 1.0;
        }
        cluster /= 6.0;
        const n = rand.float(f32) * 2.0 - 1.0;
        const metal = body_hp.hp(cluster, body_a);
        const air = air_hp.hp(n, air_a) * p.air_mix;
        // Stick hit: the 1.5 kHz-and-up mid band that `body_hz` throws away,
        // gated to a few ms. A slow crash decay without it opens at full wash
        // level, so there is no strike to hear and the hit reads as soft.
        const hit = hit_hp.hp(cluster + n, hit_a) * expEnv(t, p.attack_decay) * p.attack_mix;
        // Each tooth is a short burst, not a gap in a continuous noise: the
        // ridge is struck, rings for a moment and is left behind.
        var gate: f32 = 1.0;
        if (p.ratchet_hz > 0.0) {
            tooth_phase += p.ratchet_hz / srf;
            tooth_phase -= @floor(tooth_phase);
            gate = 0.12 + 0.88 * expEnv(tooth_phase / p.ratchet_hz, p.ratchet_hz * 6.0);
        }
        s.* = ((metal + air) * expEnv(t, p.decay) + hit) * gate;
    }
    normalize(buf, 0.85);
    return buf;
}

/// Tunable knobs behind `clap()` - see `clapGen`. Defaults reproduce the
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

/// Tunable knobs behind the toms - see `tomGen`.
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

/// Tunable knobs behind the perc-hi/perc-lo voices - see `percGen`. Unlike
/// `TomParams`, pitch is fixed rather than swept: a tom is defined by its
/// downward glide, a hand-perc hit (conga/timbale) is defined by NOT having
/// one, so this is what actually makes perc-hi/perc-lo read as a different
/// instrument instead of a retuned tom.
pub const PercParams = struct {
    tone1_hz: f32,
    tone2_hz: f32,
    body_decay: f32 = 30.0,
    slap_decay: f32 = 220.0,
    slap_mix: f32 = 0.4,
    /// The upper partial's decay as a multiple of `body_decay`. A struck
    /// membrane's (1,1) mode is damped harder than its fundamental and dies
    /// first; 1.0 is the old behaviour, where both rang equally.
    tone2_decay_mul: f32 = 1.0,
    drive: f32 = 1.6,
    dur_s: f32 = 0.16,
    seed: u64,
};

/// Fixed-pitch two-tone struck body (see `twoToneBody`, shared with
/// snareGen/rimGen) plus a short highpassed noise slap, saturated. No pitch
/// sweep - that's the tom's signature move, not this one's.
fn percGen(allocator: std.mem.Allocator, sr: u32, p: PercParams) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var prng = std.Random.DefaultPrng.init(p.seed);
    const rand = prng.random();
    var p1: f32 = 0;
    var p2: f32 = 0;
    var hp: OnePole = .{};
    const hp_a = cutoffAlpha(2200.0, srf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        const body = twoToneBody(&p1, &p2, p.tone1_hz, p.tone2_hz, srf, t, p.body_decay, p.body_decay * p.tone2_decay_mul);
        const slap = hp.hp(rand.float(f32) * 2.0 - 1.0, hp_a) * expEnv(t, p.slap_decay) * p.slap_mix;
        s.* = saturate((body + slap) * p.drive, 1.0);
    }
    normalize(buf, 0.93);
    return buf;
}

/// Tunable knobs behind `rim()` - see `rimGen`. Defaults reproduce the
/// original shipped rim exactly.
pub const RimParams = struct {
    tone1_hz: f32 = 1720.0,
    tone2_hz: f32 = 1130.0,
    tone_decay: f32 = 150.0,
    /// As `PercParams.tone2_decay_mul` - a struck bar's upper mode dies first
    /// too, and by more, since it is nearly three times the frequency.
    tone2_decay_mul: f32 = 1.0,
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
        const tone = twoToneBody(&p1, &p2, p.tone1_hz, p.tone2_hz, srf, t, p.tone_decay, p.tone_decay * p.tone2_decay_mul);
        const click = (rand.float(f32) * 2.0 - 1.0) * expEnv(t, p.click_decay) * 0.5;
        s.* = saturate((tone + click) * p.drive, 1.0);
    }
    normalize(buf, 0.9);
    return buf;
}

// ---------------------------------------------------------------------------
// Chip voice
//
// The generators above model drums: a struck body, a shell, a metal cluster.
// A chip has none of that. A 2A03 has three things a drum can be made of - a
// pulse channel with four duty cycles, a 4-bit stepped triangle, and a noise
// channel that is a shift register clocked at one of sixteen fixed rates -
// and every level it emits is one of sixteen. Rendering chip drums through
// the analog generators gets the rhythm right and the sound wrong, because
// the sound IS the quantisation: sixteen noise colours instead of a filter
// sweep, sixteen volume steps instead of a smooth decay, a pitch that can
// only land on the timer values the chip can count to.

/// The noise channel's sixteen timer periods in CPU cycles (NTSC). There is
/// no continuous control here: these are the only sixteen noise colours the
/// chip can make, which is why every chip hat and snare sounds related.
const nes_noise_periods = [16]f32{ 4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068 };
const nes_cpu_hz: f32 = 1_789_773.0;
/// The APU's envelope/sweep units are clocked by the frame counter, not by
/// the sample: volume steps at 240 Hz and pitch at 120 Hz, which is what
/// makes a chip decay audibly staircase rather than glide.
const nes_env_hz: f32 = 240.0;
const nes_sweep_hz: f32 = 120.0;

/// The noise channel's 15-bit shift register. Feedback is bit 0 XOR bit 1,
/// or bit 0 XOR bit 6 in short mode - which shortens the sequence from 32767
/// steps to 93 and turns hiss into a pitched metallic rattle. That short mode
/// is where a chip snare's buzz comes from.
const Lfsr = struct {
    reg: u16 = 1,
    short: bool = false,

    fn next(self: *Lfsr) f32 {
        const tap: u16 = if (self.short) (self.reg >> 6) & 1 else (self.reg >> 1) & 1;
        const fb: u16 = (self.reg & 1) ^ tap;
        self.reg = ((self.reg >> 1) | (fb << 14)) & 0x7FFF;
        // The channel is silent while bit 0 is set and at full level when it
        // is clear - a two-level output, not a noise floor.
        return if (self.reg & 1 == 0) 1.0 else -1.0;
    }
};

/// Snap a frequency to what the chip's 11-bit timer can actually count.
/// `divider` is 16 for the pulse channels and 32 for the triangle. High notes
/// land visibly off-pitch this way, which is a chip's own out-of-tuneness and
/// not an error to correct.
fn nesTimerFreq(hz: f32, divider: f32) f32 {
    const period = std.math.clamp(@round(nes_cpu_hz / (divider * @max(hz, 1.0)) - 1.0), 8.0, 2047.0);
    return nes_cpu_hz / (divider * (period + 1.0));
}

pub const ChipSource = enum { noise, pulse, triangle };

/// Tunable knobs behind `chipGen`. One generator covers every pad because
/// the chip does: a drum is a channel, an envelope and a duration.
pub const ChipParams = struct {
    source: ChipSource = .noise,
    /// Index into `nes_noise_periods`: 0 is the brightest hiss, 15 a slow
    /// crackle. Swept linearly to `noise_index_end` across the hit, which is
    /// the tracker's pitch macro on the noise channel.
    noise_index: u8 = 0,
    noise_index_end: ?u8 = null,
    /// 93-step register instead of 32767: buzz instead of hiss.
    short: bool = false,
    /// `pulse`/`triangle` only: pitch falls from `freq_start` toward
    /// `freq_end`, exponentially at `pitch_decay`.
    freq_start: f32 = 220.0,
    freq_end: f32 = 110.0,
    pitch_decay: f32 = 60.0,
    /// Pulse duty. The chip offers 0.125, 0.25, 0.5 and 0.75 - nothing else.
    duty: f32 = 0.5,
    /// Noise struck together with a tone pad, which on hardware means a
    /// second channel triggered on the same row. This is how a tracker gets
    /// an attack onto a triangle kick.
    noise_mix: f32 = 0.0,
    /// That second channel's own decay. It is a different channel with a
    /// different envelope, so it dies while the tone is still ringing -
    /// which is what makes the noise read as the attack of the drum rather
    /// than as hiss laid over it.
    noise_decay: f32 = 300.0,
    /// Volume envelope decay rate, before the 240 Hz staircase.
    decay: f32 = 60.0,
    /// Retriggers of the whole envelope, `burst_gap_s` apart - a chip clap is
    /// the same noise hit written three rows in a row.
    bursts: u8 = 1,
    burst_gap_s: f32 = 0.012,
    dur_s: f32 = 0.1,
    /// Shift-register start state. Hardware resets to 1; varying it is how
    /// two noise pads avoid being the same sequence twice.
    seed: u16 = 1,
};

fn chipGen(allocator: std.mem.Allocator, sr: u32, p: ChipParams) std.mem.Allocator.Error![]f32 {
    const srf: f32 = @floatFromInt(sr);
    const buf = try allocator.alloc(f32, frames(sr, p.dur_s));
    var noise: Lfsr = .{ .reg = if (p.seed & 0x7FFF == 0) 1 else p.seed & 0x7FFF, .short = p.short };
    var noise_phase: f32 = 0.0;
    var noise_level: f32 = 1.0;
    var tone_phase: f32 = 0.0;
    const idx_start: f32 = @floatFromInt(@min(p.noise_index, 15));
    const idx_end: f32 = @floatFromInt(@min(p.noise_index_end orelse p.noise_index, 15));

    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / srf;
        const norm = std.math.clamp(t / p.dur_s, 0.0, 1.0);
        // Envelope: held for a whole 240 Hz frame, then rounded to one of the
        // sixteen levels the DAC has.
        const t_env = @floor(t * nes_env_hz) / nes_env_hz;
        var env: f32 = 0.0;
        for (0..@max(p.bursts, 1)) |b| {
            const tb = t_env - @as(f32, @floatFromInt(b)) * p.burst_gap_s;
            if (tb >= 0.0) env = @max(env, expEnv(tb, p.decay));
        }
        env = @floor(env * 15.0) / 15.0;

        // Noise runs for every pad: on its own for the hats and snares, and
        // under the tone pads as the second channel.
        const idx = std.math.clamp(@round(idx_start + (idx_end - idx_start) * norm), 0.0, 15.0);
        const noise_hz = nes_cpu_hz / nes_noise_periods[@intFromFloat(idx)];
        noise_phase += noise_hz / srf;
        while (noise_phase >= 1.0) {
            noise_level = noise.next();
            noise_phase -= 1.0;
        }

        const tone: f32 = switch (p.source) {
            .noise => 0.0,
            .pulse, .triangle => blk: {
                // Pitch is reloaded by the sweep unit, so it steps at 120 Hz
                // and lands only on a timer value the chip can hold.
                const t_sweep = @floor(t * nes_sweep_hz) / nes_sweep_hz;
                const target = p.freq_end + (p.freq_start - p.freq_end) * expEnv(t_sweep, p.pitch_decay);
                const divider: f32 = if (p.source == .pulse) 16.0 else 32.0;
                const hz = nesTimerFreq(target, divider);
                tone_phase += hz / srf;
                tone_phase -= @floor(tone_phase);
                if (p.source == .pulse) break :blk if (tone_phase < p.duty) 1.0 else -1.0;
                // 32-step triangle, 4 bits deep: the staircase is audible and
                // is most of why a chip triangle bass reads as a chip.
                const step: f32 = @floor(tone_phase * 32.0);
                const level = if (step < 16.0) 15.0 - step else step - 16.0;
                break :blk level / 7.5 - 1.0;
            },
        };

        s.* = switch (p.source) {
            .noise => noise_level * env,
            else => blk: {
                const ne = @floor(expEnv(t_env, p.noise_decay) * 15.0) / 15.0;
                break :blk tone * env * (1.0 - p.noise_mix) + noise_level * ne * p.noise_mix;
            },
        };
    }
    normalize(buf, 0.95);
    return buf;
}

// ---------------------------------------------------------------------------
// Kit variants - alternate flavours of the same 16 drums, selectable at
// runtime via `:drum-kit <name>` (see tui/commands.zig). Unlike `kit` above,
// these are never rendered to WAV or embedded: picking one calls the
// generators directly into the DrumMachine's pads, so extra kits cost zero
// shipped bytes - just the parameter tables below.

// zig fmt: on

/// Sampler-side shaping applied to a slot on load, on top of its generator's
/// audio - transpose, region trim, duration and tone tilt, all plain `Pad`
/// params (see dsp/pad.zig). Every field's default is "untouched".
pub const Tune = struct {
    /// Playback transpose in semitones (`Pad.pitch_semitones`).
    pitch: f32 = 0.0,
    /// Region end as a fraction of the clip (`Pad.end_norm`) - the knob that
    /// turns a full-length hit into a tight one.
    end: f32 = 1.0,
    /// Duration multiplier (`Pad.stretch_ratio`), independent of `pitch`.
    stretch: f32 = 1.0,
    /// Bipolar tone tilt (`Pad.filter`): negative darkens, positive thins.
    filter: f32 = 0.0,
};

/// Second-voice tunings. The `-2`/crash/stick pads share their neighbour's
/// generator, so without these they were the same hit at a different mixer
/// level. Each one moves pitch, length and tone far enough that the pair
/// reads as two drums, not one drum twice. (perc-hi/perc-lo don't need one:
/// `percGen` gives them their own fixed-pitch generator, see `PercParams`.)
const alt_kick: Tune = .{ .pitch = 3.0, .end = 0.6, .filter = 0.12 };
const alt_snare: Tune = .{ .pitch = -2.5, .end = 0.5, .filter = -0.16 };
const alt_hat: Tune = .{ .pitch = 5.0, .end = 0.55, .filter = 0.25 };
/// Crash = the open hat's tone dropped a fourth, generated straight to its
/// own longer, slower-decaying "wash" length (see `crashDefault` and its
/// per-flavour siblings) rather than time-stretched at runtime - WSOLA has
/// nothing to lock onto in this much broadband noise and splices audibly.
const alt_crash: Tune = .{ .pitch = -5.0, .filter = -0.08 };
const alt_stick: Tune = .{ .pitch = 7.0, .end = 0.35, .filter = 0.3 };

/// One pad slot in a runtime kit variant: display name, generator, default
/// mixer gain and pad tuning - the same shape as `PadDef` minus the WAV
/// filename (these are never written to disk). A null `gen` is an empty slot:
/// the "init" kit's blank slate, loaded as a silent pad rather than generated
/// audio.
/// Which shared generator a `VariantSlot` dispatches to - replaces a bare
/// function pointer so a slot's params can be a plain data literal instead
/// of a one-line wrapper function per flavor (there were ~130 of those:
/// `kickAnalog`, `snareAnalog`, ... one per generator per kit).
pub const GenKind = enum { kick, snare, hat, clap, tom, perc, rim, chip };

pub const Params = union(GenKind) {
    kick: KickParams,
    snare: SnareParams,
    hat: HatParams,
    clap: ClapParams,
    tom: TomParams,
    perc: PercParams,
    rim: RimParams,
    chip: ChipParams,
};

/// Dispatch a slot's `(kind, params)` to the generator it names. The
/// per-kind `Params` payload is exactly what each wrapper used to close
/// over, now a data literal in `variants` instead of a function body.
pub fn genSlot(kind: GenKind, params: Params, allocator: std.mem.Allocator, sr: u32) std.mem.Allocator.Error![]f32 {
    return switch (kind) {
        .kick => kickGen(allocator, sr, params.kick),
        .snare => snareGen(allocator, sr, params.snare),
        .hat => metalHat(allocator, sr, params.hat),
        .clap => clapGen(allocator, sr, params.clap),
        .tom => tomGen(allocator, sr, params.tom),
        .perc => percGen(allocator, sr, params.perc),
        .rim => rimGen(allocator, sr, params.rim),
        .chip => chipGen(allocator, sr, params.chip),
    };
}

pub const VariantSlot = struct {
    name: []const u8 = "",
    /// Null is an empty slot (the "init" kit's blank slate, loaded as a
    /// silent pad rather than generated audio) - `params` is meaningless
    /// without a `kind` to interpret it.
    kind: ?GenKind = null,
    params: Params = undefined,
    gain: f32 = 1.0,
    tune: Tune = .{},
};

/// Every kit lays its 16 pads out the same way, soundtype by soundtype, so a
/// pad and its second voice sit next to each other: kick, kick-2, snare,
/// snare-2, hihat, hat-2, open, crash | clap, rim, stick, tom-1, tom-2,
/// perc-hi, perc-lo, and the kit's signature sound last.
pub const KitVariant = struct {
    name: []const u8,
    /// Sound character, not genre - mirrors `synth_presets.Preset.category`.
    category: []const u8,
    /// First tag is always "wstudio"; the rest are genre associations.
    tags: []const []const u8,
    pads: [16]VariantSlot,
};

pub const variants = [_]KitVariant{
    // Blank slate - every pad empty, nothing to unlearn before loading your
    // own samples. What a fresh drum machine starts on, mirroring the synth's
    // own "init" preset (see dsp/synth_presets.zig).
    .{ .name = "init", .category = "utility", .tags = &.{"wstudio"}, .pads = [_]VariantSlot{.{}} ** 16 },
    // Also where the old "eurobeat" kit ended up: it was this one with more
    // click on the kick and 700 Hz more air on the hat, which is a second
    // voice, not a kit. Its punchier kick, wider snare and its "stab" are the
    // -2 pads and the signature slot here.
    .{ .name = "digital", .category = "digital", .tags = &.{ "wstudio", "house", "eurobeat", "dance" }, .pads = .{
        .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{} }, .gain = 1.00 },
        .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 52.0,
            .freq_start_add = 145.0,
            .pitch_decay = 58.0,
            .body_decay = 12.0,
            .click_decay = 300.0,
            .click_freq = 1900.0,
            .click_mix = 0.65,
            .drive = 3.0,
            .dur_s = 0.3,
        } }, .gain = 0.90 },
        .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{} }, .gain = 0.85 },
        .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 190.0,
            .tone2_hz = 280.0,
            .tone_decay = 25.0,
            .noise_decay = 18.0,
            .drive = 2.0,
            .dur_s = 0.26,
            .lp_hz = 9500.0,
            .hp_hz = 1000.0,
        } }, .gain = 0.80 },
        .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.09, .decay = 65.0 } }, .gain = 0.50 },
        .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.05, .decay = 110.0, .body_hz = 7200.0, .air_hz = 10_000.0, .air_mix = 0.35 } }, .gain = 0.45 },
        .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.42, .decay = 8.5 } }, .gain = 0.50 },
        .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.92, .decay = 3.9, .attack_mix = 0.5 } }, .gain = 0.54, .tune = alt_crash },
        .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{} }, .gain = 0.70 },
        .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{} }, .gain = 0.65 },
        .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{} }, .gain = 0.55, .tune = alt_stick },
        .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{ .freq_start = 220.0, .freq_end = 110.0, .dur_s = 0.42, .seed = 0x701 } }, .gain = 0.80 },
        .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{ .freq_start = 160.0, .freq_end = 80.0, .dur_s = 0.5, .seed = 0x702 } }, .gain = 0.80 },
        .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 520.0, .tone2_hz = 730.0, .seed = 0x703 } }, .gain = 0.70 },
        .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 310.0, .tone2_hz = 430.0, .seed = 0x704 } }, .gain = 0.70 },
        .{ .name = "stab", .kind = .rim, .params = .{ .rim = .{ .tone1_hz = 880.0, .tone2_hz = 1320.0, .tone_decay = 12.0, .click_decay = 100.0, .drive = 2.8, .dur_s = 0.4 } }, .gain = 0.66 },
    } },
    .{ .name = "analog", .category = "analog", .tags = &.{ "wstudio", "techno" }, .pads = .{
        .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 45.0,
            .freq_start_add = 90.0,
            .pitch_decay = 30.0,
            .body_decay = 8.0,
            .click_decay = 380.0,
            .click_freq = 1500.0,
            .click_mix = 0.25,
            .drive = 3.2,
            .dur_s = 0.55,
        } }, .gain = 1.00 },
        .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 45.0,
            .freq_start_add = 90.0,
            .pitch_decay = 30.0,
            .body_decay = 8.0,
            .click_decay = 380.0,
            .click_freq = 1500.0,
            .click_mix = 0.25,
            .drive = 3.2,
            .dur_s = 0.55,
        } }, .gain = 0.90, .tune = alt_kick },
        // The machine snare this kit models is two oscillators about an
        // octave apart with noise over them; these two were a fifth apart,
        // which is the library default and not any machine's interval. The
        // low oscillator keeps its tuning, so the kit stays as deep as it was.
        .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 150.0,
            .tone2_hz = 300.0,
            .tone_decay = 18.0,
            .noise_decay = 36.0,
            .drive = 1.1,
            .dur_s = 0.3,
        } }, .gain = 0.80 },
        .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 150.0,
            .tone2_hz = 300.0,
            .tone_decay = 18.0,
            .noise_decay = 36.0,
            .drive = 1.1,
            .dur_s = 0.3,
        } }, .gain = 0.72, .tune = alt_snare },
        .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.06, .decay = 90.0, .body_hz = 7000.0, .air_hz = 9500.0, .air_mix = 0.2 } }, .gain = 0.45 },
        .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.06, .decay = 90.0, .body_hz = 7000.0, .air_hz = 9500.0, .air_mix = 0.2 } }, .gain = 0.40, .tune = alt_hat },
        .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.35, .decay = 10.0, .body_hz = 7000.0, .air_hz = 9500.0, .air_mix = 0.2 } }, .gain = 0.45 },
        .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.77, .decay = 4.5, .body_hz = 7000.0, .air_hz = 9500.0, .air_mix = 0.2, .attack_mix = 0.5 } }, .gain = 0.50, .tune = alt_crash },
        .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
            .lp_hz = 2500.0,
            .hp_hz = 1000.0,
            .burst_decay = 180.0,
            .tail_decay = 10.0,
            .tail_mix = 0.7,
            .dur_s = 0.4,
        } }, .gain = 0.65 },
        .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1600.0,
            .tone2_hz = 1050.0,
            .tone_decay = 170.0,
            .click_decay = 350.0,
            .drive = 1.5,
            .dur_s = 0.07,
        } }, .gain = 0.60 },
        .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1600.0,
            .tone2_hz = 1050.0,
            .tone_decay = 170.0,
            .click_decay = 350.0,
            .drive = 1.5,
            .dur_s = 0.07,
        } }, .gain = 0.52, .tune = alt_stick },
        .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 180.0,
            .freq_end = 90.0,
            .dur_s = 0.6,
            .body_decay = 4.0,
            .attack_decay = 100.0,
            .drive = 1.8,
            .attack_mix = 0.08,
            .seed = 0x711,
        } }, .gain = 0.85 },
        .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 130.0,
            .freq_end = 60.0,
            .dur_s = 0.7,
            .body_decay = 3.5,
            .attack_decay = 100.0,
            .drive = 1.8,
            .attack_mix = 0.08,
            .seed = 0x712,
        } }, .gain = 0.85 },
        .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 430.0, .tone2_hz = 610.0, .drive = 1.9, .seed = 0x713 } }, .gain = 0.75 },
        .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 260.0, .tone2_hz = 360.0, .drive = 1.9, .seed = 0x714 } }, .gain = 0.75 },
        // The drum machine cowbell is two square oscillators at 540 and 800 Hz
        // - 681 cents, a fifth flattened by 19 - and it is the beating of that
        // not-quite-interval that reads as metal. This pair was 560/845, which
        // is 721 cents: neither the machine's interval nor the acoustic
        // cowbell's 1:1.44 that the percussion kit uses.
        .{ .name = "cowbell", .kind = .rim, .params = .{ .rim = .{ .tone1_hz = 540.0, .tone2_hz = 800.0, .tone_decay = 15.0, .click_decay = 100.0, .drive = 2.2, .dur_s = 0.35 } }, .gain = 0.62 },
    } },
    .{ .name = "acoustic", .category = "acoustic", .tags = &.{ "wstudio", "rock" }, .pads = .{
        .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 62.0,
            .freq_start_add = 150.0,
            .pitch_decay = 70.0,
            .body_decay = 20.0,
            .click_decay = 300.0,
            .click_freq = 2000.0,
            .click_mix = 0.8,
            .drive = 2.2,
            .dur_s = 0.22,
        } }, .gain = 1.00 },
        .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 62.0,
            .freq_start_add = 150.0,
            .pitch_decay = 70.0,
            .body_decay = 20.0,
            .click_decay = 300.0,
            .click_freq = 2000.0,
            .click_mix = 0.8,
            .drive = 2.2,
            .dur_s = 0.22,
        } }, .gain = 0.90, .tune = alt_kick },
        .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 200.0,
            .tone2_hz = 300.0,
            .tone_decay = 30.0,
            .noise_decay = 14.0,
            .drive = 1.8,
            .dur_s = 0.22,
        } }, .gain = 0.90 },
        .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 200.0,
            .tone2_hz = 300.0,
            .tone_decay = 30.0,
            .noise_decay = 14.0,
            .drive = 1.8,
            .dur_s = 0.22,
        } }, .gain = 0.82, .tune = alt_snare },
        .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.06, .decay = 75.0, .body_hz = 6000.0, .air_hz = 10_000.0, .air_mix = 0.4 } }, .gain = 0.55 },
        .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.06, .decay = 75.0, .body_hz = 6000.0, .air_hz = 10_000.0, .air_mix = 0.4 } }, .gain = 0.50, .tune = alt_hat },
        .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.3, .decay = 11.0, .body_hz = 6000.0, .air_hz = 10_000.0, .air_mix = 0.4 } }, .gain = 0.55 },
        .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.66, .decay = 5.0, .body_hz = 6000.0, .air_hz = 10_000.0, .air_mix = 0.4, .attack_mix = 0.5 } }, .gain = 0.62, .tune = alt_crash },
        .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
            .lp_hz = 3500.0,
            .hp_hz = 1300.0,
            .burst_decay = 260.0,
            .tail_decay = 22.0,
            .tail_mix = 0.35,
            .dur_s = 0.25,
        } }, .gain = 0.65 },
        .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1900.0,
            .tone2_hz = 1250.0,
            .tone_decay = 130.0,
            .click_decay = 280.0,
            .drive = 2.1,
            .dur_s = 0.06,
        } }, .gain = 0.70 },
        .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1900.0,
            .tone2_hz = 1250.0,
            .tone_decay = 130.0,
            .click_decay = 280.0,
            .drive = 2.1,
            .dur_s = 0.06,
        } }, .gain = 0.62, .tune = alt_stick },
        .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 260.0,
            .freq_end = 140.0,
            .dur_s = 0.3,
            .body_decay = 9.0,
            .attack_decay = 140.0,
            .drive = 1.5,
            .attack_mix = 0.2,
            .seed = 0x721,
        } }, .gain = 0.80 },
        .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 190.0,
            .freq_end = 100.0,
            .dur_s = 0.35,
            .body_decay = 8.0,
            .attack_decay = 140.0,
            .drive = 1.5,
            .attack_mix = 0.2,
            .seed = 0x722,
        } }, .gain = 0.80 },
        .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 560.0, .tone2_hz = 780.0, .slap_mix = 0.5, .seed = 0x723 } }, .gain = 0.72 },
        .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 340.0, .tone2_hz = 470.0, .slap_mix = 0.5, .seed = 0x724 } }, .gain = 0.72 },
        .{ .name = "ride", .kind = .hat, .params = .{ .hat = .{ .dur_s = 1.2, .decay = 3.2, .body_hz = 4200.0, .air_hz = 7800.0, .air_mix = 0.25 } }, .gain = 0.48 },
    } },
    .{ .name = "industrial", .category = "industrial", .tags = &.{ "wstudio", "techno" }, .pads = .{
        .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 50.0,
            .freq_start_add = 110.0,
            .pitch_decay = 40.0,
            .body_decay = 9.0,
            .click_decay = 250.0,
            .click_freq = 900.0,
            .click_mix = 0.9,
            .drive = 4.5,
            .dur_s = 0.5,
        } }, .gain = 1.00 },
        .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 50.0,
            .freq_start_add = 110.0,
            .pitch_decay = 40.0,
            .body_decay = 9.0,
            .click_decay = 250.0,
            .click_freq = 900.0,
            .click_mix = 0.9,
            .drive = 4.5,
            .dur_s = 0.5,
        } }, .gain = 0.92, .tune = alt_kick },
        .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 140.0,
            .tone2_hz = 260.0,
            .tone_decay = 15.0,
            .noise_decay = 26.0,
            .drive = 2.4,
            .dur_s = 0.32,
        } }, .gain = 0.85 },
        .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 140.0,
            .tone2_hz = 260.0,
            .tone_decay = 15.0,
            .noise_decay = 26.0,
            .drive = 2.4,
            .dur_s = 0.32,
        } }, .gain = 0.78, .tune = alt_snare },
        .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.12, .decay = 45.0, .body_hz = 5500.0, .air_hz = 8500.0, .air_mix = 0.5 } }, .gain = 0.50 },
        .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.12, .decay = 45.0, .body_hz = 5500.0, .air_hz = 8500.0, .air_mix = 0.5 } }, .gain = 0.45, .tune = alt_hat },
        .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.6, .decay = 5.0, .body_hz = 5500.0, .air_hz = 8500.0, .air_mix = 0.5 } }, .gain = 0.50 },
        .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 1.32, .decay = 2.3, .body_hz = 5500.0, .air_hz = 8500.0, .air_mix = 0.5, .attack_mix = 0.5 } }, .gain = 0.58, .tune = alt_crash },
        .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
            .lp_hz = 2800.0,
            .hp_hz = 900.0,
            .burst_decay = 150.0,
            .tail_decay = 8.0,
            .tail_mix = 0.8,
            .dur_s = 0.45,
        } }, .gain = 0.70 },
        .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1500.0,
            .tone2_hz = 980.0,
            .tone_decay = 110.0,
            .click_decay = 220.0,
            .drive = 3.0,
            .dur_s = 0.09,
        } }, .gain = 0.65 },
        .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1500.0,
            .tone2_hz = 980.0,
            .tone_decay = 110.0,
            .click_decay = 220.0,
            .drive = 3.0,
            .dur_s = 0.09,
        } }, .gain = 0.58, .tune = alt_stick },
        .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 210.0,
            .freq_end = 95.0,
            .dur_s = 0.55,
            .body_decay = 5.0,
            .attack_decay = 90.0,
            .drive = 2.4,
            .attack_mix = 0.25,
            .seed = 0x731,
        } }, .gain = 0.85 },
        .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 150.0,
            .freq_end = 65.0,
            .dur_s = 0.65,
            .body_decay = 4.5,
            .attack_decay = 90.0,
            .drive = 2.4,
            .attack_mix = 0.25,
            .seed = 0x732,
        } }, .gain = 0.85 },
        .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 480.0, .tone2_hz = 670.0, .drive = 3.0, .slap_mix = 0.55, .seed = 0x733 } }, .gain = 0.78 },
        .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 290.0, .tone2_hz = 400.0, .drive = 3.0, .slap_mix = 0.55, .seed = 0x734 } }, .gain = 0.78 },
        .{ .name = "anvil", .kind = .rim, .params = .{ .rim = .{ .tone1_hz = 760.0, .tone2_hz = 1210.0, .tone_decay = 24.0, .click_decay = 70.0, .drive = 4.5, .dur_s = 0.45 } }, .gain = 0.68 },
    } },
    // The second voices here are the old "gfunk" kit folded in: its long
    // 46 Hz sub kick, wider snare and brighter hat were the only things that
    // told the two apart, and a whole kit to hold three pads is a waste of a
    // slot. Tagged for both so a "g-funk" search still lands.
    .{
        .name = "boombap",
        .category = "vinyl",
        .tags = &.{ "wstudio", "hip-hop", "boom-bap", "g-funk" },
        .pads = .{
            .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
                .freq_end = 52.0,
                .freq_start_add = 70.0,
                .pitch_decay = 45.0,
                .body_decay = 16.0,
                .click_decay = 500.0,
                .click_freq = 1200.0,
                .click_mix = 0.15,
                .drive = 3.0,
                .dur_s = 0.4,
            } }, .gain = 1.00 },
            // The g-funk sub: 46 Hz, 0.7 s, barely any click. Long enough to carry
            // a bassline on its own, which is the whole point of the voice.
            .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
                .freq_end = 46.0,
                .freq_start_add = 75.0,
                .pitch_decay = 35.0,
                .body_decay = 6.0,
                .click_decay = 420.0,
                .click_freq = 1400.0,
                .click_mix = 0.2,
                .drive = 3.4,
                .dur_s = 0.7,
            } }, .gain = 0.90 },
            .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
                .tone1_hz = 165.0,
                .tone2_hz = 245.0,
                .tone_decay = 26.0,
                .noise_decay = 32.0,
                .drive = 2.0,
                .dur_s = 0.24,
            } }, .gain = 0.85 },
            .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
                .tone1_hz = 175.0,
                .tone2_hz = 250.0,
                .tone_decay = 22.0,
                .noise_decay = 28.0,
                .drive = 1.9,
                .dur_s = 0.25,
                .lp_hz = 7000.0,
                .hp_hz = 1000.0,
            } }, .gain = 0.80 },
            .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.045, .decay = 140.0, .body_hz = 6600.0, .air_hz = 8800.0, .air_mix = 0.15 } }, .gain = 0.45 },
            .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.05, .decay = 120.0, .body_hz = 7600.0, .air_hz = 10_800.0, .air_mix = 0.2 } }, .gain = 0.40 },
            .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.28, .decay = 12.0, .body_hz = 6600.0, .air_hz = 8800.0, .air_mix = 0.15 } }, .gain = 0.45 },
            .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.62, .decay = 5.5, .body_hz = 6600.0, .air_hz = 8800.0, .air_mix = 0.15, .attack_mix = 0.5 } }, .gain = 0.50, .tune = alt_crash },
            .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
                .lp_hz = 2600.0,
                .hp_hz = 1000.0,
                .burst_decay = 200.0,
                .tail_decay = 14.0,
                .tail_mix = 0.4,
                .dur_s = 0.28,
            } }, .gain = 0.65 },
            .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
                .tone1_hz = 1550.0,
                .tone2_hz = 1000.0,
                .tone_decay = 140.0,
                .click_decay = 280.0,
                .drive = 2.2,
                .dur_s = 0.07,
            } }, .gain = 0.60 },
            .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
                .tone1_hz = 1550.0,
                .tone2_hz = 1000.0,
                .tone_decay = 140.0,
                .click_decay = 280.0,
                .drive = 2.2,
                .dur_s = 0.07,
            } }, .gain = 0.52, .tune = alt_stick },
            .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
                .freq_start = 200.0,
                .freq_end = 100.0,
                .dur_s = 0.35,
                .body_decay = 7.0,
                .attack_decay = 110.0,
                .drive = 2.0,
                .attack_mix = 0.15,
                .seed = 0x741,
            } }, .gain = 0.80 },
            .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
                .freq_start = 140.0,
                .freq_end = 70.0,
                .dur_s = 0.42,
                .body_decay = 6.0,
                .attack_decay = 110.0,
                .drive = 2.0,
                .attack_mix = 0.15,
                .seed = 0x742,
            } }, .gain = 0.80 },
            .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 460.0, .tone2_hz = 640.0, .drive = 1.4, .dur_s = 0.14, .seed = 0x743 } }, .gain = 0.72 },
            .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 280.0, .tone2_hz = 390.0, .drive = 1.4, .dur_s = 0.14, .seed = 0x744 } }, .gain = 0.72 },
            .{ .name = "vinyl", .kind = .clap, .params = .{ .clap = .{ .lp_hz = 1800.0, .hp_hz = 250.0, .burst_decay = 70.0, .tail_decay = 5.0, .tail_mix = 0.8, .dur_s = 0.5 } }, .gain = 0.48 },
        },
    },
    // The one kit built around a kick that outlives the bar: 42 Hz, 1.1 s,
    // almost no click, shallow pitch bend. That is the sound doing the
    // bassline's job rather than the drum's, so kick-2 is the short clicky
    // top layer you stack on it when the sub alone has no attack.
    .{
        .name = "trap",
        .category = "sub",
        .tags = &.{ "wstudio", "trap", "hip-hop" },
        .pads = .{
            .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
                .freq_end = 42.0,
                .freq_start_add = 60.0,
                .pitch_decay = 26.0,
                .body_decay = 3.2,
                .click_decay = 400.0,
                .click_freq = 1300.0,
                .click_mix = 0.12,
                .drive = 1.7,
                .dur_s = 1.1,
            } }, .gain = 1.00 },
            .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
                .freq_end = 60.0,
                .freq_start_add = 150.0,
                .pitch_decay = 90.0,
                .body_decay = 26.0,
                .click_decay = 300.0,
                .click_freq = 2600.0,
                .click_mix = 0.85,
                .drive = 2.4,
                .dur_s = 0.16,
            } }, .gain = 0.85 },
            .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
                .tone1_hz = 210.0,
                .tone2_hz = 330.0,
                .tone_decay = 40.0,
                .noise_decay = 26.0,
                .drive = 2.0,
                .dur_s = 0.18,
                .lp_hz = 9000.0,
                .hp_hz = 1200.0,
            } }, .gain = 0.88 },
            .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
                .tone1_hz = 250.0,
                .tone2_hz = 380.0,
                .tone_decay = 55.0,
                .noise_decay = 34.0,
                .drive = 2.6,
                .dur_s = 0.14,
                .lp_hz = 11_000.0,
                .hp_hz = 1500.0,
            } }, .gain = 0.80 },
            // Both hats are far shorter than any other kit's: at 1/32-note roll
            // speed a 45 ms hat is still ringing when the next one lands.
            .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.028, .decay = 190.0, .body_hz = 8200.0, .air_hz = 11_500.0, .air_mix = 0.3 } }, .gain = 0.48 },
            .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.022, .decay = 240.0, .body_hz = 9000.0, .air_hz = 12_000.0, .air_mix = 0.25 } }, .gain = 0.42 },
            .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.3, .decay = 12.0, .body_hz = 8200.0, .air_hz = 11_500.0, .air_mix = 0.3 } }, .gain = 0.48 },
            .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.8, .decay = 4.2, .body_hz = 8000.0, .air_hz = 11_000.0, .air_mix = 0.3, .attack_mix = 0.5 } }, .gain = 0.52, .tune = alt_crash },
            .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
                .lp_hz = 4000.0,
                .hp_hz = 1400.0,
                .burst_decay = 260.0,
                .tail_decay = 24.0,
                .tail_mix = 0.3,
                .dur_s = 0.26,
            } }, .gain = 0.72 },
            .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
                .tone1_hz = 1900.0,
                .tone2_hz = 1250.0,
                .tone_decay = 160.0,
                .click_decay = 320.0,
                .drive = 2.2,
                .dur_s = 0.06,
            } }, .gain = 0.66 },
            .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
                .tone1_hz = 1900.0,
                .tone2_hz = 1250.0,
                .tone_decay = 160.0,
                .click_decay = 320.0,
                .drive = 2.2,
                .dur_s = 0.06,
            } }, .gain = 0.58, .tune = alt_stick },
            .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
                .freq_start = 180.0,
                .freq_end = 90.0,
                .dur_s = 0.45,
                .body_decay = 6.0,
                .attack_decay = 130.0,
                .drive = 2.0,
                .attack_mix = 0.1,
                .seed = 0x7d1,
            } }, .gain = 0.82 },
            .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
                .freq_start = 130.0,
                .freq_end = 65.0,
                .dur_s = 0.55,
                .body_decay = 5.0,
                .attack_decay = 130.0,
                .drive = 2.0,
                .attack_mix = 0.1,
                .seed = 0x7d2,
            } }, .gain = 0.82 },
            .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 620.0, .tone2_hz = 880.0, .body_decay = 60.0, .slap_mix = 0.25, .dur_s = 0.1, .seed = 0x7d3 } }, .gain = 0.70 },
            .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 380.0, .tone2_hz = 540.0, .body_decay = 60.0, .slap_mix = 0.25, .dur_s = 0.12, .seed = 0x7d4 } }, .gain = 0.70 },
            // The old g-funk "zap", dropped when that kit folded into boombap:
            // a 700 Hz to 60 Hz dive over 0.8 s, which reads as a sub drop here.
            .{ .name = "dive", .kind = .tom, .params = .{ .tom = .{ .freq_start = 700.0, .freq_end = 60.0, .dur_s = 0.8, .body_decay = 3.5, .attack_decay = 180.0, .drive = 2.2, .attack_mix = 0.04, .seed = 0x7d5 } }, .gain = 0.70 },
        },
    },
    // High-tempo break kit: everything tuned up and cut short, because at
    // 170 BPM a 0.3 s snare tail is already covering the next hit. The snare
    // is the loud one on purpose - it carries the pattern, the kick only
    // punctuates it.
    .{
        .name = "breaks",
        .category = "breakbeat",
        .tags = &.{ "wstudio", "jungle", "drum-and-bass" },
        .pads = .{
            .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
                .freq_end = 56.0,
                .freq_start_add = 135.0,
                .pitch_decay = 80.0,
                .body_decay = 20.0,
                .click_decay = 320.0,
                .click_freq = 2200.0,
                .click_mix = 0.55,
                .drive = 2.8,
                .dur_s = 0.2,
            } }, .gain = 1.00 },
            .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
                .freq_end = 44.0,
                .freq_start_add = 90.0,
                .pitch_decay = 45.0,
                .body_decay = 9.0,
                .click_decay = 380.0,
                .click_freq = 1500.0,
                .click_mix = 0.3,
                .drive = 3.0,
                .dur_s = 0.45,
            } }, .gain = 0.88 },
            .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
                .tone1_hz = 235.0,
                .tone2_hz = 350.0,
                .tone_decay = 26.0,
                .noise_decay = 15.0,
                .drive = 2.4,
                .dur_s = 0.3,
                .lp_hz = 9500.0,
                .hp_hz = 900.0,
            } }, .gain = 0.95 },
            // The ghost snare: same drum hit softer and choked, for the rolls
            // between the backbeats.
            .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
                .tone1_hz = 260.0,
                .tone2_hz = 390.0,
                .tone_decay = 40.0,
                .noise_decay = 26.0,
                .drive = 2.2,
                .dur_s = 0.16,
                .lp_hz = 10_000.0,
                .hp_hz = 1100.0,
            } }, .gain = 0.78 },
            .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.05, .decay = 120.0, .body_hz = 6800.0, .air_hz = 9500.0, .air_mix = 0.3 } }, .gain = 0.48 },
            .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.04, .decay = 150.0, .body_hz = 7400.0, .air_hz = 10_200.0, .air_mix = 0.25 } }, .gain = 0.42 },
            .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.34, .decay = 9.5, .body_hz = 6800.0, .air_hz = 9500.0, .air_mix = 0.3 } }, .gain = 0.48 },
            .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.7, .decay = 4.6, .body_hz = 6400.0, .air_hz = 9000.0, .air_mix = 0.35, .attack_mix = 0.5 } }, .gain = 0.56, .tune = alt_crash },
            .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
                .lp_hz = 3400.0,
                .hp_hz = 1100.0,
                .burst_decay = 190.0,
                .tail_decay = 18.0,
                .tail_mix = 0.45,
                .dur_s = 0.3,
            } }, .gain = 0.68 },
            .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
                .tone1_hz = 1700.0,
                .tone2_hz = 1120.0,
                .tone_decay = 130.0,
                .click_decay = 260.0,
                .drive = 2.4,
                .dur_s = 0.07,
            } }, .gain = 0.64 },
            .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
                .tone1_hz = 1700.0,
                .tone2_hz = 1120.0,
                .tone_decay = 130.0,
                .click_decay = 260.0,
                .drive = 2.4,
                .dur_s = 0.07,
            } }, .gain = 0.56, .tune = alt_stick },
            .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
                .freq_start = 260.0,
                .freq_end = 150.0,
                .dur_s = 0.3,
                .body_decay = 9.0,
                .attack_decay = 120.0,
                .drive = 2.2,
                .attack_mix = 0.2,
                .seed = 0x7e1,
            } }, .gain = 0.84 },
            .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
                .freq_start = 190.0,
                .freq_end = 105.0,
                .dur_s = 0.36,
                .body_decay = 8.0,
                .attack_decay = 120.0,
                .drive = 2.2,
                .attack_mix = 0.2,
                .seed = 0x7e2,
            } }, .gain = 0.84 },
            .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 500.0, .tone2_hz = 700.0, .body_decay = 45.0, .slap_mix = 0.45, .dur_s = 0.12, .seed = 0x7e3 } }, .gain = 0.74 },
            .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 300.0, .tone2_hz = 420.0, .body_decay = 45.0, .slap_mix = 0.45, .dur_s = 0.12, .seed = 0x7e4 } }, .gain = 0.74 },
            // Ride: a crash's length with almost none of its air, so the metal
            // partials ping through instead of washing over the pattern. What
            // is left is spiky - RMS 0.025 against an open hat's 0.064 at the
            // same peak - so its gain runs higher than the hats' or it would
            // sit under the pattern instead of over it.
            .{ .name = "ride", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.9, .decay = 3.6, .body_hz = 9000.0, .air_hz = 12_000.0, .air_mix = 0.1, .attack_mix = 0.5 } }, .gain = 0.68 },
        },
    },
    // The bright, clean, short pop kit - and the only one. "technopop" and
    // "kawaii" were this kit at 1 kHz intervals of brightness (kick within
    // 8 Hz, snare within 25 Hz, hat within 1.2 kHz), so the two ends of that
    // range live here as second voices: technopop's clicky 0.18 s kick and
    // kawaii's 10 kHz snare and 8 kHz hat.
    .{ .name = "citypop", .category = "digital", .tags = &.{ "wstudio", "city-pop", "funk", "technopop", "kawaii" }, .pads = .{
        .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 60.0,
            .freq_start_add = 140.0,
            .pitch_decay = 65.0,
            .body_decay = 16.0,
            .click_decay = 320.0,
            .click_freq = 1800.0,
            .click_mix = 0.7,
            .drive = 2.0,
            .dur_s = 0.25,
        } }, .gain = 1.00 },
        .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 55.0,
            .freq_start_add = 120.0,
            .pitch_decay = 80.0,
            .body_decay = 18.0,
            .click_decay = 300.0,
            .click_freq = 2400.0,
            .click_mix = 0.9,
            .drive = 1.8,
            .dur_s = 0.18,
        } }, .gain = 0.90 },
        .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 195.0,
            .tone2_hz = 285.0,
            .tone_decay = 26.0,
            .noise_decay = 12.0,
            .drive = 1.6,
            .dur_s = 0.2,
            .lp_hz = 7500.0,
            .hp_hz = 950.0,
        } }, .gain = 0.90 },
        .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 220.0,
            .tone2_hz = 330.0,
            .tone_decay = 30.0,
            .noise_decay = 16.0,
            .drive = 1.7,
            .dur_s = 0.2,
            .lp_hz = 10_000.0,
            .hp_hz = 1200.0,
        } }, .gain = 0.82 },
        .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.055, .decay = 100.0, .body_hz = 6800.0, .air_hz = 9500.0, .air_mix = 0.35 } }, .gain = 0.50 },
        .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.04, .decay = 140.0, .body_hz = 8000.0, .air_hz = 11_000.0, .air_mix = 0.45 } }, .gain = 0.45 },
        .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.32, .decay = 10.0, .body_hz = 6800.0, .air_hz = 9500.0, .air_mix = 0.35 } }, .gain = 0.50 },
        .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.70, .decay = 4.5, .body_hz = 6800.0, .air_hz = 9500.0, .air_mix = 0.35, .attack_mix = 0.5 } }, .gain = 0.56, .tune = alt_crash },
        .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
            .lp_hz = 3200.0,
            .hp_hz = 1200.0,
            .burst_decay = 240.0,
            .tail_decay = 20.0,
            .tail_mix = 0.3,
            .dur_s = 0.24,
        } }, .gain = 0.60 },
        .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1850.0,
            .tone2_hz = 1200.0,
            .tone_decay = 140.0,
            .click_decay = 300.0,
            .drive = 1.9,
            .dur_s = 0.06,
        } }, .gain = 0.70 },
        .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1850.0,
            .tone2_hz = 1200.0,
            .tone_decay = 140.0,
            .click_decay = 300.0,
            .drive = 1.9,
            .dur_s = 0.06,
        } }, .gain = 0.62, .tune = alt_stick },
        .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 240.0,
            .freq_end = 130.0,
            .dur_s = 0.32,
            .body_decay = 8.0,
            .attack_decay = 130.0,
            .drive = 1.6,
            .attack_mix = 0.15,
            .seed = 0x761,
        } }, .gain = 0.85 },
        .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 175.0,
            .freq_end = 95.0,
            .dur_s = 0.38,
            .body_decay = 7.0,
            .attack_decay = 130.0,
            .drive = 1.6,
            .attack_mix = 0.15,
            .seed = 0x762,
        } }, .gain = 0.85 },
        .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 540.0, .tone2_hz = 750.0, .body_decay = 40.0, .slap_mix = 0.3, .seed = 0x763 } }, .gain = 0.76 },
        .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 330.0, .tone2_hz = 450.0, .body_decay = 40.0, .slap_mix = 0.3, .seed = 0x764 } }, .gain = 0.76 },
        .{ .name = "gated", .kind = .snare, .params = .{ .snare = .{ .tone1_hz = 170.0, .tone2_hz = 255.0, .tone_decay = 18.0, .noise_decay = 7.0, .drive = 2.0, .dur_s = 0.5, .lp_hz = 6500.0, .hp_hz = 700.0 } }, .gain = 0.72 },
    } },
    // Console drums, played on the chip's own three voices rather than
    // modelled on acoustic ones. A 2A03 had no drum channels: a tracker made
    // a kit out of the noise channel, the 4-bit triangle and a pulse, and the
    // machine's limits are the sound. The noise pads sit on the sixteen timer
    // periods the chip can count to and nothing between them; the snares use
    // the register's short mode, whose 93-step sequence buzzes instead of
    // hissing; the kick and toms are the triangle's staircase bent down with
    // a noise channel struck alongside for the attack; every decay steps at
    // 240 Hz through sixteen volume levels. Nothing here is filtered, because
    // nothing on the chip could be.
    .{
        .name = "chiptune",
        .category = "8-bit",
        .tags = &.{ "wstudio", "chiptune", "game" },
        .pads = .{
            // Triangle bent an octave and a half down inside 40 ms, with a
            // frame of noise on the front - the standard tracker kick.
            .{ .name = "kick", .kind = .chip, .params = .{ .chip = .{
                .source = .triangle,
                .freq_start = 165.0,
                .freq_end = 48.0,
                .pitch_decay = 90.0,
                .decay = 40.0,
                .noise_mix = 0.14,
                .noise_index = 6,
                .dur_s = 0.11,
                .seed = 0x21,
            } }, .gain = 1.00 },
            // The other way to write it: a 50% pulse instead of the triangle,
            // which is louder and harder because a pulse is a square edge.
            .{ .name = "kick-2", .kind = .chip, .params = .{ .chip = .{
                .source = .pulse,
                .duty = 0.5,
                .freq_start = 210.0,
                .freq_end = 58.0,
                .pitch_decay = 120.0,
                .decay = 52.0,
                .noise_mix = 0.12,
                .noise_index = 5,
                .dur_s = 0.09,
                .seed = 0x22,
            } }, .gain = 0.92 },
            // Noise swept two periods down over the hit: the chip has no
            // filter envelope, so stepping the timer is the only way to make
            // a snare fall.
            .{ .name = "snare", .kind = .chip, .params = .{ .chip = .{
                .noise_index = 3,
                .noise_index_end = 5,
                .decay = 30.0,
                .dur_s = 0.15,
                .seed = 0x23,
            } }, .gain = 0.88 },
            // Short mode: 93 steps instead of 32767, which reads as a pitched
            // metallic rattle. This is the snare everyone recognises.
            .{ .name = "snare-2", .kind = .chip, .params = .{ .chip = .{
                .noise_index = 2,
                .noise_index_end = 4,
                .short = true,
                .decay = 36.0,
                .dur_s = 0.12,
                .seed = 0x24,
            } }, .gain = 0.80 },
            .{ .name = "hihat", .kind = .chip, .params = .{ .chip = .{
                .noise_index = 0,
                .decay = 210.0,
                .dur_s = 0.03,
                .seed = 0x25,
            } }, .gain = 0.46 },
            .{ .name = "hat-2", .kind = .chip, .params = .{ .chip = .{
                .noise_index = 1,
                .decay = 260.0,
                .dur_s = 0.025,
                .seed = 0x26,
            } }, .gain = 0.42 },
            .{ .name = "open", .kind = .chip, .params = .{ .chip = .{
                .noise_index = 0,
                .decay = 22.0,
                .dur_s = 0.18,
                .seed = 0x27,
            } }, .gain = 0.46 },
            .{ .name = "crash", .kind = .chip, .params = .{ .chip = .{
                .noise_index = 2,
                .decay = 7.0,
                .dur_s = 0.6,
                .seed = 0x28,
            } }, .gain = 0.50 },
            // A chip clap is the same noise hit written on three rows in a
            // row, so it is one envelope retriggered twice, not a new voice.
            .{ .name = "clap", .kind = .chip, .params = .{ .chip = .{
                .noise_index = 4,
                .decay = 120.0,
                .bursts = 3,
                .burst_gap_s = 0.013,
                .dur_s = 0.14,
                .seed = 0x29,
            } }, .gain = 0.66 },
            // The thinnest duty the chip has, held at pitch: a click with a
            // tone in it, which is all a chip rim can be.
            .{ .name = "rim", .kind = .chip, .params = .{ .chip = .{
                .source = .pulse,
                .duty = 0.125,
                .freq_start = 2200.0,
                .freq_end = 2200.0,
                .decay = 380.0,
                .dur_s = 0.035,
                .seed = 0x2a,
            } }, .gain = 0.62 },
            .{ .name = "stick", .kind = .chip, .params = .{ .chip = .{
                .source = .pulse,
                .duty = 0.125,
                .freq_start = 3300.0,
                .freq_end = 3300.0,
                .decay = 460.0,
                .dur_s = 0.028,
                .seed = 0x2b,
            } }, .gain = 0.55 },
            .{ .name = "tom-1", .kind = .chip, .params = .{ .chip = .{
                .source = .triangle,
                .freq_start = 420.0,
                .freq_end = 190.0,
                .pitch_decay = 34.0,
                .decay = 34.0,
                .noise_mix = 0.07,
                .noise_index = 7,
                .dur_s = 0.15,
                .seed = 0x2c,
            } }, .gain = 0.82 },
            .{ .name = "tom-2", .kind = .chip, .params = .{ .chip = .{
                .source = .triangle,
                .freq_start = 300.0,
                .freq_end = 140.0,
                .pitch_decay = 30.0,
                .decay = 30.0,
                .noise_mix = 0.07,
                .noise_index = 8,
                .dur_s = 0.17,
                .seed = 0x2d,
            } }, .gain = 0.82 },
            .{ .name = "perc-hi", .kind = .chip, .params = .{ .chip = .{
                .source = .pulse,
                .duty = 0.25,
                .freq_start = 1250.0,
                .freq_end = 880.0,
                .pitch_decay = 120.0,
                .decay = 95.0,
                .dur_s = 0.07,
                .seed = 0x2e,
            } }, .gain = 0.68 },
            .{ .name = "perc-lo", .kind = .chip, .params = .{ .chip = .{
                .source = .pulse,
                .duty = 0.25,
                .freq_start = 840.0,
                .freq_end = 590.0,
                .pitch_decay = 110.0,
                .decay = 80.0,
                .dur_s = 0.09,
                .seed = 0x2f,
            } }, .gain = 0.68 },
            // The kit's signature: a pulse dropped three octaves in a tenth
            // of a second, stepping through timer values on the way down.
            // Every console made this sound and no drum machine did.
            .{ .name = "blip", .kind = .chip, .params = .{ .chip = .{
                .source = .pulse,
                .duty = 0.25,
                .freq_start = 1800.0,
                .freq_end = 220.0,
                .pitch_decay = 55.0,
                .decay = 26.0,
                .dur_s = 0.14,
                .seed = 0x30,
            } }, .gain = 0.64 },
        },
    },
    .{ .name = "vaporwave", .category = "tape", .tags = &.{ "wstudio", "vaporwave", "chill" }, .pads = .{
        .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 50.0,
            .freq_start_add = 60.0,
            .pitch_decay = 28.0,
            .body_decay = 8.0,
            .click_decay = 500.0,
            .click_freq = 900.0,
            .click_mix = 0.08,
            .drive = 2.0,
            .dur_s = 0.5,
        } }, .gain = 1.00 },
        .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 50.0,
            .freq_start_add = 60.0,
            .pitch_decay = 28.0,
            .body_decay = 8.0,
            .click_decay = 500.0,
            .click_freq = 900.0,
            .click_mix = 0.08,
            .drive = 2.0,
            .dur_s = 0.5,
        } }, .gain = 0.88, .tune = alt_kick },
        .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 155.0,
            .tone2_hz = 225.0,
            .tone_decay = 16.0,
            .noise_decay = 10.0,
            .drive = 1.2,
            .dur_s = 0.35,
            .lp_hz = 4500.0,
            .hp_hz = 600.0,
        } }, .gain = 0.80 },
        .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 155.0,
            .tone2_hz = 225.0,
            .tone_decay = 16.0,
            .noise_decay = 10.0,
            .drive = 1.2,
            .dur_s = 0.35,
            .lp_hz = 4500.0,
            .hp_hz = 600.0,
        } }, .gain = 0.72, .tune = alt_snare },
        .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.07, .decay = 80.0, .body_hz = 4800.0, .air_hz = 7000.0, .air_mix = 0.15 } }, .gain = 0.40 },
        .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.07, .decay = 80.0, .body_hz = 4800.0, .air_hz = 7000.0, .air_mix = 0.15 } }, .gain = 0.35, .tune = alt_hat },
        .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.5, .decay = 6.0, .body_hz = 4800.0, .air_hz = 7000.0, .air_mix = 0.15 } }, .gain = 0.40 },
        .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 1.1, .decay = 2.7, .body_hz = 4800.0, .air_hz = 7000.0, .air_mix = 0.15, .attack_mix = 0.5 } }, .gain = 0.45, .tune = alt_crash },
        .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
            .lp_hz = 2200.0,
            .hp_hz = 800.0,
            .burst_decay = 160.0,
            .tail_decay = 9.0,
            .tail_mix = 0.75,
            .dur_s = 0.5,
        } }, .gain = 0.60 },
        .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1400.0,
            .tone2_hz = 900.0,
            .tone_decay = 100.0,
            .click_decay = 200.0,
            .drive = 1.4,
            .dur_s = 0.08,
        } }, .gain = 0.55 },
        .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 1400.0,
            .tone2_hz = 900.0,
            .tone_decay = 100.0,
            .click_decay = 200.0,
            .drive = 1.4,
            .dur_s = 0.08,
        } }, .gain = 0.47, .tune = alt_stick },
        .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 190.0,
            .freq_end = 95.0,
            .dur_s = 0.5,
            .body_decay = 4.5,
            .attack_decay = 90.0,
            .drive = 1.4,
            .attack_mix = 0.06,
            .seed = 0x791,
        } }, .gain = 0.75 },
        .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 140.0,
            .freq_end = 70.0,
            .dur_s = 0.6,
            .body_decay = 4.0,
            .attack_decay = 90.0,
            .drive = 1.4,
            .attack_mix = 0.06,
            .seed = 0x792,
        } }, .gain = 0.75 },
        .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 420.0, .tone2_hz = 580.0, .drive = 1.1, .slap_mix = 0.15, .dur_s = 0.22, .seed = 0x793 } }, .gain = 0.68 },
        .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 260.0, .tone2_hz = 360.0, .drive = 1.1, .slap_mix = 0.15, .dur_s = 0.22, .seed = 0x794 } }, .gain = 0.68 },
        .{ .name = "wash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 1.5, .decay = 2.5, .body_hz = 2600.0, .air_hz = 4800.0, .air_mix = 0.5 } }, .gain = 0.38 },
    } },
    .{ .name = "hardcore", .category = "distorted", .tags = &.{ "wstudio", "j-core", "hardcore" }, .pads = .{
        .{ .name = "kick", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 58.0,
            .freq_start_add = 220.0,
            .pitch_decay = 95.0,
            .body_decay = 14.0,
            .click_decay = 180.0,
            .click_freq = 2400.0,
            .click_mix = 0.85,
            .drive = 7.5,
            .dur_s = 0.22,
        } }, .gain = 1.00 },
        .{ .name = "kick-2", .kind = .kick, .params = .{ .kick = .{
            .freq_end = 58.0,
            .freq_start_add = 220.0,
            .pitch_decay = 95.0,
            .body_decay = 14.0,
            .click_decay = 180.0,
            .click_freq = 2400.0,
            .click_mix = 0.85,
            .drive = 7.5,
            .dur_s = 0.22,
        } }, .gain = 0.92, .tune = alt_kick },
        .{ .name = "snare", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 215.0,
            .tone2_hz = 320.0,
            .tone_decay = 22.0,
            .noise_decay = 22.0,
            .drive = 3.4,
            .dur_s = 0.2,
            .lp_hz = 10_000.0,
            .hp_hz = 1300.0,
        } }, .gain = 0.85 },
        .{ .name = "snare-2", .kind = .snare, .params = .{ .snare = .{
            .tone1_hz = 215.0,
            .tone2_hz = 320.0,
            .tone_decay = 22.0,
            .noise_decay = 22.0,
            .drive = 3.4,
            .dur_s = 0.2,
            .lp_hz = 10_000.0,
            .hp_hz = 1300.0,
        } }, .gain = 0.78, .tune = alt_snare },
        .{ .name = "hihat", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.032, .decay = 170.0, .body_hz = 8200.0, .air_hz = 11_500.0, .air_mix = 0.4 } }, .gain = 0.45 },
        .{ .name = "hat-2", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.032, .decay = 170.0, .body_hz = 8200.0, .air_hz = 11_500.0, .air_mix = 0.4 } }, .gain = 0.40, .tune = alt_hat },
        .{ .name = "open", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.13, .decay = 32.0, .body_hz = 8200.0, .air_hz = 11_500.0, .air_mix = 0.4 } }, .gain = 0.45 },
        .{ .name = "crash", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.44, .decay = 7.3, .body_hz = 8200.0, .air_hz = 11_500.0, .air_mix = 0.4, .attack_mix = 0.5 } }, .gain = 0.50, .tune = alt_crash },
        .{ .name = "clap", .kind = .clap, .params = .{ .clap = .{
            .lp_hz = 3600.0,
            .hp_hz = 1500.0,
            .burst_decay = 280.0,
            .tail_decay = 20.0,
            .tail_mix = 0.3,
            .dur_s = 0.2,
        } }, .gain = 0.70 },
        .{ .name = "rim", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 2000.0,
            .tone2_hz = 1350.0,
            .tone_decay = 170.0,
            .click_decay = 280.0,
            .drive = 3.5,
            .dur_s = 0.045,
        } }, .gain = 0.60 },
        .{ .name = "stick", .kind = .rim, .params = .{ .rim = .{
            .tone1_hz = 2000.0,
            .tone2_hz = 1350.0,
            .tone_decay = 170.0,
            .click_decay = 280.0,
            .drive = 3.5,
            .dur_s = 0.045,
        } }, .gain = 0.52, .tune = alt_stick },
        .{ .name = "tom-1", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 280.0,
            .freq_end = 150.0,
            .dur_s = 0.24,
            .body_decay = 10.0,
            .attack_decay = 150.0,
            .drive = 3.2,
            .attack_mix = 0.2,
            .seed = 0x7b1,
        } }, .gain = 0.80 },
        .{ .name = "tom-2", .kind = .tom, .params = .{ .tom = .{
            .freq_start = 200.0,
            .freq_end = 100.0,
            .dur_s = 0.28,
            .body_decay = 9.0,
            .attack_decay = 150.0,
            .drive = 3.2,
            .attack_mix = 0.2,
            .seed = 0x7b2,
        } }, .gain = 0.80 },
        .{ .name = "perc-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 620.0, .tone2_hz = 860.0, .drive = 3.4, .body_decay = 45.0, .dur_s = 0.11, .seed = 0x7b3 } }, .gain = 0.72 },
        .{ .name = "perc-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 380.0, .tone2_hz = 520.0, .drive = 3.4, .body_decay = 45.0, .dur_s = 0.11, .seed = 0x7b4 } }, .gain = 0.72 },
        .{ .name = "screech", .kind = .tom, .params = .{ .tom = .{ .freq_start = 1600.0, .freq_end = 120.0, .dur_s = 0.35, .body_decay = 4.0, .attack_decay = 120.0, .drive = 6.0, .attack_mix = 0.15, .seed = 0x7c4 } }, .gain = 0.68 },
    } },
    // The one kit that does NOT follow the kick/snare/hat layout every other
    // one shares - it has no kick, no snare and no hihat, because a hand
    // percussion set doesn't have them. Pads run low to high instead: the
    // three congas and a slap, bongos, timbales, then the struck wood and
    // the two bells, the shaken and scraped gourds, and a bombo underneath
    // it all. Meant to be layered under another machine, not played on its
    // own.
    //
    // The roster is Cuban throughout. It used to carry an agogo, a cabasa, a
    // tambourine and a surdo - three Brazilian instruments and one generic
    // one, in a kit that calls itself Afro-Cuban - while the section that
    // actually keeps time in Cuban music, the scraped gourd, was missing
    // entirely. Now: two bells rather than one, since Cuban music uses a
    // pair and they are different instruments (the campana is the wide,
    // thick, low one the bongosero picks up for the montuno; the cha-cha
    // bell is the small bright one mounted on the timbales), maracas and a
    // chekere for the shaken gourds, and a guiro for the scraped one.
    //
    // The pitches are the common Afro-Cuban tuning - tumba D3, conga G3,
    // quinto C4, bongos above them, timbales a fourth apart, which is the
    // interval that pair is tuned to. What the first version got wrong was
    // everything above the fundamental: every drum here had its second
    // partial at a perfect fifth, which is a chord, not a drum. A struck
    // circular membrane's next mode is the (1,1) at 1.593x, and it is damped
    // harder than the fundamental, so it dies first - that ratio and that
    // faster decay are most of what separates a drum from a two-note chime.
    // The struck bars work the same way with different numbers: a free bar's
    // second mode sits at 2.76x, which is why claves and woodblocks read as
    // wood rather than as pitched percussion.
    .{
        .name = "percussion",
        .category = "percussion",
        .tags = &.{ "wstudio", "latin", "afro-cuban" },
        .pads = .{
            // Open tones, which are what a conga is tuned by: the drum rings
            // on after the hand leaves. The old set decayed in under a tenth
            // of a second, which is a muffled tone, not an open one.
            .{ .name = "tumba", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 147.0, .tone2_hz = 234.0, .body_decay = 11.0, .tone2_decay_mul = 2.2, .slap_mix = 0.22, .drive = 1.4, .dur_s = 0.5, .seed = 0x811 } }, .gain = 0.90 },
            .{ .name = "conga", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 196.0, .tone2_hz = 312.0, .body_decay = 13.0, .tone2_decay_mul = 2.2, .slap_mix = 0.25, .drive = 1.4, .dur_s = 0.45, .seed = 0x812 } }, .gain = 0.88 },
            .{ .name = "quinto", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 262.0, .tone2_hz = 417.0, .body_decay = 16.0, .tone2_decay_mul = 2.2, .slap_mix = 0.3, .drive = 1.4, .dur_s = 0.38, .seed = 0x813 } }, .gain = 0.86 },
            // Same drum as the quinto, struck at the edge with a cupped hand:
            // the head is choked, so the tone barely speaks and the crack
            // carries it. That crack is the reason the drum can be heard over
            // a band at all.
            .{ .name = "slap", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 262.0, .tone2_hz = 417.0, .body_decay = 55.0, .tone2_decay_mul = 2.2, .slap_decay = 260.0, .slap_mix = 0.95, .drive = 2.6, .dur_s = 0.14, .seed = 0x814 } }, .gain = 0.84 },
            // Bongos are small, high and quick - the hembra sits around E4
            // and the macho around B4, and neither rings anywhere near as
            // long as a conga.
            .{ .name = "bongo-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 330.0, .tone2_hz = 526.0, .body_decay = 26.0, .tone2_decay_mul = 2.4, .slap_mix = 0.4, .drive = 1.6, .dur_s = 0.24, .seed = 0x815 } }, .gain = 0.82 },
            .{ .name = "bongo-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 494.0, .tone2_hz = 787.0, .body_decay = 32.0, .tone2_decay_mul = 2.4, .slap_mix = 0.45, .drive = 1.6, .dur_s = 0.2, .seed = 0x816 } }, .gain = 0.80 },
            // Timbales are the odd pair here: a thin, high-tension head on a
            // metal shell, so the shell rings with the head instead of
            // swallowing it. They keep the fourth between them and hold their
            // upper partial far longer than a hide drum does.
            .{ .name = "timbale-lo", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 300.0, .tone2_hz = 478.0, .body_decay = 14.0, .tone2_decay_mul = 1.5, .slap_mix = 0.45, .drive = 2.2, .dur_s = 0.45, .seed = 0x817 } }, .gain = 0.84 },
            .{ .name = "timbale-hi", .kind = .perc, .params = .{ .perc = .{ .tone1_hz = 400.0, .tone2_hz = 637.0, .body_decay = 16.0, .tone2_decay_mul = 1.5, .slap_mix = 0.5, .drive = 2.2, .dur_s = 0.4, .seed = 0x818 } }, .gain = 0.82 },
            // Rosewood bars: a fundamental around 1.2 kHz with the bar's
            // second mode at 2.76x, and they ring - a quarter of a second,
            // not the 50 ms click the drum machines make of them.
            .{ .name = "clave", .kind = .rim, .params = .{ .rim = .{ .tone1_hz = 1200.0, .tone2_hz = 3312.0, .tone_decay = 18.0, .tone2_decay_mul = 3.5, .click_decay = 500.0, .drive = 1.3, .dur_s = 0.25 } }, .gain = 0.70 },
            // A slit block is hollower and lower than a clave and damped by
            // the hand that holds it, so the same bar ratio over a shorter
            // ring.
            .{ .name = "woodblock", .kind = .rim, .params = .{ .rim = .{ .tone1_hz = 900.0, .tone2_hz = 2484.0, .tone_decay = 42.0, .tone2_decay_mul = 3.0, .click_decay = 420.0, .drive = 1.5, .dur_s = 0.14 } }, .gain = 0.70 },
            // Struck metal, where the partials are inharmonic and both ring:
            // the cowbell's classic 587/845 pair (1:1.44) and the agogo's
            // higher, brighter one. No decay multiplier - a bell's upper
            // partial is exactly what sustains.
            .{ .name = "chacha", .kind = .rim, .params = .{ .rim = .{ .tone1_hz = 587.0, .tone2_hz = 845.0, .tone_decay = 16.0, .click_decay = 90.0, .drive = 1.6, .dur_s = 0.32 } }, .gain = 0.66 },
            .{ .name = "campana", .kind = .rim, .params = .{ .rim = .{ .tone1_hz = 440.0, .tone2_hz = 632.0, .tone_decay = 10.0, .click_decay = 60.0, .drive = 2.0, .dur_s = 0.45 } }, .gain = 0.68 },
            // Shakers are the hat generator with its metal cluster filtered
            // out of the way (body_hz well above the partials), leaving the
            // air path as the whole sound - which is what a shaker is.
            .{ .name = "maracas", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.06, .decay = 95.0, .body_hz = 12_000.0, .air_hz = 4500.0, .air_mix = 1.0 } }, .gain = 0.56 },
            .{ .name = "chekere", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.13, .decay = 42.0, .body_hz = 5000.0, .air_hz = 3200.0, .air_mix = 0.8 } }, .gain = 0.56 },
            // Tambourine keeps some cluster: the jingles are the metal part.
            .{ .name = "guiro", .kind = .hat, .params = .{ .hat = .{ .dur_s = 0.3, .decay = 3.5, .body_hz = 9000.0, .air_hz = 2600.0, .air_mix = 1.0, .ratchet_hz = 85.0 } }, .gain = 0.54 },
            // A surdo is a 16-20 inch drum carried on a strap and struck with
            // a beater: its fundamental sits under 100 Hz, well below where
            // the old 110 Hz sweep started, and an open stroke rings for the
            // best part of a second.
            .{ .name = "bombo", .kind = .tom, .params = .{ .tom = .{ .freq_start = 120.0, .freq_end = 72.0, .dur_s = 0.7, .body_decay = 5.0, .attack_decay = 90.0, .drive = 1.9, .attack_mix = 0.18, .seed = 0x819 } }, .gain = 0.92 },
        },
    },
};

/// Look a factory kit up by name, or null if there is no such flavour.
pub fn byName(name: []const u8) ?*const KitVariant {
    const current_name = if (std.mem.eql(u8, name, "default")) "digital" else name;
    for (&variants) |*v| {
        if (std.mem.eql(u8, v.name, current_name)) return v;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests

test "default drum kit name remains a load alias for digital" {
    try std.testing.expectEqualStrings("digital", byName("default").?.name);
}

test "pads sharing a generator are tuned into different drums" {
    for (variants) |variant| {
        for (variant.pads, 0..) |a, i| {
            const kind_a = a.kind orelse continue;
            for (variant.pads[i + 1 ..]) |b| {
                if (b.kind != kind_a or !std.meta.eql(a.params, b.params)) continue;
                // Same audio on both pads: only the tuning tells them apart,
                // and a gain difference alone is the same drum twice.
                try std.testing.expect(!std.meta.eql(a.tune, b.tune));
            }
        }
    }
}

test "every kit variant's pads produce audible, finite output" {
    for (variants) |variant| {
        for (variant.pads) |slot| {
            const kind = slot.kind orelse continue; // empty slot (the "init" kit)
            const buf = try genSlot(kind, slot.params, std.testing.allocator, 48_000);
            defer std.testing.allocator.free(buf);
            try std.testing.expect(buf.len > 0);
            var peak: f32 = 0;
            for (buf) |s| {
                try std.testing.expect(std.math.isFinite(s));
                peak = @max(peak, @abs(s));
            }
            try std.testing.expect(peak > 0.05);
            try std.testing.expect(peak <= 1.0); // never clips the pad buffer
        }
    }
}

test "every crash strikes harder than the same crash without its stick hit" {
    const rms = struct {
        fn f(w: []const f32) f32 {
            var sum: f32 = 0;
            for (w) |s| sum += s * s;
            return @sqrt(sum / @as(f32, @floatFromInt(w.len)));
        }
        /// Strike (first 10 ms) over wash (100-200 ms) - what "has a transient"
        /// means in numbers.
        fn ratio(buf: []const f32) f32 {
            return f(buf[0..4_800]) / f(buf[48_000..96_000]);
        }
    };
    for (variants) |v| {
        for (v.pads) |slot| {
            if (slot.kind != .hat or !std.mem.eql(u8, slot.name, "crash")) continue;
            // 480 kHz so even the shortest crash (0.44 s) outruns the windows.
            const hit = try genSlot(.hat, slot.params, std.testing.allocator, 480_000);
            defer std.testing.allocator.free(hit);
            var flat_params = slot.params;
            flat_params.hat.attack_mix = 0;
            const flat = try genSlot(.hat, flat_params, std.testing.allocator, 480_000);
            defer std.testing.allocator.free(flat);
            // Most kits gain 1.5-1.9x here. The chiptune kit no longer takes
            // part: its crash is a `.chip` noise pad, which has no separate
            // stick layer to compare against because the chip has no way to
            // strike one channel with two envelopes.
            try std.testing.expect(rms.ratio(hit) > rms.ratio(flat) * 1.2);
        }
    }
}

test "a chip pad emits only the levels a chip has" {
    // A two-level source times a 4-bit volume is at most 31 distinct sample
    // values, however long the hit runs. Anything smooth on this path - a
    // filter, a fade, an interpolated envelope - multiplies that count
    // immediately, which is why it is worth measuring: the quantisation is
    // the sound, not an artifact of it.
    for (variants) |v| {
        for (v.pads) |slot| {
            if (slot.kind != .chip) continue;
            const p = slot.params.chip;
            // The triangle has sixteen levels of its own and a mixed-in noise
            // channel adds a second source, so neither is a two-level pad.
            if (p.source == .triangle or p.noise_mix > 0.0) continue;
            const buf = try genSlot(.chip, slot.params, std.testing.allocator, 48_000);
            defer std.testing.allocator.free(buf);
            var seen: [64]f32 = undefined;
            var n: usize = 0;
            for (buf) |s| {
                const known = for (seen[0..n]) |q| {
                    if (q == s) break true;
                } else false;
                if (known) continue;
                try std.testing.expect(n < seen.len);
                seen[n] = s;
                n += 1;
            }
            try std.testing.expect(n <= 31);
        }
    }
}

test "the noise register runs the two sequence lengths the hardware has" {
    // 32767 steps in normal mode and 93 in short mode. The 93 is the whole
    // reason short mode exists here: a sequence that short repeats inside a
    // millisecond, so it reads as a pitch rather than as noise, and that is
    // what a chip snare's buzz is.
    inline for (.{ .{ false, 32767 }, .{ true, 93 } }) |case| {
        var reg: Lfsr = .{ .short = case[0] };
        const start = reg.reg;
        var steps: usize = 0;
        while (steps < case[1]) : (steps += 1) _ = reg.next();
        try std.testing.expectEqual(start, reg.reg);
    }
}



test "the percussion kit's partials are the ones its instruments have" {
    // The numbers this kit was rebuilt on: a struck circular membrane's next
    // mode after the fundamental is the (1,1) at 1.593x, and a free bar's is
    // at 2.76x. Both are easy to "tidy" back into a musical interval by
    // someone reading the table later, and a perfect fifth is exactly what
    // was wrong with the first version of these pads.
    const v = byName("percussion").?;
    var membranes: usize = 0;
    var bars: usize = 0;
    for (v.pads) |slot| {
        switch (slot.kind orelse continue) {
            .perc => {
                const p = slot.params.perc;
                try std.testing.expectApproxEqRel(@as(f32, 1.593), p.tone2_hz / p.tone1_hz, 0.01);
                membranes += 1;
            },
            .rim => {
                // The bells are struck metal, not bars: inharmonic partials
                // that both ring, which is why they are exempt here.
                if (std.mem.eql(u8, slot.name, "chacha") or std.mem.eql(u8, slot.name, "campana")) continue;
                const p = slot.params.rim;
                try std.testing.expectApproxEqRel(@as(f32, 2.76), p.tone2_hz / p.tone1_hz, 0.01);
                bars += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 8), membranes); // 3 congas + slap + 2 bongos + 2 timbales
    try std.testing.expectEqual(@as(usize, 2), bars); // clave, woodblock
}


test "the guiro is a train of clicks and the shaken gourds are not" {
    // What separates a scrape from a shake: the pua crosses one ridge at a
    // time, so the sound is separate strikes at the rate of the ridges, while
    // maracas and a chekere are a single burst of beads. Without the ratchet
    // the guiro is just a long shaker, which is what it used to be.
    const v = byName("percussion").?;
    const bursts = struct {
        fn count(buf: []const f32) usize {
            const win = 240; // 5 ms
            var n: usize = 0;
            var prev: f32 = 0;
            var rising = false;
            var i: usize = 0;
            while (i + win < buf.len) : (i += win) {
                var m: f32 = 0;
                for (buf[i .. i + win]) |x| m = @max(m, @abs(x));
                if (m > prev * 1.3 and m > 0.05) rising = true;
                if (rising and m < prev * 0.77) {
                    n += 1;
                    rising = false;
                }
                prev = m;
            }
            return n;
        }
    };
    for (v.pads) |slot| {
        const kind = slot.kind orelse continue;
        const scraped = std.mem.eql(u8, slot.name, "guiro");
        const shaken = std.mem.eql(u8, slot.name, "maracas") or std.mem.eql(u8, slot.name, "chekere");
        if (!scraped and !shaken) continue;
        const buf = try genSlot(kind, slot.params, std.testing.allocator, 48_000);
        defer std.testing.allocator.free(buf);
        const n = bursts.count(buf);
        if (scraped) try std.testing.expect(n > 15) else try std.testing.expect(n <= 2);
    }
}
