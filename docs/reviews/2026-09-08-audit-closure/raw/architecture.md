# Architecture review

Scope: the authorized September 8 design closure pass in `docs/design`, including D1/D2 additions and media/repair integration. Production Flutter, native audio, hardware, Pen, unrelated working changes and final PR/CI gates are outside this review. Reviewed the supplied D1/main baselines and the newly connected D2/media ownership, draft, cancellation, persistence and callback seams. This is not a demand to replace the established vanilla-JavaScript study architecture with production Bloc.

Role instructions: `workflow-agents/references/architecture-review-agent.md` and `build/references/review-agent-instructions.md`. Project instructions, build/tracking context, `pubspec.yaml` and `analysis_options.yaml` establish Flutter/Bloc as the production stack; this explicitly approved silent prototype uses shared host state and injected study callbacks.

## Layer separation

No new package/import-direction violation found in the reviewed prototype scope. The main page owns the shared rig and persistence. The source studies own editable drafts; the new media helper owns only chooser/job/repair-dialog state and delegates source mutation through callbacks. This is consistent with the existing design-study boundary. No production package or dependency was added by this slice.

## State management assessment

### Source Save correction verified

The initially reproduced expression/external-switch Save failure is resolved in the reviewed revision. `expression-ux-study.js:42` calls `write(copy(draft), switchUI.pendingBindings())`, reports an error on rejection/exception, and invokes `didCommit()` only after success. The host callback at `fx-ux-prototype.html:647` snapshots the rig, applies settings and binding patches together, saves once, and restores the original rig/returns false if persistence fails. Pending binding changes remain owned by the source draft until that successful commit.

Re-ran the same isolated failed-write reproduction after the correction. Result:

```json
{"savedTarget":"missing","draftTarget":"new","notice":"Could not save. Your changes are still here."}
```

The repaired draft survives for retry and the saved mapping remains unchanged. The model suite's expression repair case now covers rejected Save and successful retry. Browser host-storage validation is in `verify_media_closure.cjs` and is owned by the coordinator/media author. The integrated media browser suite now includes combined settings-plus-binding failure/retry assertions; the test-quality report records their verification.

### Other reviewed seams

- Preset interchange validates packages before publication, revalidates file identity/content at completion, tracks USB generation, cancels the timer on Back/leave, preserves existing package copies and defers imported preset creation to the source library's confirmation.
- The preset UI requires its appliance media adapter; the obsolete browser download/file-input fallback is removed. Storage reads only the applied device format callback and its own free-space state, avoiding recursive snapshot ownership. Unknown capacity stays unavailable in both the capacity card and estimate.
- Shared busy callbacks include preset transfers in Audio, Storage, update, backup, device and power paths. Source capabilities stay simulated and are identified as such.
- Repair dialog checks the original mapping and replacement availability before Apply; expression/external/MIDI owners retain target ranges and sibling actions in their drafts. Target setters are not called to audition a replacement.
- D2 custom-clear state remains in the pedal draft, preserves fixed controls, supports restoration and handles refused saves. Mode shortcuts call the established compatibility/confirmation path and recheck at commit; transpose bypass has an independent stored enable value and preserves pitch amounts.
- D1 track naming uses stable track IDs and rolls back its host write on failure. Auxiliary Mixer controls use the same `expressionMix` owner as backing/click mappings. Fine BPM uses the existing Loop settings/draft cancellation seam.

The separate Mixer selection observation is also resolved: the track number now exposes `stage-track:<i>` for direct touch/encoder selection while the title owns Rename. Source review confirms both dispatch paths remain distinct.

## Dependency direction

Direction violations found: 0 in the scoped additions. No new package cycle or production data client import was introduced. The media helper receives source-owned `read`/`apply`/`write` callbacks rather than becoming another owner of expression or MIDI mappings.

## Validation and completeness

Freshly executed `node --test docs/design/media-closure-study.test.cjs docs/design/pedal-closure.test.cjs docs/design/fx-parity.test.cjs docs/design/media-parity-study.test.cjs`: **48 passed, 0 failed** after the final media cleanup and dynamic Storage regression. Also executed the failed-source-write reproduction above. Browser integration runs are owned by the coordinator/media author; this report does not claim their results, Pen verification, native/audio behavior, production analyze/tests or CI.

