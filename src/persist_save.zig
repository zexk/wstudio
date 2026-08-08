//! Project save path: serialize a live Session to JSON. Split out of
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
const PitchShiftSnap = persist_types.PitchShiftSnap;
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
const ControllerSnap = persist_types.ControllerSnap;
const ControllerTargetSnap = persist_types.ControllerTargetSnap;
const CcBindingSnap = persist_types.CcBindingSnap;
const ClipKind = persist_types.ClipKind;
const ClipSnap = persist_types.ClipSnap;
const AudioSourceSnap = persist_types.AudioSourceSnap;
const LaneSnap = persist_types.LaneSnap;
const SectionSnap = persist_types.SectionSnap;
const Snapshot = persist_types.Snapshot;
/// Serialise `session` as pretty-printed JSON to `path`. Writes to
/// `<path>.tmp` and renames over the target so a crash mid-write never
/// corrupts an existing project file. User-loaded sample audio is exported
/// alongside into the "<stem>_samples" sidecar directory (see
/// `exportSamples`). Safe to call while the audio thread is running.
pub fn save(
    allocator: std.mem.Allocator,
    session: *const Session,
    io: std.Io,
    path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // zig fmt: off
    const tracks = try aa.alloc(TrackSnap, session.project.tracks.items.len);
    for (session.project.tracks.items, tracks) |t, *ts| {
        var sends_buf: [project_mod.max_sends_per_track]SendSnap = undefined;
        var sends_len: usize = 0;
        for (t.sends) |maybe_send| {
            const snd = maybe_send orelse continue;
            sends_buf[sends_len] = switch (snd.target) {
                .master => .{ .is_group = false, .group = 0, .level_db = types.gainToDb(snd.level) },
                .group => |g| .{ .is_group = true, .group = g, .level_db = types.gainToDb(snd.level) },
            };
            sends_len += 1;
        }
        ts.* = .{
            .name = t.name, .gain_db = t.gain_db, .pan = t.pan, .muted = t.muted,
            .soloed = t.soloed, .color = t.color, .group = t.group,
            .sends = try aa.dupe(SendSnap, sends_buf[0..sends_len]),
        };
    }
    // zig fmt: on

    // Dense, always max_groups entries so a slot's position in the array IS
    // its index - TrackSnap.group references that position directly, no
    // separate id field or remapping needed on either side.
    const groups = try aa.alloc(GroupSnap, engine_mod.max_groups);
    for (groups, 0..) |*gs, i| {
        if (session.groups[i]) |*g| {
            gs.* = .{ .active = true, .name = g.name, .fx_chain = try chainToSnap(aa, &g.fx), .gain_db = g.gain_db, .folded = g.folded, .muted = g.muted, .soloed = g.soloed };
        } else {
            gs.* = .{};
        }
    }

    // Only the slots actually in use are written, each carrying its own
    // bank index - an unused controller has nothing to say.
    var controller_list: std.ArrayList(ControllerSnap) = .empty;
    for (session.project.controllers, 0..) |maybe, i| {
        const c = maybe orelse continue;
        var targets: std.ArrayList(ControllerTargetSnap) = .empty;
        for (c.targets) |maybe_target| {
            const t = maybe_target orelse continue;
            try targets.append(aa, .{
                .track = t.track,
                .instance_id = t.instance_id,
                .param_id = t.param_id,
                .center = t.center,
                .lo = t.lo,
                .hi = t.hi,
            });
        }
        try controller_list.append(aa, .{
            .index = @intCast(i),
            .shape = c.shape,
            .beats = c.beats,
            .depth = c.depth,
            .phase = c.phase,
            .targets = targets.items,
        });
    }

    var cc_list: std.ArrayList(CcBindingSnap) = .empty;
    for (session.project.cc_bindings) |maybe| {
        const b = maybe orelse continue;
        try cc_list.append(aa, .{ .cc = b.cc, .target = .{
            .track = b.target.track,
            .instance_id = b.target.instance_id,
            .param_id = b.target.param_id,
            .center = b.target.center,
            .lo = b.target.lo,
            .hi = b.target.hi,
        } });
    }

    const racks = try aa.alloc(RackSnap, session.racks.items.len);
    for (session.racks.items, racks) |rack, *rs| {
        rs.* = try rackToSnap(aa, rack);
    }
    const audio_sources = try aa.alloc(AudioSourceSnap, session.project.audio_sources.items.len);
    for (session.project.audio_sources.items, audio_sources) |source, *snap| snap.* = .{
        .id = source.id,
        .file = "",
        .sample_rate = source.sample_rate,
        .channel_count = source.channel_count,
    };
    try exportSamples(aa, session, io, path, racks, audio_sources);

    const lanes = try aa.alloc(LaneSnap, session.arrangement.lanes.items.len);
    for (session.arrangement.lanes.items, lanes) |*lane, *ls| {
        const clips = try aa.alloc(ClipSnap, lane.clips.items.len);
        for (lane.clips.items, clips) |clip, *c| c.* = try clipToSnap(aa, clip);
        ls.* = .{ .clips = clips };
    }
    const sections = try aa.alloc(SectionSnap, session.project.sections.items.len);
    for (session.project.sections.items, sections) |section, *ss| ss.* = .{ .tick = section.tick, .name = section.name };

    const snap: Snapshot = .{
        .tempo_bpm = session.project.tempo_bpm,
        .scale = session.project.scale,
        .tuning = session.project.tuning,
        .beats_per_bar = session.project.beats_per_bar,
        .loop_enabled = session.project.loop_enabled,
        .loop_start_bar = session.project.loop_start_bar,
        .loop_end_bar = session.project.loop_end_bar,
        .sample_rate = session.project.sample_rate,
        .tracks = tracks,
        .racks = racks,
        .arrangement = lanes,
        .sections = sections,
        .audio_sources = audio_sources,
        .song_mode = session.song_mode,
        .master_fx_chain = try chainToSnap(aa, &session.master_fx),
        .groups = groups,
        .controllers = controller_list.items,
        .cc_bindings = cc_list.items,
    };

    const tmp_path = try std.fmt.allocPrint(aa, "{s}.tmp", .{path});
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        // Stream straight from snapshot arena. `valueAlloc` duplicated whole
        // project as one more buffer before writing, doubling peak save memory.
        try std.json.Stringify.value(snap, .{ .whitespace = .indent_2 }, &fw.interface);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Build a v23 sparse note-list snapshot from a live/borrowed `midi` array
/// (see `DrumMachine.dupeMidi`'s doc comment - this only reads, never
/// frees or holds the source past the call).
pub fn midiToNoteSnaps(aa: std.mem.Allocator, midi: *const [DrumMachine.max_pads][]?DrumMachine.MidiNote) ![]const DrumNoteSnap {
    var count: usize = 0;
    for (midi) |row| for (row) |n| {
        if (n != null) count += 1;
    };
    const out = try aa.alloc(DrumNoteSnap, count);
    var i: usize = 0;
    for (midi, 0..) |row, pad| {
        for (row) |maybe_note| {
            const note = maybe_note orelse continue;
            out[i] = .{
                .pad = @intCast(pad),
                .step = note.step,
                .duration_steps = note.duration_steps,
                .velocity = note.velocity,
                .tune = note.tune,
                .prob = note.prob,
                .cond = @intFromEnum(note.cond),
                .retrig = note.retrig,
                .micro = note.micro,
            };
            i += 1;
        }
    }
    return out;
}

pub fn rackToSnap(aa: std.mem.Allocator, rack: *Rack) !RackSnap {
    var rs: RackSnap = .{ .label = rack.label, .content = undefined };

    // zig fmt: off
    switch (rack.instrument) {
        .empty => {
            rs.content = .empty;
        },
        .poly_synth => |*s| {
            
            var ss = synthToSnap(s);
            if (rack.pattern_player) |*pp| {
                ss.pattern = .{ .length_beats = pp.length_beats, .notes = try notesToSnap(aa, pp), .swing = pp.swing.load(.monotonic) };
            }
            rs.content = .{ .poly_synth = ss };
        },
        .sampler => |*s| {
            
            var smp: SamplerSnap = .{
                .pad = .{
                    .gain = s.pad.gain, .pan = s.pad.pan, .pitch_semitones = s.pad.pitch_semitones,
                    .start_norm = s.pad.start_norm, .end_norm = s.pad.end_norm, .reverse = s.pad.reverse,
                    .attack_s = s.pad.attack_s, .decay_s = s.pad.decay_s,
                    .sustain = s.pad.sustain, .release_s = s.pad.release_s,
                    .fade_in_s = s.pad.fade_in_s, .fade_out_s = s.pad.fade_out_s,
                    .stretch_ratio = s.pad.stretch_ratio,
                    .filter = s.pad.filter, .gate = s.pad.gate, .retrig = s.pad.retrig,
                    .mod_rate_hz = s.pad.mod_rate_hz, .mod_depth = s.pad.mod_depth,
                    .mod_shape = s.pad.mod_shape, .mod_dest = s.pad.mod_dest, .loop = s.pad.loop,
                    // Always saved - see the drum pad loop's comment above.
                    .name = try aa.dupe(u8, s.clipName()),
                },
                .root_note = s.root_note,
                .mono = s.mono,
            };
            if (rack.pattern_player) |*pp| {
                smp.pattern = .{ .length_beats = pp.length_beats, .notes = try notesToSnap(aa, pp), .swing = pp.swing.load(.monotonic) };
            }
            rs.content = .{ .sampler = smp };
        },
        .drum_machine => |*dm| {
            
            var ds: DrumSnap = .{
                .variant = dm.variant,
                .swing = dm.swing.load(.monotonic),
                .kit = dm.kit,
            };
            // Dense, always DrumMachine.max_pads entries - position IS the
            // pad index everywhere below, same "slice for JSON-length
            // safety, but positionally dense" shape VariantSnap's own doc
            // comment explains.
            const choke = try aa.alloc(u8, DrumMachine.max_pads);
            @memcpy(choke, &dm.choke_group);
            ds.choke_group = choke;
            const pad_len = try aa.alloc(u16, DrumMachine.max_pads);
            @memcpy(pad_len, &dm.pad_len);
            ds.pad_len = pad_len;
            // zig fmt: on

            const variants = try aa.alloc(VariantSnap, dm.variant_count);
            for (variants, 0..) |*vs, vi| {
                // variantData reads the active slot from the live state.
                const v = dm.variantData(@intCast(vi));
                vs.* = .{ .step_count = v.step_count, .steps_per_beat = v.steps_per_beat, .notes = try midiToNoteSnaps(aa, &v.midi) };
            }
            ds.variants = variants;

            // zig fmt: off
            const pads = try aa.alloc(PadSnap, DrumMachine.max_pads);
            for (pads, 0..) |*ps, i| {
                if (dm.pads[i]) |*s| {
                    const p = &s.pad;
                    ps.* = .{
                        .used = true,
                        .gain = p.gain, .pan = p.pan, .pitch_semitones = p.pitch_semitones,
                        .start_norm = p.start_norm, .end_norm = p.end_norm, .reverse = p.reverse,
                        .attack_s = p.attack_s, .decay_s = p.decay_s,
                        .sustain = p.sustain, .release_s = p.release_s,
                        .fade_in_s = p.fade_in_s, .fade_out_s = p.fade_out_s,
                        .stretch_ratio = p.stretch_ratio,
                        .filter = p.filter, .gate = p.gate, .retrig = p.retrig,
                        .mod_rate_hz = p.mod_rate_hz, .mod_depth = p.mod_depth,
                        .mod_shape = p.mod_shape, .mod_dest = p.mod_dest, .loop = p.loop,
                        // Always saved (like a track name), independent of
                        // whether the pad has user-loaded audio - a `:rename`
                        // on a shipped-kit pad has no sample_file to carry the
                        // name through otherwise. exportSamples overwrites this
                        // with the same value for user-sample pads.
                        .name = try aa.dupe(u8, s.clipName()),
                    };
                } else {
                    ps.* = .{}; // used = false - unloaded, nothing else here is meaningful
                }
            }
            ds.pads = pads;
            rs.content = .{ .drum_machine = ds };
        },
        .slicer => |*sl| {
            
            var sls: SlicerSnap = .{
                .swing = sl.swing.load(.monotonic),
                // Always saved - see the drum pad loop's identical comment
                // above (exportSamples overwrites this for user-sample clips).
                .name = try aa.dupe(u8, sl.clipName()),
            };

            const slices = try aa.alloc(PadSnap, sl.slice_count);
            for (slices, 0..) |*ps, i| {
                const p = &sl.slices[i];
                ps.* = .{
                    .gain = p.gain, .pan = p.pan, .pitch_semitones = p.pitch_semitones,
                    .start_norm = p.start_norm, .end_norm = p.end_norm, .reverse = p.reverse,
                    .attack_s = p.attack_s, .decay_s = p.decay_s,
                    .sustain = p.sustain, .release_s = p.release_s,
                    .fade_in_s = p.fade_in_s, .fade_out_s = p.fade_out_s,
                    .stretch_ratio = p.stretch_ratio,
                    .filter = p.filter, .gate = p.gate, .retrig = p.retrig,
                    .mod_rate_hz = p.mod_rate_hz, .mod_depth = p.mod_depth,
                    .mod_shape = p.mod_shape, .mod_dest = p.mod_dest, .loop = p.loop,
                };
            }
            sls.slices = slices;
            // zig fmt: on

            // The whole variant bank; the active slot reads through
            // variantData (its bank copy is stale) - mirrors the drum
            // export above.
            const variants = try aa.alloc(VariantSnap, sl.variant_count);
            for (variants, 0..) |*vs, vi| {
                const v = sl.variantData(@intCast(vi));
                vs.* = .{
                    .step_count = v.step_count,
                    .steps_per_beat = v.steps_per_beat,
                    .notes = try midiToNoteSnaps(aa, &v.midi),
                };
            }
            sls.variants = variants;
            sls.variant = sl.variant;

            const choke = try aa.alloc(u8, Slicer.max_slices);
            for (choke, sl.choke_group) |*c, g| c.* = g;
            sls.choke_group = choke;

            const slice_len = try aa.alloc(u16, Slicer.max_slices);
            @memcpy(slice_len, &sl.slice_len);
            sls.slice_len = slice_len;

            rs.content = .{ .slicer = sls };
        },
        .clap => |plugin| {
            var cs = try clapToSnap(aa, plugin);
            if (rack.pattern_player) |*pp| {
                cs.pattern = .{ .length_beats = pp.length_beats, .notes = try notesToSnap(aa, pp), .swing = pp.swing.load(.monotonic) };
            }
            rs.content = .{ .clap = cs };
        },
        .vst3 => |plugin| {
            var vs = try vst3ToSnap(aa, plugin);
            if (rack.pattern_player) |*pp| {
                vs.pattern = .{ .length_beats = pp.length_beats, .notes = try notesToSnap(aa, pp), .swing = pp.swing.load(.monotonic) };
            }
            rs.content = .{ .vst3 = vs };
        },
        inline .soundfont, .acoustic => |*sf, tag| {
            var sfs: SoundfontSnap = .{
                .preset_index = sf.preset_index,
                .gain = sf.gain,
                .pan = sf.pan,
                .transpose_semitones = sf.transpose_semitones,
                .library = if (sf.builtin) |id| @tagName(id) else "",
            };
            if (rack.pattern_player) |*pp| {
                sfs.pattern = .{ .length_beats = pp.length_beats, .notes = try notesToSnap(aa, pp), .swing = pp.swing.load(.monotonic) };
            }
            rs.content = if (tag == .acoustic) .{ .acoustic = sfs } else .{ .soundfont = sfs };
        },
    }

    rs.fx_chain = try chainToSnap(aa, &rack.fx);

    return rs;
}

pub fn clapToSnap(aa: std.mem.Allocator, plugin: *rack_mod.ClapPlugin) !ClapSnap {
    var state_base64: []const u8 = "";
    if (try plugin.saveState(aa)) |state| {
        defer aa.free(state);
        const encoded = try aa.alloc(u8, std.base64.standard.Encoder.calcSize(state.len));
        state_base64 = std.base64.standard.Encoder.encode(encoded, state);
    }
    return .{
        .path = try aa.dupe(u8, plugin.pluginPath()),
        .plugin_id = try aa.dupe(u8, plugin.id()),
        .state_base64 = state_base64,
    };
}

pub fn vst3ToSnap(aa: std.mem.Allocator, plugin: *rack_mod.Vst3Plugin) !Vst3Snap {
    const component = try plugin.saveComponentState(aa);
    defer aa.free(component);
    const component_encoded = try aa.alloc(u8, std.base64.standard.Encoder.calcSize(component.len));
    _ = std.base64.standard.Encoder.encode(component_encoded, component);
    var controller_encoded: []const u8 = "";
    if (try plugin.saveControllerState(aa)) |controller| {
        defer aa.free(controller);
        const encoded = try aa.alloc(u8, std.base64.standard.Encoder.calcSize(controller.len));
        controller_encoded = std.base64.standard.Encoder.encode(encoded, controller);
    }
    return .{
        .path = try aa.dupe(u8, plugin.pluginPath()),
        .class_id = try aa.dupe(u8, plugin.classId()),
        .component_state_base64 = component_encoded,
        .controller_state_base64 = controller_encoded,
    };
}

/// Copy a device's fields into its Snap type by name - for the FX kinds
/// below where the two structs mirror 1:1 (device just carries extra
/// runtime-state fields the Snap doesn't have). comp/mb_comp/ott/delay/eq
/// keep hand-written cases since they transform or nest fields.
pub fn snapFromDevice(comptime Snap: type, device: anytype) Snap {
    var out: Snap = .{};
    inline for (std.meta.fields(Snap)) |f| @field(out, f.name) = @field(device, f.name);
    return out;
}

// zig fmt: off
/// Shared by track racks and the master bus - both hold a user-built `Fx`
/// chain. One FxUnitSnap per slot, in chain order.
pub fn chainToSnap(aa: std.mem.Allocator, fx: *const Fx) ![]FxUnitSnap {
    const out = try aa.alloc(FxUnitSnap, fx.units.items.len);
    for (fx.units.items, out) |u, *us| {
        us.* = switch (u.payload) {
            .comp => |c| .{ .content = .{ .comp = .{
                .threshold_db = c.threshold_db, .ratio = c.ratio,
                .attack_ms = c.attack_ms, .release_ms = c.release_ms, .makeup_db = c.makeup_db,
                .knee_db = c.knee_db,
                .sidechain_source = if (c.sidechain_source) |sc| sc.track else null,
                .sidechain_pad = if (c.sidechain_source) |sc| sc.pad else null,
                .sidechain_is_group = if (c.sidechain_source) |sc| sc.is_group else false,
            } } },
            .mb_comp => |m| .{ .content = .{ .mb_comp = .{
                .xover_lo_hz = m.xover_lo_hz, .xover_hi_hz = m.xover_hi_hz,
                .attack_ms = m.attack_ms, .release_ms = m.release_ms,
                .knee_db = m.knee_db,
                .ott = m.style == .ott, .mix = m.mix,
                .low_threshold_db = m.bands[0].threshold_db, .low_ratio = m.bands[0].ratio, .low_makeup_db = m.bands[0].makeup_db,
                .mid_threshold_db = m.bands[1].threshold_db, .mid_ratio = m.bands[1].ratio, .mid_makeup_db = m.bands[1].makeup_db,
                .high_threshold_db = m.bands[2].threshold_db, .high_ratio = m.bands[2].ratio, .high_makeup_db = m.bands[2].makeup_db,
            } } },
            .ott => |o| .{ .content = .{ .ott = .{
                .depth = o.depth(), .time = o.time,
                .gain_in_db = o.gain_in_db, .gain_out_db = o.gain_out_db,
            } } },
            .delay => |d| .{ .content = .{ .delay = snapFromDevice(DelaySnap, d) } },
            .reverb => |r| .{ .content = .{ .reverb = snapFromDevice(ReverbSnap, r) } },
            .eq => |e| blk: {
                var bands: [eq_mod.num_eq_bands]EqBandSnap = undefined;
                for (&e.bands, 0..) |*b, i| bands[i] = .{
                    .freq = b.freq, .q = b.q, .gain_db = b.gain_db,
                    .kind = switch (b.kind) {
                        .peak => .peak, .lowpass => .lowpass, .highpass => .highpass,
                        .lowshelf => .lowshelf, .highshelf => .highshelf,
                        .notch => .notch, .tiltshelf => .tiltshelf,
                    },
                    .slope = b.slope,
                    .solo = b.solo,
                    .stereo_mode = switch (b.stereo_mode) {
                        .stereo => .stereo, .mid => .mid, .side => .side,
                    },
                    .dyn_enabled = b.dyn_enabled,
                    .dyn_threshold_db = b.dyn_threshold_db,
                    .dyn_amount_db = b.dyn_amount_db,
                };
                break :blk .{ .content = .{ .eq = .{ .bands = bands, .auto_gain = e.auto_gain } } };
            },
            inline else => |device, tag| .{ .content = @unionInit(persist_types.FxContentSnap, @tagName(tag), if (tag == .clap) try clapToSnap(aa, device) else if (tag == .vst3) try vst3ToSnap(aa, device) else snapFromDevice(@FieldType(persist_types.FxContentSnap, @tagName(tag)), device)) },
        };
        us.bypassed = u.bypassed;
        us.instance_id = u.instance_id;
    }
    return out;
}
// zig fmt: on

// ---------------------------------------------------------------------------
// Sample sidecar - user-loaded audio lives in "<stem>_samples/" next to the
// .wsj as mono 16-bit WAVs; PadSnap.sample_file holds the .wsj-relative path.
// ---------------------------------------------------------------------------

/// Write every user-loaded pad's audio (`Pad.user_sample`) into the sample
/// sidecar directory and point the matching pad snapshots at the files. The
/// directory is only created when the session actually holds user samples.
/// Control thread only: pad buffers are stable while the audio thread runs
/// (they are replaced only by other control-thread calls).
pub fn exportSamples(
    aa: std.mem.Allocator,
    session: *const Session,
    io: std.Io,
    path: []const u8,
    racks: []RackSnap,
    audio_sources: []AudioSourceSnap,
) !void {
    const sidecar = try std.fmt.allocPrint(aa, "{s}_samples", .{std.fs.path.stem(path)});
    const sr = session.project.sample_rate;
    var dir_ready = false;
    // Basenames written this save - anything else already in the sidecar
    // dir is left over from a previous save under different track/pad
    // indices and gets swept below.
    var written: std.StringHashMapUnmanaged(void) = .empty;
    for (session.racks.items, racks, 0..) |rack, *rs, ti| {
        switch (rack.instrument) {
            .drum_machine => |*dm| for (0..DrumMachine.max_pads) |pi| {
                const s = if (dm.pads[pi]) |*sm| sm else continue; // unloaded pad - nothing to export
                const p = &s.pad;
                if (!p.user_sample) continue;
                const base = try std.fmt.allocPrint(aa, "t{d}p{d}.wav", .{ ti, pi });
                const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, p.samples);
                rs.content.drum_machine.pads[pi].sample_file = rel;
                try written.put(aa, base, {});
                // .name already set by rackToSnap (unconditionally, for every pad).
            },
            .sampler => |*s| if (s.pad.user_sample) {
                const base = try std.fmt.allocPrint(aa, "t{d}clip.wav", .{ti});
                const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.pad.samples);
                rs.content.sampler.pad.sample_file = rel;
                try written.put(aa, base, {});
                // .name already set by rackToSnap (unconditionally).
            },
            .slicer => |*sl| if (sl.user_sample) {
                const base = try std.fmt.allocPrint(aa, "t{d}clip.wav", .{ti});
                const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                try writeSampleWav(aa, io, path, rel, &dir_ready, sr, sl.samples);
                rs.content.slicer.sample_file = rel;
                try written.put(aa, base, {});
                // .name already set by rackToSnap (unconditionally).
            },
            .poly_synth => |*s| {
                // zig fmt: off
                if (s.wt_user) {
                    const base = try std.fmt.allocPrint(aa, "t{d}oscA.wav", .{ti});
                    const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                    try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.wt.frames[0 .. s.wt.frame_count * wavetable_mod.frame_len]);
                    rs.content.poly_synth.wt_file = rel;
                    try written.put(aa, base, {});
                }
                if (s.osc_b_wt_user) {
                    const base = try std.fmt.allocPrint(aa, "t{d}oscB.wav", .{ti});
                    const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                    try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.osc_b_wt.frames[0 .. s.osc_b_wt.frame_count * wavetable_mod.frame_len]);
                    rs.content.poly_synth.osc_b_wt_file = rel;
                    try written.put(aa, base, {});
                }
                if (s.osc_c_wt_user) {
                    const base = try std.fmt.allocPrint(aa, "t{d}oscC.wav", .{ti});
                    const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                    try writeSampleWav(aa, io, path, rel, &dir_ready, sr, s.osc_c_wt.frames[0 .. s.osc_c_wt.frame_count * wavetable_mod.frame_len]);
                    rs.content.poly_synth.osc_c_wt_file = rel;
                    try written.put(aa, base, {});
                }
                // zig fmt: on
            },
            .soundfont => |*sf| if (sf.source_bytes.len > 0) {
                const base = try std.fmt.allocPrint(aa, "t{d}.sf2", .{ti});
                const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
                try writeSampleBytes(aa, io, path, rel, &dir_ready, sf.source_bytes);
                rs.content.soundfont.sf2_file = rel;
                try written.put(aa, base, {});
            },
            else => {},
        }
    }
    for (session.project.audio_sources.items, audio_sources) |source, *snap| {
        const base = try std.fmt.allocPrint(aa, "source-{d}.wav", .{source.id});
        const rel = try std.fmt.allocPrint(aa, "{s}/{s}", .{ sidecar, base });
        try writeAudioSourceWav(aa, io, path, rel, &dir_ready, source);
        snap.file = rel;
        try written.put(aa, base, {});
    }
    try pruneOrphanSamples(aa, io, path, sidecar, &written);
}

