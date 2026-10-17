# VGV code review

## Summary

No actionable software findings in the reviewed completion changes. The implementation follows the project's thin firmware-client and repository boundaries, removes the obsolete console v2 ring wiring, keeps the shared wire codec canonical, and adds bounded failure handling for GPIO ownership and PD observations. This is a source review, not approval to manufacture or deploy: assembled-board timing, cable wiring, supply margin and actual screen discharge remain physical acceptance gates.

Reviewed on 2026-09-22 in the working tree based on `a2a6a1f4c2c404effc74af3a2268e596e724ca81`. No implementation files were edited by this reviewer.

## Scope and conventions

Read `AGENTS.md`, the build/test section of `docs/PROGRESS.md`, `docs/TRACKING.md`, Dart analysis options and the pedal repository dependency manifest. Reviewed:

- Console v3 and ring sketches, PD/presence helpers, and `firmware/libraries/SegnoPanel`.
- Pedal repository PD model, codec, message handling, freshness/disposal and their tests.
- Screen GPIO helper, systemd owner and Weston drop-in, Yocto packaging and host tests.
- Both affected CI workflows, firmware dependency/build commands and firmware test runner.

The project uses C/C++ Arduino firmware, Python/shell appliance helpers, and an immutable Dart repository model with Very Good Analysis. Flutter presentation/state-management changes are absent from this diff.

## Critical — must fix

None.

## Important — should fix

None.

## Suggestions

None retained. Minor naming or formatting preferences did not establish a concrete maintenance or behavior problem and are not release blockers.

## Regression and architecture assessment

- The moved C protocol is still used by the actual sketches and cross-language golden fixture tests. Dart's protocol revision and the release firmware marker point to the new canonical header.
- Console firmware remains a thin input/state bridge. Ring animation moved to the independent MCU without putting application behavior into firmware; input counter snapshots recover loss within the link lease and reset the baseline across reboot/disconnection.
- PIO/DMA LED output removes the old interrupt-blocking output path for the expanded 70-pixel indicator chain. Pin mapping and physical pill order are explicit.
- The PD status model is immutable and carries unavailable/stale states without old electrical values. Repository input is gated by compatible hello, duplicate observations refresh freshness without duplicate events, and the new timer and stream are disposed.
- PD read failures do not rewrite controller configuration or turn unknown voltage into a false measurement. Presence handling is isolated and retains input direction.
- The GPIO request stays owned by one service. Synchronous stop acknowledgment follows drive-low and discharge delay. Weston dependency ordering and cleanup cover normal stop and failed owner cases; physical discharge timing remains explicitly provisional.
- Test changes add coverage rather than weakening existing assertions. No UI-to-data-layer dependency or new state-management layer was introduced.

## Simplicity assessment

- Lines that could be removed without reducing behavior: no justified removal identified.
- Unnecessary abstractions: none identified. Shared wire/render primitives and the narrow pixel adapter have immediate consumers or a concrete hardware purpose.
- Speculative behavior: none identified. No automatic PD cutoff, trigger reconfiguration, or unrequested encoder-button application action was added.
- Complexity verdict: proportionate to the two-MCU and GPIO lifecycle requirements.

## Testing assessment

Independently reran the following against the inspected working tree:

- `bash firmware/test/run_tests.sh`: all seven suites passed, including 54 C/Dart golden fixtures, actual console/ring sketches with simulated I/O, CTRL behavior, E9 sequence, PD polling, ring framing/recovery, and console host-to-ring forwarding/expiry.
- `python3 deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/test_screen_power.py`: all 11 tests passed, including the live socket/signal process test.

The host-to-ring bridge and invalid-frame lease-expiry regression identified by the separate test reviewer is present and passed here; it is not an outstanding finding.

Parent-provided evidence additionally records real target builds, 228 Dart tests with 98.21% coverage, clean Dart analysis, and a live systemd container sequence test including SIGKILL. Those were not rerun by this reviewer and are not claimed as independent device validation.

New behavior has meaningful success/failure/lifecycle checks. Host GPIO and E9 mocks cannot prove physical pad settling, screen timing or electrical reliability. The current physical acceptance hold therefore remains appropriate.
