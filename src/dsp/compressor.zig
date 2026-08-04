//! Feed-forward stereo-linked compressor: peak envelope follower,
//! dB-domain gain computer, makeup gain.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Compressor = struct {
    /// Which track (and, optionally, which drum pad within it) this
    /// compressor's envelope follower should detect from instead of its own
    /// input. `pad` null means "the whole track's post-chain mix" (the
    /// original, track-only behaviour); set it to key off one drum pad in
    /// isolation (e.g. duck the bass under just the kick, not the whole
    /// drum bus's snare/hats too) - see `DrumMachine`'s `Event.capture_pad`
    /// handling. Only meaningful when `track` holds a `DrumMachine`
    /// instrument; on any other instrument kind the engine never receives a
    /// matching pad capture, so it silently behaves as if `pad` were null
    /// (no crash, just no signal - same "registered but never rendered"
    /// fallback a dead whole-track source already gets).
    pub const SidechainSource = struct {
        track: u16,
        pad: ?u8 = null,
        /// When true, `track` holds a group submix bus index (0..
        /// `engine.max_groups`) instead of a track index, and `pad` is
        /// unused/meaningless - duck against a whole bus (e.g. the drum
        /// group) instead of one track. Ordering constraint: a group source
        /// only resolves for a consumer that renders AFTER it - any group
        /// with a higher bank index, or the master chain (always last).
        /// Tracks render before any group's own FX chain runs, so a
        /// track-level compressor can't sidechain off a group in this
        /// version; see `Engine.renderTracks`'s group-processing loop for
        /// where the capture is finalized.
        is_group: bool = false,
    };

    sample_rate: f32 = 48_000.0,
    threshold_db: f32 = -18.0,
    ratio: f32 = 4.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 80.0,
    makeup_db: f32 = 0.0,
    /// Width of the soft-knee transition around threshold, dB. 0 = hard
    /// knee (the ratio applies the instant `over_db` crosses 0).
    knee_db: f32 = 0.0,
    /// Envelope follower state (linear peak).
    env: f32 = 0.0,
    /// Most recent gain change before makeup, for UI metering.
    gain_reduction_db: f32 = 0.0,
    /// Which track (and optionally which drum pad) this compressor's
    /// envelope follower should detect from instead of its own input -
    /// `null` (default) is ordinary self-detecting compression. Persisted
    /// (see persist.zig's CompSnap); the engine translates this into a
    /// per-chain-slot routing table on the control thread whenever the
    /// chain syncs (see `Session`'s sidechain resync), since the audio
    /// thread never introspects chain contents live.
    sidechain_source: ?SidechainSource = null,
    /// This block's external detector signal, pushed by the engine via
    /// `Event.set_sidechain_buf` right before `process()` runs, only when
    /// `sidechain_source` is set and that track was actually rendered this
    /// block. Consumed (reset to null) at the start of every `processBlock`
    /// call, so a source that stops rendering (deleted, deactivated, or the
    /// chain hasn't resynced yet) falls back to self-detection rather than
    /// reusing a stale buffer from a prior block.
    detector: ?[]const Sample = null,

    pub fn init(sample_rate: u32) Compressor {
        return .{ .sample_rate = @floatFromInt(@max(sample_rate, 1)) };
    }

    pub const device = dsp.deviceOf(@This());

    /// Feed-forward envelope-follower update (attack/release smoothing).
    /// Shared with `MultibandComp`'s per-band stage (`dsp/multiband_comp.zig`
    /// `BandComp.gainFor`) - returns the updated envelope's dB-over-threshold
    /// value (`env_db - threshold_db`; negative means under threshold) so
    /// both can build their own gain-reduction formula on top of it.
    pub fn envelopeOverDb(env: *f32, level: f32, attack: f32, release: f32, threshold_db: f32) f32 {
        const coef = if (level > env.*) attack else release;
        env.* = coef * env.* + (1.0 - coef) * level;
        return types.gainToDb(env.*) - threshold_db;
    }

    /// Ordinary downward gain reduction in dB for `over_db` above threshold
    /// (0 when at or under it) - the ratio formula shared by `processBlock`
    /// and `BandComp.gainFor`'s downward stage. `knee_db` widens the
    /// transition around the threshold into a quadratic curve instead of an
    /// instant bend (0 = the original hard knee, exactly the old formula);
    /// the standard soft-knee gain computer (Reiss & McPherson, "Audio
    /// Effects" ch. 4).
    pub fn downwardReductionDb(over_db: f32, ratio: f32, knee_db: f32) f32 {
        const slope = 1.0 / ratio - 1.0;
        if (knee_db <= 0.0) return if (over_db > 0.0) over_db * slope else 0.0;
        const half = knee_db * 0.5;
        if (over_db <= -half) return 0.0;
        if (over_db >= half) return over_db * slope;
        const x = over_db + half;
        return slope * (x * x) / (2.0 * knee_db);
    }

    pub fn processBlock(self: *Compressor, buf: []Sample) void {
        const frames = buf.len / 2;
        // A non-positive attack_ms/release_ms flips smoothingCoef's exponent
        // positive (coef >= 1, diverges within a block); a ratio near/under
        // 0 sends downwardReductionDb's `1/ratio` toward +-inf.
        const attack_ms = dsp.sanitizeParam(self.attack_ms, 0.1, 500.0, 10.0);
        const release_ms = dsp.sanitizeParam(self.release_ms, 1.0, 2000.0, 80.0);
        const ratio = dsp.sanitizeParam(self.ratio, 1.0, 20.0, 4.0);
        const threshold_db = dsp.sanitizeParam(self.threshold_db, -60.0, 0.0, -18.0);
        const makeup_db = dsp.sanitizeParam(self.makeup_db, -24.0, 24.0, 0.0);
        const knee_db = dsp.sanitizeParam(self.knee_db, 0.0, 24.0, 0.0);
        const attack = dsp.smoothingCoefMs(attack_ms, self.sample_rate);
        const release = dsp.smoothingCoefMs(release_ms, self.sample_rate);
        const makeup = types.dbToGain(makeup_db);
        // Detector buffer must match this block's frame count to be safe to
        // index alongside `buf` - a mismatched length (chain resync landed
        // mid-block, or the source track rendered a short final block) falls
        // back to self-detection rather than risking an out-of-bounds read.
        const det = if (self.detector) |d| (if (d.len == buf.len) d else null) else null;
        self.detector = null;

        for (0..frames) |i| {
            const level = if (det) |d|
                @max(@abs(d[i * 2]), @abs(d[i * 2 + 1]))
            else
                @max(@abs(buf[i * 2]), @abs(buf[i * 2 + 1]));
            const over_db = envelopeOverDb(&self.env, level, attack, release, threshold_db);
            const reduction_db = downwardReductionDb(over_db, ratio, knee_db);
            self.gain_reduction_db = reduction_db;
            const gain = types.dbToGain(reduction_db) * makeup;

            buf[i * 2] *= gain;
            buf[i * 2 + 1] *= gain;
        }
    }

    pub fn handleEvent(self: *Compressor, ev: dsp.Event) void {
        switch (ev) {
            .set_sidechain_buf => |e| self.detector = e.buf,
            .note_on, .note_off, .all_off, .cc, .pitch_bend, .set_param, .set_param_abs, .automation_param, .clap_param, .vst3_param, .capture_pad => {},
        }
    }

    /// Clears envelope/detector state without touching `sample_rate` -
    /// callers embedding a `Compressor` by value (e.g. PolySynth's internal
    /// FX section) must use this instead of `= .{}`, which would reset
    /// sample_rate to the struct default and desync it from the real
    /// session rate.
    pub fn reset(self: *Compressor) void {
        self.env = 0.0;
        self.gain_reduction_db = 0.0;
        self.detector = null;
    }
};

