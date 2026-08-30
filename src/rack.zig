const std = @import("std");
const dsp = @import("dsp/device.zig");
const types = @import("core/types.zig");
const PolySynth = @import("dsp/synth.zig").PolySynth;
const Sampler = @import("dsp/sampler.zig").Sampler;
const DrumMachine = @import("dsp/drum_sampler.zig").DrumMachine;
const Slicer = @import("dsp/slicer.zig").Slicer;
const SoundfontPlayer = @import("dsp/soundfont_player.zig").SoundfontPlayer;
const Compressor = @import("dsp/compressor.zig").Compressor;
const MultibandComp = @import("dsp/multiband_comp.zig").MultibandComp;
const Ott = @import("dsp/ott.zig").Ott;
const StereoDelay = @import("dsp/delay.zig").StereoDelay;
const Reverb = @import("dsp/reverb.zig").Reverb;
const ParametricEq = @import("dsp/eq.zig").ParametricEq;
const Gate = @import("dsp/gate.zig").Gate;
const Saturator = @import("dsp/saturator.zig").Saturator;
const Amp = @import("dsp/amp.zig").Amp;
const Crusher = @import("dsp/crusher.zig").Crusher;
const Chorus = @import("dsp/chorus.zig").Chorus;
const Phaser = @import("dsp/phaser.zig").Phaser;
const Flanger = @import("dsp/flanger.zig").Flanger;
const Tape = @import("dsp/tape.zig").Tape;
const FreqShifter = @import("dsp/freq_shift.zig").FreqShifter;
const PitchShift = @import("dsp/pitch_shift.zig").PitchShift;
const Filter = @import("dsp/filter.zig").Filter;
const Limiter = @import("dsp/limiter.zig").Limiter;
const Utility = @import("dsp/utility.zig").Utility;
const StereoWidth = @import("dsp/stereo_width.zig").StereoWidth;
const AutoPan = @import("dsp/auto_pan.zig").AutoPan;
const TransientShaper = @import("dsp/transient_shaper.zig").TransientShaper;
const Expander = @import("dsp/expander.zig").Expander;
const Clipper = @import("dsp/clipper.zig").Clipper;
const CrossoverFx = @import("dsp/crossover_fx.zig").CrossoverFx;
pub const ClapPlugin = @import("clap/plugin.zig").ClapPlugin;
pub const Vst3Plugin = @import("vst3/plugin.zig").Vst3Plugin;
const PatternPlayer = @import("dsp/pattern.zig").PatternPlayer;
const Transport = @import("transport.zig").Transport;
const FxModBus = @import("dsp/fx_mod.zig").Bus;
const fx_params = @import("dsp/fx_params.zig");

/// A signal source: generates audio from MIDI events.
/// Add new synthesiser/sampler variants here as the engine grows.
/// `empty` is a track with no instrument inserted yet - it produces no
/// device, so `chain()` omits it and the engine renders the track silent.
pub const Instrument = union(enum) {
    empty,
    /// A track whose sound is its clips, not a generator. The arrangement
    /// renders its audio regions straight into the track scratch (see
    /// `Engine.renderOneTrack`), so like `empty` this produces no device and
    /// `chain()` omits it - the FX rack, sends and automation still apply.
    /// It exists so arming, the picker and the status line can name what a
    /// recording track is instead of a Sampler standing in for one.
    audio,
    poly_synth: PolySynth,
    /// Single-clip chromatic sampler. Owns its clip; deinit frees it.
    sampler: Sampler,
    /// DrumMachine stores its own allocator; deinit() needs no external one.
    /// The DrumMachine's internal `transport` pointer stays valid because the
    /// engine (and therefore its Transport) is heap-allocated.
    drum_machine: DrumMachine,
    /// Step-sequenced sample chopper - one shared clip cut into
    /// independently-triggerable slices. Same `*const Transport` stability
    /// rule as `drum_machine`.
    slicer: Slicer,
    clap: *ClapPlugin,
    vst3: *Vst3Plugin,
    /// SoundFont (.sf2) multi-timbral player - a preset picked from a
    /// loaded font, played chromatically like `poly_synth`/`sampler`.
    soundfont: SoundfontPlayer,
    /// Bundled acoustic sample banks (dsp/builtin_library.zig's SFZ
    /// catalog). Same player as `soundfont` - only the content source and
    /// therefore the browsing UI differ: `acoustic` picks a bundled patch,
    /// `soundfont` loads a user .sf2. Everything downstream (melodic
    /// pattern, params, persistence shape) treats the two identically.
    acoustic: SoundfontPlayer,

    /// Returns a dsp.Device fat-pointer whose `.ptr` is stable as long as
    /// the parent Rack (heap-allocated) is alive, or null for `empty`.
    pub fn device(self: *Instrument) ?dsp.Device {
        return switch (self.*) {
            .empty, .audio => null,
            .clap => |plugin| plugin.device(),
            .vst3 => |plugin| plugin.device(),
            inline else => |*p| p.device(),
        };
    }

    pub fn deinit(self: *Instrument) void {
        switch (self.*) {
            .empty, .audio => {},
            .clap => |plugin| plugin.deinit(),
            .vst3 => |plugin| plugin.deinit(),
            inline else => |*p| p.deinit(),
        }
    }

    pub fn automatableParams(self: *const Instrument) []const dsp.AutomatableParam {
        return switch (self.*) {
            .poly_synth => &PolySynth.automatable_params,
            .sampler => &Sampler.automatable_params,
            .soundfont, .acoustic => &SoundfontPlayer.automatable_params,
            .clap => |plugin| plugin.automationParams(),
            .vst3 => |plugin| plugin.automationParams(),
            .drum_machine, .slicer, .empty, .audio => &.{},
        };
    }
};

/// The instrument variants, as a plain enum - used by the instrument picker
/// and `Session.setInstrument` to name a kind without a payload.
pub const InstrumentKind = std.meta.Tag(Instrument);

/// Per-frame step of the bypass crossfade (see `FxUnit.wet`): a ~5ms fade at
/// 48kHz, the same length LSP's Bypass class defaults to. Fixed rather than
/// derived from the session rate because an FxUnit is rate-agnostic and the
/// exact fade length does not matter - only that it is not instant.
const bypass_fade_step: f32 = 1.0 / 240.0;

/// Frames of dry signal the crossfade copies at a time. Only reached while a
/// fade is in flight.
const fade_chunk_frames: usize = 128;

