//! Minimal CLAP shared library used by the host integration test.

const abi = @import("abi.zig");

const State = struct {
    active: bool = false,
    processing: bool = false,
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

fn pluginInit(_: *const abi.Plugin) callconv(.c) bool {
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
    if (!state.processing or block.audio_inputs_count != 1 or block.audio_outputs_count != 1)
        return 0;
    const input = block.audio_inputs.?[0];
    const output = block.audio_outputs.?[0];
    if (input.channel_count != 2 or output.channel_count != 2) return 0;
    const input_channels = input.data32 orelse return 0;
    const output_channels = output.data32 orelse return 0;
    const left_in = input_channels[0] orelse return 0;
    const right_in = input_channels[1] orelse return 0;
    const left_out = output_channels[0] orelse return 0;
    const right_out = output_channels[1] orelse return 0;
    for (0..block.frames_count) |frame| {
        left_out[frame] = left_in[frame] * 2;
        right_out[frame] = right_in[frame] * 2;
    }
    return 1;
}

fn audioPortCount(_: *const abi.Plugin, _: bool) callconv(.c) u32 {
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

fn getExtension(_: *const abi.Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    if (@import("std").mem.eql(u8, @import("std").mem.span(id), "clap.audio-ports")) return &audio_ports;
    return null;
}

fn onMainThread(_: *const abi.Plugin) callconv(.c) void {}

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

fn pluginCount(_: *const abi.PluginFactory) callconv(.c) u32 {
    return 1;
}

fn pluginDescriptor(_: *const abi.PluginFactory, index: u32) callconv(.c) ?*const abi.PluginDescriptor {
    return if (index == 0) &descriptor else null;
}

fn createPlugin(
    _: *const abi.PluginFactory,
    _: *const abi.Host,
    id: [*:0]const u8,
) callconv(.c) ?*const abi.Plugin {
    return if (@import("std").mem.eql(u8, @import("std").mem.span(id), @import("std").mem.span(descriptor.id)))
        &plugin
    else
        null;
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
