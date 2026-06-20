//! Polyphonic subtractive synth: oscillator per voice with an ADSR
//! amplitude envelope. Deliberately simple — it is the first
//! instrument the keyboard plays, not the last.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Waveform = enum { sine, saw, triangle, square };

pub const PolySynth = struct {
    sample_rate: f32,
    waveform: Waveform = .saw,
    /// Global pitch offset in cents. ±100 = ±1 semitone.
    detune_cents: f32 = 0.0,
    attack_s: f32 = 0.005,
    decay_s: f32 = 0.08,
    sustain: f32 = 0.7,
    release_s: f32 = 0.25,
    /// Filter cutoff in Hz. 20 Hz–Nyquist. Default open (18 kHz).
    filter_cutoff: f32 = 18_000.0,
    /// Filter resonance 0..1 (mapped to Q 0.5..20).
    filter_res: f32 = 0.0,
    gain: f32 = 0.35,
    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,
    /// Cached LP biquad coefficients — recomputed per block.
    filt_b0: f32 = 1.0, filt_b1: f32 = 0.0, filt_b2: f32 = 0.0,
    filt_a1: f32 = 0.0, filt_a2: f32 = 0.0,

    pub const max_voices = 8;

    const Stage = enum { attack, decay, sustain, release };

    const Voice = struct {
        active: bool = false,
        note: u7 = 0,
        velocity: f32 = 0.0,
        phase: f32 = 0.0,
        env: f32 = 0.0,
        stage: Stage = .attack,
        /// Per-voice DF1 biquad state (x = input history, y = output history).
        x1: f32 = 0.0, x2: f32 = 0.0,
        y1: f32 = 0.0, y2: f32 = 0.0,
    };

    pub fn init(sample_rate: u32) PolySynth {
        return .{ .sample_rate = @floatFromInt(sample_rate) };
    }

    pub fn device(self: *PolySynth) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: dsp.Device.VTable = .{
        .process = processOpaque,
        .event = eventOpaque,
        .reset = resetOpaque,
    };

    pub fn noteToFreq(note: u7) f32 {
        const n: f32 = @floatFromInt(note);
        return 440.0 * std.math.pow(f32, 2.0, (n - 69.0) / 12.0);
    }

    pub fn noteOn(self: *PolySynth, note: u7, velocity: f32) void {
        const voice = self.allocVoice();
        voice.* = .{
            .active = true,
            .note = note,
            .velocity = velocity,
            .stage = .attack,
        };
    }

    pub fn noteOff(self: *PolySynth, note: u7) void {
        for (&self.voices) |*v| {
            if (v.active and v.note == note and v.stage != .release) {
                v.stage = .release;
            }
        }
    }

    fn allocVoice(self: *PolySynth) *Voice {
        var quietest: *Voice = &self.voices[0];
        for (&self.voices) |*v| {
            if (!v.active) return v;
            if (v.env < quietest.env) quietest = v;
        }
        return quietest; // steal the quietest voice
    }

    pub fn processBlock(self: *PolySynth, buf: []Sample) void {
        const frames = buf.len / 2;
        const attack_inc  = 1.0 / @max(self.attack_s  * self.sample_rate, 1.0);
        const decay_inc   = (1.0 - self.sustain) / @max(self.decay_s * self.sample_rate, 1.0);
        const release_inc = 1.0 / @max(self.release_s * self.sample_rate, 1.0);

        self.recomputeFilter();

        for (&self.voices) |*v| {
            if (!v.active) continue;
            const freq = noteToFreq(v.note) *
                std.math.pow(f32, 2.0, self.detune_cents / 1200.0);
            const phase_inc = freq / self.sample_rate;

            for (0..frames) |i| {
                // Oscillator
                const osc = self.oscSample(v.phase);
                v.phase += phase_inc;
                if (v.phase >= 1.0) v.phase -= 1.0;

                // LP filter — signal flow: OSC → FILTER → AMP
                const filt = self.filt_b0 * osc
                           + self.filt_b1 * v.x1 + self.filt_b2 * v.x2
                           - self.filt_a1 * v.y1 - self.filt_a2 * v.y2;
                v.x2 = v.x1; v.x1 = osc;
                v.y2 = v.y1; v.y1 = filt;

                // Amplitude envelope + output
                const s = filt * v.env * v.velocity * self.gain;
                buf[i * 2]     += s;
                buf[i * 2 + 1] += s;

                // Advance envelope
                switch (v.stage) {
                    .attack => {
                        v.env += attack_inc;
                        if (v.env >= 1.0) { v.env = 1.0; v.stage = .decay; }
                    },
                    .decay => {
                        v.env -= decay_inc;
                        if (v.env <= self.sustain) { v.env = self.sustain; v.stage = .sustain; }
                    },
                    .sustain => {},
                    .release => {
                        v.env -= release_inc;
                        if (v.env <= 0.0) { v.* = .{}; break; }
                    },
                }
            }
        }
    }

    fn recomputeFilter(self: *PolySynth) void {
        // RBJ Audio EQ Cookbook — Low Pass Filter.
        // res [0,1] → Q [0.5, 20]: low res = gentle slope, high res = resonant peak.
        const q = 0.5 + self.filter_res * 19.5;
        const cutoff = std.math.clamp(self.filter_cutoff, 20.0, self.sample_rate * 0.49);
        const w0 = 2.0 * std.math.pi * cutoff / self.sample_rate;
        const cos_w0 = @cos(w0);
        const alpha = @sin(w0) / (2.0 * q);
        const a0_inv = 1.0 / (1.0 + alpha);
        self.filt_b0 = ((1.0 - cos_w0) / 2.0) * a0_inv;
        self.filt_b1 = (1.0 - cos_w0) * a0_inv;
        self.filt_b2 = self.filt_b0;
        self.filt_a1 = (-2.0 * cos_w0) * a0_inv;
        self.filt_a2 = (1.0 - alpha) * a0_inv;
    }

    fn oscSample(self: *const PolySynth, phase: f32) Sample {
        return switch (self.waveform) {
            .sine     => @sin(2.0 * std.math.pi * phase),
            .saw      => 2.0 * phase - 1.0,
            .triangle => 1.0 - 4.0 * @abs(phase - 0.5),
            .square   => if (phase < 0.5) 1.0 else -1.0,
        };
    }

    pub fn resetAll(self: *PolySynth) void {
        for (&self.voices) |*v| v.* = .{}; // zeroes all fields including filter state
    }

    fn processOpaque(ptr: *anyopaque, buf: []Sample) void {
        const self: *PolySynth = @ptrCast(@alignCast(ptr));
        self.processBlock(buf);
    }

    fn eventOpaque(ptr: *anyopaque, ev: dsp.Event) void {
        const self: *PolySynth = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .note_on => |e| self.noteOn(e.note, e.velocity),
            .note_off => |e| self.noteOff(e.note),
            .all_off => self.resetAll(),
        }
    }

    fn resetOpaque(ptr: *anyopaque) void {
        const self: *PolySynth = @ptrCast(@alignCast(ptr));
        self.resetAll();
    }
};

