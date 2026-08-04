//! Project load path: parse JSON into a live Session. Split out of
//! persist.zig.

const std = @import("std");
const Session = @import("session.zig").Session;
const wav = @import("core/wav.zig");
const types = @import("core/types.zig");
const theory = @import("theory.zig");
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
const legacy_eq_band_count = persist_types.legacy_eq_band_count;
const EqBandKindSnap = persist_types.EqBandKindSnap;
const EqStereoModeSnap = persist_types.EqStereoModeSnap;
const EqBandSnap = persist_types.EqBandSnap;
const EqSnap = persist_types.EqSnap;
const migrateEqBands = persist_types.migrateEqBands;
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
const FxSnap = persist_types.FxSnap;
const FxKind = persist_types.FxKind;
const ClapSnap = persist_types.ClapSnap;
const Vst3Snap = persist_types.Vst3Snap;
const FxUnitSnap = persist_types.FxUnitSnap;
const InstrumentKind = persist_types.InstrumentKind;
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

    var parsed = try std.json.parseFromSlice(
        Snapshot,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var session = try buildSession(allocator, &parsed.value);
    restoreSamples(allocator, io, path, &parsed.value, &session);
    return session;
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
                const ds = rs.drum orelse continue;
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
                const smp = rs.sampler orelse continue;
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
                const sls = rs.slicer orelse continue;
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
                const ss = rs.synth orelse continue;
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
                const sfs = rs.soundfont orelse continue;
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

pub fn finiteClamp(comptime T: type, value: T, lo: T, hi: T, fallback: T) T {
    if (!std.math.isFinite(value)) return fallback;
    return std.math.clamp(value, lo, hi);
}

pub fn buildSession(allocator: std.mem.Allocator, snap: *const Snapshot) !Session {
    // Reject files this build cannot represent; clamp what can be clamped.
    // Racks, tracks, and lanes are parallel arrays everywhere downstream
    // (engine slots, editor indices), so a mismatch is a malformed file.
    if (snap.version > file_version) return error.UnsupportedVersion;
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
    const steps_per_bar = @as(u32, beats_per_bar) * 4;
    const max_song_bars = std.math.maxInt(u32) / steps_per_bar;
    for (snap.arrangement) |lane| {
        for (lane.clips) |clip| {
            if (clip.length_ticks) |length| {
                const start = clip.start_tick orelse 0;
                if (length == 0 or start > std.math.maxInt(u32) - length) return error.MalformedProject;
            } else if (clip.length_bars == 0 or
                clip.start_bar > max_song_bars or
                clip.length_bars > max_song_bars - clip.start_bar)
                return error.MalformedProject;
        }
    }

    var project = Project.init(allocator);
    errdefer project.deinit();
    project.sample_rate = snap.sample_rate;
    project.tempo_bpm = finiteClamp(f64, snap.tempo_bpm, 20.0, 400.0, 120.0);
    project.scale = snap.scale;
    project.beats_per_bar = beats_per_bar;
    project.loop_start_bar = snap.loop_start_bar;
    project.loop_end_bar = snap.loop_end_bar;
    project.loop_enabled = snap.loop_enabled and snap.loop_end_bar > snap.loop_start_bar;
    for (snap.sections) |section| {
        if (section.name.len == 0) continue;
        try project.setSection(section.tick, section.name);
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
        for (t.sends[0..@min(t.sends.len, project_mod.max_sends_per_track)], 0..) |ss, i| {
            sends[i] = .{
                .target = if (ss.is_group) .{ .group = @min(ss.group, engine_mod.max_groups - 1) } else .master,
                .level = types.dbToGain(finiteClamp(f32, ss.level_db, -60.0, 12.0, -60.0)),
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
        switch (rs.kind) {
            .empty => {},
            .poly_synth => {
                const synth = try PolySynth.init(allocator, sr);
                rack.instrument = .{ .poly_synth = synth };
                // PatternPlayer holds a pointer into the heap-allocated Rack -
                // must be set AFTER the instrument lands in the rack. Same
                // for the synth's own transport (tempo-synced LFOs/arp).
                rack.instrument.poly_synth.attachTransport(&engine.transport);
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.synth) |ss| {
                    try applyToSynth(&rack.instrument.poly_synth, &ss);
                    // Same clamp the clip loader applies: a zero/negative/
                    // non-finite loop length breaks the piano roll's step
                    // math and the playback wrap.
                    rack.pattern_player.?.length_beats = finiteClamp(f64, ss.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, ss.notes);
                    rack.pattern_player.?.setSwing(ss.swing);
                }
            },
            .sampler => {
                const sampler = try Sampler.init(allocator, sr);
                rack.instrument = .{ .sampler = sampler };
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.sampler) |smp| {
                    const s = &rack.instrument.sampler;
                    applyPadSnap(&s.pad, smp.pad);
                    s.root_note = @intCast(@min(smp.root_note, 127));
                    s.mono = smp.mono;
                    rack.pattern_player.?.length_beats = finiteClamp(f64, smp.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, smp.notes);
                    rack.pattern_player.?.setSwing(smp.swing);
                }
            },
            .drum_machine => {
                const drum_machine = try DrumMachine.init(allocator, sr, &engine.transport);
                rack.instrument = .{ .drum_machine = drum_machine };
                if (rs.drum) |ds| {
                    const dmp = &rack.instrument.drum_machine;
                    // Regenerate the kit first: its pads are the audio the
                    // file never carried (only user samples reach the
                    // sidecar), and the per-pad snapshot below then layers
                    // this project's params over them. An unknown name -
                    // a kit that no longer exists - just leaves them empty.
                    if (ds.kit.len > 0) {
                        if (drum_kit.byName(ds.kit)) |variant| {
                            // Always loaded in today's soundtype-grouped
                            // order - a pre-v36 file's own pad-indexed data
                            // (notes/choke_group/pad_len/pads below) gets
                            // remapped into that same order as it's applied,
                            // rather than the kit alone being rebuilt back
                            // into the file's old order. A one-time migration
                            // instead of a permanent legacy-order session:
                            // resaving no longer scrambles the layout (see
                            // `drum_kit.legacyPadIndex`'s doc comment).
                            dmp.loadKitVariant(variant) catch {};
                        }
                    }
                    if (ds.variants.len > 0) {
                        for (dmp.variants[0..dmp.variant_count]) |*slot| DrumMachine.freeMidi(allocator, &slot.midi);
                        const count: u8 = @intCast(@min(ds.variants.len, DrumMachine.max_variants));
                        dmp.variant_count = 0;
                        for (ds.variants[0..count], dmp.variants[0..count]) |vs, *slot| {
                            const sc = std.math.clamp(vs.step_count, 1, DrumMachine.max_steps);
                            slot.step_count = sc;
                            slot.steps_per_beat = std.math.clamp(vs.steps_per_beat, 1, 32);
                            slot.midi = try DrumMachine.allocMidi(allocator, sc);
                            dmp.variant_count += 1;
                            if (snap.version >= 23) {
                                applyNoteSnap(&slot.midi, sc, vs.notes, snap.version < 36);
                            } else {
                                legacyPatternVelToMidi(&slot.midi, sc, vs.pattern, vs.vel, vs.vel_lo, vs.vel_hi, true);
                            }
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
                    } else {
                        // v2: one variant from the legacy fields.
                        const sc = std.math.clamp(ds.step_count, 1, DrumMachine.max_steps);
                        const midi = try DrumMachine.allocMidi(allocator, sc);
                        DrumMachine.freeMidi(allocator, &dmp.midi);
                        dmp.midi = midi;
                        if (snap.version >= 23) {
                            applyNoteSnap(&dmp.midi, sc, ds.notes, snap.version < 36);
                        } else {
                            legacyPatternVelToMidi(&dmp.midi, sc, ds.pattern, &.{}, &.{}, &.{}, true);
                        }
                        dmp.step_count = sc;
                        dmp.steps_per_beat = std.math.clamp(ds.steps_per_beat, 1, 32);
                    }
                    dmp.swing.store(
                        std.math.clamp(ds.swing, DrumMachine.swing_min, DrumMachine.swing_max),
                        .monotonic,
                    );
                    // The file is the source of truth even when it says
                    // nothing: a default/legacy DrumSnap has an empty slice
                    // here, which must still clear init()'s default hihat
                    // choke pairing, not leave it standing.
                    for (&dmp.choke_group) |*c| c.* = 0;
                    for (ds.choke_group, 0..) |g, pi| {
                        if (pi >= DrumMachine.max_pads) break;
                        const pad: usize = if (snap.version < 36 and pi < 16) drum_kit.legacyPadIndex(@intCast(pi)) else pi;
                        dmp.choke_group[pad] = @min(g, DrumMachine.max_choke_groups);
                    }
                    // Same "the file is the source of truth even when silent"
                    // rule as the choke groups above.
                    for (&dmp.pad_len) |*l| l.* = 0;
                    for (ds.pad_len, 0..) |l, pi| {
                        if (pi >= DrumMachine.max_pads) break;
                        const pad: usize = if (snap.version < 36 and pi < 16) drum_kit.legacyPadIndex(@intCast(pi)) else pi;
                        dmp.setPadLen(@intCast(pad), l);
                    }
                    // Only materialize a pad the file actually marked `used`
                    // (see PadSnap's doc comment) - an omitted/legacy entry
                    // (older files implicitly meant every one of their 8 was
                    // used, see the loop below) or an explicit `used = false`
                    // stays null, matching a pad nobody ever loaded.
                    for (ds.pads, 0..) |ps, pi| {
                        if (pi >= DrumMachine.max_pads) break;
                        const pad: usize = if (snap.version < 36 and pi < 16) drum_kit.legacyPadIndex(@intCast(pi)) else pi;
                        // Pre-v11 files predate the "empty pad" concept
                        // entirely (every pad was always materialized, even
                        // an untouched one just carried the generated
                        // default clip) - `used` didn't exist yet, so its
                        // absence there means "was materialized", not the
                        // v11-and-later default of `false`. Version-gated,
                        // not inferred from array length (a v11+ file can
                        // legitimately have exactly 8 real entries with some
                        // genuinely unused).
                        const was_used = ps.used or snap.version < 11;
                        if (!was_used) continue;
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
                }
            },
            .slicer => {
                const slicer = try Slicer.init(allocator, sr, &engine.transport);
                rack.instrument = .{ .slicer = slicer };
                if (rs.slicer) |sls| {
                    const sl = &rack.instrument.slicer;
                    const count: u8 = @intCast(@min(sls.slices.len, Slicer.max_slices));
                    sl.slice_count = count;
                    for (sls.slices[0..count], sl.slices[0..count]) |ps, *p| {
                        p.samples = sl.samples; // applyPadSnap never touches .samples
                        applyPadSnap(p, ps);
                    }
                    if (sls.variants.len > 0) {
                        for (sl.variants[0..sl.variant_count]) |*slot| Slicer.freeMidi(allocator, &slot.midi);
                        const vcount: u8 = @intCast(@min(sls.variants.len, Slicer.max_variants));
                        sl.variant_count = 0;
                        for (sls.variants[0..vcount], sl.variants[0..vcount]) |vs, *slot| {
                            const sc = std.math.clamp(vs.step_count, 1, Slicer.max_steps);
                            slot.step_count = sc;
                            slot.steps_per_beat = std.math.clamp(vs.steps_per_beat, 1, 32);
                            slot.midi = try Slicer.allocMidi(allocator, sc);
                            sl.variant_count += 1;
                            if (snap.version >= 28) {
                                applyNoteSnap(&slot.midi, sc, vs.notes, false);
                            } else {
                                legacyPatternVelToMidi(&slot.midi, sc, vs.pattern, vs.vel, vs.vel_lo, vs.vel_hi, false);
                            }
                        }
                        sl.variant = @min(sls.variant, vcount - 1);
                        const active = &sl.variants[sl.variant];
                        const midi = try Slicer.dupeMidi(allocator, &active.midi);
                        Slicer.freeMidi(allocator, &sl.midi);
                        sl.midi = midi;
                        sl.step_count = active.step_count;
                        sl.steps_per_beat = active.steps_per_beat;
                    } else {
                        // Pre-variant file: one variant from the legacy flat
                        // fields.
                        const sc = std.math.clamp(sls.step_count, 1, Slicer.max_steps);
                        const midi = try Slicer.allocMidi(allocator, sc);
                        Slicer.freeMidi(allocator, &sl.midi);
                        sl.midi = midi;
                        if (snap.version >= 28) {
                            applyNoteSnap(&sl.midi, sc, sls.notes, false);
                        } else {
                            legacyPatternVelToMidi(&sl.midi, sc, sls.pattern, sls.vel, &.{}, &.{}, false);
                        }
                        sl.step_count = sc;
                        sl.steps_per_beat = std.math.clamp(sls.steps_per_beat, 1, 32);
                    }
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
                }
            },
            .clap => {
                const cs = rs.clap orelse return error.MalformedProject;
                if (cs.path.len == 0 or cs.plugin_id.len == 0) return error.MalformedProject;
                const plugin = try rack_mod.ClapPlugin.load(allocator, cs.path, cs.plugin_id, sr);
                var plugin_owned = true;
                errdefer if (plugin_owned) plugin.deinit();
                plugin.attachTransport(&engine.transport);
                try loadClapState(allocator, plugin, cs.state_base64);
                rack.instrument = .{ .clap = plugin };
                plugin_owned = false;
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                rack.pattern_player.?.length_beats = finiteClamp(f64, cs.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                loadNotes(&rack.pattern_player.?, cs.notes);
                rack.pattern_player.?.setSwing(cs.swing);
            },
            .vst3 => {
                const vs = rs.vst3 orelse return error.MalformedProject;
                if (vs.path.len == 0 or vs.class_id.len != 32) return error.MalformedProject;
                const plugin = try rack_mod.Vst3Plugin.load(allocator, vs.path, vs.class_id, sr, true);
                var plugin_owned = true;
                errdefer if (plugin_owned) plugin.deinit();
                plugin.attachTransport(&engine.transport);
                try loadVst3State(allocator, plugin, vs.component_state_base64, vs.controller_state_base64);
                rack.instrument = .{ .vst3 = plugin };
                plugin_owned = false;
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                rack.pattern_player.?.length_beats = finiteClamp(f64, vs.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                loadNotes(&rack.pattern_player.?, vs.notes);
                rack.pattern_player.?.setSwing(vs.swing);
            },
            inline .soundfont, .acoustic => |tag| {
                rack.instrument = @unionInit(rack_mod.Instrument, @tagName(tag), SoundfontPlayer.init(allocator, sr));
                rack.pattern_player = PatternPlayer.init(rack.instrument.device().?, &engine.transport);
                if (rs.soundfont) |sfs| {
                    const sf = &@field(rack.instrument, @tagName(tag));
                    sf.gain = finiteClamp(f32, sfs.gain, 0.0, 2.0, 1.0);
                    sf.pan = finiteClamp(f32, sfs.pan, -1.0, 1.0, 0.0);
                    sf.transpose_semitones = finiteClamp(f32, sfs.transpose_semitones, -24.0, 24.0, 0.0);
                    // preset_index is restored by restoreSamples, after the
                    // sidecar .sf2 (if any) has actually loaded - loadSf2
                    // resets it to 0, so setting it here would be wiped.
                    rack.pattern_player.?.length_beats = finiteClamp(f64, sfs.length_beats, 1.0, std.math.floatMax(f64), 4.0);
                    loadNotes(&rack.pattern_player.?, sfs.notes);
                    rack.pattern_player.?.setSwing(sfs.swing);
                }
            },
        }

        if (rs.fx_chain) |fc| try applyFxChain(allocator, &rack.fx, fc, sr, &engine.transport)
        else try applyLegacyFx(allocator, &rack.fx, rs.fx, sr, &engine.transport);
        // Clearing the migrated flags is what keeps this idempotent: they are
        // saved verbatim by synthToSnap, so a chain that migrated on one load
        // and got written back out would migrate a *second* copy of every unit
        // on the next load, growing the chain by one per save/load cycle.
        // `applySynthPatch` clears for the same reason.
        if (rack.instrument == .poly_synth) {
            try migrateSynthFx(allocator, &rack.instrument.poly_synth, &rack.fx, sr);
            clearMigratedSynthFx(&rack.instrument.poly_synth);
        }
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

    if (snap.master_fx_chain) |fc| try applyFxChain(allocator, &self.master_fx, fc, sr, &self.engine.transport)
    else try applyLegacyFx(allocator, &self.master_fx, snap.master_fx, sr, &self.engine.transport);
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
        for (ls.clips) |cs| try lane.place(allocator, try clipFromSnap(allocator, cs, snap.beats_per_bar, snap.version));
    }
    self.setSongMode(snap.song_mode);

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

/// Apply a v23 sparse note list into a freshly `allocMidi`'d array (already
/// sized to `step_count`) - out-of-range pad/step entries (a hand-edited or
/// truncated file) are silently dropped rather than erroring the load.
/// `legacy_pad_order`: true for a pre-v36 drum-machine file, whose
/// `n.pad` values were assigned under the old (pre-soundtype-regroup)
/// layout - see `drum_kit.legacyPadIndex`. Never true for Slicer, whose
/// "pads" are audio slices with no relationship to `drum_kit.zig`'s kits.
pub fn applyNoteSnap(midi: *[DrumMachine.max_pads][]?DrumMachine.MidiNote, step_count: u16, notes: []const DrumNoteSnap, legacy_pad_order: bool) void {
    for (notes) |n| {
        const pad: u8 = if (legacy_pad_order) drum_kit.legacyPadIndex(n.pad) else n.pad;
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

/// One step's velocity from a pre-v23 file's legacy fields, mirroring
/// `applyVelSnap`'s "v12 `vel` wins, else remap `vel_lo`/`vel_hi`, else full"
/// resolution but per-cell instead of building a whole dense array - the
/// drum machine's own migrated shape is the sparse `midi`, so there's no
/// dense destination to write through here.
pub fn legacyStepVel(vel: []const []const u8, vel_lo: []const u64, vel_hi: []const u64, pad: usize, step: u16) u8 {
    if (vel.len > 0) {
        if (pad < vel.len and step < vel[pad].len) return @min(vel[pad][step], DrumMachine.vel_full);
        return DrumMachine.vel_full;
    }
    if (pad < vel_lo.len and pad < vel_hi.len and step < 64) {
        const l: u2 = @intCast((vel_lo[pad] >> @intCast(step)) & 1);
        const h: u2 = @intCast((vel_hi[pad] >> @intCast(step)) & 1);
        return DrumMachine.legacyVelToNew((h << 1) | l);
    }
    return DrumMachine.vel_full;
}

/// Pre-v23 migration: reconstruct a freshly `allocMidi`'d `midi` array from
/// the old per-pad `u64` bitmask + velocity - legacy files predate the
/// step-count ceiling growing past 64, so every bit position is safely
/// representable (bounded to `min(step_count, 64)` as defense-in-depth).
/// `legacy_pad_order`: see `applyNoteSnap`'s doc comment - same meaning,
/// same "never true for Slicer" rule. `vel`/`vel_lo`/`vel_hi` stay indexed
/// by the file's original (old-scheme) `pad` for the `legacyStepVel`
/// lookup below - they're parallel arrays to `pattern`, not yet remapped -
/// only the destination `midi`/`gridNote` pad is translated.
pub fn legacyPatternVelToMidi(
    midi: *[DrumMachine.max_pads][]?DrumMachine.MidiNote,
    step_count: u16,
    pattern: []const u64,
    vel: []const []const u8,
    vel_lo: []const u64,
    vel_hi: []const u64,
    legacy_pad_order: bool,
) void {
    const pn = @min(pattern.len, DrumMachine.max_pads);
    const limit = @min(step_count, 64);
    for (pattern[0..pn], 0..) |bits, pad| {
        const dest: u8 = if (legacy_pad_order) drum_kit.legacyPadIndex(@intCast(pad)) else @intCast(pad);
        if (dest >= DrumMachine.max_pads) continue;
        var step: u16 = 0;
        while (step < limit) : (step += 1) {
            if ((bits >> @intCast(step)) & 1 == 0) continue;
            const level = legacyStepVel(vel, vel_lo, vel_hi, pad, step);
            midi[dest][step] = DrumMachine.gridNote(dest, step, level);
        }
    }
}

// zig fmt: off
/// Rebuild an arrangement clip from its snapshot. Melodic clips copy notes
/// through a stack buffer into a fresh owned allocation; drum clips are inline.
pub fn clipFromSnap(allocator: std.mem.Allocator, cs: ClipSnap, beats_per_bar: u8, version: u32) !ws_arrangement.Clip {
    const ticks_per_bar = @as(u32, beats_per_bar) * time_grid.ticks_per_beat;
    const start_tick = cs.start_tick orelse cs.start_bar *| ticks_per_bar;
    const length_ticks = cs.length_ticks orelse cs.length_bars *| ticks_per_bar;
    var out: ws_arrangement.Clip = switch (cs.kind) {
        .melodic => blk: {
            var tmp: [pattern_mod.max_notes]pattern_mod.Note = undefined;
            const count = @min(cs.notes.len, @as(usize, pattern_mod.max_notes));
            for (cs.notes[0..count], tmp[0..count]) |n, *o| o.* = sanitizeNote(n);
            break :blk try ws_arrangement.Clip.initMelodic(
                allocator,
                start_tick,
                length_ticks,
                tmp[0..count],
                finiteClamp(f64, cs.length_beats, 1.0, std.math.floatMax(f64), 1.0),
            );
        },
        .drum => blk2: {
            var d: ws_arrangement.Clip.Drum = .{
                .step_count = std.math.clamp(cs.step_count, 1, DrumMachine.max_steps),
                .steps_per_beat = std.math.clamp(cs.steps_per_beat, 1, 32),
                .variant = @min(cs.variant, DrumMachine.max_variants - 1),
            };
            d.midi = try DrumMachine.allocMidi(allocator, d.step_count);
            if (version >= 23) {
                applyNoteSnap(&d.midi, d.step_count, cs.drum_notes, version < 36);
            } else {
                legacyPatternVelToMidi(&d.midi, d.step_count, cs.drum_pattern, cs.drum_vel, cs.drum_vel_lo, cs.drum_vel_hi, true);
            }
            break :blk2 ws_arrangement.Clip.initDrum(start_tick, length_ticks, d);
        },
    };
    errdefer out.deinit(allocator);
    out.automation.gain = try automationFromSnap(allocator, cs.gain_automation, -60.0, 12.0);
    out.automation.pan = try automationFromSnap(allocator, cs.pan_automation, -1.0, 1.0);
    try applySynthParamAutomationSnap(allocator, &out.automation, cs.synth_param_automation, cs.filter_cutoff_automation);
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
    legacy_filter_cutoff: []const AutomationPointSnap,
) !void {
    if (synth_param_automation.len > 0) {
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
        return;
    }
    if (legacy_filter_cutoff.len > 0) {
        const points = try automationFromSnap(allocator, legacy_filter_cutoff, 20.0, 20_000.0);
        try replaceSynthParamPoints(allocator, automation, 0, 21, points);
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
    p.fade_in_s       = finiteClamp(f32, ps.fade_in_s, 0.0, 5.0, 0.0);
    p.fade_out_s      = finiteClamp(f32, ps.fade_out_s, 0.0, 5.0, 0.0);
    p.stretch_ratio   = finiteClamp(f32, ps.stretch_ratio, 0.25, 4.0, 1.0);
    p.filter          = finiteClamp(f32, ps.filter, -1.0, 1.0, 0.0);
    p.gate            = ps.gate;
    p.retrig          = ps.retrig;
    p.mod_rate_hz     = finiteClamp(f32, ps.mod_rate_hz, 0.02, 20.0, 2.0);
    p.mod_depth       = finiteClamp(f32, ps.mod_depth, 0.0, 1.0, 0.0);
    p.mod_shape       = ps.mod_shape;
    p.mod_dest        = ps.mod_dest;
}
// zig fmt: on

/// A NoteSnap with pitch/velocity/times forced into playable ranges.
pub fn sanitizeNote(n: NoteSnap) pattern_mod.Note {
    return .{
        .pitch = @intCast(@min(n.pitch, 127)),
        .start_beat = finiteClamp(f64, n.start_beat, 0.0, std.math.floatMax(f64), 0.0),
        .duration_beat = finiteClamp(f64, n.duration_beat, 0.0, std.math.floatMax(f64), 0.0),
        .velocity = finiteClamp(f32, n.velocity, 0.0, 1.0, pattern_mod.default_velocity),
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

/// `fx_order` needs more than a per-field enum check: `std.json` guarantees
/// every entry is a *legal* `FxUnitKind`, but not that all kinds are
/// present exactly once (a hand-edited file could duplicate one kind and
/// drop another, silently dropping the missing unit from processing).
/// `order.len == FxUnitKind`'s variant count, so "every kind appears at
/// least once" already implies no duplicates (pigeonhole).
pub fn isValidFxOrder(order: [14]synth_mod.FxUnitKind) bool {
    var seen = [_]bool{false} ** 14;
    for (order) |kind| seen[@intFromEnum(kind)] = true;
    for (seen) |s| if (!s) return false;
    return true;
}

/// Apply a synth snapshot onto a live PolySynth, clamping every numeric
/// field to the same ranges `adjustParam` enforces - mirrors
/// `applyPadSnap`'s reasoning: a hand-edited or corrupted file could
/// otherwise smuggle an out-of-range value (e.g. unison 0 or 255, a
/// negative attack time) straight onto the audio thread. Enum fields
/// (waveform, filter_type, mod_mode, …) need no clamp - `std.json` already
/// rejects any value that isn't one of the declared tags at parse time.
pub fn applyToSynth(s: *PolySynth, ss: *const SynthSnap) !void {
    const clamp = std.math.clamp;
    try s.selectBundledWavetables(ss.wt_bundled, ss.osc_b_wt_bundled, ss.osc_c_wt_bundled);
    // Every plain param_specs field (id->field->range, shared with the live
    // h/l-nudge and automation paths) - see PolySynth.applyParamSpecs. What's
    // left below is what param_specs deliberately excludes: the mod matrix
    // (fixed array vs. optional slice, plus pre-v17 legacy migration) and
    // fx_order (needs isValidFxOrder validation, not a plain clamp).
    s.applyParamSpecs(ss);
    if (ss.mod_matrix) |rows| {
        // v17 file: take the rows as saved (clamped; a bad dest falls back
        // to cutoff inside setParamAbsolute's rules - mirror them here).
        for (0..PolySynth.max_mod_rows) |k| {
            if (k < rows.len) {
                var row = rows[k];
                row.depth = clamp(row.depth, -1.0, 1.0);
                if (PolySynth.modDestIndex(row.dest) == null) row.dest = 21;
                s.mod_matrix[k] = row;
            } else {
                s.mod_matrix[k] = .{};
            }
        }
    } else {
        // Pre-v17 file: fold the legacy fixed routes into matrix rows.
        const rows = PolySynth.legacyModRows(
            clamp(ss.fenv_amount, -4.0, 4.0),
            clamp(ss.lfo_depth, 0.0, 1.0),
            ss.lfo_target,
        );
        s.mod_matrix = [_]PolySynth.ModRow{.{}} ** PolySynth.max_mod_rows;
        s.mod_matrix[0] = rows[0];
        s.mod_matrix[1] = rows[1];
    }
    // fx_order needs isValidFxOrder validation (a hand-edited file could
    // repeat or drop a unit kind), not a plain per-field clamp.
    s.fx_order = if (isValidFxOrder(ss.fx_order)) ss.fx_order else synth_mod.default_fx_order;
    applyLfoCustomSnap(&s.lfo_custom[0], &s.lfo_custom_count[0], ss.lfo_custom);
    applyLfoCustomSnap(&s.lfo_custom[1], &s.lfo_custom_count[1], ss.lfo2_custom);
    applyLfoCustomSnap(&s.lfo_custom[2], &s.lfo_custom_count[2], ss.lfo3_custom);
}

/// One `.custom` LFO slot's points from a snap onto the live fixed array +
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
        const unit = switch (us.kind) {
            .clap => blk: {
                const cs = us.clap orelse return error.MalformedProject;
                const loaded = try fx_out.insertClap(allocator, fx_out.units.items.len, cs.path, cs.plugin_id, sr);
                if (transport) |value| loaded.payload.clap.attachTransport(value);
                try loadClapState(allocator, loaded.payload.clap, cs.state_base64);
                break :blk loaded;
            },
            .vst3 => blk: {
                const vs = us.vst3 orelse return error.MalformedProject;
                if (vs.path.len == 0 or vs.class_id.len != 32) return error.MalformedProject;
                const loaded = try fx_out.insertVst3(allocator, fx_out.units.items.len, vs.path, vs.class_id, sr);
                if (transport) |value| loaded.payload.vst3.attachTransport(value);
                try loadVst3State(allocator, loaded.payload.vst3, vs.component_state_base64, vs.controller_state_base64);
                break :blk loaded;
            },
            else => |saved_kind| blk: {
                const kind: rack_mod.FxKind = switch (saved_kind) {
                    .gate => .gate, .comp => .comp, .mb_comp => .mb_comp, .ott => .ott, .limiter => .limiter, .transient_shaper => .transient_shaper,
                    .eq => .eq, .filter => .filter, .utility => .utility, .stereo_width => .stereo_width, .auto_pan => .auto_pan, .sat => .sat, .crush => .crush, .chorus => .chorus,
                    .phaser => .phaser, .flanger => .flanger, .tape => .tape,
                    .freq_shift => .freq_shift, .delay => .delay, .reverb => .reverb,
                    .clap, .vst3 => unreachable,
                };
                break :blk try fx_out.insert(allocator, fx_out.units.items.len, kind, sr);
            },
        };
        unit.bypassed = us.bypassed;
        if (us.instance_id != 0 and fx_out.findInstance(us.instance_id) == null) {
            unit.instance_id = us.instance_id;
            if (fx_out.next_instance_id <= us.instance_id) {
                fx_out.next_instance_id = us.instance_id +% 1;
                if (fx_out.next_instance_id == 0) fx_out.next_instance_id = 1;
            }
        }
        switch (unit.payload) {
            .comp => |*c| if (us.comp) |cs| {
                if (std.math.isFinite(cs.threshold_db)) c.threshold_db = cs.threshold_db;
                if (std.math.isFinite(cs.ratio)) c.ratio = cs.ratio;
                if (std.math.isFinite(cs.attack_ms)) c.attack_ms = cs.attack_ms;
                if (std.math.isFinite(cs.release_ms)) c.release_ms = cs.release_ms;
                if (std.math.isFinite(cs.makeup_db)) c.makeup_db = cs.makeup_db;
                if (std.math.isFinite(cs.knee_db)) c.knee_db = cs.knee_db;
                c.sidechain_source = if (cs.sidechain_source) |src| .{
                    .track = if (cs.sidechain_is_group)
                        @min(src, engine_mod.max_groups - 1)
                    else
                        @min(src, engine_mod.max_tracks - 1),
                    .pad = if (cs.sidechain_is_group) null else if (cs.sidechain_pad) |p| @min(p, DrumMachine.max_pads - 1) else null,
                    .is_group = cs.sidechain_is_group,
                } else null;
            },
            .mb_comp => |*m| if (us.mb_comp) |ms| {
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
            .ott => |*o| if (us.ott) |os| {
                o.setDepth(os.depth);
                o.setTime(os.time);
                o.gain_in_db = finiteClamp(f32, os.gain_in_db, -24.0, 24.0, o.gain_in_db);
                o.gain_out_db = finiteClamp(f32, os.gain_out_db, -24.0, 24.0, o.gain_out_db);
            },
            .delay => |*d| if (us.delay) |ds| applySnapToDevice(d, ds),
            .reverb => |*r| if (us.reverb) |rs| applySnapToDevice(r, rs),
            .eq => |*e| if (us.eq) |es| {
                const bands = es.bands orelse
                    migrateEqBands(es.band_gains orelse [_]f32{0.0} ** legacy_eq_band_count);
                for (bands, 0..) |b, i| {
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
                // Legacy EQ-only bypass maps onto the slot's generic one.
                if (es.bypass) unit.bypassed = true;
            },
            .filter => |*f| if (us.filter) |fs| applySnapToDevice(f, fs),
            .limiter => |*l| if (us.limiter) |ls| applySnapToDevice(l, ls),
            .utility => |*u| if (us.utility) |usnap| applySnapToDevice(u, usnap),
            .stereo_width => |*w| if (us.stereo_width) |wsnap| applySnapToDevice(w, wsnap),
            .auto_pan => |*a| if (us.auto_pan) |asnap| applySnapToDevice(a, asnap),
            .transient_shaper => |*t| if (us.transient_shaper) |tsnap| applySnapToDevice(t, tsnap),
            .gate => |*g| if (us.gate) |gs| applySnapToDevice(g, gs),
            .sat => |*s| if (us.sat) |ss| applySnapToDevice(s, ss),
            .crush => |*c| if (us.crush) |cs| applySnapToDevice(c, cs),
            .chorus => |*c| if (us.chorus) |cs| applySnapToDevice(c, cs),
            .phaser => |*p| if (us.phaser) |ps| applySnapToDevice(p, ps),
            .flanger => |*fl| if (us.flanger) |fs| applySnapToDevice(fl, fs),
            .tape => |*t| if (us.tape) |ts| applySnapToDevice(t, ts),
            .freq_shift => |*f| if (us.freq_shift) |fs| applySnapToDevice(f, fs),
            .clap, .vst3 => {},
        }
    }
}

/// Move old synth-owned inserts into Rack's shared modular chain. Insert at
/// chain front because legacy signal flow was synth inserts, then rack FX.
pub fn migrateSynthFx(allocator: std.mem.Allocator, s: *PolySynth, fx: *Fx, sr: u32) !void {
    var pos: usize = 0;
    for (s.fx_order) |kind| {
        const enabled = switch (kind) {
            .gate => s.fx_gate_on,
            .eq => s.fx_eq_on,
            .comp => s.fx_comp_on,
            .mb_comp => s.fx_mb_on,
            .ott => s.fx_ott_on,
            .dist => s.fx_dist_on,
            .crush => s.fx_crush_on,
            .chorus => s.fx_chorus_on,
            .flanger => s.fx_flanger_on,
            .tape => s.fx_tape_on,
            .phaser => s.fx_phaser_on,
            .freq_shift => s.fx_freq_shift_on,
            .delay => s.fx_delay_on,
            .reverb => s.fx_reverb_on,
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
            if (row.fx_instance_id == 0 and fxKindOwnsParam(kind, row.dest))
                row.fx_instance_id = unit.instance_id;
        }
        pos += 1;
        switch (unit.payload) {
            .gate => |*v| {
                v.threshold_db = s.fx_gate_threshold_db;
                v.attack_ms = s.fx_gate_attack_ms;
                v.release_ms = s.fx_gate_release_ms;
            },
            .eq => |*v| {
                v.setFreq(0, s.fx_eq_low_freq);
                v.setGain(0, s.fx_eq_low_gain_db);
                v.setType(0, .lowshelf, 1);
                v.setFreq(1, s.fx_eq_mid_freq);
                v.setGain(1, s.fx_eq_mid_gain_db);
                v.setQ(1, s.fx_eq_mid_q);
                v.setType(1, .peak, 1);
                v.setFreq(2, s.fx_eq_high_freq);
                v.setGain(2, s.fx_eq_high_gain_db);
                v.setType(2, .highshelf, 1);
            },
            .comp => |*v| {
                v.threshold_db = s.fx_comp_threshold_db;
                v.ratio = s.fx_comp_ratio;
                v.attack_ms = s.fx_comp_attack_ms;
                v.release_ms = s.fx_comp_release_ms;
                v.makeup_db = s.fx_comp_makeup_db;
            },
            .mb_comp => |*v| {
                v.setXovers(s.fx_mb_xover_lo, s.fx_mb_xover_hi);
                v.attack_ms = s.fx_mb_attack_ms;
                v.release_ms = s.fx_mb_release_ms;
                v.style = s.fx_mb_style;
                v.mix = s.fx_mb_mix;
                v.bands[0].threshold_db = s.fx_mb_low_threshold_db;
                v.bands[0].ratio = s.fx_mb_low_ratio;
                v.bands[0].makeup_db = s.fx_mb_low_makeup_db;
                v.bands[1].threshold_db = s.fx_mb_mid_threshold_db;
                v.bands[1].ratio = s.fx_mb_mid_ratio;
                v.bands[1].makeup_db = s.fx_mb_mid_makeup_db;
                v.bands[2].threshold_db = s.fx_mb_high_threshold_db;
                v.bands[2].ratio = s.fx_mb_high_ratio;
                v.bands[2].makeup_db = s.fx_mb_high_makeup_db;
            },
            .ott => |*v| {
                v.setDepth(s.fx_ott_depth);
                v.setTime(s.fx_ott_time);
                v.gain_in_db = s.fx_ott_gain_in_db;
                v.gain_out_db = s.fx_ott_gain_out_db;
            },
            .sat => |*v| {
                v.drive_db = s.fx_dist_drive_db;
                v.mix = s.fx_dist_mix;
            },
            .crush => |*v| {
                v.bits = s.fx_crush_bits;
                v.downsample = s.fx_crush_rate;
                v.mix = s.fx_crush_mix;
            },
            .chorus => |*v| {
                v.rate_hz = s.fx_chorus_rate_hz;
                v.depth_ms = s.fx_chorus_depth_ms;
                v.mix = s.fx_chorus_mix;
            },
            .flanger => |*v| {
                v.rate_hz = s.fx_flanger_rate_hz;
                v.depth = s.fx_flanger_depth;
                v.feedback = s.fx_flanger_feedback;
                v.mix = s.fx_flanger_mix;
            },
            .tape => |*v| {
                v.wow_rate_hz = s.fx_tape_wow_rate_hz;
                v.wow_depth = s.fx_tape_wow_depth;
                v.flutter_rate_hz = s.fx_tape_flutter_rate_hz;
                v.flutter_depth = s.fx_tape_flutter_depth;
                v.mix = s.fx_tape_mix;
            },
            .phaser => |*v| {
                v.rate_hz = s.fx_phaser_rate_hz;
                v.depth = s.fx_phaser_depth;
                v.feedback = s.fx_phaser_feedback;
                v.mix = s.fx_phaser_mix;
            },
            .freq_shift => |*v| {
                v.shift_hz = s.fx_freq_shift_hz;
                v.mix = s.fx_freq_shift_mix;
            },
            .delay => |*v| {
                v.time_s = s.fx_delay_time_s;
                v.feedback = s.fx_delay_feedback;
                v.mix = s.fx_delay_mix;
            },
            .reverb => |*v| {
                v.room = s.fx_reverb_room;
                v.damp = s.fx_reverb_damp;
                v.mix = s.fx_reverb_mix;
            },
            .filter, .limiter, .utility, .stereo_width, .auto_pan, .transient_shaper, .clap, .vst3 => unreachable,
        }
    }
    clearMigratedSynthFx(s);
}

pub fn clearMigratedSynthFx(s: *PolySynth) void {
    s.fx_gate_on = false;
    s.fx_eq_on = false;
    s.fx_comp_on = false;
    s.fx_mb_on = false;
    s.fx_ott_on = false;
    s.fx_dist_on = false;
    s.fx_crush_on = false;
    s.fx_chorus_on = false;
    s.fx_flanger_on = false;
    s.fx_tape_on = false;
    s.fx_phaser_on = false;
    s.fx_freq_shift_on = false;
    s.fx_delay_on = false;
    s.fx_reverb_on = false;
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
    migrateSynthFx(allocator, &probe, &replacement, sr) catch |err| {
        replacement.deinit(allocator);
        return err;
    };
    errdefer replacement.deinit(allocator);
    try synth.applyPatchWithWavetables(patch);
    // `migrateSynthFx` bound every row that modulates an FX param to the
    // unit it created for that param, but it ran against `probe` - the whole
    // point of the probe being that a failed migration leaves the live synth
    // untouched. `applyPatchWithWavetables` just rewrote the real matrix from
    // the patch, whose rows carry no instance id, so carry the bindings over
    // or every migrated modulation lands on nothing.
    for (&synth.mod_matrix, probe.mod_matrix) |*row, migrated| row.fx_instance_id = migrated.fx_instance_id;
    clearMigratedSynthFx(synth);
    const displaced = rack.fx;
    rack.fx = replacement;
    return displaced;
}

/// v9-and-older fallback: expand the fixed struct-of-optionals rack into
/// unit snaps in the order the old `Fx.chain()` hard-wired, then load them
/// through the same path as v10 chains.
pub fn applyLegacyFx(allocator: std.mem.Allocator, fx_out: *Fx, fx: FxSnap, sr: u32, transport: ?*const Transport) !void {
    var snaps: [Fx.max_units]FxUnitSnap = undefined;
    var n: usize = 0;
    if (fx.gate)   |gs| { snaps[n] = .{ .kind = .gate, .gate = gs };       n += 1; }
    if (fx.comp)   |cs| { snaps[n] = .{ .kind = .comp, .comp = cs };       n += 1; }
    if (fx.eq)     |es| { snaps[n] = .{ .kind = .eq, .eq = es };           n += 1; }
    if (fx.sat)    |ss| { snaps[n] = .{ .kind = .sat, .sat = ss };         n += 1; }
    if (fx.crush)  |cs| { snaps[n] = .{ .kind = .crush, .crush = cs };     n += 1; }
    if (fx.chorus) |cs| { snaps[n] = .{ .kind = .chorus, .chorus = cs };   n += 1; }
    if (fx.phaser) |ps| { snaps[n] = .{ .kind = .phaser, .phaser = ps };   n += 1; }
    if (fx.delay)  |ds| { snaps[n] = .{ .kind = .delay, .delay = ds };     n += 1; }
    if (fx.reverb) |rs| { snaps[n] = .{ .kind = .reverb, .reverb = rs };   n += 1; }
    try applyFxChain(allocator, fx_out, snaps[0..n], sr, transport);
}
