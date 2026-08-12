const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("../dsp/device.zig");
const spectrum_mod = @import("../dsp/spectrum.zig");
const Spsc = @import("../core/ring_buffer.zig").Spsc;
const Limiter = @import("../dsp/limiter.zig").Limiter;
const Metronome = @import("../dsp/metronome.zig").Metronome;
const Sampler = @import("../dsp/sampler.zig").Sampler;
const Transport = @import("../transport.zig").Transport;
const Project = @import("../project.zig").Project;
const automation_mod = @import("../dsp/automation.zig");
const AutomationPoint = automation_mod.AutomationPoint;
const AutomationCurve = automation_mod.AutomationCurve;
const meter_mod = @import("../dsp/meter.zig");
const time_map = @import("../time_map.zig");
const arrangement = @import("../arrangement.zig");

const Sample = types.Sample;
const SpectrumAnalyzer = spectrum_mod.SpectrumAnalyzer;
const SpectrumSnapshot = spectrum_mod.SpectrumSnapshot;
const StereoCorrelation = meter_mod.StereoCorrelation;
const LoudnessMeter = meter_mod.LoudnessMeter;

pub const max_tracks = 8192;
/// Must cover Rack.chain_cap; setTrackChain silently truncates past it.
pub const max_chain_devices = 26;
pub const channels = 2;
/// Track-grouping submix buses (see `TrackState.group`, `renderTracks`'s
/// two-stage grouped-track routing). A real UI-relevant count, not
/// max_tracks' generous headroom - but still comfortably bigger than a
/// typical session's drum/vox/synth/fx-return buses need.
pub const max_groups: u8 = 16;
pub const max_sends_per_track = @import("../project.zig").max_sends_per_track;

pub const SpectrumSource = enum { none, track, master, group };

pub const Command = union(enum) {
    play,
    stop,
    seek_frames: u64,
    set_tempo: f64,
    set_time_signature: u8,
    set_meter_denominator: u8,
    set_tempo_point: time_map.TempoPoint,
    set_meter_point: time_map.MeterPoint,
    clear_time_map,
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
    set_track_mod_target: struct { track: u16, row: u8, id: u16, instance_id: u32 },
    set_clap_param: struct { track: u16, target: *anyopaque, id: u32, cookie: ?*anyopaque, value: f64 },
    /// Same as `set_clap_param`, for a CLAP unit that could be sitting on
    /// any chain (track, group, or master), not just hosted as a track's
    /// instrument - the FX param-grid editor's knob/drag edits use this
    /// one. Broadcasts (see `broadcastEvent`) rather than routing through
    /// a specific track, since `target` alone already picks out the exact
    /// plugin instance regardless of which chain it lives on.
    set_clap_param_any: struct { target: *anyopaque, id: u32, cookie: ?*anyopaque, value: f64 },
    /// VST3 counterpart to `set_clap_param_any`.
    set_vst3_param_any: struct { target: *anyopaque, id: u32, value: f64 },
    /// Which group (if any) `track` submixes through before the master bus.
    /// `null` routes straight to master, same as before grouping existed.
    set_track_group: struct { track: u16, group: ?u8 },
    /// Group submix bus fader (linear, post-FX-chain - see `GroupState.gain`).
    set_group_gain: struct { group: u8, gain: f32 },
    /// Group submix bus mute - see `GroupState.muted`.
    set_group_mute: struct { group: u8, muted: bool },
    /// Group submix bus solo - see `GroupState.soloed`.
    set_group_solo: struct { group: u8, soloed: bool },
    /// `group` is only read when `source == .group` (reuses `track` as the
    /// generic focus index otherwise, unchanged) - same one-analyzer-at-a-
    /// time model track/master already share, see `Engine.track_spectrum`.
    /// `target` identifies the specific EQ device instance the analyzer
    /// should tap pre/post around (its `dsp.Device.ptr`, i.e. `*ParametricEq`
    /// cast to `*anyopaque`) - null falls back to tapping the whole chain's
    /// end, same as before this field existed. See `Engine.SpectrumTap`.
    set_spectrum_active: struct { source: SpectrumSource, track: u16, group: u8 = 0, target: ?*anyopaque = null },
    /// Whether the active spectrum analyzer taps before (true) or after
    /// (false) the `target` device set above.
    set_spectrum_pre: bool,
    /// A/B loop region (frames). See Transport.advance for the wrap.
    set_loop: struct { enabled: bool, start_frames: u64, end_frames: u64 },
    set_metronome: bool,
    /// See `wstudio.o.metronome_click_gain`.
    set_metronome_gain: f32,
    /// Master limiter shape, from `wstudio.o.master_limiter_ceiling_db` (sent
    /// already converted to linear) and `master_limiter_release_ms`.
    set_limiter: struct { ceiling: f32, release_ms: f32 },
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
    /// Play the clip currently loaded into `Engine.preview` (the file
    /// browser's audition). Load the clip control-side first - `preview` is
    /// a plain Sampler, so `loadWav` takes its pad lock the same way a
    /// track's does; only the trigger has to come over the queue.
    preview_play,
    preview_stop,
};

/// Which absolute value an `AutomationCurve` overrides. `gain`/`pan` are
/// mix-bus params, applied as a post-chain multiplier in `renderTracks`.
/// Synth-instrument params (filter cutoff, LFO rate, envelope times, ...)
/// don't go through this enum - see `setTrackSynthParam`/`SynthAutomationSlot`
/// below, since there are ~30 of them and most tracks only automate a few at
/// once (a fixed per-param field the way `gain`/`pan` work would preallocate
/// far more than any project uses - see `TrackAutomation`'s own doc comment).
pub const AutomationTarget = enum { gain, pan };

/// Every parameter id representable by the persisted automation model gets a
/// slot. Curves allocate their point buffers only when used, so complete id
/// coverage no longer implies a fixed point-buffer cost per track.
pub const max_synth_slots = 256;
const max_parameter_events = 64;
const max_sample_accurate_lanes = 4;

/// One instrument-param automation slot. Array index is parameter id;
/// `active` lets audio thread skip empty curves without racing control-side
/// rebuilds.
const SynthAutomationSlot = struct {
    active: std.atomic.Value(bool) = .init(false),
    param_id: std.atomic.Value(u32) = .init(0),
    /// 0 targets the track's instrument, nonzero a specific FX unit's
    /// `instance_id` - see `dsp.Event.automation_param`'s doc comment.
    instance_id: std.atomic.Value(u32) = .init(0),
    curve: AutomationCurve = .{},
};

const ParameterEvent = struct {
    offset: u32,
    event: dsp.Event,
};

/// A device chain (track/master/group FX chain) as read by the audio
/// thread while the control thread may replace it wholesale. The graph
/// mutation gate excludes concurrent reads during publication. `dsp.Device`
/// is a two-word ptr+vtable
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
    pdc: TrackDelay = .{},
    send_pdc: [max_sends_per_track]TrackDelay = [_]TrackDelay{.{}} ** max_sends_per_track,
    audio_lane: ?*AudioLane = null,
};

pub const AudioRegion = struct {
    start_frame: u64,
    end_frame: u64,
    source_start_frame: u64,
    source_length_frames: u64,
    source_sample_rate: u32,
    channel_count: u16,
    gain: f32 = 1.0,
    fade_in_frames: u64 = 0,
    fade_out_frames: u64 = 0,
    fade_curve: arrangement.FadeCurve = .linear,
    stretch_ratio: f32 = 1.0,
    reverse: bool = false,
    samples: []const Sample,
};

const AudioLane = struct {
    regions: []AudioRegion,
};

/// Bounded per-track delay used to align primary mix routes. Storage is
/// allocated on the control thread only when some track reports latency.
const max_pdc_frames: usize = 8192;
const pdc_samples = (max_pdc_frames + 1) * channels;
const PdcBuffer = [pdc_samples]Sample;

const TrackDelay = struct {
    samples: std.atomic.Value(?*PdcBuffer) = .init(null),
    write_frame: usize = 0,

    fn process(self: *TrackDelay, buf: []Sample, delay_frames: usize) void {
        const storage = self.samples.load(.acquire) orelse return;
        const frame_capacity = max_pdc_frames + 1;
        const delay = @min(delay_frames, max_pdc_frames);
        for (0..buf.len / channels) |frame| {
            const read_frame = (self.write_frame + frame_capacity - delay) % frame_capacity;
            inline for (0..channels) |channel| {
                const input_index = frame * channels + channel;
                const write_index = self.write_frame * channels + channel;
                storage[write_index] = buf[input_index];
                buf[input_index] = storage[read_frame * channels + channel];
            }
            self.write_frame = (self.write_frame + 1) % frame_capacity;
        }
    }
};

/// Bank of distinct tracks that can be captured as a sidechain-compressor
/// detector source in one block - same small-fixed-bank convention as
/// `max_synth_slots`/`max_groups`. Most songs sidechain off one or two key
/// tracks (a kick, maybe a snare); 8 is generous headroom.
pub const max_sidechain_sources: u8 = 8;

/// Aux-send types live on `Project` (see its own doc comments) - `Project`
/// is already imported below and this avoids a circular import the other
/// way around.
/// Free-floating modulation controllers - see `dsp/controller.zig`. Owned
/// by `Project`, mirrored here as a plain value array the audio thread
/// reads (they are stateless, so there is nothing to keep in sync beyond
/// the values themselves).
pub const controller_mod = @import("../dsp/controller.zig");
pub const max_controllers = controller_mod.max_controllers;
pub const max_cc_bindings = controller_mod.max_cc_bindings;

pub const SendTarget = @import("../project.zig").SendTarget;
pub const SendSlot = @import("../project.zig").SendSlot;

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
/// `Engine` - see `TrackAutomation`'s doc comment for the class of field
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
    /// Bus mute - skips rendering the submix into the mix entirely. A real
    /// flag on the bus itself, not derived from every member track's own
    /// `muted` (which used to be how `m` on a group row worked: it flipped
    /// each member's flag, so a track added to an already-muted group played
    /// straight through, and unmuting couldn't tell which members were
    /// individually muted beforehand).
    muted: bool = false,
    /// Bus solo - a real flag on the bus itself, not derived from every
    /// member track's own `soloed` (which used to be how `S` on a group row
    /// worked: it flipped each member's flag, same drift-prone shape
    /// `muted`'s doc comment describes). Participates in the same global
    /// "only soloed things play" scan `any_solo` runs over tracks - see
    /// `renderTracks`/`renderOneTrack`.
    soloed: bool = false,
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
/// field on `TrackState` for the exact reason `TrackAutomation`'s doc comment
/// gives: `TrackState` is embedded inline in `[max_tracks]TrackState`
/// (max_tracks = 8192), so even this small `max_chain_devices`-slot array
/// would add ~400KB to Engine's own inline layout. Kept as its own
/// heap-allocated slice instead (`Engine.track_sidechain`), sized once at
/// `Engine.init` and indexed the same as `tracks` - same pattern
/// `Engine.automation` already established.
const TrackSidechainSlots = [max_chain_devices]?Compressor.SidechainSource;

/// Per-track aux-send slots - same "separate heap slice, not a `TrackState`
/// field" reasoning `TrackSidechainSlots`'s doc comment gives (this would
/// otherwise multiply by `max_tracks` too). Indexed the same as `tracks`.
const TrackSendSlots = [max_sends_per_track]?SendSlot;