/// One effect processor a chain slot can hold. Add new unit variants here as
/// the engine grows - the TUI's picker and persistence key off `FxKind`.
/// chorus/pitch_shift/delay/reverb own heap buffers (mod/delay/grain lines);
/// deinit frees them.
pub const FxPayload = union(enum) {
    gate: Gate,
    comp: Compressor,
    mb_comp: MultibandComp,
    ott: Ott,
    limiter: Limiter,
    expander: Expander,
    clipper: Clipper,
    crossover: CrossoverFx,
    transient_shaper: TransientShaper,
    eq: ParametricEq,
    filter: Filter,
    utility: Utility,
    stereo_width: StereoWidth,
    auto_pan: AutoPan,
    sat: Saturator,
    amp: Amp,
    crush: Crusher,
    chorus: Chorus,
    phaser: Phaser,
    flanger: Flanger,
    tape: Tape,
    freq_shift: FreqShifter,
    pitch_shift: PitchShift,
    delay: StereoDelay,
    reverb: Reverb,
    clap: *ClapPlugin,
    vst3: *Vst3Plugin,

    /// Returns a dsp.Device fat-pointer whose `.ptr` is stable as long as
    /// the parent FxUnit (heap-allocated by Fx.insert) is alive.
    pub fn device(self: *FxPayload) dsp.Device {
        return switch (self.*) {
            .clap => |plugin| plugin.device(),
            .vst3 => |plugin| plugin.device(),
            inline else => |*p| p.device(),
        };
    }

    pub fn deinit(self: *FxPayload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .clap => |plugin| plugin.deinit(),
            .vst3 => |plugin| plugin.deinit(),
            .chorus => |*c| c.deinit(allocator),
            .flanger => |*f| f.deinit(allocator),
            .pitch_shift => |*p| p.deinit(allocator),
            .delay => |*d| d.deinit(allocator),
            .reverb => |*r| r.deinit(allocator),
            .limiter => |*l| l.deinit(allocator),
            .utility => |*u| u.deinit(allocator),
            else => {},
        }
    }

    /// Deep-copies one payload: chorus/pitch_shift/delay/reverb get fresh lines (only
    /// their params carry over - matches what project save/load already
    /// does); the rest are plain value state and copy directly.
    pub fn dupe(self: *const FxPayload, allocator: std.mem.Allocator, sr: u32) !FxPayload {
        switch (self.*) {
            .chorus => |c| {
                var nc = try Chorus.init(allocator, sr);
                nc.rate_hz = c.rate_hz;
                nc.depth_ms = c.depth_ms;
                nc.mix = c.mix;
                return .{ .chorus = nc };
            },
            .flanger => |f| {
                var nf = try Flanger.init(allocator, sr);
                nf.rate_hz = f.rate_hz;
                nf.depth = f.depth;
                nf.feedback = f.feedback;
                nf.mix = f.mix;
                return .{ .flanger = nf };
            },
            .pitch_shift => |p| {
                var np = try PitchShift.init(allocator, sr);
                np.semitones = p.semitones;
                np.cents = p.cents;
                np.formant = p.formant;
                np.mix = p.mix;
                return .{ .pitch_shift = np };
            },
            .delay => |d| {
                var nd = try StereoDelay.init(allocator, sr, 2.0);
                nd.time_s = d.time_s;
                nd.feedback = d.feedback;
                nd.mix = d.mix;
                nd.damp = d.damp;
                return .{ .delay = nd };
            },
            .reverb => |r| {
                var nr = try Reverb.init(allocator, sr);
                nr.mix = r.mix;
                nr.room = r.room;
                nr.damp = r.damp;
                nr.predelay_ms = r.predelay_ms;
                nr.width = r.width;
                nr.low_cut_hz = r.low_cut_hz;
                nr.impulse = r.impulse;
                return .{ .reverb = nr };
            },
            .limiter => |l| {
                var nl = try Limiter.init(allocator, sr);
                nl.ceiling = l.ceiling;
                nl.release_ms = l.release_ms;
                nl.lookahead_ms = l.lookahead_ms;
                return .{ .limiter = nl };
            },
            .utility => |u| {
                var nu = try Utility.init(allocator, sr);
                nu.gain_db = u.gain_db;
                nu.invert = u.invert;
                nu.mono = u.mono;
                nu.channel = u.channel;
                nu.swap = u.swap;
                nu.delay_frames = u.delay_frames;
                nu.noise_on = u.noise_on;
                nu.noise_color = u.noise_color;
                nu.noise_db = u.noise_db;
                nu.autogain_on = u.autogain_on;
                nu.autogain_target_lufs = u.autogain_target_lufs;
                return .{ .utility = nu };
            },
            .clap => |plugin| {
                const copy = try ClapPlugin.load(allocator, plugin.pluginPath(), plugin.id(), sr);
                errdefer copy.deinit();
                if (plugin.transport) |transport| copy.attachTransport(transport);
                if (try plugin.saveState(allocator)) |state| {
                    defer allocator.free(state);
                    _ = try copy.loadState(state);
                }
                return .{ .clap = copy };
            },
            .vst3 => |plugin| {
                const copy = try Vst3Plugin.load(allocator, plugin.pluginPath(), plugin.classId(), sr, false);
                errdefer copy.deinit();
                if (plugin.transport) |transport| copy.attachTransport(transport);
                const component = try plugin.saveComponentState(allocator);
                defer allocator.free(component);
                const controller = try plugin.saveControllerState(allocator);
                defer if (controller) |c| allocator.free(c);
                try copy.loadState(component, controller orelse &.{});
                return .{ .vst3 = copy };
            },
            else => return self.*,
        }
    }
};

/// The effect variants as a plain enum - names a kind without a payload,
/// same role InstrumentKind plays for instruments.
pub const FxKind = std.meta.Tag(FxPayload);

