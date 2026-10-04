# Recording-start Part 1: architecture, simplicity, and UI verification

Review basis: `505fbcad19303b78396035c807409ee5a706f132` and the [approved Part 1 plan](../../plan/2026-10-03-feat-count-in-part-1-plan.md). One reviewer applied the architecture and simplicity roles sequentially to other authors' runtime, Settings, Looper, Tempo, App, and Session changes. This is a source review, not a claim of two independent reviewers or a complete current-head merge gate. The reviewer also added the three UI regression-test deltas discussed below; those authored tests are not self-certified by the source review.

## Architecture and simplicity

No actionable finding was found in the bound source. The [app model](../../../lib/looper/model/record_start.dart) validates the Count-in/Sound pair; lower [Settings](../../../packages/settings_repository/lib/src/settings_repository.dart) and [Looper](../../../packages/looper_repository/lib/src/looper_repository.dart) packages exchange named primitives or structural records without importing the app model. Settings serializes complete pair writes and reads back exact key membership. [Tempo](../../../lib/looper/cubit/tempo_cubit.dart) owns ordinary edits and their durable rollback through its existing queue. [Session capture](../../../lib/session/cubit/session_cubit.dart) reads durable intent under that same gate, while [Session mapping](../../../lib/session/session_mapping.dart) writes the pair into the existing file format. The Looper repository settles one native receipt and fences fresh recording acquisition before FX preparation. [App bootstrap](../../../lib/app/audio_bootstrap.dart) validates the stored pair before opening audio; [App](../../../lib/app/view/app.dart) presents typed failure and recovery outcomes without becoming a second writer.

The implementation removes the obsolete scalar writers and RecordOptions mirror. It reuses the existing Settings barrier, Tempo queue, and Looper receipt pattern. The live and restart-intent getters currently return the same confirmed pair, but name two required uses of that intent; removing either would obscure the Part 1 ownership contract. This review found no concrete compatibility layer, extra package, or general-purpose transaction framework to remove. Native callback safety, full behavior, CI, and the eventual PR-head review have separate gates.

## Cross-author fixture delta

The [audio-routing](../../../test/looper/view/audio_routing/audio_routing_test.dart) and [FX-page](../../../test/looper/view/fx/fx_page_test.dart) fixtures add the repository's coherent stopped pair and readiness/failure signals. They do not claim to test recording-start edits. The [Click dispatch regression](../../../test/control/click_dispatch_test.dart) now asserts the distinct F1/F3 outcomes: exact Click-volume compensation leaves the value owner healthy, while a refused MIDI or External held release remains owed by Control and blocks retirement until retry. Its assertions check the typed cleanup debt and audible value before and after retry. Tracing [Tempo's owner](../../../lib/looper/cubit/tempo_cubit.dart) and [Control's retirement path](../../../lib/control/cubit/control_midi.dart) found no actionable mismatch in these three fixture deltas.

## UI test evidence

New cases in [Loop settings](../../../test/looper/view/loop_settings/loop_settings_test.dart), [Audio settings](../../../test/audio_setup/view/audio_settings_section_test.dart), and [Audio console](../../../test/audio_setup/view/audio_faces_test.dart) cover an unconfirmed choice, retained selection through pending/recovery, capture lock, and refusal to issue a setter from disabled controls. The fixture drives owner state changes; it does not force a ready UI value. The Console and Audio settings cases check the retained Sound choice independently of the Loop pages.

The first serial six-suite run produced **235 passes and two failures**, both in the new Audio settings tests. A Looper-state tick entered RecordOptions with an unstubbed length capture flag. The test fixture was repaired to supply that flag from the same capture state; the affected Audio settings suite then passed **22/22**. A first green repair run still warned that two disabled-control taps were outside the test viewport; the final run scrolled the controls into view and passed 22/22 without tap warnings. The other five suites had passed unchanged in the serial run. The three final UI test files passed scoped fatal-info analysis and explicit formatting. These combined results do not substitute for a final full aggregate run on the frozen source.

Author-only screen captures covered Recording Pedal/Off, Sound On, recovery and lock, plus Tempo Count-in Off and two bars. They were inspected for selection, readable disabled reasons, and clipping at the intended screen size. These captures are visual review evidence, not CI golden proof or appliance validation.

## Source binding

SHA-256 of the reviewed runtime and fixture paths, followed by the final UI tests:

| Path | SHA-256 |
| --- | --- |
| `lib/looper/model/record_start.dart` | `4bff579132f2cb5fad671739ab925254563467723066d2e2ceea1ca37ada6294` |
| `lib/looper/cubit/tempo_cubit.dart` | `530d9809b88c0d07234ad63145e87e4525e3fc2ccbb7c7c197d79a202bf3c90b` |
| `packages/settings_repository/lib/src/settings_repository.dart` | `14240d470e089804fbda1e57ebf9fa1faf5cf7eb700c277109fcc9ff0efe3581` |
| `packages/looper_repository/lib/src/looper_repository.dart` | `84c1dbf37ca6bef641ca7323af20f89d6e6361b6b9b4b4888a9c33032eda5cae` |
| `lib/session/cubit/session_cubit.dart` | `d510167b2d0161cd4a14599f70dd8f5242ab3cabc153b0d9fbeb382fd4efe199` |
| `lib/session/session_mapping.dart` | `6bb0ea60f2dbc4e133da02749c74a44645f10f590f725bf5edfead8fa31b0923` |
| `lib/app/audio_bootstrap.dart` | `a6324a66dbefd3ab5e58cf25e457955e56c565d405a57626c07b4a97e978da8c` |
| `lib/app/view/app.dart` | `8c1553c85d130a11643763efc78847235545106bd400f59a99dcac79b3e36f88` |
| `test/looper/view/audio_routing/audio_routing_test.dart` | `c2f6f47c51d9b1fe171b4bc7b45d0f90bb8d2296d95d159f9bf5dc76fa695a7a` |
| `test/looper/view/fx/fx_page_test.dart` | `32902dd8644cc19282a6bf806cae6eff21812f379665d407fee4328560ad37e3` |
| `test/control/click_dispatch_test.dart` | `b235c61b27efc137c556a01f23cd4496f6f159f60ca62e33ba31f67812b6209a` |
| `test/audio_setup/view/audio_faces_test.dart` | `eeee63e1f9a218cd2c0232901a61e034c3db7961baef8b064d15e681d6048807` |
| `test/audio_setup/view/audio_settings_section_test.dart` | `a95770f4ddd32f4de2f11c0afe97edea97470edbf34acac4f9a2d3396a994f76` |
| `test/looper/view/loop_settings/loop_settings_test.dart` | `e7ca905614c4093cec8f93484164fb6165a1d9fea89183864a94edc6280d456d` |

Unrelated FX edits, macOS files, and controller analysis-options changes were outside this review. A changed source hash invalidates the affected conclusion until rebound.
