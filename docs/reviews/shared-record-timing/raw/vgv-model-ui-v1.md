# VGV conventions: model/UI

Base: `8749688c51912f808c3f36d4eb5bca665ede3ade`. Revision: the 21 exact working-tree hashes listed in `vgv-model-ui-v1.md`, verified before and after review with no drift. This is a bounded cross-author review of the model/UI producer and the new real-FFI snapshot test. The reviewer authored the runtime and does not certify that runtime here. One reviewer performed VGV, architecture, simplicity, and test-quality roles sequentially, using the complete corresponding workflow-agents role definitions; these are four perspectives, not four independent people.

Authority: repository AGENTS, build/tracking contract, and `docs/plan/2026-10-03-shared-record-timing.md`. No tests or product edits were performed during this review. Aggregate execution, coverage, native gates, current-head CI, saved design verification and final whole-change review are separate coordinator gates. No merge-ready claim is made.

## Result

No actionable findings in the bound scope. The Flutter/Bloc/Equatable monorepo conventions remain intact; no new dependency, linter override, data-client import in presentation, or compatibility parser was introduced.

The line-by-line changed-hunk review and caller traces cover strict default/track keys, fixed0..7 bounds, finite normalization, seven accepted choices, and capture-only edit locking. Timing has a separate typed target family using the existing enum and owner snapshot. Explicit Immediately remains distinct from inheritance. Null readiness suppresses new targets; saved rows preserve their target identity and authored values. Multi does not acquire the unrelated Record-length restriction.

Presentation watches the application-owned RecordTimingCubit and passes its nullable snapshot to the existing shared resolver/catalogue. New choices recheck current owner availability at the action callback, so an already-open picker cannot Add after readiness/capture changes. Endpoint callbacks alter draft state, not audio. External button creation uses the current accepted value for both endpoints; expression/MIDI retain0/1. Repair and Escape preserve raw authored endpoints.

Removed-invariant audit: existing tests were retained. Fixed transport fixture answers were replaced with coherent current timing/division answers; mock owner admission and readback agree. Required provider/constructor injection uses the same real timing owner. No native receipt claim is inferred from those UI mocks. Existing owned timers, subscriptions and providers retain explicit teardown patterns.

Tests exercise actual picker/save journeys, readouts, strict parsing, literal boundary choices, capture-disabled saved rows, Multi availability and exact repair/Escape endpoints. The two screenshot generators are author visual evidence, not CI behavioral coverage. The added FFI test uses a real native engine and deliberately interleaves publication between full and track reads.

Generic role heuristics about file length, single-implementation ports or handwritten fakes were not applied as blanket refactor demands: the project explicitly requires the AudioEngine seam and minimal, incremental changes. No unrelated refactor is warranted.

## Exact reviewed inputs

| Path | SHA-256 |
| --- | --- |
| `lib/control/binding/binding_labels.dart` | `8a562bf40bcbd22429f3801304dedfb3283cb0e2e1b2f6576a0604dfb94a6dc5` |
| `lib/control/binding/control_value_resolver.dart` | `12aa73c08ed54a73de2777257c69762158f0389a4ccf42220870c25379caa06d` |
| `lib/control/binding/control_value_target.dart` | `867ea1e9d8cd155ab6f184289ca9ed6a9d5080cbac1654c4b36e27147a13763f` |
| `lib/control/binding/expression_catalogue.dart` | `e0e2d0132d31fe37f9e014c1aa79c38009207ebc08fa41a0e39a6ba6d538029c` |
| `lib/control/view/control_value_readout.dart` | `88be8284848d489db215f5cb2388eced9d85dd5f005cdb841069cdac836dd744` |
| `lib/control/view/midi_controls/midi_control_cards.dart` | `d8c17b668063e351b326619b78bbe4f302adc0b392f3c0e4210737e3419a4220` |
| `lib/control/view/midi_controls/midi_controls_page.dart` | `aae76410b4cc0e779cdecfcf8f3716fbafa5a6c55c885ca36f84744d337508c5` |
| `lib/control/view/pedal_setup/expression_controls_panel.dart` | `81c5536aa90e3a8870696629ce3f8313bf94e639e8ce63ebf537392b75d42a01` |
| `lib/control/view/pedal_setup/external_controls_editor.dart` | `0968d16ee1b9ff8bac7a0be3b0f0abe51e6827accd5d165a7a938456b637f2ba` |
| `lib/control/view/pedal_setup/external_pedal_page.dart` | `499f8d489e13362972b85e88d8129e403f1c62ac928e8c1aa6cc79c4bd70f9bf` |
| `packages/segno_engine/test/record_timing_snapshot_test.dart` | `922e50e569ebdc3dece359c5d369ecee7950688440dc6dbf106b51900f73a07c` |
| `test/control/binding/binding_labels_test.dart` | `5b8f9e75c9919bd7d48564c589640377a97762223043b9af49fbe220483476c6` |
| `test/control/binding/control_value_resolver_test.dart` | `7e2b20de286eff506141e045b092798d63ad2dd75b7b3eadeffd77a2d6c80dbb` |
| `test/control/binding/control_value_target_test.dart` | `86a5e289fb30b13e2ddb3feb1b8f25f0cff123bb92470576c19cd09b867d9639` |
| `test/control/binding/expression_catalogue_test.dart` | `ab4cc3668ebdb63c0a8586dc507ea4fb2c1ab2ff31d811c2c7071395b85d3344` |
| `test/control/external_controls_page_test.dart` | `fac1dee7e302f1ba2bc330da471cec1b4004fc0284540ddcdd9dbec28536527e` |
| `test/control/external_expression_page_test.dart` | `b1ee4858330427ebac7f4fc6ac96d673c1e2ca6f280f73eb60cbd5a0e0b689b6` |
| `test/control/external_pedal_page_test.dart` | `466558f59a61d6c2a8df899158133b3336e1e7aebf5c7a46cdea5f8f2005d9d4` |
| `test/control/midi_controls_page_test.dart` | `3c6ed4e6c9f2a4fbba29002a235bf729006178f956ffbcd1f84cab4ef4144e92` |
| `test/screenshots/external_pedal_screenshots_test.dart` | `0795aba681915cc3e9f8cd8c6ec82a4b86a82f4fc972cfa8c8efc0965a42e668` |
| `test/screenshots/midi_controls_screenshots_test.dart` | `4899f8cc3090c02c1b4aab20449eb437e0a926caef3c1d2e19f1931661c2f2e9` |
