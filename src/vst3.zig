pub const abi = @import("vst3/abi.zig");
pub const scan = @import("vst3/scan.zig");
pub const module = @import("vst3/module.zig");
pub const plugin = @import("vst3/plugin.zig");
pub const Vst3Plugin = plugin.Vst3Plugin;

test {
    _ = abi;
    _ = scan;
    _ = module;
    _ = plugin;
}
