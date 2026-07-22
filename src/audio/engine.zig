const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("../dsp/device.zig");
const spectrum_mod = @import("../dsp/spectrum.zig");
const Spsc = @import("../core/ring_buffer.zig").Spsc;
const Limiter = @import("../dsp/limiter.zig").Limiter;
const Metronome = @import("../dsp/metronome.zig").Metronome;
const Transport = @import("../transport.zig").Transport;
const Project = @import("../project.zig").Project;
const automation_mod = @import("../dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;
const AutomationCurve = automation_mod.AutomationCurve;
const meter_mod = @import("../dsp/meter.zig");

const Sample = types.Sample;
const SpectrumAnalyzer = spectrum_mod.SpectrumAnalyzer;
const SpectrumSnapshot = spectrum_mod.SpectrumSnapshot;
const StereoCorrelation = meter_mod.StereoCorrelation;
const LoudnessMeter = meter_mod.LoudnessMeter;

pub const max_tracks = 8192;
/// Must cover Rack.chain_cap (pattern player + instrument + a full 9-unit
/// FX chain); setTrackChain silently truncates past it.
pub const max_chain_devices = 12;
pub const channels = 2;
/// Track-grouping submix buses (see `TrackState.group`, `renderTracks`'s
/// two-stage grouped-track routing). Same small-fixed-bank scale as
/// max_variants/max_choke_groups elsewhere - a real UI-relevant count, not
/// max_tracks' generous headroom.
pub const max_groups: u8 = 8;

pub const SpectrumSource = enum { none, track, master, group };

pub const Command = union(enum) {
    play,
    stop,
    seek_frames: u64,
    set_tempo: f64,
    /// Beats per bar; the beat unit stays /4 (a beat is always a quarter).
    set_time_signature: u8,
    set_master_gain: f32,
    set_track_gain: struct { track: u16, gain: f32 },
    set_track_pan: struct { track: u16, pan: f32 },
    set_track_mute: struct { track: u16, muted: bool },
    set_track_solo: struct { track: u16, soloed: bool },
    note_on: struct { track: u16, note: u7, velocity: f32 },
    note_off: struct { track: u16, note: u7 },
    all_notes_off,
    cc: struct { track: u16, cc: u7, value: u7 },
    pitch_bend: struct { track: u16, bend: i16 },
    /// Nudge synth editor parameter `id` by `steps` on track `track`. Applied
    /// on the audio thread so editor edits don't race the block reader. u16,
    /// not u8 - see dsp/device.zig's Event.set_param doc comment.
    set_track_param: struct { track: u16, id: u16, steps: i32 },
    /// Absolute-value counterpart to `set_track_param` - for undo, which
    /// restores a captured value directly rather than replaying a delta (a
    /// delta lands wrong whenever any nudge in the batch hit a param's
    /// clamp, and enum/toggle params treat any nonzero delta as one step).
    /// Same route automation's own `Event.set_param_abs` already takes,
    /// just originating from the control-side command queue.
    set_track_param_abs: struct { track: u16, id: u16, value: f32 },
    set_clap_param: struct { track: u16, target: *anyopaque, id: u32, cookie: ?*anyopaque, value: f64 },
    /// Which group (if any) `track` submixes through before the master bus.
    /// `null` routes straight to master, same as before grouping existed.
    set_track_group: struct { track: u16, group: ?u8 },
    /// Group submix bus fader (linear, post-FX-chain - see `GroupState.gain`).
    set_group_gain: struct { group: u8, gain: f32 },
    /// `group` is only read when `source == .group` (reuses `track` as the
    /// generic focus index otherwise, unchanged) - same one-analyzer-at-a-
    /// time model track/master already share, see `Engine.track_spectrum`.
    set_spectrum_active: struct { source: SpectrumSource, track: u16, group: u8 = 0 },
    /// A/B loop region (frames). See Transport.advance for the wrap.
    set_loop: struct { enabled: bool, start_frames: u64, end_frames: u64 },
    set_metronome: bool,
    /// See `wstudio.o.metronome_click_gain`.
    set_metronome_gain: f32,
    /// Arms a `bars`-bar count-in at the current position: the metronome
    /// clicks through it (regardless of `set_metronome`'s on/off state)
    /// while the transport stays stopped, then playback starts for real
    /// exactly on the downbeat. `bars == 0` skips the count-in and starts
    /// playback immediately. See Engine.firePreRoll and
    /// `wstudio.o.count_in_bars`.
    record: u8,
    /// Clears the master bus's integrated-LUFS accumulator so a fresh
    /// loudness measurement starts from this point (momentary/short-term
    /// keep reading through it). See `LoudnessMeter.resetIntegrated`.
    reset_loudness,
};

/// Which absolute value an `AutomationCurve` overrides. `gain`/`pan` are
/// mix-bus params, applied as a post-chain multiplier in `renderTracks`.
/// Synth-instrument params (filter cutoff, LFO rate, envelope times, ...)
/// don't go through this enum - see `setTrackSynthParam`/`SynthAutomationSlot`
/// below, since there are ~30 of them and most tracks only automate a few at
/// once (a fixed per-param field the way `gain`/`pan` work would preallocate
/// far more than any project uses - see `AutomationPair`'s own doc comment).
pub const AutomationTarget = enum { gain, pan };

/// Every parameter id representable by the persisted automation model gets a
/// slot. Curves allocate their point buffers only when used, so complete id
/// coverage no longer implies a fixed point-buffer cost per track.
pub const max_synth_slots = 256;

/// One synth-param automation slot. `param_id` matches `PolySynth.
/// setParamAbsolute`'s id space (filter cutoff is just param_id 21 here, no
/// longer a dedicated field) or `null` for an unused slot.
const SynthAutomationSlot = struct {
    param_id: ?u8 = null,
    curve: AutomationCurve = .{},
};

/// A device chain (track/master/group FX chain) as read by the audio
/// thread while the control thread may be replacing it wholesale (adding,
/// removing, or reordering FX/instrument slots) with no other
/// synchronization between the two. `dsp.Device` is a two-word ptr+vtable
/// pair (see `dsp/device.zig`), not atomically writable as a single unit -
/// an audio-thread read torn mid-overwrite could pair one device's data
/// pointer with a DIFFERENT device type's vtable, calling the wrong
/// `process` function against the wrong memory layout (not just "stale
/// sound for one block" the way a torn scalar field would be - real type
/// confusion, crash-capable). Double-buffered instead: `set` (control
/// thread) stages the whole new chain into whichever buffer isn't
/// currently active, then atomically flips `active` - `slice()` (audio
/// thread) always observes one buffer's contents wholesale, old or new,
/// never a mix. Same "audio thread never blocks, control thread does the
/// work" discipline `AutomationCurve`'s lock already applies to gain/pan
/// automation, just via a swap instead of a spin since a whole chain can't
/// be copied under a lock without risking the audio thread blocking on it.
fn ChainBank(comptime max: usize) type {
    return struct {
        bufs: [2][max]dsp.Device = undefined,
        counts: [2]usize = .{ 0, 0 },
        /// 0 or 1 - which of `bufs`/`counts` is live. `u8`, not `u1`:
        /// `std.atomic.Value` needs an extern-compatible int width.
        active: std.atomic.Value(u8) = .init(0),

        /// Audio-thread read. Snapshot the result once per use (don't call
        /// `slice()` again later in the same render pass) - the buffer can
        /// flip between two calls, and a chain must be read as one
        /// consistent whole for a given block. `pub` so tests elsewhere in
        /// the crate can assert chain length without a dedicated accessor.
        pub fn slice(self: *const @This()) []const dsp.Device {
            const idx = self.active.load(.acquire);
            return self.bufs[idx][0..self.counts[idx]];
        }

        /// Control-thread write.
        fn set(self: *@This(), devices: []const dsp.Device) void {
            const next: u8 = self.active.load(.monotonic) ^ 1;
            const n = @min(devices.len, max);
            self.counts[next] = n;
            for (devices[0..n], self.bufs[next][0..n]) |src, *dst| dst.* = src;
            self.active.store(next, .release);
        }
    };
}

const TrackState = struct {
    active: bool = false,
    gain: f32 = 1.0,
    pan: f32 = 0.0,
    muted: bool = false,
    soloed: bool = false,
    chain: ChainBank(max_chain_devices) = .{},
    /// Which group submix bus (see `max_groups`) this track's post-gain/pan
    /// signal routes through instead of straight to the master mix. `null`
    /// (the default) is the pre-grouping behaviour, unchanged.
    group: ?u8 = null,
};

/// Bank of distinct tracks that can be captured as a sidechain-compressor
/// detector source in one block - same small-fixed-bank convention as
/// `max_synth_slots`/`max_groups`. Most songs sidechain off one or two key
/// tracks (a kick, maybe a snare); 8 is generous headroom.
pub const max_sidechain_sources: u8 = 8;

/// One block's captured signal for a track registered as some compressor's
/// sidechain-detector source (see `Compressor.sidechain_source`). `track`
/// is `null` when the slot is unused this block. `captured` says the source
/// actually rendered into `buf` THIS block; a registered slot whose track
/// never rendered (inactive, empty chain, or ordered after its consumer in
/// a mutual-reference cycle) keeps it false, and `sidechainCapture` treats
/// the slot as absent rather than handing out stale or uninitialized
/// samples. Sized to `max_block_frames` so it never needs a per-block
/// allocation; only the first `frames*channels` samples are valid for a
/// given block. Small fixed bank (~256KB total), safe to embed directly in
/// `Engine` - see `AutomationPair`'s doc comment for the class of field
/// that ISN'T safe to embed this way.
const SidechainCapture = struct {
    source: ?Compressor.SidechainSource = null,
    captured: bool = false,
    buf: [types.max_block_frames * channels]Sample = undefined,
};

/// One group submix bus: a named FX chain (see `Session.groups`, mirroring
/// `master_chain`'s shape) every member track's summed signal passes
/// through before reaching the master mix. `active` distinguishes an
/// in-use slot from a never-created one - same convention `TrackState`
/// itself uses, since `[max_groups]GroupState` is a fixed bank, not a
/// growable list.
const GroupState = struct {
    active: bool = false,
    /// Bus fader, applied to the submix AFTER the group's FX chain (ride
    /// the level of the finished bus, not what feeds its compressor) -
    /// linear, same convention as `TrackState.gain`/`master_gain`.
    gain: f32 = 1.0,
    /// Same fixed width as `master_chain` (Fx.max_units, hardcoded here the
    /// same way master_chain's own field already does rather than importing
    /// rack.zig just for the constant).
    chain: ChainBank(9) = .{},
    /// Per-chain-slot sidechain-detector source, parallel to `chain` - see
    /// `TrackSidechainSlots`'s doc comment for why this lives directly on
    /// GroupState (safe here, unlike on TrackState) rather than as a
    /// separate heap slice.
    sidechain_sources: [9]?Compressor.SidechainSource = [_]?Compressor.SidechainSource{null} ** 9,
};

/// Per-track, per-chain-slot sidechain-detector routing (see `Compressor.
/// sidechain_source`), parallel to `TrackState.chain`. Deliberately NOT a
/// field on `TrackState` for the exact reason `AutomationPair`'s doc comment
/// gives: `TrackState` is embedded inline in `[max_tracks]TrackState`
/// (max_tracks = 8192), so even this small `max_chain_devices`-slot array
/// would add ~400KB to Engine's own inline layout. Kept as its own
/// heap-allocated slice instead (`Engine.track_sidechain`), sized once at
/// `Engine.init` and indexed the same as `tracks` - same pattern
/// `Engine.automation` already established.
const TrackSidechainSlots = [max_chain_devices]?Compressor.SidechainSource;

/// A track slot's song-mode gain/pan automation, flattened from the
/// arrangement's clips by `Session.rebuildSongData` (see dsp/automation.zig).
/// Empty (the default) means no override - the track plays at its manual
/// `TrackState.gain`/`.pan`, same as before automation existed.
///
/// Deliberately NOT a field on `TrackState`: that struct is embedded inline
/// in a `[max_tracks]TrackState` array (max_tracks = 8192), so every byte
/// added there is multiplied 8192x. Curves are kept in this separately
/// allocated slice, and each curve allocates point storage only when used.
const AutomationPair = struct {
    gain: AutomationCurve = .{},
    pan: AutomationCurve = .{},
    /// Parameter-id automation. Empty curves allocate no point storage.
    synth_slots: [max_synth_slots]SynthAutomationSlot = [_]SynthAutomationSlot{.{}} ** max_synth_slots,

    fn deinit(self: *AutomationPair, allocator: std.mem.Allocator) void {
        self.gain.deinit(allocator);
        self.pan.deinit(allocator);
        for (&self.synth_slots) |*slot| slot.curve.deinit(allocator);
    }

    fn clear(self: *AutomationPair, allocator: std.mem.Allocator) void {
        self.gain.set(allocator, &.{}) catch unreachable;
        self.pan.set(allocator, &.{}) catch unreachable;
        for (&self.synth_slots) |*slot| {
            slot.curve.set(allocator, &.{}) catch unreachable;
            slot.param_id = null;
        }
    }

    fn swapContent(self: *AutomationPair, other: *AutomationPair) void {
        self.gain.swapPoints(&other.gain);
        self.pan.swapPoints(&other.pan);
        for (&self.synth_slots, &other.synth_slots) |*a, *b| {
            a.curve.swapPoints(&b.curve);
            std.mem.swap(?u8, &a.param_id, &b.param_id);
        }
    }
};

pub const UiSnapshot = struct {
    playing: bool,
    /// True while a `.record` count-in is clicking through its bar - the
    /// transport itself is still stopped (`playing` is false) until it
    /// finishes. Lets the UI show a distinct "counting in" state and lets
    /// space cancel it instead of arming a second one.
    pre_rolling: bool,
    position_frames: u64,
    peak: [channels]f32,
    /// Master-bus phase correlation, -1 (out of phase) .. +1 (in phase) -
    /// see `dsp/meter.zig`'s `StereoCorrelation`.
    correlation: f32,
    /// Master-bus K-weighted loudness (LUFS), see `dsp/meter.zig`'s
    /// `LoudnessMeter`. Floored at `LoudnessMeter.floor_lufs` (-120) at
    /// silence/startup.
    lufs_momentary: f32,
    lufs_short_term: f32,
    lufs_integrated: f32,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    commands: Spsc(Command, 256) = .{},
    /// Commands are realtime messages and cannot block their producer. Count
    /// queue saturation so the UI can report it instead of failing silently.
    dropped_commands: std.atomic.Value(u32) = .init(0),
    master_gain: f32 = 1.0,
    /// Always-on master-bus limiter: catches hot mixes before the WAV
    /// writer's ±1 clamp (and the DAC) turns them into hard-clip distortion.
    limiter: Limiter,
    /// User-built master bus FX chain (see Fx.chain), applied to the summed
    /// mix before `master_gain` and the always-on limiter. Devices are fat
    /// pointers into `Session.master_fx`'s heap units, see `setMasterChain`.
    /// Sized to Fx.max_units.
    master_chain: ChainBank(9) = .{},
    metronome: Metronome,
    metronome_enabled: bool = false,
    /// Monotonic count of beats fired so far - same resync-on-discontinuity
    /// technique as DrumMachine.next_step_k, one level up (beats, not steps).
    metronome_next_beat: u64 = 0,
    /// Record count-in: frames left in the armed bar (0 = no pre-roll in
    /// flight). `pre_roll_elapsed` is a virtual clock - the transport itself
    /// hasn't started yet - driving the same beat-boundary click math
    /// `fireMetronome` uses, via its own `pre_roll_next_beat` counter. See
    /// `firePreRoll`.
    pre_roll_frames_remaining: u64 = 0,
    pre_roll_elapsed: u64 = 0,
    pre_roll_next_beat: u64 = 0,
    /// Index layer over `track_pool`: `tracks[i]` is which pooled
    /// `TrackState` object logical slot `i` currently refers to. Insert/
    /// delete/swap (control thread, called while the audio thread may be
    /// mid-`process()`) shift POINTERS here rather than copying `TrackState`
    /// values between slots - a raw struct copy would drag a live
    /// `ChainBank`'s buffer bytes across index positions non-atomically,
    /// the same crash-capable torn-read risk `ChainBank` itself closes for
    /// direct chain edits. Swapping a pointer is a single atomic store; the
    /// backing object it points to is never moved or partially overwritten
    /// while any other slot might still reference it (see
    /// `applyInsertTrack`/`applyDeleteTrack`/`swapTracks`). Heap slice of
    /// length `max_tracks`, owned, freed in `deinit`.
    tracks: []std.atomic.Value(*TrackState),
    /// Stable backing storage `tracks` indexes into by pointer - a fixed
    /// pool of `max_tracks` objects, never moved once allocated. Heap slice
    /// (owned, freed in `deinit`) for the same by-value-construction/stack
    /// size reason `automation`/`track_sidechain` are: inline it is ~3.2MB.
    track_pool: []TrackState,
    scratch: [types.max_block_frames * channels]Sample = undefined,
    /// Group submix buses (see `TrackState.group`/`renderTracks`). Fixed
    /// bank of `max_groups` (8), not multiplied by `max_tracks` - negligible
    /// size (~256KB total), safe to embed directly unlike `AutomationPair`.
    groups: [max_groups]GroupState = [_]GroupState{.{}} ** max_groups,
    group_scratch: [max_groups][types.max_block_frames * channels]Sample = undefined,
    peak: [channels]f32 = .{ 0.0, 0.0 },
    /// Single analyzer reused for whichever track/group is being viewed.
    track_spectrum: SpectrumAnalyzer,
    master_spectrum: SpectrumAnalyzer,
    /// Master-bus phase-correlation and LUFS meters - always on (unlike the
    /// spectrum analyzers, there's only ever one master bus to measure, so
    /// no active-source gating needed). See `UiSnapshot`/`uiSnapshot`.
    master_correlation: StereoCorrelation,
    master_loudness: LoudnessMeter,
    active_spectrum_source: SpectrumSource = .none,
    active_spectrum_track: u16 = 0,
    active_spectrum_group: u8 = 0,
    shared: Shared = .{},
    /// Offline-bounce handshake. When the UI thread sets `bounce_active`, the
    /// realtime backend parks (outputs silence, sets `bounce_parked`) so the UI
    /// thread can drive process() into a file without racing the audio thread.
    bounce_active: std.atomic.Value(bool) = .init(false),
    bounce_parked: std.atomic.Value(bool) = .init(false),
    /// One gain/pan automation pair per track slot - see `AutomationPair`'s
    /// doc comment for why this is a separate heap allocation rather than a
    /// field on `TrackState`. Indexed the same as `tracks`.
    automation: []AutomationPair,
    /// Per-track chain-slot sidechain-detector routing - see
    /// `TrackSidechainSlots`'s doc comment for why this is a separate heap
    /// allocation. Indexed the same as `tracks`.
    track_sidechain: []TrackSidechainSlots,
    /// Per-chain-slot sidechain-detector routing for the master bus, parallel
    /// to `master_chain` - safe to embed directly (not scaled by max_tracks).
    master_sidechain_sources: [9]?Compressor.SidechainSource = [_]?Compressor.SidechainSource{null} ** 9,
    /// This block's captured signal per registered sidechain-detector source
    /// track - see `SidechainCapture`. Rebuilt every block in `renderTracks`.
    sidechain_captures: [max_sidechain_sources]SidechainCapture = [_]SidechainCapture{.{}} ** max_sidechain_sources,

    const Shared = struct {
        playing: std.atomic.Value(bool) = .init(false),
        pre_rolling: std.atomic.Value(bool) = .init(false),
        position_frames: std.atomic.Value(u64) = .init(0),
        peak_bits: [channels]std.atomic.Value(u32) = .{ .init(0), .init(0) },
        correlation_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1.0))),
        lufs_momentary_bits: std.atomic.Value(u32) = .init(@bitCast(LoudnessMeter.floor_lufs)),
        lufs_short_term_bits: std.atomic.Value(u32) = .init(@bitCast(LoudnessMeter.floor_lufs)),
        lufs_integrated_bits: std.atomic.Value(u32) = .init(@bitCast(LoudnessMeter.floor_lufs)),
    };

    /// By-value init, for tests that keep an Engine on their own frame -
    /// affordable since the per-track banks live on the heap (see
    /// `tracks`). Heap-allocated engines (Session, persist.buildSession)
    /// still use `initInPlace` to skip the remaining ~0.5MB of copies.
    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !Engine {
        var self: Engine = undefined;
        try initInPlace(&self, allocator, sample_rate);
        return self;
    }

    /// Construct the Engine directly through `self` (no big stack
    /// temporaries - see `init`). On error `self` is left undefined.
    pub fn initInPlace(self: *Engine, allocator: std.mem.Allocator, sample_rate: u32) !void {
        // Sample rate reaches every oscillator, filter, spectrum band, and
        // metronome calculation below. Reject it before those paths can
        // divide by zero when loading a malformed project/config.
        if (sample_rate == 0) return error.InvalidSampleRate;
        var track_spec = try SpectrumAnalyzer.init(allocator, sample_rate);
        errdefer track_spec.deinit(allocator);
        var master_spec = try SpectrumAnalyzer.init(allocator, sample_rate);
        errdefer master_spec.deinit(allocator);
        var metronome = try Metronome.init(allocator, sample_rate);
        errdefer metronome.deinit();
        const automation = try allocator.alloc(AutomationPair, max_tracks);
        errdefer allocator.free(automation);
        for (automation) |*a| a.* = .{};
        const track_sidechain = try allocator.alloc(TrackSidechainSlots, max_tracks);
        errdefer allocator.free(track_sidechain);
        for (track_sidechain) |*s| s.* = [_]?Compressor.SidechainSource{null} ** max_chain_devices;
        const track_pool = try allocator.alloc(TrackState, max_tracks);
        errdefer allocator.free(track_pool);
        for (track_pool) |*t| t.* = .{};
        const tracks = try allocator.alloc(std.atomic.Value(*TrackState), max_tracks);
        errdefer allocator.free(tracks);
        for (tracks, track_pool) |*slot, *t| slot.* = .init(t);

        self.* = .{
            .allocator = allocator,
            .transport = .{ .sample_rate = sample_rate },
            .limiter = Limiter.init(sample_rate),
            .metronome = metronome,
            .tracks = tracks,
            .track_pool = track_pool,
            .track_spectrum = track_spec,
            .master_spectrum = master_spec,
            .master_correlation = StereoCorrelation.init(sample_rate),
            .master_loudness = LoudnessMeter.init(sample_rate),
            .automation = automation,
            .track_sidechain = track_sidechain,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.metronome.deinit();
        self.master_spectrum.deinit(self.allocator);
        self.track_spectrum.deinit(self.allocator);
        for (self.automation) |*pair| pair.deinit(self.allocator);
        self.allocator.free(self.automation);
        self.allocator.free(self.track_sidechain);
        self.allocator.free(self.tracks);
        self.allocator.free(self.track_pool);
    }

    pub fn loadProject(self: *Engine, project: *const Project) void {
        self.transport.tempo_bpm = project.tempo_bpm;
        self.transport.time_signature.beats_per_bar = project.beats_per_bar;
        const fpb = project.framesPerBar();
        self.transport.loop_enabled = project.loop_enabled and
            project.loop_end_bar > project.loop_start_bar;
        self.transport.loop_start_frames = @as(u64, project.loop_start_bar) * fpb;
        self.transport.loop_end_frames = @as(u64, project.loop_end_bar) * fpb;
        // Safe to write straight into the pooled `TrackState`s (bypassing
        // ChainBank's atomic swap): `loadProject` only ever runs right
        // after `initInPlace`, on an `Engine` no audio thread has been
        // started against yet (see callers) - not a live mutation.
        for (self.tracks, 0..) |*slot, i| {
            const state = slot.load(.monotonic);
            if (i < project.tracks.items.len) {
                const t = project.tracks.items[i];
                state.* = .{
                    .active = true,
                    .gain = types.dbToGain(t.gain_db),
                    .pan = t.pan,
                    .muted = t.muted,
                    .soloed = t.soloed,
                    .group = t.group,
                };
            } else {
                state.* = .{};
            }
        }
    }

    /// Shift engine slots [idx, total) up by one (to make room for a new
    /// track), then initialize `idx` as a new active track with no chain.
    /// `total` is the track count before the insert. Shifts the parallel
    /// per-track heap arrays (`automation`, `track_sidechain`) in the same
    /// motion - they are indexed the same as `tracks` and would otherwise
    /// stay keyed to the pre-shift indices.
    ///
    /// Called from the UI/control thread while the audio thread may be
    /// mid-`process()`. Shifts POINTERS (single-word atomic stores), never
    /// `TrackState` values - see `tracks`'s doc comment for why a raw
    /// struct copy would be crash-capable here. `track_sidechain`/
    /// `automation` stay plain value shifts (small POD arrays, no fat
    /// pointers to tear) - same lower-severity "stale for one block" race
    /// they already tolerated before this change, unaffected by it.
    ///
    /// Note: a multi-slot shift still can't be made atomic as a WHOLE
    /// through per-slot pointer stores alone - for one instant mid-shift,
    /// two adjacent slots briefly point at the same backing track, so an
    /// audio-thread render pass unlucky enough to land in that window
    /// could render that one track's instrument twice in the same block
    /// (an audible glitch, self-corrects next block, not a crash). That
    /// residual is pre-existing (the original value-copy version had the
    /// same window) and out of scope here; only the type-confusion/crash
    /// risk from copying `TrackState`'s `ChainBank` by value is what this
    /// change closes.
    pub fn applyInsertTrack(self: *Engine, idx: u16, total: u16, gain: f32, pan: f32, muted: bool) void {
        var i: usize = @min(total, max_tracks - 1);
        // The pointer about to be evicted from the visible range - nothing
        // in [idx, total] still needs its CURRENT content, so it's safe to
        // reset in place before being republished at `idx` below.
        const fresh = self.tracks[i].load(.monotonic);
        while (i > idx) : (i -= 1) {
            self.tracks[i].store(self.tracks[i - 1].load(.monotonic), .release);
            self.track_sidechain[i] = self.track_sidechain[i - 1];
            self.automation[i].swapContent(&self.automation[i - 1]);
        }
        fresh.* = .{
            .active = true,
            .gain = gain,
            .pan = pan,
            .muted = muted,
        };
        self.tracks[idx].store(fresh, .release);
        self.track_sidechain[idx] = [_]?Compressor.SidechainSource{null} ** max_chain_devices;
        self.automation[idx].clear(self.allocator);
    }

    /// Shift engine slots [idx+1, total) down by one, clearing the last slot.
    /// Same parallel-array rule, and same pointer-vs-value/residual-glitch
    /// notes, as `applyInsertTrack`.
    pub fn applyDeleteTrack(self: *Engine, idx: u16, total: u16) void {
        // The track actually being deleted - overwritten out of the visible
        // range by the very first loop iteration below, so nothing else
        // needs its content past this point.
        const evicted = self.tracks[idx].load(.monotonic);
        for (idx..total - 1) |i| {
            self.tracks[i].store(self.tracks[i + 1].load(.monotonic), .release);
            self.track_sidechain[i] = self.track_sidechain[i + 1];
            self.automation[i].swapContent(&self.automation[i + 1]);
        }
        evicted.* = .{};
        self.tracks[total - 1].store(evicted, .release);
        self.track_sidechain[total - 1] = [_]?Compressor.SidechainSource{null} ** max_chain_devices;
        self.automation[total - 1].clear(self.allocator);
    }

    /// Swap two tracks' engine slots (state + chain + the parallel
    /// automation/sidechain rows) in place. Same race class as
    /// applyInsertTrack/applyDeleteTrack - called from the UI/control
    /// thread while the audio thread may be mid-block. Pointer swap, not a
    /// value swap - see `tracks`'s doc comment.
    pub fn swapTracks(self: *Engine, a: u16, b: u16) void {
        const pa = self.tracks[a].load(.monotonic);
        const pb = self.tracks[b].load(.monotonic);
        self.tracks[a].store(pb, .release);
        self.tracks[b].store(pa, .release);
        std.mem.swap(TrackSidechainSlots, &self.track_sidechain[a], &self.track_sidechain[b]);
        self.automation[a].swapContent(&self.automation[b]);
    }

    /// Fires `self.metronome.trigger` at every beat boundary inside
    /// [pos_f, pos_f+frames), starting from `beat_k`, and returns the first
    /// beat not yet fired - shared beat-boundary-crossing loop between
    /// `fireMetronome` (real transport position, resyncs on discontinuity
    /// before calling this) and `firePreRoll` (a virtual clock that's always
    /// contiguous, so it skips the resync). Same technique as
    /// DrumMachine.processBlock's step firing, one level up: beats instead
    /// of steps.
    fn fireBeatBoundaries(self: *Engine, beat_k: u64, fpb: f64, bpb: u64, pos_f: f64, frames: u32) u64 {
        var bk = beat_k;
        while (true) {
            const fire_pos = @as(f64, @floatFromInt(bk)) * fpb;
            if (fire_pos >= pos_f + @as(f64, @floatFromInt(frames))) break;

            const fire_frame: u32 = if (fire_pos <= pos_f)
                0
            else
                @intCast(@min(
                    @as(u64, @intFromFloat(fire_pos - pos_f)),
                    @as(u64, frames - 1),
                ));

            self.metronome.trigger(bk % bpb == 0, fire_frame);
            bk += 1;
        }
        return bk;
    }

    /// Fire the metronome click at every beat boundary inside this block,
    /// then mix whatever's in flight into `out`.
    fn fireMetronome(self: *Engine, out: []Sample, frames: u32) void {
        if (self.transport.playing) {
            const pos_f = @as(f64, @floatFromInt(self.transport.position_frames));
            const fpb = self.transport.framesPerBeat();
            var beat_k = self.metronome_next_beat;

            const expected = @as(f64, @floatFromInt(beat_k)) * fpb;
            if (@abs(expected - pos_f) > fpb * 2.0) {
                beat_k = @intFromFloat(@ceil(pos_f / fpb));
            }

            const bpb: u64 = self.transport.time_signature.beats_per_bar;
            self.metronome_next_beat = self.fireBeatBoundaries(beat_k, fpb, bpb, pos_f, frames);
        }

        self.metronome.render(out, channels, frames);
    }

    /// Clicks through the armed count-in bar and, once it's fully elapsed,
    /// starts the transport for real - recording begins exactly on the
    /// downbeat. Same beat-boundary-crossing loop as `fireMetronome`, just
    /// driven by `pre_roll_elapsed` (a virtual clock) instead of the real
    /// transport position, since the transport hasn't started yet. Clicks
    /// unconditionally - count-in isn't gated by `metronome_enabled`; it's
    /// the only timing cue you have while nothing else is playing.
    fn firePreRoll(self: *Engine, out: []Sample, frames: u32) void {
        const fpb = self.transport.framesPerBeat();
        const bpb: u64 = self.transport.time_signature.beats_per_bar;
        const pos_f: f64 = @floatFromInt(self.pre_roll_elapsed);

        self.pre_roll_next_beat = self.fireBeatBoundaries(self.pre_roll_next_beat, fpb, bpb, pos_f, frames);
        self.metronome.render(out, channels, frames);

        if (frames >= self.pre_roll_frames_remaining) {
            self.pre_roll_frames_remaining = 0;
            self.pre_roll_next_beat = 0;
            self.transport.play();
        } else {
            self.pre_roll_frames_remaining -= frames;
            self.pre_roll_elapsed += frames;
        }
    }

    pub fn setTrackChain(self: *Engine, track: u16, devices: []const dsp.Device) void {
        self.trackAt(track).chain.set(devices);
    }

    /// Replaces `dst` wholesale with `sources`, null-padding past its
    /// length - shared body of `setTrackSidechainSources`/
    /// `setMasterSidechainSources`/`setGroupSidechainSources`, which differ
    /// only in which fixed-size slot array they hand it.
    fn replaceSidechainSlots(dst: []?Compressor.SidechainSource, sources: []const ?Compressor.SidechainSource) void {
        @memset(dst, null);
        const n = @min(sources.len, dst.len);
        @memcpy(dst[0..n], sources[0..n]);
    }

    /// Replace a track's per-chain-slot sidechain-detector routing (see
    /// `Compressor.sidechain_source`). `sources[i]` is the track index
    /// chain slot `i`'s compressor (if any) should detect from instead of
    /// its own input; `null` entries and any slot past `sources.len` stay
    /// self-detecting. Called by `Session` alongside `setTrackChain`
    /// whenever this track's Fx chain (re)syncs, since the audio thread
    /// never introspects chain contents to discover this itself.
    pub fn setTrackSidechainSources(self: *Engine, track: u16, sources: []const ?Compressor.SidechainSource) void {
        replaceSidechainSlots(&self.track_sidechain[@min(track, max_tracks - 1)], sources);
    }

    /// Replace a track's flattened gain or pan automation curve wholesale
    /// (control thread). Called by `Session.rebuildSongData` whenever the
    /// arrangement's clips change; an empty `points` clears it, falling back
    /// to the track's manual gain/pan (e.g. when leaving song mode). Safe to
    /// call while the audio thread is running - `AutomationCurve.set` takes
    /// its own lock, same discipline as `PatternPlayer.setSongNotes`.
    pub fn setTrackAutomation(self: *Engine, track: u16, target: AutomationTarget, points: []const AutomationPoint) void {
        const pair = &self.automation[@min(track, max_tracks - 1)];
        switch (target) {
            .gain => pair.gain.set(self.allocator, points) catch @panic("out of memory setting gain automation"),
            .pan => pair.pan.set(self.allocator, points) catch @panic("out of memory setting pan automation"),
        }
    }

    /// Replace a track's instrument-param automation curve for `param_id`.
    /// The persisted id is also the array index, covering its entire u8
    /// domain without a sparse-bank capacity limit.
    pub fn setTrackSynthParam(self: *Engine, track: u16, param_id: u8, points: []const AutomationPoint) void {
        const pair = &self.automation[@min(track, max_tracks - 1)];
        const slot = &pair.synth_slots[param_id];
        slot.curve.set(self.allocator, points) catch @panic("out of memory setting parameter automation");
        slot.param_id = if (points.len == 0) null else param_id;
    }

    /// Clear every synth-param automation slot for a track (control thread).
    /// `Session.rebuildSongData` calls this before repopulating a track's
    /// slots from scratch each rebuild, so a param removed from every clip
    /// since the last rebuild doesn't linger in a stale slot forever.
    pub fn clearTrackSynthParams(self: *Engine, track: u16) void {
        const pair = &self.automation[@min(track, max_tracks - 1)];
        for (&pair.synth_slots) |*slot| {
            slot.param_id = null;
            slot.curve.set(self.allocator, &.{}) catch unreachable;
        }
    }

    /// Same shape as `setTrackChain` but for the master bus - no instrument
    /// slot, just whichever FX stages `Session.master_fx` has active.
    pub fn setMasterChain(self: *Engine, devices: []const dsp.Device) void {
        self.master_chain.set(devices);
    }

    /// Same shape as `setTrackSidechainSources` but for the master chain.
    pub fn setMasterSidechainSources(self: *Engine, sources: []const ?Compressor.SidechainSource) void {
        replaceSidechainSlots(&self.master_sidechain_sources, sources);
    }

    /// Same shape as `setMasterChain` but for group submix bus `idx` - FX
    /// stages only, no instrument slot. `active` marks the group slot in use
    /// (`renderTracks` skips inactive slots entirely); called whenever
    /// `Session.groups[idx]` changes, same call-site convention
    /// `syncMasterChain` already follows for the master bus.
    pub fn setGroupChain(self: *Engine, idx: u8, active: bool, devices: []const dsp.Device) void {
        if (idx >= max_groups) return;
        const g = &self.groups[idx];
        g.active = active;
        g.chain.set(devices);
    }

    /// Same shape as `setTrackSidechainSources` but for group submix bus `idx`.
    pub fn setGroupSidechainSources(self: *Engine, idx: u8, sources: []const ?Compressor.SidechainSource) void {
        if (idx >= max_groups) return;
        replaceSidechainSlots(&self.groups[idx].sidechain_sources, sources);
    }

    pub fn send(self: *Engine, cmd: Command) bool {
        if (self.commands.push(cmd)) return true;
        _ = self.dropped_commands.fetchAdd(1, .monotonic);
        return false;
    }

    pub fn setTrackParam(self: *Engine, track: u16, id: u16, value: f32) bool {
        return self.send(.{ .set_track_param_abs = .{ .track = track, .id = id, .value = value } });
    }

    pub fn takeDroppedCommands(self: *Engine) u32 {
        return self.dropped_commands.swap(0, .acq_rel);
    }

    pub fn process(self: *Engine, out: []Sample) void {
        const frames: u32 = @intCast(out.len / channels);
        std.debug.assert(frames <= types.max_block_frames);

        self.drainCommands();
        @memset(out, 0.0);

        if (self.pre_roll_frames_remaining > 0) {
            // Count-in: click through the armed bar, no track audio, and
            // the transport itself stays stopped until it's done.
            self.firePreRoll(out, frames);
        } else {
            self.renderTracks(out, frames);
            if (self.metronome_enabled) self.fireMetronome(out, frames);
        }

        self.processChainWithSidechain(self.master_chain.slice(), &self.master_sidechain_sources, out, frames);

        for (out) |*s| s.* *= self.master_gain;
        self.limiter.processBlock(out);

        // Peaks measured post-limiter, so the meters show what actually
        // reaches the output.
        self.peak = .{ 0.0, 0.0 };
        var i: usize = 0;
        while (i < out.len) : (i += channels) {
            inline for (0..channels) |ch| {
                const mag = @abs(out[i + ch]);
                if (mag > self.peak[ch]) self.peak[ch] = mag;
            }
        }

        self.master_spectrum.push(out);
        self.master_spectrum.analyze();

        self.master_correlation.push(out);
        self.master_loudness.push(out);

        self.transport.advance(frames);

        self.shared.playing.store(self.transport.playing, .monotonic);
        self.shared.pre_rolling.store(self.pre_roll_frames_remaining > 0, .monotonic);
        self.shared.position_frames.store(self.transport.position_frames, .monotonic);
        inline for (0..channels) |ch| {
            self.shared.peak_bits[ch].store(@bitCast(self.peak[ch]), .monotonic);
        }
        self.shared.correlation_bits.store(@bitCast(self.master_correlation.value()), .monotonic);
        self.shared.lufs_momentary_bits.store(@bitCast(self.master_loudness.momentary()), .monotonic);
        self.shared.lufs_short_term_bits.store(@bitCast(self.master_loudness.shortTerm()), .monotonic);
        self.shared.lufs_integrated_bits.store(@bitCast(self.master_loudness.integrated()), .monotonic);
    }

    pub fn uiSnapshot(self: *const Engine) UiSnapshot {
        var snap: UiSnapshot = .{
            .playing = self.shared.playing.load(.monotonic),
            .pre_rolling = self.shared.pre_rolling.load(.monotonic),
            .position_frames = self.shared.position_frames.load(.monotonic),
            .peak = undefined,
            .correlation = @bitCast(self.shared.correlation_bits.load(.monotonic)),
            .lufs_momentary = @bitCast(self.shared.lufs_momentary_bits.load(.monotonic)),
            .lufs_short_term = @bitCast(self.shared.lufs_short_term_bits.load(.monotonic)),
            .lufs_integrated = @bitCast(self.shared.lufs_integrated_bits.load(.monotonic)),
        };
        inline for (0..channels) |ch| {
            snap.peak[ch] = @bitCast(self.shared.peak_bits[ch].load(.monotonic));
        }
        return snap;
    }

    /// Returns the current spectrum snapshot for the given track, or null if
    /// that track is not the one being analyzed (so a just-switched view never
    /// shows the previous track's bins). Relies on the analyzer's `active`
    /// atomic - no race on internal fields.
    pub fn trackSpectrumSnapshot(self: *const Engine, track: u16) ?SpectrumSnapshot {
        if (self.active_spectrum_source != .track or track != self.active_spectrum_track)
            return null;
        return self.track_spectrum.snapshot();
    }

    /// Same idea as `trackSpectrumSnapshot`, keyed by group index instead -
    /// shares the same reused `track_spectrum` analyzer (only one of
    /// track/master/group can be in view at a time).
    pub fn groupSpectrumSnapshot(self: *const Engine, group: u8) ?SpectrumSnapshot {
        if (self.active_spectrum_source != .group or group != self.active_spectrum_group)
            return null;
        return self.track_spectrum.snapshot();
    }

    pub fn masterSpectrumSnapshot(self: *const Engine) ?SpectrumSnapshot {
        return self.master_spectrum.snapshot();
    }

    fn drainCommands(self: *Engine) void {
        while (self.commands.pop()) |cmd| switch (cmd) {
            .play => self.transport.play(),
            .stop => {
                self.transport.stop();
                self.pre_roll_frames_remaining = 0; // cancel an in-flight count-in too
            },
            .seek_frames => |f| self.transport.seekFrames(f),
            .set_tempo => |bpm| self.transport.tempo_bpm = bpm,
            .set_time_signature => |bpb| self.transport.time_signature.beats_per_bar = bpb,
            .set_master_gain => |g| self.master_gain = g,
            .set_track_gain => |c| self.trackAt(c.track).gain = c.gain,
            .set_track_pan => |c| self.trackAt(c.track).pan = c.pan,
            .set_track_mute => |c| self.trackAt(c.track).muted = c.muted,
            .set_track_solo => |c| self.trackAt(c.track).soloed = c.soloed,
            .note_on => |c| self.sendTrackEvent(c.track, .{
                .note_on = .{ .note = c.note, .velocity = c.velocity },
            }),
            .note_off => |c| self.sendTrackEvent(c.track, .{
                .note_off = .{ .note = c.note },
            }),
            .all_notes_off => for (self.tracks) |*slot| {
                const t = slot.load(.acquire);
                for (t.chain.slice()) |dev| dev.sendEvent(.all_off);
            },
            // zig fmt: off
            .cc         => |c| self.sendTrackEvent(c.track, .{ .cc         = .{ .cc   = c.cc,   .value = c.value } }),
            // zig fmt: on
            .pitch_bend => |c| self.sendTrackEvent(c.track, .{ .pitch_bend = .{ .bend = c.bend } }),
            .set_track_param => |c| self.sendTrackEvent(c.track, .{ .set_param = .{ .id = c.id, .steps = c.steps } }),
            .set_track_param_abs => |c| self.sendTrackEvent(c.track, .{ .set_param_abs = .{ .id = c.id, .value = c.value } }),
            .set_clap_param => |c| self.sendTrackEvent(c.track, .{ .clap_param = .{
                .target = c.target,
                .id = c.id,
                .cookie = c.cookie,
                .value = c.value,
            } }),
            .set_track_group => |c| self.trackAt(c.track).group = c.group,
            .set_group_gain => |c| if (c.group < max_groups) {
                self.groups[c.group].gain = c.gain;
            },
            .set_loop => |c| {
                self.transport.loop_enabled = c.enabled;
                self.transport.loop_start_frames = c.start_frames;
                self.transport.loop_end_frames = c.end_frames;
            },
            .set_metronome => |v| self.metronome_enabled = v,
            .set_metronome_gain => |g| self.metronome.gain = g,
            .record => |bars| {
                if (bars == 0) {
                    self.transport.play();
                } else {
                    const bpb: f64 = @floatFromInt(self.transport.time_signature.beats_per_bar);
                    const total_beats = @as(f64, @floatFromInt(bars)) * bpb;
                    self.pre_roll_frames_remaining = @intFromFloat(total_beats * self.transport.framesPerBeat());
                    self.pre_roll_elapsed = 0;
                    self.pre_roll_next_beat = 0;
                }
            },
            .set_spectrum_active => |c| {
                // `.track` and `.group` sources share `track_spectrum`'s one
                // accumulator (see below), so a category change alone must
                // reset it too - comparing only the numeric index let a
                // switch from group N back to track N (or vice versa) skip
                // the reset, since both zero it out identically on a
                // `.none` transition in between. Compare against the OLD
                // source before it's overwritten.
                if (c.source != self.active_spectrum_source or
                    (c.source == .track and c.track != self.active_spectrum_track) or
                    (c.source == .group and c.group != self.active_spectrum_group))
                {
                    self.track_spectrum.accumulated = 0;
                }
                self.active_spectrum_source = c.source;
                self.active_spectrum_track = c.track;
                self.active_spectrum_group = c.group;
                self.track_spectrum.active.store(c.source == .track or c.source == .group, .release);
                self.master_spectrum.active.store(c.source == .master, .release);
            },
            .reset_loudness => self.master_loudness.resetIntegrated(),
        };
    }

    /// `pub` so tests elsewhere in the crate can reach a track's state
    /// without duplicating the pointer-indirection load.
    pub fn trackAt(self: *Engine, index: u16) *TrackState {
        return self.tracks[@min(index, max_tracks - 1)].load(.acquire);
    }

    fn sendTrackEvent(self: *Engine, track: u16, ev: dsp.Event) void {
        const state = self.trackAt(track);
        for (state.chain.slice()) |dev| dev.sendEvent(ev);
    }

    /// This block's captured signal for `track`, if it was registered and
    /// rendered as a sidechain-detector source (see `SidechainCapture`).
    /// Null means "no capture available" - either nothing points at `track`
    /// as a source, or it was registered but never rendered this block (an
    /// inactive/empty source track, or a same-block mutual-reference edge
    /// case where it hasn't rendered yet) - either way the caller's
    /// compressor falls back to self-detection, never stale samples and
    /// never a crash. The `captured` check is what makes that true: a
    /// registered-but-unrendered slot's `buf` holds a previous block's
    /// signal at best and uninitialized memory at worst.
    fn sidechainCapture(self: *Engine, src: Compressor.SidechainSource, frames: u32) ?[]const Sample {
        for (&self.sidechain_captures) |*c| {
            const key = c.source orelse continue;
            if (key.track == src.track and key.pad == src.pad and c.captured)
                return c.buf[0 .. frames * channels];
        }
        return null;
    }

    /// Runs `chain` over `buf`, injecting each slot's captured sidechain
    /// detector signal (if any) before that slot processes - shared body of
    /// the master/track/group render paths, which differ only in which
    /// chain, sidechain-source slots, and scratch buffer they pass in.
    fn processChainWithSidechain(
        self: *Engine,
        chain: []const dsp.Device,
        sidechain_sources: []const ?Compressor.SidechainSource,
        buf: []Sample,
        frames: u32,
    ) void {
        for (chain, 0..) |dev, slot| {
            if (sidechain_sources[slot]) |src| {
                if (self.sidechainCapture(src, frames)) |sc_buf| dev.sendEvent(.{ .set_sidechain_buf = .{ .buf = sc_buf } });
            }
            dev.process(buf);
        }
    }

    /// Register `src` as a sidechain-detector source to capture this block,
    /// if it isn't already and there's a free slot - extras past
    /// `max_sidechain_sources` are silently dropped, same "bank of 8"
    /// convention `max_synth_slots` already uses. A whole-track source
    /// (`pad == null`) and a specific pad on that same track are distinct
    /// keys - both can be registered and captured independently in one
    /// block.
    fn registerSidechainSource(self: *Engine, src: Compressor.SidechainSource) void {
        for (&self.sidechain_captures) |*c| {
            if (c.source) |key| if (key.track == src.track and key.pad == src.pad) return;
        }
        for (&self.sidechain_captures) |*c| {
            if (c.source == null) {
                c.source = src;
                return;
            }
        }
    }

    /// Render one track's instrument+FX chain and, unless muted/soloed-out,
    /// mix it into `out` or its group's accumulator. Extracted from
    /// `renderTracks` so the sidechain pre-pass (below) and the main loop
    /// can both call it - a track referenced as some compressor's detector
    /// source elsewhere in the mix must render exactly once, before any
    /// chain that reads its captured signal, never twice (that would
    /// double-tick a stateful instrument's envelopes/oscillator phase within
    /// one block).
    fn renderOneTrack(self: *Engine, ti: u16, out: []Sample, frames: u32, beat_pos: f64, any_solo: bool) void {
        const track = self.trackAt(ti);
        // One snapshot for this whole render pass - the control thread may
        // flip `track.chain`'s active buffer between calls to `slice()`, so
        // every use below must share the same snapshot rather than each
        // re-reading it (which could observe the chain change mid-render).
        const chain = track.chain.slice();
        if (!track.active or chain.len == 0) return;

        const auto = &self.automation[ti];
        // Instrument-param automation must reach the device before it
        // renders this block, unlike gain/pan below (a post-chain
        // multiplier) - push it through the same Event path
        // adjustParam/CC already use. Only fires for slots actually
        // holding a param this track (valueAt is null otherwise), so
        // tracks with no synth-param automation pay nothing extra.
        for (&auto.synth_slots) |*slot| {
            const pid = slot.param_id orelse continue;
            if (slot.curve.valueAt(beat_pos)) |val| {
                self.sendTrackEvent(ti, .{ .set_param_abs = .{ .id = pid, .value = val } });
            }
        }

        const scratch = self.scratch[0 .. frames * channels];
        @memset(scratch, 0.0);

        // If this track is referenced as some compressor's PER-PAD detector
        // source, broadcast a capture request to every device in the chain
        // before any of them process this block - only `DrumMachine` acts on
        // it (see `Event.capture_pad`'s doc comment), and it must see the
        // request before its own `process()` call below, regardless of
        // whether it sits at chain slot 0 (no pattern player) or 1. Zeroed
        // first so a pad that doesn't exist yields silence, not garbage.
        for (&self.sidechain_captures) |*c| {
            const src = c.source orelse continue;
            if (src.track != ti) continue;
            const pad = src.pad orelse continue;
            const dest = c.buf[0 .. frames * channels];
            @memset(dest, 0.0);
            for (chain) |dev| {
                dev.sendEvent(.{ .capture_pad = .{ .pad = pad, .buf = dest } });
            }
            // Mark it captured NOW rather than in the post-chain finalize
            // below: the instrument (the only device that fills `dest`)
            // always precedes any FX slot in the same chain, so a
            // compressor on this very track keyed to one of its own pads
            // (duck the drum bus off its own kick) reads a fully-rendered
            // buffer by the time its slot's injection runs - the
            // finalize-time flag made that case silently fall back to
            // self-detection. Cross-track readers only run after this
            // whole track finishes, so nothing reads any earlier than
            // before; a chain with no DrumMachine leaves the zeroed buffer
            // = a silent detector, the documented bad-pad convention.
            c.captured = true;
        }

        self.processChainWithSidechain(chain, &self.track_sidechain[ti], scratch, frames);

        // If this track is itself a registered sidechain-detector source,
        // finalize its capture now - before `scratch` gets reused by the
        // next track rendered. Captured regardless of mute/solo (a muted
        // track's audio is already computed above either way; a sidechain
        // key cares about the signal, not whether it's in the mix). A
        // whole-track source (`pad == null`) copies the finished post-chain
        // mix; a per-pad source's buffer was already filled above (during
        // the instrument's own `process()` call, via `capture_pad`) - just
        // mark it captured. Multiple slots can reference the same track
        // (different pads, or a pad alongside the whole track), so this
        // walks every slot rather than stopping at the first match.
        for (&self.sidechain_captures) |*c| {
            const src = c.source orelse continue;
            if (src.track != ti) continue;
            if (src.pad == null) @memcpy(c.buf[0 .. frames * channels], scratch);
            c.captured = true;
        }

        if (track.muted or (any_solo and !track.soloed)) return;

        const gain = auto.gain.valueAt(beat_pos) orelse track.gain;
        const pan = auto.pan.valueAt(beat_pos) orelse track.pan;
        const angle = (pan + 1.0) * std.math.pi / 4.0;
        const gain_l = gain * @cos(angle);
        const gain_r = gain * @sin(angle);

        // A grouped track (an active group assignment) submixes into its
        // group's accumulator instead of straight to `out` - the
        // group's own FX chain runs on the sum once every member has
        // contributed, below. Ungrouped tracks (the default, and any
        // track pointed at an inactive/removed group slot) are
        // unaffected - same "no override" fallback automation uses.
        const dest: []Sample = blk: {
            if (track.group) |gidx| {
                if (gidx < max_groups and self.groups[gidx].active) {
                    break :blk self.group_scratch[gidx][0 .. frames * channels];
                }
            }
            break :blk out;
        };
        for (0..frames) |i| {
            dest[i * channels] += scratch[i * channels] * gain_l;
            dest[i * channels + 1] += scratch[i * channels + 1] * gain_r;
        }

        if (self.active_spectrum_source == .track and
            ti == self.active_spectrum_track)
        {
            self.track_spectrum.push(scratch);
            self.track_spectrum.analyze();
        }
    }

    fn renderTracks(self: *Engine, out: []Sample, frames: u32) void {
        // When any track is soloed, only soloed tracks are audible.
        var any_solo = false;
        for (self.tracks) |*slot| {
            const t = slot.load(.acquire);
            if (t.active and t.soloed) {
                any_solo = true;
                break;
            }
        }

        // Block-start beat position, for gain/pan automation below. One
        // evaluation per block (not per sample) - plenty of resolution for a
        // parameter curve, same granularity the metronome's beat math uses.
        const beat_pos = @as(f64, @floatFromInt(self.transport.position_frames)) / self.transport.framesPerBeat();

        // Zero every active group's submix accumulator before tracks sum
        // into it below - same per-block-zero convention as the per-track
        // `scratch` buffer, just once per active group instead of per track.
        for (&self.groups, 0..) |*g, gi| {
            if (g.active) @memset(self.group_scratch[gi][0 .. frames * channels], 0.0);
        }

        // Sidechain pre-scan: which track indices does ANY compressor (own
        // chain, a group chain, or the master chain) reference as its
        // detector source this block? Registering (not capturing yet) is
        // cheap and the same "walk every slot, most are null" cost the
        // per-track loop below already pays.
        for (&self.sidechain_captures) |*c| {
            c.source = null;
            c.captured = false;
        }
        for (self.tracks, 0..) |*slot, ti| {
            const t = slot.load(.acquire);
            const clen = t.chain.slice().len;
            if (!t.active or clen == 0) continue;
            for (self.track_sidechain[ti][0..clen]) |src| {
                if (src) |s| self.registerSidechainSource(s);
            }
        }
        for (&self.groups) |*g| {
            if (!g.active) continue;
            for (g.sidechain_sources[0..g.chain.slice().len]) |src| {
                if (src) |s| self.registerSidechainSource(s);
            }
        }
        for (self.master_sidechain_sources[0..self.master_chain.slice().len]) |src| {
            if (src) |s| self.registerSidechainSource(s);
        }

        // Phase 1: fully render every registered source track FIRST (in
        // whatever order `sidechain_captures` collected them), so its
        // captured signal is ready before phase 2's consumers run. A source
        // that ALSO sidechains off another source registered after it (a
        // mutual/circular reference - rare, not a normal use case) simply
        // falls back to self-detection that block via `sidechainCapture`'s
        // null return, never a crash. Two slots can share the same track
        // (e.g. a kick-pad capture and a snare-pad capture on the same drum
        // track) - dedup against slots already handled earlier in this same
        // loop so that track still renders exactly once.
        for (&self.sidechain_captures, 0..) |*c, idx| {
            const ti = (c.source orelse continue).track;
            var dup = false;
            for (self.sidechain_captures[0..idx]) |prev| {
                if (prev.source) |ps| if (ps.track == ti) {
                    dup = true;
                    break;
                };
            }
            if (dup) continue;
            self.renderOneTrack(ti, out, frames, beat_pos, any_solo);
        }

        // Phase 2: every other track, in original order, skipping whatever
        // phase 1 already rendered (never render a track twice - see
        // renderOneTrack's own doc comment for why that matters). Iterates
        // by pointer (`&self.sidechain_captures`), not by value - each
        // capture embeds a `max_block_frames`-sized buffer, and copying that
        // 8 times per track (times max_tracks) would be a real per-block
        // cost, not just a style nit.
        for (0..max_tracks) |ti_usize| {
            const ti: u16 = @intCast(ti_usize);
            var already_done = false;
            for (&self.sidechain_captures) |*c| {
                if (c.source) |s| if (s.track == ti) {
                    already_done = true;
                    break;
                };
            }
            if (already_done) continue;
            self.renderOneTrack(ti, out, frames, beat_pos, any_solo);
        }

        // Each active group's FX chain applies to its submix, then the
        // result sums into `out` - the same shape `process()` applies
        // master_chain to the whole mix, one level up.
        for (&self.groups, 0..) |*g, gi| {
            if (!g.active) continue;
            const gscratch = self.group_scratch[gi][0 .. frames * channels];
            self.processChainWithSidechain(g.chain.slice(), &g.sidechain_sources, gscratch, frames);
            for (out, gscratch) |*o, s| o.* += s * g.gain;

            if (self.active_spectrum_source == .group and @as(u8, @intCast(gi)) == self.active_spectrum_group) {
                self.track_spectrum.push(gscratch);
                self.track_spectrum.analyze();
            }
        }
    }
};

