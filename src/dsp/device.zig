//! Device interface: the common shape of every built-in instrument
//! and effect. Tracks hold a chain of devices; the engine drives them
//! on the audio thread, so implementations must not allocate or block
//! inside `process` - buffers are allocated up front at init time.

const std = @import("std");
const types = @import("../core/types.zig");

/// Clamp `val` to `[lo, hi]`, falling back to `default` if it's NaN/inf -
/// every FX unit's parameter setter needs this same non-finite guard since
/// params can arrive from untrusted persisted state or automation curves.
pub fn sanitizeParam(val: f32, lo: f32, hi: f32, default: f32) f32 {
    return if (std.math.isFinite(val)) std.math.clamp(val, lo, hi) else default;
}

pub fn smoothingCoefMs(ms: f32, sample_rate: f32) f32 {
    return @exp(-1.0 / (ms * 0.001 * sample_rate));
}

/// Per-note expression a sequenced note carries beyond pitch and velocity.
/// Every field's default is its neutral value, so a live keyboard press, a
/// MIDI note or an arpeggiated step - none of which supply any of this -
/// sounds exactly as it did before per-note expression existed.
///
/// Kept as one struct rather than three loose parameters so growing it
/// later doesn't touch the ~70 `Event.note_on` construction sites again.
pub const Articulation = struct {
    /// -1 hard left .. +1 hard right, applied on top of whatever pan the
    /// voice already has (a synth's unison spread, a sampler's own pan).
    pan: f32 = 0.0,
    /// Detune in cents, on top of the instrument's own tuning. This is the
    /// per-note counterpart of a patch's detune knob, not a pitch bend:
    /// it's fixed for the note's whole life.
    fine_cents: f32 = 0.0,
    /// Multiplies the instrument's amp-envelope release time, so one note
    /// can ring past the patch's own tail without a second patch. 1 = the
    /// patch's release exactly.
    release_scale: f32 = 1.0,

    pub const neutral: Articulation = .{};

    /// Clamps to the ranges the editors and the loader both enforce, so a
    /// hand-edited project or a Lua caller can't push a voice somewhere the
    /// UI has no way to show or undo.
    pub fn clamped(self: Articulation) Articulation {
        return .{
            .pan = sanitizeParam(self.pan, -1.0, 1.0, 0.0),
            .fine_cents = sanitizeParam(self.fine_cents, -100.0, 100.0, 0.0),
            .release_scale = sanitizeParam(self.release_scale, 0.1, 4.0, 1.0),
        };
    }

    pub fn isNeutral(self: Articulation) bool {
        return self.pan == 0.0 and self.fine_cents == 0.0 and self.release_scale == 1.0;
    }
};

