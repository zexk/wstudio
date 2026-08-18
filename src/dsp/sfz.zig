//! Bounded SFZ reader. It resolves SFZ global/group/region inheritance and
//! external samples into the same flat sample bank used by SF2 playback.
//! Unsupported performance features fail or collapse explicitly instead of
//! claiming full SFZ compatibility.

const std = @import("std");
const audio_file = @import("../core/audio_file.zig");
const sample_bank = @import("soundfont.zig");

const Region = sample_bank.Region;
const Preset = sample_bank.Preset;
const SampleBank = sample_bank.SampleBank;

pub const ParseError = error{
    Empty,
    Malformed,
    MissingSample,
    UnsupportedOpcode,
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
    loops: bool = false,
    loop_start: u32 = 0,
    loop_end: u32 = 0,
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
    var in_group = false;
    var section: enum { none, global, group, region } = .none;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const before_comment = if (std.mem.indexOf(u8, raw_line, "//")) |i| raw_line[0..i] else raw_line;
        // A line is a token stream, not one opcode: SFZ packs several
        // `key=value` pairs per line and writes headers inline before them.
        var rest = std.mem.trim(u8, before_comment, " \t\r");
        while (rest.len > 0) {
            if (rest[0] == '<') {
                const close = std.mem.indexOfScalar(u8, rest, '>') orelse return error.Malformed;
                if (current) |r| try appendRegion(allocator, io, sample_dir, target_sample_rate, r, &samples, &regions);
                current = null;
                const header = rest[0 .. close + 1];
                if (std.mem.eql(u8, header, "<global>")) {
                    section = .global;
                    global = .{};
                    in_group = false;
                } else if (std.mem.eql(u8, header, "<group>")) {
                    section = .group;
                    group = global;
                    in_group = true;
                } else if (std.mem.eql(u8, header, "<region>")) {
                    section = .region;
                    // `group` is a snapshot taken when its header was read, so
                    // it only carries the `<global>` opcodes seen by then. A
                    // file that writes regions straight under `<global>` has to
                    // inherit from `global` itself or it loses all of them.
                    current = if (in_group) group else global;
                } else return error.UnsupportedOpcode;
                rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.Malformed;
            const key = std.mem.trim(u8, rest[0..eq], " \t");
            const after = rest[eq + 1 ..];
            const end = valueEnd(after);
            const value = std.mem.trim(u8, after[0..end], " \t");
            if (key.len == 0 or value.len == 0) return error.Malformed;
            switch (section) {
                .global => try apply(&global, key, value),
                .group => try apply(&group, key, value),
                .region => try apply(&(current orelse return error.Malformed), key, value),
                .none => return error.Malformed,
            }
            rest = std.mem.trimStart(u8, after[end..], " \t");
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
    } else if (std.mem.eql(u8, key, "loop_mode")) {
        // `loop_sustain` collapses to a plain loop for the same reason SF2
        // sample mode 3 does (see soundfont.zig): the unlooped tail after
        // key-up is the part we drop.
        if (std.mem.eql(u8, value, "no_loop") or std.mem.eql(u8, value, "one_shot")) s.loops = false else if (std.mem.eql(u8, value, "loop_continuous") or std.mem.eql(u8, value, "loop_sustain")) s.loops = true else return error.UnsupportedOpcode;
    } else if (std.mem.eql(u8, key, "key")) {
        const v = try midi(value);
        s.key_lo = v;
        s.key_hi = v;
        s.root_key = v;
    } else if (std.mem.eql(u8, key, "lokey")) s.key_lo = try midi(value) else if (std.mem.eql(u8, key, "hikey")) s.key_hi = try midi(value) else if (std.mem.eql(u8, key, "lovel") or std.mem.eql(u8, key, "xfin_lovel")) s.vel_lo = try midi(value) else if (std.mem.eql(u8, key, "hivel") or std.mem.eql(u8, key, "xfout_hivel")) s.vel_hi = try midi(value) else if (std.mem.eql(u8, key, "pitch_keycenter")) s.root_key = try midi(value) else if (std.mem.eql(u8, key, "pitch_keytrack")) s.scale_tuning_cents = try float(value) else if (std.mem.eql(u8, key, "tune")) s.tune_cents = try float(value) else if (std.mem.eql(u8, key, "volume") or std.mem.eql(u8, key, "global_volume")) s.volume_db += try float(value) else if (std.mem.eql(u8, key, "offset")) s.offset = try uint(u32, value) else if (std.mem.eql(u8, key, "loop_start")) s.loop_start = try uint(u32, value) else if (std.mem.eql(u8, key, "loop_end")) s.loop_end = try uint(u32, value) else if (std.mem.eql(u8, key, "ampeg_attack")) s.attack_s = try nonnegative(value) else if (std.mem.eql(u8, key, "ampeg_decay")) s.decay_s = try nonnegative(value) else if (std.mem.eql(u8, key, "ampeg_sustain")) s.sustain = std.math.clamp((try float(value)) / 100, 0, 1) else if (std.mem.eql(u8, key, "ampeg_release")) s.release_s = try nonnegative(value) else if (std.mem.eql(u8, key, "seq_position")) s.seq_position = try uint(u16, value) else if (std.mem.eql(u8, key, "seq_length") or std.mem.eql(u8, key, "amp_veltrack") or std.mem.eql(u8, key, "rt_decay") or std.mem.eql(u8, key, "xfin_hivel") or std.mem.eql(u8, key, "xfout_lovel")) {
        _ = try float(value);
    } else if (std.mem.eql(u8, key, "ampeg_dynamic") or std.mem.eql(u8, key, "group_label")) {
        // Editor metadata and an envelope-recalculation hint: neither changes
        // a rendered sample, and rejecting them would lock out every VSCO 2
        // patch, which sets both.
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
    // Whatever libsndfile makes of the bytes, rather than a branch per
    // extension: an SFZ pack can point at any of the formats it reads.
    const raw = try audio_file.parseAlloc(allocator, bytes);
    defer allocator.free(raw.samples);
    if (raw.sample_rate == 0) return error.InvalidValue;
    const offset: usize = @min(s.offset, raw.samples.len);
    // Kept at its recorded rate: the voice already reads the pool at an
    // arbitrary pitch ratio, so a 44.1k sample in a 48k project is one more
    // constant folded into that ratio. Band-limiting all of it up front
    // instead cost 31 of the grand piano's 33 second load.
    const decoded = raw.samples[offset..];
    const rate_cents: f32 = @floatCast(1200.0 * std.math.log2(
        @as(f64, @floatFromInt(raw.sample_rate)) / @as(f64, @floatFromInt(sample_rate)),
    ));
    const start = samples.items.len;
    try samples.appendSlice(allocator, decoded);
    if (samples.items.len > std.math.maxInt(u32)) return error.OutputTooLarge;
    // SFZ counts loop points in source frames from the file start and calls
    // the last looped frame `loop_end`; the pool wants pool indices and an
    // exclusive end. A loop that `offset` already cut past, or one the file
    // is too short for, degrades to no loop rather than reading a neighbour.
    const loop_lo = (start + @as(usize, s.loop_start)) -| offset;
    const loop_hi = (start + @as(usize, s.loop_end) + 1) -| offset;
    const loops = s.loops and s.loop_end > s.loop_start and
        s.loop_start >= offset and loop_hi <= samples.items.len;
    try regions.append(allocator, .{
        .start = @intCast(start),
        .end = @intCast(samples.items.len),
        .loop_start = @intCast(if (loops) loop_lo else samples.items.len),
        .loop_end = @intCast(if (loops) loop_hi else samples.items.len),
        .loops = loops,
        .key_lo = s.key_lo,
        .key_hi = s.key_hi,
        .vel_lo = s.vel_lo,
        .vel_hi = s.vel_hi,
        .root_key = s.root_key,
        .scale_tuning_cents = s.scale_tuning_cents,
        .tune_semitones = (s.tune_cents + rate_cents) / 100,
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

/// Where an opcode's value ends inside `after` (the text past its `=`). A
/// sample path may contain spaces, so the value runs up to the token that
/// starts the *next* `key=`, not to the next space.
fn valueEnd(after: []const u8) usize {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, after, from, '=')) |eq| {
        var i = eq;
        while (i > 0 and !std.ascii.isWhitespace(after[i - 1])) i -= 1;
        // No whitespace ahead of it: that `=` sits inside this value.
        if (i > 0) return i;
        from = eq + 1;
    }
    return after.len;
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

test "off-rate sample keeps its recorded frames and pays for it in tune" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wav_buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav_buf);
    const frames = [_]f32{ 0, 0.5, 1, 0.5, 0, -0.5, -1, -0.5 };
    try @import("../core/wav.zig").write(&writer, 44_100, 1, &frames, .pcm16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tone.wav", .data = writer.buffered() });
    var bank = try parse(std.testing.allocator, std.testing.io, tmp.dir, "<region>\nsample=tone.wav\ntune=0\n", "Piano", 48_000);
    defer bank.deinit();
    // No resampling at load: the pool holds the file's own frames.
    try std.testing.expectEqual(frames.len, bank.sample_data.len);
    // The region's tune is what makes the voice read those frames at 44.1k
    // while the engine runs at 48k (soundfont_player.spawnVoice's `rate`).
    const r = bank.presets[0].regions[0];
    const rate = std.math.pow(f64, 2.0, @as(f64, r.tune_semitones) * 100.0 / 1200.0);
    try std.testing.expectApproxEqAbs(@as(f64, 44_100), rate * 48_000, 0.5);
}

test "SFZ reads inline headers and several opcodes per line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wav_buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav_buf);
    try @import("../core/wav.zig").write(&writer, 48_000, 1, &.{ 0.25, -0.25 }, .pcm16);
    // A space in the file name: the value must not stop at the first space.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "grand tone.wav", .data = writer.buffered() });
    var bank = try parse(std.testing.allocator, std.testing.io, tmp.dir, "<group> ampeg_release=0.4\n<region> sample=grand tone.wav lokey=60 hikey=62 pitch_keycenter=61 // tail\n", "Piano", 48_000);
    defer bank.deinit();
    try std.testing.expectEqual(@as(usize, 1), bank.presets[0].regions.len);
    const r = bank.presets[0].regions[0];
    try std.testing.expectEqual(@as(u8, 60), r.key_lo);
    try std.testing.expectEqual(@as(u8, 62), r.key_hi);
    try std.testing.expectEqual(@as(u8, 61), r.root_key);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), r.release_s, 1e-6);
}

