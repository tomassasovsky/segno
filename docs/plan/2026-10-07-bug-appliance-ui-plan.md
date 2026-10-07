# Appliance UI regressions — Issue #1298

## Success Criteria

```success-criteria
GOAL: Fix the recording-input badge crop and four-bar loop-length failure from release #154; leave the mixer-pan failure open until it can be reproduced.

SUCCESS CRITERIA:
- Recording-input check badges remain fully inside the padded card on the 1024×600 appliance layout. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/audio_routing/audio_routing_test.dart
- The default loop cap is one minute, four bars in 4/4 fit the default cap, and capacity refusals explain how to raise it. | verify: bash packages/segno_engine/src/test/run_native_tests.sh; /Users/Tomas/development/flutter/bin/flutter test test/looper/view/loop_settings/loop_settings_test.dart
- Dart analysis and Bloc lint pass for the changed Dart code. | verify: /Users/Tomas/development/flutter/bin/dart analyze
- The appliance shows complete input badges, accepts a four-bar length outside capture, and displays the useful capacity error for a preset longer than the one-minute cap. | verify: manual: 1. Install the candidate release on the appliance. 2. Check both recording-input badges. 3. Set a four-bar loop length while no track is recording or overdubbing. 4. Try an eight-bar 4/4 preset and check the capacity explanation.

NON-GOALS:
- Change mixer-pan behavior without reproducing its cause.
- Publish or merge a release as part of the diagnostic installation.
- Merge the change without the issue's merge gate.

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/audio_routing/audio_routing_test.dart test/looper/view/tracks_view_test.dart test/looper/view/loop_settings/loop_settings_test.dart test/looper/cubit/record_options_cubit_test.dart test/audio_setup/view/audio_faces_test.dart && /Users/Tomas/development/flutter/bin/dart analyze && bloc lint lib test packages
```

Native verification after changing the default cap:

```sh
bash packages/segno_engine/src/test/run_native_tests.sh
EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh
EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
```

## Context

Issue #1298 was reported against appliance release #154, built from
`e0c7578713d41e6603f59faa828307e0101c641a`. The provided photo confirms that
both visible recording-input check badges are clipped at their right edges on
the compact display. The card places a 32-pixel badge at the right edge of its
padded stack, but the card border makes that stack two pixels narrower than
the placement assumes.

The issue also reports mixer pan not working and four-bar loop length edits
being rejected. The length cause is confirmed: the D17 preset guard checks
capacity at 30 BPM, where four bars of 4/4 take 32 seconds, exceeding the
default 30-second cap. The user approved raising the default to one minute,
accepting the added audio-buffer memory, while preserving the 30 BPM guard.
Capacity refusals will identify the loop-length limit and where to change it;
other refusal causes retain their generic message. For pan, a new native
live-output regression changes both lane pans through `le_engine_set_mix` with
whole-track Pre caching enabled and disabled; both modes produce the expected
hard-left output, and the cached mode rerenders. A `PumpedNativeEngine` test
also drives both live-monitor input pan and track pan through the settings
coordinator, repository, Dart FFI, and native engine, producing the expected
stereo output. The user confirms the appliance still
shows the failure with track FX bypassed, with live input pan as well as track
pan, while output balance works and the selected bus is Stereo. The source
tests do not reproduce this device behavior, so no speculative pan change is
made; #1298 remains open pending further runtime investigation.
The release candidate only fixes the badge and loop-cap reports.

To capture the appliance discrepancy, the coordinator now emits a `PAN_DIAG`
log after confirmed track/input pan edits. It records requested and confirmed
pan, engine-reported per-lane pan, per-track peaks, monitor and output channel
peaks, output channel count, sample rate, backend, and the resolved first
output bus. Logging runs on the control isolate and does not alter the audio
path. The user authorized installing a temporary diagnostic build on the
appliance; the signed bundle is retained as a one-day Actions artifact for
this non-published install. This is not a release or a claim that the pan
issue is fixed.

## MVP

1. Correct the recording-input badge placement and add a geometry regression
   test at the constrained appliance layout.
2. Raise the default loop cap to one minute and provide a capacity-specific
   explanation. Continue tracing and reproducing the pan failure; implement
   only a cause-specific fix.
3. Run the focused test suites, Dart analysis, and Bloc lint. Install only the
   verified temporary diagnostic build, collect the device evidence, then fix
   pan only when that evidence identifies the cause.

## References

- Related issue: #1298
- Appliance integration context: [APPLIANCE_INTEGRATION.md](../APPLIANCE_INTEGRATION.md)
