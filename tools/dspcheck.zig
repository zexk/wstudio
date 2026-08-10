//! Runs a directory of real audio files through the DSP paths that consume
//! sample data, and reports what broke or came out wrong.
//!
//! Two different jobs, because a sample corpus can answer two questions:
//!
//!   1. Robustness - does anything crash, allocate unboundedly, or emit a
//!      non-finite sample when fed audio nobody wrote a fixture for? Every
//!      file goes through `wav.parseAlloc`, a `Sampler` render, and all 21
//!      built-in FX units.
//!   2. Accuracy - the file names in a commercial sample library carry the
//!      tempo and key as ground truth, so `tempo.detect` and `pitch.detect`
//!      can be scored against them instead of eyeballed. This is the same
//!      kind of corpus `tempo.zig`'s `min_confidence` was tuned on.
//!
//! Usage: `zig build dspcheck -- work/audio_refs [--verbose]`
//! Exit code is non-zero only for robustness failures. Accuracy is reported,
//! never asserted - a detector scoring badly on pads is a fact about pads.

const std = @import("std");
const ws = @import("wstudio");

const Sample = ws.types.Sample;
const sample_rate: u32 = 48_000;
/// Cap on file bytes. The corpus has a 71 MB pad in it deliberately; this is
/// well past that but stops a stray multi-gigabyte file from OOMing the run.
const max_file_bytes: usize = 256 * 1024 * 1024;
/// Detectors get the head of the clip, not all of it. Both are O(n) or worse
/// in clip length and neither gains accuracy past a few seconds, so a long
/// pad would otherwise dominate the whole run's wall time.
const analysis_seconds: usize = 20;

const Tally = struct {
    files: usize = 0,
    decoded: usize = 0,
    /// Decode rejections by error name, e.g. `NotWav` for the AIFF/MP3 dirs.
    decode_errors: std.StringHashMapUnmanaged(usize) = .empty,

    tempo_labelled: usize = 0,
    tempo_detected: usize = 0,
    tempo_exact: usize = 0,
    tempo_octave: usize = 0,

    pitch_labelled: usize = 0,
    pitch_detected: usize = 0,
    pitch_exact: usize = 0,

    rendered: usize = 0,
    silent: usize = 0,
    /// Robustness failures: a non-finite sample out of the sampler or an FX
    /// unit. These are the only thing that fails the run.
    nonfinite_render: usize = 0,
    nonfinite_fx: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();

    var root: []const u8 = "work/audio_refs";
    var verbose = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) verbose = true else root = arg;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;

    var tally: Tally = .{};
    defer tally.decode_errors.deinit(init.gpa);

    var dir = try std.Io.Dir.cwd().openDir(init.io, root, .{ .iterate = true });
    defer dir.close(init.io);
    var walker = try dir.walk(init.gpa);
    defer walker.deinit();

    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isAudioName(entry.basename)) continue;
        const path = try std.fs.path.join(init.gpa, &.{ root, entry.path });
        defer init.gpa.free(path);
        try checkFile(init.gpa, init.io, path, entry.basename, &tally, if (verbose) out else null);
    }

    try report(out, &tally);
    try out.flush();

    if (tally.nonfinite_render != 0 or tally.nonfinite_fx != 0) return error.NonFiniteAudio;
    if (tally.files == 0) return error.NoAudioFiles;
}

