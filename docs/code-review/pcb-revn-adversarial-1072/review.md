<!-- cspell:words DeepSeek GPIO Schurter revn -->
# Bug-focused review: Revision N adversarial closeout

28 September 2026. **Bug-focused review complete: no unresolved actionable finding.** The publication delta is clean, the unchanged implementation evidence remains applicable, and the requested multi-model review is complete following Claude's successful console continuation. This is acceptance of the identified bare-board manufacturing data. Current-head CI remains a separate unmet merge condition.

## Target and identity

PR #1080, issue #1072. Base hardware head: `44edd9483518768506533a3b6fe30e85d6d530c4`. Reviewed the complete subsequent publication delta: the 17-file documentation commit `34257020a3529b93cc73abb432f17d35551949ba`, followed by the successful console verdict and its final working-tree publication updates. Scope includes corrected manufacturing/wiring/programming guidance, external review summaries and provenance, production/documentation audit reports, progress and prior-review pointers, and manufacturing-manifest status. No circuit, BOM, native PCB or Gerber ZIP changed.

The existing implementation and native/CAM evidence carries forward explicitly through the [previous bug gate](../pcb-stock-cost-1072/review.md). This pass does not claim another full line-by-line review of the older implementation. The [production audit](../../reviews/pcb-revn-adversarial-1072/production-coverage.md) independently rechecked current native/archive identities, critical footprints/net maps, purchasing coverage, fuse access and the enclosure envelope. The [documentation review](../../reviews/pcb-revn-adversarial-1072/documentation-review.md) pins the three corrected assembly documents by content hash.

| Final publication input | Reviewed SHA-256 |
| --- | --- |
| `docs/PROGRESS.md` | `f7c40e04c94e2eccbde2b230bc3bb94464b407b2befa15505337d711499b24a7` |
| `hardware/MANUFACTURING.md` | `f4403c9c65f744dfb4ab05dbfe2c153129fa82b727276b5bb2103e53b89ca680` |
| `hardware/segno_wiring.md` | `8117501d22a3b277b09fd95df3f1e07ebe515b9f74f9458ada20971abe3afd38` |
| `hardware/kicad/RING_ASSEMBLY.md` | `7df6cb52127c84b71e57e936288cf55edd3b3cae60cd032b5d84bf9729b5a53b` |
| `docs/reviews/screen-power-stock-cost-1072/review.md` | `268170fb867812fa09c0295e00aaee43ed16f1f66eb13d77ebbb08e752900177` |
| `docs/reviews/pcb-revn-adversarial-1072/review.md` | `821192b5404878adf24f543c1fae1beda80efed448fc2975622e8b23cd6b6b03` |
| `docs/reviews/pcb-revn-adversarial-1072/claude-console.md` | `14bede68665fd44115cef2b2273c43fbed790c70f3f8d3230e98f33a7747223c` |
| `docs/reviews/pcb-finish-all-three-1072/manufacturing-zips.json` | `a2c65dfea97d40d0633107504b0d2dcd4064b92a83932656d50f2d80d24f7cd0` |

Publication must preserve these reviewed identities and record the resulting commit. Delivery synchronization is a publishing operation, not something proved by reading the repository manifest.

## Completed review angles

