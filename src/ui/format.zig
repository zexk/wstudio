//! Value formatters both frontends print verbatim. Anything that turns a
//! parameter into user-facing text and would otherwise be re-typed per view
//! belongs here, so a change to how a value reads lands everywhere at once.

const std = @import("std");

/// Below this a pan is "centered" - a knob or a nudge can leave a value a
/// hair off zero, and reading "L0%" there is noise, not information.
pub const pan_center_epsilon: f32 = 0.005;

/// Mixer-style pan readout: "C", or the side plus how far it leans.
pub fn panLabel(buf: []u8, pan: f32) []const u8 {
    if (@abs(pan) < pan_center_epsilon) return "C";
    const pct: u32 = @intFromFloat(@abs(pan) * 100.0);
    return std.fmt.bufPrint(buf, "{c}{d}%", .{ panLetter(pan)[0], pct }) catch "C";
}

/// Just the side, for the status line's one-column-wide slot.
pub fn panLetter(pan: f32) []const u8 {
    if (@abs(pan) < pan_center_epsilon) return "C";
    return if (pan < 0) "L" else "R";
}

test "pan formatting" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("C", panLabel(&buf, 0.0));
    try std.testing.expectEqualStrings("C", panLabel(&buf, -0.001));
    try std.testing.expectEqualStrings("L42%", panLabel(&buf, -0.42));
    try std.testing.expectEqualStrings("R100%", panLabel(&buf, 1.0));
    try std.testing.expectEqualStrings("C", panLetter(0.004));
    try std.testing.expectEqualStrings("L", panLetter(-0.5));
    try std.testing.expectEqualStrings("R", panLetter(0.5));
}