const PolySynth = @import("../dsp/synth.zig").PolySynth;
const DrumMachine = @import("../dsp/drum_sampler.zig").DrumMachine;
const Compressor = @import("../dsp/compressor.zig").Compressor;

test "engine rejects a zero sample rate" {
    try std.testing.expectError(error.InvalidSampleRate, Engine.init(std.testing.allocator, 0));
}

test "renderTracks pushes filter-cutoff automation into the synth before it processes the block" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.filter_cutoff = 1_000.0; // manual value - automation should override it
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    engine.setTrackSynthParam(0, 21, &.{.{ .beat = 0.0, .value = 5_000.0 }});

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 5_000.0), synth.filter_cutoff, 1.0);

    // Clearing the curve (empty points) falls back to the manual value again
    // - matches gain/pan's own "no automation" fallback, not a frozen value.
    engine.setTrackSynthParam(0, 21, &.{});
    synth.filter_cutoff = 1_000.0;
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1_000.0), synth.filter_cutoff, 1.0);
}

test "renderTracks handles multiple simultaneous synth-param automation slots" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    engine.setTrackSynthParam(0, 21, &.{.{ .beat = 0.0, .value = 5_000.0 }}); // filter cutoff
    engine.setTrackSynthParam(0, 29, &.{.{ .beat = 0.0, .value = 8.0 }}); // lfo rate
    engine.setTrackSynthParam(0, 34, &.{.{ .beat = 0.0, .value = 0.5 }}); // sub level

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 5_000.0), synth.filter_cutoff, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), synth.lfo_rate_hz, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), synth.sub_level, 1e-3);

    // Clearing one slot frees it without disturbing the other two.
    engine.setTrackSynthParam(0, 29, &.{});
    synth.lfo_rate_hz = 1.0;
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), synth.lfo_rate_hz, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 5_000.0), synth.filter_cutoff, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), synth.sub_level, 1e-3);
}

