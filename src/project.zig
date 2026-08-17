//! Project model: the document a user edits.
//!
//! Lives on the control side. The audio thread never touches this
//! directly - edits are translated into engine commands.

const std = @import("std");
const types = @import("core/types.zig");
const theory = @import("theory.zig");
const dsp_tuning = @import("dsp/tuning.zig");
const dsp_controller = @import("dsp/controller.zig");
const time_map = @import("time_map.zig");
const time_grid = @import("time_grid.zig");

pub const TrackKind = enum { audio, midi };

/// Number of colors in `style.track_palette`. Duplicated here (rather than
/// importing the tui-layer style module into this control-layer one) so
/// `Session.insertTrack` can auto-assign colors; `style.zig` comptime-asserts
/// its palette length matches this constant to keep the two in sync.
pub const track_color_count: u8 = 16;

/// Aux/send slots per track (see `Track.sends`). Same small-fixed-bank
/// convention as the engine's `max_sidechain_sources`/`max_groups` - a
/// Small fixed bank, not a growable list. Defined here (not
/// `audio/engine.zig`, which
/// already imports `Project` from this file) so `Track` can hold the type
/// directly without a circular import.
pub const max_sends_per_track: u8 = 8;

/// Where a track's aux send lands - either straight to the master bus or
/// into one of the group submix buses (see `Session.groups`), same
/// destination set `Track.group` already routes a track's PRIMARY signal
/// through. A send is a parallel, independently-leveled tap alongside that
/// primary route, not a replacement for it.
pub const SendTarget = union(enum) { master, group: u8 };

/// One aux send: post-fader (applies after the track's own gain/pan, same
/// signal the primary-destination mix already uses), linear `level` - same
/// convention `gain_db`/`types.dbToGain` already establish for track gain.
pub const SendSlot = struct {
    target: SendTarget,
    level: f32 = 0.0,
    pre_fader: bool = false,
};

pub const Track = struct {
    name: []const u8,
    kind: TrackKind = .audio,
    gain_db: f32 = 0.0,
    /// -1.0 hard left, 0.0 center, 1.0 hard right.
    pan: f32 = 0.0,
    muted: bool = false,
    soloed: bool = false,
    /// 0 = no color (default, uncolored name, matches every track's
    /// look before this field existed). 1..track_palette.len index into
    /// `style.track_palette`, cycled with `[`/`]` in the tracks view.
    /// Auto-assigned on creation by `Session.insertTrack`; duplicated
    /// tracks instead inherit their source's color.
    color: u8 = 0,
    /// Which group submix bus (see `Session.Group`/`Session.groups`) this
    /// track's signal routes through instead of straight to the master mix.
    /// `null` (the default) is the pre-grouping behaviour, unchanged.
    group: ?u8 = null,
    /// Parallel aux sends - see `SendSlot`. `null` entries are unused slots.
    sends: [max_sends_per_track]?SendSlot = @splat(null),
};

fn meterBarTicks(meter: time_map.MeterPoint) u32 {
    return @max(1, time_grid.barTicks(@max(meter.numerator, 1), @max(meter.denominator, 1)));
}

pub const Section = struct {
    tick: u32,
    name: []const u8,
};

