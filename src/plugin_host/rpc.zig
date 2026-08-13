//! Control-path RPC between the parent and a sandboxed plugin child:
//! everything that doesn't run on the audio thread (param enumeration,
//! state save/load, GUI toggle). The real-time path (process/event/reset/
//! latencyFrames) uses transport.zig's shared memory instead.
//!
//! Wire shape: one `Header` (kind + payload length) followed by that many
//! payload bytes, over the child's stdin (parent -> child requests) and
//! stdout (child -> parent responses) pipes. Payloads for the fixed-size
//! messages are raw struct bytes - both CLAP's `abi.ParamInfo` and VST3's
//! `abi.ParameterInfo` are already `extern struct`, and this protocol only
//! ever talks to a child built from the same source, so there's no need
//! for a serialization format richer than "copy the bytes".

const std = @import("std");

pub const Kind = enum(u32) {
    ping,
    service_main_thread,
    /// VST3 only: `Direct.setParameter` is a synchronous controller call,
    /// not an audio-thread-queued event the way CLAP's is (CLAP's own
    /// `setParameter` doc comment says so explicitly) - so unlike CLAP's
    /// bridged `setParameter`, which stays a pending event flushed on the
    /// next `processBlock`, VST3's needs a real round trip to preserve
    /// "effective immediately" semantics (see `Vst3Plugin.parameterValue`
    /// read back right after `setParameter` in the integration test).
    set_parameter,
    /// CLAP's `get_extension` (which `latencyFrames`/`tailFrames` both go
    /// through) is main-thread-only per spec - a real plugin (confirmed
    /// with Odin2) can assert-and-abort if it's called from any other
    /// thread. These must be a round trip to the main/RPC thread, not a
    /// passive read the audio thread's `audioLoop` publishes on its own -
    /// that was the bug: querying them there crashed the child outright.
    latency_frames,
    tail_frames,
    parameter_count,
    parameter_info,
    parameter_name,
    parameter_value,
    format_parameter,
    toggle_gui,
    save_state,
    load_state,
    attach_transport,
    shutdown,
};

pub const Header = extern struct {
    kind: Kind,
    len: u32,
    /// Nonzero on a response that failed (the RPC call itself succeeded,
    /// the plugin-side operation didn't) - callers translate to a Zig
    /// error. Requests always send 0.
    failed: u32 = 0,
};

pub const max_payload: usize = 1 << 20; // 1 MiB - generous for a CLAP/VST3 state blob

pub fn requestMinPayload(kind: Kind) usize {
    return switch (kind) {
        .set_parameter, .format_parameter => 12,
        .parameter_info, .parameter_name, .parameter_value => 4,
        else => 0,
    };
}

pub const Error = error{ RpcClosed, RpcPayloadTooLarge } || std.Io.Writer.Error || std.Io.Reader.Error;

/// Writes one frame. `payload` may be empty.
pub fn send(w: *std.Io.Writer, kind: Kind, failed: bool, payload: []const u8) Error!void {
    if (payload.len > max_payload) return error.RpcPayloadTooLarge;
    const header: Header = .{ .kind = kind, .len = @intCast(payload.len), .failed = @intFromBool(failed) };
    try w.writeAll(std.mem.asBytes(&header));
    if (payload.len > 0) try w.writeAll(payload);
    try w.flush();
}

pub const Received = struct { kind: Kind, failed: bool, payload: []u8 };

/// Reads one frame's header plus its payload into `scratch` (must be at
/// least as big as the payload; callers know their own message shapes).
/// Returns `error.RpcClosed` on a clean EOF (the child exited).
pub fn recv(r: *std.Io.Reader, scratch: []u8) Error!Received {
    var header_bytes: [@sizeOf(Header)]u8 = undefined;
    r.readSliceAll(&header_bytes) catch |err| switch (err) {
        error.EndOfStream => return error.RpcClosed,
        else => |e| return e,
    };
    const header = std.mem.bytesToValue(Header, &header_bytes);
    if (header.len > max_payload or header.len > scratch.len) return error.RpcPayloadTooLarge;
    const payload = scratch[0..header.len];
    if (header.len > 0) try r.readSliceAll(payload);
    return .{ .kind = header.kind, .failed = header.failed != 0, .payload = payload };
}

test "Header round-trips through raw bytes" {
    const h: Header = .{ .kind = .parameter_info, .len = 42, .failed = 1 };
    const bytes = std.mem.asBytes(&h);
    const back = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    try std.testing.expectEqual(Kind.parameter_info, back.kind);
    try std.testing.expectEqual(@as(u32, 42), back.len);
    try std.testing.expectEqual(@as(u32, 1), back.failed);
}

test "send then recv round-trips a payload over an in-memory pipe-like buffer" {
    var buf: [256]u8 = undefined;
    var writer_state = std.Io.Writer.fixed(&buf);
    try send(&writer_state, .parameter_value, false, "hello");
    var reader_state = std.Io.Reader.fixed(writer_state.buffered());
    var scratch: [64]u8 = undefined;
    const got = try recv(&reader_state, &scratch);
    try std.testing.expectEqual(Kind.parameter_value, got.kind);
    try std.testing.expect(!got.failed);
    try std.testing.expectEqualStrings("hello", got.payload);
}

test "fixed-shape requests declare their minimum payload" {
    try std.testing.expectEqual(@as(usize, 12), requestMinPayload(.set_parameter));
    try std.testing.expectEqual(@as(usize, 4), requestMinPayload(.parameter_info));
    try std.testing.expectEqual(@as(usize, 0), requestMinPayload(.load_state));
}
