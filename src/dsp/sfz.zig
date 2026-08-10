//! Bounded SFZ reader. It resolves SFZ global/group/region inheritance and
//! external WAV samples into the same flat sample bank used by SF2 playback.
//! Unsupported performance features fail or collapse explicitly instead of
//! claiming full SFZ compatibility.

const std = @import("std");
const pad_dsp = @import("pad.zig");
const flac = @import("../core/flac.zig");
const wav = @import("../core/wav.zig");
const sample_bank = @import("soundfont.zig");

const Region = sample_bank.Region;
const Preset = sample_bank.Preset;
const SampleBank = sample_bank.SampleBank;

pub const ParseError = error{
    Empty,
    Malformed,
    MissingSample,
    UnsupportedOpcode,
    UnsupportedSampleFormat,
    InvalidValue,
    InvalidPath,
    SampleTooLarge,
    OutputTooLarge,
};

const Settings = struct {
    sample: ?[]const u8 = null,
    trigger_release: bool = false,
    key_lo: u8 = 0,
    key_hi: u8 = 127,
    vel_lo: u8 = 0,
    vel_hi: u8 = 127,
    root_key: u8 = 60,
    scale_tuning_cents: f32 = 100,
    tune_cents: f32 = 0,
    volume_db: f32 = 0,
    offset: u32 = 0,
    attack_s: f32 = 0,
    decay_s: f32 = 0,
    sustain: f32 = 1,
    release_s: f32 = 0.1,
    seq_position: u16 = 1,
    cc64_lo: u8 = 0,
    cc64_hi: u8 = 127,
};

pub fn parse(
    allocator: std.mem.Allocator,
    io: std.Io,
    sample_dir: std.Io.Dir,
    text: []const u8,
    name: []const u8,
    target_sample_rate: u32,
) !SampleBank {
    var samples: std.ArrayListUnmanaged(f32) = .empty;
    errdefer samples.deinit(allocator);
    var regions: std.ArrayListUnmanaged(Region) = .empty;
    errdefer regions.deinit(allocator);

    var global: Settings = .{};
    var group = global;
    var current: ?Settings = null;
    var section: enum { none, global, group, region } = .none;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const before_comment = if (std.mem.indexOf(u8, raw_line, "//")) |i| raw_line[0..i] else raw_line;
        const line = std.mem.trim(u8, before_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '<') {
            if (current) |r| try appendRegion(allocator, io, sample_dir, target_sample_rate, r, &samples, &regions);
            current = null;
            if (std.mem.eql(u8, line, "<global>")) {
                section = .global;
                global = .{};
                group = global;
            } else if (std.mem.eql(u8, line, "<group>")) {
                section = .group;
                group = global;
            } else if (std.mem.eql(u8, line, "<region>")) {
                section = .region;
                current = group;
            } else return error.UnsupportedOpcode;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Malformed;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.Malformed;
        switch (section) {
            .global => try apply(&global, key, value),
            .group => try apply(&group, key, value),
            .region => try apply(&(current orelse return error.Malformed), key, value),
            .none => return error.Malformed,
        }
    }
    if (current) |r| try appendRegion(allocator, io, sample_dir, target_sample_rate, r, &samples, &regions);
    if (regions.items.len == 0) return error.Empty;

    var fixed_name = [_]u8{0} ** 20;
    @memcpy(fixed_name[0..@min(name.len, fixed_name.len)], name[0..@min(name.len, fixed_name.len)]);
    const owned_regions = try regions.toOwnedSlice(allocator);
    errdefer allocator.free(owned_regions);
    const owned_samples = try samples.toOwnedSlice(allocator);
    errdefer allocator.free(owned_samples);
    const presets = try allocator.alloc(Preset, 1);
    errdefer allocator.free(presets);
    presets[0] = .{ .name = fixed_name, .bank = 0, .program = 0, .regions = owned_regions };
    return .{ .allocator = allocator, .sample_data = owned_samples, .presets = presets };
}

