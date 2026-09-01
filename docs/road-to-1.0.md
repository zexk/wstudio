# Road to 1.0

Beta releases remain development snapshots. Work may continue between them
without treating any beta as a frozen release candidate.

The per-release goal and validation documents for beta.5 through beta.9 are
gone now that those releases shipped. What they delivered is recorded in
[CHANGELOG.md](../CHANGELOG.md).

## 1.0.0-beta.10

Follow the [beta.10 goals](beta-10-goals.md), then release the working snapshot.
Known hardening gaps do not block beta releases. Continue changing project and
plugin formats as needed; compatibility hardening begins after 1.0.0.

## 1.0.0

Set a separate 1.0.0 gate when product direction is ready for compatibility
commitments. Do not infer that gate from a beta release.

VST3 is the last planned large feature. Embedded plugin GUIs, surround buses,
polyphonic plugin modulation, and MIDI 2.0 are not 1.0 requirements. VST2 is
not a 1.0 requirement.
