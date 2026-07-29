//! Core Audio playback through macOS's default output Audio Unit.

const std = @import("std");
const types = @import("../core/types.zig");
const backend_mod = @import("backend.zig");
const capture_types = @import("capture_types.zig");
const CaptureBlock = capture_types.CaptureBlock;

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

const AudioObjectPropertyAddress = extern struct {
    mSelector: u32,
    mScope: u32,
    mElement: u32,
};

const RenderCallback = *const fn (?*anyopaque, *u32, *const anyopaque, u32, u32, ?*AudioBufferList) callconv(.c) OSStatus;
const AURenderCallbackStruct = extern struct {
    inputProc: RenderCallback,
    inputProcRefCon: ?*anyopaque,
};

const audio_unit_type_output = 0x61756f75; // 'auou'
const audio_unit_subtype_default_output = 0x64656620; // 'def '
const audio_unit_subtype_hal_output = 0x6168616c; // 'ahal'
const audio_unit_manufacturer_apple = 0x6170706c; // 'appl'
const audio_format_linear_pcm = 0x6c70636d; // 'lpcm'
const audio_format_flag_is_float = 1 << 0;
const audio_format_flag_is_packed = 1 << 3;
const audio_unit_property_stream_format = 8;
const audio_unit_property_set_render_callback = 23;
const audio_output_unit_property_current_device = 2000;
const audio_output_unit_property_enable_io = 2003;
const audio_output_unit_property_set_input_callback = 2005;
const audio_unit_scope_global = 0;
const audio_unit_scope_input = 1;
const audio_unit_scope_output = 2;
const audio_hardware_property_default_input_device = 0x64496e20; // 'dIn '
const audio_object_property_scope_global = 0x676c6f62; // 'glob'
const audio_object_property_element_main = 0;
const audio_object_system_object = 1;
const audio_object_unknown = 0;

extern fn AudioComponentFindNext(AudioComponent, *const AudioComponentDescription) callconv(.c) AudioComponent;
extern fn AudioComponentInstanceNew(AudioComponent, *AudioUnit) callconv(.c) OSStatus;
extern fn AudioComponentInstanceDispose(AudioUnit) callconv(.c) OSStatus;
extern fn AudioUnitSetProperty(AudioUnit, u32, u32, u32, *const anyopaque, u32) callconv(.c) OSStatus;
extern fn AudioUnitInitialize(AudioUnit) callconv(.c) OSStatus;
extern fn AudioUnitUninitialize(AudioUnit) callconv(.c) OSStatus;
extern fn AudioOutputUnitStart(AudioUnit) callconv(.c) OSStatus;
extern fn AudioOutputUnitStop(AudioUnit) callconv(.c) OSStatus;
extern fn AudioUnitRender(AudioUnit, *u32, *const anyopaque, u32, u32, *AudioBufferList) callconv(.c) OSStatus;
extern fn AudioObjectGetPropertyData(u32, *const AudioObjectPropertyAddress, u32, ?*const anyopaque, *u32, *anyopaque) callconv(.c) OSStatus;

