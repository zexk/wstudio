//! Renders a factory synth preset or drum-kit pad to a waveform PNG and a
//! spectrogram PNG - measurement (presetscan/kitcheck) gives numbers, this
//! gives a picture, for the class of thing a human eye catches instantly
//! (a resonance ring, a harsh partial, a filter sweep) and a summary
//! statistic doesn't.
//!
//! Usage:
//!   zig build audioviz -- <preset-name> [--note N] [--vel V] [--out PREFIX]
//!   zig build audioviz -- <kit-name>/<pad-name> [--out PREFIX]
//!
//! Writes PREFIX_wave.png (min/max envelope) and PREFIX_spec.png (STFT
//! magnitude, log-ish dB range, brighter = louder, low frequency at the
//! bottom). PREFIX defaults to the preset/pad name. Both are 8-bit
//! grayscale PNGs, hand-encoded (one IHDR + one IDAT + IEND) through
//! `std.compress.flate`'s zlib mode - no image library, just the stdlib
//! this project already links.

const std = @import("std");
const ws = @import("wstudio");

const Sample = ws.types.Sample;
const PolySynth = ws.dsp.synth.PolySynth;
const presets = ws.dsp.synth_presets.presets;
const DrumMachine = ws.dsp.DrumMachine;
const drum_kit = ws.dsp.drum_kit;
const Transport = ws.Transport;

const sample_rate: u32 = 48_000;
const block_frames: usize = 256;
const hold_s: f32 = 1.5;
const tail_s: f32 = 2.0;
const drum_frames: usize = 48_000; // 1 s, matches kitcheck

// ---------------------------------------------------------------------------
// Rendering - same shape as presetscan.zig / kitcheck.zig, duplicated
// rather than shared: these are one-shot tools, not a library.

fn renderPreset(allocator: std.mem.Allocator, preset: ws.dsp.synth_presets.Preset, note: u7, vel: f32) ![]Sample {
    var rack = ws.Rack{
        .instrument = .{ .poly_synth = try PolySynth.init(allocator, sample_rate) },
        .label = "audioviz",
    };
    defer rack.deinit(allocator);
    var displaced = try ws.persist.applySynthPreset(allocator, &rack, preset, sample_rate);
    displaced.deinit(allocator);
    const synth = &rack.instrument.poly_synth;

    const srf: f32 = @floatFromInt(sample_rate);
    const hold_frames: usize = @intFromFloat(hold_s * srf);
    const total_frames: usize = @intFromFloat((hold_s + tail_s) * srf);
    const buf = try allocator.alloc(Sample, total_frames * 2);
    @memset(buf, 0);

    synth.noteOn(note, vel);
    var done: usize = 0;
    while (done < total_frames) {
        var n: usize = @min(block_frames, total_frames - done);
        if (done < hold_frames) n = @min(n, hold_frames - done);
        const chunk = buf[done * 2 ..][0 .. n * 2];
        synth.processBlock(chunk);
        for (rack.fx.units.items) |unit| unit.device().process(chunk);
        done += n;
        if (done == hold_frames) synth.noteOff(note);
    }
    return buf;
}

fn renderPad(allocator: std.mem.Allocator, variant: *const drum_kit.KitVariant, pad: usize) ![]Sample {
    var transport: Transport = .{ .sample_rate = sample_rate };
    var dm = try DrumMachine.init(allocator, sample_rate, &transport);
    defer dm.deinit();
    try dm.loadKitVariant(variant);
    const dev = dm.device();
    dev.sendEvent(.{ .note_on = .{ .note = @intCast(pad), .velocity = 1.0 } });

    // A scratch buffer sized like kitcheck's (1024 floats = 512 stereo
    // frames), reused every call and copied into the big output buffer -
    // slicing straight into the output at a 256-frame stride tripped an
    // internal block-size assumption inside DrumMachine.process.
    const buf = try allocator.alloc(Sample, drum_frames * 2);
    const scratch = try allocator.alloc(f32, 1024);
    defer allocator.free(scratch);
    var done: usize = 0;
    while (done < drum_frames) : (done += scratch.len / 2) {
        @memset(scratch, 0);
        dev.process(scratch);
        const n = @min(scratch.len / 2, drum_frames - done);
        @memcpy(buf[done * 2 ..][0 .. n * 2], scratch[0 .. n * 2]);
    }
    return buf;
}

// ---------------------------------------------------------------------------
// Waveform: min/max envelope per pixel column, filled between them so a
// short transient doesn't vanish between two sampled points the way a
// plain line-through-samples plot would lose it at this many-to-one
// downsample ratio.

const wave_w: u32 = 1200;
const wave_h: u32 = 300;

