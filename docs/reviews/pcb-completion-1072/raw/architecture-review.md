# Architecture Review

Date: 2026-09-22. Scope: the screen-power keeper, systemd integration and Yocto
recipe; console v3 and XIAO ring firmware; shared panel/protocol library; and
the new PD status model, codec and repository behavior. This is an independent
software architecture review of the working revision. It does not review the
reviewer's earlier relay/component edits or certify the physical boards.

## Layer Separation

- Violations found: 0.
- `pedal_repository` retains its existing data/link seam. The immutable PD
  observation and wire codec import no presentation, Flutter UI or bloc code.
  The repository owns freshness, connection gating, logging and stream disposal.
- Firmware owns physical I/O and reports observations. The PD helper reads
  STUSB4500 status without changing PDOs/NVM or inventing an automatic cutoff.
  Unknown accepted voltage remains zero on the wire and `null` in Dart.
- The Pi's screen-power owner remains an appliance service. It does not place
  hardware access or shutdown policy in a Flutter widget or repository.
- Shared protocol/rendering code resides in `firmware/libraries/SegnoPanel`;
  both MCU targets build against the same canonical pedal codec.

## State Management Assessment

### Screen lifecycle — correct in the reviewed revision

The keeper locates the Pi 5 RP1 controller by label and requests the named
GPIO17 initially low. The console circuit connects that Pi header line through
J25; it is distinct from the Pico's GP17 UART input. No conflicting GPIO17
assignment was found in the appliance configuration. The implementation owner
also confirmed the RP1 label against the actual Pi without changing its state.

Weston binds to the keeper and starts after it. Screen power is acknowledged
only after the power-on wait, before Weston starts. Existing app ordering causes
the app to stop before Weston's synchronous power-off hook. A completed off
request is acknowledged only after the discharge wait. Normal termination drives
low before releasing the GPIO; ON never bypasses the keeper.

The initial version had a verified keeper-SIGKILL ordering gap: Weston's off
command failed while the keeper's separate cleanup was still discharging the
screens. The implementation now uses an OFF-only reclaim path. It retries GPIO
ownership only for bounded EBUSY, initially acquires the line low, holds it for
the discharge interval, and propagates other errors. The reviewed fault fixture
shows both exclusive owners finishing their low interval before Weston stops.
This finding is resolved, not an outstanding issue.

The final root audit also caught interruption while re-enabling after a completed
OFF: the previous `enabled=False` could survive until the ON wait ended and
incorrectly suppress cleanup. The targeted recheck confirms the revised daemon
invalidates its completed-state marker before every GPIO transition. Only an OFF
whose full wait completed can now skip cleanup. A deterministic production-loop
test interrupts the later ON wait and observes low, the full discharge wait and
ownership release. This issue is resolved in the helper revision fingerprinted
below; firmware sources were unchanged by this follow-up.

The 5-second discharge and 1-second startup waits are provisional constants,
not measured panel requirements. Software sequence validation does not establish
their electrical adequacy.

### Console/ring ownership and recovery — correct

- Console owns the latest host state, forwards canonical state every 100 ms and
  clears indicators on goodbye or its existing 5-second host timeout.
- Ring owns local pixels and encoder sampling. It starts dark and blanks after
  500 ms without valid console state. Periodic repaint also restores pixels
  after a separate LED supply interruption.
- SLIP framing has a bounded buffer and CRC-16 validation. Truncated, malformed
  and oversized packets resynchronize at the next frame boundary. Decoders use
  payloads before the parser buffer can be reused.
- Cumulative detents and button-edge counts recover missing snapshots; duplicate
  snapshots are idempotent. Unsigned wrap, reboot nonce changes, the 500 ms lease
  and implausible jumps are handled without replaying offline turns. The button
  is released when the link expires. Its lack of a new looper action is an
  explicit product decision, not an omitted input decoder.
- Actual XIAO aliases and console net assignments agree with the firmware. PIO1
  LED output uses DMA so the 70-pixel chain does not mask UART/encoder interrupts.
  ISR/shared encoder counters have bounded interrupt exclusion at main-loop
  sampling and snapshot reads.
- Physical CTRL contact presence owns unplug detection. The removed analog
  top-rail heuristic can no longer mistake a fast full-toe move for unplugging.
  E9 sampling preserves caller interrupt state and leaves the input buffer off
  between samples; physical validation on the assembled hardware remains needed.

### PD observation lifecycle — correct

The helper waits through startup/attachment settling, bounds individual Wire
transactions, and rechecks attachment, VBUS/policy state and unchanged RDO before
publishing a contract. Failure, detach, incoherence and stale status clear prior
electrical values. Current is a negotiated request, not measured consumption.

The repository trusts PD reports only after a compatible hello, separately
expires PD observations after three seconds, refreshes duplicate-report freshness
without repeated events/logs, and cancels its timer and closes the stream on
disposal. Firmware changes and link loss invalidate the prior observation.
All exposed observation fields are immutable.