pub const AudioSource = struct {
    id: u32,
    path: []const u8,
    sample_rate: u32,
    channel_count: u16,
    samples: []f32,
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "untitled",
    sample_rate: u32 = types.default_sample_rate,
    tempo_bpm: f64 = 120.0,
    tempo_points: std.ArrayList(time_map.TempoPoint) = .empty,
    /// Song key used by piano-roll scale tools and sample tuning.
    scale: ?theory.Scale = null,
    /// Temperament every pitched instrument plays in. Orthogonal to `scale`
    /// above: that one picks which of the twelve keys the piece uses, this
    /// one picks what frequency those keys sound at. The default is equal
    /// temperament, which changes nothing.
    tuning: dsp_tuning.Tuning = .{},
    /// The time signature's numerator. Control-side source of truth - the
    /// transport mirrors it, exactly like `tempo_bpm`. NOT a bar length in
    /// quarter notes: pair it with `meter_denominator` through
    /// `quarterBeatsPerBar`, since a 6/8 bar is three quarter notes.
    beats_per_bar: u8 = 4,
    meter_denominator: u8 = 4,
    meter_points: std.ArrayList(time_map.MeterPoint) = .empty,
    /// A/B loop region in bars (`loop_end_bar` exclusive; empty = no region).
    /// Control-side source of truth - Session.syncLoop pushes it to the
    /// transport as frames whenever it (or the bar math) changes.
    loop_enabled: bool = false,
    loop_start_bar: u32 = 0,
    loop_end_bar: u32 = 0,
    /// Free-floating modulation controllers (see `dsp/controller.zig`).
    /// Project-scoped rather than per-track: one controller drives knobs
    /// across any number of tracks, which is the whole point of it.
    controllers: [dsp_controller.max_controllers]?dsp_controller.Controller = @splat(null),
    /// Learned MIDI CC bindings - the same targets, driven by hardware
    /// instead of an LFO. See `dsp_controller.CcBinding`.
    cc_bindings: [dsp_controller.max_cc_bindings]?dsp_controller.CcBinding = @splat(null),
    tracks: std.ArrayList(Track) = .empty,
    sections: std.ArrayList(Section) = .empty,
    audio_sources: std.ArrayList(AudioSource) = .empty,
    next_audio_source_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Project {
        return .{ .allocator = allocator };
    }

    /// Frames in one bar at the current tempo and time signature.
    pub fn framesPerBar(self: *const Project) u64 {
        const sr = @as(f64, @floatFromInt(@max(self.sample_rate, 1)));
        const bpm = if (std.math.isFinite(self.tempo_bpm) and self.tempo_bpm > 0.0) self.tempo_bpm else 120.0;
        const frames_f = sr * 60.0 / bpm * self.quarterBeatsPerBar();
        if (!std.math.isFinite(frames_f) or frames_f >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            return std.math.maxInt(u64);
        const frames: u64 = @intFromFloat(frames_f);
        return @max(frames, 1);
    }

    pub fn deinit(self: *Project) void {
        self.tempo_points.deinit(self.allocator);
        self.meter_points.deinit(self.allocator);
        for (self.tracks.items) |t| self.allocator.free(t.name);
        self.tracks.deinit(self.allocator);
        for (self.sections.items) |section| self.allocator.free(section.name);
        self.sections.deinit(self.allocator);
        for (self.audio_sources.items) |source| {
            self.allocator.free(source.path);
            self.allocator.free(source.samples);
        }
        self.audio_sources.deinit(self.allocator);
    }

    pub fn secondsAtBeat(self: *const Project, beat: f64) f64 {
        return time_map.secondsAtBeat(self.tempo_points.items, self.tempo_bpm, beat);
    }

    pub fn beatAtSeconds(self: *const Project, seconds: f64) f64 {
        return time_map.beatAtSeconds(self.tempo_points.items, self.tempo_bpm, seconds);
    }

    pub fn framesAtBeat(self: *const Project, beat: f64) u64 {
        const frames = self.secondsAtBeat(beat) * @as(f64, @floatFromInt(@max(self.sample_rate, 1)));
        if (!std.math.isFinite(frames) or frames >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
        return @intFromFloat(@max(frames, 0.0));
    }

    pub fn beatAtFrames(self: *const Project, frames: u64) f64 {
        return self.beatAtSeconds(@as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(@max(self.sample_rate, 1))));
    }

    pub fn meterAtBeat(self: *const Project, beat: f64) time_map.MeterPoint {
        return time_map.meterAt(self.meter_points.items, .{ .beat = 0, .numerator = @max(self.beats_per_bar, 1), .denominator = @max(self.meter_denominator, 1) }, beat);
    }

    /// One bar's length in quarter-note beats, which is the unit every
    /// pattern length, note position and clip tick in the project is measured
    /// in. The signature's beat unit counts: a 6/8 bar is three quarter notes,
    /// not six. Same figure `Transport.positionBarBeat` and `beatAtBar` use.
    pub fn quarterBeatsPerBar(self: *const Project) f64 {
        return (time_map.MeterPoint{
            .beat = 0,
            .numerator = @max(self.beats_per_bar, 1),
            .denominator = @max(self.meter_denominator, 1),
        }).quarterBeatsPerBar();
    }

    pub fn beatAtBar(self: *const Project, target_bar: u32) f64 {
        var segment_beat: f64 = 0;
        var bars: u64 = 0;
        var meter = time_map.MeterPoint{ .beat = 0, .numerator = @max(self.beats_per_bar, 1), .denominator = @max(self.meter_denominator, 1) };
        for (self.meter_points.items) |point| {
            const length = point.beat - segment_beat;
            const bars_f = @ceil(@max(length, 0.0) / meter.quarterBeatsPerBar());
            const segment_bars: u64 = if (bars_f >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) std.math.maxInt(u64) else @intFromFloat(bars_f);
            if (@as(u64, target_bar) < bars +| segment_bars) return segment_beat + @as(f64, @floatFromInt(@as(u64, target_bar) - bars)) * meter.quarterBeatsPerBar();
            bars +|= segment_bars;
            segment_beat = point.beat;
            meter = point;
        }
        return segment_beat + @as(f64, @floatFromInt(@as(u64, target_bar) -| bars)) * meter.quarterBeatsPerBar();
    }

    pub fn frameAtBar(self: *const Project, bar: u32) u64 {
        return self.framesAtBeat(self.beatAtBar(bar));
    }

    /// Quarter-note beat (what the tempo and meter maps are keyed by) as a
    /// tick on the editors' timeline, saturating rather than trapping - a
    /// point may legally sit past any tick the arrangement can address.
    pub fn tickAtBeat(beat: f64) u32 {
        const ticks = beat * @as(f64, @floatFromInt(time_grid.ticks_per_beat));
        if (!std.math.isFinite(ticks) or ticks <= 0) return 0;
        if (ticks >= @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
        return @intFromFloat(ticks);
    }

    pub const BarPos = struct { bar: u32, start_tick: u32 };

    /// Which bar `tick` falls in, and where that bar starts. `beatAtBar`
    /// inverted into the tick domain the arrangement editors work in - they
    /// used to divide by one fixed bar length, so any meter point left their
    /// ruler numbering disagreeing with the transport's own bar readout.
    /// A meter point always opens a new bar, cutting the one it lands in
    /// short, which is the rule `beatAtBar` and `Transport.barBeatAtFrames`
    /// already follow.
    pub fn barAtTick(self: *const Project, tick: u32) BarPos {
        var segment_tick: u32 = 0;
        var bar: u32 = 0;
        var meter = time_map.MeterPoint{ .beat = 0, .numerator = @max(self.beats_per_bar, 1), .denominator = @max(self.meter_denominator, 1) };
        for (self.meter_points.items) |point| {
            const point_tick = tickAtBeat(point.beat);
            if (point_tick > tick) break;
            if (point_tick > segment_tick) {
                const bar_ticks = meterBarTicks(meter);
                bar +|= (point_tick - segment_tick + bar_ticks - 1) / bar_ticks;
            }
            segment_tick = point_tick;
            meter = point;
        }
        const bar_ticks = meterBarTicks(meter);
        const whole = (tick - segment_tick) / bar_ticks;
        return .{ .bar = bar +| whole, .start_tick = segment_tick +| whole *| bar_ticks };
    }

    /// First tick of `bar`, the direction `barAtTick` doesn't cover - used to
    /// place bar-addressed spans (the loop region) on a tick timeline.
    pub fn tickAtBar(self: *const Project, bar: u32) u32 {
        return tickAtBeat(self.beatAtBar(bar));
    }

    pub fn setTempoPoint(self: *Project, point: time_map.TempoPoint) !void {
        if (!std.math.isFinite(point.beat) or point.beat < 0 or !std.math.isFinite(point.bpm) or point.bpm < 20 or point.bpm > 400) return error.InvalidTempoPoint;
        for (self.tempo_points.items) |*existing| {
            if (existing.beat == point.beat) {
                existing.* = point;
                return;
            }
        }
        if (self.tempo_points.items.len == time_map.max_tempo_points) return error.TooManyTempoPoints;
        var index = self.tempo_points.items.len;
        for (self.tempo_points.items, 0..) |existing, i| if (existing.beat > point.beat) {
            index = i;
            break;
        };
        try self.tempo_points.insert(self.allocator, index, point);
    }

    pub fn setMeterPoint(self: *Project, point: time_map.MeterPoint) !void {
        if (!std.math.isFinite(point.beat) or point.beat < 0 or point.numerator == 0 or point.numerator > 32 or !std.math.isPowerOfTwo(point.denominator) or point.denominator > 32) return error.InvalidMeterPoint;
        for (self.meter_points.items) |*existing| {
            if (existing.beat == point.beat) {
                existing.* = point;
                return;
            }
        }
        if (self.meter_points.items.len == time_map.max_meter_points) return error.TooManyMeterPoints;
        var index = self.meter_points.items.len;
        for (self.meter_points.items, 0..) |existing, i| if (existing.beat > point.beat) {
            index = i;
            break;
        };
        try self.meter_points.insert(self.allocator, index, point);
    }

    pub fn addAudioSource(self: *Project, path: []const u8, sample_rate: u32, channel_count: u16, samples: []const f32) !u32 {
        const id = self.next_audio_source_id;
        try self.addAudioSourceWithId(id, path, sample_rate, channel_count, samples);
        return id;
    }

    pub fn addAudioSourceWithId(self: *Project, id: u32, path: []const u8, sample_rate: u32, channel_count: u16, samples: []const f32) !void {
        // ponytail: recording is mono today. Lift this when audio import keeps
        // interleaved channels through WAV decode and source persistence.
        if (id == 0 or self.audioSource(id) != null or channel_count == 0 or channel_count > 2 or samples.len % channel_count != 0) return error.InvalidAudioSource;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_samples = try self.allocator.dupe(f32, samples);
        errdefer self.allocator.free(owned_samples);
        try self.audio_sources.append(self.allocator, .{
            .id = id,
            .path = owned_path,
            .sample_rate = @max(sample_rate, 1),
            .channel_count = @max(channel_count, 1),
            .samples = owned_samples,
        });
        self.next_audio_source_id = @max(self.next_audio_source_id, id +| 1);
    }

    pub fn audioSource(self: *const Project, id: u32) ?*const AudioSource {
        for (self.audio_sources.items) |*source| if (source.id == id) return source;
        return null;
    }

    pub fn setSection(self: *Project, tick: u32, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        for (self.sections.items) |*section| {
            if (section.tick != tick) continue;
            self.allocator.free(section.name);
            section.name = owned;
            return;
        }
        var index = self.sections.items.len;
        for (self.sections.items, 0..) |section, i| {
            if (section.tick > tick) {
                index = i;
                break;
            }
        }
        try self.sections.insert(self.allocator, index, .{ .tick = tick, .name = owned });
    }

    pub fn removeSection(self: *Project, tick: u32) bool {
        for (self.sections.items, 0..) |section, i| {
            if (section.tick != tick) continue;
            const removed = self.sections.orderedRemove(i);
            self.allocator.free(removed.name);
            return true;
        }
        return false;
    }

    pub fn insertTime(self: *Project, at: u32, width: u32) void {
        for (self.sections.items) |*section| {
            if (section.tick >= at) section.tick +|= width;
        }
    }

    pub fn removeTime(self: *Project, lo: u32, hi: u32) void {
        if (hi <= lo) return;
        var i: usize = 0;
        while (i < self.sections.items.len) {
            if (self.sections.items[i].tick >= lo and self.sections.items[i].tick < hi) {
                const removed = self.sections.orderedRemove(i);
                self.allocator.free(removed.name);
            } else {
                if (self.sections.items[i].tick >= hi) self.sections.items[i].tick -= hi - lo;
                i += 1;
            }
        }
    }

    /// Appends a track. Duplicates the name so the caller's string need not
    /// outlive the project.
    pub fn addTrack(self: *Project, track: Track) !usize {
        const name = try self.allocator.dupe(u8, track.name);
        errdefer self.allocator.free(name);
        var t = track;
        t.name = name;
        try self.tracks.append(self.allocator, t);
        return self.tracks.items.len - 1;
    }

    /// Inserts a track at `index`, shifting later tracks right. Duplicates
    /// the name.
    pub fn insertTrack(self: *Project, index: usize, track: Track) !void {
        const name = try self.allocator.dupe(u8, track.name);
        errdefer self.allocator.free(name);
        var t = track;
        t.name = name;
        try self.tracks.insert(self.allocator, index, t);
    }

    pub fn removeTrack(self: *Project, index: usize) void {
        if (index >= self.tracks.items.len) return;
        const t = self.tracks.orderedRemove(index);
        self.allocator.free(t.name);
    }

    pub fn renameTrack(self: *Project, index: usize, new_name: []const u8) !void {
        if (index >= self.tracks.items.len) return error.InvalidTrack;
        const name = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.tracks.items[index].name);
        self.tracks.items[index].name = name;
    }

    /// Swap two tracks' positions. No allocation, cannot fail.
    pub fn swapTracks(self: *Project, a: usize, b: usize) void {
        if (a >= self.tracks.items.len or b >= self.tracks.items.len) return;
        std.mem.swap(Track, &self.tracks.items[a], &self.tracks.items[b]);
    }
};

test "add and remove tracks" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();

    const a = try p.addTrack(.{ .name = "drums" });
    const b = try p.addTrack(.{ .name = "bass", .gain_db = -3.0 });
    try std.testing.expectEqual(@as(usize, 0), a);
    try std.testing.expectEqual(@as(usize, 1), b);
    try std.testing.expectEqual(@as(usize, 2), p.tracks.items.len);

    p.removeTrack(0);
    try std.testing.expectEqualStrings("bass", p.tracks.items[0].name);
}

