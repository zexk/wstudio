# Beta.7 production-workflow validation

This record turns [beta-7-goals.md](beta-7-goals.md) into repeatable project
journeys. Run commands from repository root in Nix development shell. Generated
audio and round-trip files stay under `.zig-cache/` or caller-selected temporary
directories.

## Recorded result

2026-07-29 automated gate passed on Linux:

- `zig build check`: passed, including bundled CLAP/VST3 integration fixtures.
- `zig build -Dtarget=x86_64-windows-gnu`: passed.
- Internal master and four numbered stem exports: passed as audible-format
  stereo 48 kHz 16-bit PCM files.
- ReleaseSafe soak: 172,802,048 frames in 42,188 blocks, ten save/load round
  trips, three exports, finite audible peak 0.501, no crash or hang.
- Valgrind 3.26 Memcheck on baseline-CPU debug build and full demo export:
  zero errors, zero bytes in use at exit.
- CLAP/VST3 scans: no third-party plugins installed, compatibility listening
  pass skipped.
- Physical recording and Windows/macOS hardware passes remain environment
  skips listed below.

## Clean-checkout gate

```sh
zig build test
zig build
tmp_dir=$(mktemp -d)
zig-out/bin/wstudio render demo.wsj "$tmp_dir/master.wav"
zig-out/bin/wstudio render-stems demo.wsj "$tmp_dir/stems"
file "$tmp_dir/master.wav" "$tmp_dir"/stems/*.wav
zig build beta7-soak -Doptimize=ReleaseSafe
zig build -Dcpu=baseline
valgrind --leak-check=full --show-leak-kinds=definite,indirect \
  --errors-for-leak-kinds=definite,indirect --track-origins=yes \
  --error-exitcode=99 zig-out/bin/wstudio render demo.wsj \
  .zig-cache/valgrind-render.wav
zig build -Dtarget=x86_64-windows-gnu
```

Expected artifacts:

- `master.wav`: 36 seconds, stereo 48 kHz, 16-bit PCM, audible, limiter-bounded.
- `stems/1-lead.wav` through `stems/4-drums.wav`: four audible numbered stems.
- `.zig-cache/beta7-soak/roundtrip.wsj`: final file from ten save/load cycles.
- `.zig-cache/beta7-soak/export-1.wav` through `export-3.wav`: three atomic
  exports after one simulated hour of play/stop/seek processing.

## Journey 1: internal production

`demo.wsj` is maintained by `tools/gendemo.zig`. It contains melodic and drum
instruments, multiple arrangement sections, track and instrument automation,
mix FX, groups, sidechain routing, and master processing.

```sh
zig build gendemo
zig build test
zig build
zig-out/bin/wstudio render demo.wsj .zig-cache/beta7-master.wav
zig-out/bin/wstudio render-stems demo.wsj .zig-cache/beta7-stems
```

Listen for distinct lead, electric piano, bass, and drum parts. Master must
follow arrangement structure and include effect tails. Automated persistence
test `a loaded project renders sample-identical to the session that saved it`
checks live/reloaded render equality. Engine tests cover gain, pan, mute, solo,
groups, sidechains, automation, master FX, and limiter ceiling.

## Journey 2: recording and editing

Automated coverage uses synthetic audio and MIDI so clean hosts need no device:

```sh
zig build test
```

Relevant tests cover count-in start/cancel, MIDI input velocity, live piano and
drum recording, audio capture finalization, one-step undo/redo of captured
sample plus arrangement clip, sample sidecar save/reload, editor retargeting,
autosave, recovery staging, and transactional project replacement.

Physical-device pass:

```sh
zig build
zig-out/bin/wstudio devices
zig-out/bin/wstudio --tui
```

In tracks view, create Sampler track, press `r` to arm, open Sampler, enter
insert mode, press `space`, wait through count-in, record, then stop. Save with
`:write .zig-cache/beta7-recording.wsj`, reopen with
`:edit .zig-cache/beta7-recording.wsj`, and export with
`:bounce .zig-cache/beta7-recording.wav` plus
`:bounce-stems .zig-cache/beta7-recording-stems`. Repeat in piano roll using
listed live MIDI input. Expected result: one clip per take, matching timing and
velocity, no duplicate or missing tail, undo removes whole take, redo restores
whole take.

## Journey 3: plugins

Bundled CLAP and VST3 fixtures need no installed plugin:

```sh
zig build test
```

CLAP integration covers lifecycle, GUI calls, audio, parameters, latency,
tails, callbacks, state save/reload, identity, and teardown. VST3 integration
covers discovery, repeated load/unload, instrument/effect audio, note and mapped
MIDI events, parameters, component/controller state, restart servicing, mono
layout, latency, and teardown. Persistence tests cover plugin identity/state;
session and engine tests cover clone/reorder ownership and automation routing.

Third-party compatibility pass starts with:

```sh
zig-out/bin/wstudio clap-scan
zig-out/bin/wstudio vst3-scan
```

Use scanned CLAP IDs and paths with `:clap-instrument` and `:clap-fx`; choose
VST3 entries from instrument and effect pickers. Automate one parameter on each,
clone and reorder tracks/effects, save/reopen, then run master and stem exports.
Expected result: same identity, parameter value, automation target, state,
routing, and audio after reload.

## Fault and recovery coverage

`zig build test` exercises truncated and malformed JSON, future versions,
invalid automation and plugin state fields, missing sidecars, historical
fixtures, atomic project/export replacement, autosave creation, forced reload,
and failed session replacement. Expected result: current session remains intact
after failed load, previous file remains intact after failed write, temporary
files are removed, and unrelated tracks remain usable.

## Current environment record

Validation host on 2026-07-29: NixOS Linux x86_64, kernel 7.1.1, Zig 0.16.
ALSA listed onboard PCH, Blue Snowball input, Controller input/output, and
`Midi Through Port-0`. No installed CLAP or VST3 plugins were discovered.

Known skips:

- Physical recording requires audible/manual inspection and microphone/MIDI
  activity. Automated synthetic coverage runs everywhere.
- Third-party CLAP/VST3 journey skipped when scans return no plugins. Bundled
  fixture integration still runs.
- Windows and macOS hardware journeys require those hosts. Windows cross-build
  covers compilation only from Linux.
