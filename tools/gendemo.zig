//! Generate the shipped demo project, `demo.wsj`.
//!
//! Run with `zig build gendemo`. Builds the curated four-track starter session
//! (supersaw lead, FM e-piano, FM bass, drum machine) that used to live in
//! `Session.initDefault`, then arranges its loops into a 16-bar song on the
//! timeline (the same way the `A` view stamps clips) and ships in song mode.
//! Re-run after changing the demo and commit the refreshed `demo.wsj`. Open it
//! with `wstudio demo.wsj` and hit space — the transport sweeps the
//! arrangement instead of looping every track (press `A`, then `T` to compare
//! with pattern mode).
//!
//! Song structure (bars, 4/4):
//!   0–1   drums only              (intro)
//!   2–7   + bass + e-piano        (groove)
//!   8–13  + lead                  (full)
//!   14–15 drums + e-piano         (outro; lead & bass drop out)
//!
//! Melodic loops are two bars (8 beats) so their clips span two bars; the drum
//! loop is one bar (16 steps) so it is stamped bar by bar. The drums carry two
//! pattern variants: A is the main groove, B adds a snare/tom fill on the last
//! beat and is stamped on every 4th bar (3, 7, 11, 15) — the same flow as
//! cycling patterns with `[`/`]` in the arrangement view.

const std = @import("std");
const ws = @import("wstudio");

const out_path = "demo.wsj";

// Track indices, assigned below.
const lead = 0;
const epiano = 1;
const bass = 2;
const drums = 3;