test "insert track" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();

    _ = try p.addTrack(.{ .name = "a" });
    _ = try p.addTrack(.{ .name = "c" });
    try p.insertTrack(1, .{ .name = "b" });
    try std.testing.expectEqualStrings("b", p.tracks.items[1].name);
    try std.testing.expectEqualStrings("c", p.tracks.items[2].name);
}

test "rename track" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();

    _ = try p.addTrack(.{ .name = "old" });
    try p.renameTrack(0, "new");
    try std.testing.expectEqualStrings("new", p.tracks.items[0].name);
}

test "track mutations reject invalid indices" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.addTrack(.{ .name = "only" });

    p.removeTrack(99);
    p.swapTracks(0, 99);
    try std.testing.expectError(error.InvalidTrack, p.renameTrack(99, "bad"));
    try std.testing.expectEqual(@as(usize, 1), p.tracks.items.len);
    try std.testing.expectEqualStrings("only", p.tracks.items[0].name);
}

test "framesPerBar remains valid with invalid timing fields" {
    var p = Project.init(std.testing.allocator);
    p.sample_rate = 0;
    p.tempo_bpm = std.math.nan(f64);
    p.beats_per_bar = 0;
    try std.testing.expectEqual(@as(u64, 1), p.framesPerBar());

    p.sample_rate = std.math.maxInt(u32);
    p.tempo_bpm = std.math.floatMin(f64);
    p.beats_per_bar = std.math.maxInt(u8);
    try std.testing.expectEqual(std.math.maxInt(u64), p.framesPerBar());
}

