//! Exercises the two failure modes out-of-process sandboxing exists for:
//! a plugin process that crashes, and one that stops responding without
//! exiting. Drives `Bridge` directly (not through `ClapPlugin`) so the
//! child can be killed/stopped from outside without needing a
//! deliberately-misbehaving plugin fixture - a real SIGKILL/SIGSTOP is a
//! more faithful stand-in for "third-party plugin misbehaves" than a
//! cooperative one anyway.

const std = @import("std");
const ws = @import("wstudio");
const bridge_mod = ws.plugin_host.bridge;
const transport = ws.plugin_host.transport;

/// Generous bound for "the bridge noticed and stopped waiting" - well
/// above `Bridge`'s internal 40ms per-block deadline and reaper latency,
/// well below "this looks like a hang" from a human running the suite.
const assert_bound_ns: u64 = 2 * std.time.ns_per_s;

fn expectWithin(deadline_ns: u64, predicate: anytype) !void {
    if (!transport.waitUntil(deadline_ns, predicate)) return error.TimedOutWaitingForCondition;
}

pub fn main(init: std.process.Init) !void {
    // The whole sandboxing feature is Linux-only for now (see
    // bridge.zig's doc comment) - `Bridge.spawn` itself would just
    // return `error.SandboxUnsupportedOnThisPlatform` here, so skip
    // outright rather than fail CI on the platforms that don't build the
    // bridge child at all yet.
    if (@import("builtin").os.tag != .linux) return;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const plugin_path = args.next() orelse return error.MissingPluginPath;

    try testCrash(init.gpa, plugin_path);
    try testHang(init.gpa, plugin_path);
}

fn testCrash(gpa: std.mem.Allocator, plugin_path: []const u8) !void {
    const b = try bridge_mod.Bridge.spawn(gpa, .{ .kind = .clap, .path = plugin_path, .plugin_id = "", .sample_rate = 48_000 });
    defer b.deinit();

    // Sanity: the bridge actually works before we kill it.
    var buf = [_]f32{ 1, 1, 1, 1 };
    b.processBlock(&buf, &.{}, null);
    try std.testing.expect(!b.isDead());

    const pid = b.child.id orelse return error.NoChildPid;
    try std.posix.kill(pid, .KILL);

    const DeadPred = struct {
        b: *bridge_mod.Bridge,
        pub fn check(p: @This()) bool {
            return p.b.isDead();
        }
    };
    try expectWithin(transport.monotonicNs() + assert_bound_ns, DeadPred{ .b = b });

    // Post-crash: process() must degrade to silence, never hang or
    // propagate the crash to this (parent) process.
    buf = .{ 1, 1, 1, 1 };
    const before = transport.monotonicNs();
    b.processBlock(&buf, &.{}, null);
    const elapsed = transport.monotonicNs() - before;
    try std.testing.expect(elapsed < assert_bound_ns);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &buf);

    // `deinit()` on an already-dead bridge must not hang or hit the
    // kill-on-an-already-reaped-pid panic this test would otherwise catch
    // (see bridge.zig's `deinit` doc comment for the incident this guards).
}

fn testHang(gpa: std.mem.Allocator, plugin_path: []const u8) !void {
    const b = try bridge_mod.Bridge.spawn(gpa, .{ .kind = .clap, .path = plugin_path, .plugin_id = "", .sample_rate = 48_000 });
    defer b.deinit();

    var buf = [_]f32{ 1, 1, 1, 1 };
    b.processBlock(&buf, &.{}, null);
    try std.testing.expect(!b.isDead());

    const pid = b.child.id orelse return error.NoChildPid;
    try std.posix.kill(pid, .STOP); // stuck, not exited - the reaper's wait() won't fire
    var status: u32 = 0;
    if (std.os.linux.waitpid(pid, &status, std.os.linux.W.UNTRACED) != @as(usize, @intCast(pid)) or
        !std.os.linux.W.IFSTOPPED(status)) return error.ChildDidNotStop;

    buf = .{ 1, 1, 1, 1 };
    const before = transport.monotonicNs();
    b.processBlock(&buf, &.{}, null);
    const elapsed = transport.monotonicNs() - before;
    // Must return (silence) well before this bound, entirely on its own
    // per-block deadline - not wait for the process to become responsive
    // again, which it never will without the SIGCONT below.
    try std.testing.expect(elapsed < assert_bound_ns);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &buf);

    // SIGKILL terminates even a stopped (SIGSTOP'd) process on Linux, so
    // this alone - no SIGCONT needed - lets `deinit()`'s reaper `wait()`
    // complete during cleanup.
    try std.posix.kill(pid, .KILL);
}