/// A track slot's song-mode gain/pan automation, flattened from the
/// arrangement's clips by `Session.rebuildSongData` (see dsp/automation.zig).
/// Empty (the default) means no override - the track plays at its manual
/// `TrackState.gain`/`.pan`, same as before automation existed.
///
/// Deliberately NOT a field on `TrackState`: that struct is embedded inline
/// in a `[max_tracks]TrackState` array (max_tracks = 8192), so every byte
/// added there is multiplied 8192x. Curves are kept in this separately
/// allocated slice, and each curve allocates point storage only when used.
const TrackAutomation = struct {
    gain: AutomationCurve = .{},
    pan: AutomationCurve = .{},
    sends: [max_sends_per_track]AutomationCurve = [_]AutomationCurve{.{}} ** max_sends_per_track,
    /// Parameter-id automation. Empty curves allocate no point storage.
    synth_slots: [max_synth_slots]SynthAutomationSlot = [_]SynthAutomationSlot{.{}} ** max_synth_slots,

    fn deinit(self: *TrackAutomation, allocator: std.mem.Allocator) void {
        self.gain.deinit(allocator);
        self.pan.deinit(allocator);
        for (&self.sends) |*curve| curve.deinit(allocator);
        for (&self.synth_slots) |*slot| slot.curve.deinit(allocator);
    }

    fn clear(self: *TrackAutomation, allocator: std.mem.Allocator) void {
        self.gain.set(allocator, &.{}) catch unreachable;
        self.pan.set(allocator, &.{}) catch unreachable;
        for (&self.sends) |*curve| curve.set(allocator, &.{}) catch unreachable;
        for (&self.synth_slots) |*slot| {
            slot.curve.set(allocator, &.{}) catch unreachable;
            slot.active.store(false, .release);
        }
    }

    fn swapContent(self: *TrackAutomation, other: *TrackAutomation) void {
        self.gain.swapPoints(&other.gain);
        self.pan.swapPoints(&other.pan);
        for (&self.sends, &other.sends) |*a, *b| a.swapPoints(b);
        for (&self.synth_slots, &other.synth_slots) |*a, *b| {
            a.curve.swapPoints(&b.curve);
            const active = a.active.load(.acquire);
            const param_id = a.param_id.load(.acquire);
            a.active.store(b.active.load(.acquire), .release);
            a.param_id.store(b.param_id.load(.acquire), .release);
            b.active.store(active, .release);
            b.param_id.store(param_id, .release);
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
    /// Per-track post-FX, post-gain/pan peaks before any group processing.
    track_peak: [max_tracks][channels]f32 = [_][channels]f32{.{ 0.0, 0.0 }} ** max_tracks,
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
    /// `Spsc` is single-producer only, but the control/UI thread isn't the
    /// only one calling `send` - a live MIDI input device dispatches from
    /// its own reader thread (see `MidiIn.dispatch`/`sendMidi` below). A
    /// second producer racing `commands.push`'s non-atomic load-write-store
    /// against the first could silently drop one side's command (both
    /// compute the same next `tail`, so the queue only advances by one) or,
    /// on genuine overlap, tear a `Command` union write the consumer then
    /// reads half-updated. Same queue shape, kept separate so each side
    /// still only ever has the one producer `Spsc` requires.
    midi_commands: Spsc(Command, 256) = .{},
    /// Mono input samples crossing from capture/control thread to audio
    /// thread for direct monitoring. Capacity covers about 340 ms at 48 kHz.
    monitor_samples: Spsc(Sample, 16384) = .{},
    /// Commands are realtime messages and cannot block their producer. Count
    /// queue saturation so the UI can report it instead of failing silently.
    dropped_commands: std.atomic.Value(u32) = .init(0),
    /// Largest primary-route latency beyond PDC storage seen since UI poll.
    excessive_latency_frames: std.atomic.Value(u32) = .init(0),
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
    /// Off-mixer audition voice: the file browser loads the clip under its
    /// cursor here and triggers it, so a sample can be heard before it's
    /// picked without touching any track. Mixed in post-master-chain (the
    /// user's master FX shouldn't colour a preview) but pre-`master_gain`,
    /// so the fader and the limiter still apply.
    preview: Sampler,
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
    /// Number of logical track slots worth visiting on the audio thread.
    /// Tracks are contiguous, so walking the remaining `max_tracks` empty
    /// slots every block only burns realtime budget.
    track_count: std.atomic.Value(u16) = .init(0),
    /// Stable backing storage `tracks` indexes into by pointer - a fixed
    /// pool of `max_tracks` objects, never moved once allocated. Heap slice
    /// (owned, freed in `deinit`) for the same by-value-construction/stack
    /// size reason `automation`/`track_sidechain` are: inline it is ~3.2MB.
    track_pool: []TrackState,
    scratch: [types.max_block_frames * channels]Sample = undefined,
    route_scratch: [types.max_block_frames * channels]Sample = undefined,
    automation_gain: [types.max_block_frames]f32 = undefined,
    automation_pan: [types.max_block_frames]f32 = undefined,
    automation_bus: [types.max_block_frames]f32 = undefined,
    /// Group submix buses (see `TrackState.group`/`renderTracks`). Fixed
    /// bank of `max_groups` (8), not multiplied by `max_tracks` - negligible
    /// size (~256KB total), safe to embed directly unlike `TrackAutomation`.
    groups: [max_groups]GroupState = [_]GroupState{.{}} ** max_groups,
    group_scratch: [max_groups][types.max_block_frames * channels]Sample = undefined,
    peak: [channels]f32 = .{ 0.0, 0.0 },
    track_peak: [max_tracks][channels]f32 = [_][channels]f32{.{ 0.0, 0.0 }} ** max_tracks,
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
    /// The specific EQ device instance the active analyzer taps around, and
    /// which side - see `set_spectrum_active`/`set_spectrum_pre`.
    active_spectrum_target: ?*anyopaque = null,
    spectrum_pre: bool = false,
    shared: Shared = .{},
    /// Offline-bounce handshake. When the UI thread sets `bounce_active`, the
    /// realtime backend parks (outputs silence, sets `bounce_parked`) so the UI
    /// thread can drive process() into a file without racing the audio thread.
    bounce_active: std.atomic.Value(bool) = .init(false),
    bounce_parked: std.atomic.Value(bool) = .init(false),
    /// Structural graph mutation gate. Audio owns it for one complete block;
    /// control-side publishers wait for that block, then update coherent
    /// pointer/routing banks. Audio never waits: if mutation already owns the
    /// gate, that callback emits silence. Structural edits are rare enough
    /// that one dropped block beats torn device/routing state.
    graph_mutating: std.atomic.Value(bool) = .init(false),
    /// One gain/pan automation pair per track slot - see `TrackAutomation`'s
    /// doc comment for why this is a separate heap allocation rather than a
    /// field on `TrackState`. Indexed the same as `tracks`.
    automation: []TrackAutomation,
    master_gain_automation: AutomationCurve = .{},
    group_gain_automation: [max_groups]AutomationCurve = [_]AutomationCurve{.{}} ** max_groups,
    /// Per-track chain-slot sidechain-detector routing - see
    /// `TrackSidechainSlots`'s doc comment for why this is a separate heap
    /// allocation. Indexed the same as `tracks`.
    track_sidechain: []TrackSidechainSlots,
    /// Per-track aux-send routing - see `TrackSendSlots`'s doc comment for
    /// why this is a separate heap allocation. Indexed the same as `tracks`.
    track_sends: []TrackSendSlots,
    /// Per-chain-slot sidechain-detector routing for the master bus, parallel
    /// to `master_chain` - safe to embed directly (not scaled by max_tracks).
    master_sidechain_sources: [9]?Compressor.SidechainSource = [_]?Compressor.SidechainSource{null} ** 9,
    /// Project-wide modulation controllers, pushed whole by
    /// `Session.syncControllers`. Read-only on the audio thread, same
    /// "control thread replaces, audio thread only reads" discipline
    /// `track_sends` follows.
    controllers: [max_controllers]?controller_mod.Controller = @splat(null),
    /// Learned MIDI CC bindings, pushed whole alongside `controllers`.
    cc_bindings: [max_cc_bindings]?controller_mod.CcBinding = @splat(null),
    /// See `lastCc`. Written by the audio thread as it drains CC commands,
    /// read by the UI thread; zero means "nothing seen yet", which is why
    /// the sequence counter starts at 1.
    last_cc: std.atomic.Value(u32) = .init(0),
    /// This block's captured signal per registered sidechain-detector source
    /// track - see `SidechainCapture`. Rebuilt every block in `renderTracks`.
    sidechain_captures: [max_sidechain_sources]SidechainCapture = [_]SidechainCapture{.{}} ** max_sidechain_sources,

    const Shared = struct {
        playing: std.atomic.Value(bool) = .init(false),
        pre_rolling: std.atomic.Value(bool) = .init(false),
        position_frames: std.atomic.Value(u64) = .init(0),
        peak_bits: [channels]std.atomic.Value(u32) = .{ .init(0), .init(0) },
        track_peak_bits: [max_tracks][channels]std.atomic.Value(u32) = [_][channels]std.atomic.Value(u32){.{ .init(0), .init(0) }} ** max_tracks,
        correlation_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1.0))),
        lufs_momentary_bits: std.atomic.Value(u32) = .init(@bitCast(LoudnessMeter.floor_lufs)),
        lufs_short_term_bits: std.atomic.Value(u32) = .init(@bitCast(LoudnessMeter.floor_lufs)),
        lufs_integrated_bits: std.atomic.Value(u32) = .init(@bitCast(LoudnessMeter.floor_lufs)),
        /// Blocks `process` has finished, ever. Read by the control thread to
        /// tell when a device dropped from a chain can no longer be in use -
        /// see `Engine.blocksDone` and `Session.retireFxChain`.
        blocks_done: std.atomic.Value(u64) = .init(0),
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
        var preview = try Sampler.init(allocator, sample_rate);
        errdefer preview.deinit();
        var limiter = try Limiter.init(allocator, sample_rate);
        errdefer limiter.deinit(allocator);
        const automation = try allocator.alloc(TrackAutomation, max_tracks);
        errdefer allocator.free(automation);
        for (automation) |*a| a.* = .{};
        const track_sidechain = try allocator.alloc(TrackSidechainSlots, max_tracks);
        errdefer allocator.free(track_sidechain);
        for (track_sidechain) |*s| s.* = [_]?Compressor.SidechainSource{null} ** max_chain_devices;
        const track_sends = try allocator.alloc(TrackSendSlots, max_tracks);
        errdefer allocator.free(track_sends);
        for (track_sends) |*s| s.* = [_]?SendSlot{null} ** max_sends_per_track;
        const track_pool = try allocator.alloc(TrackState, max_tracks);
        errdefer allocator.free(track_pool);
        for (track_pool) |*t| t.* = .{};
        const tracks = try allocator.alloc(std.atomic.Value(*TrackState), max_tracks);
        errdefer allocator.free(tracks);
        for (tracks, track_pool) |*slot, *t| slot.* = .init(t);

        self.* = .{
            .allocator = allocator,
            .transport = .{ .sample_rate = sample_rate },
            .limiter = limiter,
            .metronome = metronome,
            .preview = preview,
            .tracks = tracks,
            .track_pool = track_pool,
            .track_spectrum = track_spec,
            .master_spectrum = master_spec,
            .master_correlation = StereoCorrelation.init(sample_rate),
            .master_loudness = LoudnessMeter.init(sample_rate),
            .automation = automation,
            .track_sidechain = track_sidechain,
            .track_sends = track_sends,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.metronome.deinit();
        self.preview.deinit();
        self.limiter.deinit(self.allocator);
        self.master_spectrum.deinit(self.allocator);
        self.track_spectrum.deinit(self.allocator);
        for (self.automation) |*pair| pair.deinit(self.allocator);
        self.master_gain_automation.deinit(self.allocator);
        for (&self.group_gain_automation) |*curve| curve.deinit(self.allocator);
        self.allocator.free(self.automation);
        self.allocator.free(self.track_sidechain);
        self.allocator.free(self.track_sends);
        for (self.track_pool) |*track| {
            self.freeAudioLane(track.audio_lane);
            if (track.pdc.samples.load(.acquire)) |samples| std.heap.page_allocator.destroy(samples);
            for (&track.send_pdc) |*delay| if (delay.samples.load(.acquire)) |samples| std.heap.page_allocator.destroy(samples);
        }
        self.allocator.free(self.tracks);
        self.allocator.free(self.track_pool);
    }

    pub fn loadProject(self: *Engine, project: *const Project) void {
        self.transport.tempo_bpm = project.tempo_bpm;
        self.transport.time_signature.beats_per_bar = project.beats_per_bar;
        self.transport.time_signature.beat_unit = project.meter_denominator;
        self.transport.tempo_point_count = 0;
        self.transport.meter_point_count = 0;
        for (project.tempo_points.items) |point| self.transport.setTempoPoint(point);
        for (project.meter_points.items) |point| self.transport.setMeterPoint(point);
        self.transport.loop_enabled = project.loop_enabled and
            project.loop_end_bar > project.loop_start_bar;
        self.transport.loop_start_frames = project.frameAtBar(project.loop_start_bar);
        self.transport.loop_end_frames = project.frameAtBar(project.loop_end_bar);
        // Safe to write straight into the pooled `TrackState`s (bypassing
        // ChainBank's atomic swap): `loadProject` only ever runs right
        // after `initInPlace`, on an `Engine` no audio thread has been
        // started against yet (see callers) - not a live mutation.
        for (self.tracks, 0..) |*slot, i| {
            const state = slot.load(.monotonic);
            if (i < project.tracks.items.len) {
                const t = project.tracks.items[i];
                const pdc = state.pdc;
                const send_pdc = state.send_pdc;
                state.* = .{
                    .active = true,
                    .gain = types.dbToGain(t.gain_db),
                    .pan = t.pan,
                    .muted = t.muted,
                    .soloed = t.soloed,
                    .group = t.group,
                    .pdc = pdc,
                    .send_pdc = send_pdc,
                };
                self.track_sends[i] = t.sends;
                for (t.sends, 0..) |send_slot, send_index| if (send_slot != null) self.ensureDelay(&state.send_pdc[send_index]);
            } else {
                const pdc = state.pdc;
                const send_pdc = state.send_pdc;
                state.* = .{ .pdc = pdc, .send_pdc = send_pdc };
                self.track_sends[i] = [_]?SendSlot{null} ** max_sends_per_track;
            }
        }
        self.track_count.store(@intCast(@min(project.tracks.items.len, max_tracks)), .release);
    }

    /// Shift engine slots [idx, total) up by one (to make room for a new
    /// track), then initialize `idx` as a new active track with no chain.
    /// `total` is the track count before the insert. Shifts the parallel
    /// per-track heap arrays (`automation`, `track_sidechain`) in the same
    /// motion - they are indexed the same as `tracks` and would otherwise
    /// stay keyed to the pre-shift indices.
    ///
    /// `graph_mutating` excludes audio reads for this whole shift, including
    /// parallel routing and automation arrays. Pointers move instead of
    /// `TrackState` values so stable device state stays at one address.
    pub fn applyInsertTrack(self: *Engine, idx: u16, total: u16, gain: f32, pan: f32, muted: bool) void {
        self.lockGraph();
        defer self.unlockGraph();
        var i: usize = @min(total, max_tracks - 1);
        // The pointer about to be evicted from the visible range - nothing
        // in [idx, total] still needs its CURRENT content, so it's safe to
        // reset in place before being republished at `idx` below.
        const fresh = self.tracks[i].load(.monotonic);
        self.freeAudioLane(fresh.audio_lane);
        while (i > idx) : (i -= 1) {
            self.tracks[i].store(self.tracks[i - 1].load(.monotonic), .release);
            self.track_sidechain[i] = self.track_sidechain[i - 1];
            self.track_sends[i] = self.track_sends[i - 1];
            self.automation[i].swapContent(&self.automation[i - 1]);
        }
        const pdc = fresh.pdc;
        const send_pdc = fresh.send_pdc;
        fresh.* = .{
            .active = true,
            .gain = gain,
            .pan = pan,
            .muted = muted,
            .pdc = pdc,
            .send_pdc = send_pdc,
        };
        self.tracks[idx].store(fresh, .release);
        self.track_sidechain[idx] = [_]?Compressor.SidechainSource{null} ** max_chain_devices;
        self.track_sends[idx] = [_]?SendSlot{null} ** max_sends_per_track;
        self.automation[idx].clear(self.allocator);
        self.track_count.store(@min(total + 1, max_tracks), .release);
    }

    /// Shift engine slots [idx+1, total) down by one, clearing the last slot.
    /// Same graph-gate and stable-pointer rules as `applyInsertTrack`.
    pub fn applyDeleteTrack(self: *Engine, idx: u16, total: u16) void {
        self.lockGraph();
        defer self.unlockGraph();
        // The track actually being deleted - overwritten out of the visible
        // range by the very first loop iteration below, so nothing else
        // needs its content past this point.
        const evicted = self.tracks[idx].load(.monotonic);
        for (idx..total - 1) |i| {
            self.tracks[i].store(self.tracks[i + 1].load(.monotonic), .release);
            self.track_sidechain[i] = self.track_sidechain[i + 1];
            self.track_sends[i] = self.track_sends[i + 1];
            self.automation[i].swapContent(&self.automation[i + 1]);
        }
        const pdc = evicted.pdc;
        const send_pdc = evicted.send_pdc;
        self.freeAudioLane(evicted.audio_lane);
        evicted.* = .{ .pdc = pdc, .send_pdc = send_pdc };
        self.tracks[total - 1].store(evicted, .release);
        self.track_sidechain[total - 1] = [_]?Compressor.SidechainSource{null} ** max_chain_devices;
        self.track_sends[total - 1] = [_]?SendSlot{null} ** max_sends_per_track;
        self.automation[total - 1].clear(self.allocator);
        self.track_count.store(total - 1, .release);
    }

    /// Swap two tracks' engine slots, including parallel routing and
    /// automation rows, under the graph gate. Pointer swap keeps device
    /// state at stable addresses.
    pub fn swapTracks(self: *Engine, a: u16, b: u16) void {
        self.lockGraph();
        defer self.unlockGraph();
        const pa = self.tracks[a].load(.monotonic);
        const pb = self.tracks[b].load(.monotonic);
        self.tracks[a].store(pb, .release);
        self.tracks[b].store(pa, .release);
        std.mem.swap(TrackSidechainSlots, &self.track_sidechain[a], &self.track_sidechain[b]);
        std.mem.swap(TrackSendSlots, &self.track_sends[a], &self.track_sends[b]);
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
            var beat_k = self.metronome_next_beat;
            const position = self.transport.position_frames;
            const current_beat = self.transport.positionBeats();
            if (@abs(@as(f64, @floatFromInt(beat_k)) - current_beat) > 2.0) beat_k = @intFromFloat(@ceil(current_beat));
            while (true) : (beat_k += 1) {
                const boundary = self.transport.framesAtBeats(@floatFromInt(beat_k));
                if (boundary >= position +| frames) break;
                const fire_frame: u32 = if (boundary <= position) 0 else @intCast(boundary - position);
                self.metronome.trigger(self.transport.barBeatAtFrames(boundary).beat == 0, fire_frame);
            }
            self.metronome_next_beat = beat_k;
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
        // Click the signature's own beat unit rather than a quarter note, so
        // the accent lands on beat 1 of the bar the count-in actually covers
        // - `Transport.positionBarBeat` numbers beats the same way. Identical
        // to the old quarter-note click for any x/4 signature.
        const meter = self.transport.currentMeter();
        const fpb = self.transport.framesPerBeat() * 4.0 / @as(f64, @floatFromInt(@max(meter.denominator, 1)));
        const bpb: u64 = @max(meter.numerator, 1);
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
        self.lockGraph();
        defer self.unlockGraph();
        self.trackAt(track).chain.set(devices);
        if (devices.len != 0) self.ensureRouteDelays();
    }

    /// Publish chain and its parallel sidechain routing as one graph change.
    pub fn setTrackChainState(self: *Engine, track: u16, devices: []const dsp.Device, sources: []const ?Compressor.SidechainSource) void {
        self.lockGraph();
        defer self.unlockGraph();
        self.trackAt(track).chain.set(devices);
        if (devices.len != 0) self.ensureRouteDelays();
        replaceSidechainSlots(&self.track_sidechain[@min(track, max_tracks - 1)], sources);
    }

    fn ensureRouteDelays(self: *Engine) void {
        const count = self.track_count.load(.acquire);
        for (0..count) |track_index| {
            const track = self.trackAt(@intCast(track_index));
            self.ensureDelay(&track.pdc);
            for (self.track_sends[track_index], 0..) |send_slot, slot| if (send_slot != null) self.ensureDelay(&track.send_pdc[slot]);
        }
    }

    fn ensureDelay(_: *Engine, delay: *TrackDelay) void {
        if (delay.samples.load(.acquire) != null) return;
        const samples = std.heap.page_allocator.create(PdcBuffer) catch return;
        @memset(samples, 0.0);
        if (delay.samples.cmpxchgStrong(null, samples, .release, .acquire) != null) std.heap.page_allocator.destroy(samples);
    }

    fn chainLatencyRaw(chain: []const dsp.Device) u32 {
        var total: u32 = 0;
        for (chain) |device| total +|= device.latencyFrames();
        return total;
    }

    fn destinationLatency(self: *const Engine, target: SendTarget) u32 {
        return switch (target) {
            .master => 0,
            .group => |group| if (group < max_groups and self.groups[group].active) chainLatencyRaw(self.groups[group].chain.slice()) else 0,
        };
    }

    fn primaryTarget(track: *const TrackState) SendTarget {
        return if (track.group) |group| .{ .group = group } else .master;
    }

    fn routeLatency(self: *const Engine, track: *const TrackState, target: SendTarget) u32 {
        return @min(chainLatencyRaw(track.chain.slice()) +| self.destinationLatency(target), max_pdc_frames);
    }

    fn maxGraphRouteLatency(self: *Engine) u32 {
        var maximum: u32 = 0;
        const count = self.track_count.load(.acquire);
        for (self.tracks[0..count], 0..) |*slot, ti| {
            const track = slot.load(.acquire);
            if (!track.active) continue;
            const chain_latency = chainLatencyRaw(track.chain.slice());
            const primary_raw = chain_latency +| self.destinationLatency(primaryTarget(track));
            maximum = @max(maximum, @min(primary_raw, max_pdc_frames));
            if (primary_raw > max_pdc_frames) _ = self.excessive_latency_frames.fetchMax(primary_raw - @as(u32, max_pdc_frames), .monotonic);
            for (self.track_sends[ti]) |maybe_send| {
                const route_send = maybe_send orelse continue;
                const raw = chain_latency +| self.destinationLatency(route_send.target);
                maximum = @max(maximum, @min(raw, max_pdc_frames));
                if (raw > max_pdc_frames) _ = self.excessive_latency_frames.fetchMax(raw - @as(u32, max_pdc_frames), .monotonic);
            }
        }
        return maximum;
    }

    pub fn takeExcessiveLatencyFrames(self: *Engine) u32 {
        return self.excessive_latency_frames.swap(0, .acq_rel);
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
        self.lockGraph();
        defer self.unlockGraph();
        replaceSidechainSlots(&self.track_sidechain[@min(track, max_tracks - 1)], sources);
    }

    /// Replace a track's aux-send list wholesale (control thread) - same
    /// "whole-array push, audio thread never mutates it" shape as
    /// `setTrackSidechainSources`. Called by `Session.pushTrackSends`
    /// whenever a send target/level changes.
    pub fn setTrackSends(self: *Engine, track: u16, sends: TrackSendSlots) void {
        self.lockGraph();
        defer self.unlockGraph();
        const index = @min(track, max_tracks - 1);
        self.track_sends[index] = sends;
        for (sends, 0..) |send_slot, slot| if (send_slot != null) self.ensureDelay(&self.trackAt(index).send_pdc[slot]);
    }

    pub fn setTrackAudioRegions(self: *Engine, track: u16, regions: []const AudioRegion) void {
        const replacement: ?*AudioLane = if (regions.len == 0) null else blk: {
            const lane = self.allocator.create(AudioLane) catch @panic("out of memory setting audio regions");
            lane.regions = self.allocator.dupe(AudioRegion, regions) catch {
                self.allocator.destroy(lane);
                @panic("out of memory setting audio regions");
            };
            break :blk lane;
        };
        self.lockGraph();
        const state = self.trackAt(track);
        const old = state.audio_lane;
        state.audio_lane = replacement;
        self.unlockGraph();
        self.freeAudioLane(old);
    }

    fn freeAudioLane(self: *Engine, lane: ?*AudioLane) void {
        const value = lane orelse return;
        self.allocator.free(value.regions);
        self.allocator.destroy(value);
    }

    /// Replace the whole controller bank (control thread) - same shape as
    /// `setTrackSends`. Called by `Session.syncModulation` whenever a
    /// controller's shape/rate/depth or target list changes.
    pub fn setControllers(self: *Engine, controllers: [max_controllers]?controller_mod.Controller) void {
        self.lockGraph();
        defer self.unlockGraph();
        self.controllers = controllers;
    }

    /// Replace the learned MIDI CC map (control thread), same discipline as
    /// `setControllers`.
    pub fn setCcBindings(self: *Engine, bindings: [max_cc_bindings]?controller_mod.CcBinding) void {
        self.lockGraph();
        defer self.unlockGraph();
        self.cc_bindings = bindings;
    }

    /// Controller number of the most recent CC the audio thread saw, packed
    /// with a counter that advances on every message so a repeat of the same
    /// number still reads as new. Null before any CC has arrived. Polled by
    /// `App.tick` to drive `:cc-bind`'s learn mode - the same "reader thread
    /// signals, the UI picks it up once a frame" shape `MidiIn.dirty`
    /// already uses, but on the engine so it works for every platform's MIDI
    /// backend at once.
    pub fn lastCc(self: *Engine) ?struct { cc: u7, seq: u24 } {
        const packed_cc = self.last_cc.load(.acquire);
        if (packed_cc == 0) return null;
        return .{ .cc = @intCast(packed_cc & 0x7F), .seq = @intCast(packed_cc >> 8) };
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

    pub fn setMixAutomation(self: *Engine, target: automation_mod.MixTarget, points: []const AutomationPoint) void {
        switch (target) {
            .master_gain => self.master_gain_automation.set(self.allocator, points) catch @panic("out of memory setting master automation"),
            .group_gain => |group| if (group < max_groups) self.group_gain_automation[group].set(self.allocator, points) catch @panic("out of memory setting group automation"),
            .send_level => |send_target| if (send_target.track < max_tracks and send_target.slot < max_sends_per_track) self.automation[send_target.track].sends[send_target.slot].set(self.allocator, points) catch @panic("out of memory setting send automation"),
        }
    }

    /// Replace a track's instrument- or FX-unit-param automation curve at
    /// `slot_index`. `instance_id` 0 targets the instrument (`param_id` its
    /// own flat id space); nonzero targets that FX unit's `instance_id`
    /// (`param_id` a local index into its `dsp.fx_params` table) - see
    /// `dsp.Event.automation_param`'s doc comment.
    pub fn setTrackSynthParam(self: *Engine, track: u16, slot_index: u8, instance_id: u32, param_id: u32, points: []const AutomationPoint) void {
        const pair = &self.automation[@min(track, max_tracks - 1)];
        const slot = &pair.synth_slots[slot_index];
        slot.curve.set(self.allocator, points) catch @panic("out of memory setting parameter automation");
        slot.param_id.store(param_id, .release);
        slot.instance_id.store(instance_id, .release);
        slot.active.store(points.len != 0, .release);
    }

    /// Clear every synth-param automation slot for a track (control thread).
    /// `Session.rebuildSongData` calls this before repopulating a track's
    /// slots from scratch each rebuild, so a param removed from every clip
    /// since the last rebuild doesn't linger in a stale slot forever.
    pub fn clearTrackSynthParams(self: *Engine, track: u16) void {
        const pair = &self.automation[@min(track, max_tracks - 1)];
        for (&pair.synth_slots) |*slot| {
            slot.curve.set(self.allocator, &.{}) catch unreachable;
            slot.active.store(false, .release);
        }
    }

    pub fn trackLatencyFrames(self: *const Engine, track: u16) u32 {
        if (track >= max_tracks) return 0;
        var total: u32 = 0;
        for (self.tracks[track].chain.slice()) |device| total +|= device.latencyFrames();
        return total;
    }

    /// Same shape as `setTrackChain` but for the master bus - no instrument
    /// slot, just whichever FX stages `Session.master_fx` has active.
    pub fn setMasterChain(self: *Engine, devices: []const dsp.Device) void {
        self.lockGraph();
        defer self.unlockGraph();
        self.master_chain.set(devices);
    }

    pub fn setMasterChainState(self: *Engine, devices: []const dsp.Device, sources: []const ?Compressor.SidechainSource) void {
        self.lockGraph();
        defer self.unlockGraph();
        self.master_chain.set(devices);
        replaceSidechainSlots(&self.master_sidechain_sources, sources);
    }

    /// Same shape as `setTrackSidechainSources` but for the master chain.
    pub fn setMasterSidechainSources(self: *Engine, sources: []const ?Compressor.SidechainSource) void {
        self.lockGraph();
        defer self.unlockGraph();
        replaceSidechainSlots(&self.master_sidechain_sources, sources);
    }

    /// Same shape as `setMasterChain` but for group submix bus `idx` - FX
    /// stages only, no instrument slot. `active` marks the group slot in use
    /// (`renderTracks` skips inactive slots entirely); called whenever
    /// `Session.groups[idx]` changes, same call-site convention
    /// `syncMasterChain` already follows for the master bus.
    pub fn setGroupChain(self: *Engine, idx: u8, active: bool, devices: []const dsp.Device) void {
        if (idx >= max_groups) return;
        self.lockGraph();
        defer self.unlockGraph();
        const g = &self.groups[idx];
        g.active = active;
        g.chain.set(devices);
        if (devices.len != 0) self.ensureRouteDelays();
    }

    pub fn setGroupChainState(self: *Engine, idx: u8, active: bool, devices: []const dsp.Device, sources: []const ?Compressor.SidechainSource) void {
        if (idx >= max_groups) return;
        self.lockGraph();
        defer self.unlockGraph();
        const g = &self.groups[idx];
        g.active = active;
        g.chain.set(devices);
        if (devices.len != 0) self.ensureRouteDelays();
        replaceSidechainSlots(&g.sidechain_sources, sources);
    }

    /// Same shape as `setTrackSidechainSources` but for group submix bus `idx`.
    pub fn setGroupSidechainSources(self: *Engine, idx: u8, sources: []const ?Compressor.SidechainSource) void {
        if (idx >= max_groups) return;
        self.lockGraph();
        defer self.unlockGraph();
        replaceSidechainSlots(&self.groups[idx].sidechain_sources, sources);
    }

    pub fn send(self: *Engine, cmd: Command) bool {
        if (self.commands.push(cmd)) return true;
        _ = self.dropped_commands.fetchAdd(1, .monotonic);
        return false;
    }

    /// Same contract as `send`, for the one other command producer (live
    /// MIDI input, off the control/UI thread) - see `midi_commands`'s doc
    /// comment for why it needs its own queue instead of sharing `send`'s.
    pub fn sendMidi(self: *Engine, cmd: Command) bool {
        if (self.midi_commands.push(cmd)) return true;
        _ = self.dropped_commands.fetchAdd(1, .monotonic);
        return false;
    }

    pub fn setTrackParam(self: *Engine, track: u16, id: u16, value: f32) bool {
        return self.send(.{ .set_track_param_abs = .{ .track = track, .id = id, .value = value } });
    }

    pub fn takeDroppedCommands(self: *Engine) u32 {
        return self.dropped_commands.swap(0, .acq_rel);
    }

    /// Realtime backend entry point. Offline export parks here so frontend
    /// audio callbacks cannot race the control thread driving `process`.
    pub fn renderRealtime(self: *Engine, out: []Sample) void {
        if (self.bounce_active.load(.acquire)) {
            @memset(out, 0);
            self.bounce_parked.store(true, .release);
            return;
        }
        self.process(out);
    }

    pub fn monitorInput(self: *Engine, samples: []const Sample) void {
        for (samples) |sample| {
            if (!self.monitor_samples.push(sample)) break;
            if (!self.monitor_samples.push(sample)) break;
        }
    }

    pub fn monitorInputInterleaved(self: *Engine, samples: []const Sample, input_channels: u8) void {
        if (input_channels == 1) return self.monitorInput(samples);
        for (samples) |sample| if (!self.monitor_samples.push(sample)) break;
    }

    fn mixMonitoredInput(self: *Engine, out: []Sample) void {
        var frame: usize = 0;
        while (frame < out.len / channels) : (frame += 1) {
            const left = self.monitor_samples.pop() orelse break;
            const right = self.monitor_samples.pop() orelse left;
            out[frame * channels] += left;
            out[frame * channels + 1] += right;
        }
    }

    pub fn process(self: *Engine, out: []Sample) void {
        const frames: u32 = @intCast(out.len / channels);
        std.debug.assert(frames <= types.max_block_frames);

        @memset(out, 0.0);
        if (self.graph_mutating.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.graph_mutating.store(false, .release);

        self.drainCommands();
        const track_count = self.track_count.load(.acquire);
        @memset(self.track_peak[0..track_count], .{ 0.0, 0.0 });

        if (self.pre_roll_frames_remaining > 0) {
            // Count-in: click through the armed bar, no track audio, and
            // the transport itself stays stopped until it's done. If the
            // count-in ends mid-block, render only up to that point here so
            // the remainder of the block still gets real track audio instead
            // of the whole block going silent on the punch-in.
            const roll_frames: u32 = @intCast(@min(self.pre_roll_frames_remaining, frames));
            self.firePreRoll(out[0 .. roll_frames * channels], roll_frames);
            const rest = frames - roll_frames;
            if (rest > 0) {
                const tail = out[roll_frames * channels ..];
                self.renderTracks(tail, rest);
                if (self.metronome_enabled) self.fireMetronome(tail, rest);
            }
        } else {
            self.renderTracks(out, frames);
            if (self.metronome_enabled) self.fireMetronome(out, frames);
        }

        const master_tap: ?SpectrumTap = if (self.active_spectrum_source == .master and self.active_spectrum_target != null)
            .{ .target = self.active_spectrum_target.?, .analyzer = &self.master_spectrum, .pre = self.spectrum_pre }
        else
            null;
        self.processChainWithSidechain(self.master_chain.slice(), &self.master_sidechain_sources, out, frames, master_tap, &.{});

        self.preview.processBlock(out);
        self.mixMonitoredInput(out);

        const master_gains = self.automation_bus[0..frames];
        const master_automated = self.master_gain_automation.fillValues(master_gains, self.transport.positionBeats(), 1.0 / self.transport.framesPerBeat(), self.master_gain);
        for (0..frames) |frame| {
            const gain = if (master_automated) master_gains[frame] else self.master_gain;
            out[frame * channels] *= gain;
            out[frame * channels + 1] *= gain;
        }
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

        if (master_tap == null) {
            self.master_spectrum.push(out);
            self.master_spectrum.analyze();
        }

        self.master_correlation.push(out);
        self.master_loudness.push(out);

        self.transport.advance(frames);

        self.shared.playing.store(self.transport.playing, .monotonic);
        self.shared.pre_rolling.store(self.pre_roll_frames_remaining > 0, .monotonic);
        self.shared.position_frames.store(self.transport.position_frames, .monotonic);
        inline for (0..channels) |ch| {
            self.shared.peak_bits[ch].store(@bitCast(self.peak[ch]), .monotonic);
        }
        for (0..track_count) |track| inline for (0..channels) |ch| {
            self.shared.track_peak_bits[track][ch].store(@bitCast(self.track_peak[track][ch]), .monotonic);
        };
        self.shared.correlation_bits.store(@bitCast(self.master_correlation.value()), .monotonic);
        self.shared.lufs_momentary_bits.store(@bitCast(self.master_loudness.momentary()), .monotonic);
        self.shared.lufs_short_term_bits.store(@bitCast(self.master_loudness.shortTerm()), .monotonic);
        self.shared.lufs_integrated_bits.store(@bitCast(self.master_loudness.integrated()), .monotonic);
        _ = self.shared.blocks_done.fetchAdd(1, .release);
    }

    fn lockGraph(self: *Engine) void {
        while (self.graph_mutating.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlockGraph(self: *Engine) void {
        self.graph_mutating.store(false, .release);
    }

    /// How many blocks `process` has completed. A device that was still in a
    /// chain when this read `n` can only be touched by blocks `<= n`, so once
    /// it reads `> n` no in-flight block can reach that device any more -
    /// which is what makes deferred FX-unit frees safe (`Session.retireFxChain`).
    pub fn blocksDone(self: *const Engine) u64 {
        return self.shared.blocks_done.load(.acquire);
    }

    pub fn uiSnapshot(self: *const Engine) UiSnapshot {
        var snap: UiSnapshot = .{
            .playing = self.shared.playing.load(.monotonic),
            .pre_rolling = self.shared.pre_rolling.load(.monotonic),
            .position_frames = self.shared.position_frames.load(.monotonic),
            .peak = undefined,
            .track_peak = undefined,
            .correlation = @bitCast(self.shared.correlation_bits.load(.monotonic)),
            .lufs_momentary = @bitCast(self.shared.lufs_momentary_bits.load(.monotonic)),
            .lufs_short_term = @bitCast(self.shared.lufs_short_term_bits.load(.monotonic)),
            .lufs_integrated = @bitCast(self.shared.lufs_integrated_bits.load(.monotonic)),
        };
        inline for (0..channels) |ch| {
            snap.peak[ch] = @bitCast(self.shared.peak_bits[ch].load(.monotonic));
        }
        for (0..max_tracks) |track| inline for (0..channels) |ch| {
            snap.track_peak[track][ch] = @bitCast(self.shared.track_peak_bits[track][ch].load(.monotonic));
        };
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

    /// Drains both command queues - `commands` (control/UI thread) and
    /// `midi_commands` (live MIDI input's own thread, see its doc comment)
    /// - through the same `applyCommand` body.
    fn drainCommands(self: *Engine) void {
        while (self.commands.pop()) |cmd| self.applyCommand(cmd);
        while (self.midi_commands.pop()) |cmd| self.applyCommand(cmd);
    }

    fn applyCommand(self: *Engine, cmd: Command) void {
        switch (cmd) {
            .play => self.transport.play(),
            .stop => {
                self.transport.stop();
                self.pre_roll_frames_remaining = 0; // cancel an in-flight count-in too
            },
            .seek_frames => |f| self.transport.seekFrames(f),
            .set_tempo => |bpm| self.transport.tempo_bpm = bpm,
            .set_time_signature => |bpb| self.transport.time_signature.beats_per_bar = bpb,
            .set_meter_denominator => |denominator| self.transport.time_signature.beat_unit = denominator,
            .set_tempo_point => |point| self.transport.setTempoPoint(point),
            .set_meter_point => |point| self.transport.setMeterPoint(point),
            .clear_time_map => {
                self.transport.tempo_point_count = 0;
                self.transport.meter_point_count = 0;
            },
            .set_master_gain => |g| self.master_gain = g,
            .set_track_gain => |c| if (self.trackAtIfValid(c.track)) |track| {
                track.gain = c.gain;
            },
            .set_track_pan => |c| if (self.trackAtIfValid(c.track)) |track| {
                track.pan = c.pan;
            },
            .set_track_mute => |c| if (self.trackAtIfValid(c.track)) |track| {
                track.muted = c.muted;
            },
            .set_track_solo => |c| if (self.trackAtIfValid(c.track)) |track| {
                track.soloed = c.soloed;
            },
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
            .cc         => |c| self.applyCc(c.track, c.cc, c.value),
            // zig fmt: on
            .pitch_bend => |c| self.sendTrackEvent(c.track, .{ .pitch_bend = .{ .bend = c.bend } }),
            .set_track_param => |c| self.sendTrackEvent(c.track, .{ .set_param = .{ .id = c.id, .steps = c.steps } }),
            .set_track_param_abs => |c| self.sendTrackEvent(c.track, .{ .set_param_abs = .{ .id = c.id, .value = c.value } }),
            .set_track_mod_target => |c| self.sendTrackEvent(c.track, .{ .set_mod_target = .{
                .row = c.row,
                .id = c.id,
                .instance_id = c.instance_id,
            } }),
            .set_clap_param => |c| self.sendTrackEvent(c.track, .{ .clap_param = .{
                .target = c.target,
                .id = c.id,
                .cookie = c.cookie,
                .value = c.value,
            } }),
            .set_clap_param_any => |c| self.broadcastEvent(.{ .clap_param = .{
                .target = c.target,
                .id = c.id,
                .cookie = c.cookie,
                .value = c.value,
            } }),
            .set_vst3_param_any => |c| self.broadcastEvent(.{ .vst3_param = .{
                .target = c.target,
                .id = c.id,
                .value = c.value,
            } }),
            .set_track_group => |c| if (self.trackAtIfValid(c.track)) |track| {
                track.group = c.group;
            },
            .set_group_gain => |c| if (c.group < max_groups) {
                self.groups[c.group].gain = c.gain;
            },
            .set_group_mute => |c| if (c.group < max_groups) {
                self.groups[c.group].muted = c.muted;
            },
            .set_group_solo => |c| if (c.group < max_groups) {
                self.groups[c.group].soloed = c.soloed;
            },
            .set_loop => |c| {
                self.transport.loop_enabled = c.enabled;
                self.transport.loop_start_frames = c.start_frames;
                self.transport.loop_end_frames = c.end_frames;
            },
            .preview_play => self.preview.trigger(self.preview.root_note, 0.9, 0),
            .preview_stop => self.preview.resetAll(),
            .set_metronome => |v| self.metronome_enabled = v,
            .set_metronome_gain => |g| self.metronome.gain = g,
            .set_limiter => |v| {
                self.limiter.ceiling = v.ceiling;
                self.limiter.release_ms = v.release_ms;
            },
            .record => |bars| {
                if (bars == 0) {
                    self.transport.play();
                } else {
                    // The signature's beat unit counts: a 6/8 bar is three
                    // quarter notes, not six, which is how the transport's
                    // own bar/beat readout and the loop region measure it.
                    const bpb = self.transport.currentMeter().quarterBeatsPerBar();
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
                    switch (c.source) {
                        .track, .group => self.track_spectrum.reset(),
                        .master => self.master_spectrum.reset(),
                        .none => {},
                    }
                }
                self.active_spectrum_source = c.source;
                self.active_spectrum_track = c.track;
                self.active_spectrum_group = c.group;
                self.active_spectrum_target = c.target;
                self.track_spectrum.active.store(c.source == .track or c.source == .group, .release);
                self.master_spectrum.active.store(c.source == .master, .release);
            },
            .set_spectrum_pre => |pre| self.spectrum_pre = pre,
            .reset_loudness => self.master_loudness.resetIntegrated(),
        }
    }

    /// `pub` so tests elsewhere in the crate can reach a track's state
    /// without duplicating the pointer-indirection load.
    pub fn trackAt(self: *Engine, index: u16) *TrackState {
        const clamped: u16 = @min(index, max_tracks - 1);
        const needed = clamped + 1;
        if (needed > self.track_count.load(.monotonic)) self.track_count.store(needed, .release);
        return self.tracks[clamped].load(.acquire);
    }

    fn trackAtIfValid(self: *Engine, index: u16) ?*TrackState {
        if (index >= max_tracks) return null;
        return self.tracks[index].load(.acquire);
    }

    /// Route one incoming MIDI CC. A learned binding (see
    /// `controller_mod.CcBinding`) drives its own target's param, on
    /// whatever track that lives on, and *replaces* the raw forward for that
    /// controller number - otherwise a knob learned onto CC7 would move both
    /// the param it was bound to and every instrument's `applyCC` gain at
    /// once. An unbound CC still reaches the routed track's devices exactly
    /// as before.
    ///
    /// Also records the number for `lastCc` regardless, which is what makes
    /// learn mode able to see a knob that is already bound to something.
    fn applyCc(self: *Engine, track: u16, cc: u7, value: u7) void {
        // Bit 7 is a "something has arrived" flag - a CC number of 0 with a
        // wrapped counter would otherwise pack to plain zero, which `lastCc`
        // reads as "nothing seen yet".
        const prev = self.last_cc.load(.monotonic);
        const seq: u32 = ((prev >> 8) +% 1) & 0xFFFFFF;
        self.last_cc.store((seq << 8) | 0x80 | @as(u32, cc), .release);

        var bound = false;
        for (&self.cc_bindings) |maybe| {
            const b = maybe orelse continue;
            if (b.cc != cc) continue;
            bound = true;
            self.sendTrackEvent(b.target.track, .{ .automation_param = .{
                .id = @intCast(b.target.param_id),
                .value = b.target.valueAt01(@as(f32, @floatFromInt(value)) / 127.0),
                .instance_id = b.target.instance_id,
            } });
        }
        if (!bound) self.sendTrackEvent(track, .{ .cc = .{ .cc = cc, .value = value } });
    }

    fn sendTrackEvent(self: *Engine, track: u16, ev: dsp.Event) void {
        const state = self.trackAtIfValid(track) orelse return;
        for (state.chain.slice()) |dev| dev.sendEvent(ev);
    }

    /// Delivers `ev` to every device in every chain (master, every active
    /// track, every active group) - for events matched by target-pointer
    /// identity inside the device itself (`clap_param`/`vst3_param`) rather
    /// than by which chain they live on, since a CLAP/VST3 unit can sit on
    /// any of the three and the control thread has no cheap way to know
    /// which without walking the same chains anyway.
    fn broadcastEvent(self: *Engine, ev: dsp.Event) void {
        for (self.master_chain.slice()) |dev| dev.sendEvent(ev);
        for (self.tracks) |*slot| {
            const t = slot.load(.acquire);
            if (!t.active) continue;
            for (t.chain.slice()) |dev| dev.sendEvent(ev);
        }
        for (&self.groups) |*g| {
            if (!g.active) continue;
            for (g.chain.slice()) |dev| dev.sendEvent(ev);
        }
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
            if (key.track == src.track and key.pad == src.pad and key.is_group == src.is_group and c.captured)
                return c.buf[0 .. frames * channels];
        }
        return null;
    }

    /// Runs `chain` over `buf`, injecting each slot's captured sidechain
    /// detector signal (if any) before that slot processes - shared body of
    /// the master/track/group render paths, which differ only in which
    /// chain, sidechain-source slots, and scratch buffer they pass in.
    /// Where the active spectrum analyzer should tap this block, matched by
    /// device identity (`dsp.Device.ptr`) against whichever EQ instance is
    /// actually open - see `set_spectrum_active`'s doc comment.
    const SpectrumTap = struct {
        target: *anyopaque,
        analyzer: *SpectrumAnalyzer,
        pre: bool,
    };

    fn processChainWithSidechain(
        self: *Engine,
        chain: []const dsp.Device,
        sidechain_sources: []const ?Compressor.SidechainSource,
        buf: []Sample,
        frames: u32,
        tap: ?SpectrumTap,
        parameter_events: []const ParameterEvent,
    ) void {
        for (chain, 0..) |dev, slot| {
            const sidechain = if (sidechain_sources[slot]) |src| self.sidechainCapture(src, frames) else null;
            if (tap) |t| if (dev.ptr == t.target and t.pre) {
                t.analyzer.push(buf);
                t.analyzer.analyze();
            };
            if (dev.acceptsSampleOffsetEvents()) {
                for (parameter_events) |param| dev.sendEvent(param.event);
                if (sidechain) |sc_buf| dev.sendEvent(.{ .set_sidechain_buf = .{ .buf = sc_buf } });
                dev.process(buf);
            } else {
                var cursor: u32 = 0;
                var event_index: usize = 0;
                while (cursor < frames) {
                    while (event_index < parameter_events.len and parameter_events[event_index].offset == cursor) : (event_index += 1) {
                        var event = parameter_events[event_index].event;
                        event.automation_param.sample_offset = 0;
                        dev.sendEvent(event);
                    }
                    const next = if (event_index < parameter_events.len) @min(parameter_events[event_index].offset, frames) else frames;
                    if (next == cursor) continue;
                    const first: usize = cursor * channels;
                    const last: usize = next * channels;
                    if (sidechain) |sc_buf| dev.sendEvent(.{ .set_sidechain_buf = .{ .buf = sc_buf[first..last] } });
                    dev.process(buf[first..last]);
                    cursor = next;
                }
            }
            if (tap) |t| if (dev.ptr == t.target and !t.pre) {
                t.analyzer.push(buf);
                t.analyzer.analyze();
            };
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
            if (c.source) |key| if (key.track == src.track and key.pad == src.pad and key.is_group == src.is_group) return;
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
    fn renderOneTrack(self: *Engine, ti: u16, out: []Sample, frames: u32, beat_pos: f64, any_solo: bool, max_route_latency: u32) void {
        const track = self.trackAt(ti);
        // One snapshot for this whole render pass - the control thread may
        // flip `track.chain`'s active buffer between calls to `slice()`, so
        // every use below must share the same snapshot rather than each
        // re-reading it (which could observe the chain change mid-render).
        const chain = track.chain.slice();
        if (!track.active or (chain.len == 0 and track.audio_lane == null)) return;

        const auto = &self.automation[ti];
        // Instrument-param automation must reach the device before it
        // renders this block, unlike gain/pan below (a post-chain
        // multiplier) - push it through the same Event path
        // adjustParam/CC already use. Only fires for slots actually
        // holding a param this track (valueAt is null otherwise), so
        // tracks with no synth-param automation pay nothing extra.
        var lanes: [max_sample_accurate_lanes]*SynthAutomationSlot = undefined;
        var lane_count: usize = 0;
        for (&auto.synth_slots) |*slot| {
            if (!slot.active.load(.acquire)) continue;
            if (lane_count < lanes.len) {
                lanes[lane_count] = slot;
                lane_count += 1;
            } else if (slot.curve.valueAt(beat_pos)) |val| {
                self.sendTrackEvent(ti, .{ .automation_param = .{
                    .id = slot.param_id.load(.acquire),
                    .value = val,
                    .instance_id = slot.instance_id.load(.acquire),
                } });
            }
        }

        var parameter_events: [max_parameter_events]ParameterEvent = undefined;
        var parameter_event_count: usize = 0;
        var lane_values: [max_sample_accurate_lanes][max_parameter_events]f32 = undefined;
        if (lane_count > 0) {
            const points_per_lane = max_parameter_events / lane_count;
            const spacing: u32 = @max(1, std.math.divCeil(u32, frames, @intCast(points_per_lane)) catch 1);
            const point_count: usize = @intCast(std.math.divCeil(u32, frames, spacing) catch 1);
            const beat_step = @as(f64, @floatFromInt(spacing)) / self.transport.framesPerBeat();
            var active_lane: [max_sample_accurate_lanes]bool = .{false} ** max_sample_accurate_lanes;
            for (lanes[0..lane_count], 0..) |slot, lane| {
                active_lane[lane] = slot.curve.fillValues(lane_values[lane][0..point_count], beat_pos, beat_step, 0);
            }
            for (0..point_count) |point| {
                for (lanes[0..lane_count], 0..) |slot, lane| {
                    if (!active_lane[lane]) continue;
                    const offset: u32 = @intCast(point * spacing);
                    parameter_events[parameter_event_count] = .{
                        .offset = offset,
                        .event = .{ .automation_param = .{
                            .id = slot.param_id.load(.acquire),
                            .value = lane_values[lane][point],
                            .instance_id = slot.instance_id.load(.acquire),
                            .sample_offset = offset,
                        } },
                    };
                    parameter_event_count += 1;
                }
            }
        }

        // Modulation controllers ride the same event path, evaluated after
        // the curves above so a controller wired to a param that also has an
        // automation lane visibly does something - a silent no-op because
        // some clip still holds a stale lane would be the harder behaviour
        // to explain. Stateless (phase comes from `beat_pos`), so this is a
        // read of the bank plus one event per bound target.
        for (&self.controllers) |maybe| {
            const ctrl = maybe orelse continue;
            const level = ctrl.valueAt(beat_pos);
            for (ctrl.targets) |maybe_target| {
                const target = maybe_target orelse continue;
                if (target.track != ti) continue;
                self.sendTrackEvent(ti, .{ .automation_param = .{
                    .id = @intCast(target.param_id),
                    .value = target.valueFor(level),
                    .instance_id = target.instance_id,
                } });
            }
        }

        const scratch = self.scratch[0 .. frames * channels];
        @memset(scratch, 0.0);
        if (track.audio_lane) |lane| self.renderAudioLane(lane, scratch, frames);

        // If this track is referenced as some compressor's PER-PAD detector
        // source, broadcast a capture request to every device in the chain
        // before any of them process this block - only `DrumMachine` acts on
        // it (see `Event.capture_pad`'s doc comment), and it must see the
        // request before its own `process()` call below, regardless of
        // whether it sits at chain slot 0 (no pattern player) or 1. Zeroed
        // first so a pad that doesn't exist yields silence, not garbage.
        var has_pad_capture = false;
        for (&self.sidechain_captures) |*c| {
            const src = c.source orelse continue;
            if (src.is_group or src.track != ti) continue;
            const pad = src.pad orelse continue;
            has_pad_capture = true;
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

        const track_tap: ?SpectrumTap = if (self.active_spectrum_source == .track and ti == self.active_spectrum_track and self.active_spectrum_target != null)
            .{ .target = self.active_spectrum_target.?, .analyzer = &self.track_spectrum, .pre = self.spectrum_pre }
        else
            null;
        // ponytail: per-pad capture owns one whole-block destination. Keep
        // automation at block start until capture requests carry slice offsets.
        const timed_events = if (has_pad_capture) parameter_events[0..@min(parameter_event_count, lane_count)] else parameter_events[0..parameter_event_count];
        self.processChainWithSidechain(chain, &self.track_sidechain[ti], scratch, frames, track_tap, timed_events);
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
            if (src.is_group or src.track != ti) continue;
            if (src.pad == null) @memcpy(c.buf[0 .. frames * channels], scratch);
            c.captured = true;
        }

        // A track counts as soloed-in if it's soloed itself OR its own bus
        // is soloed (GroupState.soloed) - see any_solo's own doc comment for
        // why a bus solo has to fold into this same global scan rather than
        // being its own separate gate.
        const group_soloed = if (track.group) |gidx| gidx < max_groups and self.groups[gidx].active and self.groups[gidx].soloed else false;
        if (track.muted or (any_solo and !track.soloed and !group_soloed)) return;

        const primary_signal = self.route_scratch[0 .. frames * channels];
        @memcpy(primary_signal, scratch);
        // Saturating: `max_route_latency` was measured at the top of this
        // block, and a chain's latency can grow between then and here -
        // `FxUnit.latencyFrames` changes answer the instant the UI thread
        // flips `bypassed`, which it does without going through the command
        // queue. A route that momentarily reads longer than the recorded
        // maximum needs no padding at all, which is what 0 says; a plain
        // `-` panics on it in a ReleaseSafe build, on the audio thread.
        track.pdc.process(primary_signal, max_route_latency -| self.routeLatency(track, primaryTarget(track)));

        const beat_step = 1.0 / self.transport.framesPerBeat();
        const gains = self.automation_gain[0..frames];
        const pans = self.automation_pan[0..frames];
        const gain_automated = auto.gain.fillValues(gains, beat_pos, beat_step, track.gain);
        const pan_automated = auto.pan.fillValues(pans, beat_pos, beat_step, track.pan);
        const automated = gain_automated or pan_automated;
        const base_angle = (track.pan + 1.0) * std.math.pi / 4.0;
        const base_gain_l = track.gain * @cos(base_angle);
        const base_gain_r = track.gain * @sin(base_angle);

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
            const gain_l, const gain_r = if (automated) blk: {
                const angle = (pans[i] + 1.0) * std.math.pi / 4.0;
                break :blk .{ gains[i] * @cos(angle), gains[i] * @sin(angle) };
            } else .{ base_gain_l, base_gain_r };
            const left = primary_signal[i * channels] * gain_l;
            const right = primary_signal[i * channels + 1] * gain_r;
            dest[i * channels] += left;
            dest[i * channels + 1] += right;
            self.track_peak[ti][0] = @max(self.track_peak[ti][0], @abs(left));
            self.track_peak[ti][1] = @max(self.track_peak[ti][1], @abs(right));
        }

        // Aux sends: the same gain/pan'd signal, tapped in parallel into
        // zero or more OTHER destinations at an independent level - `dest`
        // above is the track's one primary route, this is every additional
        // one. A muted track already returned above, so it sends nothing
        // either, matching how a real mixer's sends follow the fader.
        for (self.track_sends[ti], 0..) |maybe_send, slot| {
            const snd = maybe_send orelse continue;
            // Read the lane before the level gate, not after: `snd.level` is
            // where an automation lane *starts*, and parking the manual send
            // at 0 to let the lane ride it up is the ordinary way to automate
            // one - gating on the manual level alone made those sends silent.
            const send_levels = self.automation_bus[0..frames];
            const send_automated = auto.sends[slot].fillValues(send_levels, beat_pos, beat_step, snd.level);
            if (!send_automated and snd.level <= 0.0) continue;
            const send_dest: []Sample = switch (snd.target) {
                .master => out,
                .group => |gidx| blk: {
                    if (gidx >= max_groups or !self.groups[gidx].active) continue;
                    break :blk self.group_scratch[gidx][0 .. frames * channels];
                },
            };
            @memcpy(primary_signal, scratch);
            track.send_pdc[slot].process(primary_signal, max_route_latency -| self.routeLatency(track, snd.target)); // saturating, same reason as the primary route above
            for (0..frames) |i| {
                const gain_l, const gain_r = if (snd.pre_fader)
                    .{ @as(f32, 1.0), @as(f32, 1.0) }
                else if (automated) blk: {
                    const angle = (pans[i] + 1.0) * std.math.pi / 4.0;
                    break :blk .{ gains[i] * @cos(angle), gains[i] * @sin(angle) };
                } else .{ base_gain_l, base_gain_r };
                const send_level = if (send_automated) send_levels[i] else snd.level;
                send_dest[i * channels] += primary_signal[i * channels] * gain_l * send_level;
                send_dest[i * channels + 1] += primary_signal[i * channels + 1] * gain_r * send_level;
            }
        }

        if (track_tap == null and self.active_spectrum_source == .track and
            ti == self.active_spectrum_track)
        {
            self.track_spectrum.push(scratch);
            self.track_spectrum.analyze();
        }
    }

    fn renderAudioLane(self: *Engine, lane: *const AudioLane, out: []Sample, frames: u32) void {
        const block_start = self.transport.position_frames;
        const block_end = block_start +| frames;
        const engine_rate = @as(u64, self.transport.sample_rate);
        for (lane.regions) |region| {
            if (region.end_frame <= block_start or region.start_frame >= block_end) continue;
            const first = @max(block_start, region.start_frame);
            const last = @min(block_end, region.end_frame);
            const source_frames = region.samples.len / @max(region.channel_count, 1);
            for (first..last) |timeline_frame| {
                const relative = timeline_frame - region.start_frame;
                const source_offset: u64 = @intFromFloat(@as(f64, @floatFromInt(relative)) * @as(f64, @floatFromInt(region.source_sample_rate)) / @as(f64, @floatFromInt(engine_rate)) / region.stretch_ratio);
                if (source_offset >= region.source_length_frames) break;
                const source_frame = region.source_start_frame + if (region.reverse) region.source_length_frames - source_offset - 1 else source_offset;
                if (source_frame >= source_frames) break;
                const dst: usize = @intCast((timeline_frame - block_start) * channels);
                const src: usize = @intCast(source_frame * region.channel_count);
                const fade_in = if (region.fade_in_frames > 0)
                    arrangement.fadeGain(@as(f32, @floatFromInt(relative)) / @as(f32, @floatFromInt(region.fade_in_frames)), region.fade_curve)
                else
                    1.0;
                const remaining = region.end_frame - timeline_frame - 1;
                const fade_out = if (region.fade_out_frames > 0)
                    arrangement.fadeGain(@as(f32, @floatFromInt(remaining)) / @as(f32, @floatFromInt(region.fade_out_frames)), region.fade_curve)
                else
                    1.0;
                const gain = region.gain * @min(fade_in, fade_out);
                out[dst] += region.samples[src] * gain;
                out[dst + 1] += (if (region.channel_count > 1) region.samples[src + 1] else region.samples[src]) * gain;
            }
        }
    }

    fn renderTracks(self: *Engine, out: []Sample, frames: u32) void {
        const track_count = self.track_count.load(.acquire);
        // When any track OR any bus is soloed, only soloed tracks/buses are
        // audible - a bus solo is folded into the same global flag rather
        // than a separate gate (see `renderOneTrack`'s `group_soloed` check).
        var any_solo = false;
        for (self.tracks[0..track_count]) |*slot| {
            const t = slot.load(.acquire);
            if (t.active and t.soloed) {
                any_solo = true;
                break;
            }
        }
        if (!any_solo) for (self.groups) |g| {
            if (g.active and g.soloed) {
                any_solo = true;
                break;
            }
        };

        // Block-start beat position, for gain/pan automation below. One
        // evaluation per block (not per sample) - plenty of resolution for a
        // parameter curve, same granularity the metronome's beat math uses.
        const beat_pos = self.transport.positionBeats();
        const max_route_latency = self.maxGraphRouteLatency();

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
        for (self.tracks[0..track_count], 0..) |*slot, ti| {
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
            const source = c.source orelse continue;
            if (source.is_group) continue; // resolved in the group loop below, not a track index
            const ti = source.track;
            var dup = false;
            for (self.sidechain_captures[0..idx]) |prev| {
                if (prev.source) |ps| if (!ps.is_group and ps.track == ti) {
                    dup = true;
                    break;
                };
            }
            if (dup) continue;
            self.renderOneTrack(ti, out, frames, beat_pos, any_solo, max_route_latency);
        }

        // Phase 2: every other track, in original order, skipping whatever
        // phase 1 already rendered (never render a track twice - see
        // renderOneTrack's own doc comment for why that matters). Iterates
        // by pointer (`&self.sidechain_captures`), not by value - each
        // capture embeds a `max_block_frames`-sized buffer, and copying that
        // 8 times per track (times max_tracks) would be a real per-block
        // cost, not just a style nit.
        for (0..track_count) |ti_usize| {
            const ti: u16 = @intCast(ti_usize);
            var already_done = false;
            for (&self.sidechain_captures) |*c| {
                if (c.source) |s| if (!s.is_group and s.track == ti) {
                    already_done = true;
                    break;
                };
            }
            if (already_done) continue;
            self.renderOneTrack(ti, out, frames, beat_pos, any_solo, max_route_latency);
        }

        // Each active group's FX chain applies to its submix, then the
        // result sums into `out` - the same shape `process()` applies
        // master_chain to the whole mix, one level up.
        for (&self.groups, 0..) |*g, gi| {
            if (!g.active or g.muted) continue;
            const gscratch = self.group_scratch[gi][0 .. frames * channels];
            const group_tap: ?SpectrumTap = if (self.active_spectrum_source == .group and @as(u8, @intCast(gi)) == self.active_spectrum_group and self.active_spectrum_target != null)
                .{ .target = self.active_spectrum_target.?, .analyzer = &self.track_spectrum, .pre = self.spectrum_pre }
            else
                null;
            self.processChainWithSidechain(g.chain.slice(), &g.sidechain_sources, gscratch, frames, group_tap, &.{});

            // If this group is itself a registered sidechain-detector
            // source (`SidechainSource.is_group`), finalize its capture now
            // - same idea as `renderOneTrack`'s whole-track finalize, one
            // level up. Safe for any consumer that hasn't rendered yet:
            // every track already has (groups always process after all
            // tracks), and groups here process in ascending bank-index
            // order, so a lower-index source is always done before a
            // higher-index consumer group or the master chain reads it. A
            // same/lower-index consumer, or any track-level compressor,
            // simply never sees `captured = true` and falls back to
            // self-detection - the same graceful "unresolved this block"
            // path a circular track reference already takes. Skipped for a
            // muted group (never processed above, no signal to capture).
            for (&self.sidechain_captures) |*c| {
                const src = c.source orelse continue;
                if (!src.is_group or src.track != gi) continue;
                @memcpy(c.buf[0 .. frames * channels], gscratch);
                c.captured = true;
            }

            const group_gains = self.automation_bus[0..frames];
            const group_automated = self.group_gain_automation[gi].fillValues(group_gains, beat_pos, 1.0 / self.transport.framesPerBeat(), g.gain);
            for (0..frames) |frame| {
                const gain = if (group_automated) group_gains[frame] else g.gain;
                out[frame * channels] += gscratch[frame * channels] * gain;
                out[frame * channels + 1] += gscratch[frame * channels + 1] * gain;
            }

            if (group_tap == null and self.active_spectrum_source == .group and @as(u8, @intCast(gi)) == self.active_spectrum_group) {
                self.track_spectrum.push(gscratch);
                self.track_spectrum.analyze();
            }
        }
    }
};

const PolySynth = @import("../dsp/synth.zig").PolySynth;
const DrumMachine = @import("../dsp/drum_sampler.zig").DrumMachine;
const drum_kit = @import("../dsp/drum_kit.zig");
const Compressor = @import("../dsp/compressor.zig").Compressor;

test "input monitor duplicates mono capture into stereo output" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.monitorInput(&.{ 0.25, -0.5 });
    var out: [4]Sample = undefined;
    engine.process(&out);
    try std.testing.expectEqualSlices(Sample, &.{ 0.25, 0.25, -0.5, -0.5 }, &out);
}

/// A drum machine with audible pads: a fresh one is the blank "init" kit
/// (see DrumMachine.init), so tests that need sound load a flavour first.
fn testDrumMachine(transport: *const Transport) !DrumMachine {
    var dm = try DrumMachine.init(std.testing.allocator, 48_000, transport);
    errdefer dm.deinit();
    try dm.loadKitVariant(drum_kit.byName("default").?);
    return dm;
}

/// A deliberately extreme compressor: limiting ratio and a near-instant
/// envelope, so the tests below can measure gain reduction within a couple
/// of blocks rather than waiting out a musical release. Only the threshold
/// varies - low enough that the master tests' summed mix triggers it, higher
/// for the sidechain tests where the detector is a single quiet track.
fn testCompressor(threshold_db: f32) Compressor {
    var comp = Compressor.init(48_000);
    comp.threshold_db = threshold_db;
    comp.ratio = 20.0;
    comp.attack_ms = 0.1;
    comp.release_ms = 0.1;
    return comp;
}

const LatentImpulse = struct {
    latency: u32,
    frame: u32 = 0,

    pub fn processBlock(self: *@This(), buf: []Sample) void {
        for (0..buf.len / channels) |i| {
            if (self.frame == self.latency) {
                buf[i * channels] += 0.25;
                buf[i * channels + 1] += 0.25;
            }
            self.frame += 1;
        }
    }

    pub fn reset(self: *@This()) void {
        self.frame = 0;
    }

    pub fn latencyFrames(self: *const @This()) u32 {
        return self.latency;
    }

    const device = dsp.deviceOf(@This());
};

const TestLatencyDelay = struct {
    latency: u32,
    history: [16 * channels]Sample = @splat(0),
    write_frame: usize = 0,

    pub fn processBlock(self: *@This(), buf: []Sample) void {
        for (0..buf.len / channels) |frame| {
            const read_frame = (self.write_frame + 16 - self.latency) % 16;
            inline for (0..channels) |channel| {
                const index = frame * channels + channel;
                self.history[self.write_frame * channels + channel] = buf[index];
                buf[index] = self.history[read_frame * channels + channel];
            }
            self.write_frame = (self.write_frame + 1) % 16;
        }
    }

    pub fn latencyFrames(self: *const @This()) u32 {
        return self.latency;
    }

    pub fn reset(self: *@This()) void {
        @memset(&self.history, 0);
        self.write_frame = 0;
    }

    const device = dsp.deviceOf(@This());
};

/// Answers one latency the first time it is asked and a bigger one after.
/// That is the interleaving a bypass toggle produces: the engine reads a
/// chain's latency once for the graph maximum and again per route, and
/// `FxUnit.latencyFrames` changes answer the instant the UI thread flips
/// `bypassed` (which it does directly, not through the command queue).
const LatencyFlip = struct {
    reads: *u32,
    after: u32,

    pub fn processBlock(_: *@This(), _: []Sample) void {}
    pub fn reset(_: *@This()) void {}

    pub fn latencyFrames(self: *const @This()) u32 {
        defer self.reads.* += 1;
        return if (self.reads.* == 0) 0 else self.after;
    }

    const device = dsp.deviceOf(@This());
};

test "a route whose latency grows mid-block does not underflow the PDC delta" {
    var reads: u32 = 0;
    var flip = LatencyFlip{ .reads = &reads, .after = 64 };
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{flip.device()});

    var output: [8]Sample = undefined;
    engine.process(&output);

    try std.testing.expect(reads >= 2); // both reads really happened
    for (output) |s| try std.testing.expect(std.math.isFinite(s));
}

test "engine rejects a zero sample rate" {
    try std.testing.expectError(error.InvalidSampleRate, Engine.init(std.testing.allocator, 0));
}

test "audio callback returns silence instead of waiting on a graph mutation" {
    var e = try Engine.init(std.testing.allocator, 48_000);
    defer e.deinit();
    var out: [8]Sample = @splat(1.0);

    e.lockGraph();
    e.process(&out);
    e.unlockGraph();

    const silence: [8]Sample = @splat(0.0);
    try std.testing.expectEqualSlices(Sample, &silence, &out);
}

test "plugin delay compensation aligns track impulses" {
    var immediate = LatentImpulse{ .latency = 0 };
    var latent = LatentImpulse{ .latency = 2 };
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.trackAt(1).* = .{ .active = true };
    engine.setTrackChain(0, &.{immediate.device()});
    engine.setTrackChain(1, &.{latent.device()});

    var output: [8]Sample = undefined;
    engine.process(&output);

    try std.testing.expectEqual(@as(Sample, 0), output[0]);
    try std.testing.expectEqual(@as(Sample, 0), output[2]);
    try std.testing.expect(output[4] > 0.3);
}

test "plugin delay compensation aligns primary and send routes" {
    var impulse = LatentImpulse{ .latency = 0 };
    var group_delay = TestLatencyDelay{ .latency = 2 };
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{impulse.device()});
    engine.setGroupChain(0, true, &.{group_delay.device()});
    var sends: TrackSendSlots = @splat(null);
    sends[0] = .{ .target = .{ .group = 0 }, .level = 1.0 };
    engine.setTrackSends(0, sends);

    var output: [12]Sample = undefined;
    engine.process(&output);

    try std.testing.expectEqual(@as(Sample, 0), output[0]);
    try std.testing.expectEqual(@as(Sample, 0), output[2]);
    try std.testing.expect(output[4] > 0.3);
    try std.testing.expectEqual(@as(Sample, 0), output[8]);
}

test "mix automation stores independent master group and send curves" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.setMixAutomation(.master_gain, &.{.{ .beat = 0, .value = 0.5 }});
    engine.setMixAutomation(.{ .group_gain = 2 }, &.{.{ .beat = 0, .value = 0.25 }});
    engine.setMixAutomation(.{ .send_level = .{ .track = 3, .slot = 1 } }, &.{.{ .beat = 0, .value = 0.75 }});

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), engine.master_gain_automation.valueAt(0).?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), engine.group_gain_automation[2].valueAt(0).?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), engine.automation[3].sends[1].valueAt(0).?, 1e-6);
}

