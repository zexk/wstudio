//! Minimal CLAP shared library used by the host integration test.

const abi = @import("abi.zig");

const State = struct {
    active: bool = false,
    processing: bool = false,
    gain: f64 = 2,
    host: ?*const abi.Host = null,
};

var state: State = .{};

const features = [_:null]?[*:0]const u8{
    "audio-effect",
    "stereo",
};

const descriptor: abi.PluginDescriptor = .{
    .clap_version = abi.version,
    .id = "studio.wstudio.test.double",
    .name = "wstudio CLAP test",
    .vendor = "wstudio",
    .url = null,
    .manual_url = null,
    .support_url = null,
    .plugin_version = "1.0",
    .description = "Doubles stereo input",
    .features = &features,
};

const instrument_features = [_:null]?[*:0]const u8{
    "instrument",
    "synthesizer",
    "stereo",
};

const instrument_descriptor: abi.PluginDescriptor = .{
    .clap_version = abi.version,
    .id = "studio.wstudio.test.instrument",
    .name = "wstudio CLAP instrument test",
    .vendor = "wstudio",
    .url = null,
    .manual_url = null,
    .support_url = null,
    .plugin_version = "1.0",
    .description = "Test instrument",
    .features = &instrument_features,
};

fn pluginInit(_: *const abi.Plugin) callconv(.c) bool {
    const host = state.host orelse return false;
    host.request_callback(host);
    const host_state: *const abi.HostState = @ptrCast(@alignCast(host.get_extension(host, abi.ext_state) orelse return false));
    host_state.mark_dirty(host);
    const host_params: *const abi.HostParams = @ptrCast(@alignCast(host.get_extension(host, abi.ext_params) orelse return false));
    host_params.request_flush(host);
    const host_latency: *const abi.HostLatency = @ptrCast(@alignCast(host.get_extension(host, abi.ext_latency) orelse return false));
    host_latency.changed(host);
    const host_tail: *const abi.HostTail = @ptrCast(@alignCast(host.get_extension(host, abi.ext_tail) orelse return false));
    host_tail.changed(host);
    return true;
}

fn pluginDestroy(_: *const abi.Plugin) callconv(.c) void {}

fn pluginActivate(_: *const abi.Plugin, _: f64, min_frames: u32, max_frames: u32) callconv(.c) bool {
    if (min_frames == 0 or max_frames < min_frames) return false;
    state.active = true;
    return true;
}

fn pluginDeactivate(_: *const abi.Plugin) callconv(.c) void {
    state.active = false;
}

fn startProcessing(_: *const abi.Plugin) callconv(.c) bool {
    if (!state.active) return false;
    state.processing = true;
    return true;
}

fn stopProcessing(_: *const abi.Plugin) callconv(.c) void {
    state.processing = false;
}

fn reset(_: *const abi.Plugin) callconv(.c) void {}

fn process(_: *const abi.Plugin, block: *const abi.Process) callconv(.c) i32 {
    if (!state.processing or block.audio_inputs_count > 1 or block.audio_outputs_count != 1)
        return 0;
    const output = block.audio_outputs.?[0];
    if (output.channel_count != 2) return 0;
    const output_channels = output.data32 orelse return 0;
    const left_out = output_channels[0] orelse return 0;
    const right_out = output_channels[1] orelse return 0;
    if (block.in_events) |events| {
        for (0..events.size(events)) |index| {
            const header = events.get(events, @intCast(index)) orelse continue;
            if (header.space_id != abi.core_event_space_id or header.event_type != abi.event_param_value)
                continue;
            const event: *const abi.EventParamValue = @ptrCast(@alignCast(header));
            if (event.param_id == 7) state.gain = event.value;
        }
    }
    if (block.audio_inputs_count == 1) {
        const input = block.audio_inputs.?[0];
        if (input.channel_count != 2) return 0;
        const input_channels = input.data32 orelse return 0;
        const left_in = input_channels[0] orelse return 0;
        const right_in = input_channels[1] orelse return 0;
        for (0..block.frames_count) |frame| {
            left_out[frame] = left_in[frame] * @as(f32, @floatCast(state.gain));
            right_out[frame] = right_in[frame] * @as(f32, @floatCast(state.gain));
        }
    } else {
        for (0..block.frames_count) |frame| {
            left_out[frame] = @floatCast(state.gain);
            right_out[frame] = @floatCast(state.gain);
        }
    }
    return 1;
}

