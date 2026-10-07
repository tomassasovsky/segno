Model: Claude Opus (subagent), in-session

# Review of PR #1155 (head d13af7e16b5e1202ebb9483de8307caaac5417d1, base codex/fade-clear-history 270209fbc)

## Verified correct (traced)

- **Node bound.** In json_read.c, each JSON value takes exactly one `alloc_node`: objects at :61, arrays at :111, and strings, bools, null and numbers at :151-190. Keys are not separate nodes; `parse_object` stores them on the member, :88. Every non-root value is parsed only after the parser consumes a distinct ':' (:84), '[' (:114) or ',' (:98 or :133). `p->i` only moves forward, so each node maps to a different punctuation byte. That makes `1 + count(':' ',' '[')` an upper bound for every accepted parse, and also for partial parses that fail. Object commas and punctuation inside strings or after an embedded NUL only raise the count.
- **Complete read.** `fseek` and `ftell` errors give `size = -1`, which is rejected. An empty file is rejected. `size + 1` cannot overflow. A short `fread` gives LE_ERR_INVALID (perf_render.c:345-363).
- **Overflow and ownership.** The INT_MAX check and the `SIZE_MAX/sizeof` check come before the allocation (:370). On every failure path, `text` is freed inside the loader, and `arena.nodes` is always freed by the worker (:1674), including when it is NULL. No path leaks or double-frees.
- **Publication.** `result` is stored relaxed before the release store of `done` (:1678-1680). The poll does an acquire-load of `done` and only then a relaxed load of `result` (:1729, :1737). The ordering is correct. Each `begin` callocs a fresh session (:1701), so `result == 0 == LE_OK` and the status resets.
- **Dart.** `failed` is `!EngineResult.fromCode(rc).isOk` (native_audio_engine.dart:2282). Idle, running and valid-empty renders all return LE_OK, so `failed` is false for them. The cubit takes `failed` from the same `done` progress snapshot (performance_recorder_cubit.dart:518-523). It ORs it into `anyFailed` (:548-550). Stopped-early still takes precedence (:559-560). Finalization is unchanged. The repository passes progress through unchanged (performance_repository.dart:212).
- **Legacy tests.** Both updated assertions (test_engine_core.c:32408 and :32452-32454) get stricter: they move from LE_OK to LE_ERR_INVALID and keep `done && count == 0`. In the identity test, the valid cases (`i >= 20`) still assert LE_OK and `count > 0`. Honest.

## Findings

1. **The large-manifest test passes on the base, so it does not test the new sizing (medium, test).**
   - Where: test_engine_core.c:19465-19490.
   - Trigger: the base arena it replaces is `8192 + 16 * LE_LAYER_STAGING_RING_CAPACITY` = 8192 + 16×(8×256) = 40,960 nodes (base perf_render.c:69). The test builds 2,100 × 10 + about 10 ≈ 21,010 nodes, so it passes with or without this change.
   - Impact: the comment's claim that it is "well past 8,192" is only true against master before #1145. The text-sized arena, which is the actual point of the PR, has no test oracle. Issue #1144 also asks for a supported-size capture that "renders correctly", but this test renders zero tracks.
   - Smallest fix: build more than 40,960 nodes, for example 2,048 layers plus a large `armSnapshot`/`disarmSnapshot` FX payload, or about 4,200 entries. Better still, add one real track so the render produces a stem whose samples are checked.
2. **Failure paths with no test (low, test).**
   - The short-read branch (perf_render.c:360) and both LE_ERR_DEVICE returns (:356, :379) are never exercised.
   - The `failed` mapping in NativeAudioEngine (native_audio_engine.dart:2282) has no test. The recorder test sets `failed: true` on a fake, and the new Dart test only checks equality and hash. Plan acceptance item 3 asked for the real mapping to be tested.
   - segno_engine/test has no native-backed Dart harness today.
   - Smallest fix: a fake-bindings unit test for `renderPoll` that returns -1 with done=1 and checks `failed`. The short-read branch can stay as documented, since a seam would be needed to reach it.
3. **The old test comment now contradicts the code (low).**
   - Where: test_engine_core.c:19418-19421.
   - The old block comment still says a missing or corrupt manifest is "matching a render that legitimately has nothing to do". It sits directly above the new comment, which says the opposite.
   - Fix: delete the old block.

## Optional notes

- **Size bound vs json_read.** json_read indexes the text with `int` (`p->i` at :8 and :194, and `string_len`). A manifest larger than INT_MAX would overflow inside the parser. This is not new and not realistic. Bounding `size` at `INT_MAX - 1`, next to the existing node check, would make "size bounds" match the parser.
- **Banner text.** A whole-render manifest failure shows `perfPartial` ("Some tracks failed to render…", app_en.arb:1262), but in this case every stem failed. The plan explicitly rules out a new banner, so this is a wording call for the owner.
- Boot salvage (performance_repository.dart:709, :770) still checks only `done`, as the plan scopes.

Verdict: no correctness defects in the native, Dart or cubit changes. Approve after the large-manifest test is made to exceed the base arena's 40,960 nodes (finding 1). Findings 2-3 are non-blocking.