test "plugin latency beyond PDC storage is surfaced" {
    var latent = LatentImpulse{ .latency = max_pdc_frames + 37 };
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{latent.device()});

    var output: [8]Sample = undefined;
    engine.process(&output);
    try std.testing.expectEqual(@as(u32, 37), engine.takeExcessiveLatencyFrames());
    try std.testing.expectEqual(@as(u32, 0), engine.takeExcessiveLatencyFrames());
}

test "audio region renders source trim on its timeline" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true, .gain = std.math.sqrt2 };
    const source = [_]Sample{ 0.1, 0.25, 0.5 };
    engine.setTrackAudioRegions(0, &.{.{
        .start_frame = 1,
        .end_frame = 3,
        .source_start_frame = 1,
        .source_length_frames = 2,
        .source_sample_rate = 48_000,
        .channel_count = 1,
        .samples = &source,
    }});

    var output: [8]Sample = undefined;
    engine.process(&output);
    for (output, [_]Sample{ 0, 0, 0.25, 0.25, 0.5, 0.5, 0, 0 }) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
    }
}

test "audio region handles final transport block" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    const source = [_]Sample{1};
    engine.setTrackAudioRegions(0, &.{.{
        .start_frame = std.math.maxInt(u64) - 1,
        .end_frame = std.math.maxInt(u64),
        .source_start_frame = 0,
        .source_length_frames = 1,
        .source_sample_rate = 48_000,
        .channel_count = 1,
        .samples = &source,
    }});
    engine.transport.position_frames = std.math.maxInt(u64) - 1;

    var output: [4]Sample = undefined;
    engine.process(&output);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, engine.transport.position_frames);
}

