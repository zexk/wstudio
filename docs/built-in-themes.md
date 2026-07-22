# Built-in themes

wstudio includes familiar palettes so a terminal or desktop theme does not
need to be recreated in `init.lua`. Use a name with `:colorscheme`,
`wstudio.o.gui_theme`, or `wstudio.o.tui_theme`:

| Name | Upstream palette | Variant |
| --- | --- | --- |
| `catppuccin_mocha` | Catppuccin | Mocha |
| `catppuccin_latte` | Catppuccin | Latte |
| `dracula` | Dracula | Dracula |
| `gruvbox_dark` | Gruvbox | dark, hard background |
| `gruvbox_light` | Gruvbox | light |
| `nord` | Nord | default |
| `solarized_dark` | Solarized | dark |
| `solarized_light` | Solarized | light |
| `tokyonight` | TokyoNight | night |

The original `patina`, `patina_light`, `graphite`, `graphite_light`, and
`umbra` themes remain available. The TUI additionally accepts `none`, which
leaves the terminal palette untouched.

These are wstudio adaptations, not official ports or endorsements. Proper
project names are used to identify palette compatibility. Config names stay
lowercase with underscores because they are Zig enum values and shell-friendly.

## Attribution and licenses

- [Catppuccin](https://github.com/catppuccin/catppuccin), copyright the
  Catppuccin contributors, MIT License.
- [Dracula](https://github.com/dracula/dracula-theme), copyright Dracula
  Theme, MIT License.
- [Gruvbox](https://github.com/morhetz/gruvbox), copyright Pavel Pertsev,
  MIT License.
- [Nord](https://github.com/nordtheme/nord), copyright Arctic Ice Studio and
  Sven Greb, MIT License.
- [Solarized](https://github.com/altercation/solarized), copyright Ethan
  Schoonover, MIT License.
- [TokyoNight](https://github.com/folke/tokyonight.nvim), copyright Folke
  Lemaitre, Apache License 2.0.

The palettes are mapped onto wstudio's semantic UI roles. A few intermediate
surface shades are derived where an upstream palette has fewer background
steps than wstudio requires; the named accent and endpoint colors remain the
upstream values.