test "setTrackSynthParam covers the complete persisted parameter id space" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    for (0..max_synth_slots) |i| {
        engine.setTrackSynthParam(0, @intCast(i), &.{.{ .beat = 0.0, .value = 1.0 }});
    }
    const pair = &engine.automation[0];
    for (pair.synth_slots) |slot| try std.testing.expect(slot.param_id != null);
}

test "notes sound even while transport is stopped (live preview)" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);

    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    engine.process(&block);
    try std.testing.expect(engine.peak[0] > 0.01);
    try std.testing.expectEqual(@as(u64, 0), engine.transport.position_frames);
}

test "transport advances only while playing" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var block: [512]Sample = undefined;

    engine.process(&block);
    try std.testing.expectEqual(@as(u64, 0), engine.transport.position_frames);

    _ = engine.send(.play);
    engine.process(&block);
    try std.testing.expectEqual(@as(u64, 256), engine.transport.position_frames);
}

test "metronome only clicks while enabled and playing" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var block: [512]Sample = undefined;

    _ = engine.send(.play);
    engine.process(&block); // enabled = false: silent
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);

    _ = engine.send(.{ .set_metronome = true });
    engine.process(&block); // first block always crosses beat 0
    try std.testing.expect(engine.peak[0] > 0.0);
}

