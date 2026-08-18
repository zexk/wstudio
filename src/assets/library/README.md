# Bundled acoustic library

Three CC0 packs, each in its own directory with its own licence text. All are
plain SFZ + FLAC, so adding an instrument is a data change plus one row in
`src/dsp/builtin_library.zig`.

## `vcsl/`

A curated subset of the Versilian Community Sample Library by Versilian
Studios: grand and upright piano, Italian harpsichord, pipe organ, concert
harp, glockenspiel, marimba, vibraphone, xylophone, Kenyan kalimba, harmonica.

Source: <https://versilian-studios.com/vcsl-keys/> for the keys, published
2023-10-11, and <https://github.com/sgossner/VCSL> for the rest. Dedicated to
the public domain under CC0 1.0; exact licence text is in `vcsl/LICENSE`.

## `freepats/`

Sound banks from the FreePats project: nylon-string and clean electric
guitar, tenor ukulele, finger and picked bass, honky-tonk piano, tenor
saxophone, clarinet, soprano recorder.

Source: <https://freepats.zenvoid.org/>. Dedicated to the public domain under
CC0 1.0; exact licence text is in `freepats/LICENSE`. The per-bank recording
credits are on the linked pages; the saxophone and clarinet are themselves
assembled from VCSL samples.

## `vsco2/`

Patches from Versilian Studios Chamber Orchestra 2, Community Edition: violin,
viola and cello sections, pizzicato contrabass, flute, and harmon-muted
trumpet.

Source: <https://github.com/sgossner/VSCO-2-CE>, `SFZ` branch for the mappings
and `master` for the samples. Dedicated to the public domain under CC0 1.0;
exact licence text is in `vsco2/LICENSE`.

## What was changed on the way in

- Release-trigger samples are dropped, along with the regions naming them,
  until playback supports release regions.
- Samples that shipped as WAV were re-encoded to FLAC (lossless) to keep the
  repository smaller.
- Sample paths in each SFZ were rewritten to sit next to the SFZ under a
  directory named after the bank. For VSCO 2 that also means folding its
  `<control> default_path=` prefix into each `sample=`, which drops the only
  Windows-style backslash paths in the set. Mappings are otherwise unchanged.
- Where a pack ships several articulations, only one is bundled, and
  round-robin variants that need `lorand`/`hirand` are left out: the reader
  has no random-round-robin support, so it would layer them instead.