/// One inserted chain slot. Heap-allocated by `Fx.insert` so the device
/// pointer the engine holds stays stable across chain edits (insert, remove,
/// reorder only shuffle the pointer list, never move the unit itself).
pub const FxUnit = struct {
    payload: FxPayload,
    /// Stable across reorder/save/load. Matrix routes target this, not slot.
    instance_id: u32,
    /// Bypassed units stay in `chain()` and fade out instead of vanishing
    /// from it - see `wet`.
    bypassed: bool = false,
    /// Crossfade position between the unit's output (1) and its untouched
    /// input (0). Flipping `bypassed` used to drop the unit out of the
    /// device list between blocks, which steps the signal at the splice:
    /// audible as a click on anything with a tail, a filter, or any gain
    /// at all. This ramps instead, at `bypass_fade_step` per frame.
    ///
    /// Once the fade has settled at 0 the unit stops processing entirely,
    /// so a bypassed chain still costs nothing and still passes audio
    /// through bit for bit. The payload's state does go stale while it sits
    /// there (a reverb tail decays to nothing, a filter forgets); fading
    /// back in from dry is what keeps that from clicking on the way back.
    wet: f32 = 1.0,
    mod_bus: ?*const FxModBus = null,

    pub fn kind(self: *const FxUnit) FxKind {
        return std.meta.activeTag(self.payload);
    }

    /// Bypass with no fade, for the paths where there is nothing to fade
    /// from: loading a project, duplicating a chain, building a fixture.
    /// The live toggle sets `bypassed` on its own and lets `processBlock`
    /// ramp `wet` across.
    pub fn setBypassed(self: *FxUnit, on: bool) void {
        self.bypassed = on;
        self.wet = if (on) 0.0 else 1.0;
    }

    fn mod(self: *const FxUnit, param_id: u16) f32 {
        return if (self.mod_bus) |bus| bus.amount(self.instance_id, param_id) else 0.0;
    }

    /// Runs the payload, crossfading against the dry input while `wet` is
    /// travelling between bypassed and active. A settled bypass returns
    /// without touching the buffer or the payload at all.
    fn processBlock(self: *FxUnit, buf: []types.Sample) void {
        const target: f32 = if (self.bypassed) 0.0 else 1.0;
        if (!std.math.isFinite(self.wet)) self.wet = target;
        if (self.wet == target) {
            if (target == 0.0) return;
            self.processPayload(buf);
            return;
        }
        // Fading: keep a dry copy to blend against. Chunked so the copy is
        // a small stack buffer rather than a per-unit allocation the size
        // of the largest block the engine can hand out - the fade only
        // lasts a few milliseconds, so the chunking never costs anything
        // in the steady state.
        var chunk: [fade_chunk_frames * 2]types.Sample = undefined;
        var off: usize = 0;
        while (off < buf.len) {
            const len = @min(buf.len - off, chunk.len);
            const slice = buf[off..][0..len];
            @memcpy(chunk[0..len], slice);
            self.processPayload(slice);
            var f: usize = 0;
            while (f + 1 < len) : (f += 2) {
                self.wet = if (target > self.wet)
                    @min(target, self.wet + bypass_fade_step)
                else
                    @max(target, self.wet - bypass_fade_step);
                slice[f] = chunk[f] * (1.0 - self.wet) + slice[f] * self.wet;
                slice[f + 1] = chunk[f + 1] * (1.0 - self.wet) + slice[f + 1] * self.wet;
            }
            off += len;
        }
    }

    fn processPayload(self: *FxUnit, buf: []types.Sample) void {
        const max_params = 256;
        var modded_idx: [max_params]u16 = undefined;
        var modded_base: [max_params]f32 = undefined;
        var modded_count: usize = 0;
        const count = fx_params.paramCount(self.kind());
        std.debug.assert(count <= max_params);
        for (0..count) |idx| {
            if (!fx_params.isAutomatable(self.kind(), idx)) continue;
            const amount = self.mod(@intCast(idx));
            if (amount == 0.0) continue;
            const range = fx_params.paramRange(&self.payload, idx);
            modded_idx[modded_count] = @intCast(idx);
            modded_base[modded_count] = fx_params.getParam(&self.payload, idx);
            fx_params.setParamAbsolute(
                &self.payload,
                idx,
                modded_base[modded_count] + amount * (range[1] - range[0]),
            );
            modded_count += 1;
        }

        switch (self.payload) {
            .clap => |v| v.device().process(buf),
            .vst3 => |v| v.device().process(buf),
            inline else => |*v| v.processBlock(buf),
        }

        // Twice, because a setter can clamp against a sibling field that is
        // still holding *its* modulated value on the first pass - the same
        // stale-sibling trap `MultibandComp.setXovers` exists to dodge on
        // load. Only one of a mutually-clamped pair can be blocked at a
        // time (each setter's other bound is a fixed constant), so the
        // second pass always lands both. A no-op for every param whose
        // setter clamps against nothing.
        for (0..2) |_| {
            for (modded_idx[0..modded_count], modded_base[0..modded_count]) |idx, base|
                fx_params.setParamAbsolute(&self.payload, idx, base);
        }
    }

    fn reset(self: *FxUnit) void {
        self.payload.device().reset();
    }

    fn latencyFrames(self: *FxUnit) u32 {
        // A settled bypass is a wire: it neither delays nor processes, so
        // it must not claim the payload's latency and have the engine
        // compensate for a unit that is not running.
        if (self.bypassed and self.wet == 0.0) return 0;
        return self.payload.device().latencyFrames();
    }

    /// A unit is a transparent wrapper around its payload, so it must pass
    /// events through the same way it passes `process`/`reset`/latency
    /// through. Leaving `.event` off the vtable made `Device.sendEvent` a
    /// silent no-op for every FX unit on every track, group, and master
    /// chain - which killed sidechain compression outright, since
    /// `Engine.processChainWithSidechain` hands a compressor its detector
    /// buffer through exactly this path and the comp then fell back to
    /// self-detection (audible as flat attenuation instead of pumping).
    ///
    /// An `automation_param` addressed to THIS unit's `instance_id` (see the
    /// event's own doc comment) is handled here directly instead of being
    /// forwarded - no individual FX kind implements `handleEvent` for it,
    /// unlike instruments, since a plain effect has no note/CC concept to
    /// hang a dispatch method off of. `isAutomatable` guards against a
    /// stale/out-of-range index (e.g. a comp sidechain row, never a legal
    /// automation target) reaching a live field write.
    fn handleEvent(self: *FxUnit, ev: dsp.Event) void {
        switch (ev) {
            .automation_param => |p| {
                if (p.instance_id == 0 or p.instance_id != self.instance_id) return;
                const idx: usize = @intCast(p.id);
                if (!fx_params.isPayloadAutomatable(&self.payload, idx)) return;
                switch (self.payload) {
                    .clap => |plugin| {
                        const info = plugin.parameterInfo(@intCast(idx)) orelse return;
                        plugin.setParameterAt(info.id, info.cookie, p.value, p.sample_offset);
                    },
                    .vst3 => |plugin| {
                        const info = plugin.parameterInfo(idx) orelse return;
                        plugin.setParameterAt(info.id, p.value, p.sample_offset);
                    },
                    else => fx_params.setParamAbsolute(&self.payload, idx, p.value),
                }
            },
            else => self.payload.device().sendEvent(ev),
        }
    }

    const vtable: dsp.Device.VTable = .{
        .sample_offset_events = struct {
            fn call(ptr: *anyopaque) bool {
                const self: *FxUnit = @ptrCast(@alignCast(ptr));
                return self.payload.device().acceptsSampleOffsetEvents();
            }
        }.call,
        .event = struct {
            fn call(ptr: *anyopaque, ev: dsp.Event) void {
                const self: *FxUnit = @ptrCast(@alignCast(ptr));
                self.handleEvent(ev);
            }
        }.call,
        .process = struct {
            fn call(ptr: *anyopaque, buf: []types.Sample) void {
                const self: *FxUnit = @ptrCast(@alignCast(ptr));
                self.processBlock(buf);
            }
        }.call,
        .reset = struct {
            fn call(ptr: *anyopaque) void {
                const self: *FxUnit = @ptrCast(@alignCast(ptr));
                self.reset();
            }
        }.call,
        .latency_frames = struct {
            fn call(ptr: *anyopaque) u32 {
                const self: *FxUnit = @ptrCast(@alignCast(ptr));
                return self.latencyFrames();
            }
        }.call,
    };

    pub fn device(self: *FxUnit) dsp.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// User-built effect chain: an ordered list of inserted units, applied in
/// series after the instrument. Starts empty; the user inserts units where
/// they want them (duplicates allowed), reorders, bypasses, and removes.
/// Shared by every track's Rack and the engine's master bus
/// (Session.master_fx) - the same units plug into either one the same way.
pub const Fx = struct {
    units: std.ArrayListUnmanaged(*FxUnit) = .empty,
    next_instance_id: u32 = 1,

    /// Chain length cap. Every unit costs a stack slot in the fixed-size
    /// `[max_units]Device` buffers the audio thread builds each block, so it
    /// stays a compile-time bound rather than growing freely. It has to be at
    /// least the internal kind count, since `internal_fx_kinds` builds a chain
    /// holding one of each; 32 leaves room for the next few units on top of
    /// that, and is well past any musically useful insert count.
    pub const max_units = 32;

    fn allocInstanceId(self: *Fx) u32 {
        while (true) {
            const id = self.next_instance_id;
            self.next_instance_id +%= 1;
            if (self.next_instance_id == 0) self.next_instance_id = 1;
            if (id == 0) continue;
            var used = false;
            for (self.units.items) |u| {
                if (u.instance_id == id) {
                    used = true;
                    break;
                }
            }
            if (!used) return id;
        }
    }

    pub fn findInstance(self: *const Fx, id: u32) ?*FxUnit {
        for (self.units.items) |u| if (u.instance_id == id) return u;
        return null;
    }

    pub fn attachTransport(self: *Fx, transport: *const Transport) void {
        for (self.units.items) |unit| switch (unit.payload) {
            .auto_pan => |*effect| effect.attachTransport(transport),
            else => {},
        };
    }

    /// A fresh payload of `kind` with its defaults. Only chorus/delay/reverb
    /// allocate (their mod/delay lines).
    pub fn initPayload(allocator: std.mem.Allocator, kind: FxKind, sr: u32) !FxPayload {
        // zig fmt: off
        return switch (kind) {
            .gate    => .{ .gate = Gate.init(sr) },
            .comp    => .{ .comp = Compressor.init(sr) },
            .mb_comp => .{ .mb_comp = MultibandComp.init(sr) },
            .ott     => blk: {
                var ott = Ott.init(sr);
                ott.setDepth(0.1);
                break :blk .{ .ott = ott };
            },
            .eq      => .{ .eq = ParametricEq.init(sr) },
            .filter  => .{ .filter = Filter.init(sr) },
            .utility => .{ .utility = try Utility.init(allocator, sr) },
            .stereo_width => .{ .stereo_width = .{} },
            .auto_pan => .{ .auto_pan = AutoPan.init(sr) },
            .transient_shaper => .{ .transient_shaper = TransientShaper.init(sr) },
            .limiter => .{ .limiter = try Limiter.init(allocator, sr) },
            .expander => .{ .expander = Expander.init(sr) },
            .clipper => .{ .clipper = Clipper.init(sr) },
            .crossover => .{ .crossover = CrossoverFx.init(sr) },
            .sat     => .{ .sat = .{} },
            .amp     => .{ .amp = Amp.init(sr) },
            .crush   => .{ .crush = .{} },
            .chorus  => .{ .chorus = try Chorus.init(allocator, sr) },
            .phaser  => .{ .phaser = Phaser.init(sr) },
            .flanger => .{ .flanger = try Flanger.init(allocator, sr) },
            .tape    => .{ .tape = Tape.init(sr) },
            .freq_shift => .{ .freq_shift = FreqShifter.init(sr) },
            .pitch_shift => .{ .pitch_shift = try PitchShift.init(allocator, sr) },
            .delay   => blk: {
                var delay = try StereoDelay.init(allocator, sr, 2.0);
                delay.time_s = 0.25;
                break :blk .{ .delay = delay };
            },
            .reverb  => .{ .reverb = try Reverb.init(allocator, sr) },
            .clap    => return error.ClapPluginRequiresPath,
            .vst3    => return error.Vst3PluginRequiresPath,
            // zig fmt: on
        };
    }

    /// Insert a fresh `kind` unit (defaults) at `pos`, clamped to the chain
    /// end. Fails without touching the chain on `error.ChainFull` / OOM.
    pub fn insert(self: *Fx, allocator: std.mem.Allocator, pos: usize, kind: FxKind, sr: u32) !*FxUnit {
        if (self.units.items.len >= max_units) return error.ChainFull;
        const unit = try allocator.create(FxUnit);
        errdefer allocator.destroy(unit);
        unit.* = .{ .payload = try initPayload(allocator, kind, sr), .instance_id = self.allocInstanceId() };
        errdefer unit.payload.deinit(allocator);
        try self.units.insert(allocator, @min(pos, self.units.items.len), unit);
        return unit;
    }

    /// Insert a settings-only copy with a fresh instance id.
    pub fn insertDupe(self: *Fx, allocator: std.mem.Allocator, pos: usize, source: *const FxUnit, sr: u32) !*FxUnit {
        if (self.units.items.len >= max_units) return error.ChainFull;
        const unit = try allocator.create(FxUnit);
        errdefer allocator.destroy(unit);
        unit.* = .{ .payload = try source.payload.dupe(allocator, sr), .instance_id = self.allocInstanceId() };
        errdefer unit.payload.deinit(allocator);
        unit.setBypassed(source.bypassed);
        try self.units.insert(allocator, @min(pos, self.units.items.len), unit);
        return unit;
    }

    pub fn insertClap(
        self: *Fx,
        allocator: std.mem.Allocator,
        pos: usize,
        path: []const u8,
        plugin_id: []const u8,
        sr: u32,
    ) !*FxUnit {
        if (self.units.items.len >= max_units) return error.ChainFull;
        const plugin = try ClapPlugin.load(allocator, path, plugin_id, sr);
        errdefer plugin.deinit();
        // An effect needs somewhere to receive the chain's audio; how many
        // ports it has beyond that is its own business (mixers and
        // sidechain effects declare several, and demanding exactly one
        // locked all of them out).
        if (plugin.audio_inputs_count == 0) return error.ClapPluginIsNotEffect;
        const unit = try allocator.create(FxUnit);
        errdefer allocator.destroy(unit);
        unit.* = .{ .payload = .{ .clap = plugin }, .instance_id = self.allocInstanceId() };
        try self.units.insert(allocator, @min(pos, self.units.items.len), unit);
        return unit;
    }

    pub fn insertVst3(self: *Fx, allocator: std.mem.Allocator, pos: usize, path: []const u8, plugin_id: []const u8, sr: u32) !*FxUnit {
        if (self.units.items.len >= max_units) return error.ChainFull;
        const plugin = try Vst3Plugin.load(allocator, path, plugin_id, sr, false);
        errdefer plugin.deinit();
        const unit = try allocator.create(FxUnit);
        errdefer allocator.destroy(unit);
        unit.* = .{ .payload = .{ .vst3 = plugin }, .instance_id = self.allocInstanceId() };
        try self.units.insert(allocator, @min(pos, self.units.items.len), unit);
        return unit;
    }

    /// Remove and free the unit at `idx`. Push the new chain to the engine
    /// (setTrackChain/syncMasterChain) in the same control-thread breath.
    pub fn remove(self: *Fx, allocator: std.mem.Allocator, idx: usize) void {
        if (idx >= self.units.items.len) return;
        const unit = self.units.orderedRemove(idx);
        unit.payload.deinit(allocator);
        allocator.destroy(unit);
    }

    /// Swap two slots' positions. Unit memory never moves, so the engine's
    /// device pointers stay valid; re-sync the chain to apply the new order.
    pub fn swap(self: *Fx, a: usize, b: usize) void {
        if (a == b or a >= self.units.items.len or b >= self.units.items.len) return;
        std.mem.swap(*FxUnit, &self.units.items[a], &self.units.items[b]);
    }

    /// First unit of `kind` in chain order, or null.
    pub fn find(self: *const Fx, kind: FxKind) ?*FxUnit {
        const i = self.findIdx(kind) orelse return null;
        return self.units.items[i];
    }

    /// Index of the first unit of `kind`, or null.
    pub fn findIdx(self: *const Fx, kind: FxKind) ?usize {
        for (self.units.items, 0..) |u, i| if (u.kind() == kind) return i;
        return null;
    }

    pub fn deinit(self: *Fx, allocator: std.mem.Allocator) void {
        for (self.units.items) |u| {
            u.payload.deinit(allocator);
            allocator.destroy(u);
        }
        self.units.deinit(allocator);
    }

    /// Fills `buf` with every unit in chain order and returns the used
    /// slice. Bypassed units stay in the list: bypass is a crossfade the
    /// unit performs on itself (`FxUnit.wet`), and a unit dropped from the
    /// device list has no way to finish one. A settled bypass costs a
    /// predicted branch and returns the buffer untouched.
    pub fn chain(self: *Fx, buf: *[max_units]dsp.Device) []const dsp.Device {
        var len: usize = 0;
        for (self.units.items) |u| {
            buf[len] = u.device();
            len += 1;
        }
        return buf[0..len];
    }

    /// Sidechain-detector source per chain slot, parallel to `chain()`'s own
    /// device ordering (same units, same order, so the two always line up).
    /// Only `.comp` payloads with `sidechain_source` set produce a non-null
    /// entry; every other unit kind has no such concept. Feeds `Engine.
    /// set*SidechainSources` - see `Session`'s chain-sync call sites, which
    /// call this alongside `chain()` any time the chain (re)syncs.
    pub fn sidechainSources(self: *const Fx, buf: *[max_units]?Compressor.SidechainSource) []const ?Compressor.SidechainSource {
        var len: usize = 0;
        for (self.units.items) |u| {
            buf[len] = switch (u.payload) {
                .comp => |c| c.sidechain_source,
                else => null,
            };
            len += 1;
        }
        return buf[0..len];
    }

    /// Deep-copies the whole chain in order: fresh heap allocations for
    /// every owned buffer (delay/reverb lines, chorus mod line) so the copy
    /// shares no memory with the original and can be torn down
    /// independently. FX buffer *contents* (reverb tail, delay line) aren't
    /// preserved, only params - same as project save/load and `Rack.dupe`,
    /// which calls this for its own fx field.
    pub fn dupe(self: *const Fx, allocator: std.mem.Allocator, sr: u32) !Fx {
        var out: Fx = .{};
        errdefer out.deinit(allocator);
        for (self.units.items) |u| {
            const nu = try allocator.create(FxUnit);
            errdefer allocator.destroy(nu);
            nu.* = .{
                .payload = try u.payload.dupe(allocator, sr),
                .instance_id = u.instance_id,
                .bypassed = u.bypassed,
                .wet = u.wet,
            };
            errdefer nu.payload.deinit(allocator);
            try out.units.append(allocator, nu);
        }
        out.next_instance_id = self.next_instance_id;
        return out;
    }
};

pub const Rack = struct {
    instrument: Instrument,
    fx: Fx = .{},
    label: []const u8,
    /// Serialized pre-freeze project state. Empty for ordinary and flattened
    /// racks; frozen audio keeps bytes, never live instrument/plugin objects.
    frozen_state: []u8 = &.{},
    frozen_track: u16 = 0,
    /// Rendered from pattern mode, so its audio region repeats while song
    /// mode is off. Applies to frozen and permanently flattened tracks.
    rendered_loop: bool = false,
    /// True when `label` was heap-allocated (e.g. loaded from a project file)
    /// and must be freed in deinit. False for string-literal labels.
    owned_label: bool = false,
    /// Piano-roll sequencer. Set after the Rack lands on the heap so the
    /// self-referential synth pointer is stable.
    pattern_player: ?PatternPlayer = null,

    pub fn deinit(self: *Rack, allocator: std.mem.Allocator) void {
        if (self.owned_label) allocator.free(self.label);
        if (self.frozen_state.len > 0) allocator.free(self.frozen_state);
        self.instrument.deinit();
        self.fx.deinit(allocator);
    }

    /// Deep-copies this rack for track duplication: fresh heap allocations
    /// for every owned buffer (pad audio, delay/reverb lines) so the two
    /// racks share no memory and can be torn down independently. FX buffer
    /// *contents* (reverb tail, delay line) aren't preserved - only their
    /// parameters - matching what project save/load already does.
    pub fn dupe(self: *const Rack, allocator: std.mem.Allocator, sr: u32, transport: *const Transport) !*Rack {
        const rack = try allocator.create(Rack);
        errdefer allocator.destroy(rack);
        const label = try allocator.dupe(u8, self.label);
        var label_owned = true;
        errdefer if (label_owned) allocator.free(label);
        const frozen_state = try allocator.dupe(u8, self.frozen_state);
        var frozen_state_owned = true;
        errdefer if (frozen_state_owned) allocator.free(frozen_state);
        rack.* = .{
            .instrument = .empty,
            .label = label,
            .owned_label = true,
            .frozen_state = frozen_state,
            .frozen_track = self.frozen_track,
            .rendered_loop = self.rendered_loop,
        };
        label_owned = false;
        frozen_state_owned = false;
        errdefer rack.deinit(allocator);

        switch (self.instrument) {
            // `audio` carries no payload to copy - the clips the duplicate
            // plays live on the arrangement lane, not in the rack.
            .empty, .audio => {
                rack.instrument = self.instrument;
            },
            .poly_synth => |*s| {
                const synth = try s.dupe();
                rack.instrument = .{ .poly_synth = synth };
                rack.instrument.poly_synth.attachTransport(transport);
            },
            .sampler => |*s| {
                const sampler = try s.dupe();
                rack.instrument = .{ .sampler = sampler };
            },
            .drum_machine => |*dm| {
                const drum_machine = try dm.dupe();
                rack.instrument = .{ .drum_machine = drum_machine };
            },
            .slicer => |*sl| {
                const slicer = try sl.dupe();
                rack.instrument = .{ .slicer = slicer };
            },
            .clap => |plugin| {
                const copy = try ClapPlugin.load(allocator, plugin.pluginPath(), plugin.id(), sr);
                var copy_owned = true;
                errdefer if (copy_owned) copy.deinit();
                copy.attachTransport(transport);
                if (try plugin.saveState(allocator)) |state| {
                    defer allocator.free(state);
                    _ = try copy.loadState(state);
                }
                rack.instrument = .{ .clap = copy };
                copy_owned = false;
            },
            .vst3 => |plugin| {
                const copy = try Vst3Plugin.load(allocator, plugin.pluginPath(), plugin.classId(), sr, true);
                var copy_owned = true;
                errdefer if (copy_owned) copy.deinit();
                copy.attachTransport(transport);
                const component = try plugin.saveComponentState(allocator);
                defer allocator.free(component);
                const controller = try plugin.saveControllerState(allocator);
                defer if (controller) |c| allocator.free(c);
                try copy.loadState(component, controller orelse &.{});
                rack.instrument = .{ .vst3 = copy };
                copy_owned = false;
            },
            inline .soundfont, .acoustic => |*sf, tag| {
                const copy = try sf.dupe();
                rack.instrument = @unionInit(Instrument, @tagName(tag), copy);
            },
        }
        // Set AFTER the instrument lands in the heap rack - the player holds
        // a pointer into it (same rule as Session.setInstrument).
        if (self.pattern_player) |*pp| {
            var new_pp = PatternPlayer.init(rack.instrument.device().?, transport);
            new_pp.note_count = pp.note_count;
            new_pp.notes = pp.notes;
            new_pp.length_beats = pp.length_beats;
            new_pp.swing.store(pp.swing.load(.monotonic), .monotonic);
            rack.pattern_player = new_pp;
        }

        rack.fx = try self.fx.dupe(allocator, sr);

        return rack;
    }

    /// Capacity every `chain()` scratch buffer needs: pattern player +
    /// instrument + a full FX chain.
    pub const chain_cap = Fx.max_units + 2;

    pub const ModTarget = struct {
        instance_id: u32 = 0,
        param_id: u16,

        pub fn eql(a: ModTarget, b: ModTarget) bool {
            return a.instance_id == b.instance_id and a.param_id == b.param_id;
        }
    };

    /// Runtime modulation destinations for this rack. Instrument fields lead,
    /// followed by each existing native FX unit in signal-flow order.
    pub fn modTargetCount(self: *const Rack) usize {
        var count: usize = PolySynth.mod_dest_ids.len;
        for (self.fx.units.items) |unit| {
            for (0..fx_params.paramCount(unit.kind())) |idx| {
                if (fx_params.isAutomatable(unit.kind(), idx)) count += 1;
            }
        }
        return count;
    }

    pub fn modTargetAt(self: *const Rack, wanted: usize) ?ModTarget {
        if (wanted < PolySynth.mod_dest_ids.len)
            return .{ .param_id = PolySynth.mod_dest_ids[wanted] };
        var at = wanted - PolySynth.mod_dest_ids.len;
        for (self.fx.units.items) |unit| {
            for (0..fx_params.paramCount(unit.kind())) |idx| {
                if (!fx_params.isAutomatable(unit.kind(), idx)) continue;
                if (at == 0) return .{ .instance_id = unit.instance_id, .param_id = @intCast(idx) };
                at -= 1;
            }
        }
        return null;
    }

    pub fn modTargetIndex(self: *const Rack, target: ModTarget) ?usize {
        for (0..self.modTargetCount()) |idx|
            if (ModTarget.eql(self.modTargetAt(idx).?, target)) return idx;
        return null;
    }

    pub fn writeModTargetLabel(self: *const Rack, target: ModTarget, w: *std.Io.Writer) !void {
        if (target.instance_id == 0) return w.writeAll(PolySynth.modDestLabel(target.param_id));
        const unit = self.fx.findInstance(target.instance_id) orelse return w.writeAll("missing FX");
        if (!fx_params.isAutomatable(unit.kind(), target.param_id)) return w.writeAll("missing FX param");
        try w.print("{s} {d} / {s}", .{ @tagName(unit.kind()), target.instance_id, fx_params.paramName(&unit.payload, target.param_id) });
    }

    /// Fills `buf` with [pattern_player?, instrument, ...fx] in signal-flow
    /// order and returns the used slice. Caller must keep `buf` alive for as
    /// long as the slice is passed to the engine.
    pub fn chain(self: *Rack, buf: *[chain_cap]dsp.Device) []const dsp.Device {
        // zig fmt: off
        var len: usize = 0;
        if (self.pattern_player) |*pp| { buf[len] = pp.device(); len += 1; }
        if (self.instrument.device()) |dev| { buf[len] = dev; len += 1; }
        const mod_bus: ?*const FxModBus = switch (self.instrument) {
            .poly_synth => |*s| &s.fx_mod_bus,
            else => null,
        };
        for (self.fx.units.items) |unit| unit.mod_bus = mod_bus;
        var fx_buf: [Fx.max_units]dsp.Device = undefined;
        for (self.fx.chain(&fx_buf)) |dev| { buf[len] = dev; len += 1; }
        return buf[0..len];
    }

    /// Same shape as `chain()`, parallel slot-for-slot - a pattern-player or
    /// instrument slot is never a sidechain-detector consumer (null), only
    /// `fx`'s own units can be. Callers push this to `Engine.
    /// setTrackSidechainSources` alongside `chain()`'s own `setTrackChain`.
    pub fn sidechainSources(self: *Rack, buf: *[chain_cap]?Compressor.SidechainSource) []const ?Compressor.SidechainSource {
        var len: usize = 0;
        if (self.pattern_player != null) { buf[len] = null; len += 1; }
        if (self.instrument.device() != null) { buf[len] = null; len += 1; }
        var fx_buf: [Fx.max_units]?Compressor.SidechainSource = undefined;
        for (self.fx.sidechainSources(&fx_buf)) |src| { buf[len] = src; len += 1; }
        // zig fmt: on
        return buf[0..len];
    }
};

test "a unit's device forwards events to its payload instead of swallowing them" {
    var fx = Fx{};
    defer fx.deinit(std.testing.allocator);
    const unit = try fx.insert(std.testing.allocator, 0, .comp, 48_000);

    // The engine hands a compressor its sidechain detector through exactly
    // this path (Engine.processChainWithSidechain -> Device.sendEvent). A
    // unit device with no `.event` in its vtable drops it silently, and the
    // comp self-detects - which is what killed every sidechain in the app.
    const detector = [_]types.Sample{1.0} ** 8;
    unit.device().sendEvent(.{ .set_sidechain_buf = .{ .buf = &detector } });
    try std.testing.expect(unit.payload.comp.detector != null);
    try std.testing.expectEqual(@as(usize, 8), unit.payload.comp.detector.?.len);
}

test "chain follows insertion order, not a fixed slot order" {
    var rack = Rack{
        .instrument = .{ .poly_synth = try PolySynth.init(std.testing.allocator, 48_000) },
        .label = "test",
    };
    defer rack.fx.deinit(std.testing.allocator);
    defer rack.instrument.deinit();

    // Insert an EQ, then a comp *in front of it* - the old fixed rack would
    // zig fmt: off
    // have forced comp → eq; the chain must play them as ordered.
    const eq   = try rack.fx.insert(std.testing.allocator, 0, .eq, 48_000);
    const comp = try rack.fx.insert(std.testing.allocator, 0, .comp, 48_000);

    var buf: [Rack.chain_cap]dsp.Device = undefined;
    const ch = rack.chain(&buf);

    // No pattern_player → synth at [0], comp at [1], eq at [2].
    try std.testing.expectEqual(@as(usize, 3), ch.len);
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.instrument.poly_synth)), ch[0].ptr,
    );
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&comp.payload.comp)), ch[1].ptr,
    );
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&eq.payload.eq)), ch[2].ptr,
        // zig fmt: on
    );
}

