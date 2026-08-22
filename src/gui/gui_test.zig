//! The GUI driving itself, through Dear ImGui's test engine.
//!
//! Built only with `-Dgui-test`: the engine hooks every item submission and
//! has no business inside a released binary, so `build_options.gui_test`
//! keeps the whole thing out of a normal build. When it is on, wstudio
//! still comes up as itself - real engine, real audio host - and the tests
//! act on it the way a person would, by clicking the actual widgets and
//! pressing the actual keys, then reading the result off `App`.
//!
//! Needs an X display. There is no window worth looking at, so run it on a
//! throwaway one, and read the result off the exit status:
//!
//!     zig build -Dgui-test
//!     Xvfb :99 & DISPLAY=:99 zig-out/bin/wstudio --gui

const std = @import("std");
const zgui = @import("zgui");
const app_mod = @import("app.zig");
const icons = @import("../ui/icons.zig");
const te = zgui.te;

var app: *app_mod.App = undefined;
var frames: u32 = 0;

pub fn start(target: *app_mod.App) void {
    app = target;
    // The engine itself is already up: `zgui.init` starts one whenever the
    // bindings were built with the test engine in them, and starting a
    // second would register its settings handlers over the first ones.
    const engine = te.getTestEngine().?;
    engine.setRunSpeed(.fast);
    register(engine);
    engine.queueTests(.tests, "all", .{});
}

/// Called once per presented frame. Non-null means the run is over and the
/// process should exit with that code.
pub fn afterSwap() ?u8 {
    const engine = te.getTestEngine() orelse return null;
    engine.postSwap();
    frames += 1;
    // The queue reads as empty until the engine has picked the first test
    // up, which is why this waits for a few frames before believing it.
    if (frames < 8 or !engine.isTestQueueEmpty()) return null;
    engine.printResultSummary();
    var tested: c_int = 0;
    var passed: c_int = 0;
    engine.getResult(&tested, &passed);
    return if (tested > 0 and tested == passed) 0 else 1;
}

/// Hold a key down for a frame, the way the modal layer expects to see it:
/// `handleShortcuts` edge-detects with `isKeyPressed`, so a press and a
/// release inside one frame is a keystroke nothing ever observes.
fn pressKey(ctx: *te.TestContext, key: zgui.Key) void {
    ctx.keyDown(@intFromEnum(key));
    ctx.yield(2);
    ctx.keyUp(@intFromEnum(key));
    ctx.yield(2);
}

// An item ref is the whole label, not the part after `##`: ImGui hashes the
// text before it too, and every button in the chrome carries an icon glyph
// there. Spelling the refs with the same `icons` constants the views draw
// with keeps a renamed glyph from quietly turning into a missing item.
fn register(engine: *te.TestEngine) void {
    _ = engine.registerTest("transport", "the play button starts and stops playback", @src(), struct {
        pub fn run(ctx: *te.TestContext) !void {
            ctx.setRef("Transport");
            ctx.itemAction(.click, icons.play ++ "##transport-play", .{}, null);
            ctx.yield(4);
            _ = te.check(@src(), .{}, app.core.session.engine.uiSnapshot().playing, "clicking play starts the transport");
            ctx.itemAction(.click, icons.stop ++ "##transport-stop", .{}, null);
            ctx.yield(4);
            _ = te.check(@src(), .{}, !app.core.session.engine.uiSnapshot().playing, "clicking stop stops it again");
        }
    });

    // F1 rather than a letter: the modal grammar routes most letters
    // through the view under the cursor, so what they do depends on the
    // project loaded, while help opens from anywhere and leaves through
    // escape the same way.
    _ = engine.registerTest("modal", "a key reaches the modal layer", @src(), struct {
        pub fn run(ctx: *te.TestContext) !void {
            const before = app.core.view;
            pressKey(ctx, .f1);
            _ = te.check(@src(), .{}, app.core.view == .help, "F1 opens help");
            pressKey(ctx, .escape);
            _ = te.check(@src(), .{}, app.core.view == before, "escape returns to the view it came from");
        }
    });

    _ = engine.registerTest("picker", "instrument picker keeps modal navigation", @src(), struct {
        pub fn run(ctx: *te.TestContext) !void {
            app.core.openInstrumentPicker(0, false);
            ctx.yield(2);
            pressKey(ctx, .j);
            _ = te.check(@src(), .{}, app.core.picker_cursor == 1, "j moves picker cursor down");
            pressKey(ctx, .escape);
            _ = te.check(@src(), .{}, app.core.view == .tracks, "escape closes picker");
        }
    });
}
