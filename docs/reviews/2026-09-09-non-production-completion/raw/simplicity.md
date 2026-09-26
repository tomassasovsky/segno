# Code simplicity review

## Scope and independence

The approved scope is the local JavaScript design prototype in `docs/plan/2026-09-09-non-production-completion-plan.md`, issue 919. The repository uses Flutter/native code elsewhere; this review applies the existing prototype's pure-model → study/controller → host-adapter boundaries. It does not impose production Bloc architecture on the design artifact.

The baseline is `/tmp/segno-completion-baseline`. Only the coordinator's selected-render, illustrative sound, recorder destination/tap, storage, and related host integration delta was reviewed. Timing and optional MIDI/touch/Solo work, earlier recovery implementations, other dirty files, Pen, and video are outside this role. All source and baseline hashes, test commands and result limits are in `../reviewed-sources.json`.

During the review the coordinator explicitly reassigned three fixes to this reviewer: Audio Library destination identity/publication guards; deletion of the redundant processing render API and migration of its standalone preview; and imported Follow-off render-length scaling. Those authored lines and their tests are excluded from this reviewer's independent verdict. They have author verification; the coordinator assigned independent rechecks to the VGV reviewer. The VGV reviewer reported independent clean USB-copy and standalone-preview tests; imported-length review was separately requested.

## Core purpose

Provide one selected-track render contract, an audible explanation of signal/tail choices, and safe simulated USB performance recording with frozen take settings and recoverable committed parts.

## Redundancy found and resolved

The new shared policy originally coexisted with `SegnoProcessingBehavior.selectedRecipe`, which encoded incompatible rules for Once/fractional/independent sources and shared FX. Keeping both would leave two executable authorities. Under explicit coordinator authorization this reviewer removed the old function, its unused helpers/export, and two old-only tests, then migrated the standalone processing preview to the shared policy. The current-policy tests retain source/exclusion/neutral-destination coverage and add rational Once/independent behavior. The preview's old API call and a text-wrap overflow were found by the other reviewer and corrected; its existing 17 model + Chrome/Firefox suite passes unchanged layout assertions at both viewport sizes.

The coordinator's `renderRack` now resolves placement, channel state and effective activation once for both selected-track Post and shared FX. This is a focused helper with two real callers. The recorder settings-only publication path expresses a distinct transaction instead of coupling user preferences to an unavailable physical drive.

## Remaining complexity assessment

No additional removal or abstraction is justified in the independently reviewed delta. Rational common-cycle arithmetic is required by fractional lengths; using BigInt for exact decimal fractions avoids rounding a false cycle. The recorder's separate durable/pending state, capacity checks at start/checkpoint/finalize, and final drive checks serve different failure boundaries. Sound-example state is transient and disposed on navigation; no persistence layer or speculative engine wrapper was added.

The code remains compact and uses the existing callback seams. Main-host integration is dense, but a broad host rewrite would be unrelated to this approved closure pass. No documentation removal is proposed.

## Validation and revision

The final coordinator recorder and rack-processing suites pass Chrome and Firefox. The shared policy/processing suites pass 25 tests. Standalone processing passes its existing browser behavior and bounds checks. The author-owned copy and imported-length fixes have separate normal-host regressions and independent review requests. See `../reviewed-sources.json` for exact command outcomes, full source/baseline hashes, and exclusions.

| File in docs/design | SHA-256 |
| --- | --- |
| selected-render-policy.js | `0c9dd6be59b07b31d467b470b12dc4a091a0bedf68bd94c925cb2e894b0e507b` |
| sound-behavior-audio.js | `f801e7883fe004e6dbc780dcd3cb7ae4847fa21ad87887faab7df1f8af75e678` |
| sound-behavior-study.js | `a66d8a314b93cdaf2ff09b29d25513cef462c27573b8091ccdbf1861d5cee969` |
| performance-recording-model.js | `e57e0694d46a70fd11ec50446541f3ddeef42ee5954f34914129139119a85856` |
| performance-recording-study.js | `602952defaa2785fd9525b0b1f55332ade59bef7faef28e49926919958a380d6` |
| audio-library-study.js | `c95a6e09ce50a02cdde226c6488c4f29ee234de280c475fafdc4b291f0dd770b` |
| storage-study.js | `ecbd437d64ba0858007bce7ff0fcd3857e76123f7c7cb5f61a59627d176122f2` |
| bounce-performance-study.js | `d9ad2d4382d6f2b47028021cfb0fe8d18c0ebf504031745f770f0851041bcbbb` |
| fx-ux-prototype.html | `483ac9fe67deb2eec9384487b3440e0c74019ec23b2507b3d0ffc57dad04997d` |
| processing-behavior-study.js | `6163f11216a171f1b737a13bc599406133a52a6bc425fb73427349bf73fdf501` |
| processing-behavior-preview.html | `7be1d5845837864b455bacb447ac5302d70b8e0ec82486766bb8919d5f798734` |

## Verdict

No unresolved actionable simplicity finding remains in the independently reviewed coordinator delta. The one redundant render policy has been removed. Remaining justified removal: 0 lines (0%); no further abstraction recommended. Authored fixes are excluded from independent certification, and this verdict makes no production, hardware, CI or merge claim.