## Dependency Direction

- Direction violations: 0; no introduced cycle or reverse layer dependency.
- The shared firmware library is below both sketches. The PD helper uses the
  already installed core Wire API; it does not add a configuration-writing
  vendor library.
- Main CI and appliance release use the same pinned MCU core and LED libraries,
  include the shared library explicitly, and compile both actual targets.
  Ring UF2 installation is documented separately from the console SWD updater.
- The existing pinned meta-openembedded revision contains the
  [python3-gpiod 2.3.0 recipe](https://github.com/openembedded/meta-openembedded/blob/07330a98cf93806b7a4e0170a541b94962ff3960/meta-python/recipes-devtools/python/python3-gpiod_2.3.0.bb),
  which declares libgpiod >=2.1 and its Python dependencies. The pinned Poky
  [Python manifest](https://github.com/yoctoproject/poky/blob/d0b46a6624ec9c61c47270745dd0b2d5abbe6ac1/meta/recipes-devtools/python/python3/python3-manifest.json)
  places `glob` in core and `socket` in I/O. The added runtime dependencies cover
  those helper imports. A full Yocto image build was not performed by this review.

## Package Structure

- `pedal_repository`: complete existing package, narrow added observation model,
  codec and repository behavior, project lint configuration and behavioral tests.
- `SegnoPanel`: bounded shared firmware library; one canonical codec rather than
  divergent per-board copies. Host tests exercise the production sketches.
- Appliance service: helper, unit, Weston drop-in, recipe installation and tests
  are present; the keeper is dependency-started rather than independently enabled.

## Validation Evidence

Independently executed for this review:

- `bash firmware/test/run_tests.sh`: all seven suites passed, including 54
  cross-language fixtures, production sketch behavior, ring loss/wrap recovery,
  presence sequencing and PD fault handling.
- Focused PD model/repository Flutter tests: 13 passed.
- Screen helper host tests: 12 passed after targeted recheck, including real
  Unix-socket processing, daemon termination, interruption during re-enable,
  OFF-only fallback, bounded busy retry and GPIO error paths.
- `git diff --check`: clean.

Inspected implementation-owner evidence, distinguished from reviewer execution:

- Real systemd integration with production helper/units/drop-in, an exclusive
  simulated RP1 request and shortened 0.05-second waits passed orderly stop,
  restart and keeper SIGKILL. Recorded orderly sequence was app stop → GPIO low
  → low wait complete → Weston stop. The fault sequence had cleanup acquisition,
  completed low wait/release, fallback acquisition, completed low wait/release,
  then Weston stop. This proves ordering in the fixture, not physical discharge.
- Final Pico 2 build: 71,056 program bytes and 11,168 RAM bytes. Final XIAO build:
  63,968 program bytes and 10,808 RAM bytes. These compile the reviewed sources.
- PD author reports all 228 package tests, analyzer, actual 30-file bloc lint and
  98.2055% line coverage passing; behavioral conclusions above also received the
  independent focused test execution.

Key reviewed source SHA-256 values:

| Source | SHA-256 |
| --- | --- |
| screen-power helper | `0fdc717299a16c29383a65f20e20400abe4444ecbe7ea98791fc67b0e8eb876c` |
| keeper service | `a0d5af275bb563ad59d58c101567883b24f9e892e36ab801b3cc5a640c671d17` |
| Weston drop-in | `b6a852214ac9c707d3c4d62b4a4a25853192f8dfd30684aea9bb9ebb22753a73` |
| console sketch | `79f4a39125fb0c8bba543c7e2c8380ced00bcbfe6c7e0886eb262df65e681a66` |
| ring sketch | `cb4e3ddfc2507bc047f65d126aa3e72e568a989eee395325daec872f3aca8050` |
| ring link | `f91504b9b61a14345d8327b77fc4edbb4606f2c51ee80281016fc6b82f78dc2b` |
| PD helper | `65716a99130de6fddfab3ca4a6299165c5d90a7126b237c959e56bb132f2baa6` |
| PD repository | `f30e3ca02ecaf10d34738eb3da3da4700f8a30d434fb7131664a81996e2e08c3` |

## Verdict

Architecture is clean in the reviewed software revision: 0 unresolved Critical,
0 Important and 0 Suggestion findings. Authors confirmed firmware and PD behavior
sources were stable before this report; remaining documentation edits do not
change that review scope.

This is not fabrication or device-release approval. No v3 hardware was flashed
or exercised during this review. Actual GPIO-to-screen timing, startup current,
USB cable pinout, hot operation, encoder direction, harness order and UART/LED
behavior still need the established physical acceptance checks. The owner's
HDMI-only darkness observation is useful evidence but does not substitute for
those checks or qualify the provisional software delays.