test "audio region applies gain and linear edge fades" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true, .gain = std.math.sqrt2 };
    const source = [_]Sample{ 1, 1, 1, 1 };
    engine.setTrackAudioRegions(0, &.{.{
        .start_frame = 0,
        .end_frame = 4,
        .source_start_frame = 0,
        .source_length_frames = 4,
        .source_sample_rate = 48_000,
        .channel_count = 1,
        .gain = 0.5,
        .fade_in_frames = 2,
        .fade_out_frames = 2,
        .samples = &source,
    }});

    var output: [8]Sample = undefined;
    engine.process(&output);
    for (output, [_]Sample{ 0, 0, 0.25, 0.25, 0.25, 0.25, 0, 0 }) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
    }
}

test "audio region stretch and reverse remap source frames" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true, .gain = std.math.sqrt2 };
    const source = [_]Sample{ 0.1, 0.2, 0.3, 0.4 };
    engine.setTrackAudioRegions(0, &.{.{
        .start_frame = 0,
        .end_frame = 4,
        .source_start_frame = 0,
        .source_length_frames = 4,
        .source_sample_rate = 48_000,
        .channel_count = 1,
        .stretch_ratio = 2,
        .reverse = true,
        .samples = &source,
    }});

    var output: [8]Sample = undefined;
    engine.process(&output);
    for (output, [_]Sample{ 0.4, 0.4, 0.4, 0.4, 0.3, 0.3, 0.3, 0.3 }) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
    }
}

