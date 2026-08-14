//! Zig adapter for Steinberg's official generated VST3 C API.

const std = @import("std");
const builtin = @import("builtin");
const official = @import("vst3_c_api").api;

pub const Result = i32;
pub const not_implemented: Result = if (builtin.os.tag == .windows) @bitCast(@as(u32, 0x80004001)) else 3;
pub const Tuid = [16]u8;
pub const abi_callconv: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const FUnknownVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
};

pub const FUnknown = extern struct {
    vtable: *const FUnknownVTable,
};
pub const HostApplicationVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    get_name: *const fn (*anyopaque, *[128]u16) callconv(abi_callconv) Result,
    create_instance: *const fn (*anyopaque, *const Tuid, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
};
pub const HostApplication = extern struct { vtable: *const HostApplicationVTable };

pub const FactoryInfo = extern struct {
    vendor: [64]u8,
    url: [256]u8,
    email: [128]u8,
    flags: i32,
};

pub const ClassInfo = extern struct {
    cid: Tuid,
    cardinality: i32,
    category: [32]u8,
    name: [64]u8,
};

pub const ClassInfo2 = extern struct {
    cid: Tuid,
    cardinality: i32,
    category: [32]u8,
    name: [64]u8,
    class_flags: u32,
    subcategories: [128]u8,
    vendor: [64]u8,
    version: [64]u8,
    sdk_version: [64]u8,
};

pub const PluginFactoryVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    get_factory_info: *const fn (*anyopaque, *FactoryInfo) callconv(abi_callconv) Result,
    count_classes: *const fn (*anyopaque) callconv(abi_callconv) i32,
    get_class_info: *const fn (*anyopaque, i32, *ClassInfo) callconv(abi_callconv) Result,
    create_instance: *const fn (*anyopaque, [*]const u8, [*]const u8, *?*anyopaque) callconv(abi_callconv) Result,
};

pub const PluginFactory = extern struct {
    vtable: *const PluginFactoryVTable,
};

pub const PluginFactory2VTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    get_factory_info: *const fn (*anyopaque, *FactoryInfo) callconv(abi_callconv) Result,
    count_classes: *const fn (*anyopaque) callconv(abi_callconv) i32,
    get_class_info: *const fn (*anyopaque, i32, *ClassInfo) callconv(abi_callconv) Result,
    create_instance: *const fn (*anyopaque, [*]const u8, [*]const u8, *?*anyopaque) callconv(abi_callconv) Result,
    get_class_info_2: *const fn (*anyopaque, i32, *ClassInfo2) callconv(abi_callconv) Result,
};

pub const PluginFactory2 = extern struct {
    vtable: *const PluginFactory2VTable,
};

pub const BusInfo = extern struct {
    media_type: i32,
    direction: i32,
    channel_count: i32,
    name: [128]u16,
    bus_type: i32,
    flags: u32,
};

pub const ComponentVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    initialize: *const fn (*anyopaque, ?*FUnknown) callconv(abi_callconv) Result,
    terminate: *const fn (*anyopaque) callconv(abi_callconv) Result,
    get_controller_class_id: *const fn (*anyopaque, *Tuid) callconv(abi_callconv) Result,
    set_io_mode: *const fn (*anyopaque, i32) callconv(abi_callconv) Result,
    get_bus_count: *const fn (*anyopaque, i32, i32) callconv(abi_callconv) i32,
    get_bus_info: *const fn (*anyopaque, i32, i32, i32, *BusInfo) callconv(abi_callconv) Result,
    get_routing_info: *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(abi_callconv) Result,
    activate_bus: *const fn (*anyopaque, i32, i32, i32, u8) callconv(abi_callconv) Result,
    set_active: *const fn (*anyopaque, u8) callconv(abi_callconv) Result,
    set_state: *const fn (*anyopaque, *anyopaque) callconv(abi_callconv) Result,
    get_state: *const fn (*anyopaque, *anyopaque) callconv(abi_callconv) Result,
};

pub const Component = extern struct { vtable: *const ComponentVTable };

