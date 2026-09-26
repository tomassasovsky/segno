# Design handoff technical review

September 9, 2026. Independent review of another author's accepted-behavior contract and the coordinator's bounded design-reference refresh. No production implementation, Pen edits or findings fixes were made by this reviewer.

## Scope and result

Reviewed:

- `docs/handoff/segno-app/accepted-behavior.md`
- `docs/design/export_handoff_geometry.cjs`
- `docs/design/verify_handoff_display.cjs`
- The two added `.stage-feedback` rules in `docs/design/stage-display-study.css`

**No unresolved actionable findings on the reviewed revision.** One minor test-quality finding was corrected by the coordinator and independently rechecked. No demonstrated product defect or accepted-contract contradiction remains. Do not count this report as independent review of `implementation-map.md` or `reference-gates.md`, which this reviewer authored. It is not a native audio, hardware, deployment or final Pen-save review.

## Resolved DH-TECH-01 — require populated meters before testing their widths

Priority: P3. File: `docs/design/verify_handoff_display.cjs`, lines 16–17.

The original whole-track-meter check collected `.stage-meter` elements, filtered away missing or zero-width fills, then called `every`. If a regression removed every meter or fill, the filtered array was empty and `every` still passed. The test consequently reported “whole-track meter” success while the required content was absent.

The coordinator added explicit assertions for four meter surfaces and a visible fill in the populated fixture before comparing widths. The revised script independently passes in Chrome and Firefox. This addresses the reported vacuous-success case without broadening the UI change.

## Architecture and conventions

The accepted contract consistently treats latest owner decisions as product authority and prototype tests as interaction evidence rather than production proof. It preserves the existing repository/Bloc/native boundary and forbids copying the accumulated JavaScript architecture or maintaining a second application. It separates musical session state from physical device state, and stable controller identity from current editor selection.

Cross-checks covered the accepted completion/timing records, crown, stage roles, instrument closure, loop settings, optional controls, audio-device recovery, Fade and Speed records, plus the source-gate inventory. The document correctly supersedes older “recover in Free” and no-tail drafts, retains the first-completed-take crown, whole-track meter, independent instruments and current 239/300/26 reference limits. Older records still containing proposal language are appropriately identified rather than silently treated as newer requirements. No specific contradiction was established.

The geometry exporter uses the existing geometry adapter and read-only review fixtures, closes its browser in `finally`, and writes only the four intended reference outputs. It does not change application storage or native runtime. The small-screen capture preserves its dedicated 1280 × 720 geometry; the main references are 1920 × 1080. Existing output directories are present in the handoff. The fixed local server is consistent with this repository's author-side preview utilities.

## Tests and observed behavior

Independently ran `verify_handoff_display.cjs` before and after DH-TECH-01 was corrected: Chrome and Firefox both passed the revised checks for crown ownership, selected-display crown, explicit meter presence, whole-width measurement and recovery feedback.

Also exercised the actual clock-loss fixture through the view menu in **Track, Wave and Mixer**, in both browsers. The entire “Clock lost · Captured audio kept” text remained within its feedback box vertically and horizontally, and each box stayed inside its track/meter/wave container. This additionally checks the shared CSS rule in layouts not covered by the submitted clock-loss assertion. The cue remains noninteractive and inherits the existing centered positioning.

Inspected generated geometry: main Track, Wave and Mixer roots have 1920 × 1080 dimensions, and the selected-track root has 1280 × 720 dimensions. The exporter was not rerun during this review because its artifacts were being used by the active Pen refresh. Final native Pen alignment and on-disk save evidence remain the coordinator's separate verification responsibility.

## Simplicity and readiness

The two CSS rules repair the reproduced overflow without new application state, popup variants or runtime logic. They constrain width, allow normal wrapping and reduce only the recovery cue's heading size. The scripts reuse existing browser and geometry dependencies. No new abstraction or compatibility path is warranted.

No broader code change is requested by this review. Production acceptance still requires the platform evidence stated in the handoff; no amount of browser or Pen verification closes native or hardware gates.

## Reviewed revision

SHA-256 values bind this report to the locally reviewed files, which are not yet represented by a committed handoff revision:

| File | SHA-256 |
| --- | --- |
| `accepted-behavior.md` | `82212525e35f4785ec67767fef1d3d647a7b6aa08db7ca8ab311eeb4eeb156a8` |
| `export_handoff_geometry.cjs` | `433260fadae6f88cde0e72e19251b09d377dc54600147947bb6b189b7e711efc` |
| `verify_handoff_display.cjs` | `7035877a0e498c8536ab54184cc47b5a8edea751ee100a04ccf1a44431bfff15` |
| `stage-display-study.css` | `856252127dc821994fd420453860d408b0944d5cc4a486e7552dff8b51ff0cf6` |

## Transfer appendix

Additional narrow review of `docs/handoff/segno-app/verify_handoff.py` and the README's Transfer instructions. This does not extend the independent review to this reviewer's own implementation/reference documents.

**DH-TRANSFER-01 (P2): copy the manifest separately.** `transfer-manifest.json` is deliberately excluded from its own `files` array, avoiding recursive self-hashing. The README initially instructs another checkout to copy the listed files only. Following that instruction literally does not copy the manifest, so the recipient cannot run the verifier. Explicitly transfer `transfer-manifest.json` alongside every listed file; self-hashing is not required. No transfer or implementation files were changed by this reviewer.

Verified observations:

- `Path(__file__).resolve().parents[3]` correctly resolves the repository from the committed `docs/handoff/segno-app/` location, independent of the working directory.
- Verify mode is read-only. Only explicit `--write` replaces the local manifest; it does not copy or overwrite application/design files. The README cautions against blind overwrites and distinguishes excluded dirty production changes from the supplied design snapshot.
- Ran the current verifier successfully: **2,452 file hashes and handoff Markdown links passed**. Its success claim is appropriately limited to those checks, not native behavior, Pen parity, a clean checkout or Git-base equality.
- A static scan of existing local `src`, `href` and CSS `url()` dependencies under `docs/design` found no existing referenced files omitted from the manifest. This is a static dependency check, not a claim to resolve every dynamically generated URL or external source reference. The whole design directory is included.
- The recipient must still check out the recorded base revision and reconcile newer local edits before copying. The script does not enforce Git revision or implement a transfer, and the README does not claim it does.

After clarifying the manifest-copy instruction, regenerate the final snapshot because this appendix and any final evidence updates change listed hashes.

**DH-TRANSFER-01 resolved.** Independently re-read the coordinator's revised README: it explicitly requires the listed design/context files **and the manifest itself**, preserves relative paths, and explains the self-hash exclusion. Reviewed README SHA-256: `64bd4e4300e5b5cea8e002be13a89cd1a50cb95f08b8ba2076f35743b6cb76da`. No unresolved transfer finding remains. The coordinator's final manifest regeneration and verification follow this saved appendix; the earlier 2,452-file pass is not represented as a pass of that not-yet-regenerated snapshot.