test "realtime render parks and clears output during offline bounce" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.bounce_active.store(true, .release);
    var output = [_]Sample{1} ** 8;

    engine.renderRealtime(&output);

    try std.testing.expect(engine.bounce_parked.load(.acquire));
    try std.testing.expectEqualSlices(Sample, &([_]Sample{0} ** 8), &output);
}

test "renderTracks pushes filter-cutoff automation into the synth before it processes the block" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.filter_cutoff = 1_000.0; // manual value - automation should override it
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    engine.setTrackSynthParam(0, 21, 0, 21, &.{.{ .beat = 0.0, .value = 5_000.0 }});

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 5_000.0), synth.filter_cutoff, 1.0);

    // Clearing the curve (empty points) falls back to the manual value again
    // - matches gain/pan's own "no automation" fallback, not a frozen value.
    engine.setTrackSynthParam(0, 21, 0, 21, &.{});
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
    engine.setTrackSynthParam(0, 21, 0, 21, &.{.{ .beat = 0.0, .value = 5_000.0 }}); // filter cutoff
    engine.setTrackSynthParam(0, 29, 0, 29, &.{.{ .beat = 0.0, .value = 8.0 }}); // lfo rate
    engine.setTrackSynthParam(0, 34, 0, 34, &.{.{ .beat = 0.0, .value = 0.5 }}); // sub level

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 5_000.0), synth.filter_cutoff, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), synth.lfo_rate_hz, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), synth.sub_level, 1e-3);

    // Clearing one slot frees it without disturbing the other two.
    engine.setTrackSynthParam(0, 29, 0, 29, &.{});
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
        engine.setTrackSynthParam(0, @intCast(i), 0, @intCast(i), &.{.{ .beat = 0.0, .value = 1.0 }});
    }
    const pair = &engine.automation[0];
    for (&pair.synth_slots) |*slot| try std.testing.expect(slot.active.load(.acquire));
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
    const snap = engine.uiSnapshot();
    try std.testing.expect(snap.track_peak[0][0] > 0.01);
    try std.testing.expect(snap.track_peak[0][1] > 0.01);
    try std.testing.expectEqual(@as(f32, 0.0), snap.track_peak[1][0]);
    try std.testing.expectEqual(@as(u64, 0), engine.transport.position_frames);
}

