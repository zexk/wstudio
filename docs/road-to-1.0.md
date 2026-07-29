# Road to 1.0

Four more beta releases remain after beta.5. Each release gets one main
theme. Scope narrows toward 1.0 instead of growing until the final tag.

## 1.0.0-beta.5: close known gaps

Finish the existing [beta.5 goals](beta-5-goals.md): device routing, complete
undo coverage, CLAP lifecycle support, and GUI integration coverage.

No new instrument or effect work belongs in this release.

## 1.0.0-beta.6: VST3 hosting

Implement the bounded [beta.6 VST3 goals](beta-6-goals.md). Add VST3
instruments and effects to the format-neutral plugin catalog that already
distinguishes CLAP, VST3, and VST2.

Target the same useful baseline already offered for CLAP: discovery, audio and
note processing, parameters, saved identity and state, latency, and generic
parameter editing. Native custom editor windows remain separate platform work.

VST2 stays outside the 1.0 plan. It requires a separate host adapter and its
distribution license is no longer available to new hosts.

## 1.0.0-beta.7: production workflow

Use complete projects and beta feedback to close the bounded
[beta.7 production-workflow goals](beta-7-goals.md) across recording, editing,
arrangement, automation, mixing, plugin use, save/load, and export.

Prefer fixes and missing links between existing features. No new instrument,
effect, plugin format, or editing subsystem.

## 1.0.0-beta.8: compatibility freeze

Settle [beta.8 compatibility-freeze goals](beta-8-goals.md): `.wsj`
migrations, Lua API behavior, configuration names, commands, keyboard grammar,
CLI behavior, documentation, and plugin persistence.

After this beta, incompatible changes require a documented migration or wait
until after 1.0.

## 1.0.0-beta.9: release candidate

Follow the bounded [beta.9 release-candidate goals](beta-9-goals.md). Feature
freeze. Fix crashes, data loss, audio corruption, platform failures, and
release or documentation defects. Verify clean installs, bundled demo, project
round trips, device setup, plugins, and release artifacts on Linux, Windows,
and macOS.

## 1.0.0

Release beta.9 code as 1.0 once no release-blocking regression remains. Do not
attach a final feature batch to the stable tag.

VST3 is the last planned large feature. Embedded plugin GUIs, surround buses,
polyphonic plugin modulation, and MIDI 2.0 are not 1.0 requirements. VST2 is
not a 1.0 requirement.