const song_bars = 16;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var session = try ws.Session.initDefault(gpa);
    defer session.deinit();

    // ── Track 0 — supersaw lead ──────────────────────────────────────────────
    try session.setInstrument(0, .poly_synth);
    try session.project.renameTrack(0, "lead");
    {
        const s = &session.racks.items[0].instrument.poly_synth;
        s.waveform = .saw;
        s.unison = 7;
        s.unison_detune = 35.0;
        s.unison_spread = 0.7;
        s.osc_b_on = true;
        s.osc_b_waveform = .saw;
        s.osc_b_semi = -12.0;
        s.osc_b_detune_cents = 5.0;
        s.osc_b_level = 0.55;
        s.osc_b_unison = 2;
        s.osc_b_unison_detune = 10.0;
        s.filter_cutoff = 9_000.0;
        s.attack_s = 0.012;
        s.release_s = 0.4;
        const r = session.racks.items[0];
        r.fx.comp = ws.dsp.Compressor.init(session.project.sample_rate);
        r.fx.delay = try ws.dsp.StereoDelay.init(gpa, session.project.sample_rate, 2.0);
        r.fx.delay.?.setTime(0.375);
        r.fx.reverb = try ws.dsp.Reverb.init(gpa, session.project.sample_rate);
        const pp = &r.pattern_player.?;
        pp.length_beats = 8.0;
        // A simple two-bar arpeggio over Am.
        const notes = [_]struct { p: u7, b: f64 }{
            .{ .p = 69, .b = 0.0 }, .{ .p = 72, .b = 0.5 }, .{ .p = 76, .b = 1.0 }, .{ .p = 72, .b = 1.5 },
            .{ .p = 69, .b = 2.0 }, .{ .p = 72, .b = 2.5 }, .{ .p = 77, .b = 3.0 }, .{ .p = 76, .b = 3.5 },
        };
        for (notes) |n| pp.addNote(.{ .pitch = n.p, .start_beat = n.b, .duration_beat = 0.5, .velocity = 0.8 });
    }

    // ── Track 1 — FM electric piano ──────────────────────────────────────────
    _ = try session.addTrack("e-piano");
    try session.setInstrument(1, .poly_synth);
    session.project.tracks.items[1].gain_db = -3.0;
    {
        const s = &session.racks.items[1].instrument.poly_synth;
        s.waveform = .sine;
        s.osc_b_on = true;
        s.osc_b_waveform = .sine;
        s.osc_b_level = 0.0;
        s.mod_mode = .fm_b_to_a;
        s.mod_amount = 2.5;
        s.attack_s = 0.003;
        s.decay_s = 1.8;
        s.sustain = 0.0;
        s.release_s = 0.3;
        s.filter_cutoff = 8_000.0;
        s.fenv_amount = 1.2;
        s.fenv_attack_s = 0.005;
        s.fenv_decay_s = 0.35;
        s.fenv_sustain = 0.0;
        s.noise_level = 0.06;
        s.noise_color = 1.0;
        s.gain = 0.32;
        const r = session.racks.items[1];
        r.fx.reverb = try ws.dsp.Reverb.init(gpa, session.project.sample_rate);
        r.fx.reverb.?.mix = 0.22;
        const pp = &r.pattern_player.?;
        pp.length_beats = 8.0;
        // Am — F chord stabs.
        const chords = [_]struct { p: u7, b: f64 }{
            .{ .p = 57, .b = 0.0 }, .{ .p = 60, .b = 0.0 }, .{ .p = 64, .b = 0.0 },
            .{ .p = 53, .b = 4.0 }, .{ .p = 57, .b = 4.0 }, .{ .p = 60, .b = 4.0 },
        };
        for (chords) |n| pp.addNote(.{ .pitch = n.p, .start_beat = n.b, .duration_beat = 3.5, .velocity = 0.7 });
    }

    // ── Track 2 — FM bass ────────────────────────────────────────────────────
    _ = try session.addTrack("bass");
    try session.setInstrument(2, .poly_synth);
    session.project.tracks.items[2].gain_db = -3.0;
    {
        const s = &session.racks.items[2].instrument.poly_synth;
        s.waveform = .saw;
        s.voice_mode = .mono;
        s.glide_s = 0.05;
        s.osc_b_on = true;
        s.osc_b_waveform = .sine;
        s.osc_b_level = 0.0;
        s.mod_mode = .fm_b_to_a;
        s.mod_amount = 3.5;
        s.sub_level = 0.45;
        s.sub_shape = .sine;
        s.attack_s = 0.006;
        s.decay_s = 0.28;
        s.sustain = 0.6;
        s.release_s = 0.15;
        s.filter_cutoff = 1_100.0;
        s.filter_res = 0.2;
        s.fenv_amount = 2.2;
        s.fenv_attack_s = 0.004;
        s.fenv_decay_s = 0.22;
        s.fenv_sustain = 0.0;
        s.gain = 0.40;
        const r = session.racks.items[2];
        r.fx.comp = ws.dsp.Compressor.init(session.project.sample_rate);
        const pp = &r.pattern_player.?;
        pp.length_beats = 8.0;
        // Root notes: A1 for the Am bar, F1 for the F bar.
        const notes = [_]struct { p: u7, b: f64 }{
            .{ .p = 33, .b = 0.0 }, .{ .p = 33, .b = 1.0 }, .{ .p = 33, .b = 2.0 }, .{ .p = 33, .b = 3.0 },
            .{ .p = 29, .b = 4.0 }, .{ .p = 29, .b = 5.0 }, .{ .p = 29, .b = 6.0 }, .{ .p = 29, .b = 7.0 },
        };
        for (notes) |n| pp.addNote(.{ .pitch = n.p, .start_beat = n.b, .duration_beat = 0.9, .velocity = 0.85 });
    }

    // ── Track 3 — drum machine (ships with its default groove) ────────────────
    _ = try session.addTrack("drums");
    try session.setInstrument(3, .drum_machine);

    // ── Arrange the loops into a 16-bar song ─────────────────────────────────
    // Melodic clips are stamped on the even downbeats their two-bar loops fill.
    for ([_]u32{ 8, 10, 12 }) |bar| try session.stampClip(lead, bar);
    for ([_]u32{ 2, 4, 6, 8, 10, 12, 14 }) |bar| try session.stampClip(epiano, bar);
    for ([_]u32{ 2, 4, 6, 8, 10, 12 }) |bar| try session.stampClip(bass, bar);

    // Variant B: the main groove plus a snare/tom fill on beat 4.
    const dm = &session.racks.items[drums].instrument.drum_machine;
    std.debug.assert(dm.addVariant());
    _ = dm.pattern[1].fetchOr(0b1010 << 12, .acq_rel); // snare on steps 13, 15
    _ = dm.pattern[5].fetchOr(1 << 12, .acq_rel); // tom-1 on step 13
    _ = dm.pattern[6].fetchOr(1 << 14, .acq_rel); // tom-2 on step 15

    // The one-bar drum loop underpins the whole song: groove (A) bar by bar,
    // with the fill (B) closing every 4-bar phrase.
    var bar: u32 = 0;
    while (bar < song_bars) : (bar += 1) {
        dm.selectVariant(if (bar % 4 == 3) 1 else 0);
        try session.stampClip(drums, bar);
    }
    dm.selectVariant(0); // leave the groove live for pattern mode

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
