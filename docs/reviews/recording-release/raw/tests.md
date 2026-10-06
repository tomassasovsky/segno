# Segno Transfer release packaging — Test Quality Review

## Scope and revision

Reviewed **d8261ca22f67c91331c3a7c91ea615c3bcf22b40 → 158395fe2c6fa949276a8b821863e5f449def94a**, the complete eight-file packaging commit: Mac workflow, build and packaging scripts, installation text, release notes, README, progress and plan. Read applicable repository/build/test-review instructions. No implementation edits, GitHub mutations, appliance operations or installed-app interactions were performed.

`git diff --exit-code d8261ca2 -- apps/segno_transfer/Sources apps/segno_transfer/Tests` passes: this commit changes neither runtime source nor its existing tests. The original review was packaging-only. The lifecycle addendum below extends the scope to the subsequent streaming-quit cleanup correction and its regression test; it does not replace the separate reviewer's operating-system proof or the overall branch gate.

## Findings

**Critical: 0 | Important: 0 | Suggestion: 0.** No verified packaging bug or actionable test-quality gap remains in the scoped commit. Hosted CI is still required before publishing the approved tag.

## Validation and coverage

### Independent checks

- `bash -n` passes for `build-app.sh` and `package-app.sh`.
- **Nine actual-script rejection/version cases pass**, run from isolated fixture trees under `/tmp`, without changing the real app or repository. Driver: `/tmp/segno-release-package-negative-check.py`; results: `/tmp/segno-release-package-negative-check.log`.
- The generated real disk image passes independent `shasum -a 256 -c SHA256SUMS` and `hdiutil verify`.
- Runtime source/tests are unchanged; no redundant Swift, Python, Flutter, or engine suite was run for this packaging-only commit. Existing app validation consists of the previously completed 24 Swift and 14 Python tests, and the hosted Mac workflow retains those suites.

| Case | Actual behavior observed |
| --- | --- |
| Missing app bundle | Nonzero exit before packaging |
| Signed fixture modified after signing | Real `codesign` rejects the modified bundle |
| Validly signed Intel fixture | Architecture gate rejects `x86_64` |
| Validly signed Apple Silicon fixture with invalid version | Version-format gate rejects it |
| Disk-image creation fails | Script propagates exit 42 and removes staging |
| Disk-image verification fails | Script propagates exit 43 and removes staging |
| App version 0.1.0, tag `transfer-v0.1.0` | Exact workflow shell block succeeds |
| App version 0.1.0, tag `transfer-v0.2.0` | Exact workflow shell block rejects it |
| App version 0.1.0, tag `transfer-v0.1.0-extra` | Exact workflow shell block rejects it |

The architecture/version/signature cases use tiny real Mach-O app fixtures and the real macOS signature, architecture and plist tools. Only the external disk-image command is substituted in the two intentional command-failure cases; the script itself runs unchanged. All six packaging rejection/failure fixtures leave no checksum output and no staging directory. The three version cases execute the shell block extracted from the workflow rather than a separately reimplemented comparator.

These tests exercise observable failures and cleanup. They do not match script source text or require a new packaging/UI test framework. There is no meaningful Swift line-coverage percentage for this shell/distribution-only delta. No new untested Swift service, state unit or UI component is introduced. The CI packaging step itself exercises the successful build/package path on a clean hosted Mac.

### Local real-image evidence

Read the author's `/tmp/segno-release-local-dmg-verification.json`. It records the mounted image's app signature, exact binary/helper match with the build, matching installation/license contents, and `/Applications` shortcut. The image is 335,720 bytes, version 0.1.0, minimum macOS 14.0. SHA-256:

```text
dbf69508aab20a79868af5ab27f7f171c173c2aaab8828c2e310aa0303f15dc7
```

The author performed mount/content inspection; this reviewer independently checked the resulting image's checksum and structural verification without remounting it. This establishes the local artifact, not an unobserved hosted build or a first launch on another Mac.

## Workflow and failure-path review

The Mac job keeps existing Python, formatting and Swift checks before the build and package steps. Build verification now fails immediately if the freshly built app's signature is invalid. Recreating the app directory avoids carrying stale bundle contents into the next signed package; this removes stale output rather than retaining it as fallback behavior.

The standalone packaging script verifies its input signature, requires the intended architecture and numeric app version, stages the app and installation/license files privately, creates and verifies the compressed image, and only then writes its checksum. `set -euo pipefail` plus the exit trap prevents a failed staging/create/verify step from appearing successful. CI's normal success conditions stop artifact upload after a failed package step; the release job additionally requires the complete Mac job to pass.

