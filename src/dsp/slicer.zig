//! Step-sequenced sample chopper - the "Slicer" instrument. One shared
//! sample buffer is chopped into up to `max_slices` independently-
//! triggerable regions ("slices"), each with its own start/end/pitch/gain/
//! pan/reverse/ADSR - the same per-region params `dsp/sampler.zig`'s
//! standalone Sampler and `dsp/drum_sampler.zig`'s drum pads already carry,
//! sharing `dsp/pad.zig`'s `renderVoice` engine unmodified.
//!
//! Unlike DrumMachine (`max_pads` independent Samplers, each owning its own
//! clip buffer), every slice's `Pad.samples` here aliases the SAME
//! underlying buffer (a slice is just `{ptr, len}`, so this costs nothing) -
//! `sliceInto(n)` just sets each slice's `start_norm`/`end_norm` to an equal
//! 1/n fraction of the one shared clip. That's the whole trick that makes
//! "one sample, N independently playable chops" cheap.
//!
//! Each slice's step data is a compact MIDI note (`midi`, a per-slice,
//! heap-owned slice sized to `step_count`) - the same architecture
//! `dsp/drum_sampler.zig` moved to, and for the same reason: the old `u64`
//! bitmask plus parallel `vel` array is exactly why steps were once
//! hard-capped at 64 (one word's bit width, not a chosen musical limit).
//! Pattern positions use fixed 32 ticks per beat; editor grid division only
//! changes navigation and rendering stride. The note type
//! itself (`MidiNote`, and the `Cond` trig conditions with it) is
//! DrumMachine's, imported rather than re-declared, so a step means exactly
//! the same thing in both grids and the shared editors/renderers can treat
//! the two machines alike.
//!
//! The step sequencer is shared with DrumMachine's, in
//! `dsp/step_grid_ops.zig`: both types carry the same
//! `song_mode`/`swing`/`next_step_k`/`song_clips` state under the same field
//! names, so `scanBlock`/`fireSongStep`/`scheduleNote`/`drainRolls`/
//! `trigFires` take them as `anytype`, as do the ~20 per-step grid accessors
//! and the whole-grid transforms (`clearGrid`, `euclidLane`, `rotateLane`,
//! …). What genuinely diverges and stays here is voice allocation and
//! render: a slice owns a small pool aliasing one shared buffer, a drum pad
//! is a whole embedded Sampler.
//!
//! `midi`/`Variant.midi`/`SongClip.midi` are heap-owned per-slice slices
//! rather than inline `[max_slices][max_steps]` arrays for the same reason
//! DrumMachine's are: at u16's ceiling an inline array would blow up
//! `@sizeOf(Slicer)` across the 8-slot variant bank into multi-MB territory,
//! and `init`/`dupe` return this struct by value. Resizes take `sample_lock`
//! (already held by `processBlock` for the whole block) around the swap so
//! the audio thread never observes a torn slice header; per-cell writes stay
//! lock-free, the same tolerated convention as `choke_group`.

const std = @import("std");
const types = @import("../core/types.zig");
const dsp = @import("device.zig");
const Transport = @import("../transport.zig").Transport;
const pad_mod = @import("pad.zig");
const Pad = pad_mod.Pad;
const Voice = pad_mod.Voice;
const DrumMachine = @import("drum_sampler.zig").DrumMachine;
const Note = @import("pattern.zig").Note;
const onset = @import("onset.zig");
const tempo = @import("tempo.zig");
const pitch = @import("pitch.zig");
const step_grid_ops = @import("step_grid_ops.zig");

const Sample = types.Sample;

