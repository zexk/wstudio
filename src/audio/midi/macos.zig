//! CoreMIDI input. Connects a configured source index, or every current
//! source when unset, and forwards channel messages into the engine.

const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const midi = @import("../../midi.zig");
const Spsc = @import("../../core/ring_buffer.zig").Spsc;
const midi_velocity = @import("velocity.zig");
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
extern fn wstudio_midi_ump_input_port_create(MIDIClientRef, CFStringRef, *const fn ([*]const u32, u32, ?*anyopaque) callconv(.c) void, ?*anyopaque, *MIDIPortRef) callconv(.c) OSStatus;
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
    /// Note-ons lost because the UI thread had not drained `note_queue`.
    /// Read and cleared by `App.serviceMidiInput`, which warns: the note was
    /// still auditioned, so silence here would mean a take quietly missing
    /// notes the player heard.
    dropped_notes: std.atomic.Value(u32) = .init(0),
    note_queue: Spsc(RecNote, 32) = .{},
    parser: midi.Parser = .{},

    pub const RecNote = struct { pitch: u7, vel: u7 };
    pub const Error = error{ ClientCreateFailed, PortCreateFailed, SourceInvalid, SourceConnectFailed };

    pub fn start(self: *MidiIn, source_name: []const u8) Error!void {
        const name = CFStringCreateWithCString(null, "wstudio", utf8_encoding) orelse return error.ClientCreateFailed;
        defer CFRelease(name);

        if (MIDIClientCreate(name, null, null, &self.client) != 0) return error.ClientCreateFailed;
        errdefer {
            _ = MIDIClientDispose(self.client);
            self.client = 0;
        }
        if (wstudio_midi_ump_input_port_create(self.client, name, readUmp, self, &self.port) != 0 and
            MIDIInputPortCreate(self.client, name, read, self, &self.port) != 0) return error.PortCreateFailed;

        const count: usize = @intCast(@max(MIDIGetNumberOfSources(), 0));
        if (source_name.len > 0) {
            const index = std.fmt.parseInt(usize, source_name, 10) catch return error.SourceInvalid;
            if (index >= count) return error.SourceInvalid;
            const source = MIDIGetSource(@intCast(index));
            if (source == 0 or MIDIPortConnectSource(self.port, source, null) != 0) return error.SourceConnectFailed;
        } else {
            for (0..count) |i| {
                const source = MIDIGetSource(@intCast(i));
                if (source != 0) _ = MIDIPortConnectSource(self.port, source, null);
            }
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
            const result = self.parser.feed(bytes[offset..]) orelse {
                var next = offset + 1;
                while (next < bytes.len and bytes[next] & 0x80 == 0) next += 1;
                if (next == bytes.len) break;
                offset = next;
                continue;
            };
            offset += result.consumed;
            self.dispatch(result.msg);
        }
    }

    fn readUmp(words: [*]const u32, word_count: u32, context: ?*anyopaque) callconv(.c) void {
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

    fn dispatch(self: *MidiIn, msg: midi.Msg) void {
        midi_velocity.dispatch(self, msg);
    }
};

/// Heap-allocated, not returned by value: `Engine` is over 1 MiB (mostly
/// `max_tracks`-scaled meter arrays), and a by-value local blows macOS's
/// default thread stack - see `[[reference_wstudio_gotchas]]`.
fn testEngine() !*Engine {
    const engine = try std.testing.allocator.create(Engine);
    errdefer std.testing.allocator.destroy(engine);
    engine.* = try Engine.init(std.testing.allocator, 48_000);
    return engine;
}

fn destroyTestEngine(engine: *Engine) void {
    engine.deinit();
    std.testing.allocator.destroy(engine);
}

test "CoreMIDI packet bytes audition and queue notes" {
    const engine = try testEngine();
    defer destroyTestEngine(engine);
    var midi_in: MidiIn = .{ .engine = engine };

    midi_in.feed(&.{ 0x90, 64, 100, 65, 80 });
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 64, .vel = 100 }), midi_in.note_queue.pop());
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 65, .vel = 80 }), midi_in.note_queue.pop());
}

test "CoreMIDI packet keeps channel messages after unsupported system common" {
    const engine = try testEngine();
    defer destroyTestEngine(engine);
    var midi_in: MidiIn = .{ .engine = engine };

    midi_in.feed(&.{ 0xF1, 0, 0x90, 64, 100 });
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 64, .vel = 100 }), midi_in.note_queue.pop());
}

test "CoreMIDI UMP packet preserves MIDI 2.0 velocity" {
    const engine = try testEngine();
    defer destroyTestEngine(engine);
    var midi_in: MidiIn = .{ .engine = engine };

    midi_in.feedUmp(&.{ 0x40904000, 0x80000000 });
    try std.testing.expectEqual(@as(?MidiIn.RecNote, .{ .pitch = 64, .vel = 64 }), midi_in.note_queue.pop());
}
