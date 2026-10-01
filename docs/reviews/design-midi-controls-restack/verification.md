# Verification — MIDI controls

## CI coverage correction

The first published workflow passed its tests but failed root coverage at
89.07%. The author-side run below included screenshot/native tests which the
ordinary CI job skips. That local coverage did not establish the remote gate.

Added 23 behavioral MIDI editor journeys, bringing that file to 38 passing
tests. These exercise every supported Learn format, source/channel identity,
multiple targets, Save/Cancel, duplicate sources, failed writes and deletion,
target repair, button edges, controller changes and picker navigation. An
independent source and five-perspective review found one timing-fixture risk;
explicit capture timestamps fixed it without changing the decoder rules.
The revised test delta has no unresolved actionable review findings.

The final root run excludes author-only screenshot tests and supplies no native
engine library: 2,306 pass, 68 existing skips, 23,095/25,660 covered lines
(90.0039%). Its inputs did not change during execution. The existing 90% floor
and exclusions are unchanged. Formatting, strict analysis and Bloc lint across
703 actual files also pass. No application, package, native or Pen bytes changed;
their earlier source and execution evidence remains applicable. The first
failing CI run and intermediate local runs are retained in the evidence.

The current manifest includes the reviewed test-only correction. Remote CI on
the new published head remains required; this local result does not replace it.

## Original author-side verification

The original results bind to the previous fingerprint recorded in
[source.json](source.json). That application run had no
input drift. The only later application change explicitly marks an already
ignored Future returned by removing a completed decision from its map;
independent review confirmed unchanged execution, and both close regressions
passed again. Final formatting, strict analysis, Bloc lint across 703 actual
Dart files and whitespace checks pass without input drift.

| Suite | Passed | Existing skips | Line coverage | Required floor |
| --- | ---: | ---: | --- | --- |
| app | 2433 | 6 | 23314/25660 (90.857%) | 90% |
| controller_repository | 23 | 0 | 496/601 (82.529%) | 82% |
| midi_client | 41 | 0 | 133/138 (96.377%) | No workflow floor |
| midi_device_repository | 24 | 0 | 125/137 (91.241%) | No workflow floor |
| settings_repository | 150 | 0 | 679/758 (89.578%) | No workflow floor |
| looper_repository | 656 | 0 | 3877/4044 (95.870%) | 95% |
| segno_engine | 346 | 0 | 1976/2830 (69.823%) | No workflow floor |
| session_repository | 105 | 0 | 837/874 (95.767%) | 89% |
| performance_repository | 129 | 0 | 593/597 (99.330%) | 99% |
| fx_catalogue | 21 | 0 | 89/89 (100%) | 100% |

Application coverage uses the existing CI exclusions. No threshold or behavior
assertion was weakened. The nine package runs had unchanged inputs; their
source and dependency hashes still match after the application repairs.

Native normal, address-sanitized and telemetry-disabled suites pass. All 611
bound native inputs remain unchanged. Program Change parsing and native ring
shutdown are exercised by that runner. Linux backend compilation is a remote
CI gate; physical devices and real-time latency still require the bench. The
public FFI header is unchanged. Application audio tests use the previously
verified audio library; changed MIDI translation units are covered separately
by the complete native runner.

## Repair history and independent checks

The first aggregate run exposed stale test fixtures and two expected Settings
render changes. The App fixture also waited indefinitely while disposing a
repository still borrowed by mounted widgets. The failed run was retained and
stopped explicitly; the corrected fixture unmounts the App before disposal.
Shared engine getters and sample-rate fixtures now describe valid live state.
The complete corrected application run passes.

Independent review also found a real teardown race: an outstanding FX decision
could emit after its control owner closed. Two regressions fail against the old
source, including the late emission, and pass after close cancels and drains
the decisions. The broader 17-case repair run passes. Final source review
rechecked the repair and the fixture changes.

The [adversarial report](adversarial-review.md) separates its independently
authored probes and negative control from author regression coverage. Nine MIDI
goldens, the revised parent entries and the native app journey were inspected.
The Pen save was verified on disk and its ten-reference section has no detected
clipped children. These are author-machine visual checks, not CI screenshots or
hardware proof. Full historical Pen reconciliation remains separate work.

Unchanged firmware and other unaffected package gates retain their verified
predecessor evidence. The new published commit must pass all its own remote CI
checks before readiness; local success alone does not satisfy that gate.
