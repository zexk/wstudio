# GUI screenshots

Renders the actual GUI frontend to a PNG so widget bugs (misplaced hit
regions, overlapping text, a drag that doesn't update the value) are
visible, not just inferable from reading the ImGui call chain. Companion
to [tui-screenshots.md](tui-screenshots.md) for the TUI; same motivation,
different renderer.

The whole point is that it never touches the user's real X session. The
GUI runs on an isolated Xvfb display, screenshotted there, and torn down
- nothing appears on the physical desktop and nothing is left running.

## Tool

`tools/gui_screenshot.sh`, four subcommands:

```
tools/gui_screenshot.sh capture [project.wsj] OUTPUT.png   # one-shot
tools/gui_screenshot.sh start [project.wsj]                # granular:
tools/gui_screenshot.sh run -- <command...>                #   start once,
tools/gui_screenshot.sh shot OUTPUT.png                     #   then any
tools/gui_screenshot.sh stop                                #   number of run/shot round-trips
```

Use `capture` for a "does it render" check. Use the granular form to
click/drag/verify in a loop, e.g. testing a knob or the curve widget:

```
tools/gui_screenshot.sh start demo.wsj
tools/gui_screenshot.sh shot before.png
tools/gui_screenshot.sh run -- xdotool mousemove 400 300 click 1
tools/gui_screenshot.sh run -- xdotool mousemove 400 250 keydown 1 mousemove_relative -- 0 -50 keyup 1
tools/gui_screenshot.sh shot after.png
tools/gui_screenshot.sh stop
```

**Rebuild first.** `zig build test` does not reliably refresh
`zig-out/bin/wstudio` (see [tui-screenshots.md](tui-screenshots.md)) -
run plain `zig build` before a screenshot pass.

**Tools fetched ad hoc.** `xdotool` and `imagemagick` aren't in the
project devShell (X11 there is only for linking, not for driving a
display), so the script pulls them via `nix shell nixpkgs#xdotool
nixpkgs#imagemagick` on demand, same spirit as `tools/ansi2png.py`'s ad
hoc Pillow environment. `Xvfb` itself is expected to already be on
`$PATH` (it ships with the system X server package).

**Why an isolated display and not `:0`.** Driving the user's real X
session with `xdotool` would move their mouse, steal their keyboard
focus, and pop a visible window on top of whatever they're doing - the
GUI equivalent of running a screenshot pipeline on the default tmux
socket (see the TUI doc's private-socket rule). `gui_screenshot.sh`
picks the first free display number above 90 and starts its own `Xvfb`
there; every `xdotool`/`import` call in the script is scoped to that
`DISPLAY`, never the real one.

**Window detection.** `start` waits on `xdotool search --sync --name
"wstudio GUI"` rather than a fixed sleep, since the title is set at
window creation (`src/gui/gui.zig`: `"wstudio GUI prototype"`, later
updated to include the project path).

**Wayland leakage.** GLFW prefers Wayland over X11 if `WAYLAND_DISPLAY`
is set in the environment, and Xvfb only speaks X11 - the script unsets
it before launching wstudio so the X11 backend is always picked.

**Screenshotting the root window**, not a specific window ID, is
deliberate: the virtual display only ever has the one wstudio window on
it (no window manager, no reparenting), so root capture is simpler and
more robust than tracking a window ID across `run` calls.

## State and cleanup

Session state (display number, both PIDs) lives in
`/tmp/wstudio-gui-shot.env`; only one session at a time. `stop` kills
both processes and removes the state file - always run it when done, or
a later `start` will refuse to clobber a live session. Logs from the
running session land in `/tmp/wstudio-gui-shot.{xvfb,app}.log` for
debugging a failed `start`.

As with the TUI pipeline, `:q!`-equivalent exits can leave a
`<project>.wsj~` autosave next to the project file - remove it between
runs if you relaunched with the same project.

## Reading the render

Same caveats as the TUI pipeline: this is a fresh install with no user
config, so themes/fonts are defaults, not the user's actual setup.
