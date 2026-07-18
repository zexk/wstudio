#!/usr/bin/env bash
# Deterministic TUI screenshot verification pipeline.
#
# Runs wstudio inside a private tmux server with no user tmux config, a fixed
# terminal description, and an isolated HOME/XDG config. The application also
# receives examples/init.lua explicitly, so neither terminal nor wstudio user
# configuration can affect the render.

set -euo pipefail

SOCKET="${WSTUDIO_TUI_SHOT_SOCKET:-wst-shot}"
SESSION="${WSTUDIO_TUI_SHOT_SESSION:-wst}"
COLS="${WSTUDIO_TUI_SHOT_COLS:-160}"
ROWS="${WSTUDIO_TUI_SHOT_ROWS:-48}"
STATE_FILE="${WSTUDIO_TUI_SHOT_STATE:-/tmp/wstudio-tui-shot.env}"
CLEAN_HOME="${WSTUDIO_TUI_SHOT_HOME:-/tmp/wstudio-tui-shot-home}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/zig-out/bin/wstudio"
TEMPLATE_INIT="$REPO_ROOT/examples/init.lua"
RENDERER="$REPO_ROOT/tools/ansi2png.py"
PYENV="${WSTUDIO_TUI_SHOT_PYENV:-/tmp/wstudio-tui-shot-python}"

tmx() {
  tmux -L "$SOCKET" -f /dev/null "$@"
}

render() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL' >/dev/null 2>&1; then
    python3 "$RENDERER" "$@"
  else
    if [ ! -x "$PYENV/bin/python3" ]; then
      nix build --impure \
        --expr 'let pkgs = (builtins.getFlake "flake:nixpkgs").legacyPackages.x86_64-linux; in pkgs.python3.withPackages (p:[p.pillow])' \
        -o "$PYENV"
    fi
    "$PYENV/bin/python3" "$RENDERER" "$@"
  fi
}

load_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "tui_screenshot: no session running (missing $STATE_FILE) - run 'start' first" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

cmd_start() {
  local project="${1:-}"
  if [ -f "$STATE_FILE" ] || tmx has-session -t "$SESSION" 2>/dev/null; then
    echo "tui_screenshot: a session is already running - run 'stop' first" >&2
    exit 1
  fi
  if [ ! -x "$BIN" ]; then
    echo "tui_screenshot: $BIN not found - run 'zig build' first" >&2
    exit 1
  fi

  rm -rf "$CLEAN_HOME"
  mkdir -p "$CLEAN_HOME/.config" "$CLEAN_HOME/.local/state"

  local -a app_args=(-u "$TEMPLATE_INIT")
  if [ -n "$project" ]; then
    local clean_project="$CLEAN_HOME/$(basename "$project")"
    cp "$project" "$clean_project"
    app_args+=("$clean_project")
  fi
  local command
  printf -v command '%q ' env -i \
    "HOME=$CLEAN_HOME" \
    "XDG_CONFIG_HOME=$CLEAN_HOME/.config" \
    "XDG_STATE_HOME=$CLEAN_HOME/.local/state" \
    "PATH=$PATH" \
    "LANG=C.UTF-8" \
    "LC_ALL=C.UTF-8" \
    "TERM=tmux-256color" \
    "COLORTERM=truecolor" \
    "$BIN" "${app_args[@]}"

  tmx new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" \
    -e "TERM=tmux-256color" -e "COLORTERM=truecolor" "$command"

  local pane=""
  for _ in $(seq 1 50); do
    pane="$(tmx capture-pane -t "$SESSION" -p 2>/dev/null || true)"
    [ "$(printf '%s\n' "$pane" | wc -l)" -gt 5 ] && break
    sleep 0.1
  done
  if [ "$(printf '%s\n' "$pane" | wc -l)" -le 5 ]; then
    tmx kill-session -t "$SESSION" 2>/dev/null || true
    rm -rf "$CLEAN_HOME"
    echo "tui_screenshot: application never drew a frame" >&2
    exit 1
  fi

  {
    echo "SOCKET=$SOCKET"
    echo "SESSION=$SESSION"
  } >"$STATE_FILE"
  echo "started tmux socket $SOCKET session $SESSION (${COLS}x${ROWS})"
}

cmd_run() {
  load_state
  tmx send-keys -t "$SESSION" "$@"
}

cmd_shot() {
  local out="${1:?usage: tui_screenshot.sh shot OUTPUT.png}"
  load_state
  local ansi
  ansi="$(mktemp /tmp/wstudio-tui-shot.XXXXXX.ansi)"
  tmx capture-pane -t "$SESSION" -e -p >"$ansi"
  if ! render "$ansi" "$out"; then
    rm -f "$ansi"
    return 1
  fi
  rm -f "$ansi"
  echo "wrote $out"
}

cmd_stop() {
  tmx kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$STATE_FILE"
  rm -rf "$CLEAN_HOME"
  echo "stopped"
}

cmd_capture() {
  local project="" out
  if [ "$#" -eq 2 ]; then
    project="$1"
    out="$2"
  else
    out="${1:?usage: tui_screenshot.sh capture [project.wsj] OUTPUT.png}"
  fi
  cmd_start "$project"
  if ! cmd_shot "$out"; then
    cmd_stop
    return 1
  fi
  cmd_stop
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  run) shift; [ "${1:-}" = "--" ] && shift; cmd_run "$@" ;;
  shot) shift; cmd_shot "$@" ;;
  stop) cmd_stop ;;
  capture) shift; cmd_capture "$@" ;;
  *)
    echo "usage: $0 {capture [project.wsj] OUTPUT.png | start [project.wsj] | run -- <send-keys args...> | shot OUTPUT.png | stop}" >&2
    exit 1
    ;;
esac
