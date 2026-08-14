//! Dumps everything needed to judge the factory synth presets as a set:
//! what each one is, what it actually sounds like, and which other preset it
//! is closest to.
//!
//! The drum kits could be judged by reading `variants` - 12 entries, a dozen
//! numbers each. The synth presets can't: 100 patches with ~150 fields, where
//! the fields that matter differ per patch (a pad is defined by its envelope,
//! a bass by its filter). So this measures instead of listing:
//!
//!   1. Every preset is rendered through real `PolySynth`: same note,
//!      same velocity, same hold - and reduced to features you can sort a
//!      table by: where its energy sits, how fast it starts and stops, how
//!      wide and how noisy it is.
//!   2. Every preset is compared to every other one, using patch fields
//!      (reflected, so nothing needs listing here) and those features.
//!      Two presets can be near-identical patches that sound different, or
//!      different patches that sound the same; both are worth knowing, so
//!      both distances are reported.
//!
//! The pair report at the end is the actual answer to "which of these are
//! redundant": for the closest pairs it prints which patch fields differ and
//! by how much, which is what tells you whether one can fold into the other
//! as a variation or whether they are genuinely two sounds.
//!
//! Usage: `zig build presetscan [-- --note 48 --pairs 30 --category bass]`
//! Nothing is asserted and the exit code is always 0 - this reports, it does
//! not judge. The judging is the point of reading it.

const std = @import("std");
const ws = @import("wstudio");

const Sample = ws.types.Sample;
const PolySynth = ws.dsp.synth.PolySynth;
const Patch = PolySynth.Patch;
const presets = ws.dsp.synth_presets.presets;

const sample_rate: u32 = 48_000;
const block_frames: usize = 256;
/// Note held this long, then released and left to ring. Long enough that a
/// 0.9 s pad attack finishes inside the hold, short enough that 100 presets
/// still render in a couple of seconds.
const hold_s: f32 = 1.5;
const tail_s: f32 = 2.0;
/// Spectrum window, taken from the middle of the hold so it sees the sustain
/// rather than the attack transient.
const fft_size: usize = 8192;

const Features = struct {
    peak: f32 = 0,
    rms: f32 = 0,
    /// Peak over RMS. High means transient (a pluck), low means sustained.
    crest: f32 = 0,
    /// Time from note-on to 90% of peak.
    attack_ms: f32 = 0,
    /// RMS over the last 200 ms of the hold, relative to the loudest 200 ms.
    /// ~1 means it sustains, ~0 means it decayed away while still held.
    sustain: f32 = 0,
    /// Time from note-off until the tail drops 40 dB below the hold's RMS.
    release_ms: f32 = 0,
    centroid_hz: f32 = 0,
    /// Geometric over arithmetic mean of the spectrum: ~0 is a clean tone,
    /// toward 1 is noise.
    flatness: f32 = 0,
    /// Share of spectral energy below 200 Hz / 200 Hz-2 kHz / above 2 kHz.
    low: f32 = 0,
    mid: f32 = 0,
    high: f32 = 0,
    /// 1 - |correlation(L, R)|. 0 is mono, 1 is fully decorrelated.
    width: f32 = 0,
};

const Row = struct {
    name: []const u8,
    category: []const u8,
    tags: []const []const u8,
    patch: Patch,
    f: Features,
    mod_rows: usize,
    fx_count: usize,
    arp: bool,
    /// Filled in by the pair pass.
    near_patch: usize = 0,
    near_patch_d: f32 = 0,
    near_audio: usize = 0,
    near_audio_d: f32 = 0,
};

// ---------------------------------------------------------------------------
// Rendering

fn render(allocator: std.mem.Allocator, patch: Patch, note: u7) ![]Sample {
    var synth = try PolySynth.init(allocator, sample_rate);
    defer synth.deinit();
    try synth.applyPatchWithWavetables(patch);

    const srf: f32 = @floatFromInt(sample_rate);
    const hold_frames: usize = @intFromFloat(hold_s * srf);
    const total_frames: usize = @intFromFloat((hold_s + tail_s) * srf);
    const buf = try allocator.alloc(Sample, total_frames * 2);
    @memset(buf, 0);

    synth.noteOn(note, 0.8);
    var done: usize = 0;
    while (done < total_frames) {
        var n: usize = @min(block_frames, total_frames - done);
        // Never straddle the note-off: it lands on a block boundary.
        if (done < hold_frames) n = @min(n, hold_frames - done);
        synth.processBlock(buf[done * 2 ..][0 .. n * 2]);
        done += n;
        if (done == hold_frames) synth.noteOff(note);
    }
    return buf;
}

