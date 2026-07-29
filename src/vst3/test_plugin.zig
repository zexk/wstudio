const std = @import("std");
const abi = @import("abi.zig");

const instrument_id = abi.uid(0x57535449, 0x4E535452, 0x554D454E, 0x54000001);
const effect_id = abi.uid(0x57535445, 0x46464543, 0x54000000, 0x00000001);
const mono_effect_id = abi.uid(0x5753544D, 0x4F4E4F46, 0x58000000, 0x00000001);
const instrument_controller_id = abi.uid(0x57534349, 0x4E535452, 0x554D454E, 0x54000001);
const effect_controller_id = abi.uid(0x57534345, 0x46464543, 0x54000000, 0x00000001);
const mono_controller_id = abi.uid(0x5753434D, 0x4F4E4F46, 0x58000000, 0x00000001);

fn copyText(destination: []u8, source: []const u8) void {
    @memcpy(destination[0..source.len], source);
    destination[source.len] = 0;
}

fn queryInterface(_: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
    if (std.mem.eql(u8, iid, &abi.plugin_factory_iid) or std.mem.eql(u8, iid, &abi.plugin_factory_2_iid)) {
        object.* = @ptrCast(&factory);
        return 0;
    }
    object.* = null;
    return -1;
}

fn addRef(_: *anyopaque) callconv(abi.abi_callconv) u32 {
    return 1;
}

fn release(_: *anyopaque) callconv(abi.abi_callconv) u32 {
    return 1;
}

fn getFactoryInfo(_: *anyopaque, info: *abi.FactoryInfo) callconv(abi.abi_callconv) abi.Result {
    info.* = std.mem.zeroes(abi.FactoryInfo);
    copyText(&info.vendor, "wstudio");
    return 0;
}

fn countClasses(_: *anyopaque) callconv(abi.abi_callconv) i32 {
    return 3;
}

fn getClassInfo(_: *anyopaque, _: i32, _: *abi.ClassInfo) callconv(abi.abi_callconv) abi.Result {
    return -1;
}

fn createInstance(_: *anyopaque, cid: [*]const u8, iid: [*]const u8, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
    const instance = if (std.mem.eql(u8, cid[0..16], &instrument_id) or std.mem.eql(u8, cid[0..16], &instrument_controller_id)) &instrument else if (std.mem.eql(u8, cid[0..16], &effect_id) or std.mem.eql(u8, cid[0..16], &effect_controller_id)) &effect else if (std.mem.eql(u8, cid[0..16], &mono_effect_id) or std.mem.eql(u8, cid[0..16], &mono_controller_id)) &mono_effect else return -1;
    if (std.mem.eql(u8, iid[0..16], &abi.component_iid)) object.* = @ptrCast(&instance.component) else if (std.mem.eql(u8, iid[0..16], &abi.edit_controller_iid)) object.* = @ptrCast(&instance.controller) else return -1;
    return 0;
}

fn getClassInfo2(_: *anyopaque, index: i32, info: *abi.ClassInfo2) callconv(abi.abi_callconv) abi.Result {
    info.* = std.mem.zeroes(abi.ClassInfo2);
    info.cardinality = 1;
    copyText(&info.category, "Audio Module Class");
    copyText(&info.vendor, "wstudio");
    switch (index) {
        0 => {
            info.cid = instrument_id;
            copyText(&info.name, "wstudio VST3 Test Instrument");
            copyText(&info.subcategories, "Instrument|Synth");
        },
        1 => {
            info.cid = effect_id;
            copyText(&info.name, "wstudio VST3 Test Effect");
            copyText(&info.subcategories, "Fx");
        },
        2 => {
            info.cid = mono_effect_id;
            copyText(&info.name, "wstudio VST3 Test Mono Effect");
            copyText(&info.subcategories, "Fx");
        },
        else => return -1,
    }
    return 0;
}

var factory_vtable: abi.PluginFactory2VTable = .{
    .query_interface = queryInterface,
    .add_ref = addRef,
    .release = release,
    .get_factory_info = getFactoryInfo,
    .count_classes = countClasses,
    .get_class_info = getClassInfo,
    .create_instance = createInstance,
    .get_class_info_2 = getClassInfo2,
};
var factory: abi.PluginFactory2 = .{ .vtable = &factory_vtable };

const ComponentFace = struct { vtable: *const abi.ComponentVTable, owner: *Instance };
const ProcessorFace = struct { vtable: *const abi.AudioProcessorVTable, owner: *Instance };
const ControllerFace = struct { vtable: *const abi.EditControllerVTable, owner: *Instance };
const Instance = struct { component: ComponentFace, processor: ProcessorFace, controller: ControllerFace, instrument: bool, channels: u8, param: f64 = 1 };
var instrument: Instance = undefined;
var effect: Instance = undefined;
var mono_effect: Instance = undefined;

