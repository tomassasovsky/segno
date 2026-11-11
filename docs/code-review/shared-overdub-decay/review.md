# Bug-focused gate: shared overdub decay

Base `8b740c093b7ae84fb36c19fac88914246d6278b3`; reviewed working revision is
bound by `docs/reviews/shared-overdub-decay/source.json`, fingerprint
`014a8e7cbb7887233d60c2b99c7725b7ae4b539b09f9793e0e104cbdb61a8780`.
This includes new untracked implementation and tests. The final commit must
contain these identical blobs; documentation and saved Pen are separately
bound. No unrelated local analyzer change belongs to the gate.

All eight review angles are complete: changed product hunks and enclosing
functions, removed direct write paths, Control-to-owner-to-storage/native
traces, reuse of existing parameter/ledger machinery, simplification, queued
work and real-time boundaries, root-cause fix depth, and repository/VGV
conventions. The independent reviewer read all changed tests and final fixture
deltas. The coordinator reproduced startup replay and stale storage failures,
reviewed those fixes and inspected actual UI and saved design references.

No unresolved actionable finding remains. The resolved findings are recorded
in the consolidated review; failed attempts were preserved. Final local gates:
2,617 ordinary app results, three affected package suites, 51 independent
probes, a reached-PCM negative control, eight native session cases, standard
native suites, 723-file strict static checks and three author-only renders.
Counts overlap where noted and are not summed into one claim.

This is a clean local bug review for these blobs. Published-head CI, platform
build/sanitizer jobs and human merge approval remain separate. Physical
controllers, appliance timing and OS halt were not exercised. The inherited
live-Control Session Load defect remains M5 work; successful Save and owner
adoption do not constitute full recall proof. The independent matrix's omitted
permutations are explicit in its execution report.
