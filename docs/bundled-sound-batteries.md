# Bundled sound batteries

Research snapshot: 2026-08-01. This ranks sounds wstudio could ship so a new
user can write a complete song before finding plugins or samples. It covers
bundled instruments and musical content, not recording, editing, mixing, or
effects.

## What other DAWs bundle

Major DAWs converge on a small set of engines and a much larger playable sound
library:

- acoustic and electric pianos, organs, and clavinets
- acoustic and electronic drum kits, percussion, and drum synthesis
- electric and acoustic basses and guitars
- strings, brass, woodwinds, orchestral percussion, and mallets
- choirs, voices, world instruments, and cinematic textures
- subtractive, FM, wavetable, granular, physical-modeling, and bass synths
- one-shot samplers, multisamplers, drum samplers, slicers, and instrument racks
- loops, MIDI clips, construction kits, presets, and impulse responses

This is category coverage, not a demand to copy every named device. Ableton
Live Suite lists 21 instruments and 71+ GB of presets, samples, and loops. Its
catalog includes a grand piano, electric keyboards, guitar and bass, acoustic
and electronic drums, orchestral families, mallets, voices, and several synth
methods. Logic supplies Studio Piano, Bass, Strings, and Horns beside samplers,
synths, Drum Kit Designer, and Drum Machine Designer. GarageBand exposes the
same beginner-facing core: piano, electric piano, organ, clavinet, synth,
guitar, bass, drums, and strings. Cubase pairs synths and samplers with HALion's
sample library, Groove Agent, a felt piano, and orchestral content. FL Studio
ships basic keys, bass, drums, plucked sounds, synths, samplers, and slicers.
REAPER is the lean outlier: a basic synth, drum synth, and sample player, with
no comparable acoustic library.

wstudio already covers subtractive and wavetable synthesis, chromatic sampling,
drum sampling and sequencing, slicing, SoundFont 2 multisample playback, and
plugin hosting. Missing value is mostly licensed content and useful defaults,
not more engines.

Current shipment covers grand, upright and honky-tonk piano, Italian
harpsichord, pipe organ, concert harp, glockenspiel, marimba, vibraphone,
xylophone, kalimba, nylon-string guitar, tenor ukulele, finger and picked
bass, tenor saxophone, clarinet, soprano recorder, harmonica, violin, viola
and cello sections, pizzicato contrabass, flute, and muted trumpet, from CC0
VCSL, FreePats and VSCO 2 CE through one shared SFZ sample-bank path.
Existing factory kits and synth presets cover starter drums, electric piano,
and electric bass.

## Ranked backlog

Rank uses three tests: how often sound starts a song, how many genres it serves,
and how cheaply existing wstudio engines can ship it. One excellent preset
beats a large mediocre catalog.

1. **Simple grand piano.** Highest-value universal writing sound and clearest
   blank-project test. Ship one dry, neutral SoundFont preset with velocity
   layers and release samples if license and size permit. Avoid a dedicated
   piano engine.
2. **Starter drum library.** Ship one dry acoustic kit and one electronic kit
   already mapped into Drum Machine. Include kicks, snares, claps, closed/open
   hats, toms, cymbals, and basic percussion. Current device without sounds is
   not a battery.
3. **Electric piano.** One tine and one reed preset cover soul, jazz, pop,
   lo-fi, and electronic writing. SoundFont plus existing chorus, tremolo,
   saturation, and amp-like FX covers the useful baseline.
4. **Electric bass.** One fingered preset, with picked or slap only if same
   licensed source provides it. Bass anchors more ordinary projects than
   another synth model.
5. **Tonewheel organ.** One drawbar-style preset with rotary-flavored chorus
   and modulation defaults. Add dedicated drawbars only after preset use proves
   need.
6. **Core strings.** Solo violin and cello plus one ensemble patch. Sustain and
   short articulation cover sketches; a full articulation system does not.
7. **Acoustic and electric guitar.** One steel-string and one clean electric
   preset. Do not attempt realistic strumming, chord engines, or large
   articulation matrices in first library.
8. **Mallets and chromatic percussion.** Vibraphone, marimba, glockenspiel, and
   xylophone. Small libraries, broad melodic and soundtrack use.
9. **Orchestral sketch set.** One brass ensemble, one woodwind ensemble, and
   orchestral percussion. Enough to sketch; specialist scoring belongs in
   external plugins.
10. **Upright or felt piano.** Useful color, but grand piano already satisfies
    core keyboard need.
11. **Choir and voice pads.** One neutral `ah` choir and a few vocal textures.
    Avoid lyric, phrase, and language systems.
12. **World instrument sampler set.** Small, clearly licensed selection such
    as kalimba, sitar, koto, erhu, pipa, and hand percussion. Cultural breadth
    matters, but shallow token coverage should follow core instruments.
13. **Clavinet and harpsichord.** Cheap additions when suitable source library
    already includes them; low standalone priority.
14. **Curated loops and MIDI clips.** A few original, redistributable examples
    can teach workflows, but fixed musical material ages faster than playable
    instruments. Keep optional and small.
15. **Cinematic textures and foley.** Useful for sound design, least necessary
    for proving complete-song baseline. Existing sampler and synth can load
    user material.

## Smallest useful shipment

First content release should contain ranks 1 through 4, reuse SoundFont and
Drum Machine, install no new DSP, and stay optional if download size conflicts
with wstudio's small binary. Every asset needs explicit commercial
redistribution and modification rights, source attribution where required, a
stable content version, and a project-portability rule. Public-domain or CC0
samples minimize packaging and downstream licensing work.

Do not bundle a giant General MIDI bank as the default. It gives impressive
preset count but weak curation, uneven levels, unclear identity, and a large
artifact. A small named core library gives better defaults and can grow only
when real projects expose a gap.

## Sources

- [Ableton Live edition comparison](https://www.ableton.com/en/live/compare-editions/)
- [Ableton packs catalog](https://www.ableton.com/en/packs/by/ableton/)
- [Logic Pro instrument overview](https://support.apple.com/en-gb/guide/logicpro/lgsi6c2728cc/mac)
- [Logic Pro Sound Library content types](https://support.apple.com/guide/logicpro/manage-logic-pro-content-lgcpf77e757d/mac)
- [GarageBand keyboard instruments](https://support.apple.com/en-gb/guide/garageband-ipad/chs39282dbe/ipados)
- [GarageBand instrument and sound overview](https://support.apple.com/guide/garageband-ipad/get-started-chsff8c943/ipados)
- [Cubase virtual instruments and sounds](https://www.steinberg.net/cubase/features/)
- [FL Studio instrument list](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/generator_plugins.htm)
- [REAPER included instruments](https://www.cockos.com/reaper/about.php)
- [Reason NN-XT multisample library](https://www.reasonstudios.com/devices/nn-xt)
- [Digital Performer instrument plug-ins](https://cdn-data.motu.com/manuals/software/dp/v111/Digital%20Performer%20Plug-ins%20Guide.pdf)
