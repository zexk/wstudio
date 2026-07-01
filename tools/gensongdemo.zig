//! Generate the shipped song-mode demo, `song-demo.wsj`.
//!
//! Run with `zig build gensongdemo`. Loads the curated four-track starter
//! (`demo.wsj` — regenerate that first with `zig build gendemo` if you changed
//! it), then arranges its live loops into a 16-bar song by stamping clips onto
//! the timeline exactly as the `A` view does. Enables song mode and serialises
//! with the normal project saver. Open it with `wstudio song-demo.wsj` and hit
//! space — the transport sweeps the arrangement instead of looping every track.
//!
//! Song structure (bars, 4/4):
//!   0–1   drums only              (intro)
//!   2–7   + bass + e-piano        (groove)
//!   8–13  + lead                  (full)
//!   14–15 drums + e-piano         (outro; lead & bass drop out)
//!
//! Melodic loops are two bars (8 beats) so their clips span two bars; the drum
//! loop is one bar (16 steps) so it is stamped bar by bar.

const std = @import("std");
const ws = @import("wstudio");

const in_path = "demo.wsj";
const out_path = "song-demo.wsj";

// Track indices in demo.wsj.
const lead = 0;
const epiano = 1;
const bass = 2;
const drums = 3;

const song_bars = 16;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var session = ws.persist.load(gpa, io, in_path) catch |err| {
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print(
            "gensongdemo: cannot read {s} ({s}) — run `zig build gendemo` first\n",
            .{ in_path, @errorName(err) },
        );
        try w.interface.flush();
        return err;
    };
    defer session.deinit();

    // Melodic clips are stamped on the even downbeats their two-bar loops fill.
    for ([_]u32{ 8, 10, 12 }) |bar| try session.stampClip(lead, bar);
    for ([_]u32{ 2, 4, 6, 8, 10, 12, 14 }) |bar| try session.stampClip(epiano, bar);
    for ([_]u32{ 2, 4, 6, 8, 10, 12 }) |bar| try session.stampClip(bass, bar);

    // The one-bar drum loop underpins the whole song, stamped bar by bar.
    var bar: u32 = 0;
    while (bar < song_bars) : (bar += 1) try session.stampClip(drums, bar);

    // Ship it in song mode so the arrangement drives playback on open.
    session.setSongMode(true);

    const bars = session.arrangement.lengthBars();
    try ws.persist.save(gpa, &session, io, out_path);

    // Reload what we just wrote so a broken save never ships silently.
    var check = try ws.persist.load(gpa, io, out_path);
    defer check.deinit();
    std.debug.assert(check.song_mode);
    std.debug.assert(check.arrangement.lengthBars() == bars);

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    try stdout.print("wrote {s} ({d} bars, {d} tracks) — reload ok\n", .{
        out_path, bars, session.project.tracks.items.len,
    });
    try stdout.flush();
}
