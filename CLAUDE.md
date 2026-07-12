# wstudio

Keyboard-centric DAW written in Zig 0.16, vim-modal TUI. See README.md for
the pitch/status and `src/` layout; FORMAT.md for the `.wsj` save format
and its versioning policy.

## Build / run / test

`.envrc` loads the nix devShell automatically; if it hasn't, prefix
commands with `nix develop --command`.

```
zig build run              # launch the TUI
zig build run -- demo.wsj  # curated four-track demo project
zig build test             # all tests
zig build genkit            # re-render the embedded drum kit after editing drum_kit.zig
zig build gendemo           # re-write demo.wsj after editing tools/gendemo.zig
```

**`zig build test` does not reliably rebuild `zig-out/bin/wstudio`** -
it's a separate build target. Before any interactive/tmux verification
pass, run plain `zig build` first, or a passing test suite can mask a
stale binary that looks like a real behavioral bug.

To actually see the TUI (not just read code), use the
`wstudio-tui-screenshot` skill - it drives a dedicated tmux socket and
renders a real PNG, which catches bg-color/reverse-video/layout bugs
that text captures miss.

## Hard rules

- **Never run `zig fmt`.** This codebase is deliberately hand-aligned
  (column-aligned switch arms, assignment blocks in `PolySynth.adjustParam`,
  synth editor tables, ...). `zig fmt` collapses that alignment into huge
  noisy diffs. Write new Zig by hand in the surrounding style. The global
  `nix fmt` convention is for `.nix` files only, not this repo's Zig.
- **Never `git add -A` or `-u`.** Stage files by name. `-A` has already
  swept a stray `demo.wsj~` backup into a feature commit once. Run
  `git status --short` and eyeball every untracked/modified entry before
  staging; if something doesn't belong to the current change, leave it.
- **Commit as you go, without asking first.** One logical change (feature,
  fix, UX pass) = one commit, right after it's working and tested. This
  repo has standing authorization for routine commits (not force-push or
  history rewrites, which still need asking).
- **No em dashes in new prose** (commit messages, code comments, README
  additions, help text). The ones already in the codebase predate this
  convention; don't clean them up, but don't add new ones either.

## Zig 0.16 gotcha

`@min(comptime_bound, runtime_usize)` narrows the result to the smallest
int type that fits the *comptime* bound (e.g. `@min(18, rows -| 7)` gives
a `u5`), not the runtime operand's type. Arithmetic on that result can
overflow-panic despite the values being small and sane. Annotate the
destination (`const x: usize = @min(...)`) whenever the result feeds
further arithmetic.