test "FX instance IDs survive reorder and duplication" {
    var fx: Fx = .{};
    defer fx.deinit(std.testing.allocator);
    const comp = try fx.insert(std.testing.allocator, 0, .comp, 48_000);
    const delay = try fx.insert(std.testing.allocator, 1, .delay, 48_000);
    const comp_id = comp.instance_id;
    const delay_id = delay.instance_id;
    fx.swap(0, 1);
    try std.testing.expectEqual(delay_id, fx.units.items[0].instance_id);
    try std.testing.expectEqual(comp_id, fx.units.items[1].instance_id);

    var copy = try fx.dupe(std.testing.allocator, 48_000);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expect(copy.findInstance(comp_id) != null);
    try std.testing.expect(copy.findInstance(delay_id) != null);
}

test "removing an FX unit does not hand its identity to a survivor" {
    var fx: Fx = .{};
    defer fx.deinit(std.testing.allocator);
    const comp = try fx.insert(std.testing.allocator, 0, .comp, 48_000);
    const sat = try fx.insert(std.testing.allocator, 1, .sat, 48_000);
    const dead_id = comp.instance_id;
    const sat_id = sat.instance_id;
    sat.payload.sat.mix = 0.25;

    fx.remove(std.testing.allocator, 0);

    // The saturator moved from slot 1 to slot 0 but is still itself, and the
    // compressor's id resolves to nothing rather than to its old neighbour.
    try std.testing.expectEqual(sat_id, fx.units.items[0].instance_id);
    try std.testing.expectEqual(@as(?*FxUnit, null), fx.findInstance(dead_id));

    // Automation still addressed to the removed unit has to stay inert. The
    // same event aimed at the survivor's own id must still land, or this
    // would pass by doing nothing at all.
    const mix_param = 2; // sat_specs[2]
    fx.units.items[0].handleEvent(.{ .automation_param = .{
        .instance_id = dead_id,
        .id = mix_param,
        .value = 1.0,
    } });
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), fx.units.items[0].payload.sat.mix, 1e-6);
    fx.units.items[0].handleEvent(.{ .automation_param = .{
        .instance_id = sat_id,
        .id = mix_param,
        .value = 1.0,
    } });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), fx.units.items[0].payload.sat.mix, 1e-6);

    // A unit added afterwards must not inherit the dead id either.
    const added = try fx.insert(std.testing.allocator, 1, .delay, 48_000);
    try std.testing.expect(added.instance_id != dead_id);
}

