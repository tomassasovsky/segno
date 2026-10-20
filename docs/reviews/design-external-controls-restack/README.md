# External pedals: complete setup and dispatch

Both CTRL jacks now offer Single, Dual and Expression through one setup page.
Each profile retains its own assignments. Switches support independent actions,
several effect activations and parameter values; expression supports several
heel/toe ranges and directed calibration. Missing targets remain visible for
repair. Draft edits do not affect saved configuration before confirmed Save.

The console UART route remains authoritative. The obsolete generic console
editor and calibration store are removed, while the separate MIDI route remains
available for its next slice. Contact edges, source absence, session changes and
refused writes share one dispatch owner. Accepted source state is distinct from
confirmed persisted state; failed storage remains visible and retryable.

## Evidence

The frozen 100-path candidate is in [source.json](source.json), based on
`63607bdba8e5a41359c83b45087204bec9ca1a2b`. Source hashes include new files,
deletions, firmware, goldens and the saved Pen. Public review documents are
additional evidence, not changes to the tested code.

- [Verification](verification.md): 2,467 app tests and five affected package
  suites pass; all required coverage floors pass, with no input drift.
- [Independent adversarial review](adversarial-review.md): 54 probes pass,
  including three failures reproduced before repair with unchanged assertions.
- [Source review](source-review.md) and the five quality-role reports: no
  unresolved actionable finding. One independent reviewer covered those five
  perspectives; a separate adversary performed behavioral execution.
- [Bug-focused gate](../../code-review/design-external-controls-restack/review.md).

Eleven External and nine parent-page author goldens pass. The native app was
checked after restart: independent Track 5/6 assignments survived, and Cancel
restored the saved Dual configuration after an Expression draft. Pen contains
12 matching native render references in its grouped External section; its save
and file hash were verified. Full older-canvas reconciliation remains M7 work.

Published-head CI is a separate readiness gate. This is not physical hardware
validation: contact bounce, electrical calibration, latency and no-presence-jack
unplug ambiguity remain bench checks. Nothing was flashed, deployed or merged.