pub const Slicer = struct {
    pub const max_slices: u8 = 64;
    /// Step-grid capacity: the u16 step index's own ceiling, not a musical
    /// wall - see `DrumMachine.max_steps`, which this mirrors.
    pub const max_steps: u16 = std.math.maxInt(u16);

    /// The drum machine's note and trig-condition types, reused verbatim: a
    /// slicer step and a drum step carry the same payload (velocity, length,
    /// chance, condition, micro-timing, retrig, tune), so sharing the type
    /// is what lets the grids, the editors and the save format treat them
    /// alike instead of growing a second near-identical set of each.
    pub const MidiNote = DrumMachine.MidiNote;
    pub const Cond = DrumMachine.Cond;
    /// The tail of an in-flight roll - see `DrumMachine.Roll`.
    pub const Roll = DrumMachine.Roll;
    /// Max pattern variants (A..H) one slicer can hold - same bank size as
    /// `DrumMachine.max_variants`.
    pub const max_variants: u8 = 8;
    /// Max clips one lane can hold for song-mode playback (see `song_clips`).
    pub const max_song_clips: u16 = 256;
    /// Max choke groups a slice can belong to (0 = no group, ungated).
    pub const max_choke_groups: u8 = 4;
    /// Small per-slice voice pool - slices are short one-shots retriggered
    /// often (stutters, rolls), so a few overlapping voices covers real use
    /// without Sampler's full 16 (a slicer track can have up to 64 of these
    /// pools live at once, unlike Sampler's single pad).
    pub const max_voices_per_slice: u8 = 4;
    /// `set_param`/`set_param_abs` ids are `slice << 5 | param` - same shape
    /// DrumMachine.paramId uses for its own per-pad params (widened from a
    /// 4-bit to a 5-bit param field alongside it - see that constant's doc
    /// comment).
    pub const param_stride: u16 = 32;

    pub const vel_full: u8 = DrumMachine.vel_full;
    pub const velGain = DrumMachine.velGain;

    pub const swing_min: f32 = 50.0;
    pub const swing_max: f32 = 75.0;

    const SliceVoice = struct {
        active: bool = false,
        age: u64 = 0,
        v: Voice = .{},
    };

    /// A step's note tagged with the row that owns it - `pitch` is the slice
    /// index, the same "pad tag, not a pitch" convention
    /// `DrumMachine.gridNote` documents.
    pub const gridNote = DrumMachine.gridNote;

    /// Allocate `max_slices` fresh per-slice note slices, each `len` long and
    /// null-filled. The building block every resize/dupe path shares.
    pub fn allocMidi(allocator: std.mem.Allocator, len: u16) ![max_slices][]?MidiNote {
        var out: [max_slices][]?MidiNote = undefined;
        var i: usize = 0;
        errdefer for (out[0..i]) |s| allocator.free(s);
        while (i < max_slices) : (i += 1) {
            out[i] = try allocator.alloc(?MidiNote, len);
            @memset(out[i], null);
        }
        return out;
    }

    /// Free every slice's row. Safe (a no-op) on still-empty (`&.{}`) slots,
    /// e.g. a never-materialized variant bank slot.
    pub fn freeMidi(allocator: std.mem.Allocator, midi: *[max_slices][]?MidiNote) void {
        for (midi) |s| allocator.free(s);
    }

    /// Deep-copy every slice's row into fresh allocations.
    pub fn dupeMidi(allocator: std.mem.Allocator, src: *const [max_slices][]?MidiNote) ![max_slices][]?MidiNote {
        var out: [max_slices][]?MidiNote = undefined;
        var i: usize = 0;
        errdefer for (out[0..i]) |s| allocator.free(s);
        while (i < max_slices) : (i += 1) {
            out[i] = try allocator.dupe(?MidiNote, src[i]);
        }
        return out;
    }

    /// One pattern variant: a bank slot for the step grid. The active variant
    /// lives in the live `midi`/`step_count` fields; inactive ones rest here
    /// as plain data (control thread only). `midi` is heap-owned - see the
    /// file's top doc comment. Mirrors `DrumMachine.Variant`, rows indexed by
    /// slice instead of pad.
    pub const Variant = struct {
        midi: [max_slices][]?MidiNote = [_][]?MidiNote{&.{}} ** max_slices,
        step_count: u16 = DrumMachine.ticks_per_beat * 4,
        /// Canonical musical ticks in one quarter-note beat.
        steps_per_beat: u8 = DrumMachine.ticks_per_beat,
    };

    /// A slicer clip flattened onto the arrangement's step timeline - same
    /// shape and repeat-to-fill-span semantics as `DrumMachine.SongClip` (the
    /// audio thread reads these under `sample_lock`, which `processBlock`
    /// already holds). `midi` is heap-owned: `setSongClips` takes ownership
    /// of whatever is passed in (build fresh rows per call, e.g. via
    /// `dupeMidi`, and don't reuse or free them yourself afterward).
    pub const SongClip = struct {
        start_step: u32,
        span_steps: u32,
        step_count: u16,
        steps_per_beat: u8 = DrumMachine.ticks_per_beat,
        midi: [max_slices][]?MidiNote,
    };

    allocator: std.mem.Allocator,
    sample_rate: u32,
    transport: *const Transport,

    /// Guards `samples` (and every slice's aliasing `Pad.samples`) against
    /// concurrent reads (audio thread) and writes (control thread calling
    /// `loadWav`/`sliceInto`) - mirrors `Sampler.pad_lock`. Ordinary per-slice
    /// param edits (gain, pan, start/end nudge, ...) are plain unlocked
    /// writes, same race-tolerant convention `Sampler.adjustParam`/
    /// `DrumMachine.choke_group` already use - worst case one stale block,
    /// never a crash, since nothing here reallocates.
    sample_lock: std.atomic.Mutex = .unlocked,
    /// The one shared clip every slice's `Pad.samples` aliases.
    samples: []f32,
    name: [8]u8 = [_]u8{' '} ** 8,
    /// True when the audio was loaded by the user (`:load`) - only
    /// user audio is exported to the project's audio cache on save, same
    /// convention `Pad.user_sample` documents.
    user_sample: bool = false,
    /// FLAC encode of `samples`, cached across saves - see `Pad.cached_flac`
    /// and `AudioSource.cached_flac`. Invalidated by `loadWav`, freed by
    /// `deinit`, never copied by `dupe`.
    cached_flac: ?[]const u8 = null,
    /// Tempo and root pitch class the loaded clip's file name declared (see
    /// `tempo.bpmFromName`/`pitch.rootFromName`), 0/null when it declared
    /// neither. `:bpm-sync` trusts these over the analysers. Deliberately
    /// not saved: the cache keeps the audio, not the name it arrived
    /// under, and a new snapshot field costs a `file_version` bump that
    /// rejects every existing project (see FORMAT.md).
    clip_bpm: f32 = 0,
    clip_root: ?u4 = null,

    /// Per-slice params. `slices[i].samples` always aliases `self.samples` -
    /// never independently allocated or freed; `deinit` frees `self.samples`
    /// exactly once. Slots at/past `slice_count` are inert (never triggered,
    /// never rendered) but still point at valid memory, so no branch needs a
    /// null-check the way DrumMachine's lazily-materialized pads do.
    slices: [max_slices]Pad = undefined,
    /// How many of `slices` are actually chopped out. Zero until `:slice`
    /// runs - an unsliced Slicer is silent, nothing to trigger, same as a
    /// never-loaded drum pad.
    slice_count: u8 = 0,
    voices: [max_slices][max_voices_per_slice]SliceVoice = undefined,
    next_age: u64 = 0,

    /// Canonical live pattern: one heap-owned, `step_count`-long row per
    /// slice. Control thread writes (resize under `sample_lock`; per-cell
    /// writes lock-free, matching `choke_group`'s convention), audio thread
    /// reads directly in `processBlock`. Always mirrors the active variant;
    /// edits land here and are synced back to `variants[variant]` when
    /// switching away.
    midi: [max_slices][]?MidiNote,
    /// Cached row length of every entry in `midi` - control thread writes,
    /// audio thread reads (plain field, no atomics, same convention as
    /// `choke_group`).
    step_count: u16 = DrumMachine.ticks_per_beat * 4,
    /// Canonical timing resolution. Always `DrumMachine.ticks_per_beat`.
    steps_per_beat: u8 = DrumMachine.ticks_per_beat,
    swing: std.atomic.Value(f32) = .init(50.0),

    // ── Pattern variants (control thread only) ──────────────────────────────
    /// Bank slots. Slot `variant` is stale while active - read it through
    /// `variantData`, which pulls the live state instead. Only slots
    /// `0..variant_count` ever hold a real allocation; every mutator that
    /// touches this array must iterate that range, not `0..max_variants` -
    /// see `DrumMachine.variants`, which has the same ownership rule.
    variants: [max_variants]Variant = [_]Variant{.{}} ** max_variants,
    variant_count: u8 = 1,
    /// Index of the active variant (the one in the live `midi`).
    variant: u8 = 0,

    /// Per-slice choke group (0 = none). Grouped slices opt back into the
    /// classic cut-the-previous-hit behavior `triggerSlice` alone
    /// deliberately skips - see `chokeTrigger`.
    choke_group: [max_slices]u8 = [_]u8{0} ** max_slices,
    /// Per-slice loop length in steps, 0 = follow the pattern - Elektron's
    /// per-track lengths, see `DrumMachine.pad_len` for the full rationale.
    /// Machine-level (not per-variant) and clamped at use time, same as
    /// `choke_group`/`swing`, which is also why song mode picks it up free.
    slice_len: [max_slices]u16 = [_]u16{0} ** max_slices,
    /// Performance switch the `fill`/`not_fill` trig conditions read - see
    /// `DrumMachine.fill_on`.
    fill_on: std.atomic.Value(bool) = .init(false),
    /// Hits the sequencer has decided on but not yet emitted, one slot per
    /// slice (audio thread only) - a roll's tail lands blocks after the step
    /// that started it, and a `micro`-shifted hit can land before its own
    /// step boundary. See `DrumMachine.rolls`.
    rolls: [max_slices]?Roll = [_]?Roll{null} ** max_slices,

    /// When true, processBlock fires from `song_clips` under the playhead
    /// instead of looping the live pattern - same switch DrumMachine has.
    song_mode: bool = false,
    /// Heap slice of length `max_song_clips` (owned, freed in deinit) for
    /// the same struct-size reason as `DrumMachine.song_clips`.
    song_clips: []SongClip,
    song_clip_count: u16 = 0,
    /// Whole-arrangement length in steps; silent past this (no wrap).
    song_length_steps: u32 = 0,
    /// Resolution of the absolute song timeline. The same 32 ticks per beat
    /// the live pattern runs at (see `steps_per_beat`), so every editor grid
    /// position stays exact across the two.
    song_steps_per_beat: u8 = DrumMachine.ticks_per_beat,

    // Audio-thread-only state:
    next_step_k: u64 = 0,
    last_pos_frames: u64 = 0,
    current_step: std.atomic.Value(u16) = .init(0),

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, transport: *const Transport) !Slicer {
        const samples = try allocator.alloc(f32, 0);
        errdefer allocator.free(samples);
        const song_clips = try allocator.alloc(SongClip, max_song_clips);
        errdefer allocator.free(song_clips);
        const default_step_count: u16 = DrumMachine.ticks_per_beat * 4;
        var midi = try allocMidi(allocator, default_step_count);
        errdefer freeMidi(allocator, &midi);
        var self: Slicer = .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .transport = transport,
            .samples = samples,
            .song_clips = song_clips,
            .midi = midi,
            .step_count = default_step_count,
        };
        for (&self.slices) |*p| p.* = .{ .samples = samples };
        // zig fmt: off
        for (&self.voices) |*row| for (row) |*v| { v.* = .{}; };
        // zig fmt: on
        return self;
    }

    pub fn deinit(self: *Slicer) void {
        self.allocator.free(self.samples);
        if (self.cached_flac) |flac| self.allocator.free(flac);
        for (self.song_clips[0..self.song_clip_count]) |*clip| freeMidi(self.allocator, &clip.midi);
        self.allocator.free(self.song_clips);
        freeMidi(self.allocator, &self.midi);
        for (self.variants[0..self.variant_count]) |*v| freeMidi(self.allocator, &v.midi);
    }

    /// Deep copy for track duplication: the clip audio and every heap-owned
    /// note row get fresh allocations so the two slicers share no memory;
    /// every slice re-aliases the NEW buffer. Voice state resets - no
    /// mid-flight hit worth carrying. Song-mode state isn't carried, same as
    /// `DrumMachine.dupe`: the caller rebuilds it from the arrangement.
    pub fn dupe(self: *const Slicer) !Slicer {
        var copy = try Slicer.init(self.allocator, self.sample_rate, self.transport);
        errdefer copy.deinit();

        const samples = try self.allocator.dupe(f32, self.samples);
        self.allocator.free(copy.samples);
        copy.samples = samples;
        copy.slices = self.slices;
        copy.slice_count = self.slice_count;
        for (&copy.slices) |*p| p.samples = copy.samples;
        copy.name = self.name;
        copy.user_sample = self.user_sample;
        // What the clip's file name declared, which is what `:bpm-sync`
        // trusts over the analysers - the duplicate holds the same audio, so
        // it has to know the same thing about it.
        copy.clip_bpm = self.clip_bpm;
        copy.clip_root = self.clip_root;

        const midi = try dupeMidi(self.allocator, &self.midi);
        freeMidi(copy.allocator, &copy.midi);
        copy.midi = midi;
        copy.step_count = self.step_count;
        copy.steps_per_beat = self.steps_per_beat;
        copy.swing.store(self.swing.load(.monotonic), .monotonic);
        copy.choke_group = self.choke_group;
        copy.slice_len = self.slice_len;

        // Target count first (not after the loop) so a mid-loop allocation
        // failure leaves `copy.deinit()` freeing exactly the intended range -
        // see `DrumMachine.dupe`'s identical comment.
        copy.variant_count = self.variant_count;
        for (self.variants[0..self.variant_count], 0..) |*src_slot, i| {
            copy.variants[i] = .{
                .midi = try dupeMidi(self.allocator, &src_slot.midi),
                .step_count = src_slot.step_count,
                .steps_per_beat = src_slot.steps_per_beat,
            };
        }
        copy.variant = self.variant;
        return copy;
    }

    pub const device = dsp.deviceOf(@This());

    pub fn clipName(self: *const Slicer) []const u8 {
        return pad_mod.trimmedName(&self.name);
    }

    /// Set the display name directly, independent of the loaded audio -
    /// mirrors `Sampler.rename`, and is what `:rename` reaches while a
    /// slicer editor is open.
    pub fn rename(self: *Slicer, name: []const u8) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        self.name = pad_mod.fixedName(name);
    }

    // -----------------------------------------------------------------------
    // Loading + slicing (control thread only, not while audio thread runs)

    /// Best-effort check for whether a clip is loaded - used by editors
    /// deciding whether to show an empty state (or, for the GUI/TUI slicer
    /// entry point, jump straight to the file browser instead). Not the
    /// audio thread's own gate, so a missed lock just reports "has audio"
    /// rather than spinning.
    pub fn hasAudio(self: *Slicer) bool {
        if (!self.sample_lock.tryLock()) return true;
        defer self.sample_lock.unlock();
        return self.samples.len > 0;
    }

    /// Parse raw WAV bytes into the shared clip. Resamples to engine rate if
    /// needed. When `reset_slices` is true (the interactive `:load`
    /// path), clears every slice - the old boundaries (fractions of the OLD
    /// clip's length) are meaningless against new audio, so the user
    /// re-chops with `:slice` afterward. `reset_slices = false` is for
    /// restoring a saved project: persist.zig applies each slice's saved
    /// start/end/gain/etc. BEFORE the audio bytes are read back from the
    /// audio cache, so this must only re-point every slice's `.samples`
    /// at the fresh buffer without touching `slice_count` or any slice's own
    /// params, or the just-restored slicing would be wiped out from under it.
    pub fn loadWav(self: *Slicer, wav_data: []const u8, name: []const u8, reset_slices: bool) !void {
        const samples = try pad_mod.decodeWav(self.allocator, wav_data, self.sample_rate);

        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        self.allocator.free(self.samples);
        if (self.cached_flac) |flac| self.allocator.free(flac);
        self.cached_flac = null;
        self.samples = samples;
        self.name = pad_mod.fixedName(name);
        // Read before `fixedName` throws the rest of the name away - eight
        // characters is nowhere near enough to hold "..._80_..._Gmin".
        self.clip_bpm = tempo.bpmFromName(name) orelse 0;
        self.clip_root = pitch.rootFromName(name);
        self.user_sample = true;
        if (reset_slices) {
            self.slice_count = 0;
            for (&self.slices) |*p| p.* = .{ .samples = samples };
        } else {
            for (&self.slices) |*p| {
                p.samples = samples;
                pad_mod.clampTimeParamsToDuration(p, self.sample_rate);
            }
        }
        self.clearVoices();
    }

    /// Equal-divide the shared clip into `n` regions (clamped to
    /// `1..=max_slices`), each a fresh default-params slice spanning its own
    /// 1/n fraction. Existing per-slice pattern/velocity data past the new
    /// `n` stays in the atomics (harmless - `processBlock` only ever reads
    /// pattern bits for `slice_idx < slice_count`) so re-slicing to a larger
    /// `n` later doesn't lose earlier programming.
    pub fn sliceInto(self: *Slicer, n: u8) void {
        const count = std.math.clamp(n, 1, max_slices);
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        const step_norm = 1.0 / @as(f32, @floatFromInt(count));
        for (0..count) |i| {
            self.slices[i] = .{
                .samples = self.samples,
                .start_norm = @as(f32, @floatFromInt(i)) * step_norm,
                .end_norm = @as(f32, @floatFromInt(i + 1)) * step_norm,
                .retrig = true,
            };
            // Same mono-chop default as `chopAt` - see its comment.
            self.choke_group[i] = 1;
        }
        self.slice_count = count;
        self.clearVoices();
    }

    /// Re-chop at detected transients (the MPC "slice at attacks" workflow):
    /// contiguous fresh-params regions, one per onset, first always anchored
    /// at 0. `sensitivity` 1 (only the hardest hits) .. 9 (every flutter),
    /// 5 = default. Returns the new slice count (1 = nothing detected, the
    /// whole clip as one slice).
    pub fn chopTransients(self: *Slicer, sensitivity: u8) u8 {
        var positions: [max_slices]f32 = undefined;
        const n = detectOnsets(self.samples, self.sample_rate, sensitivity, &positions);
        self.chopAt(positions[0..n]);
        return self.slice_count;
    }

    /// Serato's "Set Random": chop into `n` slices at random boundaries
    /// rather than at transients or on an even grid - the dice roll that
    /// turns a loop you know too well into chops you would never have drawn
    /// by hand. Cuts are drawn from a grid four times finer than the slice
    /// count: uneven enough to be worth rolling, coarse enough that no slice
    /// comes out too short to hear. Partial Fisher-Yates over that grid
    /// rather than rejection sampling, so a repeated draw can't spin.
    /// Returns the new slice count.
    pub fn chopRandom(self: *Slicer, n: u8, rand: std.Random) u8 {
        const count = std.math.clamp(n, 1, max_slices);
        if (count == 1) {
            self.sliceInto(1);
            return self.slice_count;
        }
        const res: usize = @as(usize, count) * 4;
        var grid: [@as(usize, max_slices) * 4 - 1]u8 = undefined;
        const pool = grid[0 .. res - 1];
        for (pool, 0..) |*g, i| g.* = @intCast(i + 1);
        for (0..count - 1) |i| {
            const j = i + rand.uintLessThan(usize, pool.len - i);
            std.mem.swap(u8, &pool[i], &pool[j]);
        }
        const cuts = pool[0 .. count - 1];
        std.mem.sort(u8, cuts, {}, std.sort.asc(u8));

        var positions: [max_slices]f32 = undefined;
        positions[0] = 0.0;
        const res_f: f32 = @floatFromInt(res);
        for (cuts, 1..) |c, k| positions[k] = @as(f32, @floatFromInt(c)) / res_f;
        self.chopAt(positions[0..count]);
        return self.slice_count;
    }

    /// Spread `step` semitones per slice across the whole chop (slice 0
    /// unchanged, slice 1 at `step`, ...) - Serato's "pitch a chop across
    /// the pads" trick, which turns one hit into a playable scale down the
    /// grid. Clamped to the pad pitch range, so a big step flattens out at
    /// the top rather than wrapping.
    pub fn spreadPitch(self: *Slicer, step: f32) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (0..self.slice_count) |i| {
            const semis = step * @as(f32, @floatFromInt(i));
            pad_mod.setParamAbsolute(&self.slices[i], pad_mod.pitch_id, semis);
        }
    }

    /// Set every live slice's `stretch_ratio` at once - the slices all view
    /// one clip, so fitting that clip to the project tempo is a single
    /// setting, not a per-slice edit. Same clamp as a manual nudge.
    pub fn stretchAll(self: *Slicer, ratio: f32) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (0..self.slice_count) |i| {
            pad_mod.setParamAbsolute(&self.slices[i], pad_mod.stretch_id, ratio);
        }
    }

    /// Set every live slice's pitch together, matching `stretchAll`.
    pub fn pitchAll(self: *Slicer, semitones: f32) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (0..self.slice_count) |i| {
            pad_mod.setParamAbsolute(&self.slices[i], pad_mod.pitch_id, semitones);
        }
    }

    /// Set every live slice's warp method together, matching `stretchAll`.
    /// One clip means one kind of material, so the algorithm that suits it is
    /// a clip-wide choice the same way the stretch ratio is.
    pub fn warpAll(self: *Slicer, method: pad_mod.WarpMethod) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (0..self.slice_count) |i| {
            self.slices[i].warp_method = method;
        }
    }

    /// Cycle all live slices to the next play mode as one. Mixed state
    /// resolves to whatever comes after slice 0's mode, so the clip always
    /// lands uniform in one keypress.
    pub fn cycleModeAll(self: *Slicer) pad_mod.PlayMode {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        if (self.slice_count == 0) return .one_shot;
        const n = pad_mod.play_mode_names.len;
        const next: pad_mod.PlayMode = @enumFromInt((@intFromEnum(pad_mod.playMode(&self.slices[0])) + 1) % n);
        for (self.slices[0..self.slice_count]) |*slice| pad_mod.setPlayMode(slice, next);
        return next;
    }

    /// Chop into contiguous regions whose starts are `positions` (ascending
    /// fractions of the clip, first entry treated as 0); each region ends
    /// where the next begins, the last at 1.0.
    pub fn chopAt(self: *Slicer, positions: []const f32) void {
        const count: u8 = @intCast(std.math.clamp(positions.len, 1, max_slices));
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        var start: f32 = 0.0;
        for (0..count) |i| {
            const next_raw = if (i + 1 < count) positions[i + 1] else 1.0;
            const next = if (std.math.isFinite(next_raw))
                std.math.clamp(next_raw, start, 1.0)
            else
                start;
            self.slices[i] = .{
                .samples = self.samples,
                .start_norm = start,
                .end_norm = if (i + 1 < count) next else 1.0,
                .retrig = true,
            };
            // Fresh chops share one choke group: slices of the same break
            // should never overlap each other (the MPC "mono chop" feel -
            // see `chokeTriggerTuned`), or the break turns to mud the moment
            // two slices land close together. Ungroup individual slices
            // afterward via `cycleChokeGroup` if independent polyphony is
            // wanted instead.
            self.choke_group[i] = 1;
            start = next;
        }
        self.slice_count = count;
        self.clearVoices();
    }

    /// Split the cursor slice at its region midpoint: the new right half is
    /// inserted at `idx + 1` (inheriting the left half's params), and every
    /// later slice - including its pattern/velocity rows - shifts down one.
    /// Returns false when full or `idx` is out of range.
    pub fn splitSlice(self: *Slicer, idx: u8) bool {
        if (idx >= self.slice_count or self.slice_count >= max_slices) return false;
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        var i: usize = self.slice_count;
        while (i > idx + 1) : (i -= 1) {
            self.slices[i] = self.slices[i - 1];
            // Rows move by swapping the slice headers, not by copying cells:
            // every row is the same `step_count` length, so a swap is both
            // cheaper and allocation-free.
            std.mem.swap([]?MidiNote, &self.midi[i], &self.midi[i - 1]);
            self.slice_len[i] = self.slice_len[i - 1];
            self.choke_group[i] = self.choke_group[i - 1];
        }
        const left = &self.slices[idx];
        const mid = left.start_norm + (left.end_norm - left.start_norm) / 2.0;
        var right = left.*;
        right.start_norm = mid;
        left.end_norm = mid;
        self.slices[idx + 1] = right;
        // The new right half starts silent - it inherited its sound from the
        // left (params and choke group), not its programming.
        self.clearRow(idx + 1);
        self.slice_len[idx + 1] = 0;
        self.choke_group[idx + 1] = self.choke_group[idx];
        self.slice_count += 1;
        self.clearVoices();
        return true;
    }

    /// Merge the cursor slice with the one after it: the region extends to
    /// the right slice's end, both rows are combined (the louder note wins
    /// where two land on the same step), and every later slice shifts up one.
    /// Returns false when `idx` is the last slice or out of range.
    pub fn mergeSliceRight(self: *Slicer, idx: u8) bool {
        if (idx >= self.slice_count or @as(u16, idx) + 1 >= self.slice_count) return false;
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        self.slices[idx].end_norm = self.slices[idx + 1].end_norm;
        for (self.midi[idx], self.midi[idx + 1]) |*dst, src| {
            const incoming = src orelse continue;
            if (dst.*) |kept| {
                if (incoming.velocity <= kept.velocity) continue;
            }
            var moved = incoming;
            moved.pitch = @intCast(idx); // the note now belongs to this row
            dst.* = moved;
        }
        var i: usize = idx + 1;
        while (i + 1 < self.slice_count) : (i += 1) {
            self.slices[i] = self.slices[i + 1];
            std.mem.swap([]?MidiNote, &self.midi[i], &self.midi[i + 1]);
            self.slice_len[i] = self.slice_len[i + 1];
            self.choke_group[i] = self.choke_group[i + 1];
        }
        self.clearRow(self.slice_count - 1);
        self.slice_len[self.slice_count - 1] = 0;
        self.choke_group[self.slice_count - 1] = 0;
        self.slice_count -= 1;
        self.clearVoices();
        return true;
    }

    /// Blank one slice's row in place (no reallocation) - the shared tail of
    /// `clearSlice` and every row-shifting edit above.
    fn clearRow(self: *Slicer, slice: u8) void {
        if (slice >= max_slices) return;
        @memset(self.midi[slice], null);
    }

    /// Kill every voice and drop any pending roll after audio or slice
    /// regions change. Rolls are keyed by slice *index*, not the region
    /// they were scheduled against - `chopAt`/`splitSlice`/`mergeSliceRight`/
    /// `sliceInto` (and a fresh sample load) all reassign what audio lives
    /// at an index, so a still-draining roll left standing would fire its
    /// remaining hits against whatever the index now points to instead of
    /// the chop the user was actually hearing when they triggered it.
    fn clearVoices(self: *Slicer) void {
        // zig fmt: off
        for (&self.voices) |*row| for (row) |*v| { v.* = .{}; };
        // zig fmt: on
        self.rolls = [_]?Roll{null} ** max_slices;
    }

    // -----------------------------------------------------------------------
    // Param editing - `id` is `slice << 5 | param` (see `param_stride`).

    pub fn adjustParam(self: *Slicer, id: u16, steps: i32) void {
        const slice_idx = id >> 5;
        const param: u8 = @intCast(id & 0x1F);
        if (slice_idx >= max_slices) return;
        pad_mod.adjustParam(&self.slices[slice_idx], param, steps);
        if (pad_mod.affectsTimeRange(param)) pad_mod.clampTimeParamsToDuration(&self.slices[slice_idx], self.sample_rate);
    }

    comptime {
        // Same 5-bit field as the drum machine's pads, same failure mode.
        for (DrumMachine.automatable_params[0]) |p| if (p.id > 0x1F)
            @compileError("pad param id no longer fits the 5-bit slice field");
    }

    pub fn paramId(slice: u8, param: u8) u16 {
        return (@as(u16, slice) << 5) | (param & 0x1F);
    }

    const automation_sections = blk: {
        @setEvalBranchQuota(100_000);
        var sections: [max_slices][]const u8 = undefined;
        for (0..max_slices) |slice_idx| sections[slice_idx] = std.fmt.comptimePrint("SLICE {d}", .{slice_idx + 1});
        break :blk sections;
    };

    pub const automatable_params = blk: {
        @setEvalBranchQuota(10_000);
        var params: [max_slices][DrumMachine.automatable_params[0].len]dsp.AutomatableParam = undefined;
        for (0..max_slices) |slice_idx| {
            for (DrumMachine.automatable_params[0], 0..) |param, param_idx| {
                params[slice_idx][param_idx] = .{
                    .id = paramId(@intCast(slice_idx), @intCast(param.id)),
                    .label = param.label,
                    .section = automation_sections[slice_idx],
                    .range = param.range,
                    .step = param.step,
                };
            }
        }
        break :blk params;
    };

    pub fn automatableParams(slice: u8) []const dsp.AutomatableParam {
        if (slice >= max_slices) return &.{};
        return &automatable_params[slice];
    }

    pub fn findAutomatableParam(id: u16) ?*const dsp.AutomatableParam {
        const slice: u8 = @intCast(id >> 5);
        if (slice >= max_slices) return null;
        for (&automatable_params[slice]) |*param| if (param.id == id) return param;
        return null;
    }

    /// Set slice-encoded param `id` to an absolute value (same clamps as
    /// `adjustParam`'s per-step nudges) - undo's restore half, mirroring
    /// `DrumMachine.setParamAbsolute`.
    pub fn setParamAbsolute(self: *Slicer, id: u16, value: f32) void {
        const slice_idx = id >> 5;
        const param: u8 = @intCast(id & 0x1F);
        if (slice_idx >= max_slices) return;
        pad_mod.setParamAbsolute(&self.slices[slice_idx], param, value);
        if (pad_mod.affectsTimeRange(param)) pad_mod.clampTimeParamsToDuration(&self.slices[slice_idx], self.sample_rate);
    }

    /// Current value of slice-encoded param `id`, in `setParamAbsolute`'s
    /// encoding (reverse as 0/1) - undo's capture half. Null past the live
    /// slice count, so undo skips rather than editing an inert slot.
    pub fn paramValue(self: *const Slicer, id: u16) ?f32 {
        const slice_idx = id >> 5;
        const param: u8 = @intCast(id & 0x1F);
        if (slice_idx >= self.slice_count) return null;
        return pad_mod.paramValue(&self.slices[slice_idx], param);
    }

    // -----------------------------------------------------------------------
    // Pattern variants (control thread) - mirrors DrumMachine's bank exactly.

    /// Sync the live pattern back into its bank slot. Silently leaves the
    /// slot's stale data in place on allocation failure (rare OOM,
    /// non-fatal - same tolerance `DrumMachine.storeActiveVariant` takes).
    fn storeActiveVariant(self: *Slicer) void {
        const slot = &self.variants[self.variant];
        const fresh = dupeMidi(self.allocator, &self.midi) catch return;
        freeMidi(self.allocator, &slot.midi);
        slot.midi = fresh;
        slot.step_count = self.step_count;
        slot.steps_per_beat = self.steps_per_beat;
    }

    /// Replace the live pattern with `slot`'s data (control thread). Used to
    /// activate a bank variant, to paste a yanked pattern, and by undo's
    /// whole-state restore. Silently leaves the live pattern unchanged on
    /// allocation failure.
    pub fn applyVariant(self: *Slicer, slot: Variant) void {
        const want: u16 = std.math.clamp(slot.step_count, 1, max_steps);
        // A never-materialized bank slot (rows still `&.{}`) means "a blank
        // pattern of that length", not "zero-length rows": every step
        // accessor indexes `midi[slice][step]` for `step < step_count`, so
        // the rows have to actually be that long.
        const fresh = (if (slot.midi[0].len == 0)
            allocMidi(self.allocator, want)
        else
            dupeMidi(self.allocator, &slot.midi)) catch return;
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        freeMidi(self.allocator, &self.midi);
        self.midi = fresh;
        self.step_count = @intCast(fresh[0].len);
        self.steps_per_beat = std.math.clamp(slot.steps_per_beat, 1, 32);
        self.sample_lock.unlock();
    }

    /// Switch the active variant to `v`, saving the live pattern first.
    pub fn selectVariant(self: *Slicer, v: u8) void {
        if (v >= self.variant_count or v == self.variant) return;
        self.storeActiveVariant();
        self.variant = v;
        self.applyVariant(self.variants[v]);
    }

    /// Step the active variant by `delta`, wrapping within the bank.
    pub fn cycleVariant(self: *Slicer, delta: i32) void {
        const n: i32 = self.variant_count;
        if (n <= 1) return;
        self.selectVariant(@intCast(@mod(@as(i32, self.variant) + delta, n)));
    }

    /// Duplicate the active variant into a new slot and switch to it - the
    /// live pattern already matches the copy. False when the bank is full or
    /// the copy can't be allocated.
    pub fn addVariant(self: *Slicer) bool {
        if (self.variant_count >= max_variants) return false;
        self.storeActiveVariant();
        const fresh = dupeMidi(self.allocator, &self.variants[self.variant].midi) catch return false;
        self.variants[self.variant_count] = .{
            .midi = fresh,
            .step_count = self.step_count,
            .steps_per_beat = self.steps_per_beat,
        };
        self.variant = self.variant_count;
        self.variant_count += 1;
        return true;
    }

    /// Remove the active variant, shifting later slots down. The slot that
    /// takes its index (or the new last) becomes active. False when it's the
    /// only one left.
    ///
    /// The shift moves ownership of each row: the removed slot's own rows are
    /// freed first, and the vacated tail slot is left aliasing the pointer it
    /// was moved from - which is why every mutator here iterates
    /// `0..variant_count` and never past it (same rule as DrumMachine's).
    pub fn removeVariant(self: *Slicer) bool {
        if (self.variant_count <= 1) return false;
        freeMidi(self.allocator, &self.variants[self.variant].midi);
        var i = self.variant;
        while (i + 1 < self.variant_count) : (i += 1) self.variants[i] = self.variants[i + 1];
        self.variant_count -= 1;
        if (self.variant >= self.variant_count) self.variant = self.variant_count - 1;
        self.applyVariant(self.variants[self.variant]);
        return true;
    }

    /// Variant `v`'s pattern data. The active one is read from the live rows
    /// (its bank slot is stale until the next switch). The returned rows
    /// ALIAS this slicer's storage - copy them with `dupeMidi` before
    /// keeping them past the next edit, same contract DrumMachine's has.
    pub fn variantData(self: *const Slicer, v: u8) Variant {
        if (v == self.variant) {
            return .{
                .midi = self.midi,
                .step_count = self.step_count,
                .steps_per_beat = self.steps_per_beat,
            };
        }
        return self.variants[@min(v, max_variants - 1)];
    }

    /// Display letter for variant `v`: A, B, C, …
    pub fn variantLetter(v: u8) u8 {
        return 'A' + @as(u8, @min(v, max_variants - 1));
    }

    /// Step slice `slice`'s choke group forward: none → 1 → … → max → none.
    pub fn cycleChokeGroup(self: *Slicer, slice: u8) void {
        if (slice >= max_slices) return;
        self.choke_group[slice] = (self.choke_group[slice] + 1) % (max_choke_groups + 1);
    }

    // -----------------------------------------------------------------------
    // Song-mode clip timeline (mirrors DrumMachine's)

    /// Replace the song-mode clip timeline (control thread). Takes ownership
    /// of every clip's `midi` rows - build them fresh per call (e.g. via
    /// `dupeMidi`) and don't free or reuse them afterward. Taken under
    /// `sample_lock` - `processBlock` holds it for the whole block, so
    /// `fireSongStep` never reads a half-written list.
    pub fn setSongClips(self: *Slicer, clips: []const SongClip, length_steps: u32, steps_per_beat: u8) void {
        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.sample_lock.unlock();
        for (self.song_clips[0..self.song_clip_count]) |*old| freeMidi(self.allocator, &old.midi);
        const count = @min(clips.len, @as(usize, max_song_clips));
        for (clips[0..count], self.song_clips[0..count]) |src, *dst| dst.* = src;
        for (clips[count..]) |src| {
            var dropped = src;
            freeMidi(self.allocator, &dropped.midi);
        }
        self.song_clip_count = @intCast(count);
        self.song_length_steps = length_steps;
        self.song_steps_per_beat = std.math.clamp(steps_per_beat, 1, 32);
    }

    // -----------------------------------------------------------------------
    // Step grid (control thread edits; audio thread reads in processBlock).
    // The bodies are `step_grid_ops.zig`'s, shared with the DrumMachine's
    // identical grid over the same `MidiNote` payload; only the slice
    // vocabulary is ours. See that file for the per-field rationale.
    pub fn toggleStep(self: *Slicer, slice: u8, step: u16) void {
        step_grid_ops.toggleStep(&self.midi, self.step_count, slice, step);
    }

    pub fn stepActive(self: *const Slicer, slice: u8, step: u16) bool {
        return step_grid_ops.stepActive(&self.midi, self.step_count, slice, step);
    }

    pub fn stepVel(self: *const Slicer, slice: u8, step: u16) u8 {
        return step_grid_ops.stepVel(&self.midi, self.step_count, slice, step);
    }

    pub fn setStepVel(self: *Slicer, slice: u8, step: u16, level: u8) void {
        step_grid_ops.setStepVel(&self.midi, self.step_count, slice, step, level);
    }

    /// Step one step's velocity through the named preset bands - same
    /// single-key gesture as `DrumMachine.cycleStepVel`.
    pub fn cycleStepVel(self: *Slicer, slice: u8, step: u16) void {
        step_grid_ops.cycleStepVel(&self.midi, self.step_count, slice, step);
    }

    /// Nudge one step's velocity by `delta`, clamped to 1..127 - 0 would be
    /// silent; use x to remove a step instead of zeroing its velocity.
    pub fn nudgeStepVel(self: *Slicer, slice: u8, step: u16, delta: i32) void {
        step_grid_ops.nudgeStepVel(&self.midi, self.step_count, slice, step, delta);
    }

    /// Fire chance of the step in percent; 100 on an empty step.
    pub fn stepProb(self: *const Slicer, slice: u8, step: u16) u8 {
        return step_grid_ops.stepProb(&self.midi, self.step_count, slice, step);
    }

    pub fn setStepProb(self: *Slicer, slice: u8, step: u16, percent: i32) void {
        step_grid_ops.setStepProb(&self.midi, self.step_count, slice, step, percent);
    }

    pub fn cycleStepProb(self: *Slicer, slice: u8, step: u16) void {
        step_grid_ops.cycleStepProb(&self.midi, self.step_count, slice, step);
    }

    /// Timing offset as a percent of one step; 0 on an empty step.
    pub fn stepMicro(self: *const Slicer, slice: u8, step: u16) i8 {
        return step_grid_ops.stepMicro(&self.midi, self.step_count, slice, step);
    }

    pub fn setStepMicro(self: *Slicer, slice: u8, step: u16, pct: i32) void {
        step_grid_ops.setStepMicro(&self.midi, self.step_count, slice, step, pct);
    }

    pub fn nudgeStepMicro(self: *Slicer, slice: u8, step: u16, delta: i32) void {
        step_grid_ops.nudgeStepMicro(&self.midi, self.step_count, slice, step, delta);
    }

    /// Hits packed into this step; 0/1 is a plain single hit.
    pub fn stepRetrig(self: *const Slicer, slice: u8, step: u16) u8 {
        return step_grid_ops.stepRetrig(&self.midi, self.step_count, slice, step);
    }

    pub fn setStepRetrig(self: *Slicer, slice: u8, step: u16, hits: i32) void {
        step_grid_ops.setStepRetrig(&self.midi, self.step_count, slice, step, hits);
    }

    pub fn cycleStepRetrig(self: *Slicer, slice: u8, step: u16) void {
        step_grid_ops.cycleStepRetrig(&self.midi, self.step_count, slice, step);
    }

    /// Trig condition of the step; `always` on an empty step.
    pub fn stepCond(self: *const Slicer, slice: u8, step: u16) Cond {
        return step_grid_ops.stepCond(&self.midi, self.step_count, slice, step);
    }

    pub fn setStepCond(self: *Slicer, slice: u8, step: u16, cond: Cond) void {
        step_grid_ops.setStepCond(&self.midi, self.step_count, slice, step, cond);
    }

    pub fn cycleStepCond(self: *Slicer, slice: u8, step: u16, delta: i32) void {
        step_grid_ops.cycleStepCond(&self.midi, self.step_count, slice, step, delta);
    }

    /// Flip the fill switch every `fill`/`not_fill` condition reads, and
    /// report the new state.
    pub fn toggleFill(self: *Slicer) bool {
        const next = !self.fill_on.load(.monotonic);
        self.fill_on.store(next, .monotonic);
        return next;
    }

    /// Per-step transpose in semitones; 0 on an empty step.
    pub fn stepTune(self: *const Slicer, slice: u8, step: u16) i8 {
        return step_grid_ops.stepTune(&self.midi, self.step_count, slice, step);
    }

    pub fn setStepTune(self: *Slicer, slice: u8, step: u16, semis: i32) void {
        step_grid_ops.setStepTune(&self.midi, self.step_count, slice, step, semis);
    }

    pub fn nudgeStepTune(self: *Slicer, slice: u8, step: u16, delta: i32) void {
        step_grid_ops.nudgeStepTune(&self.midi, self.step_count, slice, step, delta);
    }

    /// Steps slice `s` actually loops over inside a `pattern_len`-long
    /// pattern: its own `slice_len` when that's set and fits, else the whole
    /// pattern. See `DrumMachine.padSteps`.
    pub fn sliceSteps(self: *const Slicer, s: u8, pattern_len: u16) u16 {
        return step_grid_ops.laneSteps(&self.slice_len, s, pattern_len);
    }

    /// Set slice `s`'s own loop length; 0 (or anything past the pattern) goes
    /// back to following the pattern.
    pub fn setSliceLen(self: *Slicer, s: u8, len: u16) void {
        step_grid_ops.setLaneLen(&self.slice_len, self.step_count, s, len);
    }

    /// Wipe one slice's row: no steps at all.
    pub fn clearSlice(self: *Slicer, slice: u8) void {
        self.clearRow(slice);
    }

    /// Fill one slice's row with full-velocity steps across the active length.
    pub fn fillSlice(self: *Slicer, slice: u8) void {
        if (slice >= max_slices) return;
        for (self.midi[slice], 0..) |*cell, step| cell.* = gridNote(slice, @intCast(step), vel_full);
    }

    /// Nudge slice `s`'s own loop length - `$`'s counterpart for the `:len`
    /// family, and the same op `DrumMachine.nudgePadLen` is.
    pub fn nudgeSliceLen(self: *Slicer, s: u8, delta: i32) void {
        step_grid_ops.nudgeLaneLen(&self.slice_len, self.step_count, s, delta);
    }

    /// `setSliceLen`/`slice_len` under the lane-neutral names a command
    /// shared with the drum machine reaches both types by.
    pub fn setLaneLen(self: *Slicer, lane: u8, len: u16) void {
        self.setSliceLen(lane, len);
    }

    pub fn laneLen(self: *const Slicer, lane: u8) u16 {
        return if (lane >= max_slices) 0 else self.slice_len[lane];
    }

    // The whole-grid and whole-lane pattern edits, shared verbatim with the
    // drum machine - a slicer row IS a drum row (see this file's header).

    /// Wipe every slice's row. Returns the total hit count removed.
    pub fn clearGrid(self: *Slicer) u32 {
        return step_grid_ops.clearGrid(&self.midi);
    }

    /// Jitter every active hit's velocity - see
    /// `step_grid_ops.humanizeVelocity`.
    pub fn humanizeVelocity(self: *Slicer, amount_pct: f64, seed: u64) void {
        step_grid_ops.humanizeVelocity(&self.midi, amount_pct, seed);
    }

    /// Scale every hit's velocity so the loudest peaks - see
    /// `step_grid_ops.normalizeVelocity`. Returns the count touched.
    pub fn normalizeVelocity(self: *Slicer) u32 {
        return step_grid_ops.normalizeVelocity(&self.midi);
    }

    /// Replace one slice's row with a Euclidean rhythm - see
    /// `step_grid_ops.euclidLane`.
    pub fn euclidLane(self: *Slicer, slice: u8, pulses: u16, rotation: i32) void {
        step_grid_ops.euclidLane(&self.midi, self.step_count, slice, pulses, rotation);
    }

    /// Linearly ramp one slice's hit velocities - see
    /// `step_grid_ops.velocityRampLane`. Returns the count touched.
    pub fn velocityRampLane(self: *Slicer, slice: u8, v0: u8, v1: u8) u16 {
        return step_grid_ops.velocityRampLane(&self.midi, slice, v0, v1);
    }

    /// Time-mirror (retrograde) the whole live pattern - see
    /// `step_grid_ops.reverseGrid`.
    pub fn reversePattern(self: *Slicer) void {
        step_grid_ops.reverseGrid(self.allocator, &self.midi, self.step_count);
    }

    /// Rotate one slice's row `delta` steps later in time - see
    /// `step_grid_ops.rotateLane`.
    pub fn rotateLane(self: *Slicer, slice: u8, delta: i32) void {
        step_grid_ops.rotateLane(&self.midi, slice, delta);
    }

    pub fn shiftRange(self: *Slicer, row_lo: u8, row_hi: u8, step_lo: u16, step_hi: u16, drow: i32, dstep: i32) ?u32 {
        return step_grid_ops.shiftRange(&self.midi, self.step_count, row_lo, row_hi, step_lo, step_hi, drow, dstep);
    }

    pub fn reverseRange(self: *Slicer, row_lo: u8, row_hi: u8, step_lo: u16, step_hi: u16) u32 {
        return step_grid_ops.reverseRange(&self.midi, row_lo, row_hi, step_lo, step_hi);
    }

    pub fn invertRange(self: *Slicer, row_lo: u8, row_hi: u8, step_lo: u16, step_hi: u16) u32 {
        return step_grid_ops.invertRange(&self.midi, row_lo, row_hi, step_lo, step_hi);
    }

    /// Resize the live pattern to `n` steps, clamped to `[1, max_steps]`.
    /// Existing notes up to `min(old, new)` survive; a shrink then regrow does
    /// not resurrect anything past the new count. Silently leaves the pattern
    /// unchanged on allocation failure - a user-triggered, rare-OOM control
    /// thread action, not a hot path. Mirrors `DrumMachine.setStepCount`.
    pub fn setStepCount(self: *Slicer, n: u16) void {
        const new_count = std.math.clamp(n, 1, max_steps);
        if (new_count == self.step_count) return;
        var next = allocMidi(self.allocator, new_count) catch return;
        const keep = @min(self.step_count, new_count);
        for (0..max_slices) |slice| @memcpy(next[slice][0..keep], self.midi[slice][0..keep]);

        while (!self.sample_lock.tryLock()) std.atomic.spinLoopHint();
        freeMidi(self.allocator, &self.midi);
        self.midi = next;
        self.step_count = new_count;
        self.sample_lock.unlock();
    }

    pub fn currentStep(self: *const Slicer) u16 {
        return self.current_step.load(.monotonic);
    }

    /// Is slice `slice` sounding right now? For display only - read without
    /// taking `sample_lock`, the same race-tolerant convention every other
    /// UI-side read here uses (worst case the highlight is one block stale,
    /// never a crash: the pool is a fixed inline array).
    pub fn slicePlaying(self: *const Slicer, slice: u8) bool {
        if (slice >= self.slice_count) return false;
        for (self.voices[slice]) |sv| {
            if (sv.active) return true;
        }
        return false;
    }

    /// Nudge swing by `delta` percent, clamped to [swing_min, swing_max].
    pub fn adjustSwing(self: *Slicer, delta: f32) void {
        if (!std.math.isFinite(delta)) return;
        const s = std.math.clamp(self.swing.load(.monotonic) + delta, swing_min, swing_max);
        self.swing.store(s, .monotonic);
    }

    pub fn setSwing(self: *Slicer, pct: f32) void {
        if (!std.math.isFinite(pct)) return;
        self.swing.store(std.math.clamp(pct, swing_min, swing_max), .monotonic);
    }

    // -----------------------------------------------------------------------
    // Audio thread processing

    /// Trigger `slice` through its choke group: a nonzero group first cuts
    /// every ringing voice in the group INCLUDING this slice's own pool -
    /// grouped slices opt back into the classic drum-machine cut behavior
    /// that plain `triggerSlice` deliberately skips (put every slice in one
    /// group for the MPC "mono" chop feel, or pair just two for an
    /// open/closed-hat-style gate).
    pub fn chokeTrigger(self: *Slicer, slice: u8, vel: f32, block_start: u32) void {
        self.chokeTriggerTuned(slice, vel, block_start, 0, -1.0);
    }

    /// `chokeTrigger` plus a per-hit transpose (a step's parameter-locked
    /// `tune`), carried on the voice - see `pad.Voice.tune`. `hold` is how
    /// long a gated slice plays before releasing itself (`pad.Voice
    /// .hold_frames`); -1 waits for a note-off instead.
    pub fn chokeTriggerTuned(self: *Slicer, slice: u8, vel: f32, block_start: u32, tune: i8, hold: f64) void {
        if (slice >= self.slice_count) return;
        const group = self.choke_group[slice];
        if (group != 0) {
            for (0..self.slice_count) |i| {
                // zig fmt: off
                if (self.choke_group[i] == group) for (&self.voices[i]) |*sv| { sv.* = .{}; };
                // zig fmt: on
            }
        }
        self.triggerSliceTuned(slice, vel, block_start, tune, hold);
    }

    /// Trigger `slice` (0-based), stealing the oldest voice in its own small
    /// pool if all are busy. A `.one_shot` slice replayed while still ringing
    /// is allowed to overlap, matching the "manipulate chops live" workflow
    /// (stutters, rolls); a `.retrigger` slice - the chop default - cuts its
    /// own ring first, the drum-kit convention. Choke groups extend that cut
    /// across slices - see `chokeTrigger`.
    pub fn triggerSlice(self: *Slicer, slice: u8, vel: f32, block_start: u32) void {
        self.triggerSliceTuned(slice, vel, block_start, 0, -1.0);
    }

    /// `triggerSlice` with a per-hit transpose and gated hold - see
    /// `chokeTriggerTuned`.
    pub fn triggerSliceTuned(self: *Slicer, slice: u8, vel: f32, block_start: u32, tune: i8, hold: f64) void {
        if (slice >= self.slice_count) return;
        var pool = &self.voices[slice];
        // Retrigger cuts every voice on this slice; their summed last pair
        // rides onto the new one so the cut ramps instead of stepping, same
        // as the Sampler's mono/retrigger path.
        var cut_l: f32 = 0.0;
        var cut_r: f32 = 0.0;
        if (pad_mod.playMode(&self.slices[slice]) == .retrigger) {
            for (pool) |*sv| if (sv.active) {
                cut_l += sv.v.prev_l;
                cut_r += sv.v.prev_r;
                sv.* = .{};
            };
        }
        // A stolen chop is faded out over the new voice's first ~1ms, same as
        // the Sampler's own steal (`pad_mod.carryStealTail`).
        // Free slot, else steal - a voice already past its note-off goes
        // before one still holding its key, age breaking ties within each
        // group. Same order `PolySynth.stealVoice` picks in
        // (`quietest_release orelse oldest`); plain oldest-first would cut a
        // held gated chop and spare an inaudible tail.
        var slot: usize = 0;
        var oldest_age: u64 = std.math.maxInt(u64);
        var stealing_released = false;
        for (pool, 0..) |*sv, i| {
            if (!sv.active) {
                slot = i;
                break;
            }
            const released = sv.v.release_frames >= 0.0;
            const better = (released and !stealing_released) or
                (released == stealing_released and sv.age < oldest_age);
            if (better) {
                stealing_released = released;
                oldest_age = sv.age;
                slot = i;
            }
        }
        const stolen = pool[slot].v;
        pool[slot] = .{
            .active = true,
            .age = self.next_age,
            .v = .{ .active = true, .played = 0, .block_start = block_start, .vel = vel, .tune = tune, .hold_frames = hold },
        };
        pad_mod.carryStealTail(&pool[slot].v, stolen);
        pad_mod.carryTailPair(&pool[slot].v, cut_l, cut_r);
        self.next_age +%= 1;
    }

    pub fn processBlock(self: *Slicer, buf: []Sample) void {
        const channels = 2;
        const frames: u32 = @intCast(buf.len / channels);
        const sr: f64 = @floatFromInt(self.sample_rate);

        // Control-side sample/pattern swaps may hold lock. Skip block rather
        // than stall realtime thread behind allocation or cleanup.
        if (!self.sample_lock.tryLock()) return;
        defer self.sample_lock.unlock();

        if (self.transport.playing and self.slice_count > 0) {
            step_grid_ops.scanBlock(self, &self.slice_len, self.slice_count, frames);
        }

        for (self.slices[0..self.slice_count], self.voices[0..self.slice_count]) |*pad, *pool| {
            // One shared LFO phase per block, same reasoning as
            // Sampler.processBlock: tick once here rather than per-voice, so
            // simultaneous voices on this slice (rolls) stay in phase.
            pad_mod.tickModLfo(pad, sr);
            for (pool) |*sv| {
                if (!sv.active) continue;
                // Keep a mid-block trigger's `block_start` offset for its
                // first render - renderVoice consumes and resets it - same
                // rule as Sampler.processBlock (see its comment there).
                pad_mod.renderVoice(&sv.v, pad, buf, channels, frames, sr);
                if (!sv.v.active) sv.active = false;
            }
        }
    }

    /// Schedule `note` on slice `s` - see `step_grid_ops.scheduleNote`.
    pub fn scheduleNote(self: *Slicer, s: u8, note: MidiNote, step_pos: f64, step_frames: f64) void {
        step_grid_ops.scheduleNote(self, s, note, step_pos, step_frames);
    }

    /// Emit the slices' scheduled hits - see `step_grid_ops.drainRolls`.
    pub fn drainRolls(self: *Slicer, pos_f: f64, frames: u32) void {
        step_grid_ops.drainRolls(self, pos_f, frames);
    }

    pub fn resetAll(self: *Slicer) void {
        // Drops any roll tail along with the voices it would have fed -
        // see `clearVoices`'s doc comment. A stop or a panic must not leave
        // hits scheduled past it.
        self.clearVoices();
        // And rewind the step counter with them, so the next block resyncs
        // against the transport instead of carrying a count from the
        // timeline that just ended - same as `DrumMachine.resetAll`.
        self.next_step_k = 0;
        self.last_pos_frames = 0;
    }

    /// `deviceOf`'s expected name; forwards to `resetAll`.
    pub fn reset(self: *Slicer) void {
        self.resetAll();
    }

    pub fn handleEvent(self: *Slicer, ev: dsp.Event) void {
        switch (ev) {
            // A qwerty/MIDI note maps onto a slice by index, wrapping modulo
            // the current slice count - same convention DrumMachine.
            // triggerPad's `note % max_pads` uses for pad triggering.
            .note_on => |e| if (self.slice_count > 0) {
                self.chokeTrigger(e.note % self.slice_count, e.velocity, 0);
            },
            // Only a gated slice (`Pad.gate`) acts on the release; the
            // default latched slice plays out regardless.
            .note_off => |e| if (self.slice_count > 0) {
                var oldest: ?*SliceVoice = null;
                for (&self.voices[e.note % self.slice_count]) |*sv| {
                    if (!sv.active or sv.v.release_frames >= 0.0) continue;
                    if (oldest == null or sv.age < oldest.?.age) oldest = sv;
                }
                if (oldest) |sv| pad_mod.release(&sv.v);
            },
            .set_param => |e| self.adjustParam(e.id, e.steps),
            .set_param_abs => |e| self.setParamAbsolute(e.id, e.value),
            .automation_param => |e| if (e.instance_id == 0 and e.id <= std.math.maxInt(u16)) self.setParamAbsolute(@intCast(e.id), e.value),
            .cc, .pitch_bend, .midi2_cc, .midi2_pitch_bend, .midi2_per_note_pitch_bend, .channel_pressure, .poly_pressure, .program_change, .set_mod_target, .clap_param, .vst3_param, .set_sidechain_buf, .capture_pad => {},
            .all_off => self.resetAll(),
        }
    }
};