pub const Event = union(enum) {
    note_on: struct { note: u7, velocity: f32, art: Articulation = .neutral },
    note_off: struct { note: u7 },
    all_off,
    cc: struct { cc: u7, value: u7 },
    pitch_bend: struct { bend: i16 },
    /// Nudge editor parameter `id` by `steps` (signed). Applied on the audio
    /// thread so UI edits never race the reader - see PolySynth.adjustParam.
    /// `id` is u16 everywhere: DrumMachine.paramId packs a pad index (up to
    /// 64) into the high bits, and PolySynth's own flat id space ran out of
    /// u8 room once the per-LFO sync/retrigger/slew blocks landed. Every
    /// device's adjustParam/setParamAbsolute takes the same u16, so no
    /// truncation happens anywhere between the editor and the device.
    set_param: struct { id: u16, steps: i32 },
    /// Set editor parameter `id` to an absolute value - the counterpart to
    /// `set_param` automation curves need, since a curve knows the value it
    /// wants at a beat position directly rather than a delta from wherever
    /// the param last was. Same audio-thread-only rule as `set_param`. Only
    /// some ids are wired on a given device (see e.g.
    /// PolySynth.setParamAbsolute); unhandled ids are a no-op.
    set_param_abs: struct { id: u16, value: f32 },
    /// Replace one synth modulation destination atomically. `instance_id`
    /// zero names a synth parameter; nonzero names one rack FX instance and
    /// makes `id` that unit's local fx_params index.
    set_mod_target: struct { row: u8, id: u16, instance_id: u32 },
    /// `instance_id` 0 (the default) targets the track's own instrument,
    /// which owns the whole flat id space `id` indexes - every instrument
    /// device's `handleEvent` already only fires when it recognizes `id`, so
    /// broadcasting to a whole chain (see `Engine.sendTrackEvent`) is safe.
    /// A nonzero `instance_id` targets one specific `FxUnit` in the chain by
    /// its stable id (see `rack.FxUnit.instance_id`); `id` is then a local
    /// index into that unit's own `dsp.fx_params` table. 0 is never a real
    /// instance id (see `Fx.allocInstanceId`), so it's a safe sentinel.
    automation_param: struct { id: u32, value: f32, instance_id: u32 = 0, sample_offset: u32 = 0 },
    /// CLAP parameters use stable opaque u32 IDs. `target` keeps a
    /// track-wide event broadcast from changing every CLAP in the chain.
    clap_param: struct { target: *anyopaque, id: u32, cookie: ?*anyopaque, value: f64, sample_offset: u32 = 0 },
    vst3_param: struct { target: *anyopaque, id: u32, value: f64, sample_offset: u32 = 0 },
    /// Supply this block's external sidechain-detector signal - pushed by
    /// the engine to a single chain slot (not broadcast to a whole chain
    /// the way `sendTrackEvent` sends the other variants) right before that
    /// slot's `process()` runs, whenever it holds a `Compressor` with
    /// `sidechain_source` set and that source track was actually rendered
    /// this block. `buf` is interleaved stereo, same length as the block
    /// being processed, and only valid for the immediately-following
    /// `process()` call - devices that consume it must not retain the slice
    /// past that. Every device but `Compressor` ignores this, matching
    /// `set_param_abs`'s "unhandled ids are a no-op" convention.
    set_sidechain_buf: struct { buf: []const types.Sample },
    /// Ask the device to also render drum pad `pad`'s isolated signal into
    /// `buf` this block, for per-pad sidechain-detector capture (see
    /// `Compressor.SidechainSource.pad`) - the counterpart to
    /// `set_sidechain_buf`, but pushing a WRITE destination instead of
    /// supplying a read-only source. `buf` is interleaved stereo, the same
    /// length as the block about to be processed; the engine zeroes it
    /// first, so a device that ignores this (every kind but `DrumMachine`)
    /// leaves the caller with silence, never garbage. Broadcast to a
    /// track's whole chain (not one slot) before `process()` runs on any
    /// device in it, since the instrument's chain position varies by kind
    /// (`DrumMachine` has no pattern player, so it sits at slot 0 instead
    /// of 1) - see `Engine.renderOneTrack`. `DrumMachine` consumes the
    /// request at the start of the SAME block's `processBlock`, mixing the
    /// pad into the normal output exactly once (never a double-triggered
    /// voice) while also copying its isolated contribution into `buf`.
    capture_pad: struct { pad: u8, buf: []types.Sample },
};

/// Shared metadata shape for one continuous instrument param exposed to the
/// automation editor's param picker, curve labels, and h/l nudge step. Each
/// instrument that supports automation (PolySynth, Sampler) declares its own
/// `automatable_params` table of these against its own `setParamAbsolute` id
/// space - kept here, not owned by either instrument, so the automation
/// editor can look either table up through one shared type regardless of
/// which instrument the current track holds.
pub const AutomatableParam = struct {
    id: u32,
    label: []const u8,
    section: []const u8,
    range: [2]f32,
    /// h/l nudge step - same magnitude as the instrument's own `adjustParam`
    /// per-step multiplier for this id, so automation nudges feel consistent
    /// with the live editor's own h/l.
    step: f32,

    /// True for a param that is a legal mod-matrix destination but NOT a
    /// legal automation lane. PolySynth's `fx_*` ids are the only ones: the
    /// synth stopped processing its own effects when the rack chain took
    /// over, so the matrix reaches the *rack* unit that owns the param
    /// (through `fx_instance_id`) while writing the synth field an
    /// automation lane would write reaches nothing. Keyed off the section
    /// rather than a per-row flag so a new FX param can't be added to the
    /// table and silently show up as a dead lane - every one of them
    /// declares an "FX <unit>" section.
    pub fn modDestOnly(self: AutomatableParam) bool {
        return std.mem.startsWith(u8, self.section, "FX ");
    }
};

pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// In-place on interleaved stereo. Instruments add their output
        /// into `buf`; effects transform what is already there.
        process: *const fn (ptr: *anyopaque, buf: []types.Sample) void,
        /// Instruments receive note events; effects leave this null.
        event: ?*const fn (ptr: *anyopaque, ev: Event) void = null,
        /// Clear tails, voices, and envelopes (e.g. on transport stop).
        reset: *const fn (ptr: *anyopaque) void,
        latency_frames: *const fn (ptr: *anyopaque) u32 = struct {
            fn zero(_: *anyopaque) u32 {
                return 0;
            }
        }.zero,
        sample_offset_events: *const fn (ptr: *anyopaque) bool = struct {
            fn no(_: *anyopaque) bool {
                return false;
            }
        }.no,
    };

    pub fn process(self: Device, buf: []types.Sample) void {
        self.vtable.process(self.ptr, buf);
    }

    pub fn sendEvent(self: Device, ev: Event) void {
        if (self.vtable.event) |f| f(self.ptr, ev);
    }

    pub fn reset(self: Device) void {
        self.vtable.reset(self.ptr);
    }

    pub fn latencyFrames(self: Device) u32 {
        return self.vtable.latency_frames(self.ptr);
    }

    pub fn acceptsSampleOffsetEvents(self: Device) bool {
        return self.vtable.sample_offset_events(self.ptr);
    }
};

/// Builds a `Device` fat-pointer for `T`, given `T.processBlock(*T, []Sample)
/// void` and `T.reset(*T) void`. If `T` also declares `handleEvent(*T, Event)
/// void`, the vtable's `event` slot forwards to it; otherwise it stays null,
/// same split every effect (no events) vs. instrument (events) already had.
/// Usage: `pub const device = dsp.deviceOf(@This());` inside `T`'s own
/// definition - keeps the `@ptrCast(@alignCast(ptr))` shim and the static
/// vtable literal out of every device implementation.
pub fn deviceOf(comptime T: type) fn (*T) Device {
    const shim = struct {
        fn processOpaque(ptr: *anyopaque, buf: []types.Sample) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.processBlock(buf);
        }
        fn resetOpaque(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.reset();
        }
        fn eventOpaque(ptr: *anyopaque, ev: Event) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.handleEvent(ev);
        }
        fn latencyOpaque(ptr: *anyopaque) u32 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return if (@hasDecl(T, "latencyFrames")) self.latencyFrames() else 0;
        }
        fn sampleOffsetEventsOpaque(_: *anyopaque) bool {
            return @hasDecl(T, "sample_offset_events") and T.sample_offset_events;
        }
        const vtable: Device.VTable = .{
            .process = processOpaque,
            .reset = resetOpaque,
            .event = if (@hasDecl(T, "handleEvent")) eventOpaque else null,
            .latency_frames = latencyOpaque,
            .sample_offset_events = sampleOffsetEventsOpaque,
        };
        fn device(self: *T) Device {
            return .{ .ptr = self, .vtable = &vtable };
        }
    }.device;
    return shim;
}

/// Stress `effect` with 50 blocks of full-scale white noise and fail if any
/// output sample leaves +/-`limit` - the standard "does the feedback path
/// blow up" smoke test for a filter/delay-line effect. The seed is fixed so
/// a failure is reproducible; `limit` is per-effect headroom, not a spec.
pub fn expectBoundedUnderNoise(effect: anytype, limit: types.Sample) !void {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var buf: [512]types.Sample = undefined;
    for (0..50) |_| {
        for (&buf) |*s| s.* = rand.float(f32) * 2.0 - 1.0;
        effect.processBlock(&buf);
        for (buf) |s| try std.testing.expect(@abs(s) < limit);
    }
}
