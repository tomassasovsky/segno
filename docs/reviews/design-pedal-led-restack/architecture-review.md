# Architecture review

Bound to freeze-v2 fingerprint `57dcdae120419b771c9bf8ad43d7cd9c976ccaf39ce28a7cf18e884c78ffef2c` (69 paths); base `3e67d031148f21eb9c3ee99a961f6ca4587dbc3b`, intended merge parent `424e12d0e53a969f8887089be0ea9450404be969`. All source hashes were independently compared with the frozen packet and match. One implementation-independent reviewer performed source review and all five quality roles sequentially; the roles share a reviewer and are not five independent reviews. No implementation edits, tests, builds, staging, publishing or hardware operations by this reviewer.

## Result
No unresolved layering, ownership or dependency findings.

ControlCubit projects one physical mask plus semantic track/ring data. Shared Custom transport keys and bank-keyed track keys use the same function-state helper, including last-fired Press/Hold selection and pinned targets during accepted contact. Palette UI/persistence stays deferred to1032; hue transport is independent from activation. Async operation completion is guarded by setup/session identity and per-button dispatch token, retired on new contact or invalidation.

Repository owns the canonical detached frame, equality/dedup and current-version trust; PedalCubit only mirrors that frame to UI. Setup draft-bank suppression prevents another logical track's state appearing alongside the wrong assignment, while shared control states remain live. The C boundary validates before publication; firmware knows mapping and optical limits but no function assignments. Ring is independent from pill hues/mask. There are no new UI data-client imports, native/FFI API changes, Song fields, SysEx paths, PD or new-v3 transport imports.

Critical:0; Important:0; Suggestion:0.