test "metronome accents beat 1 of every bar" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    _ = engine.send(.{ .set_metronome = true });
    _ = engine.send(.play);

    var block: [64]Sample = undefined;
    engine.process(&block); // fires beat 0 (the downbeat) at frame 0
    try std.testing.expect(engine.metronome.is_accent);
}

test "record count-in clicks immediately, keeps the transport stopped, then starts on the beat" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    _ = engine.send(.{ .record = 1 });

    // 512-Sample blocks are stereo-interleaved -> 256 frames/block. 120bpm
    // 4/4 at 48kHz is 96_000 frames (375 blocks) per bar.
    var block: [512]Sample = undefined;
    engine.process(&block); // clicks the downbeat immediately
    try std.testing.expect(engine.peak[0] > 0.0);
    try std.testing.expect(!engine.transport.playing);

    for (0..98) |_| engine.process(&block); // 99 blocks total = 25_344 frames - well short
    try std.testing.expect(!engine.transport.playing);

    for (0..300) |_| engine.process(&block); // +76_800 frames - comfortably past the bar
    try std.testing.expect(engine.transport.playing);
    try std.testing.expectEqual(@as(u64, 0), engine.pre_roll_frames_remaining);
}

test "record count-in clicks even when the regular metronome is off" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    try std.testing.expect(!engine.metronome_enabled);

    _ = engine.send(.{ .record = 1 });
    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.peak[0] > 0.0);
}

