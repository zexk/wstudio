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
zig build test             # all tests (minutes)
zig build test -Dtest-filter=tuning   # only tests whose name contains "tuning" (seconds)
zig build gendemo           # re-write demo.wsj after editing tools/gendemo.zig
zig build dspcheck -- DIR   # run a real sample library through decode/detect/render/FX
zig build bench -Doptimize=ReleaseFast   # audio-callback p50/p99 and deadline use
nix run .#neutral-terminal  # launch Kitty with a clean Nerd Font configuration
```

Two ways to run one test while iterating on it:

```
zig test --test-filter "<name>" src/dsp/tuning.zig   # ~0.5s, but only for a
                                                     # file that compiles alone
zig build test -Dtest-filter="<name>"                # ~3s, works for any test
```

`zig test` on a single file is the fastest, and only works where that file
imports nothing outside its own directory and no C library - `theory.zig`,
`time_grid.zig`, `dsp/tuning.zig`, `dsp/lfo.zig`. Anything reaching
`../core/types.zig`, the `wstudio` module, or sndfile/speex/Rubber Band needs
the build graph, which is what `-Dtest-filter` goes through: it narrows both
unit-test binaries by test name and drops the integration executables
(checkdemo, the CLAP/VST3/crash harnesses), which have no test names to
filter.

### How much to run, and when

Iteration time is the budget. Run the narrowest thing that can fail:

| While | Run |
| --- | --- |
| Editing one unit | `zig test --test-filter` on the file, else `-Dtest-filter` |
| Change is working, before the commit | `-Dtest-filter` over the whole touched area (the module name, the FX kind, the format tag) |
| End of the task, before handing back | one unfiltered `zig build test` |
| Task touched playback, save/load, or export lifetimes | `zig build soak` as well |

A filtered run proves nothing about the rest, so the unfiltered suite is
still mandatory - once per task, not once per commit. It costs minutes, and
paying that between every intermediate commit of a multi-commit task buys
nothing the final run doesn't. `zig build soak` renders an hour of simulated
playback plus save/load/export as fast as the CPU allows; it is not a routine
gate, only run it when the change could leak, drift, or corrupt state over
time.

`dspcheck` is not part of `zig build test` - it needs a corpus of real audio
on disk, far too large to ship. Point it at a directory of samples; it fails
only on non-finite output, and reports tempo/pitch detector accuracy against
the BPM and key in the file names. See `tools/dspcheck.zig`.

**`zig build test` does not reliably rebuild `zig-out/bin/wstudio`** -
it's a separate build target. Before any interactive/tmux verification
pass, run plain `zig build` first, or a passing test suite can mask a
stale binary that looks like a real behavioral bug.

## Keep `.zig-cache` from eating the disk

Every distinct build configuration (filtered test binary, `-Dtarget` cross
build, plugin harness) leaves its own multi-hundred-MB directory under
`.zig-cache/o/`, and zig never evicts them. Two days of iteration reached
42 GB and 72 separate `wstudio` binaries. Prune at the end of a session:

```
find .zig-cache/o -mindepth 1 -maxdepth 1 -type d -mtime +0 -exec rm -rf {} +
```

That drops everything untouched for 24h and keeps the *current* build hot, so
the next `zig build` of the configuration you were just using is incremental.

**It is not a pure cache miss for the configurations it did evict.** A build
config that has been idle longer than the cutoff can come back with
`error: C import failed: FileNotFound` (sndfile.h, rubberband-c.h) even
though the headers are right there in the store: the prune took the cached
cimport while a manifest referencing it survived. Seen 2026-08-14 with Debug
building fine and `zig build bench -Doptimize=ReleaseFast` failing. The only
fix is `rm -rf .zig-cache` and a from-scratch rebuild, so prune at the *end*
of a session, not before a cross-build, a release build, or a benchmark.

Do not let more than one generation of `wstudio` binaries accumulate.

For visual verification of TUI changes, follow
[`docs/tui-screenshots.md`](docs/tui-screenshots.md). It drives a dedicated
tmux socket and renders a real PNG, which catches bg-color/reverse-video/
layout bugs that text captures miss.

## Hard rules

- **`zig fmt` is allowed, the fences are law.** The deliberately compact
  regions (param tables, one-line switch-arm key handlers, grouped
  struct-literal fields, aligned assignment blocks) are wrapped in
  `// zig fmt: off` / `// zig fmt: on` markers, so `zig fmt` is safe and
  encouraged on any file you touch. Never hand-reflow a fenced region to
  fmt style; if you write NEW code in that compact style and fmt would
  mangle it, extend or add a fence rather than skipping fmt. The global
  `nix fmt` convention is still for `.nix` files only.
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
- **Comments explain the why of tricky or arbitrary steps, nothing more.**
  No narration of what the next line does, no session history ("an earlier
  pass tried..."), no duplicated essays across files. Shared conventions
  and design stories live in docs/ (see docs/README.md); code keeps a
  one-line pointer. Threading/atomics contracts in dsp/ and audio/ stay
  in the code, they are load-bearing.

## Zig 0.16 gotcha

`@min(comptime_bound, runtime_usize)` narrows the result to the smallest
int type that fits the *comptime* bound (e.g. `@min(18, rows -| 7)` gives
a `u5`), not the runtime operand's type. Arithmetic on that result can
overflow-panic despite the values being small and sane. Annotate the
destination (`const x: usize = @min(...)`) whenever the result feeds
further arithmetic.
