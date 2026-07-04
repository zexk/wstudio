//! WASAPI playback backend (Windows). Shared-mode, event-driven render on
//! a dedicated thread — the Windows analogue of alsa.zig's blocking
//! snd_pcm_writei loop, just paced by an auto-reset event instead of the
//! write call itself.

const std = @import("std");
const types = @import("../core/types.zig");
const backend_mod = @import("backend.zig");

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
        ComInitFailed,
        DeviceOpenFailed,
        DeviceConfigFailed,
        ThreadSpawnFailed,
    };

    pub fn start(self: *WasapiBackend) Error!void {
        std.debug.assert(self.config.channels <= max_channels);
        std.debug.assert(self.config.block_frames <= types.max_block_frames);

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
        // 20ms, whichever is larger — same floor ALSA's set_params uses.
        const block_hns: c.REFERENCE_TIME = @divTrunc(
            @as(c.REFERENCE_TIME, self.config.block_frames) * 10_000_000,
            @as(c.REFERENCE_TIME, self.config.sample_rate),
        );
        const buffer_duration = @max(block_hns * 4, 200_000);

        if (!ok(c.IAudioClient_Initialize(
            client,
            c.AUDCLNT_SHAREMODE_SHARED,
            c.AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
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
        // COM apartments are per-thread — the render thread joins the same
        // process-wide MTA as start()'s caller, which is what lets the audio
        // client interfaces be used safely off the thread that created them.
        if (!ok(c.CoInitializeEx(null, c.COINIT_MULTITHREADED))) return;
        defer c.CoUninitialize();

        const client = self.client.?;
        const render_client = self.render_client.?;
        const channels = self.config.channels;

        while (self.running.load(.acquire)) {
            if (c.WaitForSingleObject(self.event, 2000) != c.WAIT_OBJECT_0) continue;

            var padding: c.UINT32 = 0;
            if (!ok(c.IAudioClient_GetCurrentPadding(client, &padding))) continue;
            const available = self.buffer_frames - padding;
            if (available == 0) continue;

            var data: [*c]c.BYTE = undefined;
            if (!ok(c.IAudioRenderClient_GetBuffer(render_client, available, &data))) continue;

            const out: []types.Sample = @as([*]types.Sample, @ptrCast(@alignCast(data)))[0 .. available * channels];
            self.render(self.ctx, out);

            _ = c.IAudioRenderClient_ReleaseBuffer(render_client, available, 0);
        }
    }
};
