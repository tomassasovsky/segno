# Native command fence correction review

Issue #1103, part of #1026. Reviewed October 4, 2026 against
`788999121185f35f76d71a4fa3ba24bcf23353de`. Human merge gate retained.

This is the exact three-file incremental correction from the architecture
audit, isolated from shared Count-in scheduling. The command reservation now
uses the same 64-bit width as posted and published commands. The independent
32-bit receipt revision retains its existing wrap behavior. A lane fingerprint
is evaluated once before its two halves are folded into the track fingerprint.

The coordinator read the complete extracted diff and traced initialization,
all reservation comparisons and assignments, callback publication, fingerprint
readers and the regression. The earlier independent source review covered these
unchanged mechanisms; its verdict is reused rather than described as a fresh
independent review of the extracted branch. No callback allocation, I/O, lock,
public C API or FFI symbol change is introduced.

The regression seeds quiescent counters at the 32-bit boundary and checks
observable admission: a second settings vector and fresh Record refuse before
publication, the first vector publishes without capture, then a later vector
and Record succeed. The same regression failed before the width correction.
The earlier isolated audit run excluded an unfinished Count-in test; the current
publication candidate has no such exclusion and runs its entire native suite.

No unresolved actionable finding remains in this bounded source review. Full
normal, AddressSanitizer, telemetry-disabled and C++ header results are retained
with publication evidence. The test runner does not apply ASAN to its separate
plugin-host C++ binaries; those are ordinary native checks. Device, Windows and
Linux execution and published-head CI remain separate gates. No merge or
appliance validation is claimed.
