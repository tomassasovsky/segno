<!-- cspell:words smoothstep -->
# Ten pills in normal use — #1076

> Historical implementation and device-check record. The final combined source
> is documented in [the publication record](../pedal-publication-1076-1077/verification.md).

The owner requested normal pedal operation on the existing console after
visually confirming all ten eight-pixel pills in the low-current diagnostic.
Firmware 1.9 extends the installed 1.7 implementation, retains protocol 5 and
the old PCB's ring/encoder pins, and addresses the verified 80-pixel harness.
This work is isolated from the new v3 PCB firmware and the previous single-pill
source checkout; their working files have not been overwritten.

## Behavior

- REC/PLAY retains green ready breathing, red recording, yellow layered
  recording, green playback and dark stopped-with-content behavior.
- The four track pills render the active bank's existing app state; MODE shows
  Record red, Mute green or FX blue. CLEAR follows the app's held flag; BANK B
  is blue at the same level as the other pills and BANK A is dark.
- STOP is red and UNDO blue while physically held. These acknowledge input;
  protocol 5 does not establish stopped status or undo availability. In
  particular, all-muted playback must not be mistaken for stopped transport.
- The physical order is TRACK4, TRACK3, TRACK2, TRACK1, MODE, UNDO, STOP,
  REC/PLAY, CLEAR, BANK. The first eight pills reverse their local pixel order.
- The approved eight-point centre curve and 191 peak remain. A combined
  6000-channel-unit limit proportionally dims crowded patterns. At the
  conservative 20 mA/channel model this gives <=471 mA for pill channels;
  ring <=723 mA, estimated pixel idle 104 mA and logic 140 mA total about 1.44 A,
  below the existing PCB's approximately 1.65 A power-track planning budget.
  This is an engineering estimate, not a current measurement.
- Indicator output uses NeoPixelBus 2.8.4 PIO/DMA; the ring remains on its
  existing Adafruit 1.15.5 driver. All 80 indicators clear on lost app state or
  goodbye. The wire protocol and pedal operations are unchanged.

## Local validation

All four firmware suites pass: 45 protocol fixtures, console CTRL,
ten-pill integration, and the inherited standalone diffuser diagnostic.
The integration test feeds encoded STATE frames through the real sketch and
checks all 80 pixels, both banks, mode/CLEAR/BANK, debounced STOP/UNDO events,
REC/PLAY brightness/breathing, current-budget stability and recovery, malformed
frames, disconnect and shutdown. A spatially asymmetric probe checks direction.

The Pico 2 build uses 65,996 bytes program and 10,668 bytes RAM. Both firmware
workflows install the validated LED libraries. Markdown spelling, whitespace,
workflow parsing and deployment-script syntax checks pass.

The final 1.9 ELF SHA-256 is
`021d55a8896307b851a0af05d37bbe48ea468ec9bbe450122ae851aed9d8c4c9`.

## Independent review

All five roles completed with zero unresolved findings:
[VGV](raw/vgv.md), [architecture](raw/architecture.md),
[test quality](raw/test-quality.md), [simplicity](raw/simplicity.md), and
[readiness](raw/readiness.md). The test reviewer also confirmed that disabling
the current limit, dropping row reversal, ignoring the active bank or adding
an extra dimmer each fails the output assertions. The readiness review found
and resolved a library-install name and a deployment success-flag ordering
issue before the device update. Hosted CI and a PR-head merge review have not run.

## Deployment

Firmware 1.8 was programmed over SWD and verified. The controller emitted
HELLO protocol 5 / firmware 1.8. The installed ELF and version marker both
match the verified build, and the new app invocation logged a connection to
firmware 1.8. The service is active with zero restarts. The recovery timer was
disarmed after success. See the filtered [device log](device-log.txt).

The installed update survives normal restart; the original 1.7 ELF and marker
remain backed up on the appliance. Recovery was armed before flashing,
programming had a timeout, and the independent recovery process was configured
to stop the update process before restoring, avoiding simultaneous programmers.

The new app invocation subsequently logged all ten physical footswitches:
REC/PLAY, STOP, UNDO, MODE, TRACK1–4, CLEAR and BANK. The
[control-event log](live-controls.txt) confirms the complete input path after
the update. No disconnect or service restart occurred during this check.

The owner reported that BANK was too dim during normal use. Firmware 1.9
changes its blue level from 80 to 255 before the existing centre curve, matching
MODE's FX-blue output. The shared current limit stays unchanged. All four
firmware suites and the Pico build pass again; the test-quality reviewer
confirmed the matching blue output and unchanged budget protections. The
1.8 image is preserved separately for rollback. The brightness correction was programmed and verified; HELLO 5/1/9,
installed ELF/marker hashes, and the restarted app connection all match. The
service is active without restarts and recovery is disarmed. See the
[1.9 device log](device-bank-log.txt). The owner then confirmed: **“Yes, everything looks right.”** This completes
the normal-use visual check, including the BANK correction.

The preserved 1.7 ELF SHA-256 is
`36a6868e79d30beddff3450a7237f2e89ba6efecb7185c36126b9cb4e246afbd`.

No PCB, Gerber, application bundle or protocol change is included. No order,
commit, PR or appliance OTA release has been submitted.
