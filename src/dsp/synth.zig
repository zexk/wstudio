//! Polyphonic subtractive synth: oscillator per voice with an ADSR
//! amplitude envelope. Deliberately simple — it is the first
//! instrument the keyboard plays, not the last.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");

const Sample = types.Sample;

pub const Waveform = enum { sine, saw, square };

pub const PolySynth = struct {
    sample_rate: f32,
    waveform: Waveform = .saw,
    attack_s: f32 = 0.005,
    decay_s: f32 = 0.08,
    sustain: f32 = 0.7,
    release_s: f32 = 0.25,
    gain: f32 = 0.35,
    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,

    pub const max_voices = 8;

    const Stage = enum { attack, decay, sustain, release };

    const Voice = struct {
        active: bool = false,
        note: u7 = 0,
        velocity: f32 = 0.0,
        phase: f32 = 0.0,
        env: f32 = 0.0,
        stage: Stage = .attack,
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
        const attack_inc = 1.0 / (self.attack_s * self.sample_rate);
        const decay_inc = (1.0 - self.sustain) / (self.decay_s * self.sample_rate);
        const release_inc = 1.0 / (self.release_s * self.sample_rate);

        for (&self.voices) |*v| {
            if (!v.active) continue;
            const phase_inc = noteToFreq(v.note) / self.sample_rate;
            for (0..frames) |i| {
                const s = self.oscSample(v.phase) * v.env * v.velocity * self.gain;
                buf[i * 2] += s;
                buf[i * 2 + 1] += s;

                v.phase += phase_inc;
                if (v.phase >= 1.0) v.phase -= 1.0;

                switch (v.stage) {
                    .attack => {
                        v.env += attack_inc;
                        if (v.env >= 1.0) {
                            v.env = 1.0;
                            v.stage = .decay;
                        }
                    },
                    .decay => {
                        v.env -= decay_inc;
                        if (v.env <= self.sustain) {
                            v.env = self.sustain;
                            v.stage = .sustain;
                        }
                    },
                    .sustain => {},
                    .release => {
                        v.env -= release_inc;
                        if (v.env <= 0.0) {
                            v.* = .{};
                            break;
                        }
                    },
                }
            }
        }
    }

    fn oscSample(self: *const PolySynth, phase: f32) Sample {
        return switch (self.waveform) {
            .sine => @sin(2.0 * std.math.pi * phase),
            .saw => 2.0 * phase - 1.0,
            .square => if (phase < 0.5) 1.0 else -1.0,
        };
    }

    pub fn resetAll(self: *PolySynth) void {
        for (&self.voices) |*v| v.* = .{};
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
