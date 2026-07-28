//! Core Audio playback through macOS's default output Audio Unit.

const std = @import("std");
const types = @import("../core/types.zig");
const backend_mod = @import("backend.zig");

const c = @cImport({
    @cInclude("AudioToolbox/AudioToolbox.h");
});

pub const CoreAudioBackend = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    unit: c.AudioUnit = null,

    const max_channels = 2;

    pub const Error = error{ InvalidConfig, DeviceOpenFailed, DeviceConfigFailed };

    pub fn start(self: *CoreAudioBackend) Error!void {
        try backend_mod.validateConfig(self.config, max_channels);

        const description = c.AudioComponentDescription{
            .componentType = c.kAudioUnitType_Output,
            .componentSubType = c.kAudioUnitSubType_DefaultOutput,
            .componentManufacturer = c.kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const component = c.AudioComponentFindNext(null, &description) orelse return error.DeviceOpenFailed;

        var unit: c.AudioUnit = null;
        if (c.AudioComponentInstanceNew(component, &unit) != 0) return error.DeviceOpenFailed;
        errdefer _ = c.AudioComponentInstanceDispose(unit);

        const format = c.AudioStreamBasicDescription{
            .mSampleRate = @floatFromInt(self.config.sample_rate),
            .mFormatID = c.kAudioFormatLinearPCM,
            .mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked,
            .mBytesPerPacket = self.config.channels * @sizeOf(types.Sample),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = self.config.channels * @sizeOf(types.Sample),
            .mChannelsPerFrame = self.config.channels,
            .mBitsPerChannel = @bitSizeOf(types.Sample),
            .mReserved = 0,
        };
        if (c.AudioUnitSetProperty(
            unit,
            c.kAudioUnitProperty_StreamFormat,
            c.kAudioUnitScope_Input,
            0,
            &format,
            @sizeOf(c.AudioStreamBasicDescription),
        ) != 0) return error.DeviceConfigFailed;

        const callback = c.AURenderCallbackStruct{
            .inputProc = renderCallback,
            .inputProcRefCon = self,
        };
        if (c.AudioUnitSetProperty(
            unit,
            c.kAudioUnitProperty_SetRenderCallback,
            c.kAudioUnitScope_Input,
            0,
            &callback,
            @sizeOf(c.AURenderCallbackStruct),
        ) != 0) return error.DeviceConfigFailed;
        if (c.AudioUnitInitialize(unit) != 0) return error.DeviceConfigFailed;
        errdefer _ = c.AudioUnitUninitialize(unit);
        if (c.AudioOutputUnitStart(unit) != 0) return error.DeviceConfigFailed;

        self.unit = unit;
    }

    pub fn stop(self: *CoreAudioBackend) void {
        const unit = self.unit orelse return;
        self.unit = null;
        _ = c.AudioOutputUnitStop(unit);
        _ = c.AudioUnitUninitialize(unit);
        _ = c.AudioComponentInstanceDispose(unit);
    }

    fn renderCallback(
        context: ?*anyopaque,
        _: [*c]c.AudioUnitRenderActionFlags,
        _: [*c]const c.AudioTimeStamp,
        _: c.UInt32,
        frames: c.UInt32,
        io_data: [*c]c.AudioBufferList,
    ) callconv(.c) c.OSStatus {
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
