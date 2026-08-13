// Zig 0.16 translate-c does not canonicalize `../` before applying
// `#pragma once`, so umbrella clap.h sees false duplicate definitions.
pub const core = @cImport({
    @cInclude("clap/factory/plugin-factory.h");
});
pub const entry = @cImport({
    @cInclude("clap/entry.h");
});
pub const audio_ports = @cImport({
    @cInclude("clap/ext/audio-ports.h");
});
pub const note_ports = @cImport({
    @cInclude("clap/ext/note-ports.h");
});
pub const params = @cImport({
    @cInclude("clap/ext/params.h");
});
pub const state = @cImport({
    @cInclude("clap/ext/state.h");
});
pub const latency = @cImport({
    @cInclude("clap/ext/latency.h");
});
pub const tail = @cImport({
    @cInclude("clap/ext/tail.h");
});
pub const thread_check = @cImport({
    @cInclude("clap/ext/thread-check.h");
});
pub const log = @cImport({
    @cInclude("clap/ext/log.h");
});
pub const gui = @cImport({
    @cInclude("clap/ext/gui.h");
});
pub const thread_pool = @cImport({
    @cInclude("clap/ext/thread-pool.h");
});
pub const timer_support = @cImport({
    @cInclude("clap/ext/timer-support.h");
});
