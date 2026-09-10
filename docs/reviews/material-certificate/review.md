# Supplier material correction — 1100-H14 certificate

The owner forwarded Dinacut's correction on September 9: stock previously
described as 1050 is actually 1100-H14. The supplied Alcast Laminados certificate
identifies lot 26E0269, 2.00 mm sheet, issued April 1, 2026. Its single page was
read as text and visually checked. The source file hash and numerical evidence
are in [the record](certificate-review.json). The supplier certificate is held
by the owner; it is not copied into the public repository.

Reported results are 127 MPa yield, 145 MPa tensile strength and 10% elongation,
against specified requirements of at least 95 MPa yield, 110–145 MPa tensile
strength and at least 4% elongation. The document cites ABNT NBR ISO 209 for
chemistry and ABNT NBR 7823:2023 for sheet mechanical properties. These are
certificate statements, not independent authentication or testing.

Use 95 MPa as the specification-minimum strength reference for assessment; it
is not an allowable working stress. Keep 127 MPa as the reported lot result,
not a generic guaranteed property of all 1100-H14. Compared with the earlier
1050-H14 reference of 85 MPa, the minimum increases by 11.8%; this is not a
claim that every 1100 temper exceeds every 1050 temper.

Applying these references to the existing bare-strip sensitivity screen leaves
the strength question open. At the provisional 700 N static load, its two
effective-width cases produce 269.47 and 134.73 MPa, above both 95 and 127 MPa.
That model omits folded walls, two-dimensional plate action, actual foot
contacts and printed-support stiffness. It does not prove real enclosure
failure or provide a conservative bound; it cannot qualify stomp performance.
The strength values also do not by themselves establish post-coating or
assembled performance.

The certificate resolves alloy/temper identity for the described 2 mm lot.
Confirm that this certificate covers the stock allocated to the actual job.
Obtain separate alloy/temper evidence for the 1.2 mm rear panel: it is outside
both the identified 2 mm product and the printed mechanical-property band
(1.50 < thickness ≤3.00 mm).

Material identity in the release record now reflects the supplier correction.
The current generator/drawing callouts still say 1050 and need controlled
reissue for the accepted stock. No CAD geometry, DXF, PDF, STEP, printing ZIP
or Fusion document was changed during this certificate review, and cutting
is not authorized.

An independent reviewer checked the transcription, design-reference versus
lot-result distinction, strength-screen ratios and uncovered rear-panel
thickness. No disagreement remained.