pub const CoreAudioBackend = struct {
    config: backend_mod.Config,
    render: backend_mod.RenderFn,
    ctx: *anyopaque,
    unit: AudioUnit = null,

    const max_channels = 2;

    pub const Error = error{ InvalidConfig, DeviceOpenFailed, DeviceConfigFailed };

    pub fn start(self: *CoreAudioBackend) Error!void {
        try backend_mod.validateConfig(self.config, max_channels);

        const selected_device = if (self.config.output_device.len > 0)
            std.fmt.parseInt(u32, self.config.output_device, 10) catch return error.DeviceOpenFailed
        else
            null;
        const description = AudioComponentDescription{
            .componentType = audio_unit_type_output,
            .componentSubType = if (selected_device != null) audio_unit_subtype_hal_output else audio_unit_subtype_default_output,
            .componentManufacturer = audio_unit_manufacturer_apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const component = AudioComponentFindNext(null, &description) orelse return error.DeviceOpenFailed;

        var unit: AudioUnit = null;
        if (AudioComponentInstanceNew(component, &unit) != 0) return error.DeviceOpenFailed;
        errdefer _ = AudioComponentInstanceDispose(unit);

        if (selected_device) |device| {
            var current = device;
            if (AudioUnitSetProperty(unit, audio_output_unit_property_current_device, audio_unit_scope_global, 0, &current, @sizeOf(u32)) != 0)
                return error.DeviceConfigFailed;
        }

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
        io_data: ?*AudioBufferList,
    ) callconv(.c) OSStatus {
        const self: *CoreAudioBackend = @ptrCast(@alignCast(context.?));
        const buffer = &io_data.?.mBuffers[0];
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

pub const CoreAudioCapture = struct {
    unit: AudioUnit = null,
    queue: capture_types.Queue = .{},
    buffer: [types.max_block_frames]types.Sample = undefined,

    pub const Error = error{ DeviceOpenFailed, DeviceConfigFailed };

    /// The system's default input device, or null when the Mac has none.
    /// A HAL unit is handed out and starts happily either way, so without
    /// this the no-mic case looks like a running capture that simply
    /// never fires its callback - `start` failing is what lets a record
    /// pass fall back to MIDI-only.
    fn defaultInputDevice() ?u32 {
        const address = AudioObjectPropertyAddress{
            .mSelector = audio_hardware_property_default_input_device,
            .mScope = audio_object_property_scope_global,
            .mElement = audio_object_property_element_main,
        };
        var device: u32 = audio_object_unknown;
        var size: u32 = @sizeOf(u32);
        if (AudioObjectGetPropertyData(audio_object_system_object, &address, 0, null, &size, &device) != 0) return null;
        return if (device == audio_object_unknown) null else device;
    }

    pub fn start(self: *CoreAudioCapture, sample_rate: u32, device_name: []const u8) Error!void {
        while (self.queue.pop() != null) {}
        const device = if (device_name.len > 0)
            std.fmt.parseInt(u32, device_name, 10) catch return error.DeviceOpenFailed
        else
            defaultInputDevice() orelse return error.DeviceOpenFailed;
        const description = AudioComponentDescription{
            .componentType = audio_unit_type_output,
            .componentSubType = audio_unit_subtype_hal_output,
            .componentManufacturer = audio_unit_manufacturer_apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const component = AudioComponentFindNext(null, &description) orelse return error.DeviceOpenFailed;

        var unit: AudioUnit = null;
        if (AudioComponentInstanceNew(component, &unit) != 0) return error.DeviceOpenFailed;
        errdefer _ = AudioComponentInstanceDispose(unit);

        var enabled: u32 = 1;
        if (AudioUnitSetProperty(unit, audio_output_unit_property_enable_io, audio_unit_scope_input, 1, &enabled, @sizeOf(u32)) != 0)
            return error.DeviceConfigFailed;
        var disabled: u32 = 0;
        if (AudioUnitSetProperty(unit, audio_output_unit_property_enable_io, audio_unit_scope_output, 0, &disabled, @sizeOf(u32)) != 0)
            return error.DeviceConfigFailed;

        // A HAL unit defaults to the default *output* device, so capture
        // reads the wrong hardware on any Mac whose input and output
        // devices differ until it's pointed at the input one.
        var current = device;
        if (AudioUnitSetProperty(unit, audio_output_unit_property_current_device, audio_unit_scope_global, 0, &current, @sizeOf(u32)) != 0)
            return error.DeviceConfigFailed;

        const format = AudioStreamBasicDescription{
            .mSampleRate = @floatFromInt(sample_rate),
            .mFormatID = audio_format_linear_pcm,
            .mFormatFlags = audio_format_flag_is_float | audio_format_flag_is_packed,
            .mBytesPerPacket = @sizeOf(types.Sample),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = @sizeOf(types.Sample),
            .mChannelsPerFrame = 1,
            .mBitsPerChannel = @bitSizeOf(types.Sample),
            .mReserved = 0,
        };
        if (AudioUnitSetProperty(unit, audio_unit_property_stream_format, audio_unit_scope_output, 1, &format, @sizeOf(AudioStreamBasicDescription)) != 0)
            return error.DeviceConfigFailed;

        const callback = AURenderCallbackStruct{ .inputProc = captureCallback, .inputProcRefCon = self };
        if (AudioUnitSetProperty(unit, audio_output_unit_property_set_input_callback, audio_unit_scope_global, 0, &callback, @sizeOf(AURenderCallbackStruct)) != 0)
            return error.DeviceConfigFailed;
        if (AudioUnitInitialize(unit) != 0) return error.DeviceConfigFailed;
        errdefer _ = AudioUnitUninitialize(unit);
        if (AudioOutputUnitStart(unit) != 0) return error.DeviceConfigFailed;
        self.unit = unit;
    }

    pub fn stop(self: *CoreAudioCapture) void {
        const unit = self.unit orelse return;
        self.unit = null;
        _ = AudioOutputUnitStop(unit);
        _ = AudioUnitUninitialize(unit);
        _ = AudioComponentInstanceDispose(unit);
    }

    pub fn pop(self: *CoreAudioCapture) ?CaptureBlock {
        return self.queue.pop();
    }

    fn captureCallback(
        context: ?*anyopaque,
        flags: *u32,
        timestamp: *const anyopaque,
        _: u32,
        frames: u32,
        _: ?*AudioBufferList,
    ) callconv(.c) OSStatus {
        const self: *CoreAudioCapture = @ptrCast(@alignCast(context.?));
        if (frames > self.buffer.len) return -50;

        var buffers = AudioBufferList{
            .mNumberBuffers = 1,
            .mBuffers = .{.{
                .mNumberChannels = 1,
                .mDataByteSize = frames * @sizeOf(types.Sample),
                .mData = &self.buffer,
            }},
        };
        const status = AudioUnitRender(self.unit, flags, timestamp, 1, frames, &buffers);
        if (status != 0) return status;

        var offset: usize = 0;
        while (offset < frames) {
            var block: CaptureBlock = .{};
            const count = @min(capture_types.chunk_frames, frames - offset);
            @memcpy(block.samples[0..count], self.buffer[offset..][0..count]);
            block.frames = count;
            _ = self.queue.push(block);
            offset += count;
        }
        return 0;
    }
};
