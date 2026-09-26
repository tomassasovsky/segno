# Repair unavailable controls in saved sessions

September 8, 2026. The owner approved continuing the Library repair flow for
assignments that point to unavailable effects or parameters. Local prototype
work remains under issue 919. Processing/tail policies remain open.

## Flow and implementation

The existing dependency review gains Replace for each missing control. Choose
a destination in the incoming session, then a replacement control. Review every
affected expression, external-button and MIDI assignment with its replacement
endpoint values. Use this control stages the repair; Apply and open publishes
the complete pending session through the existing boundary. Cancel discards it.

Extend the existing Library dependency state rather than adding a second browser.
Keep compatibility, exact-ID remapping and range conversion in a pure
`session-target-repair.js` model. The main host supplies target descriptors from
a copy of the incoming session. It does not borrow the live rig's effect IDs.
Preserve normalized ranges using the existing target coercion and formatting;
show typed endpoint changes explicitly. Refuse same-source duplicate targets.

Missing processor or knob IDs can be reassigned to another existing control.
This does not install a plugin, replace an entire audio processor, guess a
parameter domain or silently reconstruct a removed effect. Those operations
would need their own sound-editing choices.

## Success Criteria

```success-criteria
GOAL: Repair missing saved control targets in Library, review ranges, and publish only after explicit Apply and open.

SUCCESS CRITERIA:
- Exact target replacement preserves all affected source identities and ranges, with typed coercion and collision refusal. | verify: node --test docs/design/verify_session_target_repair.cjs
- Touch, encoder and foot controls complete replacement review; Cancel, stale choices and failed publication preserve current and archived sessions. | verify: node docs/design/verify_session_target_repair_browser.cjs
- Existing connection repair still supports pending Apply, reset, cancellation, disconnection and reload. | verify: node docs/design/verify_session_connection_repair_browser.cjs
- Saved Pen references match the prototype and remain inside clearly named groups. | verify: manual inspect native text/focus geometry and renders; save Pen and verify its on-disk hash.
- Five independent build-review roles finish with no unresolved actionable findings. | verify: manual reconcile all role reports against the final scoped revision.

NON-GOALS:
- Native audio processing, missing-plugin installation, inferred parameter domains, appliance storage guarantees, and unresolved downstream-tail policies.

VERIFICATION COMMAND: node --test docs/design/verify_session_target_repair.cjs && node docs/design/verify_session_target_repair_browser.cjs && node docs/design/verify_session_connection_repair_browser.cjs
```

Existing media and connection repairs must compose in one pending snapshot.
The held-contact request revision must cover destination, target and review
navigation so stale releases cannot stage or apply a changed choice.

## Local implementation result

The prototype and five grouped Pen references are complete. All criteria have
observed evidence in the [review record](../reviews/2026-09-08-session-target-repair/review.md):
21 focused/93 combined model checks, Chrome/Firefox interaction and recovery
journeys, five independent review roles, native geometry and saved-file checks.
This is ready for owner design review; no production or merge approval is implied.
