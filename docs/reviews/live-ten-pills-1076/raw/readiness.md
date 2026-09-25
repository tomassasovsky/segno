<!-- cspell:words Werror -->
# PR readiness review — live ten-pill firmware

## Scope

Reviewed the incremental firmware 1.7-to-1.8 change against the preserved
baseline, including the 80-pixel sketch, tests, dependency-install workflow
changes, documentation and prepared device-update/recovery procedure. This is
an Arduino C++/C firmware change; no Dart application source changed. The new
NeoPixelBus stub and workflow library lines were implemented by this reviewer,
so these checks do not constitute an independent review of those edits.

Final reviewed sketch SHA-256:
`a09c54e38bf3a1c965c0f3d47d293d443ce74c932fdbc9f72b15d03127885485`.
Compiled/staged firmware ELF SHA-256:
`595fb6c73b34af6006ff22c4ad12607cdce8dd16fcd716a8e47d19e5905bec41`.

## Formatting

- `git diff --check`: clean.
- No repository C/C++ formatter configuration applies to these firmware files.
  Existing local formatting conventions are retained.
- Both changed workflow files parse successfully as YAML.
- Prepared update and recovery shell scripts pass syntax checks; the two
  small UART helpers pass Python syntax parsing.

## Static analysis and tests

Observed `bash firmware/test/run_tests.sh` passing with `-Wall -Wextra -Werror`:

- Pedal-link contract: 45 fixtures passed.
- Actual console sketch CTRL behavior: passed.
- Ten-pill behavior: real frames, all 80 pixels, both banks, modes, button
  acknowledgements, proportional current limiting and link loss passed.
- Existing one-pill bench firmware behavior: passed.

The parent reported the real Pico 2 target compilation passing with 66,004
bytes of program and 10,668 bytes of RAM. The compiled ELF and the staged ELF
have identical SHA-256 hashes. Host tests establish renderer and protocol
behavior; the hardware build establishes the real library API compiles.
Neither result establishes physical live-operation behavior.

## Debug artifacts

- No new production debug prints, temporary feature flags, unfinished-code
  markers, merge-conflict markers, secrets or test skips were identified.
- Diagnostic output in host tests and the inherited standalone bench sketch
  is intentional test infrastructure, not enabled in production firmware.
- The protocol codec and the existing CTRL, encoder and ring implementations
  remain unchanged from the firmware 1.7 baseline.

## Device-update mechanics

Reviewed the prepared update and recovery scripts without executing them.

- The update validates both the incoming ELF hash and the installed firmware
  1.7 hash before flashing, stops the app's UART owner, verifies the SWD write
  and observes an exact protocol-5 firmware-1.8 HELLO before installation.
- The ELF and version marker are installed together; both are checked before
  restarting the app. App reconnection is checked only within the new systemd
  invocation, so historical connection logs cannot satisfy the check.
- A failed update uses an exit trap to restore the retained firmware 1.7.
  Its original hash is verified. The recovery sends a goodbye frame while
  firmware 1.8 still owns all 80 LEDs, before downgrading to firmware 1.7's
  eight-pixel driver; that prevents the remaining 72 LEDs retaining a stale
  color after a normal rollback.
- The success flag is now set only after the restarted app passes its active
  check. A failure at that last check therefore still takes the recovery path.
- The separate timed recovery is armed by the coordinating task; this report
  checks its scripts, not whether its timer is currently active on the device.

## Commit hygiene

- No new task commits or PR exist at review time; commit-message and hosted-CI
  gates therefore remain pending rather than implicitly passing.
- Existing firmware 1.7 bench additions were inherited intentionally. Their
  test runner, Adafruit stub, bench sketch and bench tests match the preserved
  baseline byte for byte.
- Firmware build artifacts remain outside the source worktree. No new ELF,
  UF2, object file, credential or other temporary binary appears among the
  untracked source files. The repository ignores ordinary build directories.

## Resolved observations

Two observations were fixed by the coordinating task during review and
rechecked: the README now uses the actual Library Manager package name
`NeoPixelBus by Makuna@2.8.4`, and the update script marks success only after
checking the restarted app remains active.

## Verdict

The reviewed source and prepared deployment mechanics are ready for the
authorized device check. There are no unresolved mechanical findings. Live
pedal behavior, any future PR's CI and final commit review remain separate
gates; this report does not mark the change ready to merge.
