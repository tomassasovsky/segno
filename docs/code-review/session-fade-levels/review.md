# Stationary Session Fade review

Issue #1139; base `a921bd9a96044b28dfad9cbd900947573a79a0d6`.
Human merge gate. This is the saved-level portion of durable Fade.

Sessions capture each recorded track's Fade amount from the same detached native
capture as its audio. Recall waits for material finalization, reads fresh track
identities and confirms every stationary Fade installation before publishing the
stopped Session. Invalid values fail before outgoing side effects; failed or
retired imports use the existing cleanup. Duration settings remain separate.

The 20-path source candidate has SHA-256
`4e8792bb7f589072bb3a79428e4e66fdea6cfb3d89e850efed04aa7f1bd3ed0d`.
Five production files add 62 lines and remove two. No new native API, state owner,
dependency or compatibility path is introduced. Exact Session schema 11 requires
finite Fade amounts between zero and one.

Root and independent reviewers covered correctness, architecture, VGV conventions,
test quality and simplicity. Review found a test that rejected an unavailable
device before reaching Fade validation, plus an invalid unequal-hash assumption.
The corrected test uses a running device, a valid audio rig, the precise validation
error and a successful positive control. Both findings are repaired; production
code was unchanged during this review.

Validation: 3,166 app tests pass with 49 conditional skips and 92.653% coverage;
716 ordinary Looper tests pass with 42 native-dependent skips and 95.436% coverage;
116 Session tests pass at 95.930%. All applicable coverage floors pass. The final
test-only corrections reran their full files (374 and 47 passing), with unchanged
production and app inputs bound to the aggregate results. Strict analysis,
19-file formatting and positive 811-file Bloc lint pass.

Twenty-one actual-native focused tests cover moving capture, known first output
samples, delayed material finalization, refusal, timeout and retirement. Native
sources and the tested library are unchanged; prior native safety evidence is
reused. Boot Retry composition uses real owners with a controlled fake device;
it does not prove full-engine reopen retention. The native sample vector is a
bounded oracle, not an exhaustive audio-history test.

Actual Claude review, published-head CI and human merge remain separate gates.
Full-engine material retention is tracked in #1140. Clear/history and user-facing
Fade controls remain subsequent work. No device or listening validation is claimed.
