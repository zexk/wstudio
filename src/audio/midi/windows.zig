//! WinMM live MIDI input. Opens one configured device index and forwards
//! packed short messages into the engine from the system callback.

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

pub const MidiIn = struct {
    handle: c.HMIDIIN = null,
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
        if (self.handle) |handle| {
            _ = c.midiInStop(handle);
            _ = c.midiInReset(handle);
            _ = c.midiInClose(handle);
            self.handle = null;
        }
        self.parser.reset();
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
