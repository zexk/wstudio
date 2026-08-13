//! Callback-time benchmark for the audio thread.
//!
//! Run with `zig build bench` (add `-Doptimize=ReleaseFast`; a debug build's
//! numbers say nothing about the real callback). Times `Engine.process` the
//! way the audio backend calls it - one block at a time, nothing else on the
//! thread - and reports p50/p99/max plus what fraction of the block's deadline
//! the p99 eats. A run over 100% at the p99 is a project that will drop out on
//! that buffer size.
//!
//! The scenarios exist to answer the open findings in `work/performance-scan.md`,
//! all of which say "measure first":
//!
//!   * the loaded project at 64/128/512 frames - the baseline profile, and the
//!     buffer-size sweep findings 3-6 all share.
//!   * tracks x aux sends (finding 4): silent poly_synth tracks, so what's
//!     measured is the per-track routing/copy/PDC/mix work, not synth DSP.
//!   * blank-track scaling to 8192 (finding 6): every track early-outs of
//!     `renderOneTrack`, so this isolates the per-block scans that run before
//!     any audio does - solo scan, sidechain pre-scan, phase-2 dedup.
//!   * meters (finding 5): the loudness/correlation push, timed on its own,
//!     against the whole-callback numbers above.
//!   * hosted plugins in-process against bridged (finding 3), if a CLAP
//!     plugin path is passed as the second argument - `zig build bench` wires
//!     the repo's own CLAP test plugin, whose DSP is one multiply, so what is
//!     measured is the round trip and not the plugin.

const std = @import("std");
const ws = @import("wstudio");

const warmup_blocks = 64;
/// Every run renders the same span of audio rather than the same number of
/// blocks, so buffer sizes stay comparable: a project's cost varies with where
/// the playhead is (the demo's intro is one drum track, its middle is four),
/// and 2000 blocks of 64 frames covers a quarter of what 2000 of 256 does.
const measure_frames = 2000 * 128;
const max_samples = measure_frames / 64;
/// Blocks per paced row - each one costs its own real-time duration, so this
/// is a second of audio at 128 frames rather than the free-running count.
const paced_blocks = 400;

const Stats = struct {
    p50_us: f64,
    p99_us: f64,
    max_us: f64,
    /// p99 as a fraction of the block deadline, in percent.
    budget_pct: f64,
};

/// Sorts `samples` in place.
fn summarize(samples: []i96, frames: u32, sample_rate: u32) Stats {
    std.mem.sort(i96, samples, {}, std.sort.asc(i96));
    const us = struct {
        fn f(ns: i96) f64 {
            return @as(f64, @floatFromInt(@as(i64, @intCast(ns)))) / 1000.0;
        }
    }.f;
    const budget_us = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(sample_rate)) * 1_000_000.0;
    const p99 = us(samples[samples.len * 99 / 100]);
    return .{
        .p50_us = us(samples[samples.len / 2]),
        .p99_us = p99,
        .max_us = us(samples[samples.len - 1]),
        .budget_pct = p99 / budget_us * 100.0,
    };
}

/// `pace` sleeps out the rest of each block's deadline instead of running the
/// next one immediately. Everything in-process measures the same either way,
/// so the fast free-running loop is fine there - but a bridged plugin's child
/// process needs the gap between callbacks to do its work, and hammering
/// blocks back to back asks a whole pool of children for many times real-time
/// throughput and reads as a bridge collapse that a real session would not
/// see. Paced runs are shorter, since each block now costs its own wall time.
fn measure(io: std.Io, session: *ws.Session, frames: u32, scratch: []i96, pace: bool) Stats {
    var block: [ws.types.max_block_frames * ws.engine.channels]ws.types.Sample = undefined;
    const out = block[0 .. frames * ws.engine.channels];
    const block_ns: i96 = @intCast(@divTrunc(@as(u64, frames) * std.time.ns_per_s, session.project.sample_rate));
    const wanted: usize = if (pace) paced_blocks else measure_frames / frames;
    const samples = scratch[0..@min(scratch.len, wanted)];
    session.engine.transport.seekFrames(0);
    for (0..warmup_blocks) |_| session.engine.process(out);
    session.engine.transport.seekFrames(0);
    for (samples) |*slot| {
        const start = std.Io.Clock.awake.now(io);
        session.engine.process(out);
        const end = std.Io.Clock.awake.now(io);
        slot.* = start.durationTo(end).nanoseconds;
        if (pace) {
            const target: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = start.nanoseconds + block_ns }, .clock = .awake };
            target.wait(io) catch {};
        }
    }
    return summarize(samples, frames, session.project.sample_rate);
}

