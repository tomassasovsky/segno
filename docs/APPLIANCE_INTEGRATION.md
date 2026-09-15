# Appliance integration — September 2026

<!-- cspell:words Wrynose -->

## Source of the running release

The appliance release `0.1.0-experimental.137` was built on September 4 from
`570a7b24bfab8021f359a84a2a97b5e0177a2c60` on
`feat/appliance-flashes-console-board`:
[successful build](https://github.com/tomassasovsky/segno/actions/runs/33886519324),
[release artifacts](https://github.com/tomassasovsky/segno/releases/tag/appliance-experimental-0.1.0-experimental.137).
The owner confirmed that this release is running on the appliance.

The release tag points to `aaf042655b5059d9aff7c647a02249c1d019de84`, which
is not the workflow's source commit. Use the workflow head above when tracing
this build. Future releases explicitly target the commit being built. Existing
release tags and published artifacts are unchanged.

## Integration scope

The stack comprises [#984](https://github.com/tomassasovsky/segno/pull/984),
[#986](https://github.com/tomassasovsky/segno/pull/986), and
[#990](https://github.com/tomassasovsky/segno/pull/990). It brings the console's
UART pedal link, CTRL jack assignments and calibration, boot-time console
firmware flashing, and boot-partition OTA payload into the current master.
The obsolete USB-MIDI pedal and AVR flashing path are removed.

The integration retains master's later RTC configuration, application fixes,
and enclosure/manufacturing changes. The final hardware changes following the
released commit are also retained. The base remains Yocto Walnascar with the
6.12 kernel; the separate Wrynose work is not required for this stack.

Integration review corrections cover compatible-HELLO gating, UART resource
ownership and reconnect tests, CTRL disconnect/unplug behavior, calibration
persistence, boot-file producer dependencies, and release-tag provenance.
These corrections make the integrated tree different from release 137.

## Hardware boundary

The running firmware targets the v2 console board: Pico 2, direct encoder and
NeoPixel ring, and CTRL ring sensing. Earlier bench records in #984 and #990
cover end-to-end console controls, boot flashing on release 133, and the FS-6
and EX-P on release 136 with firmware 1.4 / link protocol 5. Those records do
not validate a newly integrated image.

The v3 PCB and ring-board design files are retained as hardware work in
progress. They still require:

- Console firmware for the PIO UART ring link and firmware for the ring
  board's XIAO controller.
- Firmware, protocol fields, and application display for the negotiated USB
  power contract.
- End-to-end validation of those paths on assembled v3 hardware.

A clean software test run or recorded PCB DRC does not establish v3 readiness.
The v2 top-rail unplug heuristic also remains distinct from v3's physical
presence contacts; test both pedal travel and insertion/removal on the target
board before publishing a new appliance release.

## Verification and release boundary

The owner authorized integrating and merging the stack. That authorization
covers source control, required CI, and review; it does not deploy an image or
flash an appliance. Release 137 remains the device reference until a separate
release and hardware-validation task records a newer installed build.

Software checks cover the Dart application and affected packages, the native
firmware contract and sketch behavior, appliance shell helpers, and the Linux
builds in CI. Local screenshot comparisons had the same 52 failing tests on
the unmodified master baseline; their results must stay separate from the
functional checks and remote CI.
