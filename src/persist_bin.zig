//! Dense binary encoding of the `Snapshot` graph, by comptime reflection.
//!
//! Replaces the pretty-printed JSON that used to fill the .wsj's snapshot
//! section. Wire rules, applied recursively to whatever the snapshot types
//! are made of:
//!
//!   bool        one byte, 0 or 1
//!   int         LEB128 (unsigned for unsigned types, signed for signed)
//!   float       raw IEEE bits, little-endian, 4 or 8 bytes
//!   enum        its tag integer
//!   optional    one presence byte, then the payload when present
//!   struct      every field in declaration order, nothing else
//!   union(enum) the tag integer, then the active payload
//!   array       every element, no length (it is in the type)
//!   slice       LEB128 length, then the elements ([]u8 verbatim)
//!
//! Field *names* never reach the file, so the encoding is strictly
//! positional: adding, removing, or reordering any snapshot field changes
//! the format and costs a `file_version` bump, same as it always did.
//!
//! ponytail: every field is written, defaults included. A per-struct
//! presence bitmap that skips default-valued fields would shrink a
//! synth-heavy project further; add it if project size still bites.

const std = @import("std");

pub const DecodeError = error{ CorruptProjectFile, OutOfMemory };

/// Write `value` to `w`. Never fails on the value itself - any type the
/// snapshot graph can hold is encodable, and anything else is a compile
/// error.
pub fn encode(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try w.writeByte(@intFromBool(value)),
        .int => |info| switch (info.signedness) {
            .unsigned => try w.writeUleb128(value),
            .signed => try w.writeSleb128(value),
        },
        .float => |info| {
            const Bits = std.meta.Int(.unsigned, info.bits);
            var buf: [@divExact(info.bits, 8)]u8 = undefined;
            std.mem.writeInt(Bits, &buf, @bitCast(value), .little);
            try w.writeAll(&buf);
        },
        .@"enum" => try encode(w, @intFromEnum(value)),
        .optional => {
            if (value) |payload| {
                try w.writeByte(1);
                try encode(w, payload);
            } else try w.writeByte(0);
        },
        .@"struct" => |info| inline for (info.fields) |f| try encode(w, @field(value, f.name)),
        .@"union" => |info| {
            try encode(w, @intFromEnum(@as(info.tag_type.?, value)));
            switch (value) {
                inline else => |payload| try encode(w, payload),
            }
        },
        .array => for (value) |elem| try encode(w, elem),
        .pointer => |info| {
            if (info.size != .slice) @compileError("persist_bin: not a slice: " ++ @typeName(T));
            try w.writeUleb128(value.len);
            if (info.child == u8) {
                try w.writeAll(value);
            } else for (value) |elem| try encode(w, elem);
        },
        else => @compileError("persist_bin: unsupported type " ++ @typeName(T)),
    }
}

/// `encode` through zlib-wrapped deflate, which is what actually goes in the
/// file. The snapshot is enormously repetitive - long runs of defaulted
/// fields and near-identical notes, clips, and FX params - so this is worth
/// far more than any cleverness in the encoding itself: the demo project's
/// snapshot is 13 KB encoded and 0.8 KB compressed.
///
/// zlib rather than raw deflate for the adler32 in its 6-byte overhead: it
/// catches bit rot that lands inside a float, which the structure alone
/// cannot notice. `decodeCompressed` has to check that itself - this Zig's
/// inflate parses the zlib footer but never compares it.
pub fn encodeCompressed(gpa: std.mem.Allocator, out: *std.Io.Writer, value: anytype) !void {
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var compress = try std.compress.flate.Compress.init(out, window, .zlib, .best);
    try encode(&compress.writer, value);
    try compress.finish();
}

/// Inverse of `encodeCompressed`. Everything but running out of memory is
/// `error.CorruptProjectFile`, including a file that inflates past
/// `max_decompressed_bytes` - the size a project claims to be is the file's
/// word, so it caps the allocation rather than driving it.
pub fn decodeCompressed(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) DecodeError!T {
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var input: std.Io.Reader = .fixed(bytes);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, window);
    const plain = decompress.reader.allocRemaining(arena, .limited(max_decompressed_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptProjectFile,
    };
    if (std.hash.Adler32.hash(plain) != decompress.container_metadata.zlib.adler) return error.CorruptProjectFile;
    return decode(T, arena, plain);
}