fn apply(s: *Settings, key: []const u8, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "sample")) s.sample = value else if (std.mem.eql(u8, key, "trigger")) {
        if (std.mem.eql(u8, value, "attack")) s.trigger_release = false else if (std.mem.eql(u8, value, "release")) s.trigger_release = true else return error.UnsupportedOpcode;
    } else if (std.mem.eql(u8, key, "key")) {
        const v = try midi(value);
        s.key_lo = v;
        s.key_hi = v;
        s.root_key = v;
    } else if (std.mem.eql(u8, key, "lokey")) s.key_lo = try midi(value) else if (std.mem.eql(u8, key, "hikey")) s.key_hi = try midi(value) else if (std.mem.eql(u8, key, "lovel") or std.mem.eql(u8, key, "xfin_lovel")) s.vel_lo = try midi(value) else if (std.mem.eql(u8, key, "hivel") or std.mem.eql(u8, key, "xfout_hivel")) s.vel_hi = try midi(value) else if (std.mem.eql(u8, key, "pitch_keycenter")) s.root_key = try midi(value) else if (std.mem.eql(u8, key, "pitch_keytrack")) s.scale_tuning_cents = try float(value) else if (std.mem.eql(u8, key, "tune")) s.tune_cents = try float(value) else if (std.mem.eql(u8, key, "volume") or std.mem.eql(u8, key, "global_volume")) s.volume_db += try float(value) else if (std.mem.eql(u8, key, "offset")) s.offset = try uint(u32, value) else if (std.mem.eql(u8, key, "ampeg_attack")) s.attack_s = try nonnegative(value) else if (std.mem.eql(u8, key, "ampeg_decay")) s.decay_s = try nonnegative(value) else if (std.mem.eql(u8, key, "ampeg_sustain")) s.sustain = std.math.clamp((try float(value)) / 100, 0, 1) else if (std.mem.eql(u8, key, "ampeg_release")) s.release_s = try nonnegative(value) else if (std.mem.eql(u8, key, "seq_position")) s.seq_position = try uint(u16, value) else if (std.mem.eql(u8, key, "seq_length") or std.mem.eql(u8, key, "amp_veltrack") or std.mem.eql(u8, key, "rt_decay") or std.mem.eql(u8, key, "xfin_hivel") or std.mem.eql(u8, key, "xfout_lovel")) {
        _ = try float(value);
    } else if (std.mem.eql(u8, key, "locc64") or std.mem.eql(u8, key, "on_locc64")) s.cc64_lo = try midi(value) else if (std.mem.eql(u8, key, "hicc64") or std.mem.eql(u8, key, "on_hicc64")) s.cc64_hi = try midi(value) else return error.UnsupportedOpcode;
}

