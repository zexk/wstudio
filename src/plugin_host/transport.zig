//! Shared-memory audio/event handoff between the DAW process and a
//! sandboxed CLAP/VST3 plugin child (see src/plugin_host/bridge.zig and
//! child_main.zig). This is the real-time path: process()/event()/reset()/
//! latencyFrames(), called every audio block. Everything else (param
//! enumeration, state save/load, GUI toggle) goes over rpc.zig instead.
//!
//! Protocol: two monotonically increasing sequence counters. The parent
//! writes a new input block then bumps `input_seq`; the child, once it
//! observes `input_seq` change, processes and bumps `output_seq` to match.
//! The parent only ever waits for the seq value it just published, so
//! there's no ABA risk even though both counters wrap eventually. Both
//! sides busy-wait with a bounded deadline - see `waitFor` below.
//!
//! ponytail: spin-wait, not a futex/eventfd wake. Simpler and matches this
//! codebase's existing spin-lock convention (see Sampler.processBlock's
//! tryLock spin), at the cost of full CPU use on the child's audio-service
//! thread whether or not a block is pending. Move to a real futex wait if
//! profiling shows idle bridged plugins burning a noticeable core each.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../core/types.zig");
const device_mod = @import("../dsp/device.zig");
const transport_mod = @import("../transport.zig");

pub const max_frames = types.max_block_frames;
pub const max_events = 64;

pub const WireEventKind = enum(u8) {
    none,
    note_on,
    note_off,
    all_off,
    cc,
    pitch_bend,
    automation_param,
    clap_param,
    vst3_param,
};

/// Flat, fixed-size stand-in for `dsp.device.Event` that can live in shared
/// memory. `cookie` is CLAP-only and opaque on both sides of the boundary -
/// wstudio never dereferences it, only hands it back to the plugin that
/// issued it (in the child), so passing the bit pattern through is safe.
/// `target` (the pointer-identity field `Event.clap_param`/`vst3_param`
/// carry) deliberately has no wire counterpart: the parent-side proxy
/// resolves the target==self check itself before publishing an event (see
/// `fromDeviceEvent`), since only it knows the pointer the event was
/// addressed to. The child always applies whatever event arrives to its
/// one and only instance.
pub const WireEvent = extern struct {
    kind: WireEventKind = .none,
    note: u8 = 0,
    velocity: f32 = 0,
    pan: f32 = 0,
    fine_cents: f32 = 0,
    release_scale: f32 = 1,
    cc: u8 = 0,
    cc_value: u8 = 0,
    bend: i16 = 0,
    param_id: u32 = 0,
    sample_offset: u32 = 0,
    cookie: ?*anyopaque = null,
    value: f64 = 0,
};

/// Converts an engine `Event` addressed at `self_ptr` into wire form, or
/// null if this device isn't the intended target (clap_param/vst3_param
/// broadcasts) or the event has no meaning for a hosted plugin
/// (set_param/set_param_abs/set_sidechain_buf/capture_pad - unhandled by
/// ClapPlugin/Vst3Plugin's own `handleEvent` today, same no-op here).
pub fn fromDeviceEvent(ev: device_mod.Event, self_ptr: *anyopaque) ?WireEvent {
    return switch (ev) {
        .note_on => |n| .{ .kind = .note_on, .note = n.note, .velocity = n.velocity, .pan = n.art.pan, .fine_cents = n.art.fine_cents, .release_scale = n.art.release_scale },
        .note_off => |n| .{ .kind = .note_off, .note = n.note },
        .all_off => .{ .kind = .all_off },
        .cc => |c| .{ .kind = .cc, .cc = c.cc, .cc_value = c.value },
        .pitch_bend => |b| .{ .kind = .pitch_bend, .bend = b.bend },
        .automation_param => |p| .{ .kind = .automation_param, .param_id = p.id, .sample_offset = p.sample_offset, .value = p.value },
        .clap_param => |p| if (p.target == self_ptr) .{ .kind = .clap_param, .param_id = p.id, .cookie = p.cookie, .value = p.value, .sample_offset = p.sample_offset } else null,
        .vst3_param => |p| if (p.target == self_ptr) .{ .kind = .vst3_param, .param_id = p.id, .value = p.value, .sample_offset = p.sample_offset } else null,
        else => null,
    };
}

/// Reconstructs a `device.Event` inside the child, addressed at the
/// child's own real plugin instance so the existing (unmodified)
/// `handleEvent` target check passes naturally.
pub fn toDeviceEvent(wire: WireEvent, self_ptr: *anyopaque) ?device_mod.Event {
    return switch (wire.kind) {
        .none => null,
        .note_on => .{ .note_on = .{ .note = @intCast(wire.note), .velocity = wire.velocity, .art = .{ .pan = wire.pan, .fine_cents = wire.fine_cents, .release_scale = wire.release_scale } } },
        .note_off => .{ .note_off = .{ .note = @intCast(wire.note) } },
        .all_off => .all_off,
        .cc => .{ .cc = .{ .cc = @intCast(wire.cc), .value = @intCast(wire.cc_value) } },
        .pitch_bend => .{ .pitch_bend = .{ .bend = wire.bend } },
        .automation_param => .{ .automation_param = .{ .id = wire.param_id, .value = @floatCast(wire.value), .sample_offset = wire.sample_offset } },
        .clap_param => .{ .clap_param = .{ .target = self_ptr, .id = wire.param_id, .cookie = wire.cookie, .value = wire.value, .sample_offset = wire.sample_offset } },
        .vst3_param => .{ .vst3_param = .{ .target = self_ptr, .id = wire.param_id, .value = wire.value, .sample_offset = wire.sample_offset } },
    };
}

