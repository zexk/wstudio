//! Write the TUI's embedded icon font to the user's font directory.
//!
//! Run with `zig build install-font`. wstudio's TUI decorates a few views
//! with icons from a bundled 35-glyph subset of "Symbols Nerd Font Mono"
//! (see src/ui/icons.zig and src/assets/fonts/LICENSE) - those codepoints
//! only render as icons once this font (or any Nerd Font) is on the
//! system and selected as (or falls back to) the terminal's font. The TUI
//! detects whether this file exists (see icons.detectFontInstalled) and,
//! at sites that also have an ASCII rendering, shows the icon once it's
//! installed and the ASCII otherwise - so a missing font degrades to
//! plain ASCII rather than a stray tofu box next to it.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");

const win = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
}) else struct {};

const font_name = "wstudio-icons.ttf";

fn registerWindowsFont(path: []const u8) !void {
    if (builtin.os.tag != .windows) return;

    var path_w: [1024]u16 = undefined;
    const path_len = try std.unicode.utf8ToUtf16Le(&path_w, path);
    path_w[path_len] = 0;

    const key_path = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts");
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("Symbols Nerd Font Mono (TrueType)");
    var root: win.HKEY = null;
    if (win.RegOpenCurrentUser(win.KEY_CREATE_SUB_KEY | win.KEY_SET_VALUE, &root) != win.ERROR_SUCCESS)
        return error.FontRegistrationFailed;
    defer _ = win.RegCloseKey(root);
    var key: win.HKEY = null;
    if (win.RegCreateKeyExW(root, key_path, 0, null, 0, win.KEY_SET_VALUE, null, &key, null) != win.ERROR_SUCCESS)
        return error.FontRegistrationFailed;
    defer _ = win.RegCloseKey(key);
    if (win.RegSetValueExW(
        key,
        value_name,
        0,
        win.REG_SZ,
        @ptrCast(&path_w),
        @intCast((path_len + 1) * @sizeOf(u16)),
    ) != win.ERROR_SUCCESS) return error.FontRegistrationFailed;
    if (win.AddFontResourceExW(&path_w, 0, null) == 0) return error.FontRegistrationFailed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var path_buf: [1024]u8 = undefined;
    const dir = ws.iconFontDir(&path_buf) catch {
        try stdout.writeAll(
            "install-font: could not determine a font directory " ++
                "from platform environment\n",
        );
        try stdout.flush();
        return error.NoFontDir;
    };

    try std.Io.Dir.cwd().createDirPath(io, dir);

    var full_buf: [1024]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir, font_name });

    {
        const file = try std.Io.Dir.cwd().createFile(io, full_path, .{});
        defer file.close(io);
        var fbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &fbuf);
        try fw.interface.writeAll(ws.icon_font_ttf);
        try fw.interface.flush();
    }
    try registerWindowsFont(full_path);

    try stdout.print(
        "installed: {s}\n" ++
            (if (builtin.os.tag == .linux) "run `fc-cache -f` (or restart your terminal) so it picks up the new " else "restart your terminal so it picks up the new ") ++
            "font, then set your terminal's font to \"Symbols Nerd Font Mono\" - " ++
            "or just add it as a fallback font alongside your usual one, since it " ++
            "only needs to cover a handful of Private Use Area codepoints.\n",
        .{full_path},
    );
    try stdout.flush();
}
