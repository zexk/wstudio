//! Feed-forward stereo-linked compressor: peak envelope follower,
//! dB-domain gain computer, makeup gain.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const detector = @import("detector.zig");

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
    /// How long gain reduction is held at its deepest before release starts,
    /// in ms. 0 = old behaviour (release begins the frame the level drops).
    /// Same argument as the gate's hold: a source that dips between hits
    /// otherwise lets the compressor recover and re-clamp, which is heard as
    /// pumping rather than as level control.
    hold_ms: f32 = 0.0,
    /// 0 = downward (clamp what is over the threshold), 1 = upward (lift
    /// what is under it). Upward is the same gain computer mirrored around
    /// the threshold, which is why it costs a mode rather than a second
    /// unit; `ott.zig` has always had it per band, the plain compressor did
    /// not.
    mode: f32 = 0.0,
    /// Dry/wet blend of the compressed signal, 1 = fully compressed. Below
    /// 1 this is parallel ("New York") compression: the uncompressed signal
    /// keeps its transients while the compressed copy fills in underneath.
    mix: f32 = 1.0,
    makeup_db: f32 = 0.0,
    /// Width of the soft-knee transition around threshold, dB. 0 = hard
    /// knee (the ratio applies the instant `over_db` crosses 0).
    knee_db: f32 = 0.0,
    /// Detector shaping, applied to whatever drives the envelope (this
    /// unit's own input, or the external sidechain buffer). 0 = peak,
    /// 1 = RMS. Peak reacts to every transient, RMS to how loud the source
    /// actually is, which is the difference between a compressor that
    /// chases snare hits and one that rides a vocal.
    sc_mode: f32 = 0.0,
    /// Detector high-pass, Hz; 0 = off. The most-reached-for sidechain
    /// control there is: without it a bass-heavy source holds the detector
    /// over the threshold continuously, so the compressor never lets go and
    /// nothing above the bass gets shaped.
    sc_hpf_hz: f32 = 0.0,
    /// Detector low-pass, Hz; 0 = off. The mirror of `sc_hpf_hz`, for
    /// keying off body rather than off cymbals and sibilance.
    sc_lpf_hz: f32 = 0.0,
    /// Envelope follower state (linear peak).
    env: f32 = 0.0,
    /// Detector filter/RMS state, shared with every other dynamics unit -
    /// see `dsp/detector.zig`.
    det_state: detector.Detector = .{},
    /// Frames left in the current hold window, counted down one per frame.
    hold_left: f32 = 0.0,
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

    /// How far the upward stage may lift a signal, the "range" every upward
    /// compressor bounds itself with. Unbounded, the mirrored formula asks
    /// for whatever the distance to `gainToDb`'s -120dB floor happens to be:
    /// an idle OTT sat at +79dB per band, so the moment a track went quiet
    /// its noise floor was pumped up to near full scale. 24dB matches the
    /// makeup range and only engages ~30dB below the threshold, well under
    /// any musical level.
    pub const max_upward_db: f32 = 24.0;

    /// Upward gain in dB for `over_db` under the threshold (0 when at or
    /// over it) - the downward formula mirrored around the threshold, so
    /// one `ratio` describes both directions. Shared by this unit's `.up`
    /// mode and `MultibandComp`'s OTT style.
    pub fn upwardBoostDb(over_db: f32, ratio: f32) f32 {
        if (over_db > 0.0) return 0.0;
        return @min(-over_db * (1.0 - 1.0 / ratio), max_upward_db);
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
        const hold_ms = dsp.sanitizeParam(self.hold_ms, 0.0, 500.0, 0.0);
        const mix = dsp.sanitizeParam(self.mix, 0.0, 1.0, 1.0);
        const upward = dsp.sanitizeParam(self.mode, 0.0, 1.0, 0.0) >= 0.5;
        if (!std.math.isFinite(self.hold_left) or self.hold_left < 0.0) self.hold_left = 0.0;
        const attack = dsp.smoothingCoefMs(attack_ms, self.sample_rate);
        const release = dsp.smoothingCoefMs(release_ms, self.sample_rate);
        const hold_frames = hold_ms * 0.001 * self.sample_rate;
        const makeup = types.dbToGain(makeup_db);
        // Detector buffer must match this block's frame count to be safe to
        // index alongside `buf` - a mismatched length (chain resync landed
        // mid-block, or the source track rendered a short final block) falls
        // back to self-detection rather than risking an out-of-bounds read.
        const det = if (self.detector) |d| (if (d.len == buf.len) d else null) else null;
        self.detector = null;

        // Detector shaping. Left at defaults every branch is skipped and the
        // level is the same stereo peak it always was, bit for bit.
        const shaping = detector.shapingFor(
            dsp.sanitizeParam(self.sc_hpf_hz, 0.0, 2000.0, 0.0),
            dsp.sanitizeParam(self.sc_lpf_hz, 0.0, 20_000.0, 0.0),
            dsp.sanitizeParam(self.sc_mode, 0.0, 1.0, 0.0) >= 0.5,
            self.sample_rate,
        );
        if (!shaping.active()) self.det_state.reset();

        for (0..frames) |i| {
            const dl = if (det) |d| d[i * 2] else buf[i * 2];
            const dr = if (det) |d| d[i * 2 + 1] else buf[i * 2 + 1];
            const level = self.det_state.level(shaping, dl, dr);
            // Hold freezes the envelope (and so the gain reduction) at its
            // deepest instead of letting release start the moment the level
            // dips; a rise re-arms the window.
            if (level > self.env) {
                self.hold_left = hold_frames;
            } else if (self.hold_left > 0.0) {
                self.hold_left -= 1.0;
            }
            const over_db = if (self.hold_left > 0.0 and level <= self.env)
                types.gainToDb(self.env) - threshold_db
            else
                envelopeOverDb(&self.env, level, attack, release, threshold_db);
            const reduction_db = if (upward)
                upwardBoostDb(over_db, ratio)
            else
                downwardReductionDb(over_db, ratio, knee_db);
            self.gain_reduction_db = reduction_db;
            const gain = types.dbToGain(reduction_db) * makeup;
            // Parallel blend: the dry copy is the same sample, so the whole
            // mix collapses into one gain factor per frame.
            const blended = 1.0 - mix + gain * mix;

            buf[i * 2] *= blended;
            buf[i * 2 + 1] *= blended;
        }
    }

    pub fn handleEvent(self: *Compressor, ev: dsp.Event) void {
        switch (ev) {
            .set_sidechain_buf => |e| self.detector = e.buf,
            .note_on, .note_off, .all_off, .cc, .pitch_bend, .set_param, .set_param_abs, .set_mod_target, .automation_param, .clap_param, .vst3_param, .capture_pad => {},
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
        self.hold_left = 0.0;
        self.det_state.reset();
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

test "upward mode lifts a quiet signal toward the threshold" {
    var comp = Compressor.init(48_000);
    comp.threshold_db = -12.0;
    comp.ratio = 4.0;
    comp.attack_ms = 0.1;
    comp.mode = 1.0;

    // -30dB, well under the threshold: upward pulls it up by
    // 18 * (1 - 1/4) = 13.5dB, capped well short of max_upward_db.
    var quiet = [_]Sample{types.dbToGain(-30.0)} ** 9600;
    comp.processBlock(&quiet);
    try std.testing.expect(comp.gain_reduction_db > 13.0);
    try std.testing.expect(@abs(quiet[quiet.len - 2]) > types.dbToGain(-30.0) * 4.0);

    // Over the threshold, upward leaves the signal alone (downward is the
    // other mode's job).
    comp.env = 0.0;
    var loud = [_]Sample{0.9} ** 9600;
    comp.processBlock(&loud);
    try std.testing.expectApproxEqAbs(@as(Sample, 0.9), loud[loud.len - 2], 1e-4);
}

test "mix blends between dry and fully compressed" {
    var dry = Compressor.init(48_000);
    dry.threshold_db = -24.0;
    dry.attack_ms = 0.1;
    dry.mix = 0.0;
    var wet = dry;
    wet.mix = 1.0;

    var buf_dry = [_]Sample{1.0} ** 4096;
    var buf_wet = [_]Sample{1.0} ** 4096;
    dry.processBlock(&buf_dry);
    wet.processBlock(&buf_wet);

    // mix 0 is a bypass; mix 1 is the compressed signal, quieter than it.
    try std.testing.expectEqual(@as(Sample, 1.0), buf_dry[4000]);
    try std.testing.expect(buf_wet[4000] < 0.5);
}

test "hold defers release until the window expires" {
    var comp = Compressor.init(48_000);
    comp.threshold_db = -24.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 5.0;
    comp.hold_ms = 100.0; // 4800 frames

    var loud = [_]Sample{1.0} ** 4096;
    comp.processBlock(&loud);
    const held = comp.gain_reduction_db;
    try std.testing.expect(held < -10.0);

    // 1000 frames of silence, inside the hold window: reduction unchanged.
    var quiet = [_]Sample{0.0} ** 2000;
    comp.processBlock(&quiet);
    try std.testing.expectApproxEqAbs(held, comp.gain_reduction_db, 1e-4);

    // Past the window the fast release recovers to no reduction.
    for (0..20) |_| comp.processBlock(&quiet);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), comp.gain_reduction_db, 1e-3);
}