test "record with 0 bars skips the count-in and starts playback immediately" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    _ = engine.send(.{ .record = 0 });

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.transport.playing);
    try std.testing.expectEqual(@as(u64, 0), engine.pre_roll_frames_remaining);
}

test "record with 2 bars clicks through twice the frames of a 1-bar count-in" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    _ = engine.send(.{ .record = 2 });

    var block: [512]Sample = undefined;
    engine.process(&block);
    // 120bpm 4/4 at 48kHz is 96_000 frames/bar; 512 stereo-interleaved
    // Samples = 256 frames, already consumed by this first block.
    try std.testing.expectEqual(@as(u64, 96_000 * 2 - 256), engine.pre_roll_frames_remaining);
}

test "stop cancels an in-flight record count-in" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    _ = engine.send(.{ .record = 1 });
    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.pre_roll_frames_remaining > 0);

    _ = engine.send(.stop);
    engine.process(&block);
    try std.testing.expectEqual(@as(u64, 0), engine.pre_roll_frames_remaining);
    try std.testing.expect(!engine.transport.playing);
}

test "uiSnapshot reports pre_rolling during count-in, then playing once it completes" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    _ = engine.send(.{ .record = 1 });

    var block: [512]Sample = undefined;
    engine.process(&block);
    var snap = engine.uiSnapshot();
    try std.testing.expect(snap.pre_rolling);
    try std.testing.expect(!snap.playing);

    for (0..400) |_| engine.process(&block); // well past the one-bar count-in (375 blocks)
    snap = engine.uiSnapshot();
    try std.testing.expect(!snap.pre_rolling);
    try std.testing.expect(snap.playing);
}