fn rmsOf(buf: []const Sample) f32 {
    if (buf.len == 0) return 0;
    var sum: f64 = 0;
    for (buf) |s| sum += @as(f64, s) * @as(f64, s);
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(buf.len))));
}

fn analyze(allocator: std.mem.Allocator, buf: []const Sample) !Features {
    const srf: f32 = @floatFromInt(sample_rate);
    const hold_frames: usize = @intFromFloat(hold_s * srf);
    const frames = buf.len / 2;
    var f: Features = .{};
    var peak_frame: usize = 0;

    for (0..frames) |i| {
        const peak = @max(@abs(buf[i * 2]), @abs(buf[i * 2 + 1]));
        if (peak > f.peak) {
            f.peak = peak;
            peak_frame = i;
        }
    }
    f.rms = rmsOf(buf);
    f.crest = if (f.rms > 1e-9) f.peak / f.rms else 0;
    if (f.peak < 1e-6) return f; // silent patch: the rest would be noise

    // Attack: first frame reaching 90% of peak.
    for (0..frames) |i| {
        if (@max(@abs(buf[i * 2]), @abs(buf[i * 2 + 1])) >= f.peak * 0.9) {
            f.attack_ms = @as(f32, @floatFromInt(i)) / srf * 1000.0;
            break;
        }
    }

    // Sustain: last 200 ms of the hold against the loudest 200 ms window.
    const win: usize = @intFromFloat(0.2 * srf);
    var loudest: f32 = 0;
    var w: usize = 0;
    while (w + win <= hold_frames) : (w += win) {
        loudest = @max(loudest, rmsOf(buf[w * 2 ..][0 .. win * 2]));
    }
    const tail_of_hold = rmsOf(buf[(hold_frames - win) * 2 ..][0 .. win * 2]);
    f.sustain = if (loudest > 1e-9) tail_of_hold / loudest else 0;

    // Release: how long after note-off until 40 dB below the hold.
    const floor = loudest * 0.01;
    f.release_ms = @as(f32, @floatFromInt(frames - hold_frames)) / srf * 1000.0;
    var t = hold_frames;
    while (t + win <= frames) : (t += win) {
        if (rmsOf(buf[t * 2 ..][0 .. win * 2]) < floor) {
            f.release_ms = @as(f32, @floatFromInt(t - hold_frames)) / srf * 1000.0;
            break;
        }
    }

    // Stereo width from the L/R correlation over the hold.
    var sxy: f64 = 0;
    var sxx: f64 = 0;
    var syy: f64 = 0;
    for (0..hold_frames) |i| {
        const l: f64 = buf[i * 2];
        const r: f64 = buf[i * 2 + 1];
        sxy += l * r;
        sxx += l * l;
        syy += r * r;
    }
    const denom = @sqrt(sxx * syy);
    f.width = if (denom > 1e-12) 1.0 - @abs(@as(f32, @floatCast(sxy / denom))) else 0;

    // Center spectrum on loudest frame. Mid-hold is silent for plucks, which
    // would collapse distinct transient sounds to the same zero vector.
    const start = @min(peak_frame -| fft_size / 2, hold_frames - fft_size);
    const real = try allocator.alloc(f32, fft_size);
    defer allocator.free(real);
    const imag = try allocator.alloc(f32, fft_size);
    defer allocator.free(imag);
    @memset(imag, 0);
    for (0..fft_size) |i| {
        const idx = start + i;
        const mono = if (idx < frames) (buf[idx * 2] + buf[idx * 2 + 1]) * 0.5 else 0;
        const phase = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, fft_size);
        real[i] = mono * 0.5 * (1.0 - @cos(phase));
    }
    ws.dsp.fft.fft(fft_size, real, imag);

    var mag_sum: f64 = 0;
    var weighted: f64 = 0;
    var log_sum: f64 = 0;
    var bands = [3]f64{ 0, 0, 0 };
    const bin_hz = srf / @as(f32, fft_size);
    for (0..fft_size / 2) |i| {
        const mag = @sqrt(real[i] * real[i] + imag[i] * imag[i]);
        const hz = @as(f32, @floatFromInt(i)) * bin_hz;
        mag_sum += mag;
        weighted += @as(f64, mag) * hz;
        log_sum += @log(@as(f64, mag) + 1e-12);
        if (hz < 200.0) {
            bands[0] += mag;
        } else if (hz < 2000.0) {
            bands[1] += mag;
        } else {
            bands[2] += mag;
        }
    }
    if (mag_sum > 1e-12) {
        f.centroid_hz = @floatCast(weighted / mag_sum);
        const geo = @exp(log_sum / @as(f64, fft_size / 2));
        const arith = mag_sum / @as(f64, fft_size / 2);
        f.flatness = @floatCast(geo / arith);
        f.low = @floatCast(bands[0] / mag_sum);
        f.mid = @floatCast(bands[1] / mag_sum);
        f.high = @floatCast(bands[2] / mag_sum);
    }
    return f;
}