fn componentOwner(raw: *anyopaque) *Instance {
    return (@as(*ComponentFace, @ptrCast(@alignCast(raw)))).owner;
}
fn processorOwner(raw: *anyopaque) *Instance {
    return (@as(*ProcessorFace, @ptrCast(@alignCast(raw)))).owner;
}
fn componentQuery(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
    const owner = componentOwner(raw);
    if (std.mem.eql(u8, iid, &abi.component_iid)) object.* = @ptrCast(&owner.component) else if (std.mem.eql(u8, iid, &abi.audio_processor_iid)) object.* = @ptrCast(&owner.processor) else {
        object.* = null;
        return -1;
    }
    return 0;
}
fn initialize(_: *anyopaque, _: ?*abi.FUnknown) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn terminate(_: *anyopaque) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn getController(raw: *anyopaque, id: *abi.Tuid) callconv(abi.abi_callconv) abi.Result {
    const owner = componentOwner(raw);
    id.* = if (owner.instrument) instrument_controller_id else if (owner.channels == 1) mono_controller_id else effect_controller_id;
    return 0;
}
fn setIoMode(_: *anyopaque, _: i32) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn getBusCount(raw: *anyopaque, media: i32, direction: i32) callconv(abi.abi_callconv) i32 {
    if (media != 0) return 0;
    if (direction == 1) return 1;
    return if (componentOwner(raw).instrument) 0 else 1;
}
fn getBusInfo(raw: *anyopaque, media: i32, direction: i32, index: i32, info: *abi.BusInfo) callconv(abi.abi_callconv) abi.Result {
    if (media != 0 or index != 0 or (direction == 0 and componentOwner(raw).instrument)) return -1;
    info.* = std.mem.zeroes(abi.BusInfo);
    info.media_type = 0;
    info.direction = direction;
    info.channel_count = componentOwner(raw).channels;
    info.bus_type = 0;
    info.flags = 1;
    return 0;
}
fn noRouting(_: *anyopaque, _: *anyopaque, _: *anyopaque) callconv(abi.abi_callconv) abi.Result {
    return -1;
}
fn activateBus(_: *anyopaque, _: i32, _: i32, _: i32, _: u8) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn setActive(_: *anyopaque, _: u8) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn noState(_: *anyopaque, _: *anyopaque) callconv(abi.abi_callconv) abi.Result {
    return -1;
}

var component_vtable: abi.ComponentVTable = .{
    .query_interface = componentQuery,
    .add_ref = addRef,
    .release = release,
    .initialize = initialize,
    .terminate = terminate,
    .get_controller_class_id = getController,
    .set_io_mode = setIoMode,
    .get_bus_count = getBusCount,
    .get_bus_info = getBusInfo,
    .get_routing_info = noRouting,
    .activate_bus = activateBus,
    .set_active = setActive,
    .set_state = noState,
    .get_state = noState,
};

fn processorQuery(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
    return componentQuery(&processorOwner(raw).component, iid, object);
}
fn setBusArrangements(_: *anyopaque, _: ?[*]u64, _: i32, _: ?[*]u64, _: i32) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn getBusArrangement(_: *anyopaque, _: i32, _: i32, arrangement: *u64) callconv(abi.abi_callconv) abi.Result {
    arrangement.* = 3;
    return 0;
}
fn canProcess(_: *anyopaque, size: i32) callconv(abi.abi_callconv) abi.Result {
    return if (size == 0) 0 else -1;
}
fn latency(_: *anyopaque) callconv(abi.abi_callconv) u32 {
    return 7;
}
fn setup(_: *anyopaque, _: *abi.ProcessSetup) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn setProcessing(_: *anyopaque, _: u8) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn process(raw: *anyopaque, data: *abi.ProcessData) callconv(abi.abi_callconv) abi.Result {
    const owner = processorOwner(raw);
    const changes: *abi.ParameterChanges = @ptrCast(@alignCast(data.input_parameter_changes.?));
    for (0..@as(usize, @intCast(changes.vtable.get_parameter_count(changes)))) |i| {
        const queue = changes.vtable.get_parameter_data(changes, @intCast(i)) orelse continue;
        if (queue.vtable.get_parameter_id(queue) != 100) continue;
        var offset: i32 = 0;
        var value: f64 = 0;
        if (queue.vtable.get_point(queue, 0, &offset, &value) == 0) owner.param = value;
    }
    const frames: usize = @intCast(data.num_samples);
    const output = &data.outputs.?[0];
    const events: *abi.EventList = @ptrCast(@alignCast(data.input_events.?));
    const context: *abi.ProcessContext = @ptrCast(@alignCast(data.process_context.?));
    const instrument_value: f32 = if (events.vtable.get_event_count(events) > 0) @floatCast(context.tempo / 480.0) else 0;
    for (0..frames) |frame| for (0..@as(usize, @intCast(output.num_channels))) |channel| {
        output.buffers.channel_buffers_32[channel][frame] = if (owner.instrument) instrument_value * @as(f32, @floatCast(owner.param)) else data.inputs.?[0].buffers.channel_buffers_32[channel][frame] * 2 * @as(f32, @floatCast(owner.param));
    };
    return 0;
}
fn tail(_: *anyopaque) callconv(abi.abi_callconv) u32 {
    return 0;
}
var processor_vtable: abi.AudioProcessorVTable = .{
    .query_interface = processorQuery,
    .add_ref = addRef,
    .release = release,
    .set_bus_arrangements = setBusArrangements,
    .get_bus_arrangement = getBusArrangement,
    .can_process_sample_size = canProcess,
    .get_latency_samples = latency,
    .setup_processing = setup,
    .set_processing = setProcessing,
    .process = process,
    .get_tail_samples = tail,
};