test "detector high-pass keeps low end from holding the compressor down" {
    // A loud 50Hz tone under a quiet signal: unfiltered it pins the
    // detector over the threshold forever.
    const sr: f32 = 48_000.0;
    var plain = Compressor.init(48_000);
    plain.threshold_db = -24.0;
    plain.attack_ms = 1.0;
    var filtered = plain;
    filtered.sc_hpf_hz = 500.0;

    var buf_plain: [9600]Sample = undefined;
    for (0..buf_plain.len / 2) |i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const s = 0.8 * @sin(2.0 * std.math.pi * 50.0 * t);
        buf_plain[i * 2] = s;
        buf_plain[i * 2 + 1] = s;
    }
    var buf_filtered = buf_plain;
    plain.processBlock(&buf_plain);
    filtered.processBlock(&buf_filtered);

    try std.testing.expect(plain.gain_reduction_db < -10.0);
    // The 500Hz high-pass all but removes 50Hz from the detector, so the
    // compressor barely engages.
    try std.testing.expect(filtered.gain_reduction_db > plain.gain_reduction_db + 8.0);
}

test "RMS detection reacts less to a lone transient than peak does" {
    var peak = Compressor.init(48_000);
    peak.threshold_db = -30.0;
    peak.attack_ms = 0.1;
    var rms = peak;
    rms.sc_mode = 1.0;

    // One full-scale frame in an otherwise quiet block.
    var buf_peak = [_]Sample{0.02} ** 4096;
    buf_peak[100] = 1.0;
    buf_peak[101] = 1.0;
    var buf_rms = buf_peak;
    peak.processBlock(&buf_peak);
    rms.processBlock(&buf_rms);

    // Both settle on the same steady level; what differs is how hard the
    // spike hit on the way, so compare the sample right after it.
    try std.testing.expect(@abs(buf_rms[110]) > @abs(buf_peak[110]));
}

test "detector shaping left off is bit-identical to the plain peak detector" {
    var shaped = Compressor.init(48_000);
    shaped.threshold_db = -18.0;
    var plain = shaped;
    shaped.sc_hpf_hz = 0.0;
    shaped.sc_lpf_hz = 0.0;
    shaped.sc_mode = 0.0;

    var a = [_]Sample{0.0} ** 2048;
    for (&a, 0..) |*s, i| s.* = if (i % 8 < 4) 0.6 else -0.35;
    var b = a;
    shaped.processBlock(&a);
    plain.processBlock(&b);
    for (a, b) |x, y| try std.testing.expectEqual(y, x);
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
