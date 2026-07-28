//! Allocation-free modulation handoff from an instrument to following rack FX.
//! Producer and consumers run sequentially on the same audio thread.

pub const max_entries = 32;

pub const Entry = struct {
    instance_id: u32,
    param_id: u16,
    amount: f32,
};

pub const Bus = struct {
    entries: [max_entries]Entry = undefined,
    count: u8 = 0,

    pub fn clear(self: *Bus) void {
        self.count = 0;
    }

    pub fn add(self: *Bus, instance_id: u32, param_id: u16, value: f32) void {
        if (instance_id == 0 or value == 0.0) return;
        for (self.entries[0..self.count]) |*entry| {
            if (entry.instance_id == instance_id and entry.param_id == param_id) {
                entry.amount += value;
                return;
            }
        }
        if (self.count == max_entries) return;
        self.entries[self.count] = .{
            .instance_id = instance_id,
            .param_id = param_id,
            .amount = value,
        };
        self.count += 1;
    }

    pub fn amount(self: *const Bus, instance_id: u32, param_id: u16) f32 {
        for (self.entries[0..self.count]) |entry| {
            if (entry.instance_id == instance_id and entry.param_id == param_id)
                return entry.amount;
        }
        return 0.0;
    }
};

test "bus sums matching targets and keeps instances separate" {
    const std = @import("std");
    var bus: Bus = .{};
    bus.add(4, 12, 0.25);
    bus.add(4, 12, 0.5);
    bus.add(5, 12, -0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), bus.amount(4, 12), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), bus.amount(5, 12), 1e-6);
    bus.clear();
    try std.testing.expectEqual(@as(f32, 0.0), bus.amount(4, 12));
}
