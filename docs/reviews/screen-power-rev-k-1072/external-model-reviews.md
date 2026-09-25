<!-- cspell:words deepseek kimi noninteractive datasheets -->
# External adversarial review attempts

25 September 2026. These were actual external CLI runs requested by the owner,
not Codex agents renamed after other model families. **No new external model
completed a final Revision K report.** Their review coverage remains incomplete.

| Reviewer | Initial attempt | Retry / final status |
| --- | --- | --- |
| Claude Code | Read-only review request rejected at the session usage limit; reported reset at 19:40 Argentina time. | No completed new review. The earlier completed Claude review and its assessment remain historical evidence, not approval of K. |
| OpenCode Go `deepseek-v4-pro` | Provider required Global regions and rejected the request. | Retried after the owner's update; successfully inspected repository files and public sources, then provider returned `Go usage limit exceeded` at 19:22:48 UTC. No final report. |
| OpenCode Go `kimi-k3` | Stopped after noninteractive access to an old temporary source folder was rejected. | Revised brief removed outside-folder dependencies. Read native pad mappings, validation and integration files, then provider returned `Go usage limit exceeded` at 19:22:50 UTC. No final report. |
| OpenCode Go `grok-4.7` | Stopped after the same outside-folder access restriction. | Revised brief used repository files and public datasheets. Provider returned `Go usage limit exceeded` at 19:24:33 UTC. No final report. |

The successful retries reached design inspection; CLI processes subsequently
remained waiting after the quota failures and were stopped. Neither an exit
status nor an intermediate assurance was counted as completed review evidence.
No workspace privacy setting, account plan or usage credit was changed.

The review brief required verification of actual transistor and relay pinouts,
partial-power states, GPIO control, USB data paths, fuse coordination, power
budgets, heat, wiring and assembly against native files and primary datasheets.
The initial K snapshot had six tapers; the final board has eight. Even the
partial external inspection is therefore not a final-export approval.

Completed independent Codex circuit, mechanical, system, test-quality,
convention, simplicity and publication checks are recorded separately. The
[earlier Claude assessment](../screen-power-claude-1072/assessment.md) documents
the relay fault that was corrected before this revision. The pending external
reports do not invalidate measured CAD checks, but prevent claiming the
requested multi-model review is complete.
