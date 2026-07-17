//! Named color identity, shared by the GUI (float RGBA panel skin, see
//! gui/style.zig) and the TUI (ANSI-palette OSC reprogramming, see
//! tui/theme.zig). One hex table per theme name; each frontend renders it
//! through its own pipeline instead of keeping its own copy of the hex
//! literals - the two are the same brand under different rendering models,
//! not two unrelated palettes that happen to share names.
//!
//! `blue` is the one field the GUI panel skin has no use for (there's no
//! "blue surface" in the imgui skin) but the TUI needs for its routing/voice
//! ANSI slot - see tui/theme.zig's slot table.

pub const Identity = struct {
    light: bool = false,
    bg0: u24,
    bg1: u24,
    bg2: u24,
    bg3: u24,
    bg4: u24,
    bg5: u24,
    fg0: u24,
    fg1: u24,
    fg2: u24,
    fg3: u24,
    line: u24,
    line_soft: u24,
    focus: u24,
    focus_soft: u24,
    track_cursor: u24,
    modulation: u24,
    danger: u24,
    rhythm: u24,
    audio: u24,
    blue: u24,
    tracks: [7]u24,
};

/// The Patina identity is intentionally green through the full surface
/// stack, not neutral charcoal with a branded accent. See
/// docs/gui-color-identity.md.
pub const patina: Identity = .{
    .bg0 = 0x06100e,
    .bg1 = 0x0b1916,
    .bg2 = 0x12241f,
    .bg3 = 0x1b302a,
    .bg4 = 0x284239,
    .bg5 = 0x38584d,
    .fg0 = 0xf2eadb,
    .fg1 = 0xc9c0ae,
    .fg2 = 0x9a9282,
    .fg3 = 0x6f7569,
    .line = 0x1c352e,
    .line_soft = 0x0d201b,
    .focus = 0xf08777,
    .focus_soft = 0xb76559,
    .track_cursor = 0xf2eadb,
    .modulation = 0xd69ac0,
    .danger = 0xf06468,
    .rhythm = 0xc9cf73,
    .audio = 0x71b9ac,
    .blue = 0x9b9acb,
    .tracks = .{ 0xf08777, 0xf06468, 0xc9cf73, 0x71b9ac, 0xd69ac0, 0xd6a15f, 0x9b9acb },
};

/// Light counterpart specified alongside Patina in the color identity doc.
pub const patina_light: Identity = .{
    .light = true,
    .bg0 = 0xdce6dd,
    .bg1 = 0xf3efe4,
    .bg2 = 0xebe4d6,
    .bg3 = 0xd9e2d8,
    .bg4 = 0xc7d8cd,
    .bg5 = 0xa9c0b2,
    .fg0 = 0x17231f,
    .fg1 = 0x34463f,
    .fg2 = 0x5f6e66,
    .fg3 = 0x7e897f,
    .line = 0xc7d8cd,
    .line_soft = 0xe1e6dc,
    .focus = 0xad493f,
    .focus_soft = 0xd88475,
    .track_cursor = 0x17231f,
    .modulation = 0x964778,
    .danger = 0xb93640,
    .rhythm = 0x626a19,
    .audio = 0x247067,
    .blue = 0x8b8abd,
    .tracks = .{ 0xd86f61, 0xde6870, 0xb6bd5f, 0x65aaa0, 0xc787ac, 0xc9964d, 0x8b8abd },
};

/// Neutral-charcoal counterpart: the same lightness ramp and warm text with
/// the green tint removed, accents unchanged - the conventional look the
/// identity doc describes patina as deliberately not being, offered as
/// `gui_theme = "graphite"` for people who want exactly that.
pub const graphite: Identity = .{
    .bg0 = 0x0b0b0d,
    .bg1 = 0x131316,
    .bg2 = 0x1c1c21,
    .bg3 = 0x27272e,
    .bg4 = 0x36363f,
    .bg5 = 0x4c4c58,
    .fg0 = 0xf2eadb,
    .fg1 = 0xc9c0ae,
    .fg2 = 0x9a9282,
    .fg3 = 0x71716c,
    .line = 0x2a2a31,
    .line_soft = 0x17171b,
    .focus = 0xf08777,
    .focus_soft = 0xb76559,
    .track_cursor = 0xf2eadb,
    .modulation = 0xd69ac0,
    .danger = 0xf06468,
    .rhythm = 0xc9cf73,
    .audio = 0x71b9ac,
    .blue = 0x9b9acb,
    .tracks = .{ 0xf08777, 0xf06468, 0xc9cf73, 0x71b9ac, 0xd69ac0, 0xd6a15f, 0x9b9acb },
};

/// The original violet GUI palette, restored as an optional theme.
pub const umbra: Identity = .{
    .bg0 = 0x0c040f,
    .bg1 = 0x160a19,
    .bg2 = 0x231426,
    .bg3 = 0x301f34,
    .bg4 = 0x412d45,
    .bg5 = 0x553e5a,
    .fg0 = 0xd9d1da,
    .fg1 = 0xb1a7b3,
    .fg2 = 0x887b8c,
    .fg3 = 0x645567,
    .line = 0x1d1120,
    .line_soft = 0x130915,
    .focus = 0xb07bbc,
    .focus_soft = 0x886498,
    .track_cursor = 0xd9d1da,
    .modulation = 0xc68fc1,
    .danger = 0xb97873,
    .rhythm = 0xc1a77b,
    .audio = 0x7cb0af,
    .blue = 0x7899c1,
    .tracks = .{ 0xb07bbc, 0xb97873, 0xc1a77b, 0x7cb0af, 0xc68fc1, 0x7899c1, 0x86b978 },
};

pub const Name = enum { patina, patina_light, graphite, umbra };

pub fn get(name: Name) *const Identity {
    return switch (name) {
        .patina => &patina,
        .patina_light => &patina_light,
        .graphite => &graphite,
        .umbra => &umbra,
    };
}
