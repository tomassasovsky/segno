# Physical pedal indicators

All ten pedals now have independent activity and color. The app, accepted setup
map and console board use one published frame. Editing selection marks the
pedal body; it never lights an indicator. A draft bank does not change the live
bank or borrow its track lights. Fixed pedals can show their actual state even
when they cannot be selected for assignment edits.

Base: `3e67d031148f21eb9c3ee99a961f6ca4587dbc3b`.
Original proposal parent: `424e12d0e53a969f8887089be0ea9450404be969`.
The [source binding](source.json) covers 69 implementation, design and test
paths before these report-only additions.

## Behavior and hardware contract

- Custom transport and track switches show their accepted action state or
  contact. Refused actions cannot replace the last completed action. Delayed
  results cannot attach to a different contact, setup or session.
- Normal Stop and FX panic/restore honor engine admission. Disconnect clears
  contact feedback before publishing a reconnect frame. Empty Clear stays dark.
- UART version 8 carries exactly 51 STATE bytes: the existing 19-byte facts,
  ten RGB triples and a ten-bit activity mask. Unknown versions, wrong lengths
  and reserved bits are refused. No retired SysEx or AVR path is restored.
- The ten eight-pixel pills and forty-pixel ring use the layout, optical limits
  and bounded renderer sourced from PR #1079. Interrupt-safe pixel output uses
  NeoPixelBus 2.8.4; both Arduino build workflows pin the same driver versions.
- Hue and activity remain separate. Fresh hue is white; black is valid.
  User palette editing follows in PR #1032. Selection never replaces live hue.

The public version differs deliberately from earlier reconstructed protocol 6
and existing hardware protocol 7. Those intermediate app PRs must not be
installed alone. Update this app and its matching firmware together. The source
boundary and physical mapping are recorded in the
[firmware guide](../../../firmware/console_board/README.md).

## Observed verification

The complete application suite passes 2,346 tests with six existing skips and
91.126% coverage. The pedal package passes 213 tests with 97.743% coverage.
Formatting, strict analysis, real Bloc lint across 665 files and whitespace
checks pass. All inputs stayed unchanged during the final runs.

Firmware tests pass 48 shared fixtures and the actual console sketch's CTRL,
pill and ring suites. A real Pico 2 compile succeeds with 66,012 program bytes
and 10,720 static RAM bytes. Unchanged native audio and other package checks
are reused only with matching source/dependency fingerprints; their build
commands and flags did not change.

One independent reviewer completed the full source bug gate and five quality
roles. A separate adversary passed C literal and actual pixel-output probes,
two Dart codec cases and eight app/repository cases. Expectations came from
accepted behavior and a frozen literal oracle, including real engine refusal
and delayed shared-owner results. These are separate from author tests.

The first aggregate run retained one outdated positive Clear fixture on an
empty rig and one test style diagnostic. Two test-only repairs supplied actual
clearable audio, added empty-rig darkness, and preserved call order with a
cascade. Production source did not change; the final full run passes.

Six setup images were independently inspected. The running macOS app confirms
live Track 1 activity remains separate from Mode editing selection, editing
Bank B does not change live Bank A, and Stage closes setup without recording.
Pen contains the saved implementation note and indicator-state examples.
Complete historical canvas reconciliation remains part of final product QA.

No device was flashed. Physical timing, harness orientation, optical acceptance
and electrical behavior still require appliance validation. Remote CI must pass
on the published head; the existing human merge gate remains in force.
