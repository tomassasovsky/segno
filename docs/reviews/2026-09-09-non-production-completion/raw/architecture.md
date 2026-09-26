# Architecture review

## Scope and independence

The approved scope is the local JavaScript design prototype in `docs/plan/2026-09-09-non-production-completion-plan.md`, issue 919. The repository uses Flutter/native code elsewhere; this review applies the existing prototype's pure-model → study/controller → host-adapter boundaries. It does not impose production Bloc architecture on the design artifact.

The baseline is `/tmp/segno-completion-baseline`. Only the coordinator's selected-render, illustrative sound, recorder destination/tap, storage, and related host integration delta was reviewed. Timing and optional MIDI/touch/Solo work, earlier recovery implementations, other dirty files, Pen, and video are outside this role. All source and baseline hashes, test commands and result limits are in `../reviewed-sources.json`.

During the review the coordinator explicitly reassigned three fixes to this reviewer: Audio Library destination identity/publication guards; deletion of the redundant processing render API and migration of its standalone preview; and imported Follow-off render-length scaling. Those authored lines and their tests are excluded from this reviewer's independent verdict. They have author verification; the coordinator assigned independent rechecks to the VGV reviewer. The VGV reviewer reported independent clean USB-copy and standalone-preview tests; imported-length review was separately requested.

## Layer separation

No dependency-direction or layer violations remain in the independently reviewed scope. `selected-render-policy.js` computes a detached symbolic plan; the host resolves actual track/rack identity, effective bypass, placement, and channel choices. `sound-behavior-audio.js` creates illustrative PCM without application state or persistence; its study owns only playback and comparison controls. The recorder model owns frame/part allocation while its study drives lifecycle through injected capacity/publication callbacks. The host owns the prototype stores.

## State ownership and lifecycle

| Owner | Reviewed invariant |
| --- | --- |
| Selected render policy | Reads cloned source descriptors, excludes transport mute/solo and unrelated buses, gives Bounce and Save the same duration/shared-FX controls, and returns a neutral destination. |
| Main render adapter | Captures resolved Post placement, rack input/output/pan and effective activation; excludes already printed Pre from runnable effects. Channel changes alter the plan, so pending Save validation can reject stale processing. |
| Recorder study | Active take freezes destination identity, format and final-output choice. Drive loss/slow writes retain committed frames and cancel pending finalization. Recovered publication requires the original drive. |
| Recorder host | Publishes the candidate recorder/catalogue/capacity state together and restores previous fields on failed storage writes. A separate settings-only transaction lets the user choose Internal with USB absent. |
| Storage study | Unknown capacity remains unavailable, busy recording prevents eject, and View transfer returns to the recorder. |
| Sound example study | Owns one AudioContext/source/timer; changing a choice or leaving stops the example. Its PCM and output comparison are explicitly illustrative. |

The 6/8 bar conversion is now `numerator * 4 / denominator` in Bounce and length adapters, matching the quarter-note beat model and Audio Library. This was rechecked by source trace; the full meter/timing engine is outside this role.

## Findings reconciled

- USB A → Internal → USB B originally retained A's storage identity and hid a successful export on B. Corrected under delegated author ownership; copy/import/render races, stale Replace, preview identity, writer rollback and reload pass in both browsers. Independent review of that fix belongs to the other reviewer.
- Unknown USB space originally rendered as zero because `null` was coerced before formatting. The coordinator now preserves the unknown case; the final recorder suite checks the visible message.
- Recorder settings originally required the old disconnected USB. The coordinator split metadata-only publication; the original normal-host reproduction now changes to Internal with no error.
- Storage's View transfer originally opened Audio Library during USB capture. The final browser suite verifies the recorder destination.
- The render plan originally offered active printed Pre as runnable FX. The coordinator now includes Post only, once, with resolved channel state; the independent final rack-processing suite passes both browsers and confirms source immutability.
- Imported Follow-off Multiply/Divide originally retained the original render duration. Corrected under delegated author ownership; the separate normal-host test checks 24 → 48 → 24 → 12 seconds and Save/reload without changing original timing metadata. This fix is excluded from the independent verdict.

## Validation

Observed final coordinator regressions: `verify_recording_completion_browser.cjs` and `verify_render_rack_processing_browser.cjs` pass Chrome and Firefox. The final combined deterministic run passes 59 processing, selected/sound, multipart and media cases; exact commands and counts are recorded in the manifest. Author tests and independently reviewed tests remain distinct.

These checks prove simulated state, publication order, callback wiring and illustrative Web Audio behavior. They do not prove native DSP, actual recorder/filesystem durability, live USB speed/capacity, hardware behavior, whole-project CI, or production parity. Exact FX domains/defaults and factory content remain external evidence blockers documented separately.

## Reviewed revision

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

No unresolved actionable architecture finding remains in the independently reviewed coordinator delta. Authored fixes require the separate reviewer recorded above; this is not a whole-tree, production, CI, or merge certification.
