# MIDI architecture review

Base and current Git HEAD: `1ef7fb30abd328b86ac481ec71e72c9bbc59e83c`. This is a working-tree review; a later commit requires the coordinator to bind the resulting commit to these reviewed bytes. Exact intended-path hashes and scope are in [the source review](source-review.md#reviewed-file-binding).

One independent source reviewer performed the VGV, architecture, test-quality, simplicity and readiness roles sequentially. These are five review lenses, not five independent reviewers. No delegation, product edits, test execution or UI automation was performed by this reviewer. The coordinator and separate adversarial reviewer supplied execution evidence.

The local source and quality gate is **clean** for the exact 134-path manifest fingerprint `3cb49b9c0e522f35d7275b5b58a6a30095a4f8350c161796bb48f3806c2be705`. All eleven functional findings and the final future annotation are resolved; no actionable finding remains. Final app, package, native and static evidence passes. Published-head CI and final commit binding remain separate, pending gates. No ready-to-merge, merge or deployment claim is made.

## Layer and lifetime assessment

No new dependency-direction or direct presentation-to-data-client violation was found. The controller package models wire messages and opaque stable target keys; the application resolves targets and owns shared ordering. The MIDI client owns native callback lifetime, the device repository owns selection, and the Cubit owns mapping/editor dispatch lifetime.

One shared FX persistence projection and one mix coordinator are provided application-wide to Control, Monitor, Looper and Session owners. Projection does not reimplement arbitration. Native recipe receipts and pending-save tracking separate accepted audible state from durable Released state. Performance capture deliberately reads live state.

The repaired disposal path cancels and awaits confirmation work before Cubit closure and releases persistence barriers. Queued mix actions capture origin before waiting, and native capture epochs prevent callbacks from being relabeled after reconnect. No changed public C symbol or generated-binding mismatch was found. Native Program changes preserve real-time constraints.

Existing B1 captured-prior restoration is preserved, including refusal obligations. The shared-target catalogue is intentionally partial at this milestone; the remaining families and physical limits are recorded in the source review.
