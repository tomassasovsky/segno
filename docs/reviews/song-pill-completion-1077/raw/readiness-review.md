# PR readiness review — Song completion on the current console

Reviewed 24 September 2026 in the `codex/live-ten-pills` working tree at HEAD
`bedcecf2`, preserving the earlier uncommitted firmware 1.9 work for #1076.
Scope is the approved #1077 Song queue/completion path, protocol 7, native
snapshot extension and 40-pixel ring on the existing v2 PCB. The separate v3
PCB implementation was excluded.

## Formatting and analysis

- After dependency resolution, all 19 changed Dart files passed formatter
  check mode without changes. The updated integration test was checked again.
- `git diff --check` passed.
- The first analyzer attempt ran before dependencies were resolved and produced
  invalid missing-package errors. It was discarded, then rerun against the
  root app/tests and pedal, engine and looper packages.
- The initial fresh analyzer found no errors or warnings and one info: a new
  integration test comment exceeded 80 characters. The coordinator wrapped it;
  the source correction and final clean analyzer log were verified.
- Changed firmware README and the new plan passed the repository Markdown
  spelling check. There is no configured C/C++ formatter gate for these sources.

## Build and deployment contract

- The physical mapping remains the current board's GP12 ring, GP13/14/15
  encoder, GP16/17 Pi link, GP18 pill chain, GP2–11 switches and existing CTRL
  inputs. No v3 PIO ring-link mapping was imported.
- Firmware advertises version 1.10 and protocol 7. Both C and Dart use a
  21-byte STATE payload, with the queue fields appended at offsets 19 and 20.
  The release job derives its firmware marker from those exact source values.
- Both workflows install the required LED libraries. The production target
  remains Pico 2; the standalone pill diagnostic remains a separate target.
- The generated native snapshot tail matches the C declaration: signed
  32-bit queue target followed by floating-point progress. The regeneration
  log identifies this checkout's current header. Its opaque-type warnings are
  expected for engine handles, not incomplete generation.
- Deployment must replace the app and native library as one matched bundle,
  alongside firmware 1.10 and its marker. The existing ARM64 producer compiles
  both bundle halves together and runs its FFI symbol check. That symbol check
  alone cannot establish struct-layout compatibility; using the matched build
  is essential for this snapshot ABI extension.
- The coordinator reports the four firmware host suites passing with 49
  fixtures and the Pico build passing at 66,132 bytes program / 10,668 bytes
  RAM. Native normal, sanitizer, telemetry-disabled and C++ checks were reported
  on byte-identical native source. This reviewer did not rerun those builds.
- Current integration/package/application checks and the matched ARM64 build
  are the coordinator's separate gates. This report does not turn an earlier
  fixture failure or tests still in progress into a passing result.

## Recovery

The plan explicitly requires clearing all 40 pixels before downgrading to
firmware 1.9, which addresses only 24 ring pixels. The checked golden goodbye
fixture is 25 wire bytes containing a 21-byte STATE payload (length byte 0x15).
It must be delivered while firmware 1.10 still runs, before restoring the old
app/native bundle, firmware and version marker. The fixture's goodbye flag
selects the actual sketch's all-pixel clear path.

No device operation or deployment/recovery script was executed by this
reviewer. The prepared procedure was subsequently inspected as recorded below;
source readiness is not a successful device update or a physical appearance
check.

## Debug artifacts and commit hygiene

No new ad-hoc production printing, secrets, conflict markers, unfinished-code
markers or test skips were identified in the intended diff. The existing
platform-specific UART test skip and diagnostic firmware are intentional.
Generated FFI bindings and tiny binary protocol fixtures are required source
artifacts. Ordinary build output remains ignored. No new task commit exists,
so commit-message, hosted CI and PR-head merge gates remain pending.

## Resolved documentation

The active UART inspection example was corrected from its old protocol-2
HELLO to protocol 7 / firmware 1.10, including the correct checksum. Historical
bring-up observations were preserved.

## Review boundary