- Read every changed hunk and new report, including their surrounding assembly instructions and explicit limitations. Traced the guidance to the current Rev N fuse/relay topology, main/USB cable allocations, power budget and source-isolation contract. Recomputed current and power arithmetic independently.
- Removed guidance is replaced by the current protection boundary, not silently dropped: F1 is onboard, all board loads are downstream, and the incoming pair/J1-to-F1 section remains explicitly unprotected. The removed negative gate driver is no longer treated as a low-voltage guarantee. Manufacturing no longer selects an obsolete PCB against the current parts list.
- Followed programming order across manufacturing and ring assembly guides. AUX and the separately fed strip stay off while XIAO USB is attached; USB is removed before J1 returns and AUX is restored. Console USB isolation precautions remain intact.
- Read the Claude screen/ring and all three DeepSeek summaries against actual final responses and tool-result records. Independently matched all eight DeepSeek run prompt, response and event hashes to retained private artifacts. Claude screen result records confirm successful 27-turn and 12-turn passes; ring confirms a successful 27-turn pass, all with `is_error: false`. The first console attempt returned `is_error: true` after two turns and no verdict; that historical failure was not counted as approval. Its later continuation returned process exit 0, `subtype: success`, `is_error: false`, six turns and an explicit final acceptance verdict. The retained final response SHA-256 is `7ff2422898842b91dbd8423ba6ee692a5655500aa6eb127bc0f5a8f88a5c35a4`; it matches the manifest and actual result text.
- Checked that the public summaries correct rather than repeat raw model errors: pickup is not a guaranteed holding threshold; the selected MOSFET uses its 4 V on-resistance maximum; TVS stress uses clamp rather than breakdown voltage; the actual AHCT input specification replaces a generic input-clamp assumption; and thermal-spoke arithmetic is not presented as a temperature simulation. Screen-terminal voltage remains a conditional stacked-loss sensitivity.
- Checked ring coverage against the actual result: fresh native fill/refill/CAM/DRC inspection is distinguished from source-identity-based reuse of earlier circuit/encoder/XIAO evidence. Its unsuccessful exploratory verifier parser is not represented as a newly passed verifier run. The console report accurately retains earlier full-review evidence after proving identity continuity, and now records its actual successful current closeout. Independently reproduced its production-path comparison: the only change since `60ff3a637a400deb1ce846f6cb76979c94250a32` is the old DRC date line. Its actual tool calls read the three assembly-document diffs and the current screen enable circuit; that scope matches the public report. Checked R1/R2, Q1/Q2, R7 and Q5 connections directly: the released-GPIO default-off chain is supported under the stated input assumptions, and a powered software halt still requires GPIO17 low or released.
- Independently compared current/previous manufacturing manifests. All three archive objects, per-member hashes, native identities, order settings and existing verifier entries are unchanged. The aggregate-review and console-report hashes resolve exactly; the console result hash matches retained raw evidence. `bare-board-review-clean` and the completed status agree with the actual verdict, current manufacturing link, prior-review follow-up and progress entry. Historical interrupted/clean verdicts remain explicitly bounded to their original scope. Existing evidence and physical limitations are not promoted to newly performed tests.
- Evaluated reuse, simplicity, fix depth and repository conventions. The delta reuses existing design evidence, records new actual verdicts, and fixes active instructions without changing hardware. No executable behavior, real-time path, interface, dependency or test implementation changed; allocation, threading and performance regressions are not applicable to this prose-only delta.

## Findings and closure

The production audit's two active-document findings are fixed: the wrong screen archive and obsolete inline-fuse/gate-driver/power-budget instructions. The ring programming precaution is propagated. No unresolved actionable defect remains in the documentation/publication delta reviewed here.

The initially missing required Claude console verdict was a review-completeness blocker rather than an established circuit defect. Its successful six-turn continuation closes that blocker with no new actionable finding. Together with the completed Claude screen/ring, all three DeepSeek passes, production audit and retained implementation bug gate, the requested review is complete within the explicit coverage boundaries.

## Verification and limits

Scoped whitespace checks and local documentation-file links pass. Current native/archive/member hashes were independently recomputed during this pass and match the retained manufacturing record. Existing electrical, DRC/ERC, source fault-control and CAM results are reused on unchanged production identities; this report does not claim those unchanged suites were freshly rerun.

The design review cannot certify actual USB compliance, screen startup/discharge, capacitive relay endurance, closed-enclosure temperature, hand assembly or cable construction. Those documented bounds remain visible. No pre-PCB prototype is requested. Enclosure mounts and runtime installation remain separate integration work.

The final bare-board review hold can be lifted after publishing these exact reviewed files and binding the resulting commit and delivery identities. This report supports `review:clean` for that bound head; it does not support `ready-to-merge` until CI is observed green on the same head. Ordering, merging, flashing and deployment have not been performed or newly authorized by this review. Delivery refresh and the final committed-head bind remain publication steps, separate from this completed review of their source records.
