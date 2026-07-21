//! Render fixed test clips through the WSOLA time-stretch (`Pad.stretch_ratio`)
//! at a handful of settings, to WAV, for a manual listening pass - stretch
//! quality (phasiness on tonal sustain, grain-boundary clicks, transient
//! smearing on percussive material) can't be meaningfully unit-tested, only
//! heard. Not part of the automated test suite; run on demand.
//!
//! Run with `zig build stretch-demo`. Writes to zig-out/stretch-demo/ (not
//! committed - see .gitignore).

const std = @import("std");
const ws = @import("wstudio");

const sample_rate: u32 = 48_000;
const out_dir = "zig-out/stretch-demo";

/// A sustained, near-undamped tone (long release) - the case WSOLA search
/// most needs to get right, since a plain fixed-hop overlap-add would phase
/// audibly on exactly this kind of steady tonal content.
fn sustainedTone(allocator: std.mem.Allocator) ![]f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const len: usize = @intFromFloat(sr * 1.0);
    const out = try allocator.alloc(f32, len);
    const freq: f32 = 220.0; // A3
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const env = @min(1.0, t / 0.01) * @min(1.0, (sr * 1.0 - @as(f32, @floatFromInt(i))) / (sr * 0.05));
        s.* = env * (0.7 * @sin(2.0 * std.math.pi * freq * t) + 0.3 * @sin(2.0 * std.math.pi * freq * 2.0 * t));
    }
    return out;
}

/// A plucked/decaying note - fast attack, exponential decay. Stretching this
/// tests whether the decay shape survives grain reordering intact.
fn pluckedNote(allocator: std.mem.Allocator) ![]f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const len: usize = @intFromFloat(sr * 0.8);
    const out = try allocator.alloc(f32, len);
    const freq: f32 = 329.63; // E4
    const tau: f32 = 0.25;
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const env = @exp(-t / tau);
        s.* = env * (0.8 * @sin(2.0 * std.math.pi * freq * t) + 0.2 * @sin(2.0 * std.math.pi * freq * 3.0 * t));
    }
    return out;
}

/// A percussive hit - broadband noise burst, very fast decay. The known
/// weaker case: transients don't have the periodicity WSOLA's search aligns
/// on, so some smearing here is an expected limitation, not a bug to chase.
fn percussiveHit(allocator: std.mem.Allocator) ![]f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const len: usize = @intFromFloat(sr * 0.3);
    const out = try allocator.alloc(f32, len);
    const tau: f32 = 0.04;
    var prng = std.Random.DefaultPrng.init(1234);
    const rand = prng.random();
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        const env = @exp(-t / tau);
        s.* = env * (rand.float(f32) * 2.0 - 1.0);
    }
    return out;
}

const Case = struct { name: []const u8, pitch_semitones: f32, stretch_ratio: f32 };
const cases = [_]Case{
    .{ .name = "stretch_0.50x", .pitch_semitones = 0, .stretch_ratio = 0.5 },
    .{ .name = "stretch_0.75x", .pitch_semitones = 0, .stretch_ratio = 0.75 },
    .{ .name = "stretch_1.50x", .pitch_semitones = 0, .stretch_ratio = 1.5 },
    .{ .name = "stretch_2.00x", .pitch_semitones = 0, .stretch_ratio = 2.0 },
    // Duration-preserving +1 octave: stretch_ratio matches the rate the
    // pitch shift implies (2^(12/12) = 2.0), canceling the tied speed
    // change - see the `Pad.stretch_ratio` doc comment.
    .{ .name = "pitch_cancel_+12st", .pitch_semitones = 12, .stretch_ratio = 2.0 },
};

fn renderCase(allocator: std.mem.Allocator, clip: []const f32, case: Case, out: *std.ArrayList(f32)) !void {
    var s = try ws.dsp.Sampler.init(allocator, sample_rate);
    defer s.deinit();
    s.setSamples(try allocator.dupe(f32, clip), "demo");
    s.pad.pitch_semitones = case.pitch_semitones;
    s.pad.stretch_ratio = case.stretch_ratio;
    s.trigger(60, 1.0, 0);

    out.clearRetainingCapacity();
    var buf: [512]ws.types.Sample = undefined;
    var n: usize = 0;
    while (s.voices[0].active and n < 20_000) : (n += 1) {
        @memset(&buf, 0.0);
        s.processBlock(&buf);
        var i: usize = 0;
        while (i < 256) : (i += 1) try out.append(allocator, buf[i * 2]);
    }
}

fn writeWav(io: std.Io, dir: std.Io.Dir, name: []const u8, samples: []const f32) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var fbuf: [8192]u8 = undefined;
    var fw = file.writer(io, &fbuf);
    try ws.wav.write(&fw.interface, sample_rate, 1, samples, .pcm16);
    try fw.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;

    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, out_dir, .{});
    defer dir.close(io);

    const clips = [_]struct { name: []const u8, gen: *const fn (std.mem.Allocator) anyerror![]f32 }{
        .{ .name = "sustained", .gen = &sustainedTone },
        .{ .name = "plucked", .gen = &pluckedNote },
        .{ .name = "percussive", .gen = &percussiveHit },
    };

    var out_buf: std.ArrayList(f32) = .empty;
    defer out_buf.deinit(gpa);

    for (clips) |clip_spec| {
        const clip = try clip_spec.gen(gpa);
        defer gpa.free(clip);
        for (cases) |case| {
            try renderCase(gpa, clip, case, &out_buf);
            var name_buf: [128]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}_{s}.wav", .{ clip_spec.name, case.name });
            try writeWav(io, dir, name, out_buf.items);
            try stdout.print("wrote {s}/{s} ({d} frames)\n", .{ out_dir, name, out_buf.items.len });
        }
    }
    try stdout.flush();
}
