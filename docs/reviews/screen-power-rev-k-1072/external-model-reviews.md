<!-- cspell:words deepseek kimi noninteractive datasheets -->
# External adversarial review status

25 September 2026. These were actual external CLI runs requested by the owner,
not Codex agents renamed after other model families. **Claude subsequently
completed a final Revision K report in a real cloud session.** OpenCode Go
coverage remains incomplete. The [cloud assessment](claude-cloud-assessment.md)
records its verdict, evidence limits and the disposition of all eight items.

| Reviewer | Initial attempt | Retry / final status |
| --- | --- | --- |
| Claude Code | Local read-only review request rejected at the session usage limit. | Owner-authorized cloud session completed on the exact final K commit and hashes. It found no verified circuit/artwork defect and recommended first-prototype fabrication, not assembled-production qualification. |
| OpenCode Go `deepseek-v4-pro` | Provider required Global regions and rejected the request. | Retried after the owner's update; successfully inspected repository files and public sources, then provider returned `Go usage limit exceeded` at 19:22:48 UTC. No final report. |
| OpenCode Go `kimi-k3` | Stopped after noninteractive access to an old temporary source folder was rejected. | Revised brief removed outside-folder dependencies. Read native pad mappings, validation and integration files, then provider returned `Go usage limit exceeded` at 19:22:50 UTC. No final report. |
| OpenCode Go `grok-4.7` | Stopped after the same outside-folder access restriction. | Revised brief used repository files and public datasheets. Provider returned `Go usage limit exceeded` at 19:24:33 UTC. No final report. |

The successful retries reached design inspection; CLI processes subsequently
remained waiting after the quota failures and were stopped. Neither an exit
status nor an intermediate assurance was counted as completed review evidence.
The failed local/provider runs changed no workspace privacy setting or account
plan. The later cloud review used the owner's existing cloud credits; no credits
were purchased and no billing setting was changed.

The review brief required verification of actual transistor and relay pinouts,
partial-power states, GPIO control, USB data paths, fuse coordination, power
budgets, heat, wiring and assembly against native files and primary datasheets.
The initial OpenCode K snapshot had six tapers; the final board has eight.
Those partial inspections are therefore not final-export approvals. Claude's
completed cloud pass verified the final eight-taper board and archive hashes.
It had no KiCad/STEP tooling and no direct PDF access; supplied manufacturer
extracts were kept distinct from its own native-file analysis.

Completed independent Codex circuit, mechanical, system, test-quality,
convention, simplicity and publication checks are recorded separately. The
[earlier Claude assessment](../screen-power-claude-1072/assessment.md) documents
the relay fault that was corrected before this revision. Claude's cloud report
is now completed external evidence. The missing OpenCode reports still prevent
claiming the requested multi-model review is complete.