pub const StreamVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    // The four out-parameters below are all optional in the VST3 spec: a
    // plugin that does not care how many bytes moved passes null (JUCE's
    // `getState` does exactly that for `numBytesWritten`), so they are
    // `?*` here and every implementation must null-check before storing.
    read: *const fn (*anyopaque, *anyopaque, i32, ?*i32) callconv(abi_callconv) Result,
    write: *const fn (*anyopaque, *const anyopaque, i32, ?*i32) callconv(abi_callconv) Result,
    seek: *const fn (*anyopaque, i64, i32, ?*i64) callconv(abi_callconv) Result,
    tell: *const fn (*anyopaque, ?*i64) callconv(abi_callconv) Result,
};
pub const Stream = extern struct { vtable: *const StreamVTable };

pub const ProcessSetup = extern struct { process_mode: i32, symbolic_sample_size: i32, max_samples_per_block: i32, sample_rate: f64 };
pub const NoteOnEvent = extern struct { channel: i16, pitch: i16, tuning: f32, velocity: f32, length: i32, note_id: i32 };
pub const NoteOffEvent = extern struct { channel: i16, pitch: i16, velocity: f32, note_id: i32, tuning: f32 };
pub const EventPayload = extern union { note_on: NoteOnEvent, note_off: NoteOffEvent, reserved: [3]u64 };
pub const Event = extern struct { bus_index: i32, sample_offset: i32, ppq_position: f64, flags: u16, event_type: u16, payload: EventPayload };
pub const EventListVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    get_event_count: *const fn (*anyopaque) callconv(abi_callconv) i32,
    get_event: *const fn (*anyopaque, i32, *Event) callconv(abi_callconv) Result,
    add_event: *const fn (*anyopaque, *Event) callconv(abi_callconv) Result,
};
pub const EventList = extern struct { vtable: *const EventListVTable };
pub const ParameterInfo = extern struct {
    id: u32,
    title: [128]u16,
    short_title: [128]u16,
    units: [128]u16,
    step_count: i32,
    default_normalized_value: f64,
    unit_id: i32,
    flags: i32,
};
pub const ComponentHandlerVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    begin_edit: *const fn (*anyopaque, u32) callconv(abi_callconv) Result,
    perform_edit: *const fn (*anyopaque, u32, f64) callconv(abi_callconv) Result,
    end_edit: *const fn (*anyopaque, u32) callconv(abi_callconv) Result,
    restart_component: *const fn (*anyopaque, i32) callconv(abi_callconv) Result,
};
pub const ComponentHandler = extern struct { vtable: *const ComponentHandlerVTable };
pub const EditControllerVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    initialize: *const fn (*anyopaque, ?*FUnknown) callconv(abi_callconv) Result,
    terminate: *const fn (*anyopaque) callconv(abi_callconv) Result,
    set_component_state: *const fn (*anyopaque, *anyopaque) callconv(abi_callconv) Result,
    set_state: *const fn (*anyopaque, *anyopaque) callconv(abi_callconv) Result,
    get_state: *const fn (*anyopaque, *anyopaque) callconv(abi_callconv) Result,
    get_parameter_count: *const fn (*anyopaque) callconv(abi_callconv) i32,
    get_parameter_info: *const fn (*anyopaque, i32, *ParameterInfo) callconv(abi_callconv) Result,
    get_param_string_by_value: *const fn (*anyopaque, u32, f64, *[128]u16) callconv(abi_callconv) Result,
    get_param_value_by_string: *const fn (*anyopaque, u32, [*]u16, *f64) callconv(abi_callconv) Result,
    normalized_param_to_plain: *const fn (*anyopaque, u32, f64) callconv(abi_callconv) f64,
    plain_param_to_normalized: *const fn (*anyopaque, u32, f64) callconv(abi_callconv) f64,
    get_param_normalized: *const fn (*anyopaque, u32) callconv(abi_callconv) f64,
    set_param_normalized: *const fn (*anyopaque, u32, f64) callconv(abi_callconv) Result,
    set_component_handler: *const fn (*anyopaque, ?*ComponentHandler) callconv(abi_callconv) Result,
    create_view: *const fn (*anyopaque, [*:0]const u8) callconv(abi_callconv) ?*anyopaque,
};
pub const EditController = extern struct { vtable: *const EditControllerVTable };
pub const ViewRect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const PlugFrameVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    resize_view: *const fn (*anyopaque, *PlugView, *ViewRect) callconv(abi_callconv) Result,
};
pub const PlugFrame = extern struct { vtable: *const PlugFrameVTable };
pub const PlugViewVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    is_platform_type_supported: *const fn (*anyopaque, [*:0]const u8) callconv(abi_callconv) Result,
    attached: *const fn (*anyopaque, *anyopaque, [*:0]const u8) callconv(abi_callconv) Result,
    removed: *const fn (*anyopaque) callconv(abi_callconv) Result,
    on_wheel: *const fn (*anyopaque, f32) callconv(abi_callconv) Result,
    on_key_down: *const fn (*anyopaque, u16, i16, i16) callconv(abi_callconv) Result,
    on_key_up: *const fn (*anyopaque, u16, i16, i16) callconv(abi_callconv) Result,
    get_size: *const fn (*anyopaque, *ViewRect) callconv(abi_callconv) Result,
    on_size: *const fn (*anyopaque, *ViewRect) callconv(abi_callconv) Result,
    on_focus: *const fn (*anyopaque, u8) callconv(abi_callconv) Result,
    set_frame: *const fn (*anyopaque, ?*PlugFrame) callconv(abi_callconv) Result,
    can_resize: *const fn (*anyopaque) callconv(abi_callconv) Result,
    check_size_constraint: *const fn (*anyopaque, *ViewRect) callconv(abi_callconv) Result,
};
pub const PlugView = extern struct { vtable: *const PlugViewVTable };
pub const EventHandlerVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    on_fd_is_set: *const fn (*anyopaque, c_int) callconv(abi_callconv) void,
};
pub const EventHandler = extern struct { vtable: *const EventHandlerVTable };
pub const TimerHandlerVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    on_timer: *const fn (*anyopaque) callconv(abi_callconv) void,
};
pub const TimerHandler = extern struct { vtable: *const TimerHandlerVTable };
pub const RunLoopVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    register_event_handler: *const fn (*anyopaque, *EventHandler, c_int) callconv(abi_callconv) Result,
    unregister_event_handler: *const fn (*anyopaque, *EventHandler) callconv(abi_callconv) Result,
    register_timer: *const fn (*anyopaque, *TimerHandler, u64) callconv(abi_callconv) Result,
    unregister_timer: *const fn (*anyopaque, *TimerHandler) callconv(abi_callconv) Result,
};
pub const RunLoop = extern struct { vtable: *const RunLoopVTable };
pub const MidiMappingVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    get_midi_controller_assignment: *const fn (*anyopaque, i32, i16, i16, *u32) callconv(abi_callconv) Result,
};
pub const MidiMapping = extern struct { vtable: *const MidiMappingVTable };
pub const ConnectionPointVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    connect: *const fn (*anyopaque, *ConnectionPoint) callconv(abi_callconv) Result,
    disconnect: *const fn (*anyopaque, *ConnectionPoint) callconv(abi_callconv) Result,
    notify: *const fn (*anyopaque, *anyopaque) callconv(abi_callconv) Result,
};
pub const ConnectionPoint = extern struct { vtable: *const ConnectionPointVTable };
pub const ParamValueQueueVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    get_parameter_id: *const fn (*anyopaque) callconv(abi_callconv) u32,
    get_point_count: *const fn (*anyopaque) callconv(abi_callconv) i32,
    get_point: *const fn (*anyopaque, i32, *i32, *f64) callconv(abi_callconv) Result,
    add_point: *const fn (*anyopaque, i32, f64, *i32) callconv(abi_callconv) Result,
};
pub const ParamValueQueue = extern struct { vtable: *const ParamValueQueueVTable };
pub const ParameterChangesVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    get_parameter_count: *const fn (*anyopaque) callconv(abi_callconv) i32,
    get_parameter_data: *const fn (*anyopaque, i32) callconv(abi_callconv) ?*ParamValueQueue,
    add_parameter_data: *const fn (*anyopaque, *const u32, *i32) callconv(abi_callconv) ?*ParamValueQueue,
};
pub const ParameterChanges = extern struct { vtable: *const ParameterChangesVTable };
pub const FrameRate = extern struct { frames_per_second: u32, flags: u32 };
pub const Chord = extern struct { key_note: u8, root_note: u8, chord_mask: i16 };
pub const ProcessContext = extern struct {
    state: u32,
    sample_rate: f64,
    project_time_samples: i64,
    system_time: i64,
    continuous_time_samples: i64,
    project_time_music: f64,
    bar_position_music: f64,
    cycle_start_music: f64,
    cycle_end_music: f64,
    tempo: f64,
    time_sig_numerator: i32,
    time_sig_denominator: i32,
    chord: Chord,
    smpte_offset_subframes: i32,
    frame_rate: FrameRate,
    samples_to_next_clock: i32,
};
pub const AudioBusBuffers = extern struct {
    num_channels: i32,
    silence_flags: u64,
    buffers: extern union { channel_buffers_32: [*][*]f32, channel_buffers_64: [*][*]f64 },
};
pub const ProcessData = extern struct {
    process_mode: i32,
    symbolic_sample_size: i32,
    num_samples: i32,
    num_inputs: i32,
    num_outputs: i32,
    inputs: ?[*]AudioBusBuffers,
    outputs: ?[*]AudioBusBuffers,
    input_parameter_changes: ?*anyopaque,
    output_parameter_changes: ?*anyopaque,
    input_events: ?*anyopaque,
    output_events: ?*anyopaque,
    process_context: ?*anyopaque,
};

