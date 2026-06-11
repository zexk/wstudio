//! Transport: playhead position, tempo, and musical time.
//!
//! Owned and mutated exclusively by the audio thread; control threads
//! change it by sending engine commands.

const std = @import("std");

pub const TimeSignature = struct {
    beats_per_bar: u8 = 4,
    beat_unit: u8 = 4,
};

pub const Transport = struct {
    sample_rate: u32,
    tempo_bpm: f64 = 120.0,
    time_signature: TimeSignature = .{},
    playing: bool = false,
    /// Absolute position in frames since project start.
    position_frames: u64 = 0,

    pub fn framesPerBeat(self: *const Transport) f64 {
        return @as(f64, @floatFromInt(self.sample_rate)) * 60.0 / self.tempo_bpm;
    }

    pub fn positionBeats(self: *const Transport) f64 {
        return @as(f64, @floatFromInt(self.position_frames)) / self.framesPerBeat();
    }

    pub fn positionSeconds(self: *const Transport) f64 {
        return @as(f64, @floatFromInt(self.position_frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Bar/beat as shown in a position display (zero-based).
    pub fn positionBarBeat(self: *const Transport) struct { bar: u64, beat: u64 } {
        const total_beats: u64 = @intFromFloat(self.positionBeats());
        const bpb: u64 = self.time_signature.beats_per_bar;
        return .{ .bar = total_beats / bpb, .beat = total_beats % bpb };
    }

    /// Called once per processed block, after rendering it.
    pub fn advance(self: *Transport, frames: u32) void {
        if (self.playing) self.position_frames += frames;
    }

    pub fn play(self: *Transport) void {
        self.playing = true;
    }

    pub fn stop(self: *Transport) void {
        self.playing = false;
    }

    pub fn seekFrames(self: *Transport, frames: u64) void {
        self.position_frames = frames;
    }
};

test "advance only moves while playing" {
    var t: Transport = .{ .sample_rate = 48_000 };
    t.advance(256);
    try std.testing.expectEqual(@as(u64, 0), t.position_frames);
    t.play();
    t.advance(256);
    try std.testing.expectEqual(@as(u64, 256), t.position_frames);
    t.stop();
    t.advance(256);
    try std.testing.expectEqual(@as(u64, 256), t.position_frames);
}

test "musical time at 120 bpm" {
    var t: Transport = .{ .sample_rate = 48_000 };
    t.play();
    // 120 bpm => 0.5 s/beat => 24_000 frames/beat
    try std.testing.expectApproxEqAbs(@as(f64, 24_000.0), t.framesPerBeat(), 1e-9);
    t.seekFrames(24_000 * 6); // 6 beats = bar 1, beat 2 in 4/4
    const pos = t.positionBarBeat();
    try std.testing.expectEqual(@as(u64, 1), pos.bar);
    try std.testing.expectEqual(@as(u64, 2), pos.beat);
}