/// Ceiling on an inflated snapshot. Generous next to a real project (a
/// hundred thousand notes and their automation is a few MB) and far below
/// what a deflate bomb would like to hand us.
const max_decompressed_bytes = 256 * 1024 * 1024;

/// Read a `T` out of `bytes`, allocating every slice from `arena`. Trailing
/// bytes are ignored; anything else that doesn't line up is
/// `error.CorruptProjectFile`.
pub fn decode(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) DecodeError!T {
    var cursor: Cursor = .{ .bytes = bytes };
    return decodeValue(T, arena, &cursor);
}

/// Position in the encoded bytes. `bytes.len - i` is also the ceiling on any
/// length the file claims: every element costs at least one byte, so a
/// length past the end of the input is a corrupt file, not an allocation.
const Cursor = struct {
    bytes: []const u8,
    i: usize = 0,

    fn take(c: *Cursor, n: usize) DecodeError![]const u8 {
        if (n > c.bytes.len - c.i) return error.CorruptProjectFile;
        defer c.i += n;
        return c.bytes[c.i..][0..n];
    }

    fn byte(c: *Cursor) DecodeError!u8 {
        return (try c.take(1))[0];
    }

    /// LEB128, at most 10 bytes (the widest u64 encoding).
    fn leb(c: *Cursor, comptime Int: type) DecodeError!Int {
        const signed = @typeInfo(Int).int.signedness == .signed;
        const Acc = if (signed) i64 else u64;
        var acc: Acc = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try c.byte();
            const chunk: Acc = @intCast(b & 0x7f);
            acc |= std.math.shl(Acc, chunk, shift);
            if (b & 0x80 == 0) {
                if (signed and shift < 63 and b & 0x40 != 0) acc |= std.math.shl(Acc, @as(Acc, -1), shift + 7);
                break;
            }
            if (shift >= 63) return error.CorruptProjectFile;
            shift += 7;
        }
        return std.math.cast(Int, acc) orelse error.CorruptProjectFile;
    }
};

