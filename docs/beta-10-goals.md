# 1.0.0-beta.10 goals

Beta.10 is the final release candidate. It closes remaining gaps, checks the
product as one coherent DAW, completes a 20-effect internal rack, and applies
bounded release polish. Beta.10 replaces beta.9 as the code promoted to 1.0.
It is not another open-ended feature release.

## 1. Close gaps and prove system coherence

Start with beta.9's unresolved release gate, then test features through whole
workflows instead of accepting isolated subsystem tests.

- Fix real VST3 effect activation, including the recorded LSP
  `ProcessingStartFailed` blocker. Keep the bundled fixture, but require at
  least one third-party VST3 effect and one third-party CLAP plugin to scan,
  activate, process, automate, save, reopen, render, and tear down.
- Complete the interactive TUI and GUI create/edit/save/reopen journeys left
  open by beta.9. Verify physical audio capture, live MIDI input, explicit
  device selection, monitoring, count-in, stop, undo/redo, and export on
  hardware that is available.
- Check one state transition through every consumer. Track, clip, FX, group,
  routing, automation, plugin, tempo, and signature edits must agree across
  live playback, offline render, stems, undo/redo, clone/reorder, Lua, save/load,
  TUI, and GUI wherever that surface exists.
- Check transport coherence at play, stop, seek, loop wrap, recording start and
  stop, project replacement, and sample-rate changes. Live and rendered audio
  must select the same content and automation at each boundary.
- Check ownership and stale-state handling after track, clip, group, FX, and
  plugin deletion or reorder. No editor, automation lane, sidechain, modulation
  route, or plugin parameter may silently retarget another object.
- Reconcile README, help, man page, Lua docs, config template, Nix modules,
  version output, changelog, format contract, package metadata, demo project,
  and release notes against executable registries and actual behavior.

Done when every supported workflow reaches the same saved state and audible
result from either frontend, live and offline output agree, and every remaining
skip names exact unavailable hardware, OS, SDK, or third-party plugin.

## 2. Complete the creative baseline

### Twenty internal rack effects

Grow the current 14 internal kinds to exactly 20. Keep one ordered chain model,
one picker, one parameter editor, and existing automation/persistence paths.
Do not add a parallel rack or a new DSP framework.

Current 14:

- gate, compressor, multiband compressor, OTT, EQ, saturator, bitcrusher
- chorus, phaser, flanger, tape, frequency shifter, delay, reverb

Add these six missing utility and mix roles:

- filter: multimode low-pass, high-pass, band-pass, cutoff, resonance, drive,
  and mix
- limiter: rack form of the existing limiter DSP, with ceiling and release
- utility: gain, polarity invert, mono, left/right channel choice, and swap
- stereo width: mono-compatible mid/side width and output trim
- auto-pan/tremolo: one tempo-syncable LFO, phase selects pan or amplitude
- transient shaper: attack, sustain, and output trim

Each new kind must have bounded parameters, finite output under hostile input,
bypass, reorder, duplicate, modulation/automation, preset, undo/redo, Lua,
  save/reload, and offline-render coverage. Extend current registries and tagged
  unions. Bump `.wsj` version for any schema change under `FORMAT.md` policy.

### Small DAW-completeness candidates

Mature DAWs converge on recording, arrangement editing, automation, routing,
plugin hosting, and export. wstudio already has that baseline. Comparison with
[REAPER's feature overview](https://www.reaper.fm/about.php) and
[Ableton Live's arrangement manual](https://www.ableton.com/en/live-manual/12/arrangement-view/)
highlights four smaller workflow gaps worth testing with real projects:

1. Punch-in and punch-out using the existing A/B loop bounds, without take
   lanes or comping.
2. Named arrangement markers with add, rename, delete, previous, next, and
   seek. Reuse sections if they already satisfy this journey after audit.
3. Short fades at recorded-audio boundaries to prevent clicks. Editable clip
   fades or crossfades qualify only if current clip model can hold them without
   a new audio-arrangement subsystem.
4. Tempo and time-signature changes on the arrangement timeline, only if they
   fit current automation/section timing without breaking live/offline timing.

Research basis: Live documents punch bounds as part of arrangement looping in
its [recording workflow](https://www.ableton.com/en/live-manual/12/recording-new-clips/),
and documents locators, clip fades/crossfades, and timeline signature changes
in its arrangement workflow. REAPER lists punch recording, fades/crossfades,
tempo/signature changes, takes, and comping as production features. These are
comparison points, not a demand to copy either product.

Accept a candidate only when a beta.10 reference journey proves current
behavior blocks ordinary recording or arrangement work, implementation stays
small, both frontends can expose it through shared actions, and a
focused regression check covers it. Otherwise record it for post-1.0. At most
two candidates ship in beta.10.

Explicitly postponed: take lanes and comping, audio warping, elastic audio,
MPE/MIDI 2.0, surround or multi-bus hosting, plugin sandboxing, embedded plugin
GUIs, video, notation, collaboration, and any new plugin format. These are
large subsystems, not release-candidate polish.

## 3. Polish, validate, and promote unchanged

- Run one focused TUI and GUI polish pass over blank project, `demo.wsj`, all
  editors, pickers, prompts, errors, narrow/minimum layouts, and terminal/theme
  variants. Fix clipped labels, hidden state, inconsistent focus, unreadable
  selection, stale status, bad empty states, and keyboard/mouse disagreement.
- Verify every command and key exposed by help works from its stated scope.
  Errors must name failed object and recovery action without hiding current
  session or silently falling back.
- Check default presets, effect defaults, gain staging, bypass level, meters,
  limiter ceiling, tails, and demo mix by ear and through finite/peak checks.
  New effects must start useful and must not change sound while bypassed.
- Run `zig fmt` on touched Zig files, full tests, native build, isolated TUI and
  GUI screenshot journeys, soak, format corpus, Lua/config parity, CLI,
  plugin fixtures, third-party plugin pass, Valgrind, release archives, and Nix
  evaluation/build checks.
- Run native release journeys on Linux and Windows. Run macOS when hardware and
  SDK are available; otherwise keep it explicitly unverified rather than
  treating a cross-build as runtime coverage.
- Build archives from a clean checkout, extract outside the source tree, launch
  both frontends where supported, open `demo.wsj`, render master and stems, and
  verify version, permissions, licenses, docs, config template, and assets.

Beta.10 exits when:

- `zig build test`, native `zig build`, supported cross-builds, and package
  checks pass from a clean checkout.
- All 20 internal effects pass shared rack, persistence, automation, and render
  checks; curated defaults receive an audible manual pass.
- LSP VST3 activation is fixed or replaced by an equally real documented
  compatibility target with root cause and supported boundary recorded.
- Complete TUI and GUI production journeys pass without data loss, corruption,
  crash, hang, wrong routing, stale ownership, or live/offline disagreement.
- Accepted small-feature candidates pass their journey and regression checks;
  rejected candidates are explicitly postponed.
- No open release blocker remains, and docs, version, packages, demo, and
  release notes agree.

Tag beta.10 only after this gate. Promote that exact code to 1.0 apart from
fixes for blockers found during final promotion checks. No feature batch lands
on the stable tag.