/// Spectral-flux onset detection for `chopTransients`: fills `out` with
/// ascending slice-start positions (fractions of the clip, `out[0]` always
/// 0.0) and returns how many were found (>= 1).
///
/// The detection function is `onset.envelope`'s spectral flux; see there for
/// why a broadband energy envelope is not enough.
///
/// Peaks are picked the way Dixon 2006 does: a local maximum of the
/// detection function that also clears a local mean by `delta`, where
/// `sensitivity` 1..9 scales delta from 2.5x the clip's mean flux (only the
/// hardest hits) down to 0.3x (every flutter). Each accepted peak is then
/// backtracked to the valley the attack rose out of, so the transient itself
/// lands inside its own slice instead of at the point the flux topped out,
/// which is already past the attack.
pub fn detectOnsets(samples: []const f32, sample_rate: u32, sensitivity: u8, out: *[Slicer.max_slices]f32) u8 {
    out[0] = 0.0;
    var count: u8 = 1;

    const hop = onset.hopFor(sample_rate);
    const frames = onset.frameCount(samples.len, sample_rate);
    if (frames < 4) return count;

    var fallback = std.heap.stackFallback(4096 * @sizeOf(f32), std.heap.page_allocator);
    const alloc = fallback.get();
    const odf = onset.envelope(alloc, samples, sample_rate) catch return count;
    defer alloc.free(odf);

    var mean: f32 = 0;
    for (odf) |v| mean += v;
    mean /= @floatFromInt(odf.len);
    if (!(mean > 0)) return count; // silence, or a clip with no change in it

    const win = struct {
        fn f(sec: f32, rate: f32) usize {
            return @max(1, @as(usize, @intFromFloat(@round(sec * rate))));
        }
    }.f;
    const pre_max = win(0.03, onset.fps);
    const post_max = pre_max;
    const pre_avg = win(0.10, onset.fps);
    const post_avg = win(0.07, onset.fps);
    // 30 ms refractory: two boundaries closer than that are one drum hit
    // seen twice, and a slice that short isn't playable anyway.
    const min_gap = win(0.03, onset.fps);
    const max_backtrack = win(0.05, onset.fps);

    const s = std.math.clamp(sensitivity, 1, 9);
    const delta = mean * (2.5 - 0.275 * @as(f32, @floatFromInt(s - 1)));

    var last: usize = 0;
    for (1..frames) |t| {
        const v = odf[t];
        if (v <= 0) continue;

        const mlo = t -| pre_max;
        const mhi = @min(t + post_max + 1, frames);
        var is_max = true;
        for (odf[mlo..mhi]) |x| {
            if (x > v) {
                is_max = false;
                break;
            }
        }
        if (!is_max) continue;

        const alo = t -| pre_avg;
        const ahi = @min(t + post_avg + 1, frames);
        var avg: f32 = 0;
        for (odf[alo..ahi]) |x| avg += x;
        avg /= @floatFromInt(ahi - alo);
        if (v < avg + delta) continue;

        // Walk back down the rising edge. Strict `<` stops at the foot of
        // the rise rather than sliding on through the flat silence before
        // it, which would put the boundary an arbitrary 50 ms early.
        var b = t;
        while (b > 0 and t - b < max_backtrack and odf[b - 1] < odf[b]) b -= 1;
        if (b < last + min_gap) continue; // `last` starts at 0: also the head rule
        last = b;

        if (count >= Slicer.max_slices) break;
        // The window is Hann-weighted, so frame `b` reports on the audio
        // around its centre, not its start.
        out[count] = @as(f32, @floatFromInt(b * hop + onset.frame / 2)) / @as(f32, @floatFromInt(samples.len));
        count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests

fn installTestClip(s: *Slicer) !void {
    s.allocator.free(s.samples);
    s.samples = try s.allocator.alloc(f32, 1024);
    @memset(s.samples, 0.5);
    for (&s.slices) |*p| p.samples = s.samples;
}

test "slicer starts with no sample" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 0), s.samples.len);
    try std.testing.expectEqualStrings("", s.clipName());
    try std.testing.expectEqual(@as(u8, 0), s.slice_count);
}

