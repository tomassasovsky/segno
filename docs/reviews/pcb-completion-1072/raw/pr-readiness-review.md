# PR Readiness Review

Reviewed 22 September 2026 against the working tree on `codex/screen-power-board-1072` at HEAD `a2a6a1f4c2c404effc74af3a2268e596e724ca81`. This review covers the console/ring firmware completion, shared library, firmware tests, pedal protocol 6 repository changes, the new screen-power service/helper/tests, and affected CI and recipe packaging. It excludes earlier CAD/routing changes and unrelated existing hardware changes. The relay value change preserves routing and remains covered by the separate circuit/PCB audit.

## Formatting

- Clean: Dart formatter checked all 30 files under `packages/pedal_repository/lib` and `test`; none would change.
- `git diff --check` passed, including a final scoped check after documentation corrections.
- The repository has no configured C/C++ or Python formatter gate for this scope. Python syntax parsing passed for the helper and test module. Firmware is compiled with warnings treated as errors by the host suite.
- The actual CI spelling gate scans Markdown. The new completion Markdown passed spelling. An exploratory source-wide spelling check reports existing shell identifiers and Python/MCU API names; those are outside that gate and are not defects.

## Static analysis and executable checks

- Errors: 0. Warnings: 0. Infos: 0 from `dart analyze lib test packages/pedal_repository`.
- `bash firmware/test/run_tests.sh` passed: 54 C/Dart fixtures; console CTRL tests; E9 presence sequencing; PD monitoring and status codec; ring framing/recovery; console panel integration; ring sketch rendering/timeout/encoder integration.
- All 11 screen-power lifecycle tests passed.
- No actual Yocto image build or device flash was performed by this reviewer. Real MCU compilation and package/app tests were checked by the implementation team; they are separate evidence, not attributed to this reviewer's commands.

## Build and packaging inspection

- Both CI workflows install the pinned RP2350 core and LED dependencies, compile with the shared library search path, and target Pico 2 plus XIAO RP2350.
- The release firmware marker reads the canonical relocated protocol header. The console ELF is carried by the existing image recipe; the separate ring UF2 has an explicit upload artifact and documented manual installation method.
- The screen helper, service and Weston drop-in are all recipe source inputs, installed into the expected paths and included in package files. The GPIO service is intentionally dependency-started by Weston, without independent boot enablement.
- Runtime dependencies were checked against the pinned upstream sources: [Poky Python manifest](https://raw.githubusercontent.com/yoctoproject/poky/d0b46a6624ec9c61c47270745dd0b2d5abbe6ac1/meta/recipes-devtools/python/python3/python3-manifest.json) includes glob and signal in core and socket in I/O; [python3-gpiod recipe](https://raw.githubusercontent.com/openembedded/meta-openembedded/07330a98cf93806b7a4e0170a541b94962ff3960/meta-python/recipes-devtools/python/python3-gpiod_2.3.0.bb) exists at the pinned layer revision and declares its native library dependencies.
- The implementation preserves explicit physical qualification requirements rather than treating simulated GPIO/MCU I/O as an assembled-board pass.

## Debug artifacts

No new ad-hoc prints, unfinished-work markers, conflict markers, test skips, credentials or debug-only imports were found in production changes. The screen helper's stderr error message is operational failure logging. Existing checked-in RAUC public certificates are not private credentials.

## Commit hygiene

The 12 existing branch commits since the supplied base were inspected. Their descriptions identify the changes; the inherited merge from master is intentional context, not a new completion-work merge. The completion changes remain uncommitted; this report does not confer commit, push or merge approval. New shared firmware source, sketches, stubs and fixtures must be included when the implementation is committed. Existing generated CAD artifacts are intentional project deliverables and were not flagged.

## Issues resolved during review

- Active references to the removed console-local protocol header were corrected by the coordinator.
- The console README originally linked an ignored local PD/presence audit. The coordinator copied the durable report to `docs/reviews/pcb-completion-1072/pd-presence-completion.md` and relinked it. Both the destination and updated link were verified.

## Auto-fixable

None outstanding.

## Verdict

No actionable PR-readiness findings remain in the reviewed software scope. Ready for the next CI/code-review gate, not a production-order or device-release sign-off. Full image build and assembled-hardware acceptance remain explicitly open.
