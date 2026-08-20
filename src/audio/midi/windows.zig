//! Windows MIDI Services UMP input with WinMM fallback.

const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const midi = @import("../../midi.zig");
const Spsc = @import("../../core/ring_buffer.zig").Spsc;
const midi_velocity = @import("velocity.zig");
const VelocityCurve = midi_velocity.VelocityCurve;

const c = @cImport({
    @cInclude("windows.h");
    @cInclude("mmsystem.h");
});

const Midi2Callback = *const fn (?*anyopaque, [*]const u32, u32) callconv(.c) void;
extern fn wstudio_midi2_open([*]const u16, u32, Midi2Callback, ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wstudio_midi2_close(?*anyopaque) callconv(.c) void;

pub const MidiIn = struct {
    handle: c.HMIDIIN = null,
    midi2_handle: ?*anyopaque = null,
    engine: *Engine,
    active_track: std.atomic.Value(u16) = .init(0),
    velocity_curve: std.atomic.Value(VelocityCurve) = .init(.linear),
    dirty: std.atomic.Value(bool) = .init(false),
    /// Note-ons lost because the UI thread had not drained `note_queue`.
    /// Read and cleared by `App.serviceMidiInput`, which warns: the note was
    /// still auditioned, so silence here would mean a take quietly missing
    /// notes the player heard.
    dropped_notes: std.atomic.Value(u32) = .init(0),
    note_queue: Spsc(RecNote, 32) = .{},
    parser: midi.Parser = .{},

    pub const RecNote = struct { pitch: u7, vel: u7 };
    pub const Error = error{ NoDevices, SourceInvalid, DeviceOpenFailed, DeviceStartFailed };

    pub fn start(self: *MidiIn, source_name: []const u8) Error!void {
        const midi2_id = if (std.mem.startsWith(u8, source_name, "wms:")) source_name[4..] else null;
        if (midi2_id != null or source_name.len == 0) {
            const id = midi2_id orelse "";
            var id_utf16: [std.fs.max_path_bytes]u16 = undefined;
            const id_len = std.unicode.utf8ToUtf16Le(&id_utf16, id) catch return error.SourceInvalid;
            self.midi2_handle = wstudio_midi2_open(&id_utf16, @intCast(id_len), midi2Callback, self);
            if (self.midi2_handle != null) return;
            if (midi2_id != null) return error.DeviceOpenFailed;
        }

        const count = c.midiInGetNumDevs();
        if (count == 0) return error.NoDevices;
        const index: c.UINT = if (source_name.len == 0)
            0
        else
            std.fmt.parseInt(c.UINT, source_name, 10) catch return error.SourceInvalid;
        if (index >= count) return error.SourceInvalid;

        if (c.midiInOpen(
            &self.handle,
            index,
            @intFromPtr(&callback),
            @intFromPtr(self),
            c.CALLBACK_FUNCTION,
        ) != c.MMSYSERR_NOERROR) return error.DeviceOpenFailed;
        errdefer {
            _ = c.midiInClose(self.handle);
            self.handle = null;
        }
        if (c.midiInStart(self.handle) != c.MMSYSERR_NOERROR) return error.DeviceStartFailed;
    }

    pub fn stop(self: *MidiIn) void {
        if (self.midi2_handle) |handle| {
            wstudio_midi2_close(handle);
            self.midi2_handle = null;
        }
        if (self.handle) |handle| {
            _ = c.midiInStop(handle);
            _ = c.midiInReset(handle);
            _ = c.midiInClose(handle);
            self.handle = null;
        }
        self.parser.reset();
    }

    fn midi2Callback(context: ?*anyopaque, words: [*]const u32, word_count: u32) callconv(.c) void {
        const self: *MidiIn = @ptrCast(@alignCast(context.?));
        self.feedUmp(words[0..word_count]);
    }

    fn feedUmp(self: *MidiIn, words: []const u32) void {
        var offset: usize = 0;
        while (offset < words.len) {
            const result = midi.UmpParser.feed(words[offset..]) orelse break;
            offset += result.consumed;
            if (result.msg) |msg| midi_velocity.dispatchUmp(self, msg);
        }
    }

    fn callback(_: c.HMIDIIN, message: c.UINT, instance: c.DWORD_PTR, param1: c.DWORD_PTR, _: c.DWORD_PTR) callconv(.winapi) void {
        if (message != c.MIM_DATA) return;
        const self: *MidiIn = @ptrFromInt(instance);
        self.feedShort(@truncate(param1));
    }

    fn feedShort(self: *MidiIn, message_word: u32) void {
        const bytes = [_]u8{ @truncate(message_word), @truncate(message_word >> 8), @truncate(message_word >> 16) };
        const status = bytes[0];
        const len: usize = switch (status & 0xF0) {
            0xC0, 0xD0 => 2,
            0x80, 0x90, 0xA0, 0xB0, 0xE0 => 3,
            else => return,
        };
        const result = self.parser.feed(bytes[0..len]) orelse return;
        self.dispatch(result.msg);
    }

    fn dispatch(self: *MidiIn, msg: midi.Msg) void {
        midi_velocity.dispatch(self, msg);
    }
};

test "WinMM packed messages audition and queue notes" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var midi_in: MidiIn = .{ .engine = &engine };

    midi_in.feedShort(0x00644090);
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 64, .vel = 100 }), midi_in.note_queue.pop());
}

test "Windows MIDI Services UMP auditions and queues notes" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var midi_in: MidiIn = .{ .engine = &engine };

    midi_in.feedUmp(&.{ 0x40904000, 0xFFFF0000 });
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 64, .vel = 127 }), midi_in.note_queue.pop());
}