No PCB changes, firmware flashes, app deployment, commit or release was
performed by this review. The current-limit arithmetic is documented as a
planning estimate, not a measured electrical rating.

## Final verification update

The comment-length finding is resolved. The coordinator's final analyzer log
reports no issues. The targeted real-native Song pipeline integration passed,
and the complete real-native control corpus passed all 25 tests. The integration
exposed two snapshot fields missing from the test adapter; the adapter now
forwards the queue target and progress. These results replace the earlier
in-progress fixture failure noted above.

## Verdict

No outstanding source-readiness or prepared-deployment findings. Device staging,
loader verification, programming, app startup and physical behavior remain
execution gates. No device update is claimed by this review.

## Prepared deployment review

The final prepared package was inspected read-only. All 14 upload-manifest
hashes passed. All 34 files inside the app archive matched the separate app
manifest exactly, and the app executable permission was retained. The goodbye
packet exactly matched the tested protocol-7 golden fixture. All shell scripts
passed syntax checks and all Python helpers parsed successfully.

The staging script checks the installed 1.9 firmware and original app identity,
retains the original firmware and version marker, verifies the new bundle and
requires an atomic same-filesystem directory exchange. It checks the Pi's actual
loader against the staged executable and every bundled shared library before
stopping or replacing the live app.

The update stops the UART-owning app, flashes with a bounded timeout, checks
an exact protocol-7 firmware-1.10 HELLO, exchanges whole app directories and
installs the corresponding firmware artifact and marker. It verifies hashes,
then checks the new app invocation's connection, active state and restart count.
Its fatal-log check is scoped to that invocation, so earlier successful starts
cannot satisfy validation or contribute historical errors.

Failure recovery preserves the original app directory, sends the 21-byte
payload goodbye before downgrading, restores the old matched app and firmware,
verifies the old HELLO and checks the restored app invocation. The independent
recovery service first waits for the update unit to stop; it cannot start its
own flash concurrently with the update trap. The prepared unit settings use
control-group termination, oneshot update units with 120-second start/stop
allowances, recovery after 300 seconds with one-second timer accuracy, and a
oneshot recovery unit with 360-second start and 120-second stop allowances. Successful
installation disarms recovery only after fresh app verification succeeds.

The coordinator reports the final matched ARM64 build and 146-symbol parity
check passed. This review establishes package consistency and procedure
readiness, not that staging or any device mutation has already succeeded.

## Narrow startup-verifier follow-up

The first device attempt reached firmware 1.10 and a successful audio start,
then the original generic exception check triggered rollback. The coordinator
verified restoration of the original whole app, firmware 1.9, hashes and active
service without restarts. These are deployment observations reported by the
coordinator, not device actions performed by this reviewer.

The observed error is also present in both the historical accepted 1.9 startup
and the newly restored original app: recording recovery attempts a
38,381,030,944-byte read through `PerformanceRepository._readRawPcm` and
`_finalize`. The unrelated defect remains open as
[#1078](https://github.com/tomassasovsky/segno/issues/1078). Recordings were not
modified to work around it.

The revised verifier was inspected and tested independently. It pins the
historic log's SHA-256 before use, normalizes only ISO timestamp prefixes and
recognizes the complete contiguous 40-line block: the exact allocation,
PlatformDispatcher error, exception text and both complete 18-frame stacks.
At most one exact occurrence is accepted. Any changed or additional failure
outside that block remains a verification failure. A fresh successful audio
start, expected firmware connection, unchanged invocation, active service and
zero restarts remain mandatory.

All 14 supplied tests passed. Independent mutation probes modified or removed
each of the 40 signature lines and added five other failures; all 85 cases were
rejected. The exact historical, attempted and restored logs were accepted. All
16 entries in the regenerated upload manifest passed their hash checks. Shell
syntax also passed. No actionable finding remains in this verifier delta.
Accepting this exact baseline fault does not resolve it or establish that
recording recovery works; it only distinguishes it from new deployment errors.
