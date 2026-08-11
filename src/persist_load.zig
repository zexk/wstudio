//! Project load path: parse JSON into a live Session. Split out of
//! persist.zig.

const std = @import("std");
const Session = @import("session.zig").Session;
const wav = @import("core/wav.zig");
const types = @import("core/types.zig");
const theory = @import("theory.zig");
const controller_mod = @import("dsp/controller.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;
const track_color_count = project_mod.track_color_count;
const ws_arrangement = @import("arrangement.zig");
const time_grid = @import("time_grid.zig");
const rack_mod = @import("rack.zig");
const Rack = rack_mod.Rack;
const Fx = rack_mod.Fx;
const engine_mod = @import("audio/engine.zig");
const Engine = engine_mod.Engine;
const Transport = @import("transport.zig").Transport;
const synth_mod = @import("dsp/synth.zig");
const PolySynth = synth_mod.PolySynth;
const wavetable_mod = @import("dsp/wavetable.zig");
const pattern_mod = @import("dsp/pattern.zig");
const dsp_mod = @import("dsp/device.zig");
const PatternPlayer = pattern_mod.PatternPlayer;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const drum_kit = @import("dsp/drum_kit.zig");
const pad_mod = @import("dsp/pad.zig");
const Pad = pad_mod.Pad;
const lfo_mod = @import("dsp/lfo.zig");
const Sampler = @import("dsp/sampler.zig").Sampler;
const Slicer = @import("dsp/slicer.zig").Slicer;
const SoundfontPlayer = @import("dsp/soundfont_player.zig").SoundfontPlayer;
const soundfont_mod = @import("dsp/soundfont.zig");
const Compressor = @import("dsp/compressor.zig").Compressor;
const multiband_comp_mod = @import("dsp/multiband_comp.zig");
const Reverb = @import("dsp/reverb.zig").Reverb;
const eq_mod = @import("dsp/eq.zig");
const Gate = @import("dsp/gate.zig").Gate;
const Saturator = @import("dsp/saturator.zig").Saturator;
const Crusher = @import("dsp/crusher.zig").Crusher;
const Phaser = @import("dsp/phaser.zig").Phaser;
const dsp = @import("dsp/device.zig");
const automation_mod = @import("dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;

const persist_types = @import("persist_types.zig");
const persist_save = @import("persist_save.zig");
const joinWsjRel = persist_save.joinWsjRel;
const file_version = persist_types.file_version;
const AutomationPointSnap = persist_types.AutomationPointSnap;
const SynthParamAutomationSnap = persist_types.SynthParamAutomationSnap;
const NoteSnap = persist_types.NoteSnap;
const SynthSnap = persist_types.SynthSnap;
const PadSnap = persist_types.PadSnap;
const DrumNoteSnap = persist_types.DrumNoteSnap;
const VariantSnap = persist_types.VariantSnap;
const DrumSnap = persist_types.DrumSnap;
const CompSnap = persist_types.CompSnap;
const MultibandCompSnap = persist_types.MultibandCompSnap;
const OttSnap = persist_types.OttSnap;
const DelaySnap = persist_types.DelaySnap;
const ReverbSnap = persist_types.ReverbSnap;
const EqBandKindSnap = persist_types.EqBandKindSnap;
const EqStereoModeSnap = persist_types.EqStereoModeSnap;
const EqBandSnap = persist_types.EqBandSnap;
const EqSnap = persist_types.EqSnap;
const GateSnap = persist_types.GateSnap;
const SatSnap = persist_types.SatSnap;
const CrushSnap = persist_types.CrushSnap;
const ChorusSnap = persist_types.ChorusSnap;
const PhaserSnap = persist_types.PhaserSnap;
const FlangerSnap = persist_types.FlangerSnap;
const TapeSnap = persist_types.TapeSnap;
const FreqShiftSnap = persist_types.FreqShiftSnap;
const FilterSnap = persist_types.FilterSnap;
const LimiterSnap = persist_types.LimiterSnap;
const UtilitySnap = persist_types.UtilitySnap;
const StereoWidthSnap = persist_types.StereoWidthSnap;
const AutoPanSnap = persist_types.AutoPanSnap;
const TransientShaperSnap = persist_types.TransientShaperSnap;
const ClapSnap = persist_types.ClapSnap;
const Vst3Snap = persist_types.Vst3Snap;
const FxUnitSnap = persist_types.FxUnitSnap;
const SamplerSnap = persist_types.SamplerSnap;
const SlicerSnap = persist_types.SlicerSnap;
const SoundfontSnap = persist_types.SoundfontSnap;
const RackSnap = persist_types.RackSnap;
const TrackSnap = persist_types.TrackSnap;
const SendSnap = persist_types.SendSnap;
const GroupSnap = persist_types.GroupSnap;
const ClipKind = persist_types.ClipKind;
const ClipSnap = persist_types.ClipSnap;
const LaneSnap = persist_types.LaneSnap;
const SectionSnap = persist_types.SectionSnap;
const Snapshot = persist_types.Snapshot;

/// Inverse of `persist_save.snapFromDevice`: write a Snap's fields onto a
/// live device by name, leaving the device's other (runtime-state) fields
/// untouched.
pub fn applySnapToDevice(device: anytype, snap: anytype) void {
    inline for (std.meta.fields(@TypeOf(snap))) |f| {
        const value = @field(snap, f.name);
        switch (@typeInfo(f.type)) {
            .float => if (std.math.isFinite(value)) {
                @field(device.*, f.name) = value;
            },
            else => @field(device.*, f.name) = value,
        }
    }
}

/// Parse `path` and build a new Session from it.
/// Must be called before the audio backend starts (the backend captures
/// the engine pointer at init; swapping mid-session is unsafe in v1).
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Session {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(Snapshot, allocator, data, .{});
    defer parsed.deinit();

    var session = try buildSession(allocator, &parsed.value);
    restoreSamples(allocator, io, path, &parsed.value, &session);
    restoreAudioSources(allocator, io, path, &parsed.value, &session);
    if (session.song_mode) session.rebuildSongData();
    return session;
}

fn restoreAudioSources(allocator: std.mem.Allocator, io: std.Io, path: []const u8, snap: *const Snapshot, session: *Session) void {
    for (snap.audio_sources) |source| {
        if (source.id == 0 or source.channel_count == 0 or source.channel_count > 2 or source.file.len == 0) continue;
        const data = readWsjRel(allocator, io, path, source.file) orelse continue;
        defer allocator.free(data);
        const parsed = wav.parseInterleavedAlloc(allocator, data) catch continue;
        defer allocator.free(parsed.samples);
        if (parsed.channel_count != source.channel_count) continue;
        session.project.addAudioSourceWithId(source.id, source.file, parsed.sample_rate, parsed.channel_count, parsed.samples) catch continue;
    }
}

/// Load the sidecar WAVs referenced by pad snapshots back into the session's
/// pads. Failures are per-pad and non-fatal: a missing or unreadable sample
/// file leaves that pad on its shipped/generated audio, params intact.
pub fn restoreSamples(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    snap: *const Snapshot,
    session: *Session,
) void {
    for (snap.racks, session.racks.items) |rs, rack| {
        switch (rack.instrument) {
            .drum_machine => |*dm| {
                const ds = rs.content.drum_machine;
                for (ds.pads, 0..) |ps, pi| {
                    if (pi >= DrumMachine.max_pads) break;
                    if (ps.sample_file.len == 0) {
                        // No user sample to load, but a `:rename` on a
                        // shipped-kit pad still needs its name restored.
                        // Null (unmaterialized) pads have nothing to rename.
                        if (ps.name.len > 0) {
                            if (dm.pads[pi]) |*sm| sm.rename(ps.name);
                        }
                        continue;
                    }
                    const data = readWsjRel(allocator, io, path, ps.sample_file) orelse continue;
                    defer allocator.free(data);
                    // loadPadWav swaps audio + name under the pad lock and
                    // keeps the params already applied by buildSession, and
                    // materializes the pad if it wasn't already.
                    dm.loadPadWav(@intCast(pi), data, sampleName(ps)) catch continue;
                    dm.pads[pi].?.pad.user_sample = true;
                }
            },
            .sampler => |*s| {
                const smp = rs.content.sampler;
                if (smp.pad.sample_file.len == 0) {
                    if (smp.pad.name.len > 0) s.rename(smp.pad.name);
                    continue;
                }
                const data = readWsjRel(allocator, io, path, smp.pad.sample_file) orelse continue;
                defer allocator.free(data);
                // loadWav swaps audio + name under the pad lock and keeps the
                // params applied by buildSession.
                s.loadWav(data, sampleName(smp.pad)) catch continue;
                s.pad.user_sample = true;
            },
            .slicer => |*sl| {
                const sls = rs.content.slicer;
                if (sls.sample_file.len == 0) continue; // empty slicer, nothing to restore
                const data = readWsjRel(allocator, io, path, sls.sample_file) orelse continue;
                defer allocator.free(data);
                const name = if (sls.name.len > 0) sls.name else std.fs.path.stem(sls.sample_file);
                // reset_slices=false: buildSession already applied every
                // slice's saved start/end/etc. from `sls.slices` - this must
                // only swap the audio bytes, not wipe that back out (see
                // Slicer.loadWav's own doc comment).
                sl.loadWav(data, name, false) catch continue;
                sl.user_sample = true;
            },
            .poly_synth => |*s| {
                const ss = rs.content.poly_synth;
                if (ss.wt_file.len > 0) {
                    if (readWsjRel(allocator, io, path, ss.wt_file)) |data| {
                        defer allocator.free(data);
                        s.loadWavetable(.a, data) catch {};
                    }
                }
                if (ss.osc_b_wt_file.len > 0) {
                    if (readWsjRel(allocator, io, path, ss.osc_b_wt_file)) |data| {
                        defer allocator.free(data);
                        s.loadWavetable(.b, data) catch {};
                    }
                }
                if (ss.osc_c_wt_file.len > 0) {
                    if (readWsjRel(allocator, io, path, ss.osc_c_wt_file)) |data| {
                        defer allocator.free(data);
                        s.loadWavetable(.c, data) catch {};
                    }
                }
            },
            .soundfont, .acoustic => |*sf| {
                const sfs = switch (rs.content) {
                    .soundfont => |v| v,
                    .acoustic => |v| v,
                    else => continue,
                };
                if (std.meta.stringToEnum(@import("dsp/builtin_library.zig").Id, sfs.library)) |id| {
                    sf.loadBuiltin(io, id) catch continue;
                    sf.selectPresetIndex(sfs.preset_index);
                    continue;
                }
                if (sfs.sf2_file.len == 0) continue; // nothing loaded
                const data = readWsjRel(allocator, io, path, sfs.sf2_file) orelse continue;
                defer allocator.free(data);
                // loadSf2 resets preset_index to 0 - re-apply the saved
                // selection only after it succeeds.
                sf.loadSf2(data) catch continue;
                sf.selectPresetIndex(sfs.preset_index);
            },
            else => {},
        }
    }
}

/// Read a sample file stored relative to the .wsj. Null on any error.
/// 512MiB covers every sidecar kind this reads, including a full GM
/// SoundFont bank (real-world ones run tens to a couple hundred MB) - every
/// other sidecar (a WAV clip/pad/wavetable) is far smaller in practice, so
/// raising the ceiling for soundfonts costs nothing for them.
pub fn readWsjRel(allocator: std.mem.Allocator, io: std.Io, wsj_path: []const u8, rel: []const u8) ?[]u8 {
    const full = joinWsjRel(allocator, wsj_path, rel) catch return null;
    defer allocator.free(full);
    return std.Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(512 * 1024 * 1024)) catch null;
}

/// Display name for a restored sample: the saved name, else the file stem.
pub fn sampleName(ps: PadSnap) []const u8 {
    return if (ps.name.len > 0) ps.name else std.fs.path.stem(ps.sample_file);
}

/// A saved modulation target, or null if it cannot be trusted. A target
/// naming a track this file does not have would drive a param on whatever
/// track later takes that index, and a degenerate range would leave the
/// mapping math dividing by nothing - the same call `remapTrackReferences`
/// makes when a track is deleted. Shared by the controller bank and the
/// learned CC map, which sanitize identically.
fn sanitizeControllerTarget(ts: persist_types.ControllerTargetSnap, track_count: usize) ?controller_mod.Target {
    if (ts.track >= track_count) return null;
    const lo = finiteClamp(f32, ts.lo, -1e9, 1e9, 0.0);
    const hi = finiteClamp(f32, ts.hi, -1e9, 1e9, 1.0);
    if (!(hi > lo)) return null;
    return .{
        .track = ts.track,
        .instance_id = ts.instance_id,
        .param_id = ts.param_id,
        .center = finiteClamp(f32, ts.center, lo, hi, lo),
        .lo = lo,
        .hi = hi,
    };
}

pub fn finiteClamp(comptime T: type, value: T, lo: T, hi: T, fallback: T) T {
    if (!std.math.isFinite(value)) return fallback;
    return std.math.clamp(value, lo, hi);
}

pub fn buildSession(allocator: std.mem.Allocator, snap: *const Snapshot) !Session {
    // Reject files this build cannot represent; clamp what can be clamped.
    // Racks, tracks, and lanes are parallel arrays everywhere downstream
    // (engine slots, editor indices), so a mismatch is a malformed file.
    if (snap.version != file_version) return error.UnsupportedVersion;
    if (snap.tracks.len != snap.racks.len) return error.MalformedProject;
    if (snap.tracks.len > engine_mod.max_tracks) return error.MalformedProject;
    // Every other path holds "a session always has at least one track"
    // (`deleteTrack` refuses to remove the last one), so views index
    // `tracks.items[0]` after a saturating clamp rather than re-checking
    // emptiness. A hand-edited/truncated file with an empty pair would
    // hand them a zero-length list to index.
    if (snap.tracks.len == 0) return error.MalformedProject;
    if (snap.sample_rate < 8_000 or snap.sample_rate > 384_000) return error.InvalidSampleRate;
    const beats_per_bar = std.math.clamp(snap.beats_per_bar, 1, 16);
    for (snap.arrangement) |lane| {
        for (lane.clips) |clip| {
            if (clip.length_ticks == 0) return error.MalformedProject;
            if (clip.start_tick > std.math.maxInt(u32) - clip.length_ticks) return error.MalformedProject;
        }
    }

    var project = Project.init(allocator);
    errdefer project.deinit();
    project.sample_rate = snap.sample_rate;
    project.tempo_bpm = finiteClamp(f64, snap.tempo_bpm, 20.0, 400.0, 120.0);
    for (snap.tempo_points) |point| project.setTempoPoint(point) catch return error.MalformedProject;
    project.scale = snap.scale;
    // A hand-edited cents value has to be finite or every note it touches
    // renders silence; ±1200 (an octave either way) is far past any real
    // temperament but still lets someone use the table as a transposer.
    project.tuning.root = snap.tuning.root;
    for (snap.tuning.cents, &project.tuning.cents) |in, *out| {
        out.* = finiteClamp(f32, in, -1200.0, 1200.0, 0.0);
    }
    project.beats_per_bar = beats_per_bar;
    if (!std.math.isPowerOfTwo(snap.meter_denominator) or snap.meter_denominator > 32) return error.MalformedProject;
    project.meter_denominator = snap.meter_denominator;
    for (snap.meter_points) |point| project.setMeterPoint(point) catch return error.MalformedProject;
    project.loop_start_bar = snap.loop_start_bar;
    project.loop_end_bar = snap.loop_end_bar;
    project.loop_enabled = snap.loop_enabled and snap.loop_end_bar > snap.loop_start_bar;
    for (snap.sections) |section| {
        if (section.name.len == 0) continue;
        try project.setSection(section.tick, section.name);
    }
    for (snap.controllers) |cs| {
        if (cs.index >= controller_mod.max_controllers) continue;
        var c: controller_mod.Controller = .{
            .shape = cs.shape,
            // A zero or negative period would divide the phase math by
            // nothing; the upper bound is a 32-bar cycle, well past any
            // musical use and short of the precision cliff.
            .beats = finiteClamp(f32, cs.beats, 0.01, 128.0, 4.0),
            .depth = finiteClamp(f32, cs.depth, 0.0, 1.0, 0.5),
            .phase = finiteClamp(f32, cs.phase, 0.0, 1.0, 0.0),
        };
        var slot: usize = 0;
        for (cs.targets) |ts| {
            if (slot == controller_mod.max_targets) break;
            c.targets[slot] = sanitizeControllerTarget(ts, snap.tracks.len) orelse continue;
            slot += 1;
        }
        project.controllers[cs.index] = c;
    }
    var cc_slot: usize = 0;
    for (snap.cc_bindings) |bs| {
        if (cc_slot == controller_mod.max_cc_bindings) break;
        if (bs.cc > 127) continue;
        const target = sanitizeControllerTarget(bs.target, snap.tracks.len) orelse continue;
        project.cc_bindings[cc_slot] = .{ .cc = @intCast(bs.cc), .target = target };
        cc_slot += 1;
    }

    // zig fmt: off
    for (snap.tracks) |t| {
        // Clamped to the palette's actual size (tui/style.zig's
        // track_palette) - the renderer already treats an
        // out-of-range color as "uncolored" gracefully, but clamping here
        // too matches this file's established hand-edited-.wsj hygiene.
        // `group` is only bound-checked here (< max_groups); whether that
        // slot is actually an active group gets swept below, once
        // `snap.groups` itself has been loaded.
        // Extras past `max_sends_per_track` are silently dropped, same
        // "bank of N" convention the engine's own fixed sidechain/group
        // banks already use.
        var sends: [project_mod.max_sends_per_track]?project_mod.SendSlot = @splat(null);
        for (t.sends[0..@min(t.sends.len, project_mod.max_sends_per_track)]) |ss| {
            if (ss.slot >= project_mod.max_sends_per_track) continue;
            sends[ss.slot] = .{
                .target = if (ss.is_group) .{ .group = @min(ss.group, engine_mod.max_groups - 1) } else .master,
                .level = types.dbToGain(finiteClamp(f32, ss.level_db, -60.0, 12.0, -60.0)),
                .pre_fader = ss.pre_fader,
            };
        }
        _ = try project.addTrack(.{
            .name = t.name,
            .gain_db = finiteClamp(f32, t.gain_db, -60.0, 12.0, 0.0),
            .pan = finiteClamp(f32, t.pan, -1.0, 1.0, 0.0),
            .muted = t.muted, .soloed = t.soloed, .color = @min(t.color, track_color_count),
            .group = if (t.group) |g| (if (g < engine_mod.max_groups) g else null) else null,
            .sends = sends,
        });
    }
    // zig fmt: on

    const sr = project.sample_rate;

    const engine = try allocator.create(Engine);
    errdefer allocator.destroy(engine);
    try engine.initInPlace(allocator, sr);
    errdefer engine.deinit();
    engine.loadProject(&project);

    // zig fmt: off
    var racks: std.ArrayListUnmanaged(*Rack) = .empty;
    errdefer {
        for (racks.items) |r| { r.deinit(allocator); allocator.destroy(r); }
        racks.deinit(allocator);
    }

    for (snap.racks) |rs| {
        // Start blank so the errdefer below is always safe (empty has no heap).
        const rack = try allocator.create(Rack);
        rack.* = .{
            .instrument = .empty,
            .label = "",
            .owned_label = false,
        };
        errdefer { rack.deinit(allocator); allocator.destroy(rack); }
        // zig fmt: on

        // Duplicate the label; freed by Rack.deinit when owned_label = true.
        rack.label = try allocator.dupe(u8, rs.label);
        rack.owned_label = true;

        // zig fmt: off
        switch (rs.content) {
            .empty => {},
            .poly_synth => |ss| {
                const synth = try PolySynth.init(allocator, sr);
                rack.instrument = .{ .poly_synth = synth };
                // PatternPlayer holds a pointer into the heap-allocated Rack -
                // must be set AFTER the instrument lands in the rack. Same
                // for the synth's own transport (tempo-synced LFOs/arp).
                rack.instrument.poly_synth.attachTransport(&engine.transport);
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                try applyToSynth(&rack.instrument.poly_synth, &ss);
                    // Same clamp the clip loader applies: a zero/negative/
                    // non-finite loop length breaks the piano roll's step
                    // math and the playback wrap.
                    rack.pattern_player.?.length_beats = finiteClamp(f64, ss.pattern.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, ss.pattern.notes);
                    rack.pattern_player.?.setMidiEvents(ss.pattern.midi_events);
                    rack.pattern_player.?.setSwing(ss.pattern.swing);
            },
            .sampler => |smp| {
                const sampler = try Sampler.init(allocator, sr);
                rack.instrument = .{ .sampler = sampler };
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                const s = &rack.instrument.sampler;
                    applyPadSnap(&s.pad, smp.pad);
                    s.root_note = @intCast(@min(smp.root_note, 127));
                    s.mono = smp.mono;
                    rack.pattern_player.?.length_beats = finiteClamp(f64, smp.pattern.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, smp.pattern.notes);
                    rack.pattern_player.?.setMidiEvents(smp.pattern.midi_events);
                    rack.pattern_player.?.setSwing(smp.pattern.swing);
            },
            .drum_machine => |ds| {
                const drum_machine = try DrumMachine.init(allocator, sr, &engine.transport);
                rack.instrument = .{ .drum_machine = drum_machine };
                const dmp = &rack.instrument.drum_machine;
                    // Regenerate the kit first: its pads are the audio the
                    // file never carried (only user samples reach the
                    // sidecar), and the per-pad snapshot below then layers
                    // this project's params over them. An unknown name -
                    // a kit that no longer exists - just leaves them empty.
                    if (ds.kit.len > 0) {
                        if (drum_kit.byName(ds.kit)) |variant| {
                            dmp.loadKitVariant(variant) catch {};
                        }
                    }
                    // Every save writes the whole bank and `variant_count`
                    // never drops below one, so an empty bank is a malformed
                    // file rather than a shape this build can produce.
                    if (ds.variants.len == 0) return error.MalformedProject;
                    for (dmp.variants[0..dmp.variant_count]) |*slot| DrumMachine.freeMidi(allocator, &slot.midi);
                    const count: u8 = @intCast(@min(ds.variants.len, DrumMachine.max_variants));
                    dmp.variant_count = 0;
                    for (ds.variants[0..count], dmp.variants[0..count]) |vs, *slot| {
                        const sc = std.math.clamp(vs.step_count, 1, DrumMachine.max_steps);
                        slot.step_count = sc;
                        slot.steps_per_beat = std.math.clamp(vs.steps_per_beat, 1, 32);
                        slot.midi = try DrumMachine.allocMidi(allocator, sc);
                        dmp.variant_count += 1;
                        applyNoteSnap(&slot.midi, sc, vs.notes);
                    }
                    dmp.variant = @min(ds.variant, count - 1);
                    // The live pattern mirrors the active variant; the
                    // bank is the source of truth.
                    const active = &dmp.variants[dmp.variant];
                    const midi = try DrumMachine.dupeMidi(allocator, &active.midi);
                    DrumMachine.freeMidi(allocator, &dmp.midi);
                    dmp.midi = midi;
                    dmp.step_count = active.step_count;
                    dmp.steps_per_beat = active.steps_per_beat;
                    dmp.swing.store(
                        std.math.clamp(ds.swing, DrumMachine.swing_min, DrumMachine.swing_max),
                        .monotonic,
                    );
                    // The file is the source of truth even when it says
                    // nothing: a default/legacy DrumSnap has an empty slice
                    // here, which must still clear init()'s default hihat
                    // choke pairing, not leave it standing.
                    for (&dmp.choke_group) |*c| c.* = 0;
                    for (ds.choke_group, 0..) |g, pad| {
                        if (pad >= DrumMachine.max_pads) break;
                        dmp.choke_group[pad] = @min(g, DrumMachine.max_choke_groups);
                    }
                    // Same "the file is the source of truth even when silent"
                    // rule as the choke groups above.
                    for (&dmp.pad_len) |*l| l.* = 0;
                    for (ds.pad_len, 0..) |l, pad| {
                        if (pad >= DrumMachine.max_pads) break;
                        dmp.setPadLen(@intCast(pad), l);
                    }
                    // Only materialize a pad the file actually marked `used`
                    // (see PadSnap's doc comment) - an omitted entry or an
                    // explicit `used = false` stays null, matching a pad
                    // nobody ever loaded.
                    for (ds.pads, 0..) |ps, pad| {
                        if (pad >= DrumMachine.max_pads) break;
                        if (!ps.used) continue;
                        // The kit load above may have already materialized
                        // this pad - keep that sampler (its generated audio
                        // is what the file deliberately didn't carry) and
                        // just apply the params over it. applyPadSnap never
                        // touches `.samples`.
                        if (dmp.pads[pad] == null) {
                            dmp.pads[pad] = Sampler.init(allocator, sr) catch continue;
                        }
                        applyPadSnap(&dmp.pads[pad].?.pad, ps);
                    }
            },
            .slicer => |sls| {
                const slicer = try Slicer.init(allocator, sr, &engine.transport);
                rack.instrument = .{ .slicer = slicer };
                const sl = &rack.instrument.slicer;
                    const count: u8 = @intCast(@min(sls.slices.len, Slicer.max_slices));
                    sl.slice_count = count;
                    for (sls.slices[0..count], sl.slices[0..count]) |ps, *p| {
                        p.samples = sl.samples; // applyPadSnap never touches .samples
                        applyPadSnap(p, ps);
                    }
                    // Same "the bank is never empty in a file this build
                    // wrote" rule as the drum machine above.
                    if (sls.variants.len == 0) return error.MalformedProject;
                    for (sl.variants[0..sl.variant_count]) |*slot| Slicer.freeMidi(allocator, &slot.midi);
                    const vcount: u8 = @intCast(@min(sls.variants.len, Slicer.max_variants));
                    sl.variant_count = 0;
                    for (sls.variants[0..vcount], sl.variants[0..vcount]) |vs, *slot| {
                        const sc = std.math.clamp(vs.step_count, 1, Slicer.max_steps);
                        slot.step_count = sc;
                        slot.steps_per_beat = std.math.clamp(vs.steps_per_beat, 1, 32);
                        slot.midi = try Slicer.allocMidi(allocator, sc);
                        sl.variant_count += 1;
                        applyNoteSnap(&slot.midi, sc, vs.notes);
                    }
                    sl.variant = @min(sls.variant, vcount - 1);
                    const active = &sl.variants[sl.variant];
                    const midi = try Slicer.dupeMidi(allocator, &active.midi);
                    Slicer.freeMidi(allocator, &sl.midi);
                    sl.midi = midi;
                    sl.step_count = active.step_count;
                    sl.steps_per_beat = active.steps_per_beat;
                    for (&sl.choke_group) |*c| c.* = 0;
                    for (sls.choke_group, 0..) |g, i| {
                        if (i >= Slicer.max_slices) break;
                        sl.choke_group[i] = @min(g, Slicer.max_choke_groups);
                    }
                    // After the step count is settled above - setSliceLen
                    // reads it to decide whether a length is an override at
                    // all (same order the drum load uses).
                    for (&sl.slice_len) |*l| l.* = 0;
                    for (sls.slice_len, 0..) |l, i| {
                        if (i >= Slicer.max_slices) break;
                        sl.setSliceLen(@intCast(i), l);
                    }
                    sl.setSwing(sls.swing);
            },
            .clap => |cs| {
                if (cs.path.len == 0 or cs.plugin_id.len == 0) return error.MalformedProject;
                const plugin = try rack_mod.ClapPlugin.load(allocator, cs.path, cs.plugin_id, sr);
                var plugin_owned = true;
                errdefer if (plugin_owned) plugin.deinit();
                plugin.attachTransport(&engine.transport);
                try loadClapState(allocator, plugin, cs.state_base64);
                rack.instrument = .{ .clap = plugin };
                plugin_owned = false;
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                rack.pattern_player.?.length_beats = finiteClamp(f64, cs.pattern.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                loadNotes(&rack.pattern_player.?, cs.pattern.notes);
                rack.pattern_player.?.setMidiEvents(cs.pattern.midi_events);
                rack.pattern_player.?.setSwing(cs.pattern.swing);
            },
            .vst3 => |vs| {
                if (vs.path.len == 0 or vs.class_id.len != 32) return error.MalformedProject;
                const plugin = try rack_mod.Vst3Plugin.load(allocator, vs.path, vs.class_id, sr, true);
                var plugin_owned = true;
                errdefer if (plugin_owned) plugin.deinit();
                plugin.attachTransport(&engine.transport);
                try loadVst3State(allocator, plugin, vs.component_state_base64, vs.controller_state_base64);
                rack.instrument = .{ .vst3 = plugin };
                plugin_owned = false;
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                rack.pattern_player.?.length_beats = finiteClamp(f64, vs.pattern.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                loadNotes(&rack.pattern_player.?, vs.pattern.notes);
                rack.pattern_player.?.setMidiEvents(vs.pattern.midi_events);
                rack.pattern_player.?.setSwing(vs.pattern.swing);
            },
            inline .soundfont, .acoustic => |sfs, tag| {
                rack.instrument = @unionInit(rack_mod.Instrument, @tagName(tag), SoundfontPlayer.init(allocator, sr));
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                const sf = &@field(rack.instrument, @tagName(tag));
                    sf.gain = finiteClamp(f32, sfs.gain, 0.0, 2.0, 1.0);
                    sf.pan = finiteClamp(f32, sfs.pan, -1.0, 1.0, 0.0);
                    sf.transpose_semitones = finiteClamp(f32, sfs.transpose_semitones, -24.0, 24.0, 0.0);
                    // preset_index is restored by restoreSamples, after the
                    // sidecar .sf2 (if any) has actually loaded - loadSf2
                    // resets it to 0, so setting it here would be wiped.
                    rack.pattern_player.?.length_beats = finiteClamp(f64, sfs.pattern.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, sfs.pattern.notes);
                    rack.pattern_player.?.setMidiEvents(sfs.pattern.midi_events);
                    rack.pattern_player.?.setSwing(sfs.pattern.swing);
            },
        }

        try applyFxChain(allocator, &rack.fx, rs.fx_chain, sr, &engine.transport);
        try racks.append(allocator, rack);
    }
    // zig fmt: on

    // One blank lane per track keeps the arrangement parallel to racks/tracks;
    // clips (if any) are placed below once the Session owns the arrangement.
    var arrangement: ws_arrangement.Arrangement = .{};
    errdefer arrangement.deinit(allocator);
    for (racks.items) |_| try arrangement.addLane(allocator);

    // Record-arm is session state, not file state - nothing to read back -
    // but the array is positional and must stay exactly as long as `racks`
    // (see `Session.insertTrackSlots`). Left empty, `toggleArm`'s bounds
    // check silently swallowed every `r` on a loaded project, and the first
    // track insert/delete indexed past the end and panicked.
    var armed: std.ArrayListUnmanaged(bool) = .empty;
    errdefer armed.deinit(allocator);
    try armed.appendNTimes(allocator, false, racks.items.len);

    // zig fmt: off
    var self: Session = .{
        .allocator = allocator,
        .project = project,
        .engine = engine,
        .racks = racks,
        .armed = armed,
        .retired_racks = .empty,
        .retired_fx = .empty,
        .arrangement = arrangement,
    };
    for (self.racks.items, 0..) |rack, i| {
        self.syncTrackChain(@intCast(i), rack);
    }

    try applyFxChain(allocator, &self.master_fx, snap.master_fx_chain, sr, &self.engine.transport);
    self.syncMasterChain();
    // zig fmt: on

    // Groups: dense, positional (see GroupSnap's doc comment) - restore
    // exactly the active slots, push each to the engine, then sweep tracks
    // for any `.group` reference that turned out to point at a slot this
    // file never actually marked active (a hand-edited or truncated
    // `groups` array) and null it out, same "clamp on load" hygiene the
    // color/velocity/pad fields already follow.
    const group_count = @min(snap.groups.len, engine_mod.max_groups);
    for (snap.groups[0..group_count], 0..) |gs, i| {
        if (!gs.active) continue;
        const idx: u8 = @intCast(i);
        self.groups[idx] = .{
            .name = try allocator.dupe(u8, gs.name),
            .gain_db = finiteClamp(f32, gs.gain_db, -60.0, 12.0, 0.0),
            .folded = gs.folded,
            .muted = gs.muted,
            .soloed = gs.soloed,
        };
        try applyFxChain(allocator, &self.groups[idx].?.fx, gs.fx_chain, sr, &self.engine.transport);
        self.syncGroupChain(idx);
    }
    for (self.project.tracks.items) |*t| {
        if (t.group) |g| {
            if (g >= group_count or self.groups[g] == null) t.group = null;
        }
    }

    // Restore placed clips, then the song/pattern mode (setSongMode rebuilds the
    // device song buffers from the clips just placed).
    for (snap.arrangement, 0..) |ls, li| {
        const lane = self.arrangement.lane(li) orelse break;
        for (ls.clips) |cs| try lane.place(allocator, try clipFromSnap(allocator, cs));
    }
    for (snap.mix_automation) |lane| {
        switch (lane.target) {
            .master_gain => {},
            .group_gain => |group| if (group >= engine_mod.max_groups) return error.MalformedProject,
            .send_level => |send_target| if (send_target.track >= self.project.tracks.items.len or send_target.slot >= project_mod.max_sends_per_track) return error.MalformedProject,
        }
        try self.mix_automation.append(allocator, .{ .target = lane.target, .points = try automationFromSnap(allocator, lane.points, -60.0, 12.0) });
    }
    self.setSongMode(snap.song_mode);

    // The racks above were built straight from their snapshots, not through
    // `Session.createRack`, so nothing has handed them the project's
    // temperament yet - do it once here rather than in every instrument arm.
    self.setTuning(self.project.tuning);
    self.syncModulation();

    return self;
}

pub fn loadClapState(
    allocator: std.mem.Allocator,
    plugin: *rack_mod.ClapPlugin,
    encoded: []const u8,
) !void {
    if (encoded.len == 0) return;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const state = try allocator.alloc(u8, size);
    defer allocator.free(state);
    try std.base64.standard.Decoder.decode(state, encoded);
    if (!try plugin.loadState(state)) return error.PluginStateUnsupported;
}

pub fn loadVst3State(allocator: std.mem.Allocator, plugin: *rack_mod.Vst3Plugin, component_encoded: []const u8, controller_encoded: []const u8) !void {
    const component_size = try std.base64.standard.Decoder.calcSizeForSlice(component_encoded);
    const component = try allocator.alloc(u8, component_size);
    defer allocator.free(component);
    try std.base64.standard.Decoder.decode(component, component_encoded);
    const controller_size = try std.base64.standard.Decoder.calcSizeForSlice(controller_encoded);
    const controller = try allocator.alloc(u8, controller_size);
    defer allocator.free(controller);
    try std.base64.standard.Decoder.decode(controller, controller_encoded);
    try plugin.loadState(component, controller);
}

/// Apply a sparse note list into a freshly `allocMidi`'d array (already
/// sized to `step_count`) - out-of-range pad/step entries (a hand-edited or
/// truncated file) are silently dropped rather than erroring the load.
pub fn applyNoteSnap(midi: *[DrumMachine.max_pads][]?DrumMachine.MidiNote, step_count: u16, notes: []const DrumNoteSnap) void {
    for (notes) |n| {
        const pad = n.pad;
        if (pad >= DrumMachine.max_pads or n.step >= step_count) continue;
        midi[pad][n.step] = .{
            .pitch = @intCast(pad),
            .step = n.step,
            .duration_steps = @max(1, n.duration_steps),
            .velocity = @min(n.velocity, DrumMachine.vel_full),
            .tune = @intCast(std.math.clamp(@as(i16, n.tune), -24, 24)),
            .prob = @min(n.prob, 100),
            .cond = if (n.cond < @typeInfo(DrumMachine.Cond).@"enum".fields.len)
                @enumFromInt(n.cond)
            else
                .always,
            // Capped rather than rejected: a roll longer than this would
            // just be a buzz, and the file still loads.
            .retrig = @min(n.retrig, 16),
            .micro = @intCast(std.math.clamp(@as(i16, n.micro), -50, 50)),
        };
    }
}

// zig fmt: off
/// Rebuild an arrangement clip from its snapshot. Melodic clips copy notes
/// through a stack buffer into a fresh owned allocation; drum clips are inline.
pub fn clipFromSnap(allocator: std.mem.Allocator, cs: ClipSnap) !ws_arrangement.Clip {
    const start_tick = cs.start_tick;
    const length_ticks = cs.length_ticks;
    var out: ws_arrangement.Clip = switch (cs.content) {
        .melodic => |m| blk: {
            var tmp: [pattern_mod.max_notes]pattern_mod.Note = undefined;
            const count = @min(m.notes.len, @as(usize, pattern_mod.max_notes));
            for (m.notes[0..count], tmp[0..count]) |n, *o| o.* = sanitizeNote(n);
            break :blk try ws_arrangement.Clip.initMelodic(
                allocator,
                start_tick,
                length_ticks,
                tmp[0..count],
                finiteClamp(f64, m.length_beats, 1.0, std.math.floatMax(f64), 1.0),
            );
        },
        .drum => |snap| blk2: {
            var d: ws_arrangement.Clip.Drum = .{
                .step_count = std.math.clamp(snap.pattern.step_count, 1, DrumMachine.max_steps),
                .steps_per_beat = std.math.clamp(snap.pattern.steps_per_beat, 1, 32),
                .variant = @min(snap.variant, DrumMachine.max_variants - 1),
            };
            d.midi = try DrumMachine.allocMidi(allocator, d.step_count);
            applyNoteSnap(&d.midi, d.step_count, snap.pattern.notes);
            break :blk2 ws_arrangement.Clip.initDrum(start_tick, length_ticks, d);
        },
        .audio => |audio| ws_arrangement.Clip.initAudio(start_tick, length_ticks, .{
            .source_id = audio.source_id,
            .source_start_frame = audio.source_start_frame,
            .source_length_frames = audio.source_length_frames,
            .gain_db = finiteClamp(f32, audio.gain_db, -60.0, 24.0, 0.0),
            .fade_in_frames = audio.fade_in_frames,
            .fade_out_frames = audio.fade_out_frames,
            .fade_curve = audio.fade_curve,
            .stretch_ratio = finiteClamp(f32, audio.stretch_ratio, 0.125, 8.0, 1.0),
            .reverse = audio.reverse,
            .alternate_takes = blk: {
                var takes: [ws_arrangement.max_audio_takes - 1]?ws_arrangement.Clip.AudioRegion.Take = @splat(null);
                for (audio.alternate_takes[0..@min(audio.alternate_takes.len, takes.len)], 0..) |take, i| takes[i] = .{
                    .source_id = take.source_id,
                    .source_start_frame = take.source_start_frame,
                    .source_length_frames = take.source_length_frames,
                    .length_ticks = @max(1, take.length_ticks),
                };
                break :blk takes;
            },
        }),
    };
    errdefer out.deinit(allocator);
    out.layer = cs.layer;
    out.automation.gain = try automationFromSnap(allocator, cs.gain_automation, -60.0, 12.0);
    out.automation.pan = try automationFromSnap(allocator, cs.pan_automation, -1.0, 1.0);
    try applySynthParamAutomationSnap(allocator, &out.automation, cs.synth_param_automation);
    const clip_beats = time_grid.tickToBeat(out.length_ticks);
    for (out.automation.gain) |*point| point.beat = @min(point.beat, clip_beats);
    for (out.automation.pan) |*point| point.beat = @min(point.beat, clip_beats);
    for (out.automation.synth_params.items) |*curve| {
        for (curve.points) |*point| point.beat = @min(point.beat, clip_beats);
    }
    return out;
}
// zig fmt: on

/// Load a clip's synth-param automation lanes. A v13 `synth_param_automation`
/// takes priority when present; a pre-v13 file only carries the old
/// single-lane `filter_cutoff_automation`, remapped onto param_id 21 - same
/// "new field wins, else remap the old one" convention `applyVelSnap` uses
/// for drum velocity.
pub fn applySynthParamAutomationSnap(
    allocator: std.mem.Allocator,
    automation: *ws_arrangement.Clip.Automation,
    synth_param_automation: []const SynthParamAutomationSnap,
) !void {
    for (synth_param_automation) |sp| {
        // An FX-unit lane (instance_id != 0) indexes a per-unit-kind
        // table this load path can't resolve (the target FxUnit's kind
        // isn't known here, and may not even exist any more) - load
        // wide-open and let `dsp.fx_params.setParamAbsolute`'s own
        // clamp do the real bounding at automation-delivery time,
        // same as an out-of-u16-range instrument id already falls back to.
        const range = if (sp.instance_id == 0 and sp.param_id <= std.math.maxInt(u16)) blk: {
            if (synth_mod.PolySynth.findAutomatableParam(@intCast(sp.param_id))) |info| break :blk info.range;
            break :blk [2]f32{ -std.math.floatMax(f32), std.math.floatMax(f32) };
        } else [2]f32{ -std.math.floatMax(f32), std.math.floatMax(f32) };
        const points = try automationFromSnap(allocator, sp.points, range[0], range[1]);
        try replaceSynthParamPoints(allocator, automation, sp.instance_id, sp.param_id, points);
    }
}

pub fn replaceSynthParamPoints(allocator: std.mem.Allocator, automation: *ws_arrangement.Clip.Automation, instance_id: u32, param_id: u32, points: []AutomationPoint) !void {
    const dst = automation.synthParamPoints(allocator, instance_id, param_id) catch |err| {
        allocator.free(points);
        return err;
    };
    if (dst.len > 0) allocator.free(dst.*);
    dst.* = points;
}

/// Load automation breakpoints, clamping values to the same range the live
/// editor will enforce and sorting by beat - a hand-edited file has no
/// guarantee the points arrived in order, and `automation.interpolate` relies
/// on that.
pub fn automationFromSnap(
    allocator: std.mem.Allocator,
    snaps: []const AutomationPointSnap,
    lo: f32,
    hi: f32,
) ![]AutomationPoint {
    const out = try allocator.alloc(AutomationPoint, snaps.len);
    for (snaps, out) |s, *o| o.* = .{
        .beat = finiteClamp(f64, s.beat, 0.0, std.math.floatMax(f64), 0.0),
        .value = finiteClamp(f32, s.value, lo, hi, std.math.clamp(0.0, lo, hi)),
        .curve = switch (s.curve) {
            .linear => .linear,
            .hold => .hold,
            .ease => .ease,
        },
    };
    std.mem.sort(AutomationPoint, out, {}, struct {
        fn lessThan(_: void, a: AutomationPoint, b: AutomationPoint) bool {
            return a.beat < b.beat;
        }
    }.lessThan);
    return out;
}

// zig fmt: off
/// Apply a pad snapshot onto a live Pad, clamping every field to the same
/// ranges `adjustParam` enforces. Unclamped values from a hand-edited file
/// would otherwise trip adjustParam's clamp bounds (lower > upper) on the
/// audio thread, or index past buffers in the waveform view.
pub fn applyPadSnap(p: *Pad, ps: PadSnap) void {
    p.gain            = finiteClamp(f32, ps.gain, 0.0, 2.0, 1.0);
    p.pan             = finiteClamp(f32, ps.pan, -1.0, 1.0, 0.0);
    p.pitch_semitones = finiteClamp(f32, ps.pitch_semitones, -24.0, 24.0, 0.0);
    p.start_norm      = finiteClamp(f32, ps.start_norm, 0.0, 0.99, 0.0);
    p.end_norm        = finiteClamp(f32, ps.end_norm, p.start_norm + 0.01, 1.0, 1.0);
    p.reverse         = ps.reverse;
    p.attack_s        = finiteClamp(f32, ps.attack_s, 0.0, 5.0, 0.001);
    p.decay_s         = finiteClamp(f32, ps.decay_s, 0.0, 5.0, 0.0);
    p.sustain         = finiteClamp(f32, ps.sustain, 0.0, 1.0, 1.0);
    p.release_s       = finiteClamp(f32, ps.release_s, 0.001, 5.0, 0.005);
    p.env_curve       = finiteClamp(f32, ps.env_curve, -1.0, 1.0, 0.0);
    p.fade_in_s       = finiteClamp(f32, ps.fade_in_s, 0.0, 5.0, 0.0);
    p.fade_out_s      = finiteClamp(f32, ps.fade_out_s, 0.0, 5.0, 0.0);
    p.stretch_ratio   = finiteClamp(f32, ps.stretch_ratio, 0.25, 4.0, 1.0);
    p.warp_method     = ps.warp_method;
    p.filter          = finiteClamp(f32, ps.filter, -1.0, 1.0, 0.0);
    p.gate            = ps.gate;
    p.retrig          = ps.retrig;
    p.mod_rate_hz     = finiteClamp(f32, ps.mod_rate_hz, 0.02, 20.0, 2.0);
    p.mod_depth       = finiteClamp(f32, ps.mod_depth, 0.0, 1.0, 0.0);
    p.mod_shape       = ps.mod_shape;
    p.mod_dest        = ps.mod_dest;
    p.loop            = ps.loop;
}
// zig fmt: on

/// A NoteSnap with pitch/velocity/times forced into playable ranges.
pub fn sanitizeNote(n: NoteSnap) pattern_mod.Note {
    return .{
        .pitch = @intCast(@min(n.pitch, 127)),
        .start_beat = finiteClamp(f64, n.start_beat, 0.0, std.math.floatMax(f64), 0.0),
        .duration_beat = finiteClamp(f64, n.duration_beat, 0.0, std.math.floatMax(f64), 0.0),
        .velocity = finiteClamp(f32, n.velocity, 0.0, 1.0, pattern_mod.default_velocity),
        .channel = @intCast(@min(n.channel, 15)),
        .midi_track = n.midi_track,
        // One clamp for all three, shared with the Lua setter and the
        // editors, so a hand-edited file can't place a note somewhere the
        // UI has no way to show or undo.
        .art = (dsp_mod.Articulation{
            .pan = n.pan,
            .fine_cents = n.fine_cents,
            .release_scale = n.release_scale,
        }).clamped(),
    };
}

/// Load saved notes into a pattern player (control thread, before audio runs).
pub fn loadNotes(pp: *PatternPlayer, notes: []const NoteSnap) void {
    const count = @min(notes.len, @as(usize, pattern_mod.max_notes));
    pp.note_count = @intCast(count);
    for (notes[0..count], 0..) |n, j| {
        pp.notes[j] = sanitizeNote(n);
    }
}

/// Apply a synth snapshot onto a live PolySynth, clamping every numeric
/// field to the same ranges `adjustParam` enforces - mirrors
/// `applyPadSnap`'s reasoning: a hand-edited or corrupted file could
/// otherwise smuggle an out-of-range value (e.g. unison 0 or 255, a
/// negative attack time) straight onto the audio thread. Enum fields
/// (filter_type, warp_mode, …) need no clamp - `std.json` already
/// rejects any value that isn't one of the declared tags at parse time.
pub fn applyToSynth(s: *PolySynth, ss: *const SynthSnap) !void {
    const clamp = std.math.clamp;
    try s.selectBundledWavetables(ss.wt_bundled, ss.osc_b_wt_bundled, ss.osc_c_wt_bundled);
    // Every plain param_specs field (id->field->range, shared with the live
    // h/l-nudge and automation paths) - see PolySynth.applyParamSpecs. What's
    // left below is what param_specs deliberately excludes: the mod matrix
    // (fixed array vs. slice).
    s.applyParamSpecs(ss);
    // Take rows as saved, clamped. Bad destinations fall back to cutoff,
    // matching setParamAbsolute's rule.
    for (0..PolySynth.max_mod_rows) |k| {
        if (k < ss.mod_matrix.len) {
            var row = ss.mod_matrix[k];
            row.depth = clamp(row.depth, -1.0, 1.0);
            if (PolySynth.modDestIndex(row.dest) == null) row.dest = 21;
            s.mod_matrix[k] = row;
        } else {
            s.mod_matrix[k] = .{};
        }
    }
    applyLfoCustomSnap(&s.lfo_custom[0], &s.lfo_custom_count[0], ss.lfo_custom);
    applyLfoCustomSnap(&s.lfo_custom[1], &s.lfo_custom_count[1], ss.lfo2_custom);
    applyLfoCustomSnap(&s.lfo_custom[2], &s.lfo_custom_count[2], ss.lfo3_custom);
}

/// One drawn LFO slot's points from a snap onto the live fixed array +
/// count, clamped to the same phase/value ranges `setParamAbsolute` enforces
/// per-point and sorted into the order playback requires. `null`/empty/
/// over-capacity all collapse to "however many points fit". A hand-edited file overrunning
/// `max_lfo_shape_points` just gets truncated rather than rejected, same
/// spirit as `mod_matrix`'s row cap above.
pub fn applyLfoCustomSnap(dst_points: *[synth_mod.max_lfo_shape_points]synth_mod.LfoShapePoint, dst_count: *u8, src: ?[]const synth_mod.LfoShapePoint) void {
    const pts = src orelse &.{};
    const n = @min(pts.len, synth_mod.max_lfo_shape_points);
    for (pts[0..n], dst_points[0..n]) |p, *d| {
        d.* = .{
            .phase = finiteClamp(f32, p.phase, 0.0, 1.0, 0.0),
            .value = finiteClamp(f32, p.value, -1.0, 1.0, 0.0),
            .curve = finiteClamp(f32, p.curve, -1.0, 1.0, 0.0),
        };
    }
    std.mem.sort(synth_mod.LfoShapePoint, dst_points[0..n], {}, struct {
        fn lessThan(_: void, a: synth_mod.LfoShapePoint, b: synth_mod.LfoShapePoint) bool {
            return a.phase < b.phase;
        }
    }.lessThan);
    dst_count.* = @intCast(n);
}

// zig fmt: off
/// Rebuild a live chain from v10 unit snaps, in file order. Shared by track
/// racks and the master bus - both hold a user-built `Fx` chain. Snaps past
/// the chain cap are dropped (only reachable by hand-editing the file).
/// A unit whose params field is null keeps its defaults.
pub fn applyFxChain(
    allocator: std.mem.Allocator,
    fx_out: *Fx,
    chain: []const FxUnitSnap,
    sr: u32,
    transport: ?*const Transport,
) !void {
    for (chain) |us| {
        if (fx_out.units.items.len >= Fx.max_units) break;
        const unit = switch (us.content) {
            .clap => |cs| blk: {
                const loaded = try fx_out.insertClap(allocator, fx_out.units.items.len, cs.path, cs.plugin_id, sr);
                if (transport) |value| loaded.payload.clap.attachTransport(value);
                try loadClapState(allocator, loaded.payload.clap, cs.state_base64);
                break :blk loaded;
            },
            .vst3 => |vs| blk: {
                if (vs.path.len == 0 or vs.class_id.len != 32) return error.MalformedProject;
                const loaded = try fx_out.insertVst3(allocator, fx_out.units.items.len, vs.path, vs.class_id, sr);
                if (transport) |value| loaded.payload.vst3.attachTransport(value);
                try loadVst3State(allocator, loaded.payload.vst3, vs.component_state_base64, vs.controller_state_base64);
                break :blk loaded;
            },
            else => |_, saved_kind| blk: {
                const kind: rack_mod.FxKind = switch (saved_kind) {
                    .gate => .gate, .comp => .comp, .mb_comp => .mb_comp, .ott => .ott, .limiter => .limiter, .transient_shaper => .transient_shaper,
                    .eq => .eq, .filter => .filter, .utility => .utility, .stereo_width => .stereo_width, .auto_pan => .auto_pan, .sat => .sat, .crush => .crush, .chorus => .chorus,
                    .phaser => .phaser, .flanger => .flanger, .tape => .tape,
                    .freq_shift => .freq_shift, .pitch_shift => .pitch_shift, .delay => .delay, .reverb => .reverb,
                    .clap, .vst3 => unreachable,
                };
                break :blk try fx_out.insert(allocator, fx_out.units.items.len, kind, sr);
            },
        };
        unit.setBypassed(us.bypassed);
        if (us.instance_id != 0 and fx_out.findInstance(us.instance_id) == null) {
            unit.instance_id = us.instance_id;
            if (fx_out.next_instance_id <= us.instance_id) {
                fx_out.next_instance_id = us.instance_id +% 1;
                if (fx_out.next_instance_id == 0) fx_out.next_instance_id = 1;
            }
        }
        switch (us.content) {
            .comp => |cs| {
                const c = &unit.payload.comp;
                if (std.math.isFinite(cs.threshold_db)) c.threshold_db = cs.threshold_db;
                if (std.math.isFinite(cs.ratio)) c.ratio = cs.ratio;
                if (std.math.isFinite(cs.attack_ms)) c.attack_ms = cs.attack_ms;
                if (std.math.isFinite(cs.release_ms)) c.release_ms = cs.release_ms;
                if (std.math.isFinite(cs.makeup_db)) c.makeup_db = cs.makeup_db;
                if (std.math.isFinite(cs.knee_db)) c.knee_db = cs.knee_db;
                if (std.math.isFinite(cs.hold_ms)) c.hold_ms = cs.hold_ms;
                if (std.math.isFinite(cs.mode)) c.mode = cs.mode;
                if (std.math.isFinite(cs.mix)) c.mix = cs.mix;
                if (std.math.isFinite(cs.sc_mode)) c.sc_mode = cs.sc_mode;
                if (std.math.isFinite(cs.sc_hpf_hz)) c.sc_hpf_hz = cs.sc_hpf_hz;
                if (std.math.isFinite(cs.sc_lpf_hz)) c.sc_lpf_hz = cs.sc_lpf_hz;
                c.sidechain_source = if (cs.sidechain_source) |src| .{
                    .track = if (cs.sidechain_is_group)
                        @min(src, engine_mod.max_groups - 1)
                    else
                        @min(src, engine_mod.max_tracks - 1),
                    .pad = if (cs.sidechain_is_group) null else if (cs.sidechain_pad) |p| @min(p, DrumMachine.max_pads - 1) else null,
                    .is_group = cs.sidechain_is_group,
                } else null;
            },
            .mb_comp => |ms| {
                const m = &unit.payload.mb_comp;
                m.setXovers(ms.xover_lo_hz, ms.xover_hi_hz);
                if (std.math.isFinite(ms.attack_ms)) m.attack_ms = ms.attack_ms;
                if (std.math.isFinite(ms.release_ms)) m.release_ms = ms.release_ms;
                if (std.math.isFinite(ms.knee_db)) m.knee_db = ms.knee_db;
                m.style = if (ms.ott) .ott else .classic;
                if (std.math.isFinite(ms.mix)) m.mix = ms.mix;
                const saved_bands = [_][3]f32{
                    .{ ms.low_threshold_db, ms.low_ratio, ms.low_makeup_db },
                    .{ ms.mid_threshold_db, ms.mid_ratio, ms.mid_makeup_db },
                    .{ ms.high_threshold_db, ms.high_ratio, ms.high_makeup_db },
                };
                for (&m.bands, saved_bands) |*band, saved| {
                    if (std.math.isFinite(saved[0])) band.threshold_db = saved[0];
                    if (std.math.isFinite(saved[1])) band.ratio = saved[1];
                    if (std.math.isFinite(saved[2])) band.makeup_db = saved[2];
                }
            },
            .ott => |os| {
                const o = &unit.payload.ott;
                o.setDepth(os.depth);
                o.setTime(os.time);
                o.gain_in_db = finiteClamp(f32, os.gain_in_db, -24.0, 24.0, o.gain_in_db);
                o.gain_out_db = finiteClamp(f32, os.gain_out_db, -24.0, 24.0, o.gain_out_db);
            },
            .delay => |snap| applySnapToDevice(&unit.payload.delay, snap),
            .reverb => |snap| applySnapToDevice(&unit.payload.reverb, snap),
            .eq => |es| {
                const e = &unit.payload.eq;
                for (es.bands, 0..) |b, i| {
                    e.setFreq(i, b.freq);
                    e.setQ(i, b.q);
                    e.setGain(i, b.gain_db);
                    e.setType(i, switch (b.kind) {
                        .peak => .peak, .lowpass => .lowpass, .highpass => .highpass,
                        .lowshelf => .lowshelf, .highshelf => .highshelf,
                        .notch => .notch, .tiltshelf => .tiltshelf,
                    }, b.slope);
                    e.setSolo(i, b.solo);
                    e.setStereoMode(i, switch (b.stereo_mode) {
                        .stereo => .stereo, .mid => .mid, .side => .side,
                    });
                    e.setDynThreshold(i, b.dyn_threshold_db);
                    e.setDynAmount(i, b.dyn_amount_db);
                    e.setDynEnabled(i, b.dyn_enabled);
                }
                e.setAutoGain(es.auto_gain);
                // The EQ-only bypass maps onto the slot's generic one.
                if (es.bypass) unit.setBypassed(true);
            },
            inline .filter, .limiter, .utility, .stereo_width, .auto_pan,
            .transient_shaper, .gate, .sat, .crush, .chorus, .phaser,
            .flanger, .tape, .freq_shift, .pitch_shift => |snap, tag|
                applySnapToDevice(&@field(unit.payload, @tagName(tag)), snap),
            .clap, .vst3 => {},
        }
    }
}

/// Build factory-preset inserts in Rack's shared modular chain.
fn buildPresetFx(allocator: std.mem.Allocator, patch: *const PolySynth.Patch, s: *PolySynth, fx: *Fx, sr: u32) !void {
    var pos: usize = 0;
    for (patch.fx_order) |kind| {
        const enabled = switch (kind) {
            .gate => patch.fx_gate_on,
            .eq => patch.fx_eq_on,
            .comp => patch.fx_comp_on,
            .mb_comp => patch.fx_mb_on,
            .ott => patch.fx_ott_on,
            .dist => patch.fx_dist_on,
            .crush => patch.fx_crush_on,
            .chorus => patch.fx_chorus_on,
            .flanger => patch.fx_flanger_on,
            .tape => patch.fx_tape_on,
            .phaser => patch.fx_phaser_on,
            .freq_shift => patch.fx_freq_shift_on,
            .delay => patch.fx_delay_on,
            .reverb => patch.fx_reverb_on,
        };
        if (!enabled) continue;
        const rack_kind: rack_mod.FxKind = switch (kind) {
            .gate => .gate, .eq => .eq, .comp => .comp, .mb_comp => .mb_comp,
            .ott => .ott, .dist => .sat, .crush => .crush, .chorus => .chorus,
            .flanger => .flanger, .tape => .tape, .phaser => .phaser,
            .freq_shift => .freq_shift, .delay => .delay, .reverb => .reverb,
        };
        const unit = try fx.insert(allocator, pos, rack_kind, sr);
        for (&s.mod_matrix) |*row| {
            if (row.fx_instance_id != 0) continue;
            if (legacyFxParamIndex(kind, row.dest)) |idx| {
                row.fx_instance_id = unit.instance_id;
                row.dest = idx;
            }
        }
        pos += 1;
        switch (unit.payload) {
            .gate => |*v| {
                v.threshold_db = patch.fx_gate_threshold_db;
                v.attack_ms = patch.fx_gate_attack_ms;
                v.release_ms = patch.fx_gate_release_ms;
            },
            .eq => |*v| {
                v.setFreq(0, patch.fx_eq_low_freq);
                v.setGain(0, patch.fx_eq_low_gain_db);
                v.setType(0, .lowshelf, 1);
                v.setFreq(1, patch.fx_eq_mid_freq);
                v.setGain(1, patch.fx_eq_mid_gain_db);
                v.setQ(1, patch.fx_eq_mid_q);
                v.setType(1, .peak, 1);
                v.setFreq(2, patch.fx_eq_high_freq);
                v.setGain(2, patch.fx_eq_high_gain_db);
                v.setType(2, .highshelf, 1);
            },
            .comp => |*v| {
                v.threshold_db = patch.fx_comp_threshold_db;
                v.ratio = patch.fx_comp_ratio;
                v.attack_ms = patch.fx_comp_attack_ms;
                v.release_ms = patch.fx_comp_release_ms;
                v.makeup_db = patch.fx_comp_makeup_db;
            },
            .mb_comp => |*v| {
                v.setXovers(patch.fx_mb_xover_lo, patch.fx_mb_xover_hi);
                v.attack_ms = patch.fx_mb_attack_ms;
                v.release_ms = patch.fx_mb_release_ms;
                v.style = patch.fx_mb_style;
                v.mix = patch.fx_mb_mix;
                v.bands[0].threshold_db = patch.fx_mb_low_threshold_db;
                v.bands[0].ratio = patch.fx_mb_low_ratio;
                v.bands[0].makeup_db = patch.fx_mb_low_makeup_db;
                v.bands[1].threshold_db = patch.fx_mb_mid_threshold_db;
                v.bands[1].ratio = patch.fx_mb_mid_ratio;
                v.bands[1].makeup_db = patch.fx_mb_mid_makeup_db;
                v.bands[2].threshold_db = patch.fx_mb_high_threshold_db;
                v.bands[2].ratio = patch.fx_mb_high_ratio;
                v.bands[2].makeup_db = patch.fx_mb_high_makeup_db;
            },
            .ott => |*v| {
                v.setDepth(patch.fx_ott_depth);
                v.setTime(patch.fx_ott_time);
                v.gain_in_db = patch.fx_ott_gain_in_db;
                v.gain_out_db = patch.fx_ott_gain_out_db;
            },
            .sat => |*v| {
                v.drive_db = patch.fx_dist_drive_db;
                v.mix = patch.fx_dist_mix;
            },
            .crush => |*v| {
                v.bits = patch.fx_crush_bits;
                v.downsample = patch.fx_crush_rate;
                v.mix = patch.fx_crush_mix;
            },
            .chorus => |*v| {
                v.rate_hz = patch.fx_chorus_rate_hz;
                v.depth_ms = patch.fx_chorus_depth_ms;
                v.mix = patch.fx_chorus_mix;
            },
            .flanger => |*v| {
                v.rate_hz = patch.fx_flanger_rate_hz;
                v.depth = patch.fx_flanger_depth;
                v.feedback = patch.fx_flanger_feedback;
                v.mix = patch.fx_flanger_mix;
            },
            .tape => |*v| {
                v.wow_rate_hz = patch.fx_tape_wow_rate_hz;
                v.wow_depth = patch.fx_tape_wow_depth;
                v.flutter_rate_hz = patch.fx_tape_flutter_rate_hz;
                v.flutter_depth = patch.fx_tape_flutter_depth;
                v.mix = patch.fx_tape_mix;
            },
            .phaser => |*v| {
                v.rate_hz = patch.fx_phaser_rate_hz;
                v.depth = patch.fx_phaser_depth;
                v.feedback = patch.fx_phaser_feedback;
                v.mix = patch.fx_phaser_mix;
            },
            .freq_shift => |*v| {
                v.shift_hz = patch.fx_freq_shift_hz;
                v.mix = patch.fx_freq_shift_mix;
            },
            .delay => |*v| {
                v.time_s = patch.fx_delay_time_s;
                v.feedback = patch.fx_delay_feedback;
                v.mix = patch.fx_delay_mix;
            },
            .reverb => |*v| {
                v.room = patch.fx_reverb_room;
                v.damp = patch.fx_reverb_damp;
                v.mix = patch.fx_reverb_mix;
            },
            .filter, .limiter, .utility, .stereo_width, .auto_pan, .transient_shaper, .pitch_shift, .clap, .vst3 => unreachable,
        }
    }
}

pub fn fxKindOwnsParam(kind: synth_mod.FxUnitKind, id: u16) bool {
    return switch (kind) {
        .dist => id >= 84 and id <= 85,
        .crush => id >= 87 and id <= 89,
        .flanger => id >= 91 and id <= 94,
        .phaser => id >= 104 and id <= 107,
        .delay => id >= 109 and id <= 111,
        .reverb => id >= 113 and id <= 115,
        .gate => id >= 133 and id <= 135,
        .comp => id >= 138 and id <= 142,
        .mb_comp => id >= 145 and id <= 159,
        .ott => id >= 162 and id <= 165,
        .eq => id >= 168 and id <= 174,
        .chorus => id >= 177 and id <= 179,
        .freq_shift => id >= 182 and id <= 183,
        .tape => id >= 189 and id <= 193,
    };
}

fn legacyFxParamIndex(kind: synth_mod.FxUnitKind, id: u16) ?u16 {
    if (!fxKindOwnsParam(kind, id)) return null;
    return switch (kind) {
        .dist => id - 84,
        .crush => id - 87,
        .flanger => id - 91,
        .phaser => id - 104,
        .delay => id - 109,
        .reverb => id - 113,
        .gate => switch (id) { 133 => 0, 134 => 1, 135 => 3, else => unreachable },
        .comp => id - 138,
        .mb_comp => switch (id) {
            145...148 => id - 145,
            150 => 6,
            151...159 => id - 144,
            else => unreachable,
        },
        .ott => id - 162,
        .eq => switch (id) {
            168 => 1, 169 => 3,
            170 => 10, 171 => 12, 172 => 11,
            173 => 19, 174 => 21,
            else => unreachable,
        },
        .chorus => id - 177,
        .freq_shift => id - 182,
        .tape => id - 189,
    };
}

/// Install `patch` (and the FX chain its legacy carriers migrate into) on
/// `rack`'s synth, returning the chain it displaced. The caller owns that
/// chain and must re-sync the rack's chain to the engine BEFORE disposing of
/// it - `Session.retireFxChain` is the disposal to use on a live rack.
pub fn applySynthPatch(
    allocator: std.mem.Allocator,
    rack: *Rack,
    patch: PolySynth.Patch,
    sr: u32,
) !Fx {
    if (rack.instrument != .poly_synth) return error.NotSynth;
    const synth = &rack.instrument.poly_synth;
    var probe = synth.*;
    probe.applyPatch(patch);
    var replacement: Fx = .{};
    buildPresetFx(allocator, &patch, &probe, &replacement, sr) catch |err| {
        replacement.deinit(allocator);
        return err;
    };
    errdefer replacement.deinit(allocator);
    try synth.applyPatchWithWavetables(patch);
    // `buildPresetFx` bound every row that modulates an FX param to the
    // unit it created for that param, but it ran against `probe` - the whole
    // point of the probe being that a failed migration leaves the live synth
    // untouched. `applyPatchWithWavetables` just rewrote the real matrix from
    // the patch, whose rows carry no instance id, so carry the bindings over
    // or every migrated modulation lands on nothing.
    for (&synth.mod_matrix, probe.mod_matrix) |*row, migrated| row.fx_instance_id = migrated.fx_instance_id;
    const displaced = rack.fx;
    rack.fx = replacement;
    return displaced;
}
