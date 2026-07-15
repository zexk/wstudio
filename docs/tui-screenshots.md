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

2. **Always use the dedicated tmux socket `-L wst-shot`, never the
   default one.** An automation session and the user's live session may
   share the default tmux server; `kill-session`/`kill-server` on it is
   one typo away from terminating a real session.
   The private socket makes even `kill-server` safe. Prefix every tmux
   command with `-L wst-shot`; there is no reason to omit it in this repo.

   ```
   tmux -L wst-shot new-session -d -s wst -x <cols> -y <rows>
   tmux -L wst-shot send-keys -t wst "./zig-out/bin/wstudio demo.wsj" Enter
   ```

   Use `demo.wsj` for a populated project, or omit the arg for a blank
   session. Drive further input with `send-keys`; verify you're on the
   view you expect between steps with
   `tmux -L wst-shot capture-pane -t wst -p | tail -1` (status row) rather
   than assuming a key sequence landed - escape chains and a cursor
   already on MASTER can silently swallow keys.

3. **Capture and render:**

   ```
   tmux -L wst-shot capture-pane -t wst -e -p > shot.ansi
   python3 tools/ansi2png.py shot.ansi shot.png
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

`:q!` inside wstudio leaves a `demo.wsj~` autosave backup on disk that
triggers a restore prompt on the next launch - `rm` it between runs if
you relaunched with a fresh session. Kill only your own session when
done: `tmux -L wst-shot kill-session -t wst` (or `kill-server` - safe
only because it's the private socket).
