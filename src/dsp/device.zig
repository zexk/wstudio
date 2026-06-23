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