pub const AudioProcessorVTable = extern struct {
    query_interface: *const fn (*anyopaque, *const Tuid, *?*anyopaque) callconv(abi_callconv) Result,
    add_ref: *const fn (*anyopaque) callconv(abi_callconv) u32,
    release: *const fn (*anyopaque) callconv(abi_callconv) u32,
    set_bus_arrangements: *const fn (*anyopaque, ?[*]u64, i32, ?[*]u64, i32) callconv(abi_callconv) Result,
    get_bus_arrangement: *const fn (*anyopaque, i32, i32, *u64) callconv(abi_callconv) Result,
    can_process_sample_size: *const fn (*anyopaque, i32) callconv(abi_callconv) Result,
    get_latency_samples: *const fn (*anyopaque) callconv(abi_callconv) u32,
    setup_processing: *const fn (*anyopaque, *ProcessSetup) callconv(abi_callconv) Result,
    set_processing: *const fn (*anyopaque, u8) callconv(abi_callconv) Result,
    process: *const fn (*anyopaque, *ProcessData) callconv(abi_callconv) Result,
    get_tail_samples: *const fn (*anyopaque) callconv(abi_callconv) u32,
};
pub const AudioProcessor = extern struct { vtable: *const AudioProcessorVTable };

pub fn uid(a: u32, b: u32, c: u32, d: u32) Tuid {
    if (builtin.os.tag == .windows) return .{
        @truncate(a),       @truncate(a >> 8),  @truncate(a >> 16), @truncate(a >> 24),
        @truncate(b >> 16), @truncate(b >> 24), @truncate(b),       @truncate(b >> 8),
        @truncate(c >> 24), @truncate(c >> 16), @truncate(c >> 8),  @truncate(c),
        @truncate(d >> 24), @truncate(d >> 16), @truncate(d >> 8),  @truncate(d),
    };
    return .{
        @truncate(a >> 24), @truncate(a >> 16), @truncate(a >> 8), @truncate(a),
        @truncate(b >> 24), @truncate(b >> 16), @truncate(b >> 8), @truncate(b),
        @truncate(c >> 24), @truncate(c >> 16), @truncate(c >> 8), @truncate(c),
        @truncate(d >> 24), @truncate(d >> 16), @truncate(d >> 8), @truncate(d),
    };
}

