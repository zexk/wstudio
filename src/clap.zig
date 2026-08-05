pub const abi = @import("clap/abi.zig");
pub const scan = @import("clap/scan.zig");
pub const plugin = @import("clap/plugin.zig");
pub const ClapPlugin = plugin.ClapPlugin;

test {
    _ = abi;
    _ = scan;
    _ = plugin;
}