test "swing setters ignore non-finite values" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.setSwing(62.0);
    s.setSwing(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 62.0), s.swing.load(.monotonic));
    s.setSwing(std.math.inf(f32));
    try std.testing.expectEqual(@as(f32, 62.0), s.swing.load(.monotonic));
    s.adjustSwing(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 62.0), s.swing.load(.monotonic));
}

test "processBlock skips sample-lock contention" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try std.testing.expect(s.sample_lock.tryLock());
    defer s.sample_lock.unlock();
    var buf = [_]Sample{ 1, 1 };
    s.processBlock(&buf);
    try std.testing.expectEqualSlices(Sample, &.{ 1, 1 }, &buf);
}

test "sliceInto equal-divides the clip and clamps out-of-range counts" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    s.sliceInto(4);
    try std.testing.expectEqual(@as(u8, 4), s.slice_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[0].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[3].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[3].end_norm, 1e-6);
    for (s.slices[0..4]) |slice| try std.testing.expectEqual(pad_mod.PlayMode.retrigger, pad_mod.playMode(&slice));

    s.sliceInto(0); // clamps up to 1
    try std.testing.expectEqual(@as(u8, 1), s.slice_count);
    s.sliceInto(200); // clamps down to max_slices
    try std.testing.expectEqual(Slicer.max_slices, s.slice_count);
}

