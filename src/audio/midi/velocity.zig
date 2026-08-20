//! MIDI note-on velocity -> gain mapping, plus the engine dispatch the
//! platform MIDI backends share. Split out from audio/midi/linux.zig (Linux/ALSA-only)
//! so `wstudio.o.default_midi_velocity_curve` has a type that compiles on
//! every platform, same reason `audio_host.Choice` lives in host.zig rather
//! than inside a backend-specific file.

const std = @import("std");
const midi = @import("../../midi.zig");

pub const VelocityCurve = enum(u8) { linear, exponential, fixed };

/// `raw` is the 0-127 MIDI velocity byte.
pub fn apply(curve: VelocityCurve, raw: u7) f32 {
    const t = @as(f32, @floatFromInt(raw)) / 127.0;
    return switch (curve) {
        .linear => t,
        // Softer touches read quieter than linear; hard hits still reach 1.0.
        .exponential => t * t,
        // Every hit lands at full velocity - consistent triggering
        // regardless of how hard a pad/key was struck.
        .fixed => 1.0,
    };
}

pub fn apply16(curve: VelocityCurve, raw: u16) f32 {
    const t = @as(f32, @floatFromInt(raw)) / 65535.0;
    return switch (curve) {
        .linear => t,
        .exponential => t * t,
        .fixed => 1.0,
    };
}

pub fn scale16To7(value: u16) u7 {
    return @intCast((@as(u32, value) * 127 + 32767) / 65535);
}

test "linear passes velocity through unchanged" {
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 / 127.0), apply(.linear, 100), 0.0001);
}

test "exponential attenuates soft hits more than linear" {
    const soft: u7 = 40;
    try std.testing.expect(apply(.exponential, soft) < apply(.linear, soft));
}

test "fixed always returns full velocity" {
    try std.testing.expectEqual(@as(f32, 1.0), apply(.fixed, 1));
    try std.testing.expectEqual(@as(f32, 1.0), apply(.fixed, 127));
}

test "max velocity reaches 1.0 under every curve" {
    inline for (std.meta.tags(VelocityCurve)) |curve| {
        try std.testing.expectEqual(@as(f32, 1.0), apply(curve, 127));
    }
}

/// Forward one parsed channel message into the engine on the caller's active
/// track. Shared by the CoreMIDI and WinMM backends, whose `MidiIn` structs
/// are identical from here down (the ALSA sequencer backend decodes its own
/// event type instead and keeps its own version).
pub fn dispatch(self: anytype, msg: midi.Msg) void {
    const track = self.active_track.load(.monotonic);
    switch (msg) {
        .note_on => |note| {
            _ = self.engine.sendMidi(.{ .note_on = .{
                .track = track,
                .note = note.note,
                .velocity = apply(self.velocity_curve.load(.monotonic), note.velocity),
            } });
            if (!self.note_queue.push(.{ .pitch = note.note, .vel = note.velocity }))
                _ = self.dropped_notes.fetchAdd(1, .monotonic);
        },
        .note_off => |note| _ = self.engine.sendMidi(.{ .note_off = .{ .track = track, .note = note.note } }),
        .control_change => |cc| {
            if (self.engine.sendMidi(.{ .cc = .{ .track = track, .cc = cc.cc, .value = cc.value } }))
                self.dirty.store(true, .release);
        },
        .pitch_bend => |bend| _ = self.engine.sendMidi(.{ .pitch_bend = .{ .track = track, .bend = bend.bend } }),
        .channel_pressure => |pressure| _ = self.engine.sendMidi(.{ .channel_pressure = .{
            .track = track,
            .value = @as(f32, @floatFromInt(pressure.pressure)) / 127.0,
        } }),
        .poly_aftertouch => |pressure| _ = self.engine.sendMidi(.{ .poly_pressure = .{
            .track = track,
            .note = pressure.note,
            .value = @as(f32, @floatFromInt(pressure.velocity)) / 127.0,
        } }),
        else => {},
    }
}

pub fn dispatchUmp(self: anytype, msg: midi.UmpMsg) void {
    const track = self.active_track.load(.monotonic);
    switch (msg) {
        .midi1 => |legacy| dispatch(self, legacy),
        .note_on => |note| {
            _ = self.engine.sendMidi(.{ .note_on = .{
                .track = track,
                .note = note.note,
                .velocity = apply16(self.velocity_curve.load(.monotonic), note.velocity),
            } });
            const velocity = scale16To7(note.velocity);
            if (!self.note_queue.push(.{ .pitch = note.note, .vel = velocity }))
                _ = self.dropped_notes.fetchAdd(1, .monotonic);
        },
        .note_off => |note| _ = self.engine.sendMidi(.{ .note_off = .{ .track = track, .note = note.note } }),
        .control_change => |cc| {
            if (self.engine.sendMidi(.{ .midi2_cc = .{ .track = track, .cc = cc.index, .data = cc.data } }))
                self.dirty.store(true, .release);
        },
        .pitch_bend => |bend| _ = self.engine.sendMidi(.{ .midi2_pitch_bend = .{ .track = track, .data = bend.data } }),
        .per_note_pitch_bend => |bend| _ = self.engine.sendMidi(.{ .midi2_per_note_pitch_bend = .{
            .track = track,
            .note = bend.note,
            .data = bend.data,
        } }),
        .channel_pressure => |pressure| _ = self.engine.sendMidi(.{ .channel_pressure = .{
            .track = track,
            .value = @as(f32, @floatFromInt(pressure.data)) / 4294967295.0,
        } }),
        .poly_aftertouch => |pressure| _ = self.engine.sendMidi(.{ .poly_pressure = .{
            .track = track,
            .note = pressure.note,
            .value = @as(f32, @floatFromInt(pressure.data)) / 4294967295.0,
        } }),
        else => {},
    }
}

test "MIDI 2.0 velocity scaling preserves endpoints" {
    try std.testing.expectEqual(@as(f32, 0.0), apply16(.linear, 0));
    try std.testing.expectEqual(@as(f32, 1.0), apply16(.linear, 65535));
    try std.testing.expectEqual(@as(u7, 0), scale16To7(0));
    try std.testing.expectEqual(@as(u7, 127), scale16To7(65535));
    try std.testing.expectEqual(@as(u7, 64), scale16To7(32768));
}
