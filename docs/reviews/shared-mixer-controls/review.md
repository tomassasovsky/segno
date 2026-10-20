# Shared Mixer controls: consolidated review

Base: `06633b2b537efba4c59108e38764e58c0b2c542e`.
Reviewed revision: the 56 files in [source.json](source.json), fingerprint
`4f84e5257a79f854588a263055cf236c0c684f28f1f794cf13fc566646c77f45`.
No unresolved actionable finding remains in this bounded slice. Local
aggregate, coverage and static gates pass. Current published-head CI and
human merge are separate gates.

## Review coverage

The model/UI author reviewed the separately authored runtime and persistence
changes. The runtime author reviewed the model/UI under five separate
perspectives: conventions, architecture, test quality, simplicity and
readiness. These are cross-author reviews, not five different reviewers.
The coordinator reviewed integration, removed invariants and native renders.
A separate adversarial reviewer wrote and executed the behavioral probes.

The final runtime repair, late label/screenshot changes and twelve fixture
corrections received separate cross-author delta reviews. The bounded source
records are preserved in [raw](raw/). They found no further actionable defect.
They do not replace the full local gates or current-head CI.

## Repair record

| ID | Finding | Resolution and evidence |
| --- | --- | --- |
| M310-1 | A linked pair could be offered without its right input. | Catalogue and admission require both current inputs; missing-input cases cover the pair. |
| M310-2 | An older ordinary or retained contribution could outlive a newer accepted hold. | Accepted new intent retires the old baseline; before/during-hold ordering cases pass. |
| M310-3 | A missing External target could reject its valid sibling's Released projection. | Project only admitted numeric targets; the valid sibling remains operable. |
| M310-4 | Meter updates enumerated every effect parameter. | Topology checks enumerate only Mixer targets from one state snapshot. |
| M310-5 | Cancelling endpoint editing left the parent draft changed. | Cancel restores the parent value; real-page regressions preserve Save/Cancel behavior. |
| M310-6 | Unrelated topology changes cancelled queued track/effect work. | Per-target generations invalidate only affected owners; hostile queue cases pass. |
| M310-7 | New non-held MIDI input became audible while an older External Released value remained saved. | Only actual cleanup inherits a surviving Released value. The unchanged independent regression passes after failing previously. |
| M310-8 | Lane labels began at zero and monitor names repeated. | Display numbering is one-based and destination/row labels are distinct; identities are unchanged. |

The final independent run passed 52 of 52 unchanged probes. Its earlier run
passed 51 and exposed M310-7. An isolated negative control replacing the
logarithmic gain law with a linear law failed the literal expected-value
probe. Earlier fixture/launcher failures remain in the evidence record and
are not counted as product failures or successful sensitivity checks.

## Limits carried forward

A separate real session-load reproduction encounters an EMPTY track carrying
a nonzero length while the live control owner is present. The same harness
fails on the parent revision, so it remains an M5 session-publication defect.
This slice proves session-file capture of Released values, not that broader
load journey. Physical controller delivery, real interface replacement and
appliance shutdown still need hardware validation.

An unrelated uncommitted analyzer configuration change and five unrelated
raw review files are outside this slice and must not be staged with it.