test "chopAt normalizes non-finite and descending boundaries" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    s.chopAt(&.{ 0.0, 0.75, std.math.nan(f32), 0.25, std.math.inf(f32) });
    try std.testing.expectEqual(@as(u8, 5), s.slice_count);
    var previous: f32 = 0.0;
    for (s.slices[0..s.slice_count]) |slice| {
        try std.testing.expect(std.math.isFinite(slice.start_norm));
        try std.testing.expect(std.math.isFinite(slice.end_norm));
        try std.testing.expect(slice.start_norm >= previous);
        try std.testing.expect(slice.end_norm >= slice.start_norm);
        previous = slice.end_norm;
    }
    try std.testing.expectEqual(@as(f32, 1.0), previous);
    for (s.slices[0..s.slice_count]) |slice| try std.testing.expectEqual(pad_mod.PlayMode.retrigger, pad_mod.playMode(&slice));
}

test "every slice aliases the same underlying buffer (no duplication)" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(8);
    for (s.slices[0..8]) |slice| {
        try std.testing.expectEqual(s.samples.ptr, slice.samples.ptr);
    }
}

test "a duplicated slicer keeps what its clip's name declared" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.clip_bpm = 174.0;
    s.clip_root = 7;

    var copy = try s.dupe();
    defer copy.deinit();
    // Without these the duplicate's `:bpm-sync` falls back to the detector,
    // which is wrong or silent on most real loop material.
    try std.testing.expectApproxEqAbs(@as(f32, 174.0), copy.clip_bpm, 1e-6);
    try std.testing.expectEqual(@as(?u4, 7), copy.clip_root);
}

