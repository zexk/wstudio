//! Sweeps every CLAP and VST3 plugin on the search paths through the host
//! lifecycle the beta.10 release gate names: scan, load, activate, process,
//! automate, save state, reload state, render again, and tear down.
//!
//! The bundled fixture plugins prove the host against code this repository
//! wrote. This proves it against plugins it did not: the `wstudio-test-plugins`
//! bundle in `flake.nix` (LSP, Surge XT, Odin 2, sfizz, CHOW tape, Uhhyou) is
//! the intended corpus, pointed at through `CLAP_PATH`/`VST3_PATH` or a
//! positional argument.
//!
//! Usage: `zig build plugincheck -- [dir ...] [--direct] [--verbose]`
//! Plugins load sandboxed by default, the way a stock session loads them.
//! `--direct` runs them in-process instead, which is the mode that shows a
//! misbehaving plugin's own crash rather than a lost bridge child.
//!
//! Exit code is non-zero only for a host fault. A plugin driven to the ends
//! of its own declared parameter ranges may answer with an absurd level, and
//! a plugin the sandbox contains may crash: both are reported as notes, not
//! failures, because neither is something this host can fix. A plugin that
//! fails to load is reported the same way: the corpus can contain bundles
//! this machine's architecture cannot open, which is a fact about the bundle.

const std = @import("std");
const ws = @import("wstudio");

const Sample = ws.types.Sample;
const sample_rate: u32 = 48_000;
const block_frames: usize = 512;
/// Cap on automation sweeps per plugin. Surge XT alone exposes hundreds of
/// parameters, and the interesting failure (a value at either end of the
/// declared range breaking the plugin) shows up in the first handful.
const max_params_swept: usize = 8;
/// A finite but absurd sample. `processBlock` scrubs non-finite output before
/// the host ever sees it, so magnitude is what is left to check: nothing fed
/// a 0.25-amplitude sine should answer with this.
const insane_peak: Sample = 1000.0;

const Tally = struct {
    scanned: usize = 0,
    loaded: usize = 0,
    load_failed: usize = 0,
    passed: usize = 0,
    /// Host defects: a lifecycle step this host got wrong. These fail the run.
    host_faults: usize = 0,
    /// The plugin's own behaviour, not the host's: an absurd output level
    /// from a parameter driven to the end of its declared range, or a crash
    /// the sandbox contained. Reported, never fatal - a third-party plugin's
    /// bugs are not something a release gate here can fix, and the sandbox
    /// holding is the result this check wants from them.
    plugin_faults: usize = 0,
};

const Failure = error{ InsanePeak, StateRoundTrip };

/// Whether a failed step says something about this host or about the plugin.
/// Under `--direct` there is no sandbox to contain anything, so a crash is a
/// crash and everything counts against the host.
fn isPluginFault(err: anyerror, step: []const u8, direct: bool) bool {
    if (err == Failure.InsanePeak and std.mem.eql(u8, step, "automate")) return true;
    if (direct) return false;
    return switch (err) {
        error.PluginCrashed, error.RpcClosed, error.RpcCallFailed, error.RpcTimeout => true,
        else => false,
    };
}

fn record(
    tally: *Tally,
    out: *std.Io.Writer,
    format: []const u8,
    name: []const u8,
    vendor: []const u8,
    err: anyerror,
    step: []const u8,
    direct: bool,
) !void {
    const plugin_fault = isPluginFault(err, step, direct);
    if (plugin_fault) tally.plugin_faults += 1 else tally.host_faults += 1;
    try out.print("{s}  {s} {s} ({s}): {s} at {s}\n", .{
        if (plugin_fault) "note" else "FAIL",
        format,
        name,
        vendor,
        @errorName(err),
        step,
    });
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();

    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    defer roots.deinit(init.gpa);
    var verbose = false;
    var direct = false;
    var gui_seconds: u32 = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--direct")) {
            direct = true;
        } else if (std.mem.startsWith(u8, arg, "--gui=")) {
            gui_seconds = std.fmt.parseInt(u32, arg["--gui=".len..], 10) catch 0;
        } else {
            try roots.append(init.gpa, arg);
        }
    }
    if (gui_seconds != 0) return openGuis(init, roots.items, gui_seconds, direct);
    if (direct) ws.plugin_host.bridge.sandbox_enabled.store(false, .release);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;

    var tally: Tally = .{};
    try sweepClap(init, roots.items, &tally, out, verbose, direct);
    try sweepVst3(init, roots.items, &tally, out, verbose, direct);

    try out.print("\nplugins   {d} scanned, {d} loaded, {d} unloadable\n", .{
        tally.scanned,
        tally.loaded,
        tally.load_failed,
    });
    try out.print("lifecycle {d} passed, {d} host fault(s), {d} plugin-side note(s), {s} hosting\n", .{
        tally.passed,
        tally.host_faults,
        tally.plugin_faults,
        if (direct) "in-process" else "sandboxed",
    });
    try out.flush();

    if (tally.host_faults != 0) return error.PluginLifecycleFailed;
    if (tally.scanned == 0) return error.NoPluginsFound;
}

