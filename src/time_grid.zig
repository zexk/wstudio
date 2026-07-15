//! Exact musical-time grid shared by pattern and arrangement editors.

/// The finest supported grid is a 1/128 note: 32 ticks per quarter note.
pub const ticks_per_beat: u32 = 32;

pub const Division = enum(u8) {
    quarter = 4,
    eighth = 8,
    sixteenth = 16,
    thirty_second = 32,
    sixty_fourth = 64,
    one_twenty_eighth = 128,

    pub fn denominator(self: Division) u8 {
        return @intFromEnum(self);
    }

    pub fn ticks(self: Division) u32 {
        return 128 / @as(u32, self.denominator());
    }

    pub fn finer(self: Division) Division {
        return switch (self) {
            .quarter => .eighth,
            .eighth => .sixteenth,
            .sixteenth => .thirty_second,
            .thirty_second => .sixty_fourth,
            .sixty_fourth, .one_twenty_eighth => .one_twenty_eighth,
        };
    }

    pub fn coarser(self: Division) Division {
        return switch (self) {
            .quarter, .eighth => .quarter,
            .sixteenth => .eighth,
            .thirty_second => .sixteenth,
            .sixty_fourth => .thirty_second,
            .one_twenty_eighth => .sixty_fourth,
        };
    }

    pub fn label(self: Division) []const u8 {
        return switch (self) {
            .quarter => "1/4",
            .eighth => "1/8",
            .sixteenth => "1/16",
            .thirty_second => "1/32",
            .sixty_fourth => "1/64",
            .one_twenty_eighth => "1/128",
        };
    }
};

pub fn barTicks(beats_per_bar: u8) u32 {
    return @as(u32, beats_per_bar) * ticks_per_beat;
}

pub fn tickToBeat(tick: u32) f64 {
    return @as(f64, @floatFromInt(tick)) / ticks_per_beat;
}
