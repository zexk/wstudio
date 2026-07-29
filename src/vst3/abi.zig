//! Minimal VST3 ABI base types. Values mirror Steinberg's generated C API at
//! revision a137a8135679e5e20fd6334a9d61f01994d6f282.

const std = @import("std");
const builtin = @import("builtin");

pub const Result = i32;
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

pub const f_unknown_iid = uid(0x00000000, 0x00000000, 0xC0000000, 0x00000046);
pub const plugin_factory_iid = uid(0x7A4D811C, 0x52114A1F, 0xAED9D2EE, 0x0B43BF9F);
pub const plugin_factory_2_iid = uid(0x0007B650, 0xF24B4C0B, 0xA464EDB9, 0xF00B2ABB);

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

comptime {
    if (@sizeOf(FUnknown) != @sizeOf(*anyopaque)) @compileError("VST3 FUnknown ABI size mismatch");
    if (@sizeOf(Tuid) != 16) @compileError("VST3 TUID ABI size mismatch");
}

test "VST3 UID uses platform ABI byte order" {
    const component = uid(0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802);
    const expected: Tuid = if (builtin.os.tag == .windows)
        .{ 0x31, 0xff, 0x31, 0xe8, 0xd5, 0xf2, 0x01, 0x43, 0x92, 0x8e, 0xbb, 0xee, 0x25, 0x69, 0x78, 0x02 }
    else
        .{ 0xe8, 0x31, 0xff, 0x31, 0xf2, 0xd5, 0x43, 0x01, 0x92, 0x8e, 0xbb, 0xee, 0x25, 0x69, 0x78, 0x02 };
    try std.testing.expectEqual(expected, component);
    try std.testing.expectEqualStrings("e831ff31f2d54301928ebbee25697802", &formatUid(component));
}
