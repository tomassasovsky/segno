# Output destinations reconstruction: verification

October 1, 2026. Issue #1016, PR #1018, epic #1009.

Comparison base: `77d486263544859612fc76345889f41f1f4adfac`.
The merge preserves original output implementation parent
`8625ba75a7f1c489e6a2f25694c62c673c830f6c` and the verified timing, Loop
settings and atomic mix stack. Reviewed source/test fingerprint (63 paths):
`4a1feb26b741330181e76501c65d540c9e8655c7e7f3d2c046bded21278c88e5`.
Documentation is outside that fingerprint. Human merge gates remain.

## Behavior

| Journey | Required result | Evidence |
| --- | --- | --- |
| Output setup | Level, mute, Mono and balance join the existing atomic mix transaction and durable rollback | Native acknowledgment; settings, session and coordinator fault cases |
| Actual ports | Retain device intent, expose actual destinations and do not halve a lone enabled Mono jack | Odd-channel and selected-pair native sample cases |
| Record output | Capture the selected output effect chain once; freeze destination and policy at callback acknowledgment | Independent real PCM and separately reconstructed WAV samples |
| Follow output | Follow applies the selected destination's changing level and mute; default does not | Fixed expected samples before and after volume/mute changes |
| Hardware controls | Neither capture policy includes Mono, balance, hardware master gain or limiter | Wrong-bus and hardware-control exclusion probes |
| Bypass | New input is dry while existing delayed audio finishes, including sparse echoes and tails beyond eight seconds | Independent impulse arithmetic and durable DSP regressions |
| Cut sound | Stop recorded sources, cancel pending recording gestures and clear existing delay memory and current click pulse | Late-impulse replay, pending-arm cases, current-pulse sample probe |
| Delayed arm | Await callback acknowledgment; cancellation cannot leave a queued capture running | Actual pumped engine with delayed callback and cancellation/queue-pressure tests |
| Capture I/O failure | Keep live ownership and settled facts until confirmed Stop; publish recovery metadata atomically | Write failure reproduced before repair, getter failure, stop refusal and retry |
| Damaged capture metadata | Reject invalid destination identity before unsafe casts, shifts or export | Handwritten malformed fields and valid boundary neighbors |

Later live input can produce new sound after Cut; monitoring and future click
preferences are preserved. A Cut-generated recording finalization does not
restart the stopped source. Output changes have unique primitive event IDs;
bounded mix transactions emit their applied controls rather than serializing a
large payload into the fixed event format. Output-chain reconstruction never
reprocesses the already captured top-level master audio.

## Local validation

| Suite | Passed | Coverage |
| --- | ---: | ---: |
| App | 2,312; six existing skips | 93.44%; floor 90% |
| Looper repository | 536 | 96.84%; floor 95% |
| Engine Dart interface | 331 | 68.29%; no separate floor |
| Session repository | 99 | 98.58%; floor 89% |
| Settings repository | 139 | 91.69%; no separate floor |
| Performance repository | 128 | 99.31%; floor 99% |
| DAW export | 100 | 100%; floor 100% |

Native normal, AddressSanitizer and telemetry-disabled builds each pass 715
named cases across the existing five suites, plus the new plugin runtime
regression. ThreadSanitizer passes three engine races and the plugin regression;
the non-Clang C++ shim compiles. All required local coverage floors pass.

The first broad run exposed obsolete Follow/event-log expectations and a shared
app fake without arm acknowledgment. Corrected tests retain exact sample/event
assertions; the fake has explicit refusal and injected-state tests. A session
round-trip timed out under concurrent compile/test load, then passed unchanged
in an isolated suite; its timeout was not increased. Successful unchanged
package results are reused only where the exercised source and library inputs
remain the same. Final changed-input checks are recorded.

The final coverage addition checks failed cleanup after a post-arm read error:
capture stays visible and owned, cannot be re-armed into another directory, and
can be stopped immediately on retry without inventing recovery facts.

Formatter, analyzer and Bloc lint pass, with 625 files actually scanned by
Bloc. A hidden-checkout path initially produced a no-op; the final scan uses a
visible symlink to the same source and verifies the real file count. All 170
native FFI entries resolve in the full library. Immutable final library hashes:

- Device-free test library:
  `7507f3ab8c7f4efefb90c620453610a43b02c94b517fd80e1d048c8e87736020`.
- Full CMake Release library, plugins disabled:
  `7045535acbe0fb16e06f3ae37730bbc48b4bb05b5a86298b5a5e15e62dd42390`.

Independent behavioral replays pass on those frozen inputs. Source authors did
not certify their own changes. Review includes VGV conventions, architecture,
simplicity, test quality and PR readiness, plus the bug-focused and adversarial
checks. The same independent reviewer fills those five roles; they are not five
independent model votes. Published-head CI remains a separate requirement.

## Repaired findings

| Finding | Repair |
| --- | --- |
| OUT-F1 | Preserve sparse and long bypass tails until a complete delay-memory horizon is quiet |
| OUT-F2 | Require the same explicit capture policy in native and Dart readers |
| OUT-F3 | Clear actual delay memory during offline Cut and retain silence across finalization |
| OUT-F4 | Move hosted-plugin runtime reset from the control thread to callback ownership |
| OUT-F5 | Cancel queued grid/sound starts and their recorded-image reservations on Cut |
| OUT-F6 | Await capture acknowledgment and safely cancel queued native arms |
| OUT-F7 | Retain capture ownership through metadata failure; refuse session replacement if Stop fails |
| OUT-F8 | Require valid capture mask and strictly validate destination fields before reconstruction |
| OUT-F9 | Clear the currently sounding click pulse without changing future click preferences |
| OUT-F10 | Publish successful armed notification after settled metadata is saved; keep failed publication visibly owned |

The independent checks derive expected samples from fixed arithmetic or
handwritten event logs, not production conversion helpers. Earlier failing
artifacts are preserved separately. No test is skipped to make this slice pass.

## Remaining scope

This is the output foundation, not the complete routing, Mixer or FX milestone.
Routing surfaces and pair admission follow in 3c. Offline reconstruction still
has inherited limits for multiple lanes, live inputs, click and track-bus FX;
full performance parity belongs to subsequent integration. Native backing audio
remains M5. A crash before settled arm metadata publication cannot supply missing
provenance; recovery must not invent it.

Physical port identity, perceived audio, callback latency and appliance behavior
still require hardware verification. The final app-shell review follows the
routing surfaces; backend sample checks do not prove a new UI flow. No merge or
deployment is authorized by this report.
