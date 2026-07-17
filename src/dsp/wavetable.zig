//! Wavetable storage + lookup for the synth's `.wavetable` oscillator mode.
//! A table is a flat run of fixed-length frames; playback picks a fractional
//! frame position (`frame_pos`, 0..1) and crossfades between the two nearest
//! frames, each read with linear-interpolated phase - no band-limiting, so
//! high notes on harmonically dense tables will alias (accepted for v1, see
//! docs/ for the tradeoff).

const std = @import("std");
const types = @import("../core/types.zig");
const wav = @import("../core/wav.zig");

const Sample = types.Sample;

pub const frame_len: usize = 2048;

/// Bundled "basic shapes" table (sine/triangle/saw/square, one frame each -
/// see tools/genwavetable.zig). The oscillator's own frame_pos crossfade
/// gives the morph between them; no baked intermediate frames needed.
const default_wav = @embedFile("../assets/wavetable/basic_shapes.wav");

pub const Wavetable = struct {
    /// Flattened frame data: `frame_count * frame_len` samples.
    frames: []f32,
    frame_count: usize,
};

/// Copies `samples` into a table of `frame_len`-sample frames. Truncates a
/// trailing partial frame's worth of silence in rather than dropping data,
/// so any WAV length still produces at least one full frame.
pub fn fromSamples(allocator: std.mem.Allocator, samples: []const f32) !Wavetable {
    const complete = samples.len / frame_len;
    const frame_count = @max(1, complete + @intFromBool(samples.len % frame_len != 0));
    const total = frame_count * frame_len;
    const frames = try allocator.alloc(f32, total);
    const n = @min(total, samples.len);
    @memcpy(frames[0..n], samples[0..n]);
    if (n < total) @memset(frames[n..], 0.0);
    return .{ .frames = frames, .frame_count = frame_count };
}

/// Parses `bytes` as a WAV and reshapes it into a table - the shared path
/// for both the bundled default and a `:load-wavetable`-imported WAV.
pub fn fromWav(allocator: std.mem.Allocator, bytes: []const u8) !Wavetable {
    const result = try wav.parseAlloc(allocator, bytes);
    defer allocator.free(result.samples);
    return fromSamples(allocator, result.samples);
}

/// The bundled default table, owned by the caller like any other Wavetable.
pub fn loadDefault(allocator: std.mem.Allocator) !Wavetable {
    return fromWav(allocator, default_wav);
}

pub fn deinit(table: *Wavetable, allocator: std.mem.Allocator) void {
    allocator.free(table.frames);
}

pub fn dupe(table: Wavetable, allocator: std.mem.Allocator) !Wavetable {
    return .{ .frames = try allocator.dupe(f32, table.frames), .frame_count = table.frame_count };
}

/// Reads `table` at fractional frame position `frame_pos` (0..1, clamped)
/// and phase `phase` (wrapped to 0..1), bilinearly interpolating across
/// both frame and sample axes.
pub fn lookup(table: Wavetable, frame_pos: f32, phase: f32) Sample {
    if (table.frame_count == 0 or table.frames.len < table.frame_count *| frame_len) return 0.0;
    const safe_frame_pos = if (std.math.isFinite(frame_pos)) frame_pos else 0.0;
    const safe_phase = if (std.math.isFinite(phase)) phase else 0.0;
    const fc: f32 = @floatFromInt(table.frame_count - 1);
    const fp = std.math.clamp(safe_frame_pos, 0.0, 1.0) * fc;
    const f0: usize = @intFromFloat(@floor(fp));
    const f1: usize = @min(f0 + 1, table.frame_count - 1);
    const frac_f = fp - @floor(fp);

    const ph = safe_phase - @floor(safe_phase);
    const sp = ph * @as(f32, @floatFromInt(frame_len));
    const s0: usize = @intFromFloat(@floor(sp));
    const s1: usize = (s0 + 1) % frame_len;
    const frac_s = sp - @floor(sp);

    const a0 = table.frames[f0 * frame_len + s0];
    const a1 = table.frames[f0 * frame_len + s1];
    const va = a0 + (a1 - a0) * frac_s;

    const b0 = table.frames[f1 * frame_len + s0];
    const b1 = table.frames[f1 * frame_len + s1];
    const vb = b0 + (b1 - b0) * frac_s;

    return va + (vb - va) * frac_f;
}

test "lookup: single-frame table matches a plain sine read" {
    const allocator = std.testing.allocator;
    var frame: [frame_len]f32 = undefined;
    for (&frame, 0..) |*s, i| {
        s.* = @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frame_len)));
    }
    var table = try fromSamples(allocator, &frame);
    defer deinit(&table, allocator);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lookup(table, 0.0, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lookup(table, 0.5, 0.25), 0.01);
    // frame_pos is irrelevant with only one frame.
    try std.testing.expectApproxEqAbs(lookup(table, 0.0, 0.25), lookup(table, 1.0, 0.25), 0.0001);
}

test "lookup: frame_pos crossfades between distinct frames" {
    const allocator = std.testing.allocator;
    var samples: [frame_len * 2]f32 = undefined;
    @memset(samples[0..frame_len], -1.0);
    @memset(samples[frame_len..], 1.0);
    var table = try fromSamples(allocator, &samples);
    defer deinit(&table, allocator);

    try std.testing.expectApproxEqAbs(@as(f32, -1.0), lookup(table, 0.0, 0.1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lookup(table, 1.0, 0.1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lookup(table, 0.5, 0.1), 0.0001);
}

test "fromSamples pads a trailing partial frame instead of dropping it" {
    const allocator = std.testing.allocator;
    var samples = [_]f32{0.0} ** (frame_len + 1);
    samples[frame_len] = 0.75;
    var table = try fromSamples(allocator, &samples);
    defer deinit(&table, allocator);

    try std.testing.expectEqual(@as(usize, 2), table.frame_count);
    try std.testing.expectEqual(@as(f32, 0.75), table.frames[frame_len]);
    for (table.frames[frame_len + 1 ..]) |sample| try std.testing.expectEqual(@as(f32, 0.0), sample);
}

test "loadDefault: bundled basic-shapes table has 4 frames" {
    const allocator = std.testing.allocator;
    var table = try loadDefault(allocator);
    defer deinit(&table, allocator);
    try std.testing.expectEqual(@as(usize, 4), table.frame_count);
}

test "dupe: independent buffer, same content" {
    const allocator = std.testing.allocator;
    var table = try loadDefault(allocator);
    defer deinit(&table, allocator);
    table.frames[0] = 0.5;

    var copy = try dupe(table, allocator);
    defer deinit(&copy, allocator);
    try std.testing.expectEqual(@as(f32, 0.5), copy.frames[0]);

    copy.frames[0] = -0.5;
    try std.testing.expectEqual(@as(f32, 0.5), table.frames[0]);
}

test "lookup handles invalid coordinates and malformed tables safely" {
    var empty_frames: [0]f32 = .{};
    const empty = Wavetable{ .frames = &empty_frames, .frame_count = 0 };
    try std.testing.expectEqual(@as(f32, 0.0), lookup(empty, 0.0, 0.0));

    var short_frames = [_]f32{0.5};
    const short = Wavetable{ .frames = &short_frames, .frame_count = 1 };
    try std.testing.expectEqual(@as(f32, 0.0), lookup(short, 0.0, 0.0));

    var table = try fromSamples(std.testing.allocator, &.{0.25});
    defer deinit(&table, std.testing.allocator);
    try std.testing.expectEqual(lookup(table, 0.0, 0.0), lookup(table, std.math.nan(f32), std.math.inf(f32)));
}
