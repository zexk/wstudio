const std = @import("std");

const c = @cImport({
    @cInclude("alsa/asoundlib.h");
    @cInclude("stdlib.h");
});

pub fn write(w: *std.Io.Writer) !void {
    try w.writeAll("audio devices (ALSA PCM name):\n");
    var hints: [*c]?*anyopaque = null;
    if (c.snd_device_name_hint(-1, "pcm", @ptrCast(&hints)) >= 0 and hints != null) {
        defer _ = c.snd_device_name_free_hint(@ptrCast(hints));
        var i: usize = 0;
        while (hints[i]) |hint| : (i += 1) {
            const name = c.snd_device_name_get_hint(hint, "NAME") orelse continue;
            defer c.free(name);
            const io_id = c.snd_device_name_get_hint(hint, "IOID");
            defer if (io_id) |value| c.free(value);
            try w.print("  {s}\t{s}\n", .{ std.mem.span(name), if (io_id) |value| std.mem.span(value) else "input/output" });
        }
    }

    try w.writeAll("midi input devices (ALSA sequencer address):\n");
    var seq: ?*c.snd_seq_t = null;
    if (c.snd_seq_open(&seq, "default", c.SND_SEQ_OPEN_INPUT, 0) < 0) return;
    defer _ = c.snd_seq_close(seq);

    var client_info: ?*c.snd_seq_client_info_t = null;
    if (c.snd_seq_client_info_malloc(&client_info) < 0) return;
    defer c.snd_seq_client_info_free(client_info);
    var port_info: ?*c.snd_seq_port_info_t = null;
    if (c.snd_seq_port_info_malloc(&port_info) < 0) return;
    defer c.snd_seq_port_info_free(port_info);

    c.snd_seq_client_info_set_client(client_info, -1);
    while (c.snd_seq_query_next_client(seq, client_info) >= 0) {
        const client = c.snd_seq_client_info_get_client(client_info);
        c.snd_seq_port_info_set_client(port_info, client);
        c.snd_seq_port_info_set_port(port_info, -1);
        while (c.snd_seq_query_next_port(seq, port_info) >= 0) {
            const caps = c.snd_seq_port_info_get_capability(port_info);
            if (caps & c.SND_SEQ_PORT_CAP_READ == 0 or caps & c.SND_SEQ_PORT_CAP_SUBS_READ == 0) continue;
            try w.print("  {d}:{d}\t{s}\n", .{
                client,
                c.snd_seq_port_info_get_port(port_info),
                std.mem.span(c.snd_seq_port_info_get_name(port_info)),
            });
        }
    }
}
