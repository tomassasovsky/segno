# Live-input gain correction review

Issue #1124, based on Count-in mappings commit
`e160b677ae222a6ef8558c321e3e5cc0504496dc`.
The reviewed candidate consists of 22 Dart files: 12 production and 10 test
files. No native, generated, dependency or settings-schema changes.

Live-input volume uses the accepted linear 0–100% range; recorded-track and lane
gain keep their existing law. Invalid saved monitor gain is rejected before
restoration or audio opening. Session validation precedes stopping a performance
recording. No new state owner, queue, compatibility target or migration is added.

## Review and evidence

Independent architecture and VGV reviews read the complete intended diff and
traced target conversion, native admission, Settings decoding, startup, monitor
restoration and Session callers. Mechanical review verified scope and artifacts.
Test-quality and simplicity reviews also completed with no actionable findings.
All five roles are complete for the frozen source; no source changes followed
these checks. The additional Claude gate below remains incomplete.

The possible failed-load retry concern was checked and discarded: Monitor load
already cached its first future, and its only production caller starts it
without awaiting completion. The new error handler reports through the existing Bloc observer;
it does not introduce a successful-restore dependency or a new retry flow.

| Check | Observed result |
| --- | --- |
| Focused tests against native engine | 583 passed, zero skipped |
| Full application | 3,007 passed, 49 conditional skips; 92.30% coverage |
| Looper repository | 730 passed; 95.77% coverage |
| Settings repository | 191 passed; 90.98% coverage |
| Session repository | 112 passed; 95.77% coverage |
| Strict analysis | Clean across application and packages |
| Explicit formatting | 22 files, zero changes |
| Bloc lint | 793 files scanned, zero issues |

Application and package coverage meet their configured CI floors. Settings has
no configured coverage floor. All 22 source hashes remained unchanged through
aggregate checks and review. Native monitoring/capture sample tests from the
unchanged engine complement the current application conversion and admission
checks; no new physical sound or controller proof is claimed.

## Gate limits

Current-head CI and the requested additional Claude adversarial review are
separate gates. Claude review is pending because its account limit was reached;
a missing verdict is not a clean review. Do not set ready-to-merge until both
required review and CI gates pass. Human merge and appliance validation remain
outside this local verification.
