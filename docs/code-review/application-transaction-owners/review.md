# Application transaction ownership review

Issue #1109, part of #1026. Base:
`3e8196bc55100b3a1209ed2e12f12384a2777fda`. Human merge gate retained.
The reviewed source is the assembled ownership correction; native scheduling,
aliases, brightness, secondary-display extraction and visual geometry changes
are excluded.

## Review coverage

The application composition and repository extractions received separate
independent Codex reviews. The repository reviewer read the complete twelve-path
package diff, including receipt lifetime, passive queries, import publication,
cleanup refusal and removed settings APIs. The application reviewer traced
shared save ownership, Session capture and boot completion, disposal order,
control retirement, and all nine deliberate extraction differences.

The final author completeness pass read every changed presentation, model and
test hunk, including new files and paired relocations. The six relocated suites
retain 457 behavioral assertions. Root reviewed the core save, edit, Session,
application-lifetime and control paths and consolidated the full diff review.
Earlier independent mechanism reviews apply only where exact source hashes
match; they are not represented as fresh reviews of the assembled candidate.
Source and review manifests are retained with the private campaign evidence.

Claude Opus 5 completed two read-only adversarial passes. The first found
pending FX saves could be abandoned or outlive graceful application disposal.
Five new regressions reproduced those failures. The correction flushes before
disposal, retains genuine receipt completion and waits for started storage even
when another save fails. All 31 focused cases pass. Independent Codex review
covers the full four-file correction and actual session failure ordering.

The follow-up verified those fixes and found the widget disposal caller could
leave the newly reported storage failure unhandled. The caller now logs the
original error and stack after cleanup; an actual App unmount regression fails
before and passes after this correction. Root and a separate reviewer inspected
this final caller/test delta. Claude did not review that last correction; its
finding is closed by the discriminating regression and independent source review.

The follow-up also challenged an overbroad close guarantee. Queued ordinary
edits intentionally wait behind an immutable failed session boot image. A failed
flush is reported before disposal; it is not a successful durable save. Draining
around that barrier would violate recovery. The documentation now distinguishes
started storage work, which close awaits, from queued retries, which disposal
abandons after the flush attempt. No new admission policy was added.

No unresolved actionable findings remain in the reviewed source. Normal power-off
still refuses to halt after failed persistence. Forced process termination is
not covered.

## Validation

- App: 2,847 tests pass, six conditional skips, 92.127% coverage using the CI
  exclusions. Author-only screenshot tests are excluded from this aggregate.
- LooperRepository: 717 tests pass, zero skips, 95.809% coverage, against an
  immutable library built from the unchanged native source on this base.
- SettingsRepository: 187 tests pass, 90.728% coverage.
- Strict analysis passes; 135 explicit Dart paths format without changes;
  Bloc scans 785 files with zero issues.

The first app run found two test imports that reported success without
publishing the imported audio. The fake now supplies the same completion
witness that production requires; assertions were not weakened. Both focused
Session suites and the full app aggregate pass afterward. Initial failed runs
remain in the evidence record.

## Size and limits

Most of the large diff moves existing transaction bodies and their tests.
Changed production paths grow by 712 lines overall; `app.dart` loses 298 lines.
No generic transaction framework or compatibility bridge is added. Shared FX
saving and Session completion remain one cut because removing the previous
post-load writers before their replacement would lose boot persistence.

This is source and deterministic behavior validation. Existing FX geometry and
screenshot-baseline work remain separate; no Pen change, visual approval,
hardware soak, power-loss durability or deployment is certified here.
Physical device absence retains the existing wait-for-reconnect receipt policy;
this correction does not introduce a timeout or certify hardware recovery.
Current-head CI must also pass before the PR is ready to merge.
