<!-- cspell:words unassembled -->
# Test quality review — PCB completion #1072

Reviewed the current working-tree firmware, shared panel library, PD repository/codec additions and screen-power lifecycle helper and units on 2026-09-22. This is an independent software test-quality review; it does not replace the earlier PCB circuit/manufacturing review or assembled-hardware qualification.

## Observed validation

- `bash firmware/test/run_tests.sh`: all seven host suites pass; C/Dart wire contract checks all 54 binary fixtures.
- `python3 deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/test_screen_power.py`: all 11 tests pass.
- Scoped Flutter tests with coverage (`pedal_pd_status_test.dart`, `pedal_power_test.dart`, `pedal_repository_test.dart`, `pedal_link_header_test.dart`): all 44 tests pass.
- Scoped coverage: `pedal_pd_status.dart` 25/25 executable lines and `pedal_repository.dart` 139/139. Shared codec 86/163 because this run intentionally excludes unrelated codec tests; this is not a full-package coverage result.
- Implementation evidence records real Pico 2 and XIAO RP2350 builds. I inspected that evidence but did not redundantly compile both targets.

## Coverage and quality

The new ring framing tests exercise escaping, CRC corruption, truncated/oversize recovery, snapshot loss, duplicate messages, session changes, unreasonable deltas, counter wrap and timestamp wrap. The actual ring sketch is compiled into a host test for animation selection, goodbye, timeout, quadrature direction and short button pulses. The console test verifies 70-pixel grouping, bank mapping, brightness gradient and recovered ring events.

Presence tests explicitly model E9's held-high regression and verify production input-enable sequencing, pin independence and interrupt restoration. The model explicitly does not claim to prove analogue discharge timing. PD tests inject failures at each I2C transaction, short and negative reads, detach/contract change during observation, invalid registers/RDOs and timestamp wrap. They verify that the monitor never writes controller registers and does not invent voltage from a PDO index.

Dart uses the existing FakePedalLink seam, `fake_async`, `flutter_test` and Equatable conventions. It exercises compatible/incompatible hello gating, stale and duplicate status, changed firmware, disconnect, missing first observation, log wording, disposal and invalid wire states. No new UI or bloc unit is introduced.

The GPIO helper tests include real Unix socket exchanges and a child process running the actual daemon/signal handler, alongside GPIO fakes. They check initial-low selection, low-before-wait ordering, acknowledgement, failure cleanup, off-only reclamation and bounded EBUSY retry. Root is also running a real-systemd unit fixture; this review's host execution does not itself prove systemd ordering or target GPIO behaviour.

## Finding

### Important: exercise the console's actual state forwarding and host lease

Location: `firmware/test/test_console_panel.cpp:27–44`.

The test feeds `handleMessage()` directly, calls `renderIndicators()` directly, then writes `g_haveFrame = false` to simulate expiration. It never inspects a state packet produced by `sendRingState()`, and it never advances the actual console loop beyond `FRAME_TIMEOUT_MS`. The separate ring sketch test creates its own state packet. Consequently a regression in console-to-ring state forwarding or host timeout propagation can leave the new ring displaying stale activity while these tests remain green.

Feasible correction: enqueue a real host STATE on the FakeSerial receive side, run the console loop, decode the emitted `ringLink.sent` frame and assert the forwarded state. Advance past the five-second host lease, run the loop again and assert all 70 indicator pixels are dark and the emitted ring STATE has `goodbye` set. Include explicit goodbye and resumed host state to demonstrate recovery. This tests the new inter-board boundary through observable outputs without hardware or duplicated production logic.

## Physical limitations retained

Host tests and MCU compilation do not establish cable pinout, actual UART signal quality, encoder direction/detents, E9 analogue settling, screen discharge, buck/inrush/thermal margins or readiness of the unassembled boards. The user's HDMI-only darkness result is a separate passed observation. Production ordering and timing still need the assembled v3 hardware.

## Verdict

All executed tests pass. Fix the one Important integration-test gap before calling the software review complete; no verified production-code defect was found in this review pass.

## Resolved recheck — 2026-09-22

The integration-test finding is resolved. Independently inspected the revised `test_console_panel.cpp` and existing Arduino serial stub: a real receive queue now feeds STATE bytes into the production `pollLink()`/`loop()` path. The new case decodes actual console ring UART output and checks forwarded colour/gain, corrupt host traffic close to timeout, expiration clearing all 70 indicators and forwarding goodbye, and a subsequent valid frame restoring both outputs. The production paths are exercised without setting the internal lease state by hand.

Independently reran `bash firmware/test/run_tests.sh` after the change: all seven suites pass, including all 54 C/Dart fixtures. No unresolved findings remain. Software test quality is clean for the reviewed scope; the physical limitations above remain unchanged.

## Final GPIO interruption recheck — 2026-09-22

Independently reviewed the final re-enable interruption fix and reran the GPIO suite: all 12 tests pass. Before each pin transition the daemon now marks its settled state unknown; only successful completion of the low/discharge operation permits skipping final cleanup. Thus a SIGTERM during the ON settling wait after a previously completed OFF still drives GPIO low and waits before releasing ownership.

The added regression feeds OFF then ON through the production daemon loop, interrupts the ON wait with the same `SystemExit` raised by its signal handler, and checks the observable sequence: low, discharge wait, high, settling interruption, low, discharge wait, release. It does not mirror the new internal state assignment. No unresolved findings were introduced by this fix; final counts remain zero in all categories.
