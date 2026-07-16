//! Write the TUI's embedded icon font to the user's font directory.
//!
//! Run with `zig build install-font`. wstudio's TUI decorates a few views
//! with icons from a bundled 16-glyph subset of "Symbols Nerd Font Mono"
//! (see src/tui/icons.zig and src/assets/fonts/LICENSE) - those codepoints
//! only render as icons once this font (or any Nerd Font) is on the
//! system and selected as (or falls back to) the terminal's font. The TUI
//! detects whether this file exists (see icons.detectFontInstalled) and,
//! at sites that also have an ASCII rendering, shows the icon once it's
//! installed and the ASCII otherwise - so a missing font degrades to
//! plain ASCII rather than a stray tofu box next to it.

const std = @import("std");
const ws = @import("wstudio");

const font_name = "wstudio-icons.ttf";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var path_buf: [1024]u8 = undefined;
    const dir = ws.iconFontDir(&path_buf) catch {
        try stdout.writeAll(
            "install-font: could not determine a font directory " ++
                "(neither $XDG_DATA_HOME nor $HOME is set)\n",
        );
        try stdout.flush();
        return error.NoFontDir;
    };

    try std.Io.Dir.cwd().createDirPath(io, dir);

    var full_buf: [1024]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir, font_name });

    const file = try std.Io.Dir.cwd().createFile(io, full_path, .{});
    defer file.close(io);
    var fbuf: [4096]u8 = undefined;
    var fw = file.writer(io, &fbuf);
    try fw.interface.writeAll(ws.icon_font_ttf);
    try fw.interface.flush();

    try stdout.print(
        "installed: {s}\n" ++
            "run `fc-cache -f` (or restart your terminal) so it picks up the new " ++
            "font, then set your terminal's font to \"Symbols Nerd Font Mono\" - " ++
            "or just add it as a fallback font alongside your usual one, since it " ++
            "only needs to cover a handful of Private Use Area codepoints.\n",
        .{full_path},
    );
    try stdout.flush();
}
