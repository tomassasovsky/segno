# Sustained ring fade on the current console

> Historical implementation and device-check record. The final combined source
> is documented in [the publication record](../pedal-publication-1076-1077/verification.md).

Tracking: [#1077](https://github.com/tomassasovsky/segno/issues/1077).

The owner confirmed the 40-pixel strip is connected and authorized trying the
sustained-fade simulation on the existing v2 board. This is firmware 1.11,
protocol 7; the installed app, pill animations and hardware wiring stay intact.

The comet uses two 192-output head pixels, keeps at least half that output for
17 positions, and tapers to darkness across 30 positions including the head.
The remaining ten are dark at integer positions. Fractional circular shifts
interpolate directly in physical output at one revolution per 1100 ms. Only hue
receives gamma. Startup, volume and breathing output preserve the previous
brightness-96 transfer exactly.

The driver stays at brightness 255. Every transfer uses a total ring-channel
budget of 11520, the previous full-white ceiling. The 6000 pill-channel budget
is unchanged. At 20 mA per full channel plus 120 mA pixel idle and 140 mA logic,
the conservative combined estimate remains 1.634 A. The new comet fits without
limiting, even in hypothetical white; these figures are estimates, not measured
current or a revised board rating.

## Validation

Pico 2 compile passes: 66,460 bytes program and 10,668 bytes RAM.
ELF SHA-256: `0c0800e0d754d6dd82fec0702c3bc376dfe192122c23117b9e35d02e02d2ec0d`.
UF2 SHA-256: `b6d07c3505d6ac2f6cc559e95e4d5ce0213657d3e58b39bc1edfeb44719cb5eb`.

Host tests cover actual transmitted ring output, sustained shape, fractional
motion, ring wrap, colour, white and mixed-colour budget limits, stable refresh,
breathing and volume output, stopped-state restoration, link loss and goodbye.
The existing protocol and pill suites remain part of the required runner.
All four firmware suites pass, including 49 protocol fixtures. Diff whitespace
checks and all 15 startup-log verifier tests pass. Five independent reviews
report no findings; see the [consolidated review](review.md).

## Device trial

Installation succeeded after all five independent reviews passed. SWD programmed
and verified the ELF, and the board emitted HELLO protocol 7 / firmware 1.11.
The installed ELF and startup version marker match the validated build. The
unchanged whole-app manifest was verified before and after the update. The fresh
app invocation started audio and connected to firmware 1.11; it remains active
with zero restarts. Independent recovery is disarmed. The original 1.10 ELF and
marker are retained for rollback. Physical appearance on the diffuser is awaiting
the owner's observation.

The existing recording-recovery fault tracked in #1078 is outside
this change; the verifier continues to recognize only its exact pinned historic
exception, which also appeared in this startup. No new startup failure was found.
No recordings were moved, deleted or modified by this deployment.
No commit, PR or hosted release is part of this on-device trial.
