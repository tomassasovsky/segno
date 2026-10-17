# PR Readiness Review

## Scope and toolchain

Reviewed the 40-pixel full-white PCB delta after
`f8d6f889ba51bf1a8cb5e29b6f00fd852465ee2d`, including authored Python/shell,
current assembly/power documentation, native boards and final fabrication
archives. The repository is a Flutter/native application with a separate
Python/KiCad hardware toolchain; no Dart or firmware source changed in this
increment. Generated CAD and CAM files are intentional deliverables here.

## Formatting

- `git diff --check`: pass.
- No Python formatter, Python linter or shell formatter is configured for this
  hardware subtree or its CI workflow. No unrelated formatting convention was
  imposed.
- Changed Python sources retain the surrounding style and compile successfully.
  Both changed shell recipes pass `bash -n`.

## Static analysis and spelling

- Six changed/new Python files compile without execution or emitted cache files.
- Both changed routing scripts pass the shell syntax check.
- Native DRC and critical-path/fabrication checks pass as recorded in the
  separate test-quality report.
- The CI spelling job uses `.github/cspell.json`, includes Markdown, checks all
  matching files, and uses the VGV reusable workflow. The review used CSpell 9
  and the same dictionary configuration on changed/new Markdown, including
  review documents; this is not a claim that unrelated baseline Markdown was
  revalidated.
- The actual PR title passes the workflow's CSpell 9 title command.

Final changed/new Markdown spelling passes with the CI dictionary configuration.
The legitimate technical words in the historical fabrication note use a scoped
dictionary; the new thermal wording and other review-document spelling issues
were corrected during review. Errors: **0**. Warnings: **0**. No hardware Python
or shell linter is configured, so syntax checks are not represented as such a
linter run.

## Debug artifacts and accidental changes

No new secrets, private machine details, unresolved merge markers, test skips,
debugger imports, unfinished-work markers or temporary debug output were found.
Command-line progress and self-test messages are operational output of the
hardware tools. They are not production application debug prints.

An executable-AST comparison with the review base confirmed that
`console_board.py` and `ring_board.py` change only comments/documentation.
The console placement changes are the intended helper import, exclusions for
power routing, critical-route installation and final fabrication guard. The
exporter now stops on a failed DRC. The ring script installs the supply before
routing and rejects all reported violations/unconnected items before export.
The wider-branch preservation change is limited to the intended grow-only
condition plus its behavioral regression test.

The stale 24-pixel/1.44 A connector paragraph in `segno_wiring.md` was reported
and corrected during this review. Current documentation distinguishes the
2.64 A ring input design budget from normal firmware appearance and the
9.408 A whole-system planning case. Unrestricted white across all 120 LEDs
plus both screens remains outside the 10 A AUX budget. Historical v2 limits
and alternative 24/16-pixel module ratings remain clearly scoped.

## Manufacturing artifact hygiene

The final source manifest's twelve hashes match the corresponding files. All
three ZIP hashes match `manufacturing-zips.json`; all archives pass integrity
checks, contain the expected member counts and match every listed member hash:

| Archive | Members | SHA-256 |
| --- | ---: | --- |
| Console v3 | 12 | `88960bd4d96e7f06e7c9a60fb59f99a8735a10ec35e0865b3b64e40c7efab2eb` |
| White ring carrier | 10 | `d27aff2c3694b6c0f48cedd2f0bf6e9b38093dabef02558c775b456732f006ef` |
| Screen power Rev I, unchanged | 12 | `25370578cbb1184f6d2bc1913c88746ff87ce91809779c7878d62f4af735a878` |

Every console/ring member also matches the tracked loose manufacturing file
byte-for-byte. The separate independent hardware review regenerated these
exports from the final native boards and recorded parity after normalizing
creation timestamps only in `raw/independent-artifact-parity.json`. This
readiness review checked the manifests and member bytes independently; it does
not substitute an archive filename for source correspondence.

`verification.md` was reviewed against the source/native hashes, current
geometry and test evidence. Its current calculations, board specifications,
archive hashes, firmware separation and whole-system limits agree with the
reviewed records. Native visual checks are author-provided evidence, distinct
from this mechanical review.

The September 25 desktop order packet was also inspected. Its three renamed
upload ZIPs match the repository archives byte-for-byte, and their checksums,
integrity and complete member maps match the packet's `verification.json`.
The upload names in `ORDER.md` match those files. Dimensions, finishes, layer
count, copper, board colour and wire gauges agree with the publication document.
The prior September 24 order note redirects to this newer packet.

## Commit and PR hygiene

The existing PR contains five descriptive Conventional Commit subjects, with
no temporary or meaningless commit messages. This incremental review began
before the next commit; the parent owns the final commit and current-head
review continuity. SHA-256 manifests identify the reviewed working contents.

The PCB archives and native files follow this repository's existing hardware
publication pattern and are explicitly authorized deliverables. They are not
unexpected application build outputs. Python cache files are ignored. Incidental
KiCad project metadata and temporary DRC reports are excluded from the intended
publication file set.

PR #1080 targets `feat/console-board-5v-1062`. The main application workflow
only targets `master`, so its absence on this stacked PR is not a passing CI
result. The existing `ci:pending` and `autonomy:blocked-verify` boundaries remain
accurate; local checks do not authorize a merge or an assembled-hardware claim.

## Auto-fixable items

None outstanding in the reviewed final file set.

## Verdict

Mechanically ready for publication with no unresolved PR-readiness findings.
This is a readiness review of the recorded file set, not a merge authorization;
current-head review, CI status and the established physical-validation gate
remain separate requirements.