fn row(w: *std.Io.Writer, name: []const u8, frames: u32, s: Stats) !void {
    try w.print("{s: <34}{d: >6}{d: >10.1}{d: >10.1}{d: >10.1}{d: >9.1}%\n", .{ name, frames, s.p50_us, s.p99_us, s.max_us, s.budget_pct });
}

fn header(w: *std.Io.Writer, title: []const u8) !void {
    try w.print("\n{s}\n{s: <34}{s: >6}{s: >10}{s: >10}{s: >10}{s: >10}\n", .{ title, "scenario", "block", "p50 us", "p99 us", "max us", "budget" });
}

/// `tracks` silent tracks that all render, each with `sends` post-fader aux
/// sends to master. `instrument` is what fills the chain: `.empty` plus one
/// utility FX (a gain multiply) leaves routing as nearly the whole cost, which
/// is what finding 4 is about; `.poly_synth` on top of that shows what an idle
/// instrument adds. Nothing plays a note in either case.
fn routedSession(gpa: std.mem.Allocator, tracks: u16, sends: u8, instrument: ws.InstrumentKind) !ws.Session {
    var session = try ws.Session.initDefault(gpa);
    errdefer session.deinit();
    while (session.project.tracks.items.len < tracks) _ = try session.addTrack("bench");
    for (0..tracks) |i| {
        const idx: u16 = @intCast(i);
        if (instrument != .empty) try session.setInstrument(idx, instrument);
        const rack = session.racks.items[idx];
        _ = try rack.fx.insert(gpa, 0, .utility, session.project.sample_rate);
        session.syncTrackChain(idx, rack);
        for (0..sends) |slot| session.setTrackSend(idx, @intCast(slot), .master, -6.0, false);
    }
    session.engine.transport.play();
    return session;
}

/// One CLAP instance per track, `tracks` of them. Bridged or not depends on
/// `bridge.sandbox_enabled`, which `ClapPlugin.load` reads for itself.
fn pluginSession(gpa: std.mem.Allocator, tracks: u16, plugin_path: []const u8, plugin_id: []const u8) !ws.Session {
    var session = try ws.Session.initDefault(gpa);
    errdefer session.deinit();
    while (session.project.tracks.items.len < tracks) _ = try session.addTrack("bench");
    for (0..tracks) |i| {
        const idx: u16 = @intCast(i);
        const rack = session.racks.items[idx];
        _ = try rack.fx.insertClap(gpa, 0, plugin_path, plugin_id, session.project.sample_rate);
        session.syncTrackChain(idx, rack);
    }
    session.engine.transport.play();
    return session;
}

