const std = @import("std");
const zgui = @import("zgui");

pub fn draw(app: anytype) void {
    zgui.textDisabled("FILE BROWSER", .{});
    zgui.text("{s}", .{app.core.browser_dir});
    zgui.textDisabled("j/k move   enter open   h parent   r refresh   esc back", .{});
    zgui.separator();
    if (zgui.beginChild("files", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (app.core.browser_entries.items, 0..) |entry, i| {
            var label_buf: [512]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s} {s}", .{ if (entry.is_dir) "[DIR]" else "     ", entry.name }) catch continue;
            if (zgui.selectable(label, .{ .selected = app.core.browser_cursor == i })) {
                app.core.browser_cursor = i;
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
        }
    }
    zgui.endChild();
}
