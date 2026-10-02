# Independent Click runtime and integration delta review

Read-only review on 2026-10-01, followed by the final independent 55-case replay.
**No additional actionable finding remains in the bounded final delta.**
M311-A1 is resolved by its unchanged replacement-gain assertion; M311-COPY is
resolved by source inspection. This report does not claim a complete product
review, five independent roles, or the separate CI/UI gates.

## Scope and binding

Compared the retained runtime-v1 source against final TempoCubit, accounting
for the known intentional receipt bypass in the isolated sensitivity copy.
The product-v1 → v2 manifest changes exactly:

- `lib/looper/cubit/tempo_cubit.dart`
- `lib/l10n/arb/app_en.arb`
- `lib/l10n/arb/app_es.arb`

The earlier independent integration pass also read App ownership/toasts,
PowerOff state/dialog/host/goodbye, SessionCubit/session mapping, LooperPage
injection, ClickVolumeSection and relevant test deltas. That pass did not run
the author tests. The root integration production code was unchanged for this
final delta except the neutral localization wording.

| Bound artifact | SHA-256 |
| --- | --- |
| Final `lib/looper/cubit/tempo_cubit.dart` | `9641371bd07d7c6319ff4762bd9698dfc275b46d797131211b09cabbae7a34d9` |
| `product-freeze-v2.json` | `67f1cbb391796f19bed56ffd308fa2b9c8700cf46128cc1ba207e75b20947ef5` |
| `click-v5-final05-binding.json` | `4f00f85a13fab18f1fec3e8e6b8298791b7cccea309508a33e933dbb01fb7e1e` |
| Retained `final-delta-review-v3.md` | `3add296347f67a403f7ff52b6f41cfc782da05f8281d6befd453381ff4427ccf` |
| Retained `root-integration-review-v2.md` | `b689e81f32f493b89d5ef673afcdd8d1643e0556edde22d2b5bdeb08c1c684e8` |

The base is `42e5e849ec21bc5cd6a6feae0251a96923556ba7`. The execution binding
records 1,297 unchanged files before/after. Retained report names identify
private evidence, not additional files bundled with this public translation.

## Recovery admission and lifetime

`TempoCubit._clickRecoveryPending` includes either local recovery or the
repository's Click start block. Ordinary/controller admission and the Session
exclusive gate check it before a new scalar read/write or deferred intent.
This closes the checkpoint-adoption read-failure gap. Both independently
predefined cases pass with zero attempted-edit scalar writes before explicit
Retry; the owner retains 0.5 and blocks restart until recovery.

`_recoverFailedClick` now retains the original transaction's lifetime unless
that transaction itself caused the stop. An unrelated global repository
recovery flag no longer makes old durable state own a replacement runtime.
Explicit Retry restores the old checkpoint first, then separately adopts any
current repository recovery and its confirmed gain. Adoption/read failure
remains recovery-required, and a fresh lifetime guard follows asynchronous
adoption before a corrective write or clearing the start block.

This addresses reproduced M311-A1: an old 0.25 preference and a replacement
1.25 session independently failed while an old store write was delayed.
Product v1 incorrectly restarted at 0.25 after recovery. The unchanged
independent case now restarts at 1.25. The earlier write-count fixture
correction did not change this expectation.

Target readout remains available intentionally: accepted holders must still
resolve for owed cleanup. Admission is blocked instead of hiding the target
and dropping its cleanup. The core post-enqueue callback wait is unchanged.
The prior negative control is explicitly product-v1 evidence, not a rerun on
this candidate; normal C1 passes in the final 55.

## Recovery copy

M311-COPY was a coordinator-proposed candidate independently verified against
its actual call path. App used one recovery body claiming audio had stopped.
A stale old scalar rollback failure may require recovery while the replacement
runtime must continue playing, so that claim was false.

The final English and Spanish text is neutral: “Retry to recover the Click
setting.” and its Spanish translation This corrects the message
without changing correct runtime lifetime behavior. Resolution is source
inspection, not a new rendered-localization test.

## Integration ownership and failure paths

The reviewed App composition owns one TempoCubit and supplies that instance to
ordinary controls, ControlCubit and Session callbacks. `BlocProvider.value`
avoids an extra provider-owned disposal. Control close finishes before Tempo
and Mix close. Presentation continues through owners rather than directly
using native or storage clients.

PowerOff no longer catches a flush failure and proceeds to halt. App cuts off
Control ingress and awaits retirement first; explicit Retry recovers Mixer and
Click, then drains retirement again so previously refused cleanup can settle.
Monitor/Looper/Mix/Click flushes precede halt. Failure returns `flushFailed`;
the flushing phase blocks duplicates, and Retry checks a fresh snapshot. The
global pointer barrier covers navigator content during flushing/saving/goodbye.
The second retirement drain has a concrete cleanup obligation, not merely a
second attempt at saving preferences.

Session save/load acquire Mixer then Click ownership. Durable Click capture
comes from the required owner callback rather than the live held value. The FX
pending barrier was traced with the Looper flush path; no new reverse
Click-to-Mixer lock acquisition was found in this integration delta. There
were no C/FFI symbol changes or new real-time callback work in this reviewed
root integration scope.

## Test-quality assessment and limits

Read-only assessment of the associated tests found meaningful assertions with
different evidence boundaries:

- App tests exercise actual provider composition, delayed scalar writes,
  rendered Retry and post-goodbye input cutoff. Their native-free fixtures
  prove composition/state, not callback receipt.
- PowerOff tests check delayed completion, flush/goodbye/halt order, refusal,
  duplicate requests, fresh gate, Keep playing and pending-close behavior.
  Constructor/signature plumbing is not counted as new behavior coverage.
- `test/session/click_persistence_test.dart` uses actual files and a real
  PumpedNativeEngine for Save/Save As and bounded recall without ControlCubit.
  It skips without `SEGNO_ENGINE_LIB`; ordinary CI is not proof of those native
  cases or the inherited full live-Control Session Load journey.
- `test/audio_setup/view/click_volume_section_test.dart` uses real
  LooperRepository/Tempo with a stopped FakeAudioEngine under widget time.
  Gain 0.5 → 50% and gain 2 → 200% verify accepted deferred intent and display,
  not audible publication.

No tests were run for the source-only integration pass. The separate final
55-case run is reported in [independent-execution.md](independent-execution.md).
This review supplies no hardware, screenshot, keyboard or screen-reader proof,
no exhaustive repeated-fault/navigation/disposal analysis, and no full
five-role gate. No extra unresolved concrete bug was found in this bounded
scope; the listed limits remain open evidence boundaries.