test "sendMidi lands commands through its own queue, same as send" {
    // Live MIDI input dispatches through sendMidi (its own Spsc queue - see
    // Engine.midi_commands's doc comment for why it can't share `commands`
    // with the control/UI thread's `send`), not `send` - drainCommands
    // must still pick it up and apply it the same way.
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);

    try std.testing.expect(engine.sendMidi(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } }));
    engine.process(&block);
    try std.testing.expect(engine.peak[0] > 0.01);
}

test "send and sendMidi commands queued in the same block both land" {
    var synth0 = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth0.deinit();
    var synth1 = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth1.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.trackAt(1).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth0.device()});
    engine.setTrackChain(1, &.{synth1.device()});

    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.sendMidi(.{ .note_on = .{ .track = 1, .note = 64, .velocity = 1.0 } });

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.track_peak[0][0] > 0.01);
    try std.testing.expect(engine.track_peak[1][0] > 0.01);
}

test "browser audition plays off-mixer, with no track and the transport stopped" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    const clip = try std.testing.allocator.alloc(f32, 4_800);
    for (clip) |*s| s.* = 0.5;
    engine.preview.setSamples(clip, "audition");

    var block: [512]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);

    _ = engine.send(.preview_play);
    engine.process(&block);
    try std.testing.expect(engine.peak[0] > 0.01);
    try std.testing.expectEqual(@as(u64, 0), engine.transport.position_frames);

    _ = engine.send(.preview_stop);
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 0.0), engine.peak[0]);
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