// ---------------------------------------------------------------------------
// Patch comparison
//
// Reflected rather than listed: a hand-written field list would be 150 lines
// that go stale the first time someone adds a knob. Only scalar fields take
// part - arrays (mod_matrix, LFO shapes), pointers and the synth's runtime
// state carry no patch identity, and `mod_matrix` gets counted separately.

fn isScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool, .@"enum" => true,
        .optional => |o| isScalar(o.child),
        else => false,
    };
}

/// A field's value as a float, for distance and for printing. Optionals read
/// as their payload, or as `fallback` when null (null means "inherit", so it
/// should not read as a big jump from whatever it inherits).
fn scalarValue(comptime T: type, v: T, fallback: f32) f32 {
    return switch (@typeInfo(T)) {
        .float => @floatCast(v),
        .int => @floatFromInt(v),
        .bool => if (v) 1.0 else 0.0,
        .@"enum" => @floatFromInt(@intFromEnum(v)),
        .optional => |o| if (v) |inner| scalarValue(o.child, inner, fallback) else fallback,
        else => unreachable,
    };
}

const scalar_fields = blk: {
    @setEvalBranchQuota(50_000);
    var names: []const []const u8 = &.{};
    for (@typeInfo(Patch).@"struct".fields) |fld| {
        if (isScalar(fld.type)) names = names ++ [_][]const u8{fld.name};
    }
    break :blk names;
};

/// Per-field spread across the whole preset set, so distance is in units of
/// "how much this field varies at all" rather than raw Hz vs seconds.
const Ranges = [scalar_fields.len]f32;

fn fieldValue(comptime name: []const u8, p: Patch) f32 {
    const T = @FieldType(Patch, name);
    return scalarValue(T, @field(p, name), 0);
}