test "mute command silences a track" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .set_track_mute = .{ .track = 0, .muted = true } });

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);
}

test "master limiter keeps a hot mix under the ceiling" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .set_master_gain = 16.0 }); // way past clipping
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });

    var block: [512]Sample = undefined;
    var loudest: f32 = 0.0;
    for (0..8) |_| {
        engine.process(&block);
        for (block) |s| loudest = @max(loudest, @abs(s));
    }
    try std.testing.expect(loudest > 0.5); // audible…
    try std.testing.expect(loudest <= engine.limiter.ceiling + 1e-4); // …not clipped
}

test "master FX chain processes the summed mix before gain/limiter" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block); // let the synth's envelope settle in
    var loud: f32 = 0.0;
    for (block) |s| loud = @max(loud, @abs(s));

    // A master compressor riding near-instantly on a very low threshold and
    // steep ratio should crush the level well below the uncompressed pass.
    var comp = Compressor.init(48_000);
    comp.threshold_db = -60.0;
    comp.ratio = 20.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 0.1;
    engine.setMasterChain(&.{comp.device()});

    var block2: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block2);
    var quiet: f32 = 0.0;
    for (block2) |s| quiet = @max(quiet, @abs(s));

    try std.testing.expect(loud > 0.05);
    try std.testing.expect(quiet < loud * 0.5);
}