test "rack FX consumes modulation for its stable instance only" {
    var fx: Fx = .{};
    defer fx.deinit(std.testing.allocator);
    const sat = try fx.insert(std.testing.allocator, 0, .sat, 48_000);
    sat.payload.sat.mix = 0.0;
    var bus: FxModBus = .{};
    sat.mod_bus = &bus;

    // Long enough buffers to read past the saturator's oversampling delay,
    // and the tail of each is what gets compared.
    var dry: [128]types.Sample = @splat(0.1);
    sat.device().process(&dry);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), dry[dry.len - 1], 1e-6);

    bus.add(sat.instance_id, 2, 1.0);
    var wet: [128]types.Sample = @splat(0.1);
    sat.device().process(&wet);
    try std.testing.expect(wet[wet.len - 1] > dry[dry.len - 1]);
    try std.testing.expectEqual(@as(f32, 0.0), sat.payload.sat.mix);
}

test "rack modulation targets enumerate existing FX instances and fields" {
    var rack = Rack{
        .instrument = .{ .poly_synth = try PolySynth.init(std.testing.allocator, 48_000) },
        .label = "test",
    };
    defer rack.deinit(std.testing.allocator);
    const first = try rack.fx.insert(std.testing.allocator, 0, .sat, 48_000);
    const second = try rack.fx.insert(std.testing.allocator, 1, .sat, 48_000);

    const synth_count = PolySynth.mod_dest_ids.len;
    try std.testing.expectEqual(synth_count + 2 * fx_params.sat_specs.len, rack.modTargetCount());
    try std.testing.expectEqual(
        Rack.ModTarget{ .instance_id = first.instance_id, .param_id = 0 },
        rack.modTargetAt(synth_count).?,
    );
    try std.testing.expectEqual(
        Rack.ModTarget{ .instance_id = second.instance_id, .param_id = 0 },
        rack.modTargetAt(synth_count + fx_params.sat_specs.len).?,
    );
}

