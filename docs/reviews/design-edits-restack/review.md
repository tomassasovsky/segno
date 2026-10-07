# Reversible edits reconstruction review

Base: `09c8e9c2`. Incoming parent: `6cdfb9fb`. Scope: staged, working and new
source for mode rules, reversible edits and grouped Clear All, compared with
the reconstructed Tracks/UART base. Issue #1060, part of #1012 and #1058.

Gate: **clean independent review; final aggregate checks recorded separately**.

The user approved refusing completed-audio recovery that cannot fit the
current mode. Refusal preserves the session and history; the app names Free
as a compatible mode for retry. A pending operation gets a separate short
retry message. Neither response automatically changes the mode or transport.
The accepted partial-take rule is preserved: a short fragment recorded inside
an established Multi cycle occupies that full cycle with silence outside it.

The implementation checks a whole Clear All group before any member is
restored. It waits for every frozen capture to finish, and Redo cancels the
whole waiting Undo. The engine independently checks before consuming history
or changing slots, mutes or transport. Effects and cached mutes change only
when the corresponding native action succeeds.

Reviewed angles include changed functions, removed behavior, callback/control
ownership, public API and generated bindings, state persistence, group order,
reuse, simplicity, bounded callback work, failure sequences, tests and PR
readiness. Five review roles were used within the available reviewer slots.
Final test-quality/readiness share one reviewer; that reviewer authored the
bridge and excluded it from independent certification. The simplicity reviewer
independently checked the bridge. Native fixes were checked by reviewers other
than their author. The parent authored repository/UI corrections.

Resolved findings:

- Frozen-clear report ordering, generation ownership and configure resets.
- Restoring clocks according to the current mode.
- Settling stationary mode reports before deduplication and persisting only
  confirmed running-engine choices or explicit offline choices.
- Preserving frozen-group effects and history through rapid Undo/Redo.
- Callback mode-fit validation after a queued crown change.
- Refusing incompatible completed spans without truncating their playback.
- Allowing grouped re-clears to complete without fencing their own members.
- Waiting for a queued or active defining recording and its finalization.
- Matching the recovery instructions to the actual mode label in Spanish.

The final sibling-cancellation race is resolved. Shared-mode recovery waits
for a pending cancellation before checking the finalized master length.
Independent public C and Dart tests verify wait, settled refusal, retained
history and complete 750-frame recovery after an explicit Free selection.
The obsolete engine branch for queuing frozen-clear recovery was removed;
the repository is the single owner of that waiting operation.

No unresolved actionable finding remains in the complete intended diff.

Role reports and observed checks are in this directory. No deployment,
physical pedal test or appliance audio proof is claimed. Full remote CI does
not run on this PR's stacked base; local checks do not replace that gate.