test "metronome tolerates an invalid zero-beat time signature" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.transport.time_signature.beats_per_bar = 0;
    engine.metronome_enabled = true;
    engine.transport.play();

    var block: [64]Sample = undefined;
    engine.process(&block);
    try std.testing.expect(engine.metronome.is_accent);

    engine.transport.stop();
    engine.pre_roll_frames_remaining = 1;
    engine.process(&block);
    try std.testing.expect(engine.transport.playing);

    engine.transport.stop();
    _ = engine.send(.{ .record = 1 });
    engine.process(&block);
    try std.testing.expect(engine.pre_roll_frames_remaining > 0);
}

test "metronome handles final transport frame" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.metronome_enabled = true;
    engine.transport.position_frames = std.math.maxInt(u64);
    engine.transport.play();

    var block: [2]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(std.math.maxInt(u64), engine.transport.position_frames);
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
    var comp = testCompressor(-60.0);
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

    var comp = testCompressor(-60.0);
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

test "set_group_mute silences the bus without touching member tracks' own mute flags" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{synth.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    engine.setGroupChain(0, true, &.{});
    _ = engine.send(.{ .set_track_group = .{ .track = 0, .group = 0 } });

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block);
    var loud: f32 = 0.0;
    for (block) |s| loud = @max(loud, @abs(s));
    try std.testing.expect(loud > 0.05); // reaches `out` unmuted

    _ = engine.send(.{ .set_group_mute = .{ .group = 0, .muted = true } });
    for (0..4) |_| engine.process(&block);
    for (block) |s| try std.testing.expectEqual(@as(Sample, 0.0), s); // bus fully silent

    try std.testing.expect(!engine.trackAt(0).muted); // member's own flag untouched

    _ = engine.send(.{ .set_group_mute = .{ .group = 0, .muted = false } });
    for (0..4) |_| engine.process(&block);
    loud = 0.0;
    for (block) |s| loud = @max(loud, @abs(s));
    try std.testing.expect(loud > 0.05); // unmuting restores it
}

test "set_group_solo makes every member audible and silences everything else, without touching member tracks' own solo flags" {
    var synth0 = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth0.deinit();
    var synth1 = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth1.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true }; // will join group 0
    engine.trackAt(1).* = .{ .active = true }; // stays ungrouped
    engine.setTrackChain(0, &.{synth0.device()});
    engine.setTrackChain(1, &.{synth1.device()});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 1.0 } });
    engine.setGroupChain(0, true, &.{});
    _ = engine.send(.{ .set_track_group = .{ .track = 0, .group = 0 } });

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block); // let envelopes settle

    // Solo the group, but mute track 0 directly so any residual output can
    // only be track 1 leaking through - it shouldn't.
    _ = engine.send(.{ .set_track_mute = .{ .track = 0, .muted = true } });
    _ = engine.send(.{ .set_group_solo = .{ .group = 0, .soloed = true } });
    for (0..4) |_| engine.process(&block);
    for (block) |s| try std.testing.expectEqual(@as(Sample, 0.0), s); // track 1 silenced by the group solo

    try std.testing.expect(!engine.trackAt(0).soloed); // member's own flag untouched

    // Unmute track 0: now it's the only thing that should get through
    // (group-soloed, not muted); track 1 stays silenced.
    _ = engine.send(.{ .set_track_mute = .{ .track = 0, .muted = false } });
    for (0..4) |_| engine.process(&block);
    var loud: f32 = 0.0;
    for (block) |s| loud = @max(loud, @abs(s));
    try std.testing.expect(loud > 0.05);

    // Clearing the group solo restores track 1 alongside it.
    _ = engine.send(.{ .set_group_solo = .{ .group = 0, .soloed = false } });
    for (0..4) |_| engine.process(&block);
    _ = engine.send(.{ .set_track_mute = .{ .track = 0, .muted = true } }); // isolate track 1's own contribution
    for (0..4) |_| engine.process(&block);
    loud = 0.0;
    for (block) |s| loud = @max(loud, @abs(s));
    try std.testing.expect(loud > 0.05);
}

