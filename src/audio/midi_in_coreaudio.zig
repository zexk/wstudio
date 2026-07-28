//! CoreMIDI input. Connects every current system MIDI source to one input
//! port and forwards channel messages into the engine.

const std = @import("std");
const Engine = @import("engine.zig").Engine;
const midi = @import("../midi.zig");
const Spsc = @import("../core/ring_buffer.zig").Spsc;
const midi_velocity = @import("midi_velocity.zig");
const VelocityCurve = midi_velocity.VelocityCurve;

const OSStatus = i32;
const MIDIClientRef = u32;
const MIDIPortRef = u32;
const MIDIEndpointRef = u32;
const CFStringRef = ?*const anyopaque;

const MIDIPacket = extern struct {
    time_stamp: u64,
    length: u16,
    data: [256]u8,
};

const MIDIPacketList = extern struct {
    num_packets: u32,
    packet: [1]MIDIPacket,
};

const MIDIReadProc = *const fn (*const MIDIPacketList, ?*anyopaque, ?*anyopaque) callconv(.c) void;

extern fn CFStringCreateWithCString(?*const anyopaque, [*:0]const u8, u32) callconv(.c) CFStringRef;
extern fn CFRelease(CFStringRef) callconv(.c) void;
extern fn MIDIClientCreate(CFStringRef, ?*const anyopaque, ?*anyopaque, *MIDIClientRef) callconv(.c) OSStatus;
extern fn MIDIClientDispose(MIDIClientRef) callconv(.c) OSStatus;
extern fn MIDIInputPortCreate(MIDIClientRef, CFStringRef, MIDIReadProc, ?*anyopaque, *MIDIPortRef) callconv(.c) OSStatus;
extern fn MIDIPortDispose(MIDIPortRef) callconv(.c) OSStatus;
extern fn MIDIPortConnectSource(MIDIPortRef, MIDIEndpointRef, ?*anyopaque) callconv(.c) OSStatus;
extern fn MIDIGetNumberOfSources() callconv(.c) isize;
extern fn MIDIGetSource(isize) callconv(.c) MIDIEndpointRef;

const utf8_encoding = 0x08000100;

pub const MidiIn = struct {
    client: MIDIClientRef = 0,
    port: MIDIPortRef = 0,
    engine: *Engine,
    active_track: std.atomic.Value(u16) = .init(0),
    velocity_curve: std.atomic.Value(VelocityCurve) = .init(.linear),
    dirty: std.atomic.Value(bool) = .init(false),
    note_queue: Spsc(RecNote, 32) = .{},
    parser: midi.Parser = .{},

    pub const RecNote = struct { pitch: u7, vel: u7 };
    pub const Error = error{ ClientCreateFailed, PortCreateFailed };

    pub fn start(self: *MidiIn) Error!void {
        const name = CFStringCreateWithCString(null, "wstudio", utf8_encoding) orelse return error.ClientCreateFailed;
        defer CFRelease(name);

        if (MIDIClientCreate(name, null, null, &self.client) != 0) return error.ClientCreateFailed;
        errdefer {
            _ = MIDIClientDispose(self.client);
            self.client = 0;
        }
        if (MIDIInputPortCreate(self.client, name, read, self, &self.port) != 0) return error.PortCreateFailed;

        for (0..@intCast(@max(MIDIGetNumberOfSources(), 0))) |i| {
            const source = MIDIGetSource(@intCast(i));
            if (source != 0) _ = MIDIPortConnectSource(self.port, source, null);
        }
    }

    pub fn stop(self: *MidiIn) void {
        if (self.port != 0) {
            _ = MIDIPortDispose(self.port);
            self.port = 0;
        }
        if (self.client != 0) {
            _ = MIDIClientDispose(self.client);
            self.client = 0;
        }
        self.parser.reset();
    }

    fn read(packet_list: *const MIDIPacketList, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const self: *MidiIn = @ptrCast(@alignCast(context.?));
        var packet = &packet_list.packet[0];
        for (0..packet_list.num_packets) |_| {
            self.feed(packet.data[0..packet.length]);
            const next = std.mem.alignForward(usize, @intFromPtr(&packet.data) + packet.length, 4);
            packet = @ptrFromInt(next);
        }
    }

    fn feed(self: *MidiIn, bytes: []const u8) void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = self.parser.feed(bytes[offset..]) orelse break;
            offset += result.consumed;
            self.dispatch(result.msg);
        }
    }

    fn dispatch(self: *MidiIn, msg: midi.Msg) void {
        const track = self.active_track.load(.monotonic);
        switch (msg) {
            .note_on => |note| {
                _ = self.engine.send(.{ .note_on = .{
                    .track = track,
                    .note = note.note,
                    .velocity = midi_velocity.apply(self.velocity_curve.load(.monotonic), note.velocity),
                } });
                _ = self.note_queue.push(.{ .pitch = note.note, .vel = note.velocity });
            },
            .note_off => |note| _ = self.engine.send(.{ .note_off = .{ .track = track, .note = note.note } }),
            .control_change => |cc| {
                if (self.engine.send(.{ .cc = .{ .track = track, .cc = cc.cc, .value = cc.value } }))
                    self.dirty.store(true, .release);
            },
            .pitch_bend => |bend| _ = self.engine.send(.{ .pitch_bend = .{ .track = track, .bend = bend.bend } }),
            else => {},
        }
    }
};

test "CoreMIDI packet bytes audition and queue notes" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var midi_in: MidiIn = .{ .engine = &engine };

    midi_in.feed(&.{ 0x90, 64, 100, 65, 80 });
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 64, .vel = 100 }), midi_in.note_queue.pop());
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 65, .vel = 80 }), midi_in.note_queue.pop());
}
