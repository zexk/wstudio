//! Out-of-process sandboxing for hosted CLAP/VST3 plugins. `transport`
//! carries the real-time audio/event path over shared memory; `rpc` is the
//! control-path protocol over the child's stdin/stdout; `bridge` is the
//! parent-side handle (spawn, supervise, call). The child process itself
//! is `plugin_host/child_main.zig`, built as its own executable
//! (`wstudio-plugin-bridge`) by build.zig.

pub const transport = @import("plugin_host/transport.zig");
pub const rpc = @import("plugin_host/rpc.zig");
pub const bridge = @import("plugin_host/bridge.zig");
pub const editor_window = @import("plugin_host/editor_window.zig");

test {
    _ = transport;
    _ = rpc;
    _ = bridge;
    _ = editor_window;
}
