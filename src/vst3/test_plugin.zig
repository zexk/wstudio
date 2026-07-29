const std = @import("std");
const abi = @import("abi.zig");

const instrument_id = abi.uid(0x57535449, 0x4E535452, 0x554D454E, 0x54000001);
const effect_id = abi.uid(0x57535445, 0x46464543, 0x54000000, 0x00000001);

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
    return 2;
}

fn getClassInfo(_: *anyopaque, _: i32, _: *abi.ClassInfo) callconv(abi.abi_callconv) abi.Result {
    return -1;
}

fn createInstance(_: *anyopaque, cid: [*]const u8, iid: [*]const u8, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
    if (!std.mem.eql(u8, iid[0..16], &abi.component_iid)) return -1;
    const instance = if (std.mem.eql(u8, cid[0..16], &instrument_id)) &instrument else if (std.mem.eql(u8, cid[0..16], &effect_id)) &effect else return -1;
    object.* = @ptrCast(&instance.component);
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
const Instance = struct { component: ComponentFace, processor: ProcessorFace, instrument: bool };
var instrument: Instance = undefined;
var effect: Instance = undefined;

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
fn noController(_: *anyopaque, _: *abi.Tuid) callconv(abi.abi_callconv) abi.Result {
    return -1;
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
    info.channel_count = 2;
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
    .get_controller_class_id = noController,
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
    const frames: usize = @intCast(data.num_samples);
    const output = &data.outputs.?[0];
    for (0..frames) |frame| for (0..@as(usize, @intCast(output.num_channels))) |channel| {
        output.buffers.channel_buffers_32[channel][frame] = if (processorOwner(raw).instrument) 0.25 else data.inputs.?[0].buffers.channel_buffers_32[channel][frame] * 2;
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

export fn ModuleEntry(_: ?*anyopaque) callconv(abi.abi_callconv) bool {
    instrument = .{ .component = .{ .vtable = &component_vtable, .owner = &instrument }, .processor = .{ .vtable = &processor_vtable, .owner = &instrument }, .instrument = true };
    effect = .{ .component = .{ .vtable = &component_vtable, .owner = &effect }, .processor = .{ .vtable = &processor_vtable, .owner = &effect }, .instrument = false };
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