/// Sent once, right after the child finishes loading the real plugin (see
/// child_main.zig's `writeHandshake`, read by `bridge.zig`'s `Bridge.spawn`).
/// Reports what only the child could resolve: CLAP's default-plugin-id
/// selection, either kind's display name, and the two facts the parent
/// needs to answer `pluginPath`-adjacent questions without an RPC round
/// trip per call (`audio_inputs_count`, `has_gui` - both CLAP-only, zero
/// for VST3, which has no GUI support and passes `instrument` as a load
/// argument instead of detecting it).
pub const Handshake = extern struct {
    audio_inputs_count: u32 = 0,
    has_gui: u8 = 0,
    /// Whether the plugin accepts note input - the only honest test of
    /// "can this be a track's instrument", and not derivable from
    /// `audio_inputs_count` (Surge XT is an instrument with an audio input).
    has_note_input: u8 = 0,
    id_len: u32 = 0,
    name_len: u32 = 0,
    id: [256]u8 = undefined,
    name: [256]u8 = undefined,
};

pub const TransportWire = extern struct {
    sample_rate: u32 = 48_000,
    tempo_bpm: f64 = 120.0,
    beats_per_bar: u8 = 4,
    beat_unit: u8 = 4,
    playing: bool = false,
    loop_enabled: bool = false,
    _pad: [4]u8 = .{ 0, 0, 0, 0 },
    position_frames: u64 = 0,
    loop_start_frames: u64 = 0,
    loop_end_frames: u64 = 0,

    pub fn from(t: *const transport_mod.Transport) TransportWire {
        return .{
            .sample_rate = t.sample_rate,
            .tempo_bpm = t.tempo_bpm,
            .beats_per_bar = t.time_signature.beats_per_bar,
            .beat_unit = t.time_signature.beat_unit,
            .playing = t.playing,
            .loop_enabled = t.loop_enabled,
            .position_frames = t.position_frames,
            .loop_start_frames = t.loop_start_frames,
            .loop_end_frames = t.loop_end_frames,
        };
    }

    pub fn toTransport(self: TransportWire) transport_mod.Transport {
        return .{
            .sample_rate = self.sample_rate,
            .tempo_bpm = self.tempo_bpm,
            .time_signature = .{ .beats_per_bar = self.beats_per_bar, .beat_unit = self.beat_unit },
            .playing = self.playing,
            .position_frames = self.position_frames,
            .loop_enabled = self.loop_enabled,
            .loop_start_frames = self.loop_start_frames,
            .loop_end_frames = self.loop_end_frames,
        };
    }
};

/// The whole cross-process shared region. `extern struct` pins field
/// layout so two independently-linked executables (the main `wstudio`
/// binary and the `plugin-host-bridge` child) that both compile this same
/// source against the same target agree on offsets byte for byte.
///
/// Parent-written / child-read fields and child-written / parent-read
/// fields are laid out in two groups so each side's writes stay under one
/// cache line boundary as much as this struct size allows; correctness
/// doesn't depend on that, it's just less false sharing.
pub const SharedBlock = extern struct {
    // --- parent writes, child reads ---
    input_seq: u64 align(64) = 0,
    frames: u32 = 0,
    input_channels: u8 = 2,
    _pad0: [3]u8 = .{ 0, 0, 0 },
    xport: TransportWire = .{},
    event_count: u32 = 0,
    events: [max_events]WireEvent = [_]WireEvent{.{}} ** max_events,
    audio_in: [2][max_frames]f32 = undefined,
    reset_requested: u8 = 0,

    // --- child writes, parent reads ---
    output_seq: u64 align(64) = 0,
    audio_out: [2][max_frames]f32 = undefined,

    pub const shm_size = @sizeOf(SharedBlock);
};

/// Raw monotonic clock read. This codebase's usual wall-clock access goes
/// through `std.Io.Timestamp.now(io, .awake)` (see gui/gui.zig, tui/tui.zig),
/// but that requires an `Io` instance threaded down to the caller. The
/// audio thread and the reaper/tick threads this module runs on don't have
/// one and shouldn't need one for a plain clock read, so this calls the
/// same syscall `Io.Threaded`'s `awake` clock uses directly.
///
/// Per OS, not through `std.os.linux`: the sandbox this module serves is
/// Linux-only, but the module is compiled and unit-tested on every platform.
/// Raw Linux syscall numbers on macOS returned nonsense that made the
/// `@intCast` below panic, and Windows has no `clock_gettime` at all.
pub fn monotonicNs() u64 {
    switch (builtin.os.tag) {
        .windows => {
            var frequency: u64 = 0;
            var counter: u64 = 0;
            if (!std.os.windows.ntdll.RtlQueryPerformanceFrequency(@ptrCast(&frequency)).toBool()) return 0;
            if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(@ptrCast(&counter)).toBool()) return 0;
            if (frequency == 0) return 0;
            return @intCast(@divTrunc(@as(u128, counter) * std.time.ns_per_s, frequency));
        },
        else => {
            var ts: std.posix.timespec = undefined;
            if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        },
    }
}

