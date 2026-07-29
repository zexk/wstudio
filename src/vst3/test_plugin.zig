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

fn createInstance(_: *anyopaque, _: [*]const u8, _: [*]const u8, object: *?*anyopaque) callconv(abi.abi_callconv) abi.Result {
    object.* = null;
    return -1;
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

export fn ModuleEntry(_: ?*anyopaque) callconv(abi.abi_callconv) bool {
    return true;
}

export fn ModuleExit() callconv(abi.abi_callconv) bool {
    return true;
}

export fn InitDll() callconv(abi.abi_callconv) bool {
    return true;
}

export fn ExitDll() callconv(abi.abi_callconv) bool {
    return true;
}

export fn GetPluginFactory() callconv(abi.abi_callconv) ?*abi.PluginFactory {
    return @ptrCast(&factory);
}