test "grouped tracks submix through their group's FX chain; ungrouped tracks are unaffected" {
    var synth1 = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth1.deinit();
    var synth2 = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth2.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.trackAt(1).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth1.device()});
    engine.setTrackChain(1, &.{synth2.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 1.0 } });

    var comp = Compressor.init(48_000);
    comp.threshold_db = -60.0;
    comp.ratio = 20.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 0.1;
    engine.setGroupChain(0, true, &.{comp.device()});
    _ = engine.send(.{ .set_track_group = .{ .track = 0, .group = 0 } }); // track 1 stays ungrouped

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block); // let envelopes settle

    // Solo each track in turn to measure its own contribution to `out`.
    _ = engine.send(.{ .set_track_solo = .{ .track = 0, .soloed = true } });
    for (0..4) |_| engine.process(&block);
    var grouped_loud: f32 = 0.0;
    for (block) |s| grouped_loud = @max(grouped_loud, @abs(s));

    _ = engine.send(.{ .set_track_solo = .{ .track = 0, .soloed = false } });
    _ = engine.send(.{ .set_track_solo = .{ .track = 1, .soloed = true } });
    for (0..4) |_| engine.process(&block);
    var ungrouped_loud: f32 = 0.0;
    for (block) |s| ungrouped_loud = @max(ungrouped_loud, @abs(s));

    try std.testing.expect(ungrouped_loud > 0.05); // reaches `out` at all - routing works
    try std.testing.expect(grouped_loud < ungrouped_loud * 0.5); // crushed by the group's compressor
}

test "renderTracks routes a compressor's sidechain detector from a different (source) track" {
    var kick = try PolySynth.init(std.testing.allocator, 48_000);
    defer kick.deinit();
    var bass = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass.deinit();
    var comp = Compressor.init(48_000);
    comp.threshold_db = -30.0;
    comp.ratio = 20.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 0.1;

    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true }; // kick (sidechain source)
    engine.trackAt(1).* = .{ .active = true }; // bass (has the compressor)
    engine.setTrackChain(0, &.{kick.device()});
    engine.setTrackChain(1, &.{ bass.device(), comp.device() });
    // slot 0 (bass itself) has no sidechain; slot 1 (comp) detects from track 0.
    engine.setTrackSidechainSources(1, &.{ null, .{ .track = 0 } });

    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } }); // loud kick
    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 0.02 } }); // quiet bass, well under threshold on its own

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block); // let envelopes settle

    _ = engine.send(.{ .set_track_solo = .{ .track = 1, .soloed = true } });
    for (0..4) |_| engine.process(&block);
    var bass_with_sidechain: f32 = 0.0;
    for (block) |s| bass_with_sidechain = @max(bass_with_sidechain, @abs(s));

    // Remove the routing - same quiet bass note, but the compressor now
    // self-detects its own (quiet, under-threshold) input, so it should
    // barely touch the level.
    engine.setTrackSidechainSources(1, &.{});
    for (0..4) |_| engine.process(&block);
    var bass_without_sidechain: f32 = 0.0;
    for (block) |s| bass_without_sidechain = @max(bass_without_sidechain, @abs(s));

    try std.testing.expect(bass_without_sidechain > 0.001); // a real, measurable signal
    try std.testing.expect(bass_with_sidechain < bass_without_sidechain * 0.5);
}

test "renderTracks routes a compressor's sidechain detector from a single drum pad, isolated from the rest of the kit" {
    var bass = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass.deinit();
    var comp = Compressor.init(48_000);
    comp.threshold_db = -30.0;
    comp.ratio = 20.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 0.1;

    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var drum = try DrumMachine.init(std.testing.allocator, 48_000, &engine.transport);
    defer drum.deinit();
    engine.trackAt(0).* = .{ .active = true }; // drum kit (sidechain source)
    engine.trackAt(1).* = .{ .active = true }; // bass (has the compressor)
    engine.setTrackChain(0, &.{drum.device()});
    engine.setTrackChain(1, &.{ bass.device(), comp.device() });
    // slot 0 (bass itself) has no sidechain; slot 1 (comp) detects from
    // track 0's pad 0 (the kick) specifically, not its whole mix.
    engine.setTrackSidechainSources(1, &.{ null, .{ .track = 0, .pad = 0 } });

    // Hit pad 0 (kick) loud; leave every other pad untriggered.
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 0, .velocity = 1.0 } });
    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 0.02 } }); // quiet bass

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block);
    _ = engine.send(.{ .set_track_solo = .{ .track = 1, .soloed = true } });
    for (0..4) |_| engine.process(&block);
    var bass_ducked_by_kick: f32 = 0.0;
    for (block) |s| bass_ducked_by_kick = @max(bass_ducked_by_kick, @abs(s));

    // Self-detection baseline: same quiet bass, no sidechain routing.
    var bass2 = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass2.deinit();
    var comp2 = Compressor.init(48_000);
    comp2.threshold_db = -30.0;
    comp2.ratio = 20.0;
    comp2.attack_ms = 0.1;
    comp2.release_ms = 0.1;
    var engine2 = try Engine.init(std.testing.allocator, 48_000);
    defer engine2.deinit();
    engine2.trackAt(1).* = .{ .active = true };
    engine2.setTrackChain(1, &.{ bass2.device(), comp2.device() });
    _ = engine2.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 0.02 } });
    var baseline: [512]Sample = undefined;
    for (0..4) |_| engine2.process(&baseline);
    var bass_undisturbed: f32 = 0.0;
    for (baseline) |s| bass_undisturbed = @max(bass_undisturbed, @abs(s));

    try std.testing.expect(bass_undisturbed > 0.001); // a real, measurable signal
    try std.testing.expect(bass_ducked_by_kick < bass_undisturbed * 0.5);

    // Now hit a DIFFERENT pad (snare) loud instead, leaving the kick (pad 0,
    // still the compressor's detector source) silent. Inspect the engine's
    // own capture buffer directly rather than the bass's output - comparing
    // downstream audio across separately-constructed PolySynth instances
    // would just be re-testing PolySynth's determinism, not this feature.
    // The capture for (track 0, pad 0) must stay silent even though the
    // snare made the REST of the drum track loud.
    var bass3 = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass3.deinit();
    var comp3 = Compressor.init(48_000);
    var engine3 = try Engine.init(std.testing.allocator, 48_000);
    defer engine3.deinit();
    var drum3 = try DrumMachine.init(std.testing.allocator, 48_000, &engine3.transport);
    defer drum3.deinit();
    engine3.trackAt(0).* = .{ .active = true };
    engine3.trackAt(1).* = .{ .active = true };
    engine3.setTrackChain(0, &.{drum3.device()});
    engine3.setTrackChain(1, &.{ bass3.device(), comp3.device() });
    engine3.setTrackSidechainSources(1, &.{ null, .{ .track = 0, .pad = 0 } });
    _ = engine3.send(.{ .note_on = .{ .track = 0, .note = 1, .velocity = 1.0 } }); // snare, not kick

    var block3: [512]Sample = undefined;
    engine3.process(&block3);

    // The snare made the whole drum track audible...
    var drum_peak: f32 = 0.0;
    for (block3) |s| drum_peak = @max(drum_peak, @abs(s));
    try std.testing.expect(drum_peak > 0.05);

    // ...but pad 0's own capture (what the compressor actually reads) is
    // silent, since the kick itself was never triggered.
    var cap_peak: f32 = 0.0;
    for (&engine3.sidechain_captures) |*c| {
        const src = c.source orelse continue;
        if (src.track == 0 and src.pad != null and src.pad.? == 0 and c.captured) {
            for (c.buf[0 .. 512 * channels]) |s| cap_peak = @max(cap_peak, @abs(s));
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cap_peak, 1e-6);
}

test "a compressor keyed to a pad on its OWN track reads the pad, not self-detection" {
    // The drum track compresses ITSELF, keyed off its own (silent) kick pad
    // while the snare plays loud. Keyed correctly, the detector hears
    // silence and the loud snare passes uncompressed; the old finalize-time
    // captured flag made same-track pad keys fall back to self-detection,
    // which would squash the snare hard.
    var comp = Compressor.init(48_000);
    comp.threshold_db = -30.0;
    comp.ratio = 20.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 0.1;
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var drum = try DrumMachine.init(std.testing.allocator, 48_000, &engine.transport);
    defer drum.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{ drum.device(), comp.device() });
    engine.setTrackSidechainSources(0, &.{ null, .{ .track = 0, .pad = 0 } });
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 1, .velocity = 1.0 } }); // snare, kick silent

    var block: [512]Sample = undefined;
    engine.process(&block);
    var keyed_peak: f32 = 0.0;
    for (block) |s| keyed_peak = @max(keyed_peak, @abs(s));

    // Identical setup, self-detecting (no routing): the loud snare drives
    // the envelope and gets squashed.
    var comp2 = Compressor.init(48_000);
    comp2.threshold_db = -30.0;
    comp2.ratio = 20.0;
    comp2.attack_ms = 0.1;
    comp2.release_ms = 0.1;
    var engine2 = try Engine.init(std.testing.allocator, 48_000);
    defer engine2.deinit();
    var drum2 = try DrumMachine.init(std.testing.allocator, 48_000, &engine2.transport);
    defer drum2.deinit();
    engine2.trackAt(0).* = .{ .active = true };
    engine2.setTrackChain(0, &.{ drum2.device(), comp2.device() });
    _ = engine2.send(.{ .note_on = .{ .track = 0, .note = 1, .velocity = 1.0 } });

    var block2: [512]Sample = undefined;
    engine2.process(&block2);
    var self_peak: f32 = 0.0;
    for (block2) |s| self_peak = @max(self_peak, @abs(s));

    try std.testing.expect(self_peak > 0.001); // still audible, just compressed
    try std.testing.expect(keyed_peak > self_peak * 1.5); // uncompressed vs squashed
}

