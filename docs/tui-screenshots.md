# TUI screenshots

Renders an actual PNG of the running TUI so layout/color bugs are visible,
not just inferable from text. Confirmed to catch real bugs (bg colors,
reverse-video badges, clamped/overlapping text) that plain
`tmux capture-pane -p` text missed for weeks.

## Steps

1. **Rebuild first.** `zig build test` does NOT reliably refresh
   `zig-out/bin/wstudio` (separate build targets) - run plain
   `nix develop --command zig build` before every screenshot pass, even
   if you just ran the tests. If a screenshot shows something that
   contradicts code you just read, suspect a stale binary before the code.

2. **Use `tools/tui_screenshot.sh`.** It always uses the dedicated tmux
   socket `wst-shot`, never the default one. An automation session and the
   user's live session may share the default tmux server; `kill-session` or
   `kill-server` on it is one typo away from terminating a real session.

   ```
   tools/tui_screenshot.sh start demo.wsj
   tools/tui_screenshot.sh shot before.png
   tools/tui_screenshot.sh run -- Tab
   tools/tui_screenshot.sh shot arrangement.png
   tools/tui_screenshot.sh stop
   ```

   Use `demo.wsj` for a populated project, or omit the arg for a blank
   session. `run` forwards its arguments to `tmux send-keys`. Verify the
   status row between steps rather than assuming a key sequence landed.
   Escape chains and a cursor
   already on MASTER can silently swallow keys.

   The tool enforces a clean terminal and application configuration:

   - tmux runs with `-f /dev/null`, so the user's tmux configuration cannot
     change colors, status bars, key handling, or terminal overrides;
   - geometry defaults to 160x48 and terminal identity is fixed to
     `TERM=tmux-256color`, `COLORTERM=truecolor`, and the C UTF-8 locale;
   - the child gets an isolated temporary HOME, XDG config, and XDG state;
   - wstudio always starts with `-u examples/init.lua`.
   - a requested project is copied into that temporary HOME, so a local
     autosave backup or other adjacent file cannot affect the capture.

   Override geometry only when testing responsiveness:

   ```
   WSTUDIO_TUI_SHOT_COLS=100 WSTUDIO_TUI_SHOT_ROWS=30 \
     tools/tui_screenshot.sh capture demo.wsj narrow.png
   ```

3. **Capture and render:**

   ```
   tools/tui_screenshot.sh shot shot.png
   ```

   `tools/ansi2png.py` is a ~250-line pure
   Pillow renderer: parses SGR (reset/bold/faint/reverse, 30-37/90-97 fg,
   40-47/100-107 bg, 38;5;N / 38;2;r;g;b truecolor, 39/49 defaults),
   draws a per-cell background rect plus glyph in DejaVu Sans Mono, and
   dims faint text by averaging fg toward bg. It needs Pillow:

   ```
   nix build --impure --expr 'let pkgs = (builtins.getFlake "flake:nixpkgs").legacyPackages.x86_64-linux; in pkgs.python3.withPackages (p:[p.pillow])' -o /tmp/pyenv
   /tmp/pyenv/bin/python3 tools/ansi2png.py shot.ansi shot.png
   ```

   Off-the-shelf alternatives don't work here: charm-freeze's PNG mode
   segfaults in this sandbox (cgo rasterizer), and its ANSI-to-SVG path
   renders no background colors at all (invisible mode badges/selections/
   meters) - this is why the script exists.

4. **Inspect the PNG** with your agent's image-viewing capability, or
   share it with the user if requested.

## Reading the render

- Tofu/empty boxes where an icon should be = missing Nerd Font glyphs in
  DejaVu Sans Mono. Expected, not a bug - those glyphs render fine in the
  user's actual terminal.
- Braille block clusters are the spectrum analyzer; `▌██` cells with `│`
  separators punched through are the arrangement view's intended clip
  look, not corruption.

## Cleanup

`tools/tui_screenshot.sh stop` removes the private session, state file,
and isolated HOME. Always stop after a granular pass; `capture` does this
automatically. If a run made project edits, remove any `demo.wsj~` backup
before relaunching.
