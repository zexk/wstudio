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
pub const ext_params: [*:0]const u8 = "clap.params";
pub const ext_state: [*:0]const u8 = "clap.state";
pub const ext_latency: [*:0]const u8 = "clap.latency";
pub const ext_tail: [*:0]const u8 = "clap.tail";
pub const ext_thread_check: [*:0]const u8 = "clap.thread-check";
pub const ext_log: [*:0]const u8 = "clap.log";
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

pub const EventParamValue = extern struct {
    header: EventHeader,
    param_id: u32,
    cookie: ?*anyopaque,
    note_id: i32,
    port_index: i16,
    channel: i16,
    key: i16,
    value: f64,
};

pub const EventTransport = extern struct {
    header: EventHeader,
    flags: u32,
    song_pos_beats: i64,
    song_pos_seconds: i64,
    tempo: f64,
    tempo_inc: f64,
    loop_start_beats: i64,
    loop_end_beats: i64,
    loop_start_seconds: i64,
    loop_end_seconds: i64,
    bar_start: i64,
    bar_number: i32,
    tsig_num: u16,
    tsig_denom: u16,
};

pub const event_note_on: u16 = 0;
pub const event_note_off: u16 = 1;
pub const event_note_choke: u16 = 2;
pub const event_param_value: u16 = 5;
pub const event_midi: u16 = 10;
pub const event_transport: u16 = 9;
pub const core_event_space_id: u16 = 0;

pub const transport_has_tempo: u32 = 1 << 0;
pub const transport_has_beats_timeline: u32 = 1 << 1;
pub const transport_has_seconds_timeline: u32 = 1 << 2;
pub const transport_has_time_signature: u32 = 1 << 3;
pub const transport_is_playing: u32 = 1 << 4;
pub const transport_is_loop_active: u32 = 1 << 6;

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

pub const ParamInfo = extern struct {
    id: u32,
    flags: u32,
    cookie: ?*anyopaque,
    name: [256]u8,
    module: [1024]u8,
    min_value: f64,
    max_value: f64,
    default_value: f64,
};

pub const PluginParams = extern struct {
    count: *const fn (*const Plugin) callconv(.c) u32,
    get_info: *const fn (*const Plugin, u32, *ParamInfo) callconv(.c) bool,
    get_value: *const fn (*const Plugin, u32, *f64) callconv(.c) bool,
    value_to_text: *const fn (*const Plugin, u32, f64, [*]u8, u32) callconv(.c) bool,
    text_to_value: *const fn (*const Plugin, u32, [*:0]const u8, *f64) callconv(.c) bool,
    flush: *const fn (*const Plugin, *const InputEvents, *const OutputEvents) callconv(.c) void,
};

pub const HostParams = extern struct {
    rescan: *const fn (*const Host, u32) callconv(.c) void,
    clear: *const fn (*const Host, u32, u32) callconv(.c) void,
    request_flush: *const fn (*const Host) callconv(.c) void,
};

pub const InputStream = extern struct {
    ctx: *anyopaque,
    read: *const fn (*const InputStream, *anyopaque, u64) callconv(.c) i64,
};

pub const OutputStream = extern struct {
    ctx: *anyopaque,
    write: *const fn (*const OutputStream, *const anyopaque, u64) callconv(.c) i64,
};

pub const PluginState = extern struct {
    save: *const fn (*const Plugin, *const OutputStream) callconv(.c) bool,
    load: *const fn (*const Plugin, *const InputStream) callconv(.c) bool,
};

pub const HostState = extern struct {
    mark_dirty: *const fn (*const Host) callconv(.c) void,
};

pub const PluginLatency = extern struct {
    get: *const fn (*const Plugin) callconv(.c) u32,
};

pub const HostLatency = extern struct {
    changed: *const fn (*const Host) callconv(.c) void,
};

pub const PluginTail = extern struct {
    get: *const fn (*const Plugin) callconv(.c) u32,
};

pub const HostTail = extern struct {
    changed: *const fn (*const Host) callconv(.c) void,
};

pub const HostThreadCheck = extern struct {
    is_main_thread: *const fn (*const Host) callconv(.c) bool,
    is_audio_thread: *const fn (*const Host) callconv(.c) bool,
};

pub const HostLog = extern struct {
    log: *const fn (*const Host, i32, [*:0]const u8) callconv(.c) void,
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