pub const f_unknown_iid: Tuid = official.Steinberg_FUnknown_iid;
pub const plugin_factory_iid: Tuid = official.Steinberg_IPluginFactory_iid;
pub const plugin_factory_2_iid: Tuid = official.Steinberg_IPluginFactory2_iid;
pub const component_iid: Tuid = official.Steinberg_Vst_IComponent_iid;
pub const host_application_iid: Tuid = official.Steinberg_Vst_IHostApplication_iid;
pub const audio_processor_iid: Tuid = official.Steinberg_Vst_IAudioProcessor_iid;
pub const event_list_iid: Tuid = official.Steinberg_Vst_IEventList_iid;
pub const edit_controller_iid: Tuid = official.Steinberg_Vst_IEditController_iid;
pub const midi_mapping_iid: Tuid = official.Steinberg_Vst_IMidiMapping_iid;
pub const connection_point_iid: Tuid = official.Steinberg_Vst_IConnectionPoint_iid;
pub const component_handler_iid: Tuid = official.Steinberg_Vst_IComponentHandler_iid;
pub const plug_view_iid: Tuid = official.Steinberg_IPlugView_iid;
pub const plug_frame_iid: Tuid = official.Steinberg_IPlugFrame_iid;
pub const run_loop_iid: Tuid = official.Steinberg_Linux_IRunLoop_iid;

