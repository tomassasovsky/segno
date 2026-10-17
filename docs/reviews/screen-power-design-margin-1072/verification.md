<!-- cspell:words Mbps -->

# Screen-power design-margin review

25 September 2026. Follow-up to issue #1072 and PR #1080, based on
`009d6c9e29e81c7ec54dcbd83bea6c93f90a85c4`.

The owner requires one carefully planned PCB order and does not accept a
pre-PCB prototype build as a prerequisite. This review assesses improvements
within the existing through-hole, two-layer design and selected cable interfaces.
**No replacement power circuit was adopted or approved. Published Revision K
source, native boards and manufacturing archives are unchanged.** Earlier
first-prototype recommendations do not establish the requested one-batch result.

## Findings

- USB has no newly demonstrated circuit or routing fault. The large screen's
  upstream hub operates at 480 Mbps even though its touch controller is slower.
  Data-pair geometry and cable construction therefore matter. The seller's
  28 AWG description specifies conductor size, not differential impedance or
  high-speed performance. See the [USB assessment](usb-assessment.md).
- A bounded routing refinement extends the closely coupled data-pair sections
  without moving components, changing connectors or increasing route length.
  It passed a complete isolated rebuild, native ERC/DRC, connectivity and
  ground-reference checks, all 36 existing fault controls and package export.
  The [candidate patch](usb-routing-candidate.patch) is retained for the next
  revision; it is **not applied to the published board or order ZIP**.
- The current P-channel stage's specified low resistance requires 4.5 V of
  gate enhancement. Driver, fuse and wiring drops consume a material share of
  its margin on a nominal 5 V supply. This is separate from the USB question.
  A marginal calculated gate condition is not itself evidence of failure, but
  typical transistor curves cannot be presented as guaranteed limits.
- Several through-hole replacements improve one margin while leaving another
  unresolved: current-limit tolerance, hot leakage, inrush, reverse blocking,
  supply sequencing or procurement. The [alternatives](alternatives.md) and
  [provisional clamp calculations](clamp-calculations.md) record those limits.
  None is a validated replacement for Revision K.

## External reviews

The earlier completed Claude cloud review remains evidence for its original
Revision K scope. A follow-up architecture request was accepted, but the app
subsequently reported exhausted usage credits. No completed follow-up review
was obtained and no credits were purchased.

A new OpenCode Go DeepSeek attempt reviewed the proposed TN0702 / 22-ohm
driver change. It produced no response for more than 13 minutes and was
terminated. This is an incomplete attempt, not a clean review or a reported
circuit finding. Neither external attempt validates the later clamp proposal.

Independent circuit and USB reviewers rejected treating the clamp's partially
forward-biased transistor as guaranteed off. They also found that the MIC5014
common-source replacement needs additional supply-loss protection; a stocked
4 V-rated power transistor alone does not establish a complete design.

## Release status

This commit records research and an unapplied routing candidate. It makes no
new manufacturing recommendation and does not alter the console or ring.
The next screen-power revision still needs a selected power-stage decision,
its complete state/thermal/startup analysis and regenerated, independently
checked manufacturing files. No new owner measurement or prototype-build
requirement is introduced by this record.