test "A4 tuning" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), PolySynth.noteToFreq(69), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), PolySynth.noteToFreq(60), 0.01);
}

test "filter: high-Q sweep near Nyquist stays finite" {
    var synth = PolySynth.init(48_000);
    synth.filter_cutoff = 22_000.0; // above Nyquist — should be clamped
    synth.filter_res = 1.0;         // maximum resonance
    synth.noteOn(60, 1.0);

    var buf: [512]Sample = undefined;
    for (0..32) |_| {
        @memset(&buf, 0.0);
        synth.processBlock(&buf);
        for (buf) |s| {
            try std.testing.expect(!std.math.isNan(s));
            try std.testing.expect(!std.math.isInf(s));
        }
    }
}

test "filter: closed cutoff attenuates high-frequency content" {
    // Saw at 1 kHz through a 200 Hz LP filter should be much quieter.
    var open = PolySynth.init(48_000);
    open.waveform = .saw;
    open.filter_cutoff = 18_000.0;
    open.filter_res = 0.0;
    open.noteOn(84, 1.0); // C6 ≈ 1047 Hz

    var closed = PolySynth.init(48_000);
    closed.waveform = .saw;
    closed.filter_cutoff = 200.0;
    closed.filter_res = 0.0;
    closed.noteOn(84, 1.0);

    var buf_open: [512]Sample = undefined;
    var buf_closed: [512]Sample = undefined;
    // Warm up past attack
    for (0..20) |_| {
        @memset(&buf_open, 0.0);   open.processBlock(&buf_open);
        @memset(&buf_closed, 0.0); closed.processBlock(&buf_closed);
    }

    var rms_open: f32 = 0.0;
    var rms_closed: f32 = 0.0;
    for (buf_open, buf_closed) |o, c| {
        rms_open   += o * o;
        rms_closed += c * c;
    }
    try std.testing.expect(rms_closed < rms_open * 0.1); // at least 10× quieter
}

test "voice lifecycle: silence, sound, release back to silence" {
    var synth = PolySynth.init(48_000);
    var buf: [512]Sample = undefined;

    @memset(&buf, 0.0);
    synth.processBlock(&buf);
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);

    synth.noteOn(60, 1.0);
    @memset(&buf, 0.0);
    synth.processBlock(&buf);
    var peak: f32 = 0.0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.01);

    synth.noteOff(60);
    // render past the release tail (0.25 s = 12_000 frames)
    for (0..60) |_| {
        @memset(&buf, 0.0);
        synth.processBlock(&buf);
    }
    for (buf) |s| try std.testing.expectEqual(@as(Sample, 0.0), s);
    for (synth.voices) |v| try std.testing.expect(!v.active);
}

test "polyphony allocates distinct voices" {
    var synth = PolySynth.init(48_000);
    synth.noteOn(60, 1.0);
    synth.noteOn(64, 1.0);
    synth.noteOn(67, 1.0);
    var active: u32 = 0;
    for (synth.voices) |v| {
        if (v.active) active += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), active);
}
