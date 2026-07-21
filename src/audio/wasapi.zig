//! WASAPI playback backend (Windows). Shared-mode, event-driven render on
//! a dedicated thread - the Windows analogue of alsa.zig's blocking
//! snd_pcm_writei loop, just paced by an auto-reset event instead of the
//! write call itself.

const std = @import("std");
const types = @import("../core/types.zig");
const backend_mod = @import("backend.zig");
const capture_types = @import("capture_types.zig");
const CaptureBlock = capture_types.CaptureBlock;

const c = @cImport({
    @cDefine("COBJMACROS", "1");
    @cDefine("WIDL_C_INLINE_WRAPPERS", "1");
    @cDefine("INITGUID", "1");
    @cInclude("windows.h");
    @cInclude("mmdeviceapi.h");
    @cInclude("audioclient.h");
});

fn ok(hr: c.HRESULT) bool {
    return hr >= 0;
}

// audiosessiontypes.h defines these as unsuffixed hex literals; the first
// overflows translate-c's c_int, so both are spelled out here instead.
const stream_flag_auto_convert_pcm: c.DWORD = 0x80000000; // AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
const stream_flag_src_default_quality: c.DWORD = 0x08000000; // AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY

pub const WasapiBackend = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    client: ?*c.IAudioClient = null,
    render_client: ?*c.IAudioRenderClient = null,
    event: ?*anyopaque = null,
    buffer_frames: u32 = 0,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    const max_channels = 2;

    pub const Error = error{
        InvalidConfig,
        ComInitFailed,
        DeviceOpenFailed,
        DeviceConfigFailed,
        ThreadSpawnFailed,
    };

    pub fn start(self: *WasapiBackend) Error!void {
        try backend_mod.validateConfig(self.config, max_channels);

        if (!ok(c.CoInitializeEx(null, c.COINIT_MULTITHREADED))) return error.ComInitFailed;
        errdefer c.CoUninitialize();

        var enumerator: ?*c.IMMDeviceEnumerator = null;
        if (!ok(c.CoCreateInstance(
            &c.CLSID_MMDeviceEnumerator,
            null,
            c.CLSCTX_ALL,
            &c.IID_IMMDeviceEnumerator,
            @ptrCast(&enumerator),
        ))) return error.DeviceOpenFailed;
        defer _ = c.IMMDeviceEnumerator_Release(enumerator);

        var device: ?*c.IMMDevice = null;
        if (!ok(c.IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, c.eRender, c.eConsole, &device)))
            return error.DeviceOpenFailed;
        defer _ = c.IMMDevice_Release(device);

        var client: ?*c.IAudioClient = null;
        if (!ok(c.IMMDevice_Activate(device, &c.IID_IAudioClient, c.CLSCTX_ALL, null, @ptrCast(&client))))
            return error.DeviceOpenFailed;
        errdefer _ = c.IAudioClient_Release(client);

        const fmt = c.WAVEFORMATEX{
            .wFormatTag = c.WAVE_FORMAT_IEEE_FLOAT,
            .nChannels = @intCast(self.config.channels),
            .nSamplesPerSec = self.config.sample_rate,
            .nAvgBytesPerSec = self.config.sample_rate * @as(u32, self.config.channels) * 4,
            .nBlockAlign = @intCast(self.config.channels * 4),
            .wBitsPerSample = 32,
            .cbSize = 0,
        };

        // Buffer duration in 100ns units (REFERENCE_TIME), four blocks or
        // 20ms, whichever is larger - same floor ALSA's set_params uses.
        const block_hns: c.REFERENCE_TIME = @divTrunc(
            @as(c.REFERENCE_TIME, self.config.block_frames) * 10_000_000,
            @as(c.REFERENCE_TIME, self.config.sample_rate),
        );
        const buffer_duration = @max(block_hns * 4, 200_000);

        // Shared mode only accepts our rate/layout when it happens to match
        // the device mix format; AUTOCONVERTPCM has the audio engine resample
        // instead of rejecting it - a plain 44.1kHz output device would
        // otherwise fail Initialize and drop the whole app to the silent
        // NullBackend. Same job as the soft_resample flag in alsa.zig.
        if (!ok(c.IAudioClient_Initialize(
            client,
            c.AUDCLNT_SHAREMODE_SHARED,
            @as(c.DWORD, c.AUDCLNT_STREAMFLAGS_EVENTCALLBACK) |
                stream_flag_auto_convert_pcm |
                stream_flag_src_default_quality,
            buffer_duration,
            0,
            &fmt,
            null,
        ))) return error.DeviceConfigFailed;

        var buffer_frames: c.UINT32 = 0;
        if (!ok(c.IAudioClient_GetBufferSize(client, &buffer_frames))) return error.DeviceConfigFailed;

        const event = c.CreateEventW(null, 0, 0, null);
        if (event == null) return error.DeviceConfigFailed;
        errdefer _ = c.CloseHandle(event);
        if (!ok(c.IAudioClient_SetEventHandle(client, event))) return error.DeviceConfigFailed;

        var render_client: ?*c.IAudioRenderClient = null;
        if (!ok(c.IAudioClient_GetService(client, &c.IID_IAudioRenderClient, @ptrCast(&render_client))))
            return error.DeviceConfigFailed;
        errdefer _ = c.IAudioRenderClient_Release(render_client);

        if (!ok(c.IAudioClient_Start(client))) return error.DeviceConfigFailed;

        self.client = client;
        self.render_client = render_client;
        self.event = event;
        self.buffer_frames = buffer_frames;

        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.running.store(false, .release);
            return error.ThreadSpawnFailed;
        };
    }

    pub fn stop(self: *WasapiBackend) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.client) |client| {
            _ = c.IAudioClient_Stop(client);
            if (self.render_client) |rc| _ = c.IAudioRenderClient_Release(rc);
            _ = c.IAudioClient_Release(client);
            self.client = null;
            self.render_client = null;
        }
        if (self.event) |ev| {
            _ = c.CloseHandle(ev);
            self.event = null;
        }
        c.CoUninitialize();
    }

    fn run(self: *WasapiBackend) void {
        // COM apartments are per-thread - the render thread joins the same
        // process-wide MTA as start()'s caller, which is what lets the audio
        // client interfaces be used safely off the thread that created them.
        if (!ok(c.CoInitializeEx(null, c.COINIT_MULTITHREADED))) return;
        defer c.CoUninitialize();

        const client = self.client.?;
        const render_client = self.render_client.?;
        const channels = self.config.channels;
        const block_samples = @as(usize, self.config.block_frames) * channels;

        while (self.running.load(.acquire)) {
            if (c.WaitForSingleObject(self.event, 2000) != c.WAIT_OBJECT_0) continue;

            var padding: c.UINT32 = 0;
            if (!ok(c.IAudioClient_GetCurrentPadding(client, &padding))) continue;
            const available = self.buffer_frames - padding;
            if (available == 0) continue;

            var data: [*c]c.BYTE = undefined;
            if (!ok(c.IAudioRenderClient_GetBuffer(render_client, available, &data))) continue;

            // `available` spans several blocks (the very first fill is the
            // whole device buffer), but the RenderFn contract is one block
            // per call - the engine's scratch buffers are sized to
            // max_block_frames, and commands/automation are drained per
            // block. Feed it block-sized slices, same chunking as
            // OfflineBackend.renderAll.
            const out: []types.Sample = @as([*]types.Sample, @ptrCast(@alignCast(data)))[0 .. available * channels];
            var offset: usize = 0;
            while (offset < out.len) {
                const end = @min(offset + block_samples, out.len);
                self.render(self.ctx, out[offset..end]);
                offset = end;
            }

            _ = c.IAudioRenderClient_ReleaseBuffer(render_client, available, 0);
        }
    }
};

