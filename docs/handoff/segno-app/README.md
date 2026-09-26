# Segno implementation handoff

This pack captures the accepted redesign for implementation throughout the existing app. It replaces rereading the full design conversation. The current task prepares the handoff; it does not start production development or grant publication/deployment permission.

Use [IMPLEMENTATION_PROMPT.md](IMPLEMENTATION_PROMPT.md) as the next coding agent's task prompt. The owner confirmed Claude Fable 5.1; [prompting-basis.md](prompting-basis.md) records the official Anthropic sources and host-setting distinction.

| Read | Purpose |
| --- | --- |
| [Delivery checklist](delivery-checklist.md) | What is ready, observed verification and genuine limits. |
| [Accepted behavior](accepted-behavior.md) | The complete product contract, including later corrections and links to detailed records. Read once; revisit the active domain. |
| [Implementation map](implementation-map.md) | Existing Flutter/native seams, material gaps and seven ordered vertical slices. |
| [Reference gates](reference-gates.md) | Exact effect parity still requires evidence; different sounds are allowed. |
| [Transfer manifest](transfer-manifest.json) | Exact design/context files and hashes. Git HEAD alone does not contain the untracked prototype. |

The first implementation slice is the four-track main view and selected-track second display, connected to existing recording/overdub/playback, bank state and primary ownership. Then complete each dependent product task end to end. Existing production functionality is substantial; replace its old surfaces and extend its domain behavior instead of building another app beside it.

## Source hierarchy

Later owner-approved decisions and the accepted contract define behavior. The current HTML prototype and accepted Pen sections demonstrate it. Dated records explain detail and provenance. Older proposals, superseded Pen layouts and early roadmap suggestions are historical context. Current native code is implementation evidence, never a feature ceiling.

Prototype: `docs/design/fx-ux-prototype.html`. Serve `docs/design` locally and open the root page for normal Tracks startup; query scenes are demonstrations. The adjacent modules, artwork, fonts, audio examples and tests are part of the reference. `stage-two-screen-preview.html` shows display roles. Walkthroughs live under `completion-previews`, `recovery-expansion-previews` and related flow directories. They demonstrate browser behavior, not production audio or hardware.

## Transfer

For an agent in this same workspace, use the prompt directly after verifying the manifest. For another checkout, first bring the repository to the manifest's base revision, then copy the listed design/context files **and the manifest itself**, preserving their relative paths. The manifest is intentionally excluded from its own hash list. The native `.pen` file is copied as an opaque design artifact and inspected with Pen. The manifest deliberately excludes unrelated dirty application changes; the recipient must inspect and reconcile its own checkout rather than assuming this pack represents a clean production branch.

Run `python3 docs/handoff/segno-app/verify_handoff.py` to check hashes and local document links. A mismatch means the source changed after this snapshot; inspect it and refresh the manifest intentionally. Do not overwrite newer work blindly. This is a design transfer manifest, not a backup of arbitrary working-tree changes or a replacement for Git.

No further instrument UX decision is needed. Exact unresolved FX schemas, production implementation, content delivery and physical-appliance verification remain explicitly separate in the linked records.
