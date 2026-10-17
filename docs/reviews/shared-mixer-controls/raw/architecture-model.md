# Architecture review — model and UI

Review basis: base `06633b2b537efba4c59108e38764e58c0b2c542e` plus the exact 19 file hashes in the original model review source manifest (fingerprint `854620d05942b5d8bd5a971e4095d5a38b882ff6d46e56e3e5537861207da3ff`). One Astra reviewer applied five role definitions sequentially; these are five perspectives, not five independent people. This reviewer authored runtime/coordinator/session changes and does not independently certify them. The reviewed model, resolver, catalogue, labels, endpoint UI and tests were authored by Sol. No tests, product edits, Git changes or delegation were performed during this review.

## Result

No unresolved actionable findings in this scoped source. Eight typed Mix targets share `MixValueTarget.toDomain/fromDomain` and target-specific relative increments; normalized controls do not become a second interpreter. The resolver reads confirmed Mixer values into that coordinate system. The obsolete direct `writeValueTarget` was removed, leaving runtime dispatch through the shared confirmed owner. This is an API boundary review, not independent certification of the runtime implementation authored by this reviewer.

Live availability uses actual tracks/lanes, current input status and exclusion mask, pair topology and actual output buses. Both members must be present for a pair. Stable but currently unavailable targets remain identifiable for editor repair. Catalogue order is shared by the full destination catalogue and numeric-only topology consumers; FX grouping and existing master handling remain intact. Output balance retention while mono is deliberate existing behavior, not evidence of an unavailable stored control.

## Resolved review finding

M310-4: the new topology consumer initially enumerated every FX target through the full catalogue, and its extracted Mixer helper still repeatedly called `LooperRepository.state`, which takes a fresh native snapshot. The final helper `availableMixValueTargets()` takes one local `rig` and derives tracks/input/output limits from it. Full catalogue composition calls the same helper, avoiding duplicate availability rules. The focused regression verifies one state access, no FX chain enumeration and identical Mixer ordering within the full catalogue. Final resolver hash is `e6b90045c3a73f3aa7c861c4e8bcf1569d1d9b1bcc21efde5e514af1429aef90`.

No native callback, FFI symbol or generated binding change occurs in the reviewed scope. Session persistence and holder arbitration require the separate runtime review and adversary evidence.
