# Test quality review — final M3.2

Base: `da0c1f70d9815f68f9f5bb43e16f36de01a0b365`. The complete 39-path M3.2 manifest is `final-hashes.json`, fingerprint `90293cd611fb26bab771611de108652d789ea5025d99a1cf2987ecc4598cba7b`. Final file hashes were reconciled with no drift. One independent non-author reviewer performed these five roles and the bug review; a separate independent reviewer executed the adversarial probes. This reviewer authored no M3.2 product or test code and ran no duplicate broad tests or native builds. Prior native/package authorship is outside this delta.

No unresolved test-quality finding. Tests exercise behavior through existing Flutter, bloc_test/mocktail, real SettingsRepository and native-pump seams.

Model tests cover explicit malformed tokens, unknown stable identities, bank/shared assignment ownership, canonical serialization and immutable custom maps. Control tests cover accepted 800 ms timing, immediate transport, Mute isolation, fire-time target changes, retained Bank Hold recording, configuration invalidation, active/pending capture preservation and deliberate recovery from malformed storage. Repository tests distinguish absent storage, exact opaque prior bytes, write-then-throw, checkpoint-read refusal and failed restoration. UI tests cover delayed loading, grouped/fixed controls, safe Save/Cancel, pending writes, persistent uncertainty, unavailable setup replacement, Stage and desktop scrolling.

Three historical fuzz fixtures were corrected from obsolete two-tap cycling to the new configured Press transition. Original audio assertions remain; the previously silently mis-targeted redo scenario now asserts Record mode explicitly. Deleted style tests correspond to removed APIs; unreachable incoming Custom-only UI tests were excluded from this slice rather than skipped.

Root verification-v2 passed 2310 app tests with six existing skips; coverage after the unchanged CI exclusions is 19404/21462 = 90.4109589% (floor 90%). The unchanged settings source is bound to its 145-test pass and 90.1333% coverage; that package has no configured floor. Separate independent evidence contains 14 targeted checks with explicit repair amendments and retained failing originals. Fixture corrections are distinguished from product repairs.

Independently inspected nine author-rendered goldens. The actual Mac journey is author evidence, not CI or an independent hardware run. Exact encoder return is source-traced through the existing focus/navigation primitives; no physical encoder claim is made.

This slice delivers Setup Tracks. Custom editing and the accepted Mode Hold → Custom default remain explicitly assigned to the actual runtime slice, PR #1030. Current Hold → FX and Bank Hold performance recording preserve working capabilities. Retained Custom data does not imply delivered Custom execution. Host tests and desktop journeys do not prove physical pedal timing, electrical behavior or appliance ergonomics.