test "renderTracks routes a compressor's sidechain detector from a different (source) track" {
    var kick = try PolySynth.init(std.testing.allocator, 48_000);
    defer kick.deinit();
    var bass = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass.deinit();
    var comp = testCompressor(-30.0);

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
    var comp = testCompressor(-30.0);

    // On the heap through `initInPlace`: this test already holds a synth and
    // a drum machine as locals, and an `Engine` by value on top of them is
    // over a megabyte of stack frame that macOS crashed on.
    const engine = try std.testing.allocator.create(Engine);
    defer std.testing.allocator.destroy(engine);
    try Engine.initInPlace(engine, std.testing.allocator, 48_000);
    defer engine.deinit();
    var drum = try testDrumMachine(&engine.transport);
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
    var comp2 = testCompressor(-30.0);
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
    var drum3 = try testDrumMachine(&engine3.transport);
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
    var comp = testCompressor(-30.0);
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    var drum = try testDrumMachine(&engine.transport);
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
    var comp2 = testCompressor(-30.0);
    var engine2 = try Engine.init(std.testing.allocator, 48_000);
    defer engine2.deinit();
    var drum2 = try testDrumMachine(&engine2.transport);
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
    var comp = testCompressor(-30.0);

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
    var comp2 = testCompressor(-30.0);
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

test "a track's aux send taps a group in parallel with its primary route, without replacing it" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();

    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true }; // ungrouped: primary route is straight to `out`
    engine.setTrackChain(0, &.{synth.device()});
    engine.setGroupChain(0, true, &.{}); // empty-chain bus, gain 1.0
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });

    var block_no_send: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block_no_send);
    var loud_no_send: f32 = 0.0;
    for (block_no_send) |s| loud_no_send = @max(loud_no_send, @abs(s));
    try std.testing.expect(loud_no_send > 0.05); // reaches `out` via the primary route alone

    // Same signal now ALSO sent into group 0 at unity - the group's (empty)
    // chain sums straight back into `out` too, so the primary route isn't
    // replaced, it's doubled.
    var sends: TrackSendSlots = @splat(null);
    sends[0] = .{ .target = .{ .group = 0 }, .level = 1.0 };
    engine.setTrackSends(0, sends);
    var block_with_send: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block_with_send);
    var loud_with_send: f32 = 0.0;
    for (block_with_send) |s| loud_with_send = @max(loud_with_send, @abs(s));
    try std.testing.expect(loud_with_send > loud_no_send * 1.5);

    // A muted track sends nothing either - same gate its primary route hits.
    _ = engine.send(.{ .set_track_mute = .{ .track = 0, .muted = true } });
    var block_muted: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block_muted);
    var loud_muted: f32 = 0.0;
    for (block_muted) |s| loud_muted = @max(loud_muted, @abs(s));
    try std.testing.expectEqual(@as(f32, 0.0), loud_muted);
}

test "pre-fader send remains audible with track fader down" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true, .gain = 0 };
    engine.setTrackChain(0, &.{synth.device()});
    engine.setGroupChain(0, true, &.{});
    var sends: TrackSendSlots = @splat(null);
    sends[0] = .{ .target = .{ .group = 0 }, .level = 1, .pre_fader = true };
    engine.setTrackSends(0, sends);
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1 } });

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block);
    var peak: f32 = 0;
    for (block) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.05);
}

test "a compressor on the master chain sidechains off a group bus (group renders before master)" {
    var kick = try PolySynth.init(std.testing.allocator, 48_000);
    defer kick.deinit();
    var bass = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass.deinit();
    var comp = testCompressor(-30.0);

    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true, .group = 0 }; // kick, submixed through group 0
    engine.trackAt(1).* = .{ .active = true }; // quiet bass, straight to master
    engine.setTrackChain(0, &.{kick.device()});
    engine.setTrackChain(1, &.{bass.device()});
    engine.setGroupChain(0, true, &.{});
    // Silence the bus's own contribution to `out` (captured for the
    // detector taps `gscratch` BEFORE this gain multiply, so the capture
    // still carries the full kick) - otherwise the kick would reach `out`
    // through its normal routing regardless of sidechain wiring, and
    // self-detection would trigger just as hard as the routed case,
    // masking the very difference this test exists to measure.
    _ = engine.send(.{ .set_group_gain = .{ .group = 0, .gain = 0.0 } });
    engine.setMasterChain(&.{comp.device()});
    engine.setMasterSidechainSources(&.{.{ .track = 0, .is_group = true }});

    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } }); // loud kick, via the group
    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 0.02 } }); // quiet bass, well under threshold alone

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block); // let envelopes settle

    // No solo here (unlike the track-sourced sidechain test above) - kick
    // must keep rendering normally so it still feeds the group's
    // (pre-gain) capture. `out` is already effectively bass-only: the
    // group's own audible contribution is zeroed via `set_group_gain`
    // above, so there's nothing to isolate with solo.
    for (0..4) |_| engine.process(&block);
    var bass_with_sidechain: f32 = 0.0;
    for (block) |s| bass_with_sidechain = @max(bass_with_sidechain, @abs(s));

    engine.setMasterSidechainSources(&.{null});
    for (0..4) |_| engine.process(&block);
    var bass_without_sidechain: f32 = 0.0;
    for (block) |s| bass_without_sidechain = @max(bass_without_sidechain, @abs(s));

    try std.testing.expect(bass_without_sidechain > 0.001);
    try std.testing.expect(bass_with_sidechain < bass_without_sidechain * 0.5);
}

test "a track-level compressor sidechaining off a group falls back to self-detection (documented ordering ceiling)" {
    // Tracks fully render before any group's own FX chain runs, so a group
    // referenced from a TRACK's own chain never gets captured in time - see
    // `Compressor.SidechainSource.is_group`'s doc comment. This must degrade
    // gracefully (self-detection), never crash or read stale/uninitialized
    // memory.
    var kick = try PolySynth.init(std.testing.allocator, 48_000);
    defer kick.deinit();
    var bass = try PolySynth.init(std.testing.allocator, 48_000);
    defer bass.deinit();
    var comp = testCompressor(-30.0);

    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true, .group = 0 };
    engine.trackAt(1).* = .{ .active = true };
    engine.setTrackChain(0, &.{kick.device()});
    engine.setTrackChain(1, &.{ bass.device(), comp.device() });
    engine.setGroupChain(0, true, &.{});
    engine.setTrackSidechainSources(1, &.{ null, .{ .track = 0, .is_group = true } });

    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1.0 } });
    _ = engine.send(.{ .note_on = .{ .track = 1, .note = 60, .velocity = 0.02 } });

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block);

    _ = engine.send(.{ .set_track_solo = .{ .track = 1, .soloed = true } });
    for (0..4) |_| engine.process(&block);
    for (block) |s| try std.testing.expect(std.math.isFinite(s)); // no crash, no garbage
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

    try std.testing.expectEqual(@as(u16, 1), engine.track_count.load(.acquire));
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

    try std.testing.expectEqual(@as(u16, 3), engine.track_count.load(.acquire));
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

    try std.testing.expectEqual(@as(u16, 3), engine.track_count.load(.acquire));
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
    engine.setTrackSynthParam(2, 21, 0, 21, &.{.{ .beat = 0.0, .value = 5_000.0 }});
    engine.setTrackSidechainSources(2, &.{ null, .{ .track = 7 } });

    engine.applyDeleteTrack(1, 3);

    // Track 2's rows moved down to slot 1 alongside its TrackState...
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), engine.automation[1].gain.valueAt(0.0).?, 1e-6);
    try std.testing.expect(engine.automation[1].synth_slots[21].active.load(.acquire));
    try std.testing.expectEqual(@as(u16, 7), engine.track_sidechain[1][1].?.track);
    // ...and the vacated last slot is fully cleared, not left stale.
    try std.testing.expect(engine.automation[2].gain.valueAt(0.0) == null);
    try std.testing.expect(!engine.automation[2].synth_slots[21].active.load(.acquire));
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

test "out-of-range track commands do not target the last slot" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    const last: u16 = max_tracks - 1;
    try std.testing.expectEqual(@as(f32, 1.0), engine.trackAt(last).gain);
    _ = engine.send(.{ .set_track_gain = .{ .track = max_tracks, .gain = 0.25 } });
    var block: [64]Sample = undefined;
    engine.process(&block);
    try std.testing.expectEqual(@as(f32, 1.0), engine.trackAt(last).gain);
}

test "a controller drives a synth param on whatever track its target names" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    synth.filter_cutoff = 1_000.0;
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(1).* = .{ .active = true };
    engine.setTrackChain(1, &.{synth.device()});

    var bank: [max_controllers]?controller_mod.Controller = @splat(null);
    bank[0] = .{ .shape = .sine, .beats = 4.0, .depth = 1.0 };
    // Cutoff (param 21) centred at 1 kHz over the synth's own 20..20k range.
    bank[0].?.targets[0] = .{
        .track = 1,
        .param_id = 21,
        .center = 1_000.0,
        .lo = 20.0,
        .hi = 20_000.0,
    };
    engine.setControllers(bank);

    var block: [512]Sample = undefined;
    // Beat 0: a sine is at zero, so the param sits at its centre.
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1_000.0), synth.filter_cutoff, 1.0);

    // A quarter of the way through the 4-beat cycle the sine peaks, which
    // pushes the cutoff half the range above centre.
    engine.transport.position_frames = engine.transport.framesAtBeats(1.0);
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1_000.0 + 9_990.0), synth.filter_cutoff, 5.0);

    // The same target on a different track leaves this one alone.
    bank[0].?.targets[0].?.track = 0;
    engine.setControllers(bank);
    synth.filter_cutoff = 1_000.0;
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1_000.0), synth.filter_cutoff, 1.0);

    // Clearing the bank stops driving it too.
    engine.setControllers(@splat(null));
    synth.filter_cutoff = 1_000.0;
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1_000.0), synth.filter_cutoff, 1.0);
}

test "a learned CC drives its own target's param and stops reaching the routed track" {
    var bound_synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer bound_synth.deinit();
    var routed_synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer routed_synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true };
    engine.setTrackChain(0, &.{routed_synth.device()});
    engine.trackAt(1).* = .{ .active = true };
    engine.setTrackChain(1, &.{bound_synth.device()});

    var map: [max_cc_bindings]?controller_mod.CcBinding = @splat(null);
    map[0] = .{
        .cc = 74,
        .target = .{
            .track = 1,
            .param_id = 21, // filter cutoff
            .center = 1_000.0,
            .lo = 20.0,
            .hi = 20_000.0,
        },
    };
    engine.setCcBindings(map);

    var block: [512]Sample = undefined;
    // A hardware knob is absolute over the whole range: full scale is the top.
    _ = engine.sendMidi(.{ .cc = .{ .track = 0, .cc = 74, .value = 127 } });
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 20_000.0), bound_synth.filter_cutoff, 1.0);

    // CC7 is the gain `applyCC` handles; unbound, it still reaches the
    // track the MIDI input is routed to and nothing else.
    routed_synth.gain = 1.0;
    bound_synth.gain = 1.0;
    _ = engine.sendMidi(.{ .cc = .{ .track = 0, .cc = 7, .value = 0 } });
    engine.process(&block);
    try std.testing.expect(routed_synth.gain < 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bound_synth.gain, 1e-6);

    // Learning CC7 takes it over: the routed track's gain stops following it.
    map[1] = .{ .cc = 7, .target = .{
        .track = 1,
        .param_id = 21,
        .center = 1_000.0,
        .lo = 20.0,
        .hi = 20_000.0,
    } };
    engine.setCcBindings(map);
    routed_synth.gain = 1.0;
    _ = engine.sendMidi(.{ .cc = .{ .track = 0, .cc = 7, .value = 0 } });
    engine.process(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), routed_synth.gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), bound_synth.filter_cutoff, 1.0);
}

test "lastCc reports every CC, including a repeat of the same number" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    try std.testing.expect(engine.lastCc() == null);

    var block: [64]Sample = undefined;
    _ = engine.sendMidi(.{ .cc = .{ .track = 0, .cc = 0, .value = 40 } });
    engine.process(&block);
    // CC 0 has to read as a real message, not as "nothing yet".
    const first = engine.lastCc().?;
    try std.testing.expectEqual(@as(u7, 0), first.cc);

    _ = engine.sendMidi(.{ .cc = .{ .track = 0, .cc = 0, .value = 41 } });
    engine.process(&block);
    const second = engine.lastCc().?;
    try std.testing.expectEqual(@as(u7, 0), second.cc);
    try std.testing.expect(second.seq != first.seq);
}

test "send automation drives a send parked at zero" {
    var synth = try PolySynth.init(std.testing.allocator, 48_000);
    defer synth.deinit();
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    engine.trackAt(0).* = .{ .active = true, .gain = 0 }; // fader down: only the send can be heard
    engine.setTrackChain(0, &.{synth.device()});
    engine.setGroupChain(0, true, &.{});

    // The manual level is the automation lane's starting point, not a gate:
    // parking it at 0 and drawing the ride in the lane is the ordinary way
    // to automate a send.
    var sends: TrackSendSlots = @splat(null);
    sends[0] = .{ .target = .{ .group = 0 }, .level = 0, .pre_fader = true };
    engine.setTrackSends(0, sends);
    engine.setMixAutomation(.{ .send_level = .{ .track = 0, .slot = 0 } }, &.{.{ .beat = 0, .value = 1.0 }});
    _ = engine.send(.{ .note_on = .{ .track = 0, .note = 60, .velocity = 1 } });

    var block: [512]Sample = undefined;
    for (0..4) |_| engine.process(&block);
    var peak: f32 = 0;
    for (block) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.05);
}

test "a one-bar count-in in 6/8 lasts one bar, not two" {
    var engine = try Engine.init(std.testing.allocator, 48_000);
    defer engine.deinit();
    _ = engine.send(.{ .set_time_signature = 6 });
    _ = engine.send(.{ .set_meter_denominator = 8 });
    _ = engine.send(.{ .record = 1 });
    var block: [512]Sample = undefined;
    engine.process(&block);

    // 120bpm at 48kHz is 24_000 frames per quarter note. A 6/8 bar is three
    // of them - the same length `Transport.positionBarBeat` and the loop
    // region give it - not six.
    try std.testing.expectApproxEqAbs(
        @as(f64, 3.0 * 24_000.0),
        @as(f64, @floatFromInt(engine.pre_roll_frames_remaining + 256)),
        1.0,
    );
}
