//! Lock-free single-producer single-consumer ring buffer.
//!
//! This is the only communication channel between control threads and
//! the audio thread. The audio thread must never block, so commands and
//! feedback (meter values, playhead position) cross this boundary
//! instead of taking locks.

const std = @import("std");

pub fn Spsc(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));

    return struct {
        buffer: [capacity]T = undefined,
        head: std.atomic.Value(usize) = .init(0), // consumer position
        tail: std.atomic.Value(usize) = .init(0), // producer position

        const Self = @This();
        const mask = capacity - 1;

        /// Producer side. Returns false when full (caller decides
        /// whether to retry or drop).
        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail -% head == capacity) return false;
            self.buffer[tail & mask] = item;
            self.tail.store(tail +% 1, .release);
            return true;
        }

        /// Consumer side. Wait-free; safe to call from the audio thread.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (tail == head) return null;
            const item = self.buffer[head & mask];
            self.head.store(head +% 1, .release);
            return item;
        }

        pub fn len(self: *const Self) usize {
            return self.tail.load(.acquire) -% self.head.load(.acquire);
        }
    };
}

test "push/pop preserves order" {
    var q: Spsc(u32, 8) = .{};
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(q.push(3));
    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    try std.testing.expectEqual(@as(?u32, 3), q.pop());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "rejects push when full, recovers after pop" {
    var q: Spsc(u8, 4) = .{};
    for (0..4) |i| try std.testing.expect(q.push(@intCast(i)));
    try std.testing.expect(!q.push(99));
    try std.testing.expectEqual(@as(usize, 4), q.len());
    _ = q.pop();
    try std.testing.expect(q.push(99));
}

test "wraps around indices correctly" {
    var q: Spsc(u64, 4) = .{};
    for (0..1000) |i| {
        try std.testing.expect(q.push(i));
        try std.testing.expectEqual(@as(?u64, i), q.pop());
    }
}
