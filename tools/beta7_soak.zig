//! Beta.7 production-workflow soak using existing Session, persistence, and
//! bounce paths. Simulates one hour as fast as host CPU permits.

const std = @import("std");
const ws = @import("wstudio");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const project_path = args.next() orelse "demo.wsj";

    var session = try ws.persist.load(init.gpa, init.io, project_path);
    defer session.deinit();
    session.engine.transport.play();

    const target_frames: u64 = @as(u64, session.project.sample_rate) * 60 * 60;
    var rendered_frames: u64 = 0;
    var blocks: u64 = 0;
    var peak: f32 = 0;
    var block: [ws.types.max_block_frames * ws.engine.channels]ws.types.Sample = undefined;
    while (rendered_frames < target_frames) : (blocks += 1) {
        if (blocks > 0 and blocks % 4096 == 0) {
            session.engine.transport.stop();
            session.engine.process(&block);
            session.engine.transport.seekFrames((blocks * 997) % target_frames);
            session.engine.transport.play();
        }
        session.engine.process(&block);
        for (block) |sample| {
            if (!std.math.isFinite(sample)) return error.NonFiniteAudio;
            peak = @max(peak, @abs(sample));
        }
        rendered_frames += ws.types.max_block_frames;
    }
    if (peak == 0) return error.SilentProject;

    try std.Io.Dir.cwd().createDirPath(init.io, ".zig-cache/beta7-soak");
    const roundtrip_path = ".zig-cache/beta7-soak/roundtrip.wsj";
    for (0..10) |_| {
        try ws.persist.save(init.gpa, &session, init.io, roundtrip_path);
        var loaded = try ws.persist.load(init.gpa, init.io, roundtrip_path);
        loaded.deinit();
    }
    const bounce_range = ws.bounce.range(&session, 2);
    for (0..3) |i| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/beta7-soak/export-{d}.wav", .{i + 1});
        try ws.bounce.writeFile(init.gpa, init.io, path, &session, bounce_range, .pcm16);
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.print("soaked {d} frames in {d} blocks; 10 round trips; 3 exports; peak {d:.3}\n", .{ rendered_frames, blocks, peak });
    try stdout_writer.interface.flush();
}
