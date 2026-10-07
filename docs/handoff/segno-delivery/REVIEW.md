# Delivery workflow review

Completed October 1, 2026. This reviews the operating plan and agent profiles,
not application implementation, hardware behavior, or PR merge readiness.

## Scope and result

Reviewed the September 30 delivery plan, `START.md`, and seven
`.codex/agents/segno_*.toml` profiles. No application source, existing workflow
configuration, branch state, pending timing merge or issue authority changed
as part of this setup. Files remain local; this report does not claim a commit,
GitHub publication, Goal activation or scheduled execution.

Three independent review roles completed:

| Role | Reviewer | Result |
| --- | --- | --- |
| Plan splitting | GPT-6 Luna, high | No split required for the umbrella policy; implementation remains separate vertical PRs |
| VGV conventions | GPT-6 Sol, high | Publication/CI ordering clarified; unnecessary binding regeneration removed |
| Simplicity and adversarial challenge | GPT-6 Astra, high | Disposable fault-injection permission reconciled with candidate protection |

Both reviewers with findings independently rechecked the affected passages.
No actionable findings remain in this workflow review. They did not certify
the application or verify historical implementation claims. The splitting
review reused the earlier implementation inventory rather than repeating it.

## Findings and resolutions

1. **Publication cannot wait for CI that requires the push.** Local checks and
   independent review precede publication; current-head remote CI and review
   precede readiness. Missing stacked-PR CI remains an unmet gate.
2. **Test sensitivity experiments need a safe write boundary.** Reviewers may
   inject a bounded fault only into an explicitly assigned disposable source
   copy. The real candidate stays untouched; fault mutations never become
   delivery code or passing-delivery evidence.
3. **Binding regeneration follows the public API.** Regenerate bindings for
   `segno_engine_api.h` changes; apply native/C++ checks to internal headers
   without needless generation and verification cycles.

## Checks performed

- Parsed all seven final profiles with Python's TOML parser; checked required
  role fields and model/effort pairs against the host model inventory.
- Checked trailing whitespace and final newlines in all nine delivery files.
- Spell-checked the plan, handoff and profiles with the repository dictionary:
  nine files, zero remaining issues. The initial warnings were the valid
  reasoning-effort identifier, now explicitly allowlisted in its three files.
- Confirmed the timing checkout still has its original HEAD and merge parent;
  did not stage, resolve, reset or otherwise modify that work.
- Application tests were not rerun for this documentation/configuration setup.
  Native subagents performed the review, but client loading of the standalone
  custom profiles has not been exercised. Dispatch must pass their instructions
  explicitly when the calling interface cannot select a custom profile.

The final nine-file source bundle fingerprint is
`d9b53c61403058638bfbe0cda1100a141980844ff68eadb3d45a9c6c0d3d6914`.
It is SHA-256 of sorted relative paths, each followed by a null byte, its file
SHA-256 and a newline. This report is excluded to avoid a circular hash.

The next implementation task remains completing the pending recording-timing
slice with durable evidence. No later milestone is marked complete by this
workflow setup.