fn audioPortCount(plugin_ptr: *const abi.Plugin, is_input: bool) callconv(.c) u32 {
    if (is_input and plugin_ptr.desc == &instrument_descriptor) return 0;
    return 1;
}

fn getAudioPort(_: *const abi.Plugin, index: u32, _: bool, info: *abi.AudioPortInfo) callconv(.c) bool {
    if (index != 0) return false;
    info.* = .{
        .id = 0,
        .name = @splat(0),
        .flags = 1,
        .channel_count = 2,
        .port_type = "stereo",
        .in_place_pair = abi.invalid_id,
    };
    return true;
}

const audio_ports: abi.PluginAudioPorts = .{
    .count = audioPortCount,
    .get = getAudioPort,
};

fn notePortCount(_: *const abi.Plugin, is_input: bool) callconv(.c) u32 {
    return if (is_input) 1 else 0;
}

fn getNotePort(_: *const abi.Plugin, index: u32, is_input: bool, info: *abi.NotePortInfo) callconv(.c) bool {
    if (!is_input or index != 0) return false;
    info.* = .{
        .id = 0,
        .supported_dialects = abi.note_dialect_clap | abi.note_dialect_midi,
        .preferred_dialect = abi.note_dialect_clap,
        .name = @splat(0),
    };
    return true;
}

const note_ports: abi.PluginNotePorts = .{
    .count = notePortCount,
    .get = getNotePort,
};

fn paramCount(_: *const abi.Plugin) callconv(.c) u32 {
    return 1;
}

fn paramInfo(_: *const abi.Plugin, index: u32, info: *abi.ParamInfo) callconv(.c) bool {
    if (index != 0) return false;
    info.* = .{
        .id = 7,
        .flags = 1 << 5,
        .cookie = null,
        .name = @splat(0),
        .module = @splat(0),
        .min_value = 0,
        .max_value = 4,
        .default_value = 2,
    };
    @memcpy(info.name[0..4], "Gain");
    return true;
}

fn paramValue(_: *const abi.Plugin, id: u32, value: *f64) callconv(.c) bool {
    if (id != 7) return false;
    value.* = state.gain;
    return true;
}

fn valueToText(
    _: *const abi.Plugin,
    id: u32,
    value: f64,
    output: [*]u8,
    capacity: u32,
) callconv(.c) bool {
    if (id != 7 or capacity == 0) return false;
    const text = @import("std").fmt.bufPrintZ(output[0..capacity], "{d:.2}x", .{value}) catch return false;
    _ = text;
    return true;
}

fn textToValue(_: *const abi.Plugin, _: u32, _: [*:0]const u8, _: *f64) callconv(.c) bool {
    return false;
}

fn flushParams(
    _: *const abi.Plugin,
    _: *const abi.InputEvents,
    _: *const abi.OutputEvents,
) callconv(.c) void {
    state.gain += 0.25;
}

const params: abi.PluginParams = .{
    .count = paramCount,
    .get_info = paramInfo,
    .get_value = paramValue,
    .value_to_text = valueToText,
    .text_to_value = textToValue,
    .flush = flushParams,
};

fn saveState(_: *const abi.Plugin, stream: *const abi.OutputStream) callconv(.c) bool {
    const bytes = @as([8]u8, @bitCast(state.gain));
    return stream.write(stream, &bytes, bytes.len) == bytes.len;
}