test "Fx: duplicates allowed, bypass skips, remove frees, cap enforced" {
    const allocator = std.testing.allocator;
    var fx: Fx = .{};
    defer fx.deinit(allocator);

    // Two saturators in one chain - impossible with the fixed rack.
    _ = try fx.insert(allocator, 0, .sat, 48_000);
    _ = try fx.insert(allocator, 1, .sat, 48_000);
    var buf: [Fx.max_units]dsp.Device = undefined;
    try std.testing.expectEqual(@as(usize, 2), fx.chain(&buf).len);

    // Bypassed units stay in the chain (they fade themselves out), so the
    // device count does not change.
    fx.units.items[0].setBypassed(true);
    try std.testing.expectEqual(@as(usize, 2), fx.chain(&buf).len);

    fx.remove(allocator, 0);
    try std.testing.expectEqual(@as(usize, 1), fx.units.items.len);
    try std.testing.expectEqual(FxKind.sat, fx.units.items[0].kind());

    for (fx.units.items.len..Fx.max_units) |_| _ = try fx.insert(allocator, 0, .crush, 48_000);
    try std.testing.expectError(error.ChainFull, fx.insert(allocator, 0, .gate, 48_000));
}

test "Fx.swap reorders without moving unit memory" {
    const allocator = std.testing.allocator;
    var fx: Fx = .{};
    defer fx.deinit(allocator);

    const a = try fx.insert(allocator, 0, .comp, 48_000);
    const b = try fx.insert(allocator, 1, .eq, 48_000);
    fx.swap(0, 1);
    try std.testing.expectEqual(b, fx.units.items[0]);
    try std.testing.expectEqual(a, fx.units.items[1]);

    var buf: [Fx.max_units]dsp.Device = undefined;
    const ch = fx.chain(&buf);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&b.payload.eq)), ch[0].ptr);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&a.payload.comp)), ch[1].ptr);
}