fn renderWaveform(allocator: std.mem.Allocator, buf: []const Sample) ![]u8 {
    const img = try allocator.alloc(u8, wave_w * wave_h);
    @memset(img, 250); // near-white background
    const frames = buf.len / 2;
    const per_col = @max(frames / wave_w, 1);
    const mid: f32 = @floatFromInt(wave_h / 2);

    for (0..wave_w) |x| {
        const start = x * per_col;
        if (start >= frames) break;
        const end = @min(start + per_col, frames);
        var lo: f32 = 0;
        var hi: f32 = 0;
        for (start..end) |i| {
            const mono = (buf[i * 2] + buf[i * 2 + 1]) * 0.5;
            lo = @min(lo, mono);
            hi = @max(hi, mono);
        }
        const y_hi: i32 = @intFromFloat(mid - hi * mid);
        const y_lo: i32 = @intFromFloat(mid - lo * mid);
        const top: u32 = @intCast(std.math.clamp(y_hi, 0, @as(i32, @intCast(wave_h - 1))));
        const bot: u32 = @intCast(std.math.clamp(y_lo, 0, @as(i32, @intCast(wave_h - 1))));
        for (top..bot + 1) |y| img[y * wave_w + x] = 40;
    }
    // Zero-crossing axis, drawn last so it stays visible through silence.
    const axis_y: usize = wave_h / 2;
    for (0..wave_w) |x| {
        if (img[axis_y * wave_w + x] == 250) img[axis_y * wave_w + x] = 190;
    }
    return img;
}

// ---------------------------------------------------------------------------
// Spectrogram: STFT, magnitude in dB relative to the loudest bin in the
// whole render, mapped to grayscale. Low frequency at the bottom row, the
// way a spectrogram is normally read.

const fft_size: usize = 1024;
const hop: usize = 256;
const linear_bins: u32 = fft_size / 2 + 1;
// Output rows, log-spaced from `freq_lo` to Nyquist. Most of what these
// patches do lives under 2 kHz (bass, keys, bell fundamentals); a linear
// bin-per-row image spends 90%+ of its height on content nothing has much
// energy in and crushes the musically-relevant range into a few pixels.
const spec_h: u32 = 400;
const freq_lo: f32 = 30.0;

fn renderSpectrogram(allocator: std.mem.Allocator, buf: []const Sample) ![]u8 {
    const frames = buf.len / 2;
    const cols: u32 = if (frames > fft_size) @intCast((frames - fft_size) / hop + 1) else 1;
    const bin_hz = @as(f32, @floatFromInt(sample_rate)) / @as(f32, fft_size);
    const freq_hi = @as(f32, @floatFromInt(sample_rate)) / 2.0;

    const mags = try allocator.alloc(f32, @as(usize, cols) * linear_bins);
    defer allocator.free(mags);

    const real = try allocator.alloc(f32, fft_size);
    defer allocator.free(real);
    const imag = try allocator.alloc(f32, fft_size);
    defer allocator.free(imag);

    var loudest: f32 = -1000;
    for (0..cols) |c| {
        const start = c * hop;
        @memset(imag, 0);
        for (0..fft_size) |i| {
            const idx = start + i;
            const mono = if (idx < frames) (buf[idx * 2] + buf[idx * 2 + 1]) * 0.5 else 0;
            const w = 0.5 - 0.5 * @cos(std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, fft_size));
            real[i] = mono * w;
        }
        ws.dsp.fft.fft(fft_size, real, imag);
        for (0..linear_bins) |b| {
            const m = ws.dsp.fft.magnitude(real[b], imag[b]);
            const db = 20.0 * std.math.log10(m + 1e-9);
            mags[c * linear_bins + b] = db;
            loudest = @max(loudest, db);
        }
    }

    // Log-spaced row -> bin lookup, built once: row 0 (bottom) is freq_lo,
    // row spec_h-1 (top) is Nyquist. Nearest-bin, not interpolated - this is
    // for spotting a problem at a glance, not measuring one.
    var row_bin: [spec_h]usize = undefined;
    for (0..spec_h) |row| {
        const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(spec_h - 1));
        const freq = freq_lo * std.math.pow(f32, freq_hi / freq_lo, t);
        row_bin[row] = std.math.clamp(@as(usize, @intFromFloat(freq / bin_hz)), 0, linear_bins - 1);
    }

    const img = try allocator.alloc(u8, cols * spec_h);
    const floor_db = loudest - 80.0; // 80 dB of visible range below the peak
    for (0..cols) |c| {
        for (0..spec_h) |row| {
            const db = mags[c * linear_bins + row_bin[row]];
            const norm = std.math.clamp((db - floor_db) / (loudest - floor_db), 0.0, 1.0);
            const y = spec_h - 1 - row; // low frequency at the bottom
            img[y * cols + c] = @intFromFloat(norm * 255.0);
        }
    }
    return img;
}