fn writeAudioSourceWav(aa: std.mem.Allocator, io: std.Io, wsj_path: []const u8, rel: []const u8, dir_ready: *bool, source: project_mod.AudioSource) !void {
    const full = try joinWsjRel(aa, wsj_path, rel);
    if (!dir_ready.*) {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(full).?);
        dir_ready.* = true;
    }
    const tmp = try std.fmt.allocPrint(aa, "{s}.tmp", .{full});
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try wav.write(&fw.interface, source.sample_rate, source.channel_count, source.samples, .pcm16);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), full, io);
}

/// Delete any `.wav`/`.sf2` in the sample sidecar dir that wasn't written
/// this save - leftovers from a track delete/reorder that changed which
/// index each surviving sample's filename is keyed by. No-op if the sidecar
/// dir doesn't exist (never had user samples, or `exportSamples` never
/// created it because this save has none either).
pub fn pruneOrphanSamples(
    aa: std.mem.Allocator,
    io: std.Io,
    wsj_path: []const u8,
    sidecar: []const u8,
    written: *const std.StringHashMapUnmanaged(void),
) !void {
    const full_dir = try joinWsjRel(aa, wsj_path, sidecar);
    var dir = std.Io.Dir.cwd().openDir(io, full_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var stale: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".wav") and !std.ascii.endsWithIgnoreCase(entry.name, ".sf2")) continue;
        if (written.contains(entry.name)) continue;
        try stale.append(aa, try aa.dupe(u8, entry.name));
    }
    // Delete after the iterator is done - mutating a dir mid-iterate isn't
    // guaranteed safe.
    for (stale.items) |name| dir.deleteFile(io, name) catch {};
}

