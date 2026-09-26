# Screen U1/U2 alignment review

Base: `2c27234ecf7825d67c812584bc7b82e39455fa38`. Target: the complete
working-tree U1/U2 placement delta, regenerated native/placed boards, screen
manufacturing archive and associated evidence. Exact reviewed inputs are
identified by the [alignment record](../../reviews/screen-u2-alignment-1072/verification.md)
and [current archive manifest](../../reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
This scoped review does not cover every accumulated change in PR #1080.

No unresolved actionable finding remains in this delta. Independent reviewers
checked the circuit/pad contract and incident route connectivity; source/native
geometry, courtyard and body clearances, rounded routes and actual USB ground
reference; and release input/archive/delivery consistency. The coordinating
review inspected source hunks and existing placement/routing/export callers,
reviewed both local copper faces and the populated rendering, and checked
current-source fabrication validation.

The removed placement offsets have no electrical role. Original footprint
courtyards, component values, NC pads, USB paths, high-current routes, anchors
and all other parts remain intact. Local copper follows the same existing
critical-route generator; the newly exposed rear corner uses the existing
rounding helper. No new abstraction or alternative execution path was added.

The source comments were corrected before publication: C4/C5 supply legs gain
0.25 mm rather than shortening. Their topology and nearby placement remain.
Native DRC and ERC pass; all 56 fault controls pass. Independent fabrication
checks pass 409 screen and 175 console/ring assertions. Python compilation,
changed-document spelling and whitespace checks pass.

A complete automatic reroute was not run; critical-source replay and the
accepted saved native board were verified directly. Hardware operation and the
complete stacked-PR review/CI gates remain outside this bounded review. Retain
`review:pending`, `ci:pending` and `autonomy:blocked-verify`; this report grants
no merge or manufacturing-order authority.