test "Fx.dupe deep-copies params and heap buffers independently (used by undo's FX snapshot)" {
    const allocator = std.testing.allocator;
    var fx: Fx = .{};
    defer fx.deinit(allocator);

    const comp = try fx.insert(allocator, 0, .comp, 48_000);
    comp.payload.comp.threshold_db = -12.0;
    const delay = try fx.insert(allocator, 1, .delay, 48_000);
    delay.payload.delay.feedback = 0.42;
    delay.setBypassed(true);

    var dup = try fx.dupe(allocator, 48_000);
    defer dup.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), dup.units.items.len);
    try std.testing.expectEqual(@as(f32, -12.0), dup.units.items[0].payload.comp.threshold_db);
    try std.testing.expectEqual(@as(f32, 0.42), dup.units.items[1].payload.delay.feedback);
    try std.testing.expect(dup.units.items[1].bypassed);

    // Distinct unit + line memory - freeing one chain must not touch the
    // other's buffers (the crash-if-it-aliased check).
    try std.testing.expect(dup.units.items[1] != delay);
    try std.testing.expect(dup.units.items[1].payload.delay.lines[0].ptr != delay.payload.delay.lines[0].ptr);

    // Mutating the original after the dupe doesn't leak into the copy.
    comp.payload.comp.threshold_db = -30.0;
    try std.testing.expectEqual(@as(f32, -12.0), dup.units.items[0].payload.comp.threshold_db);
}

const internal_fx_kinds = [_]FxKind{
    .gate,     .comp,    .mb_comp, .ott,    .limiter, .transient_shaper, .eq,         .filter,      .crossover, .utility, .stereo_width, .auto_pan, .sat, .crush,
    .expander, .clipper, .chorus,  .phaser, .flanger, .tape,             .freq_shift, .pitch_shift, .delay,     .reverb,  .amp,
};

test "every FX payload stays finite when constructed with zero sample rate" {
    const allocator = std.testing.allocator;
    for (internal_fx_kinds) |kind| {
        var payload = try Fx.initPayload(allocator, kind, 0);
        defer payload.deinit(allocator);
        var buf = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
        payload.device().process(&buf);
        for (buf) |sample| try std.testing.expect(std.math.isFinite(sample));
    }
}