Reviewed scope is complete for the listed added/changed ownership and lifecycle seams, with no remaining actionable architecture findings at this report revision. Baselines were available for the main page, Stage display JS/CSS and Loop study; D2/media review is of the current changed feature seams rather than a full audit of every pre-existing function in those modules. A new change invalidates evidence for that changed file until reviewed again.

## Reviewed file hashes

SHA-256 values captured when this report was written; these identify this review revision, not a claim that later edits were reviewed.

| File | SHA-256 |
|---|---|
| `docs/design/fx-ux-prototype.html` | `f5fafd5e2f3f760e4d57ce6d591861cf9c549213eeb2f046ace7a69414a931b6` |
| `docs/design/stage-display-study.js` | `d10a5cf8a593aea0f37a6fa55ebfa51a7527f765de40b56d412d507f38e91fbc` |
| `docs/design/stage-display-study.css` | `7b29f0ef5a64da862bc73b947fa3ef2ef9594b64bea503c1fe55260044a06eb8` |
| `docs/design/loop-ux-study.js` | `a41dbad688e34c064da757b384a39c08b83b9beabf39a046730166d5b0f8ce20` |
| `docs/design/media-closure-study.js` | `8549c4a9ba927e7762cd91e71e694aa4c1c3c378a97e35bcfaff68e75c7c19fc` |
| `docs/design/media-closure-study.css` | `a725fb5d81319159e3afd1e4938eb1f06e023e041b563486259763032c53db17` |
| `docs/design/fx-preset-library.js` | `049cd20c658262a90ec5852bfd06c666e1933ae62ddd82884c7ef83f70c8e233` |
| `docs/design/expression-ux-study.js` | `1c42c77205dfd4f7ff5d4aef9a96617c71e7624afe9dd97b1bc010fd4940d70a` |
| `docs/design/external-switch-study.js` | `d35628ee5a4a98c802806a27f5661b2816b659a8379f00c33f8ad51d78c97dcc` |
| `docs/design/midi-controls-study.js` | `59099849f5cc0156442639af5fd14171c823a8a4bc45f1943a2c218f87e5042b` |
| `docs/design/storage-study.js` | `c53fcf0ab6ebe18c3af9e05d8732972b1cdb83f35738e81a07b58cbcbb6b97ea` |
| `docs/design/transpose-performance-study.js` | `74639a419241100a3c836014391eca194809c432c9864e096f925254b9290f17` |
| `docs/design/pedal-action-catalogue.js` | `2281281d3be1366c5497593c2a0aa218dbb4b4e4f696d8ad5641e36bdaa9e560` |
| `docs/design/mapping-action-dispatch.js` | `9bb53e6906deafaf9da8233764ef4fc96a1f6a95c8bdc691c88de383c4423149` |
| `docs/design/pedal-ux-study.js` | `c26fafabc851089c3a055fd387804c344f5b9da9b40698fe683a98177d02ead9` |
| `docs/design/pedal-performance-study.js` | `84beb3dc8dec284a475c51f202043a0ad7e1327752469cdba4bb7793f49eeb3c` |
| `docs/design/media-closure-study.test.cjs` | `549cecc2d1a294df191aeef125798f44404e58596d430c5873a7cc6ebb749576` |
| `docs/design/pedal-closure.test.cjs` | `d69a55006ec983e595613c279e0e300f280c1a92ccdedc48a9f885eb77e4df0c` |

Supplied baseline files under `/tmp/segno-closure-before`:

| File | SHA-256 |
|---|---|
| `fx-ux-prototype.html` | `d32397030dda401f164261f2b0394e6bbe462146f34e33fa3f844bdf6306c417` |
| `stage-display-study.js` | `40481387293dcc7bef7d6332e5b0f03415dc7245e7febf4fa10b2ac88cfeaf7c` |
| `stage-display-study.css` | `e48b654863678379dfcf36d349c37c183755950a133da1767872a924e00e71da` |
| `loop-ux-study.js` | `6921dd9e1968cc7b86ed954725bf21147b81d8c13bac4326efa421364fba421f` |

## Verdict

Architecture is clean for the reviewed design-only seams and hashes. The reproduced Save failure was corrected and rechecked; no remaining actionable finding. This is not production, hardware or final PR/CI review evidence.