fn computeRanges(rows: []const Row) Ranges {
    @setEvalBranchQuota(50_000);
    var out: Ranges = undefined;
    inline for (scalar_fields, 0..) |name, i| {
        var lo: f32 = std.math.floatMax(f32);
        var hi: f32 = -std.math.floatMax(f32);
        for (rows) |r| {
            const v = fieldValue(name, r.patch);
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        out[i] = if (hi > lo) hi - lo else 1.0;
    }
    return out;
}

fn patchDistance(a: Patch, b: Patch, ranges: Ranges) f32 {
    @setEvalBranchQuota(50_000);
    var sum: f32 = 0;
    inline for (scalar_fields, 0..) |name, i| {
        const d = (fieldValue(name, a) - fieldValue(name, b)) / ranges[i];
        sum += d * d;
    }
    return @sqrt(sum);
}

fn featureVector(f: Features) [8]f32 {
    // Log where the scale is multiplicative, so 20 ms vs 40 ms counts as much
    // as 200 ms vs 400 ms.
    return .{
        @log10(f.centroid_hz + 20.0),
        f.flatness,
        f.low,
        f.mid,
        f.high,
        @log10(f.attack_ms + 1.0),
        @log10(f.release_ms + 1.0),
        f.sustain,
    };
}

fn audioDistance(a: Features, b: Features, spread: [8]f32) f32 {
    const va = featureVector(a);
    const vb = featureVector(b);
    var sum: f32 = 0;
    for (va, vb, spread) |x, y, s| {
        const d = (x - y) / s;
        sum += d * d;
    }
    return @sqrt(sum);
}

// ---------------------------------------------------------------------------

fn countFx(p: Patch) usize {
    @setEvalBranchQuota(50_000);
    var n: usize = 0;
    inline for (@typeInfo(Patch).@"struct".fields) |fld| {
        if (fld.type == bool and std.mem.startsWith(u8, fld.name, "fx_") and
            std.mem.endsWith(u8, fld.name, "_on"))
        {
            if (@field(p, fld.name)) n += 1;
        }
    }
    return n;
}

fn countModRows(p: Patch) usize {
    var n: usize = 0;
    for (p.mod_matrix) |row| {
        if (row.depth != 0) n += 1;
    }
    return n;
}

/// The fields where two patches differ, worst first: the "why are these two
/// different" answer for a close pair.
fn printDiff(w: anytype, a: Patch, b: Patch, ranges: Ranges, limit: usize) !void {
    @setEvalBranchQuota(50_000);
    const Item = struct { name: []const u8, a: f32, b: f32, d: f32 };
    var items: [scalar_fields.len]Item = undefined;
    var n: usize = 0;
    inline for (scalar_fields, 0..) |name, i| {
        const va = fieldValue(name, a);
        const vb = fieldValue(name, b);
        if (va != vb) {
            items[n] = .{ .name = name, .a = va, .b = vb, .d = @abs(va - vb) / ranges[i] };
            n += 1;
        }
    }
    std.mem.sort(Item, items[0..n], {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return x.d > y.d;
        }
    }.lt);
    for (items[0..@min(n, limit)]) |it| {
        try w.print("      {s: <22} {d: >10.3} | {d: >10.3}\n", .{ it.name, it.a, it.b });
    }
    if (n > limit) try w.print("      ... and {d} more fields\n", .{n - limit});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var note: u7 = 48; // C3: low enough for basses, high enough for leads
    var pair_count: usize = 25;
    var only_category: ?[]const u8 = null;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--note")) {
            note = std.fmt.parseInt(u7, args.next() orelse "48", 10) catch 48;
        } else if (std.mem.eql(u8, arg, "--pairs")) {
            pair_count = std.fmt.parseInt(usize, args.next() orelse "25", 10) catch 25;
        } else if (std.mem.eql(u8, arg, "--category")) {
            only_category = args.next();
        }
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(allocator);

    for (presets) |p| {
        if (only_category) |c| {
            if (!std.mem.eql(u8, c, p.category)) continue;
        }
        const features = blk: {
            const buf = try render(allocator, p.patch, note);
            defer allocator.free(buf);
            break :blk try analyze(allocator, buf);
        };
        try rows.append(allocator, .{
            .name = p.name,
            .category = p.category,
            .tags = p.tags,
            .patch = p.patch,
            .f = features,
            .mod_rows = countModRows(p.patch),
            .fx_count = countFx(p.patch),
            .arp = p.patch.arp_on,
        });
    }

    if (rows.items.len == 0) {
        try w.print("No presets matched category '{s}'.\n", .{only_category.?});
        try w.flush();
        return;
    }

    const ranges = computeRanges(rows.items);

    // Feature spread, so the audio distance weights each feature by how much
    // it actually varies across the set (same idea as `ranges`).
    var spread: [8]f32 = @splat(1.0);
    {
        var lo: [8]f32 = @splat(std.math.floatMax(f32));
        var hi: [8]f32 = @splat(-std.math.floatMax(f32));
        for (rows.items) |r| {
            const v = featureVector(r.f);
            for (v, 0..) |x, i| {
                lo[i] = @min(lo[i], x);
                hi[i] = @max(hi[i], x);
            }
        }
        for (0..8) |i| spread[i] = if (hi[i] > lo[i]) hi[i] - lo[i] else 1.0;
    }

    // ponytail: O(n^2) over 100 presets is ~5k comparisons, nothing. If the
    // preset count ever reaches thousands, bucket by category first.
    for (rows.items, 0..) |*r, i| {
        r.near_patch_d = std.math.floatMax(f32);
        r.near_audio_d = std.math.floatMax(f32);
        for (rows.items, 0..) |o, j| {
            if (i == j) continue;
            const pd = patchDistance(r.patch, o.patch, ranges);
            if (pd < r.near_patch_d) {
                r.near_patch_d = pd;
                r.near_patch = j;
            }
            const ad = audioDistance(r.f, o.f, spread);
            if (ad < r.near_audio_d) {
                r.near_audio_d = ad;
                r.near_audio = j;
            }
        }
    }

    try w.print("# {d} presets, rendered at note {d}, {d} Hz\n", .{ rows.items.len, note, sample_rate });
    try w.print("# low/mid/high are the share of spectral energy below 200 Hz, 200-2k, above 2k.\n", .{});
    try w.print("# nearest_* are the closest other preset by patch fields and by measured sound.\n\n", .{});
    try w.print("name\tcategory\ttags\tpeak\trms\tcrest\tattack_ms\tsustain\trelease_ms\tcentroid\tflatness\tlow\tmid\thigh\twidth\tmods\tfx\tarp\tnearest_patch\tpatch_d\tnearest_audio\taudio_d\n", .{});
    for (rows.items) |r| {
        try w.print("{s}\t{s}\t", .{ r.name, r.category });
        for (r.tags, 0..) |t, i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{s}", .{t});
        }
        try w.print("\t{d:.3}\t{d:.4}\t{d:.1}\t{d:.0}\t{d:.2}\t{d:.0}\t{d:.0}\t{d:.3}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d}\t{d}\t{s}\t{s}\t{d:.2}\t{s}\t{d:.2}\n", .{
            r.f.peak,       r.f.rms,                       r.f.crest,                  r.f.attack_ms,
            r.f.sustain,    r.f.release_ms,                r.f.centroid_hz,            r.f.flatness,
            r.f.low,        r.f.mid,                       r.f.high,                   r.f.width,
            r.mod_rows,     r.fx_count,                    if (r.arp) "yes" else "no", rows.items[r.near_patch].name,
            r.near_patch_d, rows.items[r.near_audio].name, r.near_audio_d,
        });
    }

    // Closest pairs, each listed once, with what actually differs.
    const Pair = struct { a: usize, b: usize, patch_d: f32, audio_d: f32 };
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    defer pairs.deinit(allocator);
    for (rows.items, 0..) |ra, i| {
        for (rows.items[i + 1 ..], i + 1..) |rb, j| {
            try pairs.append(allocator, .{
                .a = i,
                .b = j,
                .patch_d = patchDistance(ra.patch, rb.patch, ranges),
                .audio_d = audioDistance(ra.f, rb.f, spread),
            });
        }
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, x: Pair, y: Pair) bool {
            return x.audio_d < y.audio_d;
        }
    }.lt);

    try w.print("\n\n# The {d} closest pairs by measured sound. A pair that is close on\n", .{pair_count});
    try w.print("# BOTH distances is the same preset twice; close on audio but far on\n", .{});
    try w.print("# patch means two ways to build one sound, which is worth keeping.\n", .{});
    for (pairs.items[0..@min(pairs.items.len, pair_count)]) |p| {
        const ra = rows.items[p.a];
        const rb = rows.items[p.b];
        try w.print("\n  {s} ({s}) <-> {s} ({s})   audio_d={d:.2}  patch_d={d:.2}\n", .{
            ra.name, ra.category, rb.name, rb.category, p.audio_d, p.patch_d,
        });
        try printDiff(w, ra.patch, rb.patch, ranges, 8);
    }

    // Category coverage, so a gap shows up as a thin row rather than by
    // reading 100 names.
    try w.print("\n\n# Coverage by category: count, and the mean of each feature.\n", .{});
    try w.print("category\tn\tcentroid\tattack_ms\trelease_ms\tsustain\tlow\thigh\n", .{});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (rows.items) |r| {
        if (seen.contains(r.category)) continue;
        try seen.put(allocator, r.category, {});
        var n: usize = 0;
        var acc: Features = .{};
        for (rows.items) |o| {
            if (!std.mem.eql(u8, o.category, r.category)) continue;
            n += 1;
            acc.centroid_hz += o.f.centroid_hz;
            acc.attack_ms += o.f.attack_ms;
            acc.release_ms += o.f.release_ms;
            acc.sustain += o.f.sustain;
            acc.low += o.f.low;
            acc.high += o.f.high;
        }
        const d: f32 = @floatFromInt(n);
        try w.print("{s}\t{d}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.2}\t{d:.2}\t{d:.2}\n", .{
            r.category,         n,               acc.centroid_hz / d, acc.attack_ms / d,
            acc.release_ms / d, acc.sustain / d, acc.low / d,         acc.high / d,
        });
    }

    try w.flush();
}