test "SFZ loop points land in the pool, offset and all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wav_buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wav_buf);
    const frames = [_]f32{ 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7 };
    try @import("../core/wav.zig").write(&writer, 48_000, 1, &frames, .pcm16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tone.wav", .data = writer.buffered() });

    // Two regions so the second one starts at a non-zero pool offset, which is
    // where a file-relative loop point would otherwise be read as a pool one.
    const text =
        \\<global> loop_mode=loop_continuous
        \\<region> sample=tone.wav loop_start=2 loop_end=5
        \\<region> sample=tone.wav offset=1 loop_start=2 loop_end=5
        \\
    ;
    var bank = try parse(std.testing.allocator, std.testing.io, tmp.dir, text, "Loop", 48_000);
    defer bank.deinit();
    const regions = bank.presets[0].regions;
    try std.testing.expectEqual(@as(usize, 2), regions.len);
    // `loop_end` is SFZ's last looped frame; the pool wants one past it.
    try std.testing.expect(regions[0].loops);
    try std.testing.expectEqual(@as(u32, 2), regions[0].loop_start);
    try std.testing.expectEqual(@as(u32, 6), regions[0].loop_end);
    // Second region: pool starts at 8, and `offset=1` shifts the loop back one.
    try std.testing.expect(regions[1].loops);
    try std.testing.expectEqual(@as(u32, 9), regions[1].loop_start);
    try std.testing.expectEqual(@as(u32, 13), regions[1].loop_end);

    // no_loop wins even with loop points present, and an out-of-range loop
    // degrades to no loop rather than reading the neighbouring region.
    var plain = try parse(std.testing.allocator, std.testing.io, tmp.dir, "<region> sample=tone.wav loop_mode=no_loop loop_start=2 loop_end=5\n", "Loop", 48_000);
    defer plain.deinit();
    try std.testing.expect(!plain.presets[0].regions[0].loops);
    var past = try parse(std.testing.allocator, std.testing.io, tmp.dir, "<region> sample=tone.wav loop_mode=loop_continuous loop_start=2 loop_end=99\n", "Loop", 48_000);
    defer past.deinit();
    try std.testing.expect(!past.presets[0].regions[0].loops);
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
