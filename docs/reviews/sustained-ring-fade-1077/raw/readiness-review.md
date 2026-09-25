<!-- cspell:words Werror -->

# PR readiness and device trial review

## Scope

Reviewed the sustained-fade delta against the saved firmware 1.10 baseline:
`firmware/console_board/console_board.ino`, its README, and
`firmware/test/test_console_pill.cpp`. Reviewed the verification record and the
private firmware-only deployment, recovery, HELLO, startup-log verification,
and launch scripts. Existing unrelated working changes were excluded.

This is an authorized local device trial, not a PR or hosted release. The
review did not operate the device, change production code, or judge the
physical appearance through the diffuser.

## Formatting

- Status: clean. The scoped tracked files pass `git diff --check`.
- No repository C/C++ formatter configuration applies to these files; the
  additions follow the existing sketch style.
- All six deployment shell files pass individual `sh -n` checks. Both Python
  helper sources parse successfully.

## Static analysis and validation

- Errors: 0. Warnings: 0. Infos: 0 in the independently rerun host builds.
- `bash firmware/test/run_tests.sh` passes all four suites, including 49 wire
  fixtures, with `-Wall -Wextra -Werror`.
- The strict startup-log verifier passes all 15 tests independently rerun.
- The reported Pico 2 build is 66,460 program bytes and 10,668 RAM bytes. The
  local built ELF and the staged new ELF independently hash to
  `0c0800e0d754d6dd82fec0702c3bc376dfe192122c23117b9e35d02e02d2ec0d`.
- The retained local 1.10 ELF independently hashes to
  `63d20797d41ccdcdc2f44b23b6fe645fe10e788a845027fa93ccaa03b1bd552c`.
- The historic startup-log baseline matches its pinned SHA-256. Only its exact
  complete historic OOM block may be recognized once; a changed allocation,
  changed stack, second occurrence, missing startup success, wrong firmware,
  or other detected error fails verification.

## Deployment and recovery

No actionable defects found in the reviewed path:

- The launch script verifies uploaded checksums and arms a separate systemd
  recovery timer at 180 seconds, with one-second timer accuracy. It verifies
  that timer is active before starting the updater; the updater checks again
  before mutation. The updater has a 120-second start timeout and a
  60-second stop timeout.
- The updater checks the retained 1.10 ELF and version marker, freshly checks
  the installed 1.10 pair, and verifies the existing complete app manifest.
  It changes only console firmware artifacts and their marker.
- SWD programming includes verification and reset. A separate UART check
  requires protocol 7 and firmware 1.11 before persisting the new ELF and
  marker for subsequent startup.
- The persisted artifact hash and version marker are checked again. The app
  manifest remains unchanged, and a fresh service invocation must report
  firmware 1.11 and successful audio startup, remain active, have zero
  restarts, and pass strict log verification.
- Failures after mutation invoke restoration of the retained 1.10 artifact
  and marker, verified SWD programming, HELLO 7/1.10, and fresh app startup
  verification. Failed recovery leaves the independent timer armed. Timer
  recovery stops the updater before running restoration.

The coordinator reports fresh installed-artifact and app-manifest checks are
already complete. Those are coordinator-observed device results; this review
independently inspected local artifacts and scripts. Flashing was still
pending at review time, so this report does not claim successful installation.

## Debug artifacts and commit hygiene

- New debug artifacts, unfinished markers, merge markers, and embedded secrets:
  0 found in the scoped change.
- Firmware build ELF and UF2 artifacts are ignored by Git.
- Commits reviewed: 0 for this trial; no new commit or PR is being prepared.
  The existing branch history and unrelated changes are outside this review.

## Auto-fixable

None.

## Verdict

Ready for the controlled firmware 1.11 device trial. No actionable readiness
or deployment findings. Successful flashing and the owner's appearance check
remain trial outcomes, not assumed evidence.