/// Write one mono clip as a 16-bit WAV at `rel` (a .wsj-relative path),
/// creating the sidecar directory on first use. Same .tmp + rename dance as
/// the project file, so a crash never leaves a truncated sample behind.
pub fn writeSampleWav(
    aa: std.mem.Allocator,
    io: std.Io,
    wsj_path: []const u8,
    rel: []const u8,
    dir_ready: *bool,
    sample_rate: u32,
    samples: []const f32,
) !void {
    const full = try joinWsjRel(aa, wsj_path, rel);
    if (!dir_ready.*) {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(full).?);
        dir_ready.* = true;
    }
    const tmp = try std.fmt.allocPrint(aa, "{s}.tmp", .{full});
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try wav.write(&fw.interface, sample_rate, 1, samples, .pcm16);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), full, io);
}

/// Write raw bytes verbatim at `rel` - the soundfont sidecar's counterpart
/// to `writeSampleWav`. A loaded .sf2 can't be losslessly reconstructed
/// from the parsed, already-resolved `SoundFont` (see dsp/soundfont.zig's
/// doc comment), so the original file bytes are what gets persisted, not a
/// re-encoding. Same .tmp + rename dance as every other sidecar write.
pub fn writeSampleBytes(
    aa: std.mem.Allocator,
    io: std.Io,
    wsj_path: []const u8,
    rel: []const u8,
    dir_ready: *bool,
    bytes: []const u8,
) !void {
    const full = try joinWsjRel(aa, wsj_path, rel);
    if (!dir_ready.*) {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(full).?);
        dir_ready.* = true;
    }
    const tmp = try std.fmt.allocPrint(aa, "{s}.tmp", .{full});
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(bytes);
        try fw.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), full, io);
}