/// WASAPI capture client (Windows), fully independent of `WasapiBackend`/
/// output - same rationale as `alsa.zig`'s `AlsaCapture`. Opened only for
/// the duration of a record pass, not the app's whole lifetime.
pub const WasapiCapture = struct {
    client: ?*c.IAudioClient = null,
    capture_client: ?*c.IAudioCaptureClient = null,
    event: ?*anyopaque = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    queue: capture_types.Queue = .{},

    pub const Error = error{ ComInitFailed, DeviceOpenFailed, DeviceConfigFailed, ThreadSpawnFailed };

    pub fn start(self: *WasapiCapture, sample_rate: u32) Error!void {
        if (!ok(c.CoInitializeEx(null, c.COINIT_MULTITHREADED))) return error.ComInitFailed;
        errdefer c.CoUninitialize();

        var enumerator: ?*c.IMMDeviceEnumerator = null;
        if (!ok(c.CoCreateInstance(
            &c.CLSID_MMDeviceEnumerator,
            null,
            c.CLSCTX_ALL,
            &c.IID_IMMDeviceEnumerator,
            @ptrCast(&enumerator),
        ))) return error.DeviceOpenFailed;
        defer _ = c.IMMDeviceEnumerator_Release(enumerator);

        var device: ?*c.IMMDevice = null;
        if (!ok(c.IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, c.eCapture, c.eConsole, &device)))
            return error.DeviceOpenFailed;
        defer _ = c.IMMDevice_Release(device);

        var client: ?*c.IAudioClient = null;
        if (!ok(c.IMMDevice_Activate(device, &c.IID_IAudioClient, c.CLSCTX_ALL, null, @ptrCast(&client))))
            return error.DeviceOpenFailed;
        errdefer _ = c.IAudioClient_Release(client);

        const fmt = c.WAVEFORMATEX{
            .wFormatTag = c.WAVE_FORMAT_IEEE_FLOAT,
            .nChannels = 1, // mono - matches Sampler.pad.samples's storage format exactly
            .nSamplesPerSec = sample_rate,
            .nAvgBytesPerSec = sample_rate * 4,
            .nBlockAlign = 4,
            .wBitsPerSample = 32,
            .cbSize = 0,
        };

        // Same 20ms floor `AlsaCapture`/`WasapiBackend`'s playback side use.
        const buffer_duration: c.REFERENCE_TIME = 200_000;
        if (!ok(c.IAudioClient_Initialize(
            client,
            c.AUDCLNT_SHAREMODE_SHARED,
            @as(c.DWORD, c.AUDCLNT_STREAMFLAGS_EVENTCALLBACK) |
                stream_flag_auto_convert_pcm |
                stream_flag_src_default_quality,
            buffer_duration,
            0,
            &fmt,
            null,
        ))) return error.DeviceConfigFailed;

        const event = c.CreateEventW(null, 0, 0, null);
        if (event == null) return error.DeviceConfigFailed;
        errdefer _ = c.CloseHandle(event);
        if (!ok(c.IAudioClient_SetEventHandle(client, event))) return error.DeviceConfigFailed;

        var capture_client: ?*c.IAudioCaptureClient = null;
        if (!ok(c.IAudioClient_GetService(client, &c.IID_IAudioCaptureClient, @ptrCast(&capture_client))))
            return error.DeviceConfigFailed;
        errdefer _ = c.IAudioCaptureClient_Release(capture_client);

        if (!ok(c.IAudioClient_Start(client))) return error.DeviceConfigFailed;

        self.client = client;
        self.capture_client = capture_client;
        self.event = event;

        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.running.store(false, .release);
            return error.ThreadSpawnFailed;
        };
    }

    pub fn stop(self: *WasapiCapture) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.client) |client| {
            _ = c.IAudioClient_Stop(client);
            if (self.capture_client) |cc| _ = c.IAudioCaptureClient_Release(cc);
            _ = c.IAudioClient_Release(client);
            self.client = null;
            self.capture_client = null;
        }
        if (self.event) |ev| {
            _ = c.CloseHandle(ev);
            self.event = null;
        }
        c.CoUninitialize();
        while (self.queue.pop() != null) {}
    }

    pub fn pop(self: *WasapiCapture) ?CaptureBlock {
        return self.queue.pop();
    }

    fn run(self: *WasapiCapture) void {
        if (!ok(c.CoInitializeEx(null, c.COINIT_MULTITHREADED))) return;
        defer c.CoUninitialize();

        const capture_client = self.capture_client.?;

        while (self.running.load(.acquire)) {
            if (c.WaitForSingleObject(self.event, 2000) != c.WAIT_OBJECT_0) continue;

            var packet_frames: c.UINT32 = 0;
            while (ok(c.IAudioCaptureClient_GetNextPacketSize(capture_client, &packet_frames)) and packet_frames > 0) {
                var data: [*c]c.BYTE = undefined;
                var frames_avail: c.UINT32 = 0;
                var flags: c.DWORD = 0;
                if (!ok(c.IAudioCaptureClient_GetBuffer(capture_client, &data, &frames_avail, &flags, null, null))) break;

                var block: CaptureBlock = .{};
                const n = @min(frames_avail, capture_types.chunk_frames);
                if (flags & c.AUDCLNT_BUFFERFLAGS_SILENT != 0) {
                    @memset(block.samples[0..n], 0.0);
                } else {
                    const src: [*]const f32 = @ptrCast(@alignCast(data));
                    @memcpy(block.samples[0..n], src[0..n]);
                }
                block.frames = n;
                _ = self.queue.push(block);

                _ = c.IAudioCaptureClient_ReleaseBuffer(capture_client, frames_avail);
            }
        }
    }
};
