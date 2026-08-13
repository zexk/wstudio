//! Audio-input (mic/line-in) capture, picked by OS the same way
//! `host.zig`'s `AudioHost` picks an output backend - but fully decoupled
//! from it. Capture never hooks into the output backend's render
//! callback: it opens its own device/stream, on its own thread, only for
//! the duration of a record pass (`App.startPendingRecording`/
//! `finishRecording`), and hands blocks to the control thread through a
//! lock-free queue it drains once per frame (`App.tick`).
//!
//! This keeps capture off `Engine`/`backend.zig`/the ~100+ existing
//! `engine.process` call sites entirely: on Linux it's a plain ALSA
//! capture PCM (`audio/backends/alsa.zig`'s `AlsaCapture`), independent of whichever
//! backend (PipeWire/JACK/ALSA) `host.zig` picked for output - ALSA's
//! "default" device is served by PipeWire (or shareable via dsnoop) on
//! virtually every desktop setup. A pure-JACK box with no such sharing is
//! the one disclosed gap: `start` just fails there and the record pass
//! proceeds MIDI-only with a status message, never a crash.

const std = @import("std");
const builtin = @import("builtin");
const capture_types = @import("capture_types.zig");

pub const CaptureBlock = capture_types.CaptureBlock;
pub const Dropout = capture_types.Dropout;
pub const chunk_frames = capture_types.chunk_frames;

const has_alsa = builtin.os.tag == .linux;
const has_wasapi = builtin.os.tag == .windows;
const has_coreaudio = builtin.os.tag == .macos;

const AlsaCapture = if (has_alsa) @import("backends/alsa.zig").AlsaCapture else void;
const WasapiCapture = if (has_wasapi) @import("backends/wasapi.zig").WasapiCapture else void;
const CoreAudioCapture = if (has_coreaudio) @import("backends/coreaudio.zig").CoreAudioCapture else void;

pub const Active = enum { none, alsa, wasapi, coreaudio };

pub const AudioInput = struct {
    alsa: AlsaCapture = if (has_alsa) .{} else {},
    wasapi: WasapiCapture = if (has_wasapi) .{} else {},
    coreaudio: CoreAudioCapture = if (has_coreaudio) .{} else {},
    active: Active = .none,
    stopped: Active = .none,

    /// Superset of both backends' error sets (`AlsaCapture.Error`,
    /// `WasapiCapture.Error`) plus `Unsupported` for a platform with
    /// neither compiled in - simpler than conditional error-set arithmetic
    /// for two sets that only differ by `ComInitFailed`.
    pub const Error = error{ Unsupported, InvalidSampleRate, ComInitFailed, DeviceOpenFailed, DeviceConfigFailed, ThreadSpawnFailed };

    /// Opens the OS default input device at `sample_rate` (matching the
    /// project's own rate, so recorded audio never needs a resample
    /// before landing in a Sampler's `pad.samples`). No-op-fails on a
    /// platform/config with no capture backend at all.
    pub fn start(self: *AudioInput, sample_rate: u32, device_name: []const u8) Error!void {
        std.debug.assert(self.active == .none);
        try capture_types.validateSampleRate(sample_rate);
        if (has_alsa) {
            try self.alsa.start(sample_rate, device_name);
            self.active = .alsa;
        } else if (has_wasapi) {
            try self.wasapi.start(sample_rate, device_name);
            self.active = .wasapi;
        } else if (has_coreaudio) {
            try self.coreaudio.start(sample_rate, device_name);
            self.active = .coreaudio;
        } else {
            return error.Unsupported;
        }
        self.stopped = .none;
    }

    pub fn stop(self: *AudioInput) void {
        const active = self.active;
        switch (active) {
            .none => {},
            .alsa => if (has_alsa) self.alsa.stop() else unreachable,
            .wasapi => if (has_wasapi) self.wasapi.stop() else unreachable,
            .coreaudio => if (has_coreaudio) self.coreaudio.stop() else unreachable,
        }
        self.active = .none;
        self.stopped = active;
    }

    /// Drains one queued block, if any - called every frame while a
    /// record pass has audio targets (`App.tick`).
    pub fn pop(self: *AudioInput) ?CaptureBlock {
        const source = if (self.active != .none) self.active else self.stopped;
        return switch (source) {
            .none => null,
            .alsa => if (has_alsa) self.alsa.pop() else unreachable,
            .wasapi => if (has_wasapi) self.wasapi.pop() else unreachable,
            .coreaudio => if (has_coreaudio) self.coreaudio.pop() else unreachable,
        };
    }

    pub fn popDropout(self: *AudioInput) ?Dropout {
        const source = if (self.active != .none) self.active else self.stopped;
        return switch (source) {
            .none => null,
            .alsa => if (has_alsa) self.alsa.popDropout() else unreachable,
            .wasapi => if (has_wasapi) self.wasapi.popDropout() else unreachable,
            .coreaudio => if (has_coreaudio) self.coreaudio.popDropout() else unreachable,
        };
    }
};

test "audio input rejects zero sample rate before opening a backend" {
    var input: AudioInput = .{};
    try std.testing.expectError(error.InvalidSampleRate, input.start(0, ""));
}

test "audio input reports unsupported when neither backend compiles in" {
    if (has_alsa or has_wasapi or has_coreaudio) return error.SkipZigTest;
    var input: AudioInput = .{};
    try std.testing.expectError(error.Unsupported, input.start(48_000, ""));
}

test "audio input start/pop/stop round-trips on this OS's backend (skipped without a device)" {
    if (!has_alsa and !has_wasapi and !has_coreaudio) return error.SkipZigTest;
    var input: AudioInput = .{};
    input.start(48_000, "") catch return error.SkipZigTest; // no capture device here
    defer input.stop();

    var spins: u32 = 0;
    var got: ?CaptureBlock = null;
    while (got == null and spins < 1_000_000) : (spins += 1) {
        got = input.pop();
        if (got == null) std.atomic.spinLoopHint();
    }
    // An opened device that delivers nothing is indistinguishable from no
    // device at all here: macOS hands out a capture stream before the mic
    // permission prompt is answered, and a denied one just stays silent.
    if (got == null) return error.SkipZigTest;
}

test "audio input exposes queued ALSA tail after stop" {
    if (!has_alsa) return error.SkipZigTest;
    var input: AudioInput = .{};
    var block: CaptureBlock = .{};
    block.frames = 1;
    block.channels = 1;
    block.samples[0] = 0.5;
    try std.testing.expect(input.alsa.queue.push(block));
    input.active = .alsa;

    input.stop();
    const tail = input.pop().?;
    try std.testing.expectEqual(@as(u32, 1), tail.frames);
    try std.testing.expectEqual(@as(f32, 0.5), tail.samples[0]);
}