/// Open each CLAP editor in turn and hold it for `seconds`, servicing the
/// main thread the way a session does. Nothing here can assert a window
/// looks right - that is what an X tool inspecting the live window is for
/// (`xwininfo -root -tree` while this runs). What it does give is a
/// reproducible way to put a real plugin editor on screen without driving
/// the whole DAW.
fn openGuis(init: std.process.Init, roots: []const []const u8, seconds: u32, direct: bool) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;
    if (!direct) ws.plugin_host.bridge.sandbox_enabled.store(false, .release);

    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    var paths: []const []const u8 = roots;
    if (roots.len == 0) {
        owned = try ws.dsp.clap_scan.searchPaths(init.gpa, init.environ_map);
        paths = owned.items;
    }
    defer ws.dsp.clap_scan.freeSearchPaths(init.gpa, &owned);

    var registry = ws.dsp.clap_scan.Registry.init(init.gpa);
    defer registry.deinit();
    try registry.scanPaths(init.io, paths);

    for (registry.plugins.items) |info| {
        const plugin = ws.dsp.ClapPlugin.load(init.gpa, info.path, info.id, sample_rate) catch continue;
        defer plugin.deinit();
        if (!plugin.hasGui()) continue;
        _ = plugin.serviceMainThread();
        const shown = plugin.toggleGui() catch false;
        try out.print("gui   {s}: {s}\n", .{ info.name, if (shown) "open" else "refused" });
        try out.flush();
        if (!shown) continue;
        var elapsed: u32 = 0;
        while (elapsed < seconds * 20) : (elapsed += 1) {
            _ = plugin.serviceMainThread();
            ws.plugin_host.transport.sleepNs(50 * std.time.ns_per_ms);
        }
        _ = plugin.toggleGui() catch {};
        // One editor per run: a single `.clap` binary can hold hundreds of
        // plugins (LSP does), and holding each in turn would outlast any
        // sitting to inspect the first.
        return;
    }
}

fn sweepClap(
    init: std.process.Init,
    roots: []const []const u8,
    tally: *Tally,
    out: *std.Io.Writer,
    verbose: bool,
    direct: bool,
) !void {
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    var paths: []const []const u8 = roots;
    if (roots.len == 0) {
        owned = try ws.dsp.clap_scan.searchPaths(init.gpa, init.environ_map);
        paths = owned.items;
    }
    defer ws.dsp.clap_scan.freeSearchPaths(init.gpa, &owned);

    var registry = ws.dsp.clap_scan.Registry.init(init.gpa);
    defer registry.deinit();
    try registry.scanPaths(init.io, paths);

    for (registry.plugins.items) |info| {
        tally.scanned += 1;
        const plugin = ws.dsp.ClapPlugin.load(init.gpa, info.path, info.id, sample_rate) catch |err| {
            tally.load_failed += 1;
            try out.print("load  CLAP {s}: {s}\n", .{ info.name, @errorName(err) });
            continue;
        };
        defer plugin.deinit();
        tally.loaded += 1;

        // A CLAP plugin may defer work to a host callback on the main thread;
        // a plugin that never gets serviced is not the plugin a session runs.
        _ = plugin.serviceMainThread();
        var step: []const u8 = "load";
        checkClapLifecycle(init.gpa, plugin, &step) catch |err| {
            try record(tally, out, "CLAP", info.name, info.vendor, err, step, direct);
            continue;
        };
        tally.passed += 1;
        if (verbose) try out.print("ok    CLAP {s} ({d} params)\n", .{ info.name, plugin.parameterCount() });
    }
}