test "re-slicing clears voices tied to the old regions" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(1, 1.0, 0);
    try std.testing.expect(s.voices[1][0].active);

    s.sliceInto(4);
    for (s.voices) |pool| {
        for (pool) |voice| try std.testing.expect(!voice.active);
    }
}

test "re-slicing mid-roll drops the pending hits instead of firing them on the new layout" {
    // Regression: a still-draining roll (Elektron retrig) is keyed by slice
    // *index*, but chopAt/splitSlice/mergeSliceRight/sliceInto all reassign
    // what audio lives at an index without touching `rolls`. A roll
    // scheduled before a re-chop used to keep firing its remaining hits
    // against whatever region the index now pointed to - an unintended
    // chop playing right after the user just re-chopped the sample.
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);

    s.scheduleNote(0, .{ .pitch = 0, .step = 0, .retrig = 4 }, 0.0, 4000.0);
    try std.testing.expect(s.rolls[0] != null);

    try std.testing.expect(s.splitSlice(0));
    try std.testing.expect(s.rolls[0] == null);
}

test "triggerSlice renders only within its own region" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.sliceInto(2);
    s.triggerSlice(1, 1.0, 0);

    var buf: [512]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.001);

    // Slice 1's Voice.played must never exceed its own region length.
    try std.testing.expect(s.voices[1][0].v.played <= @as(f64, @floatFromInt(s.samples.len)) / 2.0 + 1.0);
}

