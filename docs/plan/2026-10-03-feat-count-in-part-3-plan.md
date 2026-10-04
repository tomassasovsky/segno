# Part 3: shared Count-in mappings (#1026)

Depends on [part 2](2026-10-03-feat-count-in-part-2-plan.md).
Status: implemented under #1121 after Part 2 PR #1120. Local aggregate checks
and complete independent source review pass; additional Claude review and
current-head CI remain separate publication gates. Human merge review remains.

## Result

External buttons, expression and MIDI absolute/relative controls use the same
confirmed pair and shared countdown as touch. Exact target is
`{"ctl":"countIn"}` in Loop controls. Off/1/2/4 uses nearest normalized option
index, not rounding to four bars; step is one third. No new Sound target.

Add only now the controller method and optional Released pair to the existing
owner/repository port. One pair-wide ordinary revision makes accepted Sound
changes supersede old Count-in holders even when its numeric count remains
zero. Refusal gains no priority. Use the existing Control ledger and interpreter.

Apply Released Count-in to the accepted live pair to derive saved intent:
prior Sound true, Held2/Released0 gives live `(2,false)`, saved `(0,false)`;
Held0/Released2 gives live `(0,true)`, saved `(2,false)`. Do not resurrect a
hidden prior Sound preference. Non-held acceptance remains durable on retirement.

Save and restart use Released intent while Held remains live. A release during
capture remains owed; it never stops recording or claims success. Retry once
eligible under the original lifetime/revision. New Session/device lifetimes
must not receive old releases. Retirement never launches or restarts a canceled
countdown, and reconnect does not replay stale contacts. Recovery blocks alleged
confirmed save/halt; Retry repairs and flushes owed releases before shutdown.

## UI and proof

Button endpoints start at the current accepted choice; expression/MIDI retain
full normalized ranges. Use named choices, shared spacing and disabled reasons.
Mapping Add/Save emits no audio command. Escape/Cancel preserves raw authored
endpoints, including repaired mappings. A recovery page retains confirmed values.

1. Freeze literal choices and pair transformations independently of helpers.
2. Runtime writer owns Control, Tempo, repository projection and dispatch tests;
   UI writer owns catalogue, labels, readouts and endpoint editors. Coordinator
   composes Session/App and fixtures after shared ownership transfer.
3. Execute real-native MIDI and actual External expression movement, two-holder
   precedence, same-value ordinary Sound, refused cleanup, session replacement,
   actual Save/Save As files and shutdown. Mapping creation alone is insufficient.
4. Negative controls must distinguish live from durable pair and callback result
   from raw equality. Preserve first failures and changed-source bindings.
5. Freeze/review the full diff; pass required package/App/native/static/coverage,
   visual and current-head CI gates. Physical controls remain separately gated.

Only this part closes the whole shared Count-in requirement. No parallel
interpreter, duplicate pedal setup, new native clock receiver, generic transaction
framework or compatibility migration is in scope.