fn checkClapLifecycle(gpa: std.mem.Allocator, plugin: *ws.dsp.ClapPlugin, step: *[]const u8) !void {
    var buf: [block_frames * 2]Sample = undefined;
    step.* = "process";
    if (plugin.acceptsNotes()) plugin.handleEvent(.{ .note_on = .{ .note = 60, .velocity = 0.8 } });
    try renderBlock(plugin, &buf);

    step.* = "automate";
    // Index-addressed, not id-addressed, because the cookie a CLAP plugin
    // handed out with the parameter has to travel back with every value -
    // `Rack.FxUnit.handleEvent` sources it the same way. Odin 2 dereferences
    // its cookie without a null check, so a sweep that omitted it crashed the
    // plugin on a value the plugin itself declared legal.
    for (0..@min(plugin.parameterCount(), max_params_swept)) |i| {
        const info = plugin.parameterInfo(@intCast(i)) orelse continue;
        for ([_]f64{ info.min_value, info.max_value }) |value| {
            plugin.setParameter(info.id, info.cookie, value);
            try renderBlock(plugin, &buf);
        }
    }

    step.* = "save-state";
    if (try plugin.saveState(gpa)) |state| {
        defer gpa.free(state);
        step.* = "load-state";
        if (!try plugin.loadState(state)) return Failure.StateRoundTrip;
        try renderBlock(plugin, &buf);
    }

    step.* = "reset";
    if (plugin.acceptsNotes()) plugin.handleEvent(.all_off);
    plugin.reset();
    try renderBlock(plugin, &buf);
    step.* = "teardown";
}

fn sweepVst3(
    init: std.process.Init,
    roots: []const []const u8,
    tally: *Tally,
    out: *std.Io.Writer,
    verbose: bool,
    direct: bool,
) !void {
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    var paths: []const []const u8 = roots;
    if (roots.len == 0) {
        owned = try ws.vst3.scan.searchPaths(init.gpa, init.environ_map);
        paths = owned.items;
    }
    defer ws.vst3.scan.freeSearchPaths(init.gpa, &owned);

    var registry = ws.vst3.scan.Registry.init(init.gpa);
    defer registry.deinit();
    try registry.scanPaths(init.io, paths);

    for (registry.plugins.items) |info| {
        tally.scanned += 1;
        const plugin = ws.vst3.Vst3Plugin.load(
            init.gpa,
            info.path,
            &info.id,
            sample_rate,
            info.instrument,
        ) catch |err| {
            tally.load_failed += 1;
            try out.print("load  VST3 {s}: {s}\n", .{ info.name, @errorName(err) });
            continue;
        };
        defer plugin.deinit();
        tally.loaded += 1;

        var step: []const u8 = "load";
        checkVst3Lifecycle(init.gpa, plugin, info.instrument, &step) catch |err| {
            try record(tally, out, "VST3", info.name, info.vendor, err, step, direct);
            continue;
        };
        tally.passed += 1;
        if (verbose) try out.print("ok    VST3 {s}\n", .{info.name});
    }
}

fn checkVst3Lifecycle(
    gpa: std.mem.Allocator,
    plugin: *ws.vst3.Vst3Plugin,
    instrument: bool,
    step: *[]const u8,
) !void {
    var buf: [block_frames * 2]Sample = undefined;
    step.* = "process";
    if (instrument) plugin.handleEvent(.{ .note_on = .{ .note = 60, .velocity = 0.8 } });
    try renderBlock(plugin, &buf);

    step.* = "automate";
    for (plugin.automationParams(), 0..) |param, i| {
        if (i >= max_params_swept) break;
        for ([_]f32{ param.range[0], param.range[1] }) |value| {
            plugin.setParameter(param.id, value);
            try renderBlock(plugin, &buf);
        }
    }

    // VST3 splits processor and controller state, and a host that saves only
    // the processor half loses every controller-side edit on reopen.
    step.* = "save-state";
    const component = try plugin.saveComponentState(gpa);
    defer gpa.free(component);
    const controller = try plugin.saveControllerState(gpa);
    defer if (controller) |bytes| gpa.free(bytes);
    step.* = "load-state";
    try plugin.loadState(component, controller orelse &.{});
    try renderBlock(plugin, &buf);

    step.* = "reset";
    if (instrument) plugin.handleEvent(.all_off);
    plugin.reset();
    try renderBlock(plugin, &buf);
    step.* = "teardown";
}

/// One block of a modest sine through the plugin, checked for a level no
/// plugin fed this signal has any business producing.
fn renderBlock(plugin: anytype, buf: []Sample) !void {
    for (buf, 0..) |*s, i| {
        const phase = @as(f32, @floatFromInt(i / 2)) / @as(f32, @floatFromInt(sample_rate));
        s.* = 0.25 * @sin(2.0 * std.math.pi * 220.0 * phase);
    }
    plugin.processBlock(buf);
    for (buf) |s| {
        if (@abs(s) > insane_peak) return Failure.InsanePeak;
    }
}
