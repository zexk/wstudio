//! ALSA playback backend (Linux). On modern systems the "default"
//! device is served by PipeWire/PulseAudio's ALSA layer, so this one
//! backend reaches every desktop setup. The blocking `snd_pcm_writei`
//! paces the render thread off the device clock - no sleeping.

const std = @import("std");
const types = @import("../core/types.zig");
const backend_mod = @import("backend.zig");
const capture_types = @import("capture_types.zig");
const CaptureBlock = capture_types.CaptureBlock;

const c = @cImport(@cInclude("alsa/asoundlib.h"));

pub const AlsaBackend = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    device: [*:0]const u8 = "default",
    pcm: ?*c.snd_pcm_t = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    buffer: [types.max_block_frames * max_channels]types.Sample = undefined,

    const max_channels = 2;

    pub const Error = error{
        InvalidConfig,
        DeviceOpenFailed,
        DeviceConfigFailed,
        ThreadSpawnFailed,
    };

    pub fn start(self: *AlsaBackend) Error!void {
        try backend_mod.validateConfig(self.config, max_channels);

        var pcm: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&pcm, self.device, c.SND_PCM_STREAM_PLAYBACK, 0) < 0) {
            return error.DeviceOpenFailed;
        }
        errdefer _ = c.snd_pcm_close(pcm);

        const block_us: c_uint = @intCast(@as(u64, self.config.block_frames) *
            std.time.us_per_s / self.config.sample_rate);
        if (c.snd_pcm_set_params(
            pcm,
            c.SND_PCM_FORMAT_FLOAT, // native-endian f32: engine format, no conversion
            c.SND_PCM_ACCESS_RW_INTERLEAVED,
            self.config.channels,
            self.config.sample_rate,
            1, // allow resampling if the device can't do our rate
            @max(block_us * 4, 20_000),
        ) < 0) {
            return error.DeviceConfigFailed;
        }

        self.pcm = pcm;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.running.store(false, .release);
            _ = c.snd_pcm_close(pcm);
            self.pcm = null;
            return error.ThreadSpawnFailed;
        };
    }

    pub fn stop(self: *AlsaBackend) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.pcm) |pcm| {
            _ = c.snd_pcm_drain(pcm);
            _ = c.snd_pcm_close(pcm);
            self.pcm = null;
        }
    }

    fn run(self: *AlsaBackend) void {
        const pcm = self.pcm.?;
        const channel_count = self.config.channels;
        const block_frames: usize = self.config.block_frames;
        const samples = self.buffer[0 .. block_frames * channel_count];

        while (self.running.load(.acquire)) {
            self.render(self.ctx, samples);

            var offset: usize = 0; // in frames
            while (offset < block_frames) {
                const written = c.snd_pcm_writei(
                    pcm,
                    &samples[offset * channel_count],
                    block_frames - offset,
                );
                if (written < 0) {
                    // underrun (-EPIPE) and friends; 1 = silent recovery
                    if (c.snd_pcm_recover(pcm, @intCast(written), 1) < 0) return;
                    continue;
                }
                offset += @intCast(written);
            }
        }
    }
};

/// ALSA capture PCM (Linux), fully independent of `AlsaBackend`/whichever
/// backend is doing output - see `capture.zig`'s doc comment for why
/// audio-input recording doesn't hook into the output backend's render
/// callback at all. Opened only for the duration of a record pass (see
/// `App.startPendingRecording`), not for the app's whole lifetime, so it
/// isn't holding the mic open otherwise.
pub const AlsaCapture = struct {
    pcm: ?*c.snd_pcm_t = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    queue: capture_types.Queue = .{},

    pub const Error = error{ DeviceOpenFailed, DeviceConfigFailed, ThreadSpawnFailed };

    pub fn start(self: *AlsaCapture, sample_rate: u32) Error!void {
        var pcm: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_CAPTURE, 0) < 0) {
            return error.DeviceOpenFailed;
        }
        errdefer _ = c.snd_pcm_close(pcm);

        const block_us: c_uint = @intCast(@as(u64, capture_types.chunk_frames) *
            std.time.us_per_s / sample_rate);
        if (c.snd_pcm_set_params(
            pcm,
            c.SND_PCM_FORMAT_FLOAT, // native-endian f32: engine format, no conversion
            c.SND_PCM_ACCESS_RW_INTERLEAVED,
            1, // mono - matches Sampler.pad.samples's storage format exactly
            sample_rate,
            1, // allow resampling if the device can't do our rate
            @max(block_us * 4, 20_000),
        ) < 0) {
            return error.DeviceConfigFailed;
        }

        self.pcm = pcm;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.running.store(false, .release);
            _ = c.snd_pcm_close(pcm);
            self.pcm = null;
            return error.ThreadSpawnFailed;
        };
    }

    pub fn stop(self: *AlsaCapture) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.pcm) |pcm| {
            _ = c.snd_pcm_close(pcm);
            self.pcm = null;
        }
        // Drop anything left over so a stale tail doesn't bleed into the
        // next record pass's accumulation.
        while (self.queue.pop() != null) {}
    }

    pub fn pop(self: *AlsaCapture) ?CaptureBlock {
        return self.queue.pop();
    }

    fn run(self: *AlsaCapture) void {
        const pcm = self.pcm.?;
        while (self.running.load(.acquire)) {
            var block: CaptureBlock = .{};
            const read = c.snd_pcm_readi(pcm, &block.samples, capture_types.chunk_frames);
            if (read < 0) {
                // underrun (-EPIPE) and friends; 1 = silent recovery
                if (c.snd_pcm_recover(pcm, @intCast(read), 1) < 0) return;
                continue;
            }
            block.frames = @intCast(read);
            _ = self.queue.push(block); // drop on overflow, same tolerance as note_queue
        }
    }
};

test "alsa capture start/pop/stop (skipped without a device)" {
    var capture: AlsaCapture = .{};
    capture.start(types.default_sample_rate) catch return error.SkipZigTest; // no capture device here
    defer capture.stop();

    var spins: u32 = 0;
    var got: ?CaptureBlock = null;
    while (got == null and spins < 1_000_000) : (spins += 1) {
        got = capture.pop();
        if (got == null) std.atomic.spinLoopHint();
    }
    try std.testing.expect(got != null);
}

test "alsa backend start/render/stop (skipped without a device)" {
    const Counter = struct {
        calls: std.atomic.Value(u32) = .init(0),
        fn render(ctx: *anyopaque, out: []types.Sample) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.calls.fetchAdd(1, .monotonic);
            @memset(out, 0.0);
        }
    };

    var counter: Counter = .{};
    var backend = AlsaBackend{
        .config = .{},
        .render = Counter.render,
        .ctx = &counter,
    };
    backend.start() catch return error.SkipZigTest; // no audio device here
    defer backend.stop();

    var spins: u32 = 0;
    while (counter.calls.load(.monotonic) < 2 and spins < 1_000_000) : (spins += 1) {
        std.atomic.spinLoopHint();
    }
    try std.testing.expect(counter.calls.load(.monotonic) >= 1);
}