/// Raw sleep, same rationale as `monotonicNs`: `std.Thread.sleep`/`Io.sleep`
/// both need an `Io` in this build, which the child's tick loop doesn't
/// otherwise carry.
pub fn sleepNs(ns: u64) void {
    switch (builtin.os.tag) {
        // Millisecond granularity is all Sleep offers, rounded up so a short
        // request never becomes a busy spin.
        .windows => std.os.windows.kernel32.Sleep(@intCast((ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms)),
        else => {
            const ts: std.posix.timespec = .{
                .sec = @intCast(ns / std.time.ns_per_s),
                .nsec = @intCast(ns % std.time.ns_per_s),
            };
            _ = std.posix.system.nanosleep(&ts, null);
        },
    }
}

/// Busy-wait (spin, then yield in short bursts) until `predicate.check()`
/// is true or `deadline_ns` (a `monotonicNs()` value) passes. Returns
/// whether the predicate became true. Never blocks unboundedly - the
/// caller decides what "the plugin is stalled this block" means.
pub fn waitUntil(deadline_ns: u64, predicate: anytype) bool {
    while (true) {
        if (predicate.check()) return true;
        if (monotonicNs() >= deadline_ns) return predicate.check();
        var spins: u32 = 0;
        while (spins < 200) : (spins += 1) {
            std.atomic.spinLoopHint();
            if (predicate.check()) return true;
        }
        std.Thread.yield() catch {};
    }
}

test "WireEvent round-trips note_on through toDeviceEvent" {
    var target: u32 = 0;
    const self_ptr: *anyopaque = @ptrCast(&target);
    const ev: device_mod.Event = .{ .note_on = .{ .note = 64, .velocity = 0.75, .art = .{ .pan = 0.2, .fine_cents = 3, .release_scale = 1.5 } } };
    const wire = fromDeviceEvent(ev, self_ptr).?;
    try std.testing.expectEqual(WireEventKind.note_on, wire.kind);
    const back = toDeviceEvent(wire, self_ptr).?;
    try std.testing.expectEqual(@as(u7, 64), back.note_on.note);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), back.note_on.velocity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), back.note_on.art.pan, 1e-6);
}

test "fromDeviceEvent drops clap_param not addressed at this instance" {
    var mine: u32 = 0;
    var other: u32 = 0;
    const self_ptr: *anyopaque = @ptrCast(&mine);
    const other_ptr: *anyopaque = @ptrCast(&other);
    const ev: device_mod.Event = .{ .clap_param = .{ .target = other_ptr, .id = 5, .cookie = null, .value = 1.0 } };
    try std.testing.expect(fromDeviceEvent(ev, self_ptr) == null);
    const mine_ev: device_mod.Event = .{ .clap_param = .{ .target = self_ptr, .id = 5, .cookie = null, .value = 1.0 } };
    try std.testing.expect(fromDeviceEvent(mine_ev, self_ptr) != null);
}

test "WireEvent preserves parameter sample offset" {
    var target: u32 = 0;
    const self_ptr: *anyopaque = @ptrCast(&target);
    const ev: device_mod.Event = .{ .automation_param = .{ .id = 7, .value = 0.5, .sample_offset = 123 } };
    const back = toDeviceEvent(fromDeviceEvent(ev, self_ptr).?, self_ptr).?;
    try std.testing.expectEqual(@as(u32, 123), back.automation_param.sample_offset);
}

test "monotonicNs advances and sleepNs actually sleeps" {
    const t0 = monotonicNs();
    sleepNs(10 * std.time.ns_per_ms);
    const t1 = monotonicNs();
    try std.testing.expect(t1 > t0);
    try std.testing.expect(t1 - t0 >= 5 * std.time.ns_per_ms);
}

test "TransportWire round-trips through Transport" {
    var t = transport_mod.Transport{ .sample_rate = 44_100, .tempo_bpm = 128, .playing = true };
    t.time_signature = .{ .beats_per_bar = 3, .beat_unit = 8 };
    t.position_frames = 12345;
    const wire = TransportWire.from(&t);
    const back = wire.toTransport();
    try std.testing.expectEqual(t.sample_rate, back.sample_rate);
    try std.testing.expectEqual(t.tempo_bpm, back.tempo_bpm);
    try std.testing.expectEqual(t.time_signature.beats_per_bar, back.time_signature.beats_per_bar);
    try std.testing.expectEqual(t.playing, back.playing);
    try std.testing.expectEqual(t.position_frames, back.position_frames);
}