test "tempo and meter points stay sorted and drive conversions" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    try p.setTempoPoint(.{ .beat = 8, .bpm = 120 });
    try p.setTempoPoint(.{ .beat = 4, .bpm = 60, .ramp_to_next = true });
    try std.testing.expectEqual(@as(f64, 4), p.tempo_points.items[0].beat);
    const frame = p.framesAtBeat(7);
    try std.testing.expectApproxEqAbs(@as(f64, 7), p.beatAtFrames(frame), 0.001);

    try p.setMeterPoint(.{ .beat = 8, .numerator = 6, .denominator = 8 });
    try std.testing.expectEqual(@as(u8, 8), p.meterAtBeat(9).denominator);
    try std.testing.expectError(error.InvalidMeterPoint, p.setMeterPoint(.{ .beat = 2, .numerator = 4, .denominator = 3 }));
}

test "sections stay sorted and follow time edits" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    try p.setSection(20, "chorus");
    try p.setSection(0, "intro");
    try p.setSection(20, "verse");
    try std.testing.expectEqualStrings("intro", p.sections.items[0].name);
    try std.testing.expectEqualStrings("verse", p.sections.items[1].name);

    p.insertTime(10, 5);
    try std.testing.expectEqual(@as(u32, 25), p.sections.items[1].tick);
    p.removeTime(0, 5);
    try std.testing.expectEqual(@as(usize, 1), p.sections.items.len);
    try std.testing.expectEqual(@as(u32, 20), p.sections.items[0].tick);
}

