const std = @import("std");

const AudioObjectPropertyAddress = extern struct { mSelector: u32, mScope: u32, mElement: u32 };
const OSStatus = i32;
const MIDIEndpointRef = u32;
const CFStringRef = ?*const anyopaque;

const audio_hardware_property_devices = 0x64657623; // 'dev#'
const audio_object_property_name = 0x6c6e616d; // 'lnam'
const audio_device_property_streams = 0x73746d23; // 'stm#'
const audio_object_property_scope_global = 0x676c6f62; // 'glob'
const audio_object_property_scope_input = 0x696e7074; // 'inpt'
const audio_object_property_scope_output = 0x6f757470; // 'outp'
const audio_object_property_element_main = 0;
const audio_object_system_object = 1;
const utf8_encoding = 0x08000100;

extern fn AudioObjectGetPropertyDataSize(u32, *const AudioObjectPropertyAddress, u32, ?*const anyopaque, *u32) callconv(.c) OSStatus;
extern fn AudioObjectGetPropertyData(u32, *const AudioObjectPropertyAddress, u32, ?*const anyopaque, *u32, *anyopaque) callconv(.c) OSStatus;
extern fn CFStringGetCString(CFStringRef, [*]u8, isize, u32) callconv(.c) u8;
extern fn CFRelease(CFStringRef) callconv(.c) void;
extern fn MIDIGetNumberOfSources() callconv(.c) isize;
extern fn MIDIGetSource(isize) callconv(.c) MIDIEndpointRef;
extern fn MIDIObjectGetStringProperty(u32, CFStringRef, *CFStringRef) callconv(.c) OSStatus;
extern var kMIDIPropertyDisplayName: CFStringRef;

fn objectName(object: u32, property: ?CFStringRef, buf: []u8) ?[]const u8 {
    var name: CFStringRef = null;
    if (property) |key| {
        if (MIDIObjectGetStringProperty(object, key, &name) != 0) return null;
    } else {
        const address = AudioObjectPropertyAddress{
            .mSelector = audio_object_property_name,
            .mScope = audio_object_property_scope_global,
            .mElement = audio_object_property_element_main,
        };
        var size: u32 = @sizeOf(CFStringRef);
        if (AudioObjectGetPropertyData(object, &address, 0, null, &size, &name) != 0) return null;
    }
    defer CFRelease(name);
    if (CFStringGetCString(name, buf.ptr, @intCast(buf.len), utf8_encoding) == 0) return null;
    return std.mem.sliceTo(buf, 0);
}

fn hasStreams(device: u32, scope: u32) bool {
    const address = AudioObjectPropertyAddress{
        .mSelector = audio_device_property_streams,
        .mScope = scope,
        .mElement = audio_object_property_element_main,
    };
    var size: u32 = 0;
    return AudioObjectGetPropertyDataSize(device, &address, 0, null, &size) == 0 and size > 0;
}

pub fn write(w: *std.Io.Writer) !void {
    try w.writeAll("audio devices (Core Audio AudioDeviceID):\n");
    const address = AudioObjectPropertyAddress{
        .mSelector = audio_hardware_property_devices,
        .mScope = audio_object_property_scope_global,
        .mElement = audio_object_property_element_main,
    };
    var size: u32 = 0;
    if (AudioObjectGetPropertyDataSize(audio_object_system_object, &address, 0, null, &size) == 0) {
        var devices: [256]u32 = undefined;
        size = @min(size, @sizeOf(@TypeOf(devices)));
        if (AudioObjectGetPropertyData(audio_object_system_object, &address, 0, null, &size, &devices) == 0) {
            for (devices[0 .. size / @sizeOf(u32)]) |device| {
                var name_buf: [256]u8 = undefined;
                const name = objectName(device, null, &name_buf) orelse "unknown";
                const input = hasStreams(device, audio_object_property_scope_input);
                const output = hasStreams(device, audio_object_property_scope_output);
                const direction = if (input and output) "input/output" else if (input) "input" else if (output) "output" else "unknown";
                try w.print("  {d}\t{s}\t{s}\n", .{ device, name, direction });
            }
        }
    }

    try w.writeAll("midi input devices (CoreMIDI source index):\n");
    for (0..@intCast(@max(MIDIGetNumberOfSources(), 0))) |i| {
        const source = MIDIGetSource(@intCast(i));
        if (source == 0) continue;
        var name_buf: [256]u8 = undefined;
        const name = objectName(source, kMIDIPropertyDisplayName, &name_buf) orelse "unknown";
        try w.print("  {d}\t{s}\n", .{ i, name });
    }
}