/// Resolve a path stored relative to the .wsj against the .wsj's directory.
/// Always returns an owned allocation.
pub fn joinWsjRel(allocator: std.mem.Allocator, wsj_path: []const u8, rel: []const u8) ![]const u8 {
    if (!isSafeWsjRel(rel)) return error.UnsafeRelativePath;
    if (std.fs.path.dirname(wsj_path)) |d|
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ d, rel });
    return allocator.dupe(u8, rel);
}

pub fn isSafeWsjRel(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\') return false;
    if (rel.len >= 2 and std.ascii.isAlphabetic(rel[0]) and rel[1] == ':') return false;

    var components = std.mem.tokenizeAny(u8, rel, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

test "wsj-relative paths cannot escape the project directory" {
    const allocator = std.testing.allocator;

    const joined = try joinWsjRel(allocator, "songs/demo.wsj", "demo_samples/kick.wav");
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("songs/demo_samples/kick.wav", joined);

    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "../kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "samples/../../kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "samples\\..\\kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "/tmp/kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "\\\\server\\kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", "C:\\kick.wav"));
    try std.testing.expectError(error.UnsafeRelativePath, joinWsjRel(allocator, "songs/demo.wsj", ""));
}

/// Copy a pattern player's notes into freshly allocated NoteSnaps. Notes are
/// read under the lock into a stack buffer, then the lock is released before
/// the allocator runs - avoids leaking the lock on OOM.
/// One note to its snapshot. Shared by the live pattern and the arrangement
/// clip paths, which used to spell the same field list out twice - and so
/// dropped per-note expression from whichever of the two was missed.
fn noteToSnap(n: pattern_mod.Note) NoteSnap {
    return .{
        .pitch = n.pitch,
        .start_beat = n.start_beat,
        .duration_beat = n.duration_beat,
        .velocity = n.velocity,
        .pan = n.art.pan,
        .fine_cents = n.art.fine_cents,
        .release_scale = n.art.release_scale,
    };
}