test "triggerSlice past slice_count is a no-op" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(5, 1.0, 0);
    try std.testing.expect(!s.voices[5][0].active);
}

test "step sequencer fires the right slice on schedule" {
    var transport = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    transport.play();
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.sliceInto(4);
    s.toggleStep(2, 0); // slice 2 fires on step 0
    s.setStepCount(16);

    var buf: [64]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expect(s.voices[2][0].active);
    try std.testing.expect(!s.voices[0][0].active);
}

test "note_on wraps a note onto a slice by index" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.device().sendEvent(.{ .note_on = .{ .note = 5, .velocity = 1.0 } }); // 5 % 4 = 1
    try std.testing.expect(s.voices[1][0].active);
}

test "adjustParam edits the addressed slice only" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.adjustParam(Slicer.paramId(2, 7), 10); // slice 2's gain +10 steps of 0.01
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), s.slices[2].gain, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[0].gain, 1e-4);
}

/// Four decaying noise bursts at 0/25/50/75% of a one-second clip -
/// a synthetic drum loop for the transient-chop tests.
fn burstClip(allocator: std.mem.Allocator, sample_rate: u32) ![]f32 {
    const len = sample_rate;
    const out = try allocator.alloc(f32, len);
    @memset(out, 0.0);
    var rng = std.Random.DefaultPrng.init(42);
    const burst_len = sample_rate / 20; // 50 ms
    for (0..4) |b| {
        const at = b * (len / 4);
        for (0..burst_len) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(burst_len));
            out[at + i] = (rng.random().float(f32) * 2.0 - 1.0) * (1.0 - t);
        }
    }
    return out;
}

test "chopTransients finds the bursts and anchors slice 0 at the head" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    std.testing.allocator.free(s.samples);
    s.samples = try burstClip(std.testing.allocator, 48_000);
    for (&s.slices) |*p| p.samples = s.samples;

    const n = s.chopTransients(5);
    try std.testing.expectEqual(@as(u8, 4), n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    // Each detected boundary sits within 3% of its burst (one hop early).
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[1].start_norm, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), s.slices[2].start_norm, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[3].start_norm, 0.03);
    // Contiguous: each slice ends where the next begins.
    try std.testing.expectApproxEqAbs(s.slices[1].start_norm, s.slices[0].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[3].end_norm, 1e-6);
}

/// Four quiet ticks riding a loud sustained bass note - the case a
/// broadband energy envelope cannot see, because the ticks barely move the
/// clip's total level.
fn maskedTickClip(allocator: std.mem.Allocator, sample_rate: u32) ![]f32 {
    const len = sample_rate;
    const out = try allocator.alloc(f32, len);
    const w = 2.0 * std.math.pi * 80.0 / @as(f32, @floatFromInt(sample_rate));
    for (out, 0..) |*x, i| x.* = 0.7 * @sin(w * @as(f32, @floatFromInt(i)));
    var rng = std.Random.DefaultPrng.init(7);
    const tick_len = sample_rate / 100; // 10 ms
    for (0..4) |b| {
        const at = b * (len / 4);
        for (0..tick_len) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(tick_len));
            out[at + i] += (rng.random().float(f32) * 2.0 - 1.0) * 0.2 * (1.0 - t);
        }
    }
    return out;
}

test "chopTransients hears a tick masked by a sustained note" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    std.testing.allocator.free(s.samples);
    s.samples = try maskedTickClip(std.testing.allocator, 48_000);
    for (&s.slices) |*p| p.samples = s.samples;

    try std.testing.expectEqual(@as(u8, 4), s.chopTransients(5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[1].start_norm, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), s.slices[2].start_norm, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[3].start_norm, 0.03);
}

test "chopTransients on silence falls back to one whole-clip slice" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    std.testing.allocator.free(s.samples);
    s.samples = try std.testing.allocator.alloc(f32, 48_000);
    @memset(s.samples, 0.0);
    for (&s.slices) |*p| p.samples = s.samples;

    try std.testing.expectEqual(@as(u8, 1), s.chopTransients(9));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[0].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[0].end_norm, 1e-6);
}

test "chopRandom lays down n contiguous, uneven, non-empty slices" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    try std.testing.expectEqual(@as(u8, 12), s.chopRandom(12, prng.random()));

    var even = true;
    const nominal: f32 = 1.0 / 12.0;
    for (0..12) |i| {
        const p = &s.slices[i];
        // Non-empty, contiguous, and inside the clip.
        try std.testing.expect(p.end_norm > p.start_norm);
        if (i == 0) try std.testing.expectApproxEqAbs(@as(f32, 0.0), p.start_norm, 1e-6);
        if (i == 11) try std.testing.expectApproxEqAbs(@as(f32, 1.0), p.end_norm, 1e-6);
        if (i + 1 < 12) try std.testing.expectApproxEqAbs(p.end_norm, s.slices[i + 1].start_norm, 1e-6);
        if (@abs((p.end_norm - p.start_norm) - nominal) > 1e-4) even = false;
    }
    // The whole point of the dice roll: not an even divide.
    try std.testing.expect(!even);

    // Degenerate counts still leave a usable chop.
    try std.testing.expectEqual(@as(u8, 1), s.chopRandom(1, prng.random()));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.slices[0].end_norm, 1e-6);
}

test "cycleModeAll resolves mixed slices and walks all three play modes" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(3);
    // A fresh chop is retrigger; knock one slice out of step to prove mixed
    // state still lands uniform.
    for (s.slices[0..3]) |slice| try std.testing.expectEqual(pad_mod.PlayMode.retrigger, pad_mod.playMode(&slice));
    pad_mod.setPlayMode(&s.slices[1], .gate);

    for ([_]pad_mod.PlayMode{ .one_shot, .gate, .retrigger }) |want| {
        try std.testing.expectEqual(want, s.cycleModeAll());
        for (s.slices[0..3]) |slice| try std.testing.expectEqual(want, pad_mod.playMode(&slice));
    }
}

test "a retrigger slice cuts its own ring, a one-shot overlaps" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);

    s.triggerSlice(0, 1.0, 0);
    s.triggerSlice(0, 1.0, 0);
    var live: usize = 0;
    for (s.voices[0]) |sv| {
        if (sv.active) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), live);

    pad_mod.setPlayMode(&s.slices[1], .one_shot);
    s.triggerSlice(1, 1.0, 0);
    s.triggerSlice(1, 1.0, 0);
    live = 0;
    for (s.voices[1]) |sv| {
        if (sv.active) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live);
}

test "spreadPitch ramps a semitone step across the live slices only" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);

    s.spreadPitch(3.0);
    for (0..4) |i| {
        const want: f32 = 3.0 * @as(f32, @floatFromInt(i));
        try std.testing.expectApproxEqAbs(want, s.slices[i].pitch_semitones, 1e-6);
    }
    // Past the live count nothing was touched.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.slices[4].pitch_semitones, 1e-6);

    // A big step clamps at the pad pitch range rather than wrapping.
    s.spreadPitch(20.0);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), s.slices[3].pitch_semitones, 1e-6);
}

