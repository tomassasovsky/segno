# Shared Record timing: verification

The source manifest binds the intended implementation and tests. Results below
have retained commands, exact source/library hashes and raw output in local
execution evidence. Counts overlap; they are not summed into a larger test claim.

| Check | Observed result |
| --- | --- |
| Full app | 2,552 passed, 116 existing conditional skips; 25,839/28,398 covered lines (90.989%, unchanged 90% floor) |
| Looper repository | 675 passed, 12 conditional skips; 4,280/4,489 (95.344%, unchanged 95% floor) |
| Engine package | 346 passed against the immutable real native library; added interleaved snapshot regression passed separately |
| Settings repository | 181 passed; 784/865 (90.636%) |
| Session repository | 105 passed; 837/874 (95.767%, unchanged 89% floor) |
| Performance repository | 129 passed; 593/597 (99.330%, unchanged 99% floor) |
| Static | Explicit Dart directories format and strict analysis clean; Bloc analyzed 748 files with zero issues; whitespace clean |
| Native | Full standard, ASAN and telemetry-disabled suites plus C++ shim passed; strengthened preparation regression rerun in standard, ASAN and telemetry-disabled configurations |
| Independent native oracle | 17 groups passed; two isolated mutants failed their intended preflight/coherence assertions |
| Independent Dart oracle | Initial 34 cases: 32 passed and two shutdown-debt failures; repaired T24/T25 replay 3/3 passed; private repository pre-preparation counter changed red to 2/2 green |
| Actual App shutdown | Five focused cases passed: compensated refusal, existing recovery Retry/Keep playing, and owed release before or during shutdown; full app aggregate includes them |
| Rendering | Two native mapping golden renders compared and visually inspected; author-only font-dependent evidence |
| Actual development app | Timing edited on Track 8 in Multi, explicit Immediately versus inheritance verified; External timing added/edited/cancelled without saving the temporary mapping |
| Pen | Shared Record timing section saved; on-disk SHA256 b2762e46494834b1f71b996968536923bd6330d51e9ddcd17423aebf90e146ce |

Immutable native library SHA256:
`5084a7feaaac76906b5d34d258f347c40b339b7ef75b03365da5129f87c2a73b`.
Independent oracle SHA256:
`df15b422b459bf0a9f348b4ffb481fc5b645426aad1e6cc0e08179c0c670deee`.

The final workflow explicitly executes the native-dependent timing Session test
and Engine package suite with the built library. Ordinary root runs skip those
native-dependent cases without a library; that is not native evidence. The new
full-snapshot/interleaved-track test also passed independently with the immutable
library. No coverage floor/exclusion or ordinary assertion was relaxed.

All initial failures remain recorded, including fixture compile/initialization
errors, the first root toast dismissal that lost the Keep playing recovery
notice, and the no-test name-filter mistake. Corrected test fixture call labels
reflect the fake's existing command vocabulary; real positive/negative counters
remain asserted. No rerun of unchanged passing inputs is used as repair proof.

Limits: macOS UI and deterministic native execution do not validate appliance
acoustics, physical MIDI/pedals, power loss or system shutdown. Full live-Control
Session Load remains M5. Remote CI must pass on the published head before the PR
is marked ready to merge; this document does not claim that gate in advance.
