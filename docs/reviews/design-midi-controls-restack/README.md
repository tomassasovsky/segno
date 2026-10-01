# MIDI controls: setup, Learn and shared dispatch

MIDI now has one complete setup page: choose a device and explicit message
format, learn a source, then assign actions or several continuous or button
targets. Save confirms the configuration; Cancel leaves the saved assignment
intact. Missing sources and targets remain visible for repair. A failed disable
stays paused with a clear retry path instead of claiming the device is off.

Standard Note, CC and Program, 14-bit CC, NRPN, Bank + Program and relative CC
share one decoder and dispatch owner. Source identity, capture timestamps and
session lifetime survive queued work. Effect activation has explicit Off/On
endpoints. MIDI and External controls share target ownership and persistence;
momentary values do not accidentally become saved settings during shutdown or
session save. The obsolete seven-bit-only editor and binding path are removed.

## Evidence and scope

The 134 changed source, test, asset and Pen paths are bound in
[source.json](source.json), based on `1ef7fb30abd328b86ac481ec71e72c9bbc59e83c`.
The original MIDI format, model and wiring commits remain in the ancestry.

- [Verification](verification.md): 2,433 application tests and nine package
  suites pass, including all configured coverage floors.
- [Adversarial review](adversarial-review.md): 48 pure behavior and 18 runtime
  probes pass, with a failing timestamp-loss negative control.
- [Source review](source-review.md) and five quality perspectives: one
  independent reviewer performed the roles sequentially; a separate reviewer
  authored and ran the adversarial checks.
- [Bug-focused gate](../../code-review/design-midi-controls-restack/review.md).

Nine MIDI renders and the parent entry views were checked on the author machine.
Ten native references are saved in a labeled Pen section. The running native
app opens Learn and returns to Stage without leaving the Settings tray open.
These checks do not establish physical controller timing or appliance behavior.

This closes MIDI setup and dispatch, not the complete target catalogue. Shared
Mixer and loop/click targets follow next; performance, backing and instrument
targets follow their real domain implementations. Older Pen reconciliation is
still part of final acceptance. Published-head CI and the human merge gate are
separate; nothing has been deployed, flashed or merged.