Current official runner documentation identifies public-repository `macos-15` as arm64, matching the package gate. This was verified rather than assuming the older Intel runner mapping. [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Tag pushes are explicitly included and GitHub does not apply path filters to tag pushes, so the existing path filters do not suppress `transfer-v*` publication runs. Non-tag PR/master runs only package/upload validation artifacts; the publishing job's tag condition and `needs: mac-app` retain the release boundary. [Workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore).

The exact tag-to-app-version check precedes packaging on tag runs. Values pass through quoted environment variables rather than interpolated shell commands. The release job receives the artifact from the successful same-workflow Mac job, gets write permission only in that job, requires the remote tag to exist, and explicitly preserves the repository's existing latest-release designation. `--verify-tag` and `--latest=false` have those documented meanings. [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create).

The installation and release text accurately declares Apple Silicon, macOS 14+, local signing and absence of Apple notarization. Paid signing is not a missing requirement under the owner's approved free-distribution scope. The separate complete-download verification and streaming source-version/transport integrity behavior are unaffected.

## Remaining validation boundary

- The hosted PR job must still resolve its actions, run the real tests and produce its own image successfully on this committed source before a release tag is pushed.
- Tag publication itself was not triggered or simulated against GitHub. Its local version guard and dependency/permission structure were reviewed; actual uploaded assets must be checked after the authorized release run.
- The mounted local image/signature tests do not prove a new Mac's first-launch/Gatekeeper journey. The included instructions describe that separate user interaction.
- Overall source-clean status remains with the parent. The lifecycle correction and deterministic regression are reviewed in the addendum below; the separate real-process reproduction and hosted CI remain distinct evidence.

## Verdict

**Packaging test quality and scoped bug review are clear at 158395fe.** Local image validation plus nine targeted actual-script failure/version checks provide meaningful evidence for this small distribution layer. The hosted Mac job remains the next required release proof; no speculative new test framework is needed.


## Lifecycle correction addendum

Reviewed the subsequent working diff in `AppModel.swift`, `PreviewPlayer.swift`, `RemoteAudioLoader.swift`, `SegnoTransferApp.swift`, and `StreamingTests.swift` against packaging head **158395fe2c6fa949276a8b821863e5f449def94a**. Ordered path/NUL/bytes/NUL snapshot SHA-256: **4aaf50b0c7e1ee32ab17894e62ce6f40f3dcd1110b03265301f966eeba6b11dc**; per-file hashes: `/tmp/segno-release-shutdown-reviewed-source.json`. Packaging source is unchanged. Header spelling directives added by the other reviewer were preserved.

### Behavior and boundaries

Stopping a preview still cancels its reads promptly and resets player/UI state. Each stopped loader now contributes a cleanup task that retains the previous task and waits off the main actor until that loader's worker operations finish. This preserves cleanup for previously closed or replaced previews as well as the current one. The repository owns subprocess and temporary-file cleanup inside the read operation, so draining those operations precedes termination approval.

The app delegate keeps the existing busy-transfer confirmation/cancel flow, then waits for active model work, closes the preview through `finishForTermination`, and waits for all recorded cleanup before replying to the deferred termination request. A model-less app may still terminate immediately. The new wait does not block the main actor; queue completion does not require a worker to synchronously call back onto that actor. This review found no remaining verified lifecycle defect in that correction.

### Regression quality and stability

The new test starts two real AVFoundation preparations whose data-source reads are blocked. It closes both previews while their cleanup remains gated, begins shutdown waiting, and verifies neither cleanup nor shutdown has completed. It then releases the **newest** read first, waits for that read to finish, and requires shutdown to remain pending because the older preview is still gated. Only after releasing the older gate may shutdown complete. Final assertions compare completed reads with started reads for both sources.

This verifies the promised lifetime behavior, including forgotten older previews, instead of merely asserting that `stop()` was called. Synchronization uses locked counters and explicit semaphores, with bounded readiness waits and a fixture timeout so failed assertions can still clean up. Short settling waits let completion tasks run; the semantic ordering is controlled by the gates.

The initial version released both gates together and was insufficient: independently deleting only `await previous?.value` in an isolated `/tmp` copy still passed (`/tmp/segno-shutdown-test-mutation.log`). After the author changed the test to release the newest gate first, the same deliberate regression fails at the pending-shutdown assertion, line 119 (`/tmp/segno-shutdown-test-mutation-corrected.log`). This provides direct mutation evidence that the final test detects loss of earlier cleanup history. No repository implementation was edited by this reviewer.

### Results and limits

- Read `/tmp/segno-release-shutdown-tests.log`: **25 Swift tests passed**, zero failures, after the lifecycle implementation correction.
- Read `/tmp/segno-release-shutdown-regression.log`: **four Streaming tests passed**, zero failures, after strengthening the new test's gate ordering. No implementation changed between those runs.
- Independent mutation of the final regression: **expected failure** when earlier cleanup is dropped; the original weak regression had passed the same mutation.
- This adds one meaningful lifecycle regression to the existing test suite. No new UI testing framework or source-matching test is needed.
- AppKit termination-dialog interaction and actual SSH child/temp-file behavior are being checked separately by the delivery reviewer. The semaphore fixture proves the cleanup ordering contract but is not itself claimed as a real-process or native-quit test.

**Refreshed Test Quality verdict: Critical 0 / Important 0 / Suggestion 0.** The deterministic lifecycle regression is now meaningful and the inspected implementation satisfies it. Final branch acceptance still requires the parent to combine this result with the separate real-process evidence and CI on the eventual committed head.