pub fn notesToSnap(aa: std.mem.Allocator, pp: *PatternPlayer) ![]const NoteSnap {
    var tmp: [pattern_mod.max_notes]NoteSnap = undefined;
    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    const count = pp.note_count;
    for (pp.notes[0..@as(usize, count)], tmp[0..@as(usize, count)]) |n, *ns| {
        ns.* = noteToSnap(n);
    }
    pp.notes_lock.unlock();
    return aa.dupe(NoteSnap, tmp[0..@as(usize, count)]);
}

// zig fmt: off
/// Serialise one arrangement clip. Melodic clips duplicate their notes into
/// freshly allocated NoteSnaps; drum clips copy the bitmask by value.
pub fn clipToSnap(aa: std.mem.Allocator, clip: ws_arrangement.Clip) !ClipSnap {
    const content: persist_types.ClipContentSnap = switch (clip.content) {
        .melodic => |m| blk: {
            const ns = try aa.alloc(NoteSnap, m.notes.len);
            for (m.notes, ns) |n, *o| o.* = noteToSnap(n);
            break :blk .{ .melodic = .{ .notes = ns, .length_beats = m.length_beats } };
        },
        .drum => |d| .{ .drum = .{ .pattern = .{ .notes = try midiToNoteSnaps(aa, &d.midi), .step_count = d.step_count, .steps_per_beat = d.steps_per_beat }, .variant = d.variant } },
        .audio => |audio| blk: {
            const takes = try aa.alloc(persist_types.AudioTakeSnap, audio.takeCount() - 1);
            var n: usize = 0;
            for (audio.alternate_takes) |take| if (take) |value| {
                takes[n] = .{ .source_id = value.source_id, .source_start_frame = value.source_start_frame, .source_length_frames = value.source_length_frames, .length_ticks = value.length_ticks };
                n += 1;
            };
            break :blk .{ .audio = .{
                .source_id = audio.source_id, .source_start_frame = audio.source_start_frame,
                .source_length_frames = audio.source_length_frames, .gain_db = audio.gain_db,
                .fade_in_frames = audio.fade_in_frames, .fade_out_frames = audio.fade_out_frames,
                .stretch_ratio = audio.stretch_ratio, .reverse = audio.reverse,
                .alternate_takes = takes[0..n],
            } };
        },
    };
    var c: ClipSnap = .{ .start_tick = clip.start_tick, .length_ticks = clip.length_ticks, .layer = clip.layer, .content = content };
    c.gain_automation = try automationToSnap(aa, clip.automation.gain);
    c.pan_automation = try automationToSnap(aa, clip.automation.pan);
    if (clip.automation.synth_params.items.len > 0) {
        const sps = try aa.alloc(SynthParamAutomationSnap, clip.automation.synth_params.items.len);
        for (clip.automation.synth_params.items, sps) |sp, *o| {
            o.* = .{ .instance_id = sp.instance_id, .param_id = sp.param_id, .points = try automationToSnap(aa, sp.points) };
        }
        c.synth_param_automation = sps;
    }
    return c;
}
// zig fmt: on

