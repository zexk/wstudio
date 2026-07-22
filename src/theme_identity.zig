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

/// Light counterpart to `graphite`, by the same derivation the doc uses for
/// `patina_light`: same lightness ramp as `patina_light`, green tint bled
/// out of both the background ramp and the text column (unlike dark
/// `graphite`, `patina_light`'s fg0-fg3 do carry the green cast, so all four
/// get neutralized here, not just fg3). Accents are untouched.
pub const graphite_light: Identity = .{
    .light = true,
    .bg0 = 0xe1e1e7,
    .bg1 = 0xf1f1f6,
    .bg2 = 0xe8e8ed,
    .bg3 = 0xdedee2,
    .bg4 = 0xd0d0d6,
    .bg5 = 0xb5b5bc,
    .fg0 = 0x1d1d18,
    .fg1 = 0x3d3d38,
    .fg2 = 0x676762,
    .fg3 = 0x84847f,
    .line = 0xd0d0d6,
    .line_soft = 0xe4e4e9,
    .focus = 0xad493f,
    .focus_soft = 0xd88475,
    .track_cursor = 0x1d1d18,
    .modulation = 0x964778,
    .danger = 0xb93640,
    .rhythm = 0x626a19,
    .audio = 0x247067,
    .blue = 0x8b8abd,
    .tracks = .{ 0xd86f61, 0xde6870, 0xb6bd5f, 0x65aaa0, 0xc787ac, 0xc9964d, 0x8b8abd },
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

/// Adapt an upstream editor palette to wstudio's semantic surface and accent
/// roles. Attribution and upstream licenses live in docs/built-in-themes.md.
fn importedTheme(
    light: bool,
    backgrounds: [6]u24,
    foregrounds: [4]u24,
    accents: struct { red: u24, orange: u24, yellow: u24, green: u24, cyan: u24, blue: u24, magenta: u24 },
) Identity {
    return .{
        .light = light,
        .bg0 = backgrounds[0],
        .bg1 = backgrounds[1],
        .bg2 = backgrounds[2],
        .bg3 = backgrounds[3],
        .bg4 = backgrounds[4],
        .bg5 = backgrounds[5],
        .fg0 = foregrounds[0],
        .fg1 = foregrounds[1],
        .fg2 = foregrounds[2],
        .fg3 = foregrounds[3],
        .line = backgrounds[4],
        .line_soft = backgrounds[2],
        .focus = accents.blue,
        .focus_soft = accents.magenta,
        .track_cursor = foregrounds[0],
        .modulation = accents.magenta,
        .danger = accents.red,
        .rhythm = accents.yellow,
        .audio = accents.cyan,
        .blue = accents.blue,
        .tracks = .{ accents.red, accents.orange, accents.yellow, accents.green, accents.cyan, accents.magenta, accents.blue },
    };
}

pub const catppuccin_mocha = importedTheme(false, .{ 0x11111b, 0x181825, 0x1e1e2e, 0x313244, 0x45475a, 0x585b70 }, .{ 0xcdd6f4, 0xbac2de, 0xa6adc8, 0x7f849c }, .{ .red = 0xf38ba8, .orange = 0xfab387, .yellow = 0xf9e2af, .green = 0xa6e3a1, .cyan = 0x94e2d5, .blue = 0x89b4fa, .magenta = 0xcba6f7 });

pub const catppuccin_latte = importedTheme(true, .{ 0xdce0e8, 0xe6e9ef, 0xeff1f5, 0xccd0da, 0xbcc0cc, 0xacb0be }, .{ 0x4c4f69, 0x5c5f77, 0x6c6f85, 0x8c8fa1 }, .{ .red = 0xd20f39, .orange = 0xfe640b, .yellow = 0xdf8e1d, .green = 0x40a02b, .cyan = 0x179299, .blue = 0x1e66f5, .magenta = 0x8839ef });

pub const dracula = importedTheme(false, .{ 0x191a21, 0x21222c, 0x282a36, 0x343746, 0x44475a, 0x6272a4 }, .{ 0xf8f8f2, 0xd7d7d2, 0xb6b6b2, 0x6272a4 }, .{ .red = 0xff5555, .orange = 0xffb86c, .yellow = 0xf1fa8c, .green = 0x50fa7b, .cyan = 0x8be9fd, .blue = 0x8be9fd, .magenta = 0xbd93f9 });

pub const gruvbox_dark = importedTheme(false, .{ 0x1d2021, 0x282828, 0x3c3836, 0x504945, 0x665c54, 0x7c6f64 }, .{ 0xfbf1c7, 0xebdbb2, 0xd5c4a1, 0x928374 }, .{ .red = 0xfb4934, .orange = 0xfe8019, .yellow = 0xfabd2f, .green = 0xb8bb26, .cyan = 0x8ec07c, .blue = 0x83a598, .magenta = 0xd3869b });

pub const gruvbox_light = importedTheme(true, .{ 0xd5c4a1, 0xebdbb2, 0xfbf1c7, 0xd5c4a1, 0xbdae93, 0xa89984 }, .{ 0x282828, 0x3c3836, 0x504945, 0x7c6f64 }, .{ .red = 0x9d0006, .orange = 0xaf3a03, .yellow = 0xb57614, .green = 0x79740e, .cyan = 0x427b58, .blue = 0x076678, .magenta = 0x8f3f71 });

pub const nord = importedTheme(false, .{ 0x242933, 0x2e3440, 0x3b4252, 0x434c5e, 0x4c566a, 0x5e6a80 }, .{ 0xeceff4, 0xe5e9f0, 0xd8dee9, 0x7b88a1 }, .{ .red = 0xbf616a, .orange = 0xd08770, .yellow = 0xebcb8b, .green = 0xa3be8c, .cyan = 0x8fbcbb, .blue = 0x81a1c1, .magenta = 0xb48ead });

pub const solarized_dark = importedTheme(false, .{ 0x001f27, 0x002b36, 0x073642, 0x164550, 0x586e75, 0x657b83 }, .{ 0xfdf6e3, 0xeee8d5, 0x93a1a1, 0x839496 }, .{ .red = 0xdc322f, .orange = 0xcb4b16, .yellow = 0xb58900, .green = 0x859900, .cyan = 0x2aa198, .blue = 0x268bd2, .magenta = 0x6c71c4 });

pub const solarized_light = importedTheme(true, .{ 0xeee8d5, 0xfdf6e3, 0xeee8d5, 0xd9d2bf, 0x93a1a1, 0x839496 }, .{ 0x002b36, 0x073642, 0x586e75, 0x657b83 }, .{ .red = 0xdc322f, .orange = 0xcb4b16, .yellow = 0xb58900, .green = 0x859900, .cyan = 0x2aa198, .blue = 0x268bd2, .magenta = 0x6c71c4 });

pub const tokyonight = importedTheme(false, .{ 0x15161e, 0x1a1b26, 0x24283b, 0x292e42, 0x414868, 0x565f89 }, .{ 0xc0caf5, 0xa9b1d6, 0x9aa5ce, 0x565f89 }, .{ .red = 0xf7768e, .orange = 0xff9e64, .yellow = 0xe0af68, .green = 0x9ece6a, .cyan = 0x7dcfff, .blue = 0x7aa2f7, .magenta = 0xbb9af7 });

pub const Name = enum {
    patina,
    patina_light,
    graphite,
    graphite_light,
    umbra,
    catppuccin_mocha,
    catppuccin_latte,
    dracula,
    gruvbox_dark,
    gruvbox_light,
    nord,
    solarized_dark,
    solarized_light,
    tokyonight,
};

/// Semantic color tokens consumed by both frontends. Lua colorschemes
/// override these names through `wstudio.api.set_hl`; built-in identities
/// provide the complete fallback beneath those sparse overrides.
pub const Highlight = enum {
    bg0,
    bg1,
    bg2,
    bg3,
    bg4,
    bg5,
    fg0,
    fg1,
    fg2,
    fg3,
    line,
    line_soft,
    focus,
    focus_soft,
    track_cursor,
    modulation,
    danger,
    rhythm,
    audio,
    blue,
    track1,
    track2,
    track3,
    track4,
    track5,
    track6,
    track7,
};

pub const highlight_count = @typeInfo(Highlight).@"enum".fields.len;

pub const Overrides = struct {
    colors: [highlight_count]?u24 = [_]?u24{null} ** highlight_count,

    pub fn set(self: *Overrides, hl: Highlight, color: ?u24) void {
        self.colors[@intFromEnum(hl)] = color;
    }

    pub fn get(self: *const Overrides, hl: Highlight) ?u24 {
        return self.colors[@intFromEnum(hl)];
    }

    pub fn apply(self: *const Overrides, base: Identity) Identity {
        var result = base;
        inline for (@typeInfo(Highlight).@"enum".fields) |field| {
            const hl: Highlight = @enumFromInt(field.value);
            if (self.get(hl)) |color| {
                if (comptime field.name.len == 6 and std.mem.startsWith(u8, field.name, "track")) {
                    const index = comptime field.name[field.name.len - 1] - '1';
                    result.tracks[index] = color;
                } else {
                    @field(result, field.name) = color;
                }
            }
        }
        return result;
    }
};

pub fn get(name: Name) *const Identity {
    return switch (name) {
        .patina => &patina,
        .patina_light => &patina_light,
        .graphite => &graphite,
        .graphite_light => &graphite_light,
        .umbra => &umbra,
        .catppuccin_mocha => &catppuccin_mocha,
        .catppuccin_latte => &catppuccin_latte,
        .dracula => &dracula,
        .gruvbox_dark => &gruvbox_dark,
        .gruvbox_light => &gruvbox_light,
        .nord => &nord,
        .solarized_dark => &solarized_dark,
        .solarized_light => &solarized_light,
        .tokyonight => &tokyonight,
    };
}

const std = @import("std");

test "highlight overrides are sparse and include track colors" {
    var overrides: Overrides = .{};
    overrides.set(.focus, 0x123456);
    overrides.set(.track7, 0xabcdef);
    const resolved = overrides.apply(patina);
    try std.testing.expectEqual(@as(u24, 0x123456), resolved.focus);
    try std.testing.expectEqual(@as(u24, 0xabcdef), resolved.tracks[6]);
    try std.testing.expectEqual(patina.bg0, resolved.bg0);
}
