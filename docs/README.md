# docs/

Design context that is worth keeping but too long to live in code
comments. Code comments explain the why of the trickiest or most
arbitrary steps in place; when the explanation is really a shared
convention or a design story spanning files, it belongs here and the
code keeps a one-line pointer.

- [editing-grammar.md](editing-grammar.md): the vim grammar every
  pattern editor shares (counts, operators, motions, visual mode,
  dot-repeat) and how each editor maps the char/word/line hierarchy.
- [arrangement-playback.md](arrangement-playback.md): how pattern and song
  playback share devices, and why arrangement clips own their content.
- [midi-2.md](midi-2.md): UMP input, resolution flow, platform support, and
  deliberate MIDI 2.0 capability boundaries.
- [undo-redo.md](undo-redo.md): snapshot boundaries, swap-based history,
  parameter-nudge coalescing, and the deliberately limited undo scope.
- [user-config-storage.md](user-config-storage.md): paths, atomic JSON writes,
  corrupt-file quarantine, and the boundary between drum tuning and audio.
- [lua-api.md](lua-api.md): the `wstudio.api` surface every `init.lua` scripts
  against - options, keymaps, user commands, autocmds, and the project
  functions, with their argument shapes and errors.
- [built-in-themes.md](built-in-themes.md): the bundled colorschemes, what each
  one is derived from, and the rule new ones follow.
- [beta-10-goals.md](beta-10-goals.md): final release-candidate coherence,
  the internal rack, bounded DAW-completeness candidates, polish, and exit gate.
- [beta-10-validation.md](beta-10-validation.md): recorded frontend journey,
  automated checks, fixes, and explicit hardware or OS skips.
- [road-to-1.0.md](road-to-1.0.md): what is left between the final release
  candidate and the 1.0 tag.
- [ui-conventions.md](ui-conventions.md): TUI layout and chrome
  conventions (row budget, status row, prompt row, frame bracketing,
  icon fallback) plus the design decisions behind them.
- [gui-color-identity.md](gui-color-identity.md): the GUI's Patina palette,
  semantic color roles, and the category patterns it intentionally avoids.
- [bundled-sound-batteries.md](bundled-sound-batteries.md): competitor survey
  and ranked post-1.0 backlog for bundled instruments and musical content.

Contributor tooling, kept here for the same reason:

- [tui-screenshots.md](tui-screenshots.md): rendering a real PNG of the running
  TUI, and why the private tmux socket is not optional.
- [gui-screenshots.md](gui-screenshots.md): the same for the GUI, on an
  isolated Xvfb display.

Related documents that predate this directory and stay where they are:
`README.md` (pitch, layout, usage) and `FORMAT.md` (the `.wsj` save format and
versioning policy).