test "a bar's length in quarter beats follows the signature's beat unit" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    p.beats_per_bar = 6;
    p.meter_denominator = 8;
    // Six eighths, not six quarters.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), p.quarterBeatsPerBar(), 1e-9);
    // ...and the bar->beat conversion the loop region uses agrees.
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), p.beatAtBar(2), 1e-9);
}

test "bar lookup on the tick timeline agrees with the bar to beat conversion" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    try p.setMeterPoint(.{ .beat = 12, .numerator = 7, .denominator = 8 });
    // Bars 0-2 are 4/4 (16 ticks/beat * 4), bar 3 onwards is 7/8 (3.5 beats).
    for ([_]u32{ 0, 1, 2, 3, 4, 5 }) |bar| {
        const start = p.tickAtBar(bar);
        try std.testing.expectEqual(bar, p.barAtTick(start).bar);
        try std.testing.expectEqual(start, p.barAtTick(start).start_tick);
        // One tick short of the next bar still reads as this one.
        try std.testing.expectEqual(bar, p.barAtTick(p.tickAtBar(bar + 1) - 1).bar);
    }
    try std.testing.expectEqual(@as(u32, 12 * time_grid.ticks_per_beat), p.tickAtBar(3));
}

test "a meter point mid-bar starts a new bar instead of stretching the old one" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    try p.setMeterPoint(.{ .beat = 6, .numerator = 3, .denominator = 4 });
    // Beat 6 is halfway through 4/4 bar 1, so that bar is cut short and the
    // 3/4 run starts at bar 2 - the same rule beatAtBar applies.
    try std.testing.expectEqual(@as(u32, 1), p.barAtTick(5 * time_grid.ticks_per_beat).bar);
    try std.testing.expectEqual(@as(u32, 2), p.barAtTick(6 * time_grid.ticks_per_beat).bar);
    try std.testing.expectEqual(@as(u32, 6 * time_grid.ticks_per_beat), p.tickAtBar(2));
}

test "far-future meter point does not overflow bar conversion" {
    var p = Project.init(std.testing.allocator);
    defer p.deinit();
    try p.setMeterPoint(.{ .beat = std.math.floatMax(f64), .numerator = 3, .denominator = 4 });
    try std.testing.expectEqual(@as(f64, 4), p.beatAtBar(1));
}