// ---------------------------------------------------------------------------
// Minimal PNG writer: signature + IHDR + one IDAT (zlib deflate over
// filter-type-0 scanlines) + IEND. 8-bit grayscale only - everything this
// tool draws is grayscale.

fn crcOf(kind: *const [4]u8, data: []const u8) u32 {
    var c = std.hash.crc.Crc32.init();
    c.update(kind);
    c.update(data);
    return c.final();
}

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    try w.writeInt(u32, crcOf(kind, data), .big);
}

fn writePng(allocator: std.mem.Allocator, io: std.Io, path: []const u8, width: u32, height: u32, gray: []const u8) !void {
    std.debug.assert(gray.len == @as(usize, width) * height);

    var raw = try allocator.alloc(u8, @as(usize, height) * (1 + width));
    defer allocator.free(raw);
    for (0..height) |y| {
        raw[y * (1 + width)] = 0; // filter type: None
        @memcpy(raw[y * (1 + width) + 1 ..][0..width], gray[y * width ..][0..width]);
    }

    var idat_buf = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer idat_buf.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var compress = try std.compress.flate.Compress.init(&idat_buf.writer, window, .zlib, .best);
    try compress.writer.writeAll(raw);
    try compress.finish();

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var file_buffer: [8192]u8 = undefined;
    var fw = file.writer(io, &file_buffer);
    const w = &fw.interface;

    try w.writeAll(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 0; // color type: grayscale
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", idat_buf.written());
    try writeChunk(w, "IEND", &.{});
    try w.flush();
}

// ---------------------------------------------------------------------------

fn sanitized(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| out[i] = if (c == '/') '_' else c;
    return out;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var target: ?[]const u8 = null;
    var note: u7 = 52;
    var vel: f32 = 0.8;
    var out_prefix: ?[]const u8 = null;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--note")) {
            note = std.fmt.parseInt(u7, args.next() orelse "52", 10) catch 52;
        } else if (std.mem.eql(u8, arg, "--vel")) {
            vel = std.fmt.parseFloat(f32, args.next() orelse "0.8") catch 0.8;
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_prefix = args.next();
        } else if (target == null) {
            target = arg;
        }
    }

    const name = target orelse {
        try w.print("Usage: audioviz <preset-name>|<kit-name>/<pad-name> [--note N] [--vel V] [--out PREFIX]\n", .{});
        try w.flush();
        return;
    };

    var buf: []Sample = undefined;
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        const kit_name = name[0..slash];
        const pad_name = name[slash + 1 ..];
        var variant: ?*const drum_kit.KitVariant = null;
        for (&drum_kit.variants) |*v| {
            if (std.ascii.eqlIgnoreCase(v.name, kit_name)) variant = v;
        }
        const v = variant orelse {
            try w.print("No such kit '{s}'.\n", .{kit_name});
            try w.flush();
            return;
        };
        var pad: ?usize = null;
        for (v.pads, 0..) |slot, i| {
            if (slot.kind != null and std.ascii.eqlIgnoreCase(slot.name, pad_name)) pad = i;
        }
        const p = pad orelse {
            try w.print("No such pad '{s}' in kit '{s}'.\n", .{ pad_name, kit_name });
            try w.flush();
            return;
        };
        buf = try renderPad(allocator, v, p);
    } else {
        var patch: ?ws.dsp.synth_presets.Preset = null;
        for (presets) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, name)) patch = p;
        }
        const p = patch orelse {
            try w.print("No such preset '{s}'.\n", .{name});
            try w.flush();
            return;
        };
        buf = try renderPreset(allocator, p, note, vel);
    }
    defer allocator.free(buf);

    const owned_prefix: ?[]u8 = if (out_prefix == null) try sanitized(allocator, name) else null;
    defer if (owned_prefix) |p| allocator.free(p);
    const prefix = out_prefix orelse owned_prefix.?;

    const wave = try renderWaveform(allocator, buf);
    defer allocator.free(wave);
    const wave_path = try std.fmt.allocPrint(allocator, "{s}_wave.png", .{prefix});
    defer allocator.free(wave_path);
    try writePng(allocator, io, wave_path, wave_w, wave_h, wave);

    const frames = buf.len / 2;
    const cols: u32 = if (frames > fft_size) @intCast((frames - fft_size) / hop + 1) else 1;
    const spec = try renderSpectrogram(allocator, buf);
    defer allocator.free(spec);
    const spec_path = try std.fmt.allocPrint(allocator, "{s}_spec.png", .{prefix});
    defer allocator.free(spec_path);
    try writePng(allocator, io, spec_path, cols, spec_h, spec);

    try w.print("wrote {s} ({d}x{d}) and {s} ({d}x{d})\n", .{ wave_path, wave_w, wave_h, spec_path, cols, spec_h });
    try w.flush();
}
