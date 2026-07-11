//! Device interface: the common shape of every built-in instrument
//! and effect. Tracks hold a chain of devices; the engine drives them
//! on the audio thread, so implementations must not allocate or block
//! inside `process` — buffers are allocated up front at init time.

const std = @import("std");
const types = @import("../core/types.zig");

pub const Event = union(enum) {
    note_on: struct { note: u7, velocity: f32 },
    note_off: struct { note: u7 },
    all_off,
    cc: struct { cc: u7, value: u7 },
    pitch_bend: struct { bend: i16 },
    /// Nudge editor parameter `id` by `steps` (signed). Applied on the audio
    /// thread so UI edits never race the reader — see PolySynth.adjustParam.
    /// `id` is u16, not u8: DrumMachine.paramId packs a pad index (up to 64)
    /// into the high bits, which no longer fits u8 now that pad count grew
    /// past 15. Every other device's own adjustParam/setParamAbsolute still
    /// takes a plain u8 (their param counts are all well under 256) — the
    /// wider id only matters at this shared event boundary.
    set_param: struct { id: u16, steps: i32 },
    /// Set editor parameter `id` to an absolute value — the counterpart to
    /// `set_param` automation curves need, since a curve knows the value it
    /// wants at a beat position directly rather than a delta from wherever
    /// the param last was. Same audio-thread-only rule as `set_param`. Only
    /// some ids are wired on a given device (see e.g.
    /// PolySynth.setParamAbsolute); unhandled ids are a no-op.
    set_param_abs: struct { id: u16, value: f32 },
    /// Supply this block's external sidechain-detector signal — pushed by
    /// the engine to a single chain slot (not broadcast to a whole chain
    /// the way `sendTrackEvent` sends the other variants) right before that
    /// slot's `process()` runs, whenever it holds a `Compressor` with
    /// `sidechain_source` set and that source track was actually rendered
    /// this block. `buf` is interleaved stereo, same length as the block
    /// being processed, and only valid for the immediately-following
    /// `process()` call — devices that consume it must not retain the slice
    /// past that. Every device but `Compressor` ignores this, matching
    /// `set_param_abs`'s "unhandled ids are a no-op" convention.
    set_sidechain_buf: struct { buf: []const types.Sample },
    /// Ask the device to also render drum pad `pad`'s isolated signal into
    /// `buf` this block, for per-pad sidechain-detector capture (see
    /// `Compressor.SidechainSource.pad`) — the counterpart to
    /// `set_sidechain_buf`, but pushing a WRITE destination instead of
    /// supplying a read-only source. `buf` is interleaved stereo, the same
    /// length as the block about to be processed; the engine zeroes it
    /// first, so a device that ignores this (every kind but `DrumMachine`)
    /// leaves the caller with silence, never garbage. Broadcast to a
    /// track's whole chain (not one slot) before `process()` runs on any
    /// device in it, since the instrument's chain position varies by kind
    /// (`DrumMachine` has no pattern player, so it sits at slot 0 instead
    /// of 1) — see `Engine.renderOneTrack`. `DrumMachine` consumes the
    /// request at the start of the SAME block's `processBlock`, mixing the
    /// pad into the normal output exactly once (never a double-triggered
    /// voice) while also copying its isolated contribution into `buf`.
    capture_pad: struct { pad: u8, buf: []types.Sample },
};

/// Shared metadata shape for one continuous instrument param exposed to the
/// automation editor's param picker, curve labels, and h/l nudge step. Each
/// instrument that supports automation (PolySynth, Sampler) declares its own
/// `automatable_params` table of these against its own `setParamAbsolute` id
/// space — kept here, not owned by either instrument, so the automation
/// editor can look either table up through one shared type regardless of
/// which instrument the current track holds.
pub const AutomatableParam = struct {
    id: u8,
    label: []const u8,
    section: []const u8,
    range: [2]f32,
    /// h/l nudge step — same magnitude as the instrument's own `adjustParam`
    /// per-step multiplier for this id, so automation nudges feel consistent
    /// with the live editor's own h/l.
    step: f32,
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
};
