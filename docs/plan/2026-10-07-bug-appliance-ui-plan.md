# Appliance UI regressions — Issue #1298

## Success Criteria

```success-criteria
GOAL: Fix the appliance-reported mixer pan, recording-input badge crop, and four-bar loop-length failures from release #154.

SUCCESS CRITERIA:
- Recording-input check badges remain fully inside the padded card on the appliance-sized layout. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/audio_routing/audio_routing_test.dart
- The default loop cap is one minute, four bars in 4/4 fit the default cap, and capacity refusals explain how to raise it. | verify: bash packages/segno_engine/src/test/run_native_tests.sh; /Users/Tomas/development/flutter/bin/flutter test test/looper/view/loop_settings/loop_settings_test.dart
- Mixer pan has a focused regression test for its reproduced cause. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/tracks_view_test.dart
- Dart analysis and Bloc lint pass for the changed Dart code. | verify: /Users/Tomas/development/flutter/bin/dart analyze
- The appliance confirms pan changes, shows complete input badges, accepts a four-bar length outside capture, and displays the useful capacity error for a preset longer than the one-minute cap. | verify: manual: 1. Install the candidate release on the appliance. 2. Check both recording-input badges. 3. Change mixer pan and confirm the audio image moves. 4. Set a four-bar loop length while no track is recording or overdubbing. 5. Try an eight-bar 4/4 preset and check the capacity explanation.

NON-GOALS:
- Deploy to or modify the appliance as part of this local fix.
- Merge or publish the change without the issue's merge gate.

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
other refusal causes retain their generic message. The mixer-pan cause remains
under investigation; the source trace and existing tests show the expected
dispatch and render path, so no pan change is made without device reproduction.

## MVP

1. Correct the recording-input badge placement and add a geometry regression
   test at the constrained appliance layout.
2. Raise the default loop cap to one minute and provide a capacity-specific
   explanation. Continue tracing and reproducing the pan failure; implement
   only a cause-specific fix.
3. Run the focused test suites, Dart analysis, and Bloc lint. Preserve device
   validation as a separate, authorized follow-up.

## References

- Related issue: #1298
- Appliance integration context: [APPLIANCE_INTEGRATION.md](../APPLIANCE_INTEGRATION.md)
