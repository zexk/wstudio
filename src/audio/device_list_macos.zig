const std = @import("std");

const AudioObjectPropertyAddress = extern struct { mSelector: u32, mScope: u32, mElement: u32 };
const OSStatus = i32;
const MIDIEndpointRef = u32;

const audio_hardware_property_devices = 0x64657623; // 'dev#'
const audio_object_property_scope_global = 0x676c6f62; // 'glob'
const audio_object_property_element_main = 0;
const audio_object_system_object = 1;

extern fn AudioObjectGetPropertyDataSize(u32, *const AudioObjectPropertyAddress, u32, ?*const anyopaque, *u32) callconv(.c) OSStatus;
extern fn AudioObjectGetPropertyData(u32, *const AudioObjectPropertyAddress, u32, ?*const anyopaque, *u32, *anyopaque) callconv(.c) OSStatus;
extern fn MIDIGetNumberOfSources() callconv(.c) isize;
extern fn MIDIGetSource(isize) callconv(.c) MIDIEndpointRef;

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
            for (devices[0 .. size / @sizeOf(u32)]) |device| try w.print("  {d}\n", .{device});
        }
    }

    try w.writeAll("midi input devices (CoreMIDI source index):\n");
    for (0..@intCast(@max(MIDIGetNumberOfSources(), 0))) |i| {
        if (MIDIGetSource(@intCast(i)) != 0) try w.print("  {d}\n", .{i});
    }
}
