//! MIDI note-on velocity -> gain mapping. Split out from midi_in.zig (Linux/
//! ALSA-only) so `wstudio.o.default_midi_velocity_curve` has a type that
//! compiles on every platform, same reason `audio_host.Choice` lives in
//! host.zig rather than inside a backend-specific file.

const std = @import("std");

pub const VelocityCurve = enum(u8) { linear, exponential, fixed };

/// `raw` is the 0-127 MIDI velocity byte.
pub fn apply(curve: VelocityCurve, raw: u7) f32 {
    const t = @as(f32, @floatFromInt(raw)) / 127.0;
    return switch (curve) {
        .linear => t,
        // Softer touches read quieter than linear; hard hits still reach 1.0.
        .exponential => t * t,
        // Every hit lands at full velocity - consistent triggering
        // regardless of how hard a pad/key was struck.
        .fixed => 1.0,
    };
}

test "linear passes velocity through unchanged" {
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 / 127.0), apply(.linear, 100), 0.0001);
}

test "exponential attenuates soft hits more than linear" {
    const soft: u7 = 40;
    try std.testing.expect(apply(.exponential, soft) < apply(.linear, soft));
}

test "fixed always returns full velocity" {
    try std.testing.expectEqual(@as(f32, 1.0), apply(.fixed, 1));
    try std.testing.expectEqual(@as(f32, 1.0), apply(.fixed, 127));
}

test "max velocity reaches 1.0 under every curve" {
    inline for (std.meta.tags(VelocityCurve)) |curve| {
        try std.testing.expectEqual(@as(f32, 1.0), apply(curve, 127));
    }
}
