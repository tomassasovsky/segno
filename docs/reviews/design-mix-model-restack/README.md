# Mix model reconstruction: verification

October 1, 2026. Issue #1016, PR #1017, epic #1009.

Comparison base: `f130020e405f1e0e341dafb6a28f831d1d134fef`.
The merge retains the original mix implementation parent
`37f328efd07d8f09f2b4981752343b49129786ec` and the verified timing and Loop
settings stack. Reviewed source/test content fingerprint (97 paths):
`973532603179389dc9eb1ab9cdaef20d76e14eaea22e47b9e413d1c5e58f1153`.
Documentation is outside that fingerprint. Existing human merge gates remain.

## Behavior

| Journey | Required result | Evidence |
| --- | --- | --- |
| Input trim, pan and balance | Capture trim changes recorded samples, not live monitoring, raw clipping, tuner or sound trigger | Explicit native samples, boundary values, 18 simultaneous inputs |
| Track mix and Solo | Live level and pan stay separate from recorded source gain; Solo preserves mute and excludes monitors | Native samples, domain projection, hand-authored performance logs |
| Armed recording | Accepted image stays fixed; live faders remain usable; finalize and cancel are not blocked by unrelated pending mix | Delayed publication, cancel/refusal and arm tests |
| Drag and Reset | Latest value for every target survives coalescing; Reset preserves mute, Solo, effects and audio | Deferred callback and ordered overlapping controls |
| Save failure | Validate and durably save one candidate before native admission; restore the exact old value on refusal | Pre-write and post-write failures, present and absent checkpoints |
| Recovery failure | Stop audio, reject device restart and keep Retry available; recovery does not resume audio automatically | Independent coordinator and real AudioSetupCubit boundary tests |
| Session replacement | Save owns its session/device lifetime through settlement and synchronous capture; source gain is not applied twice on recall | Real manifest/WAV round trips and independent stale-capture tests |
| Queue pressure and history | Reject the entire start or retain enough history for exact Undo; deferred fresh starts do not depend on a control poll | Independent PCM replay, queue pressure, cancel/rearm, staged callback tests |

Both LooperBlocs, MonitorCubit, startup and session work use one coordinator.
Track pan, live lane levels, monitor levels and device input setup share one
canonical stored value. Obsolete individual mix writers were removed. Solo
remains temporary. M0 timing and M1 strict schema 8 overrides are preserved.
Sources are the accepted behavior handoff, routing/Mixer design records and
saved Pen recovery state; prototype output is not a native-audio oracle.

## Local checks

| Suite | Passed | Coverage |
| --- | ---: | ---: |
| App | 2,300; 6 existing skips | 93.49%; CI floor 90% |
| Looper repository | 528 | 96.56%; floor 95% |
| Engine Dart interface | 318 | 68.31%; no separate CI floor |
| Session repository | 97 | 98.46%; floor 89% |
| Settings repository | 138 | 91.12%; no separate CI floor |
| Performance repository | 113 | 100%; floor 99% |
| DAW export | 100 | 100%; floor 100% |

- Native normal, AddressSanitizer and telemetry-disabled configurations each
  pass five suites with 702 named cases. ThreadSanitizer races pass 3/3 and
  the non-Clang C++ shim compiles. Platform-specific limits of the test runner
  remain: macOS does not exercise Linux-only cases or real appliance audio.
- All 163 generated FFI entry points resolve in the full native library.
  The device-free test library SHA-256 is
  `30ec6841c2a4e30570098326cfd207185255b19b1a48a880df129574215a8353`;
  full CMake library is
  `2a1c5d02c6e356ce66985766c1078edd711f7716ae4d758c103869218fff8202`.
- Formatter, analyzer and Bloc lint each check the explicit source/test
  paths: 622 files, no issues or formatting changes. Whitespace passes.
  Coverage files are tied to successful executions and verified hashes.
- Final affected runs record unchanged input fingerprints. Unaffected
  session, settings, performance and DAW suites retain their passing evidence
  only because their inputs and exercised dependencies remain unchanged.
- The macOS development app builds, starts and survives hot restart. In the
  actual Signal input page, dragging level settles at -4.8 dB and double-tap
  restores 0 dB. The original level was restored. This is UI evidence, not an
  assertion about perceived sound or the physical console.
- Pen contains the persistent mix recovery state and its Retry behavior.
  The design was saved, its disk hash changed and its bounds/rendering were
  checked. Full recovery interaction through the app shell remains a final
  integration check; recovery and restart blocking are verified at public
  coordinator/repository seams and independently traced to the UI action.

## Review and repaired findings

No unresolved actionable finding remains in this reviewed mix foundation.
Independent roles cover VGV conventions, architecture, test quality, simplicity
and PR readiness, with a separate Astra adversarial review of native ownership,
publication, session and recovery boundaries. Reviewers did not approve their
own implementation. Remote CI remains a separate published-head requirement.

| Findings | Repair |
| --- | --- |
| MIX-F1, F2, F4, F9, F10 | Canonical durable mix transaction, shared consumer, latest-value coalescing and complete Reset persistence |
| MIX-F3, F16 | Invocation-time session/device fence held until detached audio capture; no late rejection after file writes |
| MIX-F5, F20 | Compact primitive logs retain their 28-byte disk format; handwritten test events use the union payload, not structure padding |
| MIX-F6, F11 | Capture-start guard preserves finalize/cancel; accepted pending Record also prevents incompatible pair edits |
| MIX-F7, F8 | Float32-safe trim boundary; original source image and live levels remain separate through WAV/session recall |
| MIX-F12, F13 | Publish capture and required Undo storage atomically, including optional Clear and callback interleaving |
| MIX-F14, F15, F19 | Confirmed edits keep their durable state across stop; post-write faults restore exact checkpoints; recovery blocks all restart callers |
| MIX-F17 | Remove unused single-value settings facades rather than retaining compatibility paths |
| MIX-F18 | Image-aware deferred capture adopts its reserved history from the callback, independent of polling |
| MIX-F21 | Pumped native snapshots preserve acknowledgment and meters; legacy fixtures model confirmed transactions without weakening PCM/FX assertions |

Independent reproductions failed before the pressure, lifecycle and restart
repairs, then passed unchanged. Existing control-sequence fuzz tests passed
without changing their expectations. The FX/Record race still has no drain
between the FX edit and Record; startup is settled before entering that race.
Native sample expectations and handwritten logs do not reuse production
conversion helpers. No test was skipped to make this slice pass.

## Remaining scope

This completes the mix foundation, not the full routing/Mixer/FX milestone.
Stereo pairing still needs selected-source expansion in 3c. Output buses,
stereo offline rendering, routing surfaces and whole-track Pre follow in the
next slices. Complete rollback of prior PCM after a destructive session-import
failure remains an inherited M5 recovery obligation.

Direct fresh deferred starts through the older primitive engine Record API
still have the inherited polling dependency. Current application fresh starts
all use the repaired image-aware API; the broader campaign must close the
remaining public native boundary. Audible pan law, physical ports, displays,
latency and pedal operation require appliance verification. Remote CI must pass
on the current PR head before readiness is claimed; no merge is authorized here.
