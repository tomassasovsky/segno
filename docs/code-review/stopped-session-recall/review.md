# Stopped Session recall review

Issue #1134; base `ff73b97941504081d884de46e7d37f621910af5e`.
Human merge gate. This is a prerequisite for durable Fade, not that whole feature.

Loading previously started imported tracks before their saved settings finished
applying. The existing native commit now publishes STOPPED content. The existing
boot admission block spans application and persistence, and normal Play launches
a completed recall. Audio-bearing loads without a running, present device are
refused before destructive work; settings-only empty loads remain supported.

The 23-path candidate is bound by source freeze SHA-256
`5d1b504fc8a4c6499dd1794bce2959bfc399f8e241ca4dd780ddf49ac897ffa7`.
Review covers native commit/clock/crown behavior, all commit callers, public and
generated API documentation, repository and Session ownership, internal apply,
failure/retry/cancellation, and meaningful test oracles. An independent checklist
was derived from the accepted behavior before reading the implementation.

Root and two independent reviewers found no remaining actionable issue. The
reviewers covered native correctness and Dart correctness, conventions, test
quality, simplicity and readiness; these were grouped roles, not five additional
people. Review requested the composed runtime test that now exercises real
Session/Looper owners through a delayed boot write. Separate native sample
assertions prove silence in the commit callback and normal explicit Play afterward.
Existing playback fixtures now launch explicitly, retaining PCM and history
assertions. Successful recall fixtures explicitly declare their present device.
The stale-crown test now expects stopped content while retaining both crown checks.
No new transport owner or API option was introduced.

Local validation passes: app 3,142 tests (49 conditional skips), 92.636% coverage;
ordinary Looper 715 tests (37 native-dependent skips), 95.163% coverage; Session
112 tests, 95.771%; Engine 356 tests with the matching native library. Focused
native repository and publication checks pass. Native standard, sanitizer,
telemetry-disabled, C++17 shim and all 187 FFI symbol checks pass. Strict analysis,
explicit formatting and Bloc lint (806 files) pass. Unchanged native and app
results were reused after fixture-only corrections; affected package checks were
rerun. Failed initial runs are retained separately from passing evidence.

Actual Claude review, published-head CI and human merge approval remain separate
gates. No appliance, physical controller or listening validation is claimed.