fn loadState(_: *const abi.Plugin, stream: *const abi.InputStream) callconv(.c) bool {
    var bytes: [8]u8 = undefined;
    if (stream.read(stream, &bytes, bytes.len) != bytes.len) return false;
    state.gain = @bitCast(bytes);
    return true;
}

const plugin_state: abi.PluginState = .{
    .save = saveState,
    .load = loadState,
};

fn latency(_: *const abi.Plugin) callconv(.c) u32 {
    return 16;
}

fn tail(_: *const abi.Plugin) callconv(.c) u32 {
    return 48_000;
}

const plugin_latency: abi.PluginLatency = .{ .get = latency };
const plugin_tail: abi.PluginTail = .{ .get = tail };

fn getExtension(_: *const abi.Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const name = @import("std").mem.span(id);
    if (@import("std").mem.eql(u8, name, "clap.audio-ports")) return &audio_ports;
    if (@import("std").mem.eql(u8, name, "clap.note-ports")) return &note_ports;
    if (@import("std").mem.eql(u8, name, "clap.params")) return &params;
    if (@import("std").mem.eql(u8, name, "clap.state")) return &plugin_state;
    if (@import("std").mem.eql(u8, name, "clap.latency")) return &plugin_latency;
    if (@import("std").mem.eql(u8, name, "clap.tail")) return &plugin_tail;
    return null;
}

fn onMainThread(_: *const abi.Plugin) callconv(.c) void {
    state.gain += 0.25;
}

const plugin: abi.Plugin = .{
    .desc = &descriptor,
    .plugin_data = &state,
    .init = pluginInit,
    .destroy = pluginDestroy,
    .activate = pluginActivate,
    .deactivate = pluginDeactivate,
    .start_processing = startProcessing,
    .stop_processing = stopProcessing,
    .reset = reset,
    .process = process,
    .get_extension = getExtension,
    .on_main_thread = onMainThread,
};

const instrument_plugin: abi.Plugin = .{
    .desc = &instrument_descriptor,
    .plugin_data = &state,
    .init = pluginInit,
    .destroy = pluginDestroy,
    .activate = pluginActivate,
    .deactivate = pluginDeactivate,
    .start_processing = startProcessing,
    .stop_processing = stopProcessing,
    .reset = reset,
    .process = process,
    .get_extension = getExtension,
    .on_main_thread = onMainThread,
};

fn pluginCount(_: *const abi.PluginFactory) callconv(.c) u32 {
    return 2;
}

fn pluginDescriptor(_: *const abi.PluginFactory, index: u32) callconv(.c) ?*const abi.PluginDescriptor {
    return switch (index) {
        0 => &descriptor,
        1 => &instrument_descriptor,
        else => null,
    };
}

fn createPlugin(
    _: *const abi.PluginFactory,
    host: *const abi.Host,
    id: [*:0]const u8,
) callconv(.c) ?*const abi.Plugin {
    const requested = @import("std").mem.span(id);
    state.host = host;
    if (@import("std").mem.eql(u8, requested, @import("std").mem.span(descriptor.id))) return &plugin;
    if (@import("std").mem.eql(u8, requested, @import("std").mem.span(instrument_descriptor.id))) return &instrument_plugin;
    return null;
}

const factory: abi.PluginFactory = .{
    .get_plugin_count = pluginCount,
    .get_plugin_descriptor = pluginDescriptor,
    .create_plugin = createPlugin,
};

fn entryInit(_: [*:0]const u8) callconv(.c) bool {
    state = .{};
    return true;
}

fn entryDeinit() callconv(.c) void {}

fn getFactory(id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    return if (@import("std").mem.eql(u8, @import("std").mem.span(id), @import("std").mem.span(abi.plugin_factory_id)))
        &factory
    else
        null;
}

pub export const clap_entry: abi.PluginEntry = .{
    .clap_version = abi.version,
    .init = entryInit,
    .deinit = entryDeinit,
    .get_factory = getFactory,
};
