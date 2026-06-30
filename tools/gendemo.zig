//! Generate the shipped demo project, `demo.wsj`.
//!
//! Run with `zig build gendemo`. Builds the curated four-track starter session
//! (supersaw lead, FM e-piano, FM bass, drum machine) that used to live in
//! `Session.initDefault`, then serialises it with the normal project saver.
//! Re-run after changing the demo and commit the refreshed `demo.wsj`. Open it
//! with `wstudio demo.wsj`.

const std = @import("std");
const ws = @import("wstudio");

const out_path = "demo.wsj";

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
        const lead = [_]struct { p: u7, b: f64 }{
            .{ .p = 69, .b = 0.0 }, .{ .p = 72, .b = 0.5 }, .{ .p = 76, .b = 1.0 }, .{ .p = 72, .b = 1.5 },
            .{ .p = 69, .b = 2.0 }, .{ .p = 72, .b = 2.5 }, .{ .p = 77, .b = 3.0 }, .{ .p = 76, .b = 3.5 },
        };
        for (lead) |n| pp.addNote(.{ .pitch = n.p, .start_beat = n.b, .duration_beat = 0.5, .velocity = 0.8 });
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
        const bass = [_]struct { p: u7, b: f64 }{
            .{ .p = 33, .b = 0.0 }, .{ .p = 33, .b = 1.0 }, .{ .p = 33, .b = 2.0 }, .{ .p = 33, .b = 3.0 },
            .{ .p = 29, .b = 4.0 }, .{ .p = 29, .b = 5.0 }, .{ .p = 29, .b = 6.0 }, .{ .p = 29, .b = 7.0 },
        };
        for (bass) |n| pp.addNote(.{ .pitch = n.p, .start_beat = n.b, .duration_beat = 0.9, .velocity = 0.85 });
    }

    // ── Track 3 — drum machine (ships with its default groove) ────────────────
    _ = try session.addTrack("drums");
    try session.setInstrument(3, .drum_machine);

    try ws.persist.save(gpa, &session, io, out_path);

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    try stdout.print("wrote {s} ({d} tracks)\n", .{ out_path, session.project.tracks.items.len });
    try stdout.flush();
}
