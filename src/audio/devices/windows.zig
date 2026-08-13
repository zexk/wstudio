const std = @import("std");

const c = @cImport({
    @cDefine("COBJMACROS", "1");
    @cDefine("WIDL_C_INLINE_WRAPPERS", "1");
    @cDefine("INITGUID", "1");
    @cInclude("windows.h");
    @cInclude("mmdeviceapi.h");
    @cInclude("mmsystem.h");
    @cInclude("propsys.h");
    @cInclude("functiondiscoverykeys_devpkey.h");
});

fn ok(hr: c.HRESULT) bool {
    return hr >= 0;
}

fn writeAudio(w: *std.Io.Writer, enumerator: ?*c.IMMDeviceEnumerator, flow: c.EDataFlow, label: []const u8) !void {
    try w.print("{s} (WASAPI endpoint ID):\n", .{label});
    var collection: ?*c.IMMDeviceCollection = null;
    if (!ok(c.IMMDeviceEnumerator_EnumAudioEndpoints(enumerator, flow, c.DEVICE_STATE_ACTIVE, &collection))) return;
    defer _ = c.IMMDeviceCollection_Release(collection);
    var count: c.UINT = 0;
    if (!ok(c.IMMDeviceCollection_GetCount(collection, &count))) return;
    for (0..count) |i| {
        var device: ?*c.IMMDevice = null;
        if (!ok(c.IMMDeviceCollection_Item(collection, @intCast(i), &device))) continue;
        defer _ = c.IMMDevice_Release(device);
        var id: c.LPWSTR = null;
        if (!ok(c.IMMDevice_GetId(device, &id)) or id == null) continue;
        defer c.CoTaskMemFree(id);
        var utf8: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&utf8, std.mem.span(id)) catch continue;

        var name: []const u8 = "unknown";
        var name_utf8: [512]u8 = undefined;
        var properties: ?*c.IPropertyStore = null;
        if (ok(c.IMMDevice_OpenPropertyStore(device, c.STGM_READ, &properties))) {
            defer _ = c.IPropertyStore_Release(properties);
            var value: c.PROPVARIANT = std.mem.zeroes(c.PROPVARIANT);
            defer _ = c.PropVariantClear(&value);
            if (ok(c.IPropertyStore_GetValue(properties, &c.PKEY_Device_FriendlyName, &value)) and
                value.unnamed_0.unnamed_0.vt == c.VT_LPWSTR and value.unnamed_0.unnamed_0.unnamed_0.pwszVal != null)
            {
                const name_len = std.unicode.utf16LeToUtf8(&name_utf8, std.mem.span(value.unnamed_0.unnamed_0.unnamed_0.pwszVal)) catch 0;
                if (name_len > 0) name = name_utf8[0..name_len];
            }
        }
        try w.print("  {s}\t{s}\n", .{ utf8[0..len], name });
    }
}

pub fn write(w: *std.Io.Writer) !void {
    if (!ok(c.CoInitializeEx(null, c.COINIT_MULTITHREADED))) return;
    defer c.CoUninitialize();
    var enumerator: ?*c.IMMDeviceEnumerator = null;
    if (!ok(c.CoCreateInstance(&c.CLSID_MMDeviceEnumerator, null, c.CLSCTX_ALL, &c.IID_IMMDeviceEnumerator, @ptrCast(&enumerator)))) return;
    defer _ = c.IMMDeviceEnumerator_Release(enumerator);
    try writeAudio(w, enumerator, c.eRender, "audio output devices");
    try writeAudio(w, enumerator, c.eCapture, "audio input devices");

    try w.writeAll("midi input devices (WinMM index):\n");
    for (0..c.midiInGetNumDevs()) |i| {
        var caps: c.MIDIINCAPSW = undefined;
        if (c.midiInGetDevCapsW(@intCast(i), &caps, @sizeOf(c.MIDIINCAPSW)) != c.MMSYSERR_NOERROR) continue;
        var utf8: [256]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&utf8, std.mem.sliceTo(&caps.szPname, 0)) catch continue;
        try w.print("  {d}\t{s}\n", .{ i, utf8[0..len] });
    }
}