test "a sidechain source that never renders falls back to self-detection, not a stale buffer" {
    // Track 1's compressor points at track 0 as its detector, but track 0 is
    // inactive: it gets REGISTERED in the capture bank every block yet never
    // renders into it. The compressor must behave exactly as if it had no
    // sidechain routing at all (self-detecting a quiet, under-threshold
    // input), never reading the capture slot's uninitialized buffer.
    var bass = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass.deinit();
    var comp = Compressor.init(48_000);
    comp.threshold_db = -30.0;
    comp.ratio = 20.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 0.1;

    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(1).* = .{ .active = true }; // track 0 stays inactive on purpose
    engine.setTrackChain(1, &.{ bass.device(), comp.device() });
    engine.setTrackSidechainSources(1, &.{ null, .{ .track = 0 } });

    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 0.02 } });
    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block);
    var with_dead_source: f32 = 0.0;
    for (block) |s| with_dead_source = @max(with_dead_source, @abs(s));

    // Same setup with the routing cleared: the self-detection baseline.
    var bass2 = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass2.deinit();
    var comp2 = Compressor.init(48_000);
    comp2.threshold_db = -30.0;
    comp2.ratio = 20.0;
    comp2.attack_ms = 0.1;
    comp2.release_ms = 0.1;
    var engine2 = try Engine.init(std.testing.allocator, 48_000);
    defer engine2.deinit();
    engine2.trackAt(1).* = .{ .active = true };
    engine2.setTrackChain(1, &.{ bass2.device(), comp2.device() });

    _ = engine2.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 0.02 } });
    var block2: [512]Sample = undefined;
    for (0..4) |_| engine2.process(&block2);

    try std.testing.expectEqualSlices(Sample, &block2, &block);
}

test "a sidechain source track is rendered exactly once, not double-mixed" {
    // Engine A: track 0 alone, referenced by nothing.
    var kick_a = try PolySynth.init(std.testing.allocator, 48_000);
    defer kick_a.deinit();
    var engine_a = try Engine.init(std.testing.allocator, 48_000);
    defer engine_a.deinit();
    engine_a.trackAt(0).* = .{ .active = true };
    engine_a.setTrackChain(0, &.{kick_a.device()});
    _ = engine_a.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    var block_a: [512]Sample = undefined;
    for (0..4) |_| engine_a.process(&block_a);

    // Engine B: identical track 0, plus a second track whose compressor
    // sidechains off it - this makes track 0 a phase-1 source. Soloing
    // track 0 isolates its own contribution to `out`, which must be
    // bit-identical to engine A's (same devices, same command sequence) -
    // any drift would mean it got rendered twice (or with different state)
    // this block.
    var kick_b = try PolySynth.init(std.testing.allocator, 48_000);
    defer kick_b.deinit();
    var bass_b = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass_b.deinit();
    var comp_b = Compressor.init(48_000);
    var engine_b = try Engine.init(std.testing.allocator, 48_000);
    defer engine_b.deinit();
    engine_b.trackAt(0).* = .{ .active = true };
    engine_b.trackAt(1).* = .{ .active = true };
    engine_b.setTrackChain(0, &.{kick_b.device()});
    engine_b.setTrackChain(1, &.{ bass_b.device(), comp_b.device() });
    engine_b.setTrackSidechainSources(1, &.{ null, .{ .track = 0 } });
    _ = engine_b.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine_b.send(.{ .set_track_solo = .{ .track = 0, .soloed = true } });
    var block_b: [512]Sample = undefined;
    for (0..4) |_| engine_b.process(&block_b);

    try std.testing.expectEqualSlices(Sample, &block_a, &block_b);
}

test "a track pointed at an inactive group slot falls back to the master mix" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true, .group = 2 }; // group 2 never activated
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block);
    var loud: f32 = 0.0;
    for (block) |s| loud = @max(loud, @abs(s));
    try std.testing.expect(loud > 0.05); // still reaches `out`, not silently dropped
}

test "solo silences other tracks but keeps the soloed one" {
    var lead = try PolySynth.init(std.testing.allocator, 48_000);
    defer lead.deinit();
    var pad = try PolySynth.init(std.testing.allocator, 48_000);
    defer pad.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.trackAt(1).* = .{ .active = true };
    engine.setTrackChain(0, &.{lead.device()});
    engine.setTrackChain(1, &.{pad.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 64, .velocity = 1.0 } });
    _ = engine.send(.{ .set_track_solo = .{ .track = 1, .soloed = true } });

    var block: [512]Sample = undefined;
    engine.process(&block);
    // track 1 is soloed, so audio is present...
    try std.testing.expect(engine.peak[0] > 0.01);

    // ...but unsoloing track 1 (no track soloed) restores both - sanity that
    // the gate is the solo state, not a permanent mute.
    _ = engine.send(.{ .set_track_solo = .{ .track = 1, .soloed = false } });
    engine.process(&block);
    try std.testing.expect(engine.peak[0] > 0.01);
}

test "uiSnapshot publishes transport and meter state" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.play);
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });

    var block: [512]Sample = undefined;
    engine.process(&block);

    const snap = engine.uiSnapshot();
    try std.testing.expect(snap.playing);
    try std.testing.expectEqual(@as(u64, 256), snap.position_frames);
    try std.testing.expect(snap.peak[0] > 0.01);
}

test "spectrum snapshot returns null when inactive" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.masterSpectrumSnapshot() == null);
}

test "spectrum snapshot returns data when active" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .set_spectrum_active = .{ .source = .track, .track = 0 } });

    var block: [512]Sample = undefined;
    for (0..10) |_| engine.process(&block);

    const snap = engine.trackSpectrumSnapshot(0);
    try std.testing.expect(snap != null);
    var has_signal = false;
    for (snap.?.bins) |b| {
        if (b > -80.0) has_signal = true;
    }
    try std.testing.expect(has_signal);
}

test "loadProject mirrors track settings" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    _ = try project.addTrack(.{ .name = "a", .gain_db = -6.0206, .pan = -1.0 });

    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.loadProject(&project);

    try std.testing.expect(engine.trackAt(0).*.active);
    try std.testing.expect(!engine.trackAt(1).*.active);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), engine.trackAt(0).*.gain, 1e-4);
}

test "applyInsertTrack shifts drum and inits new slot" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();

    engine.trackAt(0).* = .{ .active = true, .gain = 0.5 }; // lead
    engine.trackAt(1).* = .{ .active = true, .gain = 0.8 }; // drum at slot 1

    // Insert before drum (at idx=1, 2 tracks present)
    engine.applyInsertTrack(1, 2, 1.0, 0.0, false);

    try std.testing.expect(engine.trackAt(1).*.active);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), engine.trackAt(1).*.gain, 1e-6);
    try std.testing.expectEqual(@as(usize, 0), engine.trackAt(1).*.chain.slice().len);
    // Drum shifted to slot 2
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), engine.trackAt(2).*.gain, 1e-6);
}

test "applyInsertTrack in the middle shifts every later slot" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();

    engine.trackAt(0).* = .{ .active = true, .gain = 0.1 };
    engine.trackAt(1).* = .{ .active = true, .gain = 0.2 };
    engine.trackAt(2).* = .{ .active = true, .gain = 0.3 };

    engine.applyInsertTrack(1, 3, 1.0, 0.0, false);

    try std.testing.expectApproxEqAbs(@as(f32, 0.1), engine.trackAt(0).*.gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), engine.trackAt(1).*.gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), engine.trackAt(2).*.gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), engine.trackAt(3).*.gain, 1e-6);
}

test "applyDeleteTrack shifts tracks down" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();

    engine.trackAt(0).* = .{ .active = true, .gain = 0.1 };
    engine.trackAt(1).* = .{ .active = true, .gain = 0.2 }; // deleted
    engine.trackAt(2).* = .{ .active = true, .gain = 0.3 };
    engine.trackAt(3).* = .{ .active = true, .gain = 0.4 }; // drum

    engine.applyDeleteTrack(1, 4);

    try std.testing.expectApproxEqAbs(@as(f32, 0.1), engine.trackAt(0).*.gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), engine.trackAt(1).*.gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), engine.trackAt(2).*.gain, 1e-6);
    try std.testing.expect(!engine.trackAt(3).*.active); // cleared
}

test "applyDeleteTrack shifts the parallel automation and sidechain rows with the tracks" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();

    engine.trackAt(0).* = .{ .active = true };
    engine.trackAt(1).* = .{ .active = true }; // deleted
    engine.trackAt(2).* = .{ .active = true };

    engine.setTrackAutomation(2, .gain, &.{.{ .beat = 0.0, .value = 0.7 }});
    engine.setTrackSynthParam(2, 21, &.{.{ .beat = 0.0, .value = 5_000.0 }});
    engine.setTrackSidechainSources(2, &.{ null, .{ .track = 7 } });

    engine.applyDeleteTrack(1, 3);

    // Track 2's rows moved down to slot 1 alongside its TrackState...
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), engine.automation[1].gain.valueAt(0.0).?, 1e-6);
    try std.testing.expectEqual(@as(?u8, 21), engine.automation[1].synth_slots[21].param_id);
    try std.testing.expectEqual(@as(u16, 7), engine.track_sidechain[1][1].?.track);
    // ...and the vacated last slot is fully cleared, not left stale.
    try std.testing.expect(engine.automation[2].gain.valueAt(0.0) == null);
    try std.testing.expectEqual(@as(?u8, null), engine.automation[2].synth_slots[21].param_id);
    try std.testing.expectEqual(@as(?Compressor.SidechainSource, null), engine.track_sidechain[2][1]);
}

test "swapTracks exchanges the parallel automation and sidechain rows too" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();

    engine.trackAt(0).* = .{ .active = true };
    engine.trackAt(1).* = .{ .active = true };
    engine.setTrackAutomation(0, .pan, &.{.{ .beat = 0.0, .value = -0.5 }});
    engine.setTrackSidechainSources(1, &.{.{ .track = 3 }});

    engine.swapTracks(0, 1);

    try std.testing.expectApproxEqAbs(@as(f32, -0.5), engine.automation[1].pan.valueAt(0.0).?, 1e-6);
    try std.testing.expect(engine.automation[0].pan.valueAt(0.0) == null);
    try std.testing.expectEqual(@as(u16, 3), engine.track_sidechain[0][0].?.track);
    try std.testing.expectEqual(@as(?Compressor.SidechainSource, null), engine.track_sidechain[1][0]);
}