fn controllerOwner(raw: *anyopaque) *Instance {
    return (@as(*ControllerFace, @ptrCast(@alignCast(raw)))).owner;
}
fn controllerQuery(raw: *anyopaque, iid: *const abi.Tuid, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
    if (!std.mem.eql(u8, iid, &abi.edit_controller_iid)) {
        object.* = null;
        return -1;
    }
    object.* = raw;
    return 0;
}
fn getParameterCount(_: *anyopaque) callconv(abi.abi_callconv) i32 {
    return 1;
}
fn getParameterInfo(_: *anyopaque, index: i32, info: *abi.ParameterInfo) callconv(abi.abi_callconv) abi.Result {
    if (index != 0) return -1;
    info.* = std.mem.zeroes(abi.ParameterInfo);
    info.id = 100;
    for ("Gain", 0..) |byte, i| info.title[i] = byte;
    info.default_normalized_value = 1;
    info.flags = 1;
    return 0;
}
fn getString(_: *anyopaque, id: u32, value: f64, output: *[128]u16) callconv(abi.abi_callconv) abi.Result {
    if (id != 100) return -1;
    output.* = std.mem.zeroes([128]u16);
    const percent: u8 = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 100));
    var ascii: [4]u8 = undefined;
    const text = std.fmt.bufPrint(&ascii, "{d}%", .{percent}) catch return -1;
    for (text, 0..) |byte, i| output[i] = byte;
    return 0;
}
fn valueFromString(_: *anyopaque, _: u32, _: [*]u16, _: *f64) callconv(abi.abi_callconv) abi.Result {
    return -1;
}
fn identity(_: *anyopaque, _: u32, value: f64) callconv(abi.abi_callconv) f64 {
    return value;
}
fn getNormalized(raw: *anyopaque, id: u32) callconv(abi.abi_callconv) f64 {
    return if (id == 100) controllerOwner(raw).param else 0;
}
fn setNormalized(raw: *anyopaque, id: u32, value: f64) callconv(abi.abi_callconv) abi.Result {
    if (id != 100) return -1;
    controllerOwner(raw).param = value;
    return 0;
}
fn setHandler(_: *anyopaque, _: ?*abi.ComponentHandler) callconv(abi.abi_callconv) abi.Result {
    return 0;
}
fn createView(_: *anyopaque, _: [*:0]const u8) callconv(abi.abi_callconv) ?*anyopaque {
    return null;
}
var controller_vtable: abi.EditControllerVTable = .{
    .query_interface = controllerQuery,
    .add_ref = addRef,
    .release = release,
    .initialize = initialize,
    .terminate = terminate,
    .set_component_state = noState,
    .set_state = noState,
    .get_state = noState,
    .get_parameter_count = getParameterCount,
    .get_parameter_info = getParameterInfo,
    .get_param_string_by_value = getString,
    .get_param_value_by_string = valueFromString,
    .normalized_param_to_plain = identity,
    .plain_param_to_normalized = identity,
    .get_param_normalized = getNormalized,
    .set_param_normalized = setNormalized,
    .set_component_handler = setHandler,
    .create_view = createView,
};

export fn ModuleEntry(_: ?*anyopaque) callconv(abi.abi_callconv) bool {
    instrument = .{ .component = .{ .vtable = &component_vtable, .owner = &instrument }, .processor = .{ .vtable = &processor_vtable, .owner = &instrument }, .controller = .{ .vtable = &controller_vtable, .owner = &instrument }, .instrument = true, .channels = 2 };
    effect = .{ .component = .{ .vtable = &component_vtable, .owner = &effect }, .processor = .{ .vtable = &processor_vtable, .owner = &effect }, .controller = .{ .vtable = &controller_vtable, .owner = &effect }, .instrument = false, .channels = 2 };
    mono_effect = .{ .component = .{ .vtable = &component_vtable, .owner = &mono_effect }, .processor = .{ .vtable = &processor_vtable, .owner = &mono_effect }, .controller = .{ .vtable = &controller_vtable, .owner = &mono_effect }, .instrument = false, .channels = 1 };
    return true;
}

export fn ModuleExit() callconv(abi.abi_callconv) bool {
    return true;
}

export fn InitDll() callconv(abi.abi_callconv) bool {
    return ModuleEntry(null);
}

export fn ExitDll() callconv(abi.abi_callconv) bool {
    return true;
}

export fn GetPluginFactory() callconv(abi.abi_callconv) ?*abi.PluginFactory {
    return @ptrCast(&factory);
}