pub fn automationToSnap(aa: std.mem.Allocator, points: []const AutomationPoint) ![]const AutomationPointSnap {
    const out = try aa.alloc(AutomationPointSnap, points.len);
    for (points, out) |p, *o| o.* = .{
        .beat = p.beat,
        .value = p.value,
        .curve = switch (p.curve) {
            .linear => .linear,
            .hold => .hold,
            .ease => .ease,
        },
    };
    return out;
}

/// Field-by-field via `@hasField`/`@field`, same pattern `PolySynth.toPatch`
/// uses - every SynthSnap field that names a matching PolySynth field is
/// copied automatically, so a newly added field can't be forgotten here the
/// way `unison_mode` and the wavetable save fields once were. `mod_matrix`
/// stays manual: PolySynth holds a fixed array, SynthSnap a slice.
/// `wt_file`/`osc_{b,c}_wt_file` have no PolySynth counterpart (`@hasField`
/// skips them) and are filled in by the caller after this returns.
pub fn synthToSnap(s: *const PolySynth) SynthSnap {
    var snap: SynthSnap = .{};
    inline for (@typeInfo(SynthSnap).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "mod_matrix")) continue;
        if (comptime std.mem.eql(u8, f.name, "lfo_custom")) continue;
        if (@hasField(PolySynth, f.name)) {
            @field(snap, f.name) = @field(s, f.name);
        }
    }
    // Slices the live synth's rows - fine, the snapshot is serialized
    // synchronously in save() while the rack is alive.
    snap.mod_matrix = s.mod_matrix[0..];
    snap.lfo_custom = s.lfo_custom[0][0..s.lfo_custom_count[0]];
    snap.lfo2_custom = s.lfo_custom[1][0..s.lfo_custom_count[1]];
    snap.lfo3_custom = s.lfo_custom[2][0..s.lfo_custom_count[2]];
    return snap;
}