pub fn formatUid(value: Tuid) [32]u8 {
    var canonical = value;
    if (builtin.os.tag == .windows) canonical = .{
        value[3],  value[2],  value[1],  value[0],
        value[5],  value[4],  value[7],  value[6],
        value[8],  value[9],  value[10], value[11],
        value[12], value[13], value[14], value[15],
    };
    return std.fmt.bytesToHex(canonical, .lower);
}

pub fn parseUid(text: []const u8) !Tuid {
    if (text.len != 32) return error.InvalidClassId;
    var canonical: Tuid = undefined;
    _ = std.fmt.hexToBytes(&canonical, text) catch return error.InvalidClassId;
    if (builtin.os.tag != .windows) return canonical;
    return .{
        canonical[3],  canonical[2],  canonical[1],  canonical[0],
        canonical[5],  canonical[4],  canonical[7],  canonical[6],
        canonical[8],  canonical[9],  canonical[10], canonical[11],
        canonical[12], canonical[13], canonical[14], canonical[15],
    };
}

comptime {
    if (@sizeOf(FUnknown) != @sizeOf(*anyopaque)) @compileError("VST3 FUnknown ABI size mismatch");
    if (@sizeOf(Tuid) != 16) @compileError("VST3 TUID ABI size mismatch");
    const pairs = .{
        .{ FactoryInfo, official.Steinberg_PFactoryInfo },           .{ ClassInfo, official.Steinberg_PClassInfo },                         .{ ClassInfo2, official.Steinberg_PClassInfo2 },
        .{ BusInfo, official.Steinberg_Vst_BusInfo },                .{ ParameterInfo, official.Steinberg_Vst_ParameterInfo },              .{ ProcessSetup, official.Steinberg_Vst_ProcessSetup },
        .{ Event, official.Steinberg_Vst_Event },                    .{ ProcessContext, official.Steinberg_Vst_ProcessContext },            .{ AudioBusBuffers, official.Steinberg_Vst_AudioBusBuffers },
        .{ ProcessData, official.Steinberg_Vst_ProcessData },        .{ PluginFactoryVTable, official.Steinberg_IPluginFactoryVtbl },       .{ PluginFactory2VTable, official.Steinberg_IPluginFactory2Vtbl },
        .{ ComponentVTable, official.Steinberg_Vst_IComponentVtbl }, .{ EditControllerVTable, official.Steinberg_Vst_IEditControllerVtbl }, .{ AudioProcessorVTable, official.Steinberg_Vst_IAudioProcessorVtbl },
    };
    for (pairs) |pair| if (@sizeOf(pair[0]) != @sizeOf(pair[1]) or @alignOf(pair[0]) != @alignOf(pair[1])) @compileError("VST3 adapter differs from official C API");
}

test "VST3 UID uses platform ABI byte order" {
    const component = uid(0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802);
    const expected: Tuid = if (builtin.os.tag == .windows)
        .{ 0x31, 0xff, 0x31, 0xe8, 0xd5, 0xf2, 0x01, 0x43, 0x92, 0x8e, 0xbb, 0xee, 0x25, 0x69, 0x78, 0x02 }
    else
        .{ 0xe8, 0x31, 0xff, 0x31, 0xf2, 0xd5, 0x43, 0x01, 0x92, 0x8e, 0xbb, 0xee, 0x25, 0x69, 0x78, 0x02 };
    try std.testing.expectEqual(expected, component);
    try std.testing.expectEqualStrings("e831ff31f2d54301928ebbee25697802", &formatUid(component));
    try std.testing.expectEqual(component, try parseUid("e831ff31f2d54301928ebbee25697802"));
    try std.testing.expectError(error.InvalidClassId, parseUid("nope"));
}