test "attenuates loud signals, passes quiet ones" {
    var comp = Compressor.init(48_000);
    comp.threshold_db = -12.0;
    comp.ratio = 4.0;
    comp.attack_ms = 0.1;

    // loud: 0 dBFS square - should be pulled toward -9 dB
    // (-12 + 12/4), i.e. well below full scale once the envelope settles
    var loud = [_]Sample{1.0} ** 9600;
    comp.processBlock(&loud);
    try std.testing.expect(comp.gain_reduction_db < 0.0);
    try std.testing.expect(@abs(loud[loud.len - 2]) < 0.5);

    // quiet: -40 dB - should pass through nearly untouched
    comp.env = 0.0;
    var quiet = [_]Sample{0.01} ** 9600;
    comp.processBlock(&quiet);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.01), quiet[quiet.len - 2], 1e-4);
}

test "sidechain detector overrides self-detection, and is consumed after one block" {
    var comp = Compressor.init(48_000);
    comp.threshold_db = -12.0;
    comp.ratio = 4.0;
    comp.attack_ms = 0.1;
    comp.sidechain_source = .{ .track = 3 }; // just marks intent; processBlock only reads `detector`

    // Quiet signal, but a LOUD detector buffer - the quiet signal itself
    // should still get compressed because the detector, not its own input,
    // drives the envelope.
    const loud_detector = [_]Sample{1.0} ** 9600;
    var quiet = [_]Sample{0.05} ** 9600;
    comp.detector = &loud_detector;
    comp.processBlock(&quiet);
    try std.testing.expect(@abs(quiet[quiet.len - 2]) < 0.05); // gain-reduced below its own input level

    // The detector is consumed - a second block with no new detector falls
    // back to self-detection (envelope relaxes toward the now-quiet input).
    try std.testing.expect(comp.detector == null);
    comp.env = 0.0;
    var quiet2 = [_]Sample{0.05} ** 9600;
    comp.processBlock(&quiet2);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.05), quiet2[quiet2.len - 2], 1e-3);
}