test "every internal FX default keeps normal audio audible, finite, and bounded" {
    const allocator = std.testing.allocator;
    for (internal_fx_kinds) |kind| {
        var payload = try Fx.initPayload(allocator, kind, 48_000);
        defer payload.deinit(allocator);
        switch (payload) {
            .delay => |delay| try std.testing.expectApproxEqAbs(@as(f32, 0.25), delay.time_s, 1e-6),
            .ott => |ott| try std.testing.expectApproxEqAbs(@as(f32, 0.1), ott.depth(), 1e-6),
            else => {},
        }
        var buf: [2048]f32 = undefined;
        for (&buf, 0..) |*sample, i| sample.* = 0.5 * @sin(@as(f32, @floatFromInt(i / 2)) * 0.1);
        payload.device().process(&buf);
        var peak: f32 = 0.0;
        for (buf) |sample| {
            try std.testing.expect(std.math.isFinite(sample));
            peak = @max(peak, @abs(sample));
        }
        try std.testing.expect(peak > 0.001);
        try std.testing.expect(peak <= 2.0);
    }
}

test "every internal FX stays finite at its parameter extremes" {
    const allocator = std.testing.allocator;
    for (internal_fx_kinds) |kind| {
        const n = fx_params.paramCount(kind);
        // One param at each end at a time, then everything at once - a
        // feedback path only runs away when its own param is at the limit,
        // and some only when a neighbour is too (delay time + feedback).
        for (0..2 * n + 2) |combo| {
            var payload = try Fx.initPayload(allocator, kind, 48_000);
            defer payload.deinit(allocator);
            for (0..n) |idx| {
                if (!fx_params.isAutomatable(kind, idx)) continue;
                const r = fx_params.paramRange(&payload, idx);
                const end: f32 = if (combo >= 2 * n) (if (combo == 2 * n) r[0] else r[1]) else blk: {
                    if (idx != combo / 2) continue;
                    break :blk if (combo % 2 == 0) r[0] else r[1];
                };
                fx_params.setParamAbsolute(&payload, idx, end);
            }
            // Long enough for a runaway feedback loop to reach infinity.
            var buf: [512]f32 = undefined;
            for (0..64) |block| {
                for (&buf, 0..) |*sample, i| sample.* = 0.5 * @sin(@as(f32, @floatFromInt(block * 256 + i / 2)) * 0.1);
                payload.device().process(&buf);
                for (buf) |sample| {
                    if (!std.math.isFinite(sample)) {
                        std.debug.print("{s} combo {d} block {d} produced {d}\n", .{ @tagName(kind), combo, block, sample });
                        return error.NonFiniteOutput;
                    }
                }
            }
        }
    }
}

test "bypassed internal FX leave audio bit-identical" {
    const allocator = std.testing.allocator;
    var fx: Fx = .{};
    defer fx.deinit(allocator);
    for (internal_fx_kinds) |kind| (try fx.insert(allocator, fx.units.items.len, kind, 48_000)).setBypassed(true);

    var chain_buf: [Fx.max_units]dsp.Device = undefined;
    try std.testing.expectEqual(internal_fx_kinds.len, fx.chain(&chain_buf).len);
    var audio = [_]f32{ 0.25, -0.5, 0.75, -1.0 };
    const expected = audio;
    for (fx.chain(&chain_buf)) |device| device.process(&audio);
    try std.testing.expectEqualSlices(f32, &expected, &audio);
}

test "toggling bypass ramps instead of stepping the signal" {
    const allocator = std.testing.allocator;
    var fx: Fx = .{};
    defer fx.deinit(allocator);

    // A utility at -24dB: bypassing it is a 24dB jump if nothing fades.
    const unit = try fx.insert(allocator, 0, .utility, 48_000);
    unit.payload.utility.gain_db = -24.0;

    var chain_buf: [Fx.max_units]dsp.Device = undefined;
    const chain = fx.chain(&chain_buf);

    var audio = [_]f32{1.0} ** 64;
    for (chain) |device| device.process(&audio);
    const active = audio[62];
    try std.testing.expect(active < 0.1); // the gain really is applied

    // Now bypass it: the first frames after the toggle must stay near the
    // processed level and climb from there, not jump straight to dry.
    unit.bypassed = true;
    @memset(&audio, 1.0);
    for (chain) |device| device.process(&audio);
    try std.testing.expect(audio[0] < active * 2.0);
    try std.testing.expect(audio[62] > audio[0]);
    try std.testing.expect(audio[62] < 1.0); // 32 frames is well short of the full fade

    // Left running, it settles at exactly dry and stops touching the buffer.
    for (0..20) |_| {
        @memset(&audio, 1.0);
        for (chain) |device| device.process(&audio);
    }
    for (audio) |s| try std.testing.expectEqual(@as(f32, 1.0), s);
    try std.testing.expectEqual(@as(u32, 0), chain[0].latencyFrames());
}

test "drum_machine Instrument variant: device ptr stable inside heap Rack" {
    var transport: Transport = .{ .sample_rate = 48_000 };

    // zig fmt: off
    const rack = try std.testing.allocator.create(Rack);
    defer { rack.deinit(std.testing.allocator); std.testing.allocator.destroy(rack); }

    rack.* = .{
        .instrument = .{ .drum_machine = try DrumMachine.init(
            std.testing.allocator, 48_000, &transport,
        ) },
        .label = "drums",
    };

    var buf: [Rack.chain_cap]dsp.Device = undefined;
    const ch = rack.chain(&buf);

    try std.testing.expectEqual(@as(usize, 1), ch.len);
    // device() must point into the heap-allocated Rack, not a stack copy
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&rack.instrument.drum_machine)), ch[0].ptr,
        // zig fmt: on
    );
}

fn dupeDrumRackForAllocationTest(allocator: std.mem.Allocator) !void {
    var transport: Transport = .{ .sample_rate = 48_000 };
    const drum_machine = try DrumMachine.init(allocator, 48_000, &transport);
    var rack: Rack = .{ .instrument = .{ .drum_machine = drum_machine }, .label = "drums" };
    defer rack.deinit(allocator);

    const copy = try rack.dupe(allocator, 48_000, &transport);
    copy.deinit(allocator);
    allocator.destroy(copy);
}

test "rack duplication cleans partial instruments after allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, dupeDrumRackForAllocationTest, .{});
}

test "modulating a cross-clamped param pair puts both bases back" {
    // `processPayload` saves each modulated param's base, writes the
    // modulated value, and writes the base back after the block. That round
    // trip is not the identity for a param whose setter clamps against a
    // sibling: the crossover's `setXoverLo` clamps against `xover_hi_hz`,
    // which is still holding *its* modulated value when lo is restored. The
    // base then comes back clamped, and ratchets further every block.
    var fx: Fx = .{};
    defer fx.deinit(std.testing.allocator);
    const xo = try fx.insert(std.testing.allocator, 0, .crossover, 48_000);
    var bus: FxModBus = .{};
    xo.mod_bus = &bus;
    const lo = xo.payload.crossover.xover_lo_hz;
    const hi = xo.payload.crossover.xover_hi_hz;
    bus.add(xo.instance_id, 0, -1.0); // xover-lo, hard down
    bus.add(xo.instance_id, 1, -1.0); // xover-hi, hard down

    var buf: [64]types.Sample = @splat(0.1);
    for (0..4) |_| xo.device().process(&buf);

    try std.testing.expectApproxEqAbs(lo, xo.payload.crossover.xover_lo_hz, 1e-3);
    try std.testing.expectApproxEqAbs(hi, xo.payload.crossover.xover_hi_hz, 1e-3);
}
