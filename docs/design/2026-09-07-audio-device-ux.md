# Audio device setup and recovery

Status: revised prototype, reviewed positively with an interface-name color
correction. Awaiting explicit acceptance. The initial interface-picker-first
layout was rejected and replaced; it is not a current design option.

## Connected interface first

Settings → Device opens the connected audio interface. One attached interface is
the normal case. Its name, channel count and connection state form a compact
header. **Change interface** opens the secondary picker; disconnected alternatives
are not invented as permanent choices on the main page.

The main controls are sample rate, buffer size, round-trip latency measurement
and audio-health feedback. Supported values belong to the detected interface.
This study demonstrates 44.1, 48 and 96 kHz with 64–512-sample buffers. The buffer
period is calculated from the selected rate and frames; it is explicitly labelled
**per buffer**, separate from measured round-trip latency.

Input naming, pairing, trim and pan retain their accepted home under Routing →
Inputs. Output naming, stereo/mono, balance, level and mute retain Output setup.
Device configures the audio engine; it does not duplicate those channel editors.
Linux appliance scope applies. Windows drivers and desktop launch preferences do
not appear on this page.

## Applying settings

Rate, buffer and interface selection edit one draft. **Apply** commits the draft;
**Cancel** restores the active configuration. Leaving the page discards its draft.
No device reopen occurs merely because a control is selected. During playback,
Apply offers **Cancel** or **Stop audio and apply**. Recording must finish first.

Success stops loops and backing playback while retaining recorded content, effect
parameters, controller assignments and routing. Changing configuration invalidates
the previous latency measurement. Open/save failure keeps the prior configuration
and playing state; retry is explicit. Hardware configuration is appliance state:
New loop and session recall cannot replace it.

A replacement with fewer channels than the configured setup is unavailable with a
short reason. Reassigning missing ports without losing routing intent remains a
later design extension; this slice does not silently discard channels.

## Latency calibration

**Measure** first attempts automatic measurement. This is the owner-requested
default path. A supported, isolated internal loopback can complete without a
cable. If playback is running, confirm its interruption before sending a test
signal. Missing or unsuccessful automatic loopback opens the cable-test dialog.
Choose an output and input jack using touch or the encoder, connect the cable,
then **Start test**. Driver latency estimates must never be labelled measured
round-trip latency. The automatic attempt may inspect capabilities without
sending a signal; it must not probe arbitrary audible outputs. The dialog explains the
output pulse and interruption before starting. Playback stops and live monitoring
is muted during the test. Cancel, Back, leaving Device and interface loss cancel
the test without storing a partial result or restarting playback.

A successful test reports round-trip milliseconds and recording-timing
compensation. No-return and save failures offer retry. The previous valid result
remains until a new result is saved or the audio configuration changes. Merely
opening or cancelling calibration does not discard it.

## Disconnection

Interface loss stops loop and backing transport, finishes the available partial
loop take, and retains a recoverable performance-recording checkpoint. Stage
meters go quiet and its audio warning opens this same Device page. Back restores
the same Stage selection and view. Another attached interface is never substituted
automatically. Reconnecting the cable alone does not restore monitoring or start
transport; **Reconnect audio** makes that transition explicit.

## Evidence and scope

The existing Device tab in `lib/audio_setup/view/console/device_audio_tab.dart`
provided evidence for missing sample-rate, buffer and measured-latency controls.
The UX audit's host-interface recovery requirement informed the canonical repair
path. Host USB audio is distinct from Looper X's computer-facing USB gadget modes;
this screen does not claim that parity.

`verify_audio_device.cjs` passes in Chrome and Firefox: draft/apply/cancel,
automatic calibration and cable fallback, channel selection, cancellation, no-return recovery, configuration
invalidation, change during playback, capture guards, interface loss, partial-take
recovery, session isolation, storage rollback, reconnect and canvas bounds. The
Library, performance-recording, session and two-display recording regressions also
pass for the device integration.

All devices, meter values, driver outcomes and calibration results are simulated.
No audio hardware or OS preferences are changed. Production work includes actual
capability discovery, negotiated-versus-requested settings, rate changes without
changing recorded timing/pitch, asynchronous device reopen, signal isolation for
calibration, measured record compensation, hotplug and durable recovery. These
require Linux appliance validation; browser or Pen checks do not prove them.
