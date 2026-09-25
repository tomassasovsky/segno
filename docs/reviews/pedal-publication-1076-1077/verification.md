# Current-console firmware publication — #1076 and #1077

This branch publishes the cumulative work developed for the existing v2 console:
all ten eight-pixel indicator pills, native-engine Song queue completion, and
the sustained comet for the connected 40-pixel strip. Firmware 1.11 and protocol
7 are the final target. The app/native library and firmware require the matching
protocol; install them as a pair. The new v3 PCB firmware is a separate target.

## Source and tracking

The firmware, native engine, generated bindings, repository/control projections,
Dart/C fixtures, behavioral tests and both firmware build workflows belong in
one pull request because the Song state crosses all of those boundaries.
The standalone eight-pixel diagnostic and its tests are included as the bench
source from which the approved pill output was developed. The approved
[queue-fill and sustained-comet simulations](../../simulations/README.md) are
also retained as standalone browser pages; their animation scripts are unchanged.

This work closes #1076 and #1077 when merged. It retains
`autonomy:blocked-verify`: physical Song handoff and the final ring appearance
have not yet been confirmed. No production PCB order or appliance release is
part of this publication.

## Validation evidence

- [Ten-pill implementation and physical acceptance](../live-ten-pills-1076/verification.md).
- [Song queue, native/app integration and matched deployment](../song-pill-completion-1077/verification.md).
- [Final sustained ring fade, output limits and firmware 1.11 deployment](../sustained-ring-fade-1077/verification.md).

These records are dated stages of the same work, so their earlier firmware
versions and statements that no commit or PR existed describe those trials.
Their independent reviews do not by themselves certify a later PR head.

Before publication, all four firmware suites passed again: 49 protocol
fixtures, console controls, full ten-pill/ring output and the standalone
pill diagnostic. The publication review also corrected the bench diagnostic to
clear all 40 connected ring pixels; its test seeds prior colour and verifies
the complete blackout. The application/native source is unchanged since the recorded
passing native, sanitizer, telemetry-disabled, real-library integration,
Dart analysis, formatting, Bloc lint and package/application coverage checks.
The standalone previews were checked in a browser: loop-end handoff, queue and
cancel, pause/resume and individual-pixel views work; both pages render clearly.
Their embedded JavaScript parses and preserves the approved animation source.
Hosted CI status and the cumulative current-head review are reported on the PR.

## Stop timing correction found during publication review

A Song handoff can occur between repository polls. Stop previously addressed
only the old running section from the cached snapshot, allowing the newly
playing section to continue. A quick Play/Stop before the next poll could also
leave playback running. Two real-engine regressions reproduced those failures.

Song Stop now also addresses stopped content sections that may have started
since the poll. It preserves the resume intent, defining recordings, count-in
and behavior in other modes. All 197 tests in the control and real-engine
corpus files pass, including three new race regressions; analysis, formatting
and Bloc lint pass on the three changed files. This application correction and
the bench diagnostic correction have not been deployed by this publication.

## Device state and remaining checks

The latest observed installation reports firmware 1.11, connects to the matching
app and starts audio without restarting. All ten pills and the BANK brightness
were physically accepted earlier. The complete queued fill/audio handoff and
sustained comet appearance still need observation during ordinary pedal use.
The pre-existing large-recording recovery fault remains separately tracked in
#1078. No recordings were modified and this publication does not flash the pedal.