fn appendRegion(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sample_rate: u32, s: Settings, samples: *std.ArrayListUnmanaged(f32), regions: *std.ArrayListUnmanaged(Region)) !void {
    // ponytail: first round-robin member only; add runtime sequence state when
    // repeated notes expose audible machine-gunning in shipped material.
    if (s.trigger_release or s.seq_position > 1 or s.cc64_lo > 0) return;
    const path = s.sample orelse return error.MissingSample;
    if (std.fs.path.isAbsolute(path) or std.mem.indexOf(u8, path, "..") != null) return error.InvalidPath;
    const bytes = try dir.readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);
    const Raw = struct { samples: []f32, sample_rate: u32 };
    const raw: Raw = if (std.ascii.endsWithIgnoreCase(path, ".wav")) blk: {
        const decoded = try wav.parseAlloc(allocator, bytes);
        break :blk .{ .samples = decoded.samples, .sample_rate = decoded.sample_rate };
    } else if (std.ascii.endsWithIgnoreCase(path, ".flac")) blk: {
        const decoded = try flac.parseAlloc(allocator, bytes);
        break :blk .{ .samples = decoded.samples, .sample_rate = decoded.sample_rate };
    } else return error.UnsupportedSampleFormat;
    defer allocator.free(raw.samples);
    const offset: usize = @min(s.offset, raw.samples.len);
    const decoded = try pad_dsp.resample(allocator, raw.samples[offset..], raw.sample_rate, sample_rate);
    defer allocator.free(decoded);
    const start = samples.items.len;
    try samples.appendSlice(allocator, decoded);
    if (samples.items.len > std.math.maxInt(u32)) return error.OutputTooLarge;
    try regions.append(allocator, .{
        .start = @intCast(start),
        .end = @intCast(samples.items.len),
        .loop_start = @intCast(samples.items.len),
        .loop_end = @intCast(samples.items.len),
        .loops = false,
        .key_lo = s.key_lo,
        .key_hi = s.key_hi,
        .vel_lo = s.vel_lo,
        .vel_hi = s.vel_hi,
        .root_key = s.root_key,
        .scale_tuning_cents = s.scale_tuning_cents,
        .tune_semitones = s.tune_cents / 100,
        .pan = 0,
        .attenuation_gain = std.math.pow(f32, 10, s.volume_db / 20),
        .delay_s = 0,
        .attack_s = s.attack_s,
        .hold_s = 0,
        .decay_s = s.decay_s,
        .sustain = s.sustain,
        .release_s = s.release_s,
        .filter_cutoff_hz = null,
        .filter_q = 1,
        .exclusive_class = 0,
    });
}

fn uint(comptime T: type, value: []const u8) ParseError!T {
    return std.fmt.parseInt(T, value, 10) catch error.InvalidValue;
}
fn float(value: []const u8) ParseError!f32 {
    const v = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    return if (std.math.isFinite(v)) v else error.InvalidValue;
}
fn nonnegative(value: []const u8) ParseError!f32 {
    const v = try float(value);
    return if (v >= 0) v else error.InvalidValue;
}
fn midi(value: []const u8) ParseError!u8 {
    const v = try uint(u8, value);
    return if (v <= 127) v else error.InvalidValue;
}

test "SFZ global and group inheritance resolve into shared sample bank" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wav_buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav_buf);
    try @import("../core/wav.zig").write(&writer, 48_000, 1, &.{ 0.25, -0.25 }, .pcm16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tone.wav", .data = writer.buffered() });
    const bank = try parse(std.testing.allocator, std.testing.io, tmp.dir, "<global>\nvolume=-6\n<group>\nampeg_release=0.4\n<region>\nsample=tone.wav\nlokey=60\nhikey=62\npitch_keycenter=61\nlovel=1\nhivel=80\n", "Piano", 48_000);
    var owned = bank;
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.presets.len);
    try std.testing.expectEqual(@as(usize, 1), owned.presets[0].regions.len);
    const r = owned.presets[0].regions[0];
    try std.testing.expectEqual(@as(u8, 60), r.key_lo);
    try std.testing.expectEqual(@as(u8, 80), r.vel_hi);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), r.release_s, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.501187), r.attenuation_gain, 1e-5);
}

test "SFZ rejects MIDI-domain values above 127" {
    inline for ([_][]const u8{ "key", "lokey", "hikey", "pitch_keycenter", "lovel", "hivel", "xfin_lovel", "xfout_hivel", "locc64", "hicc64", "on_locc64", "on_hicc64" }) |opcode| {
        var settings: Settings = .{};
        try std.testing.expectError(error.InvalidValue, apply(&settings, opcode, "128"));
    }
}

fn parseForAllocationTest(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var bank = try parse(allocator, std.testing.io, dir, "<region>\nsample=tone.wav\n", "Piano", 48_000);
    bank.deinit();
}

test "SFZ parse cleans partial bank after allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wav_buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav_buf);
    try @import("../core/wav.zig").write(&writer, 48_000, 1, &.{ 0.25, -0.25 }, .pcm16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tone.wav", .data = writer.buffered() });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseForAllocationTest, .{tmp.dir});
}