test "splitSlice halves the region and shifts later pattern rows down" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(3);
    s.toggleStep(2, 5); // will belong to slice 3 after the split
    s.slices[1].pitch_semitones = -12.0;

    try std.testing.expect(s.splitSlice(1));
    try std.testing.expectEqual(@as(u8, 4), s.slice_count);
    // Old slice 1 spanned 1/3..2/3; halves meet at 1/2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.slices[1].end_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.slices[2].start_norm, 1e-6);
    // The right half inherits params but starts silent.
    try std.testing.expectApproxEqAbs(@as(f32, -12.0), s.slices[2].pitch_semitones, 1e-6);
    try std.testing.expect(!s.stepActive(2, 5));
    // Old slice 2's programming followed it to row 3.
    try std.testing.expect(s.stepActive(3, 5));
}

test "mergeSliceRight ORs patterns and shifts later rows up" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.toggleStep(1, 0);
    s.setStepVel(1, 0, 40);
    s.toggleStep(2, 0);
    s.setStepVel(2, 0, 90);
    s.toggleStep(2, 7);
    s.toggleStep(3, 3);

    try std.testing.expect(s.mergeSliceRight(1));
    try std.testing.expectEqual(@as(u8, 3), s.slice_count);
    // Region 1 now spans old 1+2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.slices[1].start_norm, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), s.slices[1].end_norm, 1e-6);
    // Colliding step keeps the louder velocity; disjoint steps both survive.
    try std.testing.expect(s.stepActive(1, 0));
    try std.testing.expectEqual(@as(u8, 90), s.stepVel(1, 0));
    try std.testing.expect(s.stepActive(1, 7));
    // Old slice 3 shifted up to row 2.
    try std.testing.expect(s.stepActive(2, 3));
    try std.testing.expect(!s.mergeSliceRight(2)); // last slice: nothing to its right
}

test "mergeSliceRight rejects the maximum sentinel index" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    try std.testing.expect(!s.mergeSliceRight(std.math.maxInt(u8)));
}

test "setParamAbsolute/paramValue roundtrip, null past slice_count" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.setParamAbsolute(Slicer.paramId(1, 2), -7.0);
    try std.testing.expectApproxEqAbs(@as(f32, -7.0), s.paramValue(Slicer.paramId(1, 2)).?, 1e-6);
    s.setParamAbsolute(Slicer.paramId(1, 9), 1.0);
    try std.testing.expect(s.slices[1].reverse);
    try std.testing.expectEqual(@as(?f32, null), s.paramValue(Slicer.paramId(2, 0)));
}

test "automation targets one slicer parameter" {
    const id = Slicer.paramId(1, 8);
    const param = Slicer.findAutomatableParam(id).?;
    try std.testing.expectEqualStrings("PAN", param.label);
    try std.testing.expectEqualStrings("SLICE 2", param.section);

    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    const other_pan = s.slices[0].pan;
    s.handleEvent(.{ .automation_param = .{ .id = id, .value = 0.5 } });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.slices[1].pan, 1e-6);
    try std.testing.expectApproxEqAbs(other_pan, s.slices[0].pan, 1e-6);
}

test "cycleStepVel walks the preset ladder; nudge clamps at 1" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(1);
    // Velocity lives on the note, so an empty step has nothing to cycle - it
    // reads as full and stays there until a step is placed (same semantics as
    // the drum machine's).
    s.cycleStepVel(0, 0);
    try std.testing.expectEqual(@as(u8, 127), s.stepVel(0, 0));

    s.toggleStep(0, 0);
    try std.testing.expectEqual(@as(u8, 127), s.stepVel(0, 0));
    s.cycleStepVel(0, 0);
    try std.testing.expectEqual(@as(u8, 95), s.stepVel(0, 0));
    s.nudgeStepVel(0, 0, -200);
    try std.testing.expectEqual(@as(u8, 1), s.stepVel(0, 0));
}

test "fillSlice/clearSlice cover exactly the active step range" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.setStepCount(12);
    s.fillSlice(0);
    try std.testing.expect(s.stepActive(0, 11));
    try std.testing.expect(!s.stepActive(0, 12));
    s.clearSlice(0);
    try std.testing.expect(!s.stepActive(0, 0));
}

test "variant bank: add copies, select round-trips, remove shifts" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.toggleStep(0, 0);
    s.setStepVel(0, 0, 90);

    try std.testing.expect(s.addVariant()); // B = copy of A, now active
    try std.testing.expectEqual(@as(u8, 1), s.variant);
    try std.testing.expect(s.stepActive(0, 0));
    s.toggleStep(0, 0); // B diverges: step off
    s.toggleStep(1, 2);

    s.selectVariant(0);
    try std.testing.expect(s.stepActive(0, 0)); // A intact
    try std.testing.expectEqual(@as(u8, 90), s.stepVel(0, 0));
    try std.testing.expect(!s.stepActive(1, 2));

    s.selectVariant(1);
    try std.testing.expect(!s.stepActive(0, 0)); // B's divergence held
    try std.testing.expect(s.stepActive(1, 2));

    try std.testing.expect(s.removeVariant()); // drop B, back on A
    try std.testing.expectEqual(@as(u8, 1), s.variant_count);
    try std.testing.expect(s.stepActive(0, 0));
    try std.testing.expect(!s.removeVariant()); // last one stays
}

test "chokeTrigger cuts grouped voices, leaves ungrouped ringing" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(4);
    s.choke_group[0] = 1;
    s.choke_group[1] = 1;
    // Slice 2 ungrouped, slice 3 in a different group (sliceInto's mono-chop
    // default puts every slice in group 1 - override for this test's mix).
    s.choke_group[2] = 0;
    s.choke_group[3] = 2;

    s.chokeTrigger(1, 1.0, 0);
    s.chokeTrigger(2, 1.0, 0);
    s.chokeTrigger(3, 1.0, 0);
    try std.testing.expect(s.voices[1][0].active);

    s.chokeTrigger(0, 1.0, 0); // group 1: cuts slice 1, spares 2 and 3
    try std.testing.expect(s.voices[0][0].active);
    try std.testing.expect(!s.voices[1][0].active);
    try std.testing.expect(s.voices[2][0].active);
    try std.testing.expect(s.voices[3][0].active);

    // Grouped self-retrigger cuts its own previous voice (mono chop feel):
    // still exactly one active voice in slice 0's pool.
    s.chokeTrigger(0, 1.0, 0);
    var active: usize = 0;
    for (s.voices[0]) |sv| active += @intFromBool(sv.active);
    try std.testing.expectEqual(@as(usize, 1), active);
}

test "ungrouped retrigger still overlaps (choke stays opt-in)" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    pad_mod.setPlayMode(&s.slices[0], .one_shot);
    s.choke_group[0] = 0; // sliceInto's mono-chop default doesn't apply here
    s.chokeTrigger(0, 1.0, 0);
    s.chokeTrigger(0, 1.0, 0);
    var active: usize = 0;
    for (s.voices[0]) |sv| active += @intFromBool(sv.active);
    try std.testing.expectEqual(@as(usize, 2), active);
}

test "note-off releases only oldest overlapping slice voice" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    pad_mod.setPlayMode(&s.slices[0], .gate);
    s.triggerSlice(0, 1.0, 0);
    s.triggerSlice(0, 1.0, 0);

    s.device().sendEvent(.{ .note_off = .{ .note = 0 } });
    try std.testing.expectEqual(@as(f64, 0.0), s.voices[0][0].v.release_frames);
    try std.testing.expect(s.voices[0][1].v.release_frames < 0.0);
    s.device().sendEvent(.{ .note_off = .{ .note = 0 } });
    try std.testing.expectEqual(@as(f64, 0.0), s.voices[0][1].v.release_frames);
}

test "a sequenced hit carries its step's length as the gated hold" {
    var transport = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    transport.play();
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.sliceInto(4);
    s.toggleStep(0, 0);

    var buf: [64]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    // 120 bpm at 4 steps per beat: 6000 frames a step, so a gated slice stops
    // there rather than ringing into the steps after it.
    try std.testing.expectApproxEqAbs(
        transport.framesPerStep(s.steps_per_beat),
        s.voices[0][0].v.hold_frames,
        1e-6,
    );

    // A live hit has no step to end at and waits for its note-off instead.
    s.chokeTrigger(1, 1.0, 0);
    try std.testing.expect(s.voices[1][0].v.hold_frames < 0.0);
}

test "song mode fires the clip covering the playhead, silent past the end" {
    var transport = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    transport.play();
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    try installTestClip(&s);
    s.sliceInto(4);
    // Live pattern has slice 0 on step 0 - must NOT fire in song mode.
    s.toggleStep(0, 0);

    // `setSongClips` takes ownership of each clip's rows, so both machines
    // below get their own freshly-allocated copy.
    var midi = try Slicer.allocMidi(std.testing.allocator, 16);
    midi[2][0] = Slicer.gridNote(2, 0, Slicer.vel_full); // slice 2 on the clip's step 0
    const clip: Slicer.SongClip = .{
        .start_step = 0,
        .span_steps = 16,
        .step_count = 16,
        .midi = midi,
    };
    s.setSongClips(&.{clip}, 16, 4);
    s.song_mode = true;

    var buf: [64]Sample = undefined;
    @memset(&buf, 0.0);
    s.processBlock(&buf);
    try std.testing.expect(s.voices[2][0].active);
    try std.testing.expect(!s.voices[0][0].active);

    // Past the song's end: nothing fires.
    var s2 = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s2.deinit();
    s2.sliceInto(4);
    var clip2 = clip;
    clip2.midi = try Slicer.dupeMidi(std.testing.allocator, &midi);
    s2.setSongClips(&.{clip2}, 16, 4);
    s2.song_mode = true;
    var t2 = Transport{ .sample_rate = 48_000, .tempo_bpm = 120.0 };
    t2.play();
    t2.position_frames = 48_000 * 60; // way past 16 steps
    s2.transport = &t2;
    @memset(&buf, 0.0);
    s2.processBlock(&buf);
    for (s2.voices[0..4]) |pool| {
        for (pool) |sv| try std.testing.expect(!sv.active);
    }
}

test "all_off clears every slice's voices" {
    var transport = Transport{ .sample_rate = 48_000 };
    var s = try Slicer.init(std.testing.allocator, 48_000, &transport);
    defer s.deinit();
    s.sliceInto(2);
    s.triggerSlice(0, 1.0, 0);
    s.triggerSlice(1, 1.0, 0);
    s.device().sendEvent(.all_off);
    try std.testing.expect(!s.voices[0][0].active);
    try std.testing.expect(!s.voices[1][0].active);
}
