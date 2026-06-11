//! Audio backend abstraction.
//!
//! A backend owns the device/driver thread and calls back into the
//! engine for each block. Native backends (ALSA, PipeWire, JACK,
//! CoreAudio) implement this same interface; today only the offline
//! renderer exists, which is also what export/bounce will use.

const std = @import("std");
const types = @import("../core/types.zig");

pub const Config = struct {
    sample_rate: u32 = types.default_sample_rate,
    block_frames: types.FrameCount = types.default_block_frames,
    channels: u16 = 2,
};

/// Fills `out` (interleaved, out.len = block_frames * channels).
pub const RenderFn = *const fn (ctx: *anyopaque, out: []types.Sample) void;

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque) anyerror!void,
        stop: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(self: Backend) !void {
        return self.vtable.start(self.ptr);
    }

    pub fn stop(self: Backend) void {
        self.vtable.stop(self.ptr);
    }
};

/// Drives the render callback as fast as possible — used for tests and
/// offline export rather than a sound card.
pub const OfflineBackend = struct {
    config: Config,
    render: RenderFn,
    ctx: *anyopaque,

    /// Renders `total_frames` into `out` (caller-allocated,
    /// total_frames * channels samples) in block-sized chunks, exactly
    /// as a device backend would deliver them.
    pub fn renderAll(self: *OfflineBackend, out: []types.Sample) void {
        const ch = self.config.channels;
        const block_samples: usize = @as(usize, self.config.block_frames) * ch;
        var offset: usize = 0;
        while (offset < out.len) {
            const end = @min(offset + block_samples, out.len);
            self.render(self.ctx, out[offset..end]);
            offset = end;
        }
    }
};

test "offline backend delivers every frame exactly once" {
    const Counter = struct {
        calls: u32 = 0,
        fn render(ctx: *anyopaque, out: []types.Sample) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            @memset(out, 1.0);
        }
    };

    var counter: Counter = .{};
    var backend = OfflineBackend{
        .config = .{ .block_frames = 256, .channels = 2 },
        .render = Counter.render,
        .ctx = &counter,
    };

    // 1000 frames stereo: 3 full blocks + 1 partial
    var out: [2000]types.Sample = undefined;
    backend.renderAll(&out);

    try std.testing.expectEqual(@as(u32, 4), counter.calls);
    for (out) |s| try std.testing.expectEqual(@as(types.Sample, 1.0), s);
}
