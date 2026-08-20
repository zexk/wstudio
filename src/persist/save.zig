//! Project save path: serialize a live Session into a .wsj container.
//! Split out of persist.zig.

const std = @import("std");
const Session = @import("../session.zig").Session;
const wav = @import("../core/wav.zig");
const types = @import("../core/types.zig");
const theory = @import("../theory.zig");
const project_mod = @import("../project.zig");
const Project = project_mod.Project;
const track_color_count = project_mod.track_color_count;
const ws_arrangement = @import("../arrangement.zig");
const time_grid = @import("../time_grid.zig");
const rack_mod = @import("../rack.zig");
const Rack = rack_mod.Rack;
const Fx = rack_mod.Fx;
const engine_mod = @import("../audio/engine.zig");
const Engine = engine_mod.Engine;
const Transport = @import("../transport.zig").Transport;
const synth_mod = @import("../dsp/synth.zig");
const PolySynth = synth_mod.PolySynth;
const wavetable_mod = @import("../dsp/wavetable.zig");
const pattern_mod = @import("../dsp/pattern.zig");
const PatternPlayer = pattern_mod.PatternPlayer;
const DrumMachine = @import("../dsp/drum_sampler.zig").DrumMachine;
const drum_kit = @import("../dsp/drum_kit.zig");
const pad_mod = @import("../dsp/pad.zig");
const Pad = pad_mod.Pad;
const lfo_mod = @import("../dsp/lfo.zig");
const Sampler = @import("../dsp/sampler.zig").Sampler;
const Slicer = @import("../dsp/slicer.zig").Slicer;
const SoundfontPlayer = @import("../dsp/soundfont_player.zig").SoundfontPlayer;
const soundfont_mod = @import("../dsp/soundfont.zig");
const Compressor = @import("../dsp/compressor.zig").Compressor;
const multiband_comp_mod = @import("../dsp/multiband_comp.zig");
const Reverb = @import("../dsp/reverb.zig").Reverb;
const eq_mod = @import("../dsp/eq.zig");
const Gate = @import("../dsp/gate.zig").Gate;
const Saturator = @import("../dsp/saturator.zig").Saturator;
const Crusher = @import("../dsp/crusher.zig").Crusher;
const Phaser = @import("../dsp/phaser.zig").Phaser;
const dsp = @import("../dsp/device.zig");
const automation_mod = @import("../dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;

const persist_types = @import("types.zig");
const persist_bin = @import("bin.zig");
const file_version = persist_types.file_version;
const AutomationPointSnap = persist_types.AutomationPointSnap;
const SynthParamAutomationSnap = persist_types.SynthParamAutomationSnap;
const MixAutomationSnap = persist_types.MixAutomationSnap;
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
const ClipSnap = persist_types.ClipSnap;
const AudioSourceSnap = persist_types.AudioSourceSnap;
const AudioCacheSnap = persist_types.AudioCacheSnap;
const LaneSnap = persist_types.LaneSnap;
const SectionSnap = persist_types.SectionSnap;
const Snapshot = persist_types.Snapshot;
/// Serialise `session` to `path` as a .wsj container: header, audio cache,
/// then the binary snapshot (see `persist_types.bundle_magic`
/// and `exportSamples`). Writes to `<path>.tmp` and renames over the target
/// so a crash mid-write never corrupts an existing project file - one
/// rename covers the project and every user sample it holds.
/// Safe to call while the audio thread is running.
pub fn save(
    allocator: std.mem.Allocator,
    session: *Session,
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
        for (t.sends, 0..) |maybe_send, slot| {
            const snd = maybe_send orelse continue;
            sends_buf[sends_len] = switch (snd.target) {
                .master => .{ .slot = @intCast(slot), .is_group = false, .group = 0, .level_db = types.gainToDb(snd.level), .pre_fader = snd.pre_fader },
                .group => |g| .{ .slot = @intCast(slot), .is_group = true, .group = g, .level_db = types.gainToDb(snd.level), .pre_fader = snd.pre_fader },
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
    // Only sources some clip still plays. `:consolidate` and `:comp` bake a
    // region into a fresh source and leave the one they read behind, so a
    // project that has been consolidated a few times would otherwise carry
    // every superseded recording forever - and a take is minutes of audio.
    // The in-memory list is untouched, so undo still reaches them this
    // session; reopening drops the undo history along with them.
    var kept: std.ArrayList(*project_mod.AudioSource) = .empty;
    for (session.project.audio_sources.items) |*source| {
        if (audioSourceInUse(session, source.id)) try kept.append(aa, source);
    }
    const audio_sources = try aa.alloc(AudioSourceSnap, kept.items.len);
    for (kept.items, audio_sources) |source, *snap| snap.* = .{
        .id = source.id,
        .file = "",
        .sample_rate = source.sample_rate,
        .channel_count = source.channel_count,
    };
    const lanes = try aa.alloc(LaneSnap, session.arrangement.lanes.items.len);
    for (session.arrangement.lanes.items, lanes) |*lane, *ls| {
        const clips = try aa.alloc(ClipSnap, lane.clips.items.len);
        for (lane.clips.items, clips) |clip, *c| c.* = try clipToSnap(aa, clip);
        ls.* = .{ .clips = clips };
    }
    const sections = try aa.alloc(SectionSnap, session.project.sections.items.len);
    for (session.project.sections.items, sections) |section, *ss| ss.* = .{ .tick = section.tick, .name = section.name };
    const mix_automation = try aa.alloc(MixAutomationSnap, session.mix_automation.items.len);
    for (session.mix_automation.items, mix_automation) |lane, *snap_lane| snap_lane.* = .{ .target = lane.target, .points = try automationToSnap(aa, lane.points) };

    const tmp_path = try std.fmt.allocPrint(aa, "{s}.tmp", .{path});
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);

        // Header, then the audio cache, then the snapshot. The snapshot
        // offset isn't known until the blobs are down, so it goes in as
        // zeroes and gets patched in place once it is.
        var header: [persist_types.bundle_header_len]u8 = @splat(0);
        header[0..persist_types.bundle_magic.len].* = persist_types.bundle_magic;
        try fw.interface.writeAll(&header);

        // Fills in every snapshot's cache key as it streams the blobs out.
        const audio_cache = try exportSamples(aa, session, &fw, racks, kept.items, audio_sources);

        const snap: Snapshot = .{
            .tempo_bpm = session.project.tempo_bpm,
            .tempo_points = session.project.tempo_points.items,
            .scale = session.project.scale,
            .tuning = session.project.tuning,
            .beats_per_bar = session.project.beats_per_bar,
            .meter_denominator = session.project.meter_denominator,
            .meter_points = session.project.meter_points.items,
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
            .mix_automation = mix_automation,
            .audio_cache = audio_cache,
        };

        const snap_offset = fw.logicalPos();
        // Streams straight from the snapshot arena - no second copy of the
        // whole project buffered up before it hits the file.
        try persist_bin.encodeCompressed(aa, &fw.interface, snap);
        try fw.interface.flush();

        var offset_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &offset_bytes, snap_offset, .little);
        try file.writePositionalAll(io, &offset_bytes, persist_types.bundle_magic.len);
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
        .audio => {
            rs.content = .audio;
        },
        .poly_synth => |*s| {
            
            var ss = synthToSnap(s);
            if (rack.pattern_player) |*pp| {
                ss.pattern = try patternToSnap(aa, pp);
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
                    .env_curve = s.pad.env_curve,
                    .fade_in_s = s.pad.fade_in_s, .fade_out_s = s.pad.fade_out_s,
                    .fade_curve = s.pad.fade_curve,
                    .stretch_ratio = s.pad.stretch_ratio, .warp_method = s.pad.warp_method,
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
                smp.pattern = try patternToSnap(aa, pp);
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
            // pad index everywhere below, same "slice so a truncated file
            // still loads, but positionally dense" shape VariantSnap's own doc
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
                        .env_curve = p.env_curve,
                        .fade_in_s = p.fade_in_s, .fade_out_s = p.fade_out_s,
                        .fade_curve = p.fade_curve,
                        .stretch_ratio = p.stretch_ratio, .warp_method = p.warp_method,
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
                    .env_curve = p.env_curve,
                    .fade_in_s = p.fade_in_s, .fade_out_s = p.fade_out_s,
                    .fade_curve = p.fade_curve,
                    .stretch_ratio = p.stretch_ratio, .warp_method = p.warp_method,
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
                cs.pattern = try patternToSnap(aa, pp);
            }
            rs.content = .{ .clap = cs };
        },
        .vst3 => |plugin| {
            var vs = try vst3ToSnap(aa, plugin);
            if (rack.pattern_player) |*pp| {
                vs.pattern = try patternToSnap(aa, pp);
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
                sfs.pattern = try patternToSnap(aa, pp);
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
                .hold_ms = c.hold_ms, .mode = c.mode, .mix = c.mix,
                .sc_mode = c.sc_mode, .sc_hpf_hz = c.sc_hpf_hz, .sc_lpf_hz = c.sc_lpf_hz,
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
                    .freq = b.freq, .enabled = b.enabled, .q = b.q, .gain_db = b.gain_db,
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
                break :blk .{ .content = .{ .eq = .{ .bands = bands, .auto_gain = e.auto_gain, .analog = e.analog } } };
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
// Audio cache - user-loaded audio lives inside the .wsj itself, between the
// header and the snapshot: mono 16-bit FLAC, plus a SoundFont's own bytes
// verbatim. `PadSnap.sample_file` and its siblings hold the cache key.
// ---------------------------------------------------------------------------

/// Streams the audio cache section into the open .wsj and records what landed
/// where, so the snapshot written after it points back into the same file.
const CacheWriter = struct {
    fw: *std.Io.File.Writer,
    entries: std.ArrayListUnmanaged(AudioCacheSnap) = .empty,

    /// Append one clip as 16-bit FLAC, or as the 16-bit WAV it used to be if
    /// this libsndfile can't write FLAC. Either way loading sniffs the bytes,
    /// so the fallback needs nothing on the other side. Returns `name` back,
    /// so a call site can store the key straight into the snapshot field
    /// that owns it.
    fn addAudio(
        self: *CacheWriter,
        aa: std.mem.Allocator,
        name: []const u8,
        sample_rate: u32,
        channel_count: u16,
        samples: []const f32,
    ) ![]const u8 {
        if (try wav.encodeFlacAlloc(aa, samples, sample_rate, channel_count)) |flac| {
            defer aa.free(flac);
            return self.addBytes(aa, name, flac);
        }
        return self.addRawPcm(aa, name, sample_rate, channel_count, samples);
    }

    /// Like `addAudio`, but for an `AudioSource`: FLAC-encodes at most once
    /// per source rather than on every save. `AudioSource.samples` is
    /// write-once (see its own doc comment) and `id`s are never reused, so
    /// a source that has ever been encoded stays valid forever - no dirty
    /// tracking needed. The bytes are allocated with `source_allocator`
    /// (the project's own, not this save's arena) so they outlive this
    /// call for the next save to reuse. Encoding several minutes of audio
    /// is the dominant cost of a save on a recording-heavy project, and
    /// autosave runs this every 30s by default whenever anything is dirty
    /// - without this, editing one note restarts every unrelated track's
    /// encode on the next tick.
    fn addCachedAudio(
        self: *CacheWriter,
        aa: std.mem.Allocator,
        name: []const u8,
        source: *project_mod.AudioSource,
        source_allocator: std.mem.Allocator,
    ) ![]const u8 {
        if (source.cached_flac == null) {
            source.cached_flac = try wav.encodeFlacAlloc(source_allocator, source.samples, source.sample_rate, source.channel_count);
        }
        if (source.cached_flac) |flac| return self.addBytes(aa, name, flac);
        return self.addRawPcm(aa, name, source.sample_rate, source.channel_count, source.samples);
    }

    /// Shared fallback for a build whose libsndfile can't write FLAC: a
    /// plain 16-bit WAV write, cheap enough (no entropy coding) that it
    /// isn't worth caching the way `addCachedAudio` caches FLAC.
    fn addRawPcm(
        self: *CacheWriter,
        aa: std.mem.Allocator,
        name: []const u8,
        sample_rate: u32,
        channel_count: u16,
        samples: []const f32,
    ) ![]const u8 {
        const start = self.fw.logicalPos();
        try wav.write(&self.fw.interface, sample_rate, channel_count, samples, .pcm16);
        try self.entries.append(aa, .{ .name = name, .offset = start, .len = self.fw.logicalPos() - start });
        return name;
    }

    /// Append raw bytes verbatim - the SoundFont counterpart to `addAudio`. A
    /// loaded .sf2 can't be losslessly reconstructed from the parsed,
    /// already-resolved `SoundFont` (see dsp/soundfont.zig's doc comment), so
    /// the original file bytes are what gets persisted, not a re-encoding.
    fn addBytes(self: *CacheWriter, aa: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]const u8 {
        const start = self.fw.logicalPos();
        try self.fw.interface.writeAll(bytes);
        try self.entries.append(aa, .{ .name = name, .offset = start, .len = bytes.len });
        return name;
    }
};

/// Write every user-loaded pad's audio (`Pad.user_sample`) into the audio
/// Whether any arrangement clip still names `id`, as its active audio region
/// or as one of that region's alternate takes. Those two are the only places
/// a source id is ever stored.
fn audioSourceInUse(session: *const Session, id: u32) bool {
    for (session.arrangement.lanes.items) |lane| {
        for (lane.clips.items) |clip| {
            const audio = switch (clip.content) {
                .audio => |region| region,
                else => continue,
            };
            if (audio.source_id == id) return true;
            for (audio.alternate_takes) |slot| {
                if (slot) |take| if (take.source_id == id) return true;
            }
        }
    }
    return false;
}

/// cache section of the open .wsj, point the matching snapshots at it, and
/// return the directory `Snapshot.audio_cache` carries. A session holding no
/// user audio writes no blobs and gets an empty directory.
/// Control thread only: pad buffers are stable while the audio thread runs
/// (they are replaced only by other control-thread calls).
pub fn exportSamples(
    aa: std.mem.Allocator,
    session: *Session,
    fw: *std.Io.File.Writer,
    racks: []RackSnap,
    sources: []const *project_mod.AudioSource,
    audio_sources: []AudioSourceSnap,
) ![]const AudioCacheSnap {
    var cache: CacheWriter = .{ .fw = fw };
    const sr = session.project.sample_rate;
    for (session.racks.items, racks, 0..) |rack, *rs, ti| {
        switch (rack.instrument) {
            .drum_machine => |*dm| for (0..DrumMachine.max_pads) |pi| {
                const s = if (dm.pads[pi]) |*sm| sm else continue; // unloaded pad - nothing to export
                const p = &s.pad;
                if (!p.user_sample) continue;
                const key = try std.fmt.allocPrint(aa, "t{d}p{d}.flac", .{ ti, pi });
                rs.content.drum_machine.pads[pi].sample_file = try cache.addAudio(aa, key, sr, 1, p.samples);
                // .name already set by rackToSnap (unconditionally, for every pad).
            },
            .sampler => |*s| if (s.pad.user_sample) {
                const key = try std.fmt.allocPrint(aa, "t{d}clip.flac", .{ti});
                rs.content.sampler.pad.sample_file = try cache.addAudio(aa, key, sr, 1, s.pad.samples);
                // .name already set by rackToSnap (unconditionally).
            },
            .slicer => |*sl| if (sl.user_sample) {
                const key = try std.fmt.allocPrint(aa, "t{d}clip.flac", .{ti});
                rs.content.slicer.sample_file = try cache.addAudio(aa, key, sr, 1, sl.samples);
                // .name already set by rackToSnap (unconditionally).
            },
            .poly_synth => |*s| {
                // zig fmt: off
                if (s.wt_user) {
                    const key = try std.fmt.allocPrint(aa, "t{d}oscA.flac", .{ti});
                    rs.content.poly_synth.wt_file = try cache.addAudio(aa, key, sr, 1, s.wt.frames[0 .. s.wt.frame_count * wavetable_mod.frame_len]);
                }
                if (s.osc_b_wt_user) {
                    const key = try std.fmt.allocPrint(aa, "t{d}oscB.flac", .{ti});
                    rs.content.poly_synth.osc_b_wt_file = try cache.addAudio(aa, key, sr, 1, s.osc_b_wt.frames[0 .. s.osc_b_wt.frame_count * wavetable_mod.frame_len]);
                }
                if (s.osc_c_wt_user) {
                    const key = try std.fmt.allocPrint(aa, "t{d}oscC.flac", .{ti});
                    rs.content.poly_synth.osc_c_wt_file = try cache.addAudio(aa, key, sr, 1, s.osc_c_wt.frames[0 .. s.osc_c_wt.frame_count * wavetable_mod.frame_len]);
                }
                // zig fmt: on
            },
            .soundfont => |*sf| if (sf.source_bytes.len > 0) {
                const key = try std.fmt.allocPrint(aa, "t{d}.sf2", .{ti});
                rs.content.soundfont.sf2_file = try cache.addBytes(aa, key, sf.source_bytes);
            },
            else => {},
        }
    }
    for (sources, audio_sources) |source, *snap| {
        const key = try std.fmt.allocPrint(aa, "source-{d}.flac", .{source.id});
        snap.file = try cache.addCachedAudio(aa, key, source, session.project.allocator);
    }
    return cache.entries.items;
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
        .channel = n.channel,
        .midi_track = n.midi_track,
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

fn patternToSnap(aa: std.mem.Allocator, pp: *PatternPlayer) !persist_types.PatternSnap {
    return .{
        .length_beats = pp.length_beats,
        .notes = try notesToSnap(aa, pp),
        .midi_events = pp.midi_events[0..pp.midi_event_count],
        .swing = pp.swing.load(.monotonic),
    };
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
                .fade_curve = audio.fade_curve,
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
