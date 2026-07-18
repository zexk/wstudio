#!/usr/bin/env bash
# GUI screenshot verification pipeline.
#
# Renders wstudio's GUI frontend on a private Xvfb display so it can be
# screenshotted and driven with xdotool without ever touching the user's
# real X session (:0) or leaving stray windows on their desktop - the GUI
# equivalent of docs/tui-screenshots.md's private tmux socket idiom.
#
# Usage:
#   tools/gui_screenshot.sh capture [project.wsj] OUTPUT.png
#       One-shot: start, wait for the window, screenshot, stop. Use this
#       for "does it render" checks.
#
#   tools/gui_screenshot.sh start [project.wsj]
#   tools/gui_screenshot.sh run -- <command...>     # e.g. run -- xdotool key Tab
#   tools/gui_screenshot.sh shot OUTPUT.png
#   tools/gui_screenshot.sh stop
#       Granular form for interactive passes: start once, then any number
#       of run/shot round-trips (click, drag, verify), then stop.
#
# Rebuild first: `zig build test` does not reliably refresh
# zig-out/bin/wstudio (separate build targets) - run plain `zig build`
# before a screenshot pass, per docs/tui-screenshots.md.
#
# xdotool and imagemagick aren't in the project devShell (X11 is only
# there for linking); they're fetched ad hoc via `nix shell`, same spirit
# as tools/ansi2png.py's ad hoc Pillow env. Xvfb itself is expected to
# already be on PATH.

set -euo pipefail

STATE_FILE="${WSTUDIO_GUI_SHOT_STATE:-/tmp/wstudio-gui-shot.env}"
GEOMETRY="${WSTUDIO_GUI_SHOT_GEOMETRY:-1440x900x24}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/zig-out/bin/wstudio"
TEMPLATE_INIT="$REPO_ROOT/examples/init.lua"

nx() {
  nix shell nixpkgs#xdotool nixpkgs#imagemagick --command "$@"
}

pick_display() {
  local n=90
  while [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X$n-lock" ]; do
    n=$((n + 1))
  done
  echo "$n"
}

load_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "gui_screenshot: no session running (missing $STATE_FILE) - run 'start' first" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

cmd_start() {
  local project="${1:-}"

  if [ -f "$STATE_FILE" ]; then
    echo "gui_screenshot: a session is already running (see $STATE_FILE) - run 'stop' first" >&2
    exit 1
  fi
  if [ ! -x "$BIN" ]; then
    echo "gui_screenshot: $BIN not found - run 'zig build' first" >&2
    exit 1
  fi

  local display
  display="$(pick_display)"

  Xvfb ":$display" -screen 0 "$GEOMETRY" >/tmp/wstudio-gui-shot.xvfb.log 2>&1 &
  local xvfb_pid=$!

  for _ in $(seq 1 50); do
    [ -e "/tmp/.X11-unix/X$display" ] && break
    sleep 0.1
  done
  if [ ! -e "/tmp/.X11-unix/X$display" ]; then
    kill "$xvfb_pid" 2>/dev/null || true
    echo "gui_screenshot: Xvfb never came up, see /tmp/wstudio-gui-shot.xvfb.log" >&2
    exit 1
  fi

  # Force the X11 backend: GLFW prefers Wayland if WAYLAND_DISPLAY leaks
  # in from the real session, and Xvfb only speaks X11.
  #
  # Always load the template config (-u), never the user's real
  # ~/.config/wstudio/init.lua - a user-tuned gui_font_size (or window
  # size, theme, ...) skews every layout measurement a screenshot pass
  # would otherwise catch as a real bug.
  local -a args=(-u "$TEMPLATE_INIT" --gui)
  [ -n "$project" ] && args+=("$project")
  (
    unset WAYLAND_DISPLAY
    export DISPLAY=":$display"
    exec "$BIN" "${args[@]}"
  ) >/tmp/wstudio-gui-shot.app.log 2>&1 &
  local app_pid=$!

  if ! DISPLAY=":$display" nx timeout 10 xdotool search --sync --name "wstudio GUI" >/dev/null; then
    kill "$app_pid" "$xvfb_pid" 2>/dev/null || true
    echo "gui_screenshot: window never appeared, see /tmp/wstudio-gui-shot.app.log" >&2
    exit 1
  fi

  {
    echo "DISPLAY=:$display"
    echo "XVFB_PID=$xvfb_pid"
    echo "APP_PID=$app_pid"
  } >"$STATE_FILE"

  echo "started on DISPLAY :$display (xvfb pid $xvfb_pid, wstudio pid $app_pid)"
}

cmd_run() {
  load_state
  DISPLAY="$DISPLAY" nx "$@"
}

cmd_shot() {
  local out="${1:?usage: gui_screenshot.sh shot OUTPUT.png}"
  load_state
  DISPLAY="$DISPLAY" nx import -window root "$out"
  echo "wrote $out"
}

cmd_stop() {
  load_state
  kill "$APP_PID" 2>/dev/null || true
  kill "$XVFB_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  wait "$XVFB_PID" 2>/dev/null || true
  rm -f "$STATE_FILE"
  echo "stopped"
}

cmd_capture() {
  local project="" out
  if [ "$#" -eq 2 ]; then
    project="$1"
    out="$2"
  else
    out="${1:?usage: gui_screenshot.sh capture [project.wsj] OUTPUT.png}"
  fi
  cmd_start "$project"
  cmd_shot "$out"
  cmd_stop
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  run) shift; [ "${1:-}" = "--" ] && shift; cmd_run "$@" ;;
  shot) shift; cmd_shot "$@" ;;
  stop) cmd_stop ;;
  capture) shift; cmd_capture "$@" ;;
  *)
    echo "usage: $0 {capture [project.wsj] OUTPUT.png | start [project.wsj] | run -- <cmd...> | shot OUTPUT.png | stop}" >&2
    exit 1
    ;;
esac