/// `tracks` blank tracks - no instrument, no clips, so `renderOneTrack`
/// returns immediately for every one of them.
fn blankSession(gpa: std.mem.Allocator, tracks: u16) !ws.Session {
    var session = try ws.Session.initDefault(gpa);
    errdefer session.deinit();
    while (session.project.tracks.items.len < tracks) _ = try session.addTrack("bench");
    session.engine.transport.play();
    return session;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const project_path = args.next() orelse "demo.wsj";
    // Optional: a CLAP binary and the id to instantiate from it. The id is
    // not optional in-process - an empty one means "plugin literally named
    // ''" there, while the bridge reads it as "pick the default".
    const plugin_path = args.next();
    const plugin_id = args.next() orelse "";

    const samples = try gpa.alloc(i96, max_samples);
    defer gpa.free(samples);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const w = &stdout_writer.interface;

    if (@import("builtin").mode == .Debug)
        try w.writeAll("warning: debug build; rebuild with -Doptimize=ReleaseFast for meaningful numbers\n");

    var name_buf: [64]u8 = undefined;

    // Baseline: a real project across the buffer sizes users actually pick.
    try header(w, "project playback");
    {
        var session = try ws.persist.load(gpa, io, project_path);
        defer session.deinit();
        session.engine.transport.play();
        var demo_p50: f64 = 0;
        for ([_]u32{ 64, 128, 512 }) |frames| {
            const s = measure(io, &session, frames, samples, false);
            if (frames == 128) demo_p50 = s.p50_us;
            try row(w, project_path, frames, s);
        }

        // Finding 5: the always-on master meters, timed alone at 128 frames
        // against the p50 above. Same meters the engine owns, fed the same
        // block, so this is the share of a callback they account for.
        var loudness = ws.dsp.LoudnessMeter.init(session.project.sample_rate);
        var correlation = ws.dsp.StereoCorrelation.init(session.project.sample_rate);
        var block: [128 * ws.engine.channels]ws.types.Sample = undefined;
        for (&block, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
        for (0..warmup_blocks) |_| {
            correlation.push(&block);
            loudness.push(&block);
        }
        const meter_samples = samples[0 .. measure_frames / 128];
        for (meter_samples) |*slot| {
            const start = std.Io.Clock.awake.now(io);
            correlation.push(&block);
            loudness.push(&block);
            slot.* = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        }
        const s = summarize(meter_samples, 128, session.project.sample_rate);
        try header(w, "master meters alone (finding 5)");
        try row(w, "correlation + loudness push", 128, s);
        if (demo_p50 > 0)
            try w.print("  = {d:.1}% of this project's p50 callback at 128 frames\n", .{s.p50_us / demo_p50 * 100.0});
    }

    // Finding 4: routing cost as tracks and sends scale.
    try header(w, "silent track x send scaling (finding 4)");
    for ([_]u16{ 8, 32, 128 }) |tracks| {
        for ([_]u8{ 0, 1, 4 }) |sends| {
            var session = try routedSession(gpa, tracks, sends, .empty);
            defer session.deinit();
            const name = try std.fmt.bufPrint(&name_buf, "{d} tracks, {d} sends", .{ tracks, sends });
            try row(w, name, 128, measure(io, &session, 128, samples, false));
        }
    }
    {
        // Same routing, plus an idle synth per track: the gap against
        // "128 tracks, 0 sends" is what a voiceless instrument costs.
        var session = try routedSession(gpa, 128, 0, .poly_synth);
        defer session.deinit();
        try row(w, "128 tracks, 0 sends, idle synth", 128, measure(io, &session, 128, samples, false));
    }

    // Finding 3: what the out-of-process bridge costs per instance. Same
    // plugin, same count, once loaded in-process and once sandboxed - the
    // difference is the shared-memory copies plus the synchronous wait on the
    // child, which the engine pays serially because chains render in order.
    if (plugin_path) |path| {
        try header(w, "hosted CLAP plugins, in-process vs bridged (finding 3)");
        for ([_]bool{ false, true }) |sandboxed| {
            ws.plugin_host.bridge.sandbox_enabled.store(sandboxed, .release);
            for ([_]u16{ 1, 4, 8, 16 }) |count| {
                var session = pluginSession(gpa, count, path, plugin_id) catch |err| {
                    try w.print("{d} plugins: {s}\n", .{ count, @errorName(err) });
                    continue;
                };
                defer session.deinit();
                const name = try std.fmt.bufPrint(&name_buf, "{d} plugins, {s}", .{ count, if (sandboxed) "bridged" else "in-process" });
                try row(w, name, 128, measure(io, &session, 128, samples, true));
            }
        }
        ws.plugin_host.bridge.sandbox_enabled.store(true, .release);
    }

    // Finding 6: per-block scans that run whether or not a track renders.
    try header(w, "blank track scaling (finding 6)");
    for ([_]u16{ 8, 64, 512, 2048, 8192 }) |tracks| {
        var session = try blankSession(gpa, tracks);
        defer session.deinit();
        const name = try std.fmt.bufPrint(&name_buf, "{d} blank tracks", .{tracks});
        try row(w, name, 128, measure(io, &session, 128, samples, false));
    }

    try w.flush();
}