test "invalid parameters cannot trap or poison output" {
    var comp = Compressor.init(48_000);
    comp.threshold_db = std.math.nan(f32);
    comp.ratio = 0.0;
    comp.attack_ms = -5.0;
    comp.release_ms = std.math.inf(f32);
    comp.makeup_db = std.math.inf(f32);
    comp.knee_db = std.math.nan(f32);
    var buf: [256]Sample = undefined;
    for (&buf, 0..) |*s, i| s.* = if (i % 4 < 2) 0.3 else -0.7;
    comp.processBlock(&buf);
    for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "soft knee eases reduction in before threshold, hard knee doesn't" {
    // Exactly at threshold: hard knee (knee=0) applies zero reduction since
    // downwardReductionDb only kicks in once over_db > 0; a wide soft knee
    // already has the curve halfway bent by that point.
    try std.testing.expectEqual(@as(f32, 0.0), Compressor.downwardReductionDb(0.0, 4.0, 0.0));
    try std.testing.expect(Compressor.downwardReductionDb(0.0, 4.0, 12.0) < 0.0);
    // Far outside the knee on either side, the two must agree with the
    // plain ratio formula (soft knee only perturbs the transition itself).
    try std.testing.expectApproxEqAbs(
        Compressor.downwardReductionDb(20.0, 4.0, 0.0),
        Compressor.downwardReductionDb(20.0, 4.0, 12.0),
        1e-4,
    );
    try std.testing.expectEqual(@as(f32, 0.0), Compressor.downwardReductionDb(-20.0, 4.0, 12.0));
}

test "detector length mismatch falls back to self-detection instead of an out-of-bounds read" {
    var comp = Compressor.init(48_000);
    comp.threshold_db = -12.0;
    comp.ratio = 4.0;
    const short_detector = [_]Sample{1.0} ** 4; // deliberately not buf.len
    var quiet = [_]Sample{0.05} ** 9600;
    comp.detector = &short_detector;
    comp.processBlock(&quiet); // must not panic/crash
    try std.testing.expectApproxEqAbs(@as(Sample, 0.05), quiet[quiet.len - 2], 1e-3);
}
