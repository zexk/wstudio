//! CLAP 1.2.10 ABI subset used by wstudio's host adapter.
//!
//! Field order and integer widths mirror the official C headers at
//! https://github.com/free-audio/clap/tree/1.2.10/include/clap.

pub const Version = extern struct {
    major: u32,
    minor: u32,
    revision: u32,
};

pub const version: Version = .{ .major = 1, .minor = 2, .revision = 10 };
pub const plugin_factory_id: [*:0]const u8 = "clap.plugin-factory";
pub const ext_audio_ports: [*:0]const u8 = "clap.audio-ports";
pub const invalid_id: u32 = 0xffffffff;

pub const EventHeader = extern struct {
    size: u32,
    time: u32,
    space_id: u16,
    event_type: u16,
    flags: u32,
};

pub const EventNote = extern struct {
    header: EventHeader,
    note_id: i32,
    port_index: i16,
    channel: i16,
    key: i16,
    velocity: f64,
};

pub const EventMidi = extern struct {
    header: EventHeader,
    port_index: u16,
    data: [3]u8,
};

pub const event_note_on: u16 = 0;
pub const event_note_off: u16 = 1;
pub const event_note_choke: u16 = 2;
pub const event_midi: u16 = 10;
pub const core_event_space_id: u16 = 0;

pub const InputEvents = extern struct {
    ctx: ?*anyopaque,
    size: *const fn (?*const InputEvents) callconv(.c) u32,
    get: *const fn (?*const InputEvents, u32) callconv(.c) ?*const EventHeader,
};

pub const OutputEvents = extern struct {
    ctx: ?*anyopaque,
    try_push: *const fn (?*const OutputEvents, *const EventHeader) callconv(.c) bool,
};

pub const AudioPortInfo = extern struct {
    id: u32,
    name: [256]u8,
    flags: u32,
    channel_count: u32,
    port_type: ?[*:0]const u8,
    in_place_pair: u32,
};

pub const PluginAudioPorts = extern struct {
    count: *const fn (*const Plugin, bool) callconv(.c) u32,
    get: *const fn (*const Plugin, u32, bool, *AudioPortInfo) callconv(.c) bool,
};

pub const AudioBuffer = extern struct {
    data32: ?[*]?[*]f32,
    data64: ?[*]?[*]f64,
    channel_count: u32,
    latency: u32,
    constant_mask: u64,
};

pub const Process = extern struct {
    steady_time: i64,
    frames_count: u32,
    transport: ?*const anyopaque,
    audio_inputs: ?[*]const AudioBuffer,
    audio_outputs: ?[*]AudioBuffer,
    audio_inputs_count: u32,
    audio_outputs_count: u32,
    in_events: ?*const InputEvents,
    out_events: ?*const OutputEvents,
};

pub const PluginDescriptor = extern struct {
    clap_version: Version,
    id: [*:0]const u8,
    name: [*:0]const u8,
    vendor: ?[*:0]const u8,
    url: ?[*:0]const u8,
    manual_url: ?[*:0]const u8,
    support_url: ?[*:0]const u8,
    plugin_version: ?[*:0]const u8,
    description: ?[*:0]const u8,
    features: ?[*:null]const ?[*:0]const u8,
};

pub const Host = extern struct {
    clap_version: Version,
    host_data: ?*anyopaque,
    name: [*:0]const u8,
    vendor: [*:0]const u8,
    url: [*:0]const u8,
    host_version: [*:0]const u8,
    get_extension: *const fn (*const Host, [*:0]const u8) callconv(.c) ?*const anyopaque,
    request_restart: *const fn (*const Host) callconv(.c) void,
    request_process: *const fn (*const Host) callconv(.c) void,
    request_callback: *const fn (*const Host) callconv(.c) void,
};

pub const Plugin = extern struct {
    desc: *const PluginDescriptor,
    plugin_data: ?*anyopaque,
    init: *const fn (*const Plugin) callconv(.c) bool,
    destroy: *const fn (*const Plugin) callconv(.c) void,
    activate: *const fn (*const Plugin, f64, u32, u32) callconv(.c) bool,
    deactivate: *const fn (*const Plugin) callconv(.c) void,
    start_processing: *const fn (*const Plugin) callconv(.c) bool,
    stop_processing: *const fn (*const Plugin) callconv(.c) void,
    reset: *const fn (*const Plugin) callconv(.c) void,
    process: *const fn (*const Plugin, *const Process) callconv(.c) i32,
    get_extension: *const fn (*const Plugin, [*:0]const u8) callconv(.c) ?*const anyopaque,
    on_main_thread: *const fn (*const Plugin) callconv(.c) void,
};

pub const PluginFactory = extern struct {
    get_plugin_count: *const fn (*const PluginFactory) callconv(.c) u32,
    get_plugin_descriptor: *const fn (*const PluginFactory, u32) callconv(.c) ?*const PluginDescriptor,
    create_plugin: *const fn (*const PluginFactory, *const Host, [*:0]const u8) callconv(.c) ?*const Plugin,
};

pub const PluginEntry = extern struct {
    clap_version: Version,
    init: *const fn ([*:0]const u8) callconv(.c) bool,
    deinit: *const fn () callconv(.c) void,
    get_factory: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque,
};

pub fn versionIsCompatible(v: Version) bool {
    return v.major >= 1;
}

comptime {
    if (@sizeOf(EventHeader) != 16) @compileError("CLAP event header ABI mismatch");
    if (@offsetOf(Plugin, "process") <= @offsetOf(Plugin, "reset"))
        @compileError("CLAP plugin ABI field order mismatch");
}