fn isAudioName(name: []const u8) bool {
    for ([_][]const u8{ ".wav", ".aif", ".aiff", ".mp3" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

fn checkFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    name: []const u8,
    tally: *Tally,
    verbose: ?*std.Io.Writer,
) !void {
    tally.files += 1;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(bytes);

    // Same call the Sampler/Slicer loaders make, resample included, so a
    // decode failure here is exactly what a user dragging the file in gets.
    const mono = ws.dsp.pad.decodeWav(gpa, bytes, sample_rate) catch |err| {
        const gop = try tally.decode_errors.getOrPut(gpa, @errorName(err));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (verbose) |w| try w.print("decode {s}: {s}\n", .{ @errorName(err), name });
        return;
    };
    defer gpa.free(mono);
    tally.decoded += 1;
    if (mono.len == 0) return;

    const head = mono[0..@min(mono.len, analysis_seconds * sample_rate)];
    try scoreTempo(name, head, tally, verbose);
    try scorePitch(name, head, tally, verbose);
    try renderThroughSampler(gpa, name, mono, tally, verbose);
    try runThroughEveryFx(gpa, name, head, tally, verbose);
}

/// Score `tempo.detect` against the BPM the file name declares. An answer
/// half or double the labelled tempo is counted separately: the pulse is
/// right and the metrical level is not, which is a different failure from
/// hearing an unrelated tempo.
fn scoreTempo(name: []const u8, samples: []const f32, tally: *Tally, verbose: ?*std.Io.Writer) !void {
    const labelled = ws.dsp.tempo.bpmFromName(name) orelse return;
    tally.tempo_labelled += 1;
    const got = ws.dsp.tempo.detect(samples, sample_rate) orelse {
        if (verbose) |w| try w.print("tempo declined (label {d:.0}): {s}\n", .{ labelled, name });
        return;
    };
    tally.tempo_detected += 1;
    // 2% covers the rounding in names like "127 BPM" without admitting a
    // neighbouring tempo.
    const tol = labelled * 0.02;
    if (@abs(got.bpm - labelled) <= tol) {
        tally.tempo_exact += 1;
    } else if (@abs(got.bpm - labelled * 2) <= tol * 2 or @abs(got.bpm - labelled * 0.5) <= tol) {
        tally.tempo_octave += 1;
        if (verbose) |w| try w.print("tempo x2/x0.5 {d:.1} vs {d:.0}: {s}\n", .{ got.bpm, labelled, name });
    } else if (verbose) |w| {
        try w.print("tempo wrong {d:.1} vs {d:.0} (conf {d:.2}): {s}\n", .{ got.bpm, labelled, got.confidence, name });
    }
}

/// Score `pitch.detect` against the root note in the file name. Only the
/// pitch class is comparable - a name says "F min", never which octave.
fn scorePitch(name: []const u8, samples: []const f32, tally: *Tally, verbose: ?*std.Io.Writer) !void {
    const labelled = ws.dsp.pitch.rootFromName(name) orelse return;
    tally.pitch_labelled += 1;
    const got = ws.dsp.pitch.detect(samples, sample_rate) orelse {
        if (verbose) |w| try w.print("pitch declined (label {d}): {s}\n", .{ labelled, name });
        return;
    };
    tally.pitch_detected += 1;
    if (got.note % 12 == labelled) {
        tally.pitch_exact += 1;
    } else if (verbose) |w| {
        try w.print("pitch wrong {d} vs {d}: {s}\n", .{ got.note % 12, labelled, name });
    }
}

/// Play the clip back through a real `Sampler` at its root note and an
/// octave up, and check every frame that comes out.
fn renderThroughSampler(
    gpa: std.mem.Allocator,
    name: []const u8,
    mono: []const f32,
    tally: *Tally,
    verbose: ?*std.Io.Writer,
) !void {
    var sampler = try ws.dsp.Sampler.init(gpa, sample_rate);
    defer sampler.deinit();
    sampler.setSamples(try gpa.dupe(f32, mono), name);

    const dev = sampler.device();
    dev.sendEvent(.{ .note_on = .{ .note = 60, .velocity = 1.0 } });
    dev.sendEvent(.{ .note_on = .{ .note = 72, .velocity = 0.8 } });

    var buf: [512 * ws.engine.channels]Sample = undefined;
    var peak: f32 = 0;
    for (0..64) |_| {
        @memset(&buf, 0.0);
        dev.process(&buf);
        for (buf) |x| {
            if (!std.math.isFinite(x)) {
                tally.nonfinite_render += 1;
                if (verbose) |w| try w.print("sampler emitted non-finite: {s}\n", .{name});
                return;
            }
            peak = @max(peak, @abs(x));
        }
    }
    tally.rendered += 1;
    // Not a failure: plenty of real one-shots open with silence, and a
    // pad's first blocks can sit under the noise floor.
    if (peak < 1e-6) {
        tally.silent += 1;
        if (verbose) |w| try w.print("sampler output silent: {s}\n", .{name});
    }
}

/// Feed the clip through every built-in FX unit at its default settings.
/// Hosted plugins are skipped - they need a path to a real .clap/.vst3 and
/// have their own integration test.
fn runThroughEveryFx(
    gpa: std.mem.Allocator,
    name: []const u8,
    mono: []const f32,
    tally: *Tally,
    verbose: ?*std.Io.Writer,
) !void {
    const block_frames = 512;
    const frames = @min(mono.len, block_frames * 8);

    inline for (@typeInfo(ws.FxKind).@"enum".fields) |field| {
        const kind = @field(ws.FxKind, field.name);
        if (kind != .clap and kind != .vst3) {
            var fx: ws.Fx = .{};
            defer fx.deinit(gpa);
            _ = try fx.insert(gpa, 0, kind, sample_rate);

            var chain_buf: [ws.Fx.max_units]ws.dsp.Device = undefined;
            const chain = fx.chain(&chain_buf);

            var buf: [block_frames * ws.engine.channels]Sample = undefined;
            var pos: usize = 0;
            while (pos < frames) : (pos += block_frames) {
                // Annotated: `@min` against a comptime bound would narrow the
                // result type and overflow the `n * 2` below.
                const n: usize = @min(block_frames, frames - pos);
                // Mono clip fanned out to the interleaved stereo every FX
                // unit expects.
                for (0..n) |i| {
                    buf[i * 2] = mono[pos + i];
                    buf[i * 2 + 1] = mono[pos + i];
                }
                @memset(buf[n * 2 ..], 0.0);
                for (chain) |device| device.process(&buf);
                for (buf) |x| {
                    if (!std.math.isFinite(x)) {
                        tally.nonfinite_fx += 1;
                        if (verbose) |w| try w.print("fx {s} emitted non-finite: {s}\n", .{ field.name, name });
                        break;
                    }
                }
            }
        }
    }
}

fn report(out: *std.Io.Writer, t: *Tally) !void {
    try out.print("\n=== dspcheck: {d} files ===\n", .{t.files});
    try out.print("decode    {d}/{d} ok\n", .{ t.decoded, t.files });
    var it = t.decode_errors.iterator();
    while (it.next()) |e| try out.print("          {d}x {s}\n", .{ e.value_ptr.*, e.key_ptr.* });

    try out.print("\ntempo     {d} labelled, {d} answered ({d}%), {d} correct ({d}% of answers), {d} at x2/x0.5\n", .{
        t.tempo_labelled,
        t.tempo_detected,
        pct(t.tempo_detected, t.tempo_labelled),
        t.tempo_exact,
        pct(t.tempo_exact, t.tempo_detected),
        t.tempo_octave,
    });
    try out.print("pitch     {d} labelled, {d} answered ({d}%), {d} correct ({d}% of answers)\n", .{
        t.pitch_labelled,
        t.pitch_detected,
        pct(t.pitch_detected, t.pitch_labelled),
        t.pitch_exact,
        pct(t.pitch_exact, t.pitch_detected),
    });

    try out.print("\nsampler   {d} rendered, {d} silent, {d} non-finite\n", .{ t.rendered, t.silent, t.nonfinite_render });
    try out.print("fx        {d} non-finite\n", .{t.nonfinite_fx});
}

fn pct(n: usize, of: usize) usize {
    if (of == 0) return 0;
    return n * 100 / of;
}
