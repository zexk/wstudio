//! Core Audio playback through macOS's default output Audio Unit.

const std = @import("std");
const types = @import("../core/types.zig");
const backend_mod = @import("backend.zig");

const AudioComponent = ?*opaque {};
const AudioUnit = ?*opaque {};
const OSStatus = i32;

const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32,
    componentFlagsMask: u32,
};

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32,
};

const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

const RenderCallback = *const fn (?*anyopaque, *u32, *const anyopaque, u32, u32, *AudioBufferList) callconv(.c) OSStatus;
const AURenderCallbackStruct = extern struct {
    inputProc: RenderCallback,
    inputProcRefCon: ?*anyopaque,
};

const audio_unit_type_output = 0x61756f75; // 'auou'
const audio_unit_subtype_default_output = 0x64656620; // 'def '
const audio_unit_manufacturer_apple = 0x6170706c; // 'appl'
const audio_format_linear_pcm = 0x6c70636d; // 'lpcm'
const audio_format_flag_is_float = 1 << 0;
const audio_format_flag_is_packed = 1 << 3;
const audio_unit_property_stream_format = 8;
const audio_unit_property_set_render_callback = 23;
const audio_unit_scope_input = 1;

extern fn AudioComponentFindNext(AudioComponent, *const AudioComponentDescription) callconv(.c) AudioComponent;
extern fn AudioComponentInstanceNew(AudioComponent, *AudioUnit) callconv(.c) OSStatus;
extern fn AudioComponentInstanceDispose(AudioUnit) callconv(.c) OSStatus;
extern fn AudioUnitSetProperty(AudioUnit, u32, u32, u32, *const anyopaque, u32) callconv(.c) OSStatus;
extern fn AudioUnitInitialize(AudioUnit) callconv(.c) OSStatus;
extern fn AudioUnitUninitialize(AudioUnit) callconv(.c) OSStatus;
extern fn AudioOutputUnitStart(AudioUnit) callconv(.c) OSStatus;
extern fn AudioOutputUnitStop(AudioUnit) callconv(.c) OSStatus;

pub const CoreAudioBackend = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    unit: AudioUnit = null,

    const max_channels = 2;

    pub const Error = error{ InvalidConfig, DeviceOpenFailed, DeviceConfigFailed };

    pub fn start(self: *CoreAudioBackend) Error!void {
        try backend_mod.validateConfig(self.config, max_channels);

        const description = AudioComponentDescription{
            .componentType = audio_unit_type_output,
            .componentSubType = audio_unit_subtype_default_output,
            .componentManufacturer = audio_unit_manufacturer_apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const component = AudioComponentFindNext(null, &description) orelse return error.DeviceOpenFailed;

        var unit: AudioUnit = null;
        if (AudioComponentInstanceNew(component, &unit) != 0) return error.DeviceOpenFailed;
        errdefer _ = AudioComponentInstanceDispose(unit);

        const format = AudioStreamBasicDescription{
            .mSampleRate = @floatFromInt(self.config.sample_rate),
            .mFormatID = audio_format_linear_pcm,
            .mFormatFlags = audio_format_flag_is_float | audio_format_flag_is_packed,
            .mBytesPerPacket = self.config.channels * @sizeOf(types.Sample),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = self.config.channels * @sizeOf(types.Sample),
            .mChannelsPerFrame = self.config.channels,
            .mBitsPerChannel = @bitSizeOf(types.Sample),
            .mReserved = 0,
        };
        if (AudioUnitSetProperty(
            unit,
            audio_unit_property_stream_format,
            audio_unit_scope_input,
            0,
            &format,
            @sizeOf(AudioStreamBasicDescription),
        ) != 0) return error.DeviceConfigFailed;

        const callback = AURenderCallbackStruct{
            .inputProc = renderCallback,
            .inputProcRefCon = self,
        };
        if (AudioUnitSetProperty(
            unit,
            audio_unit_property_set_render_callback,
            audio_unit_scope_input,
            0,
            &callback,
            @sizeOf(AURenderCallbackStruct),
        ) != 0) return error.DeviceConfigFailed;
        if (AudioUnitInitialize(unit) != 0) return error.DeviceConfigFailed;
        errdefer _ = AudioUnitUninitialize(unit);
        if (AudioOutputUnitStart(unit) != 0) return error.DeviceConfigFailed;

        self.unit = unit;
    }

    pub fn stop(self: *CoreAudioBackend) void {
        const unit = self.unit orelse return;
        self.unit = null;
        _ = AudioOutputUnitStop(unit);
        _ = AudioUnitUninitialize(unit);
        _ = AudioComponentInstanceDispose(unit);
    }

    fn renderCallback(
        context: ?*anyopaque,
        _: *u32,
        _: *const anyopaque,
        _: u32,
        frames: u32,
        io_data: *AudioBufferList,
    ) callconv(.c) OSStatus {
        const self: *CoreAudioBackend = @ptrCast(@alignCast(context.?));
        const buffer = &io_data.*.mBuffers[0];
        const out: []types.Sample = @as([*]types.Sample, @ptrCast(@alignCast(buffer.mData.?)))[0 .. frames * self.config.channels];
        const block_samples: usize = @as(usize, self.config.block_frames) * self.config.channels;
        var offset: usize = 0;
        while (offset < out.len) {
            const end = @min(offset + block_samples, out.len);
            self.render(self.ctx, out[offset..end]);
            offset = end;
        }
        return 0;
    }
};