fn decodeValue(comptime T: type, arena: std.mem.Allocator, c: *Cursor) DecodeError!T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return try c.byte() != 0,
        .int => return c.leb(T),
        .float => |info| {
            const Bits = std.meta.Int(.unsigned, info.bits);
            const raw = try c.take(@divExact(info.bits, 8));
            return @bitCast(std.mem.readInt(Bits, raw[0..@divExact(info.bits, 8)], .little));
        },
        .@"enum" => |info| {
            const tag = try c.leb(info.tag_type);
            return std.enums.fromInt(T, tag) orelse error.CorruptProjectFile;
        },
        .optional => |info| {
            if (try c.byte() == 0) return null;
            return try decodeValue(info.child, arena, c);
        },
        .@"struct" => |info| {
            var out: T = undefined;
            inline for (info.fields) |f| @field(out, f.name) = try decodeValue(f.type, arena, c);
            return out;
        },
        .@"union" => |info| {
            const Tag = info.tag_type.?;
            const tag = std.enums.fromInt(Tag, try c.leb(@typeInfo(Tag).@"enum".tag_type)) orelse
                return error.CorruptProjectFile;
            switch (tag) {
                inline else => |t| return @unionInit(T, @tagName(t), try decodeValue(
                    @FieldType(T, @tagName(t)),
                    arena,
                    c,
                )),
            }
        },
        .array => |info| {
            var out: T = undefined;
            for (&out) |*elem| elem.* = try decodeValue(info.child, arena, c);
            return out;
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("persist_bin: not a slice: " ++ @typeName(T));
            const len = try c.leb(usize);
            if (len > c.bytes.len - c.i) return error.CorruptProjectFile;
            if (info.child == u8) return try arena.dupe(u8, try c.take(len));
            const out = try arena.alloc(info.child, len);
            for (out) |*elem| elem.* = try decodeValue(info.child, arena, c);
            return out;
        },
        else => @compileError("persist_bin: unsupported type " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const RoundTrip = struct {
    flag: bool,
    small: u4,
    negative: i8,
    wide: u64,
    ratio: f32,
    precise: f64,
    choice: enum { a, b, c },
    maybe: ?u16,
    text: []const u8,
    list: []const struct { x: f32, y: i16 },
    fixed: [3]u8,
    payload: union(enum) { none, one: u32, pair: struct { a: u8, b: u8 } },
};

test "round-trips every shape the snapshot graph is made of" {
    const testing = std.testing;
    const in: RoundTrip = .{
        .flag = true,
        .small = 9,
        .negative = -100,
        .wide = std.math.maxInt(u64),
        .ratio = -0.125,
        .precise = 1.0 / 3.0,
        .choice = .c,
        .maybe = 40_000,
        .text = "sample key",
        .list = &.{ .{ .x = 1.5, .y = -2 }, .{ .x = 0, .y = 32_767 } },
        .fixed = .{ 7, 8, 9 },
        .payload = .{ .pair = .{ .a = 1, .b = 2 } },
    };

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try encode(&buf.writer, in);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try decode(RoundTrip, arena.allocator(), buf.written());

    try testing.expectEqual(in.flag, out.flag);
    try testing.expectEqual(in.small, out.small);
    try testing.expectEqual(in.negative, out.negative);
    try testing.expectEqual(in.wide, out.wide);
    try testing.expectEqual(in.ratio, out.ratio);
    try testing.expectEqual(in.precise, out.precise);
    try testing.expectEqual(in.choice, out.choice);
    try testing.expectEqual(in.maybe, out.maybe);
    try testing.expectEqualStrings(in.text, out.text);
    try testing.expectEqual(@as(usize, 2), out.list.len);
    try testing.expectEqual(in.list[1].y, out.list[1].y);
    try testing.expectEqual(in.fixed, out.fixed);
    try testing.expectEqual(@as(u8, 2), out.payload.pair.b);

    // Positional, so it beats JSON on size by a wide margin.
    try testing.expect(buf.written().len < 80);
}

test "compression round-trips, and pays for itself on repetitive data" {
    const testing = std.testing;
    const Row = struct { a: f32, b: u32, c: bool };
    const rows = try testing.allocator.alloc(Row, 2000);
    defer testing.allocator.free(rows);
    // What a real snapshot looks like: mostly defaults, a little variation.
    for (rows, 0..) |*row, i| row.* = .{ .a = if (i % 97 == 0) 0.5 else 0, .b = 0, .c = false };

    var buf: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer buf.deinit();
    try encodeCompressed(testing.allocator, &buf.writer, @as([]const Row, rows));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try decodeCompressed([]const Row, arena.allocator(), buf.written());

    try testing.expectEqual(rows.len, out.len);
    for (rows, out) |in_row, out_row| try testing.expectEqual(in_row.a, out_row.a);

    // 2000 rows is 12 KB flat; anything near that means compression isn't
    // running at all.
    try testing.expect(buf.written().len < 1024);
}

test "a truncated, over-long, or out-of-range file is rejected, not trusted" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // A length far past the end of the input must not become an allocation.
    const huge_len = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f };
    try testing.expectError(error.CorruptProjectFile, decode([]const u8, aa, &huge_len));
    try testing.expectError(error.CorruptProjectFile, decode([]const u32, aa, &huge_len));

    // Truncated mid-value.
    try testing.expectError(error.CorruptProjectFile, decode(f64, aa, &.{ 1, 2, 3 }));
    try testing.expectError(error.CorruptProjectFile, decode(u32, aa, &.{}));

    // An enum tag or union tag naming nothing in this build.
    const Choice = enum { a, b };
    try testing.expectError(error.CorruptProjectFile, decode(Choice, aa, &.{7}));
    const Payload = union(enum) { one: u8, two: u8 };
    try testing.expectError(error.CorruptProjectFile, decode(Payload, aa, &.{ 9, 0 }));

    // A value too wide for the field it lands in.
    try testing.expectError(error.CorruptProjectFile, decode(u8, aa, &.{ 0x80, 0x04 }));
}
