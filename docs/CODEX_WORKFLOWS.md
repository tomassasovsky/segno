# Codex workflow inventory

<!-- cspell:words Canva frontmatter graphify -->

Audited on 2026-09-04 against this repository, the installed Claude plugins and
personal skills, the Codex configuration, and 1,621 saved Claude transcripts
across 39 Segno/loopy project and worktree directories. Counts below are the
232 explicit Skill tool invocations, deduplicated by tool-call ID, observed
between 2026-07-13 and 2026-09-04. Loading a skill through a file or injected
prompt is recorded separately; absence of a Skill call does not prove non-use.
Raw transcripts, account details, and device addresses remain outside Git.

## Skills used in this project

Invoke Codex skills with `$name`, or describe the task in ordinary language.
Personal skills live under `~/.agents/skills/`; project instructions live in
`AGENTS.md`. The shared workflow instructions now use Codex tools and explicit
role definitions rather than Claude tool names or plugin-only agent types.

| Claude skill | Calls | Codex equivalent |
| --- | ---: | --- |
| `code-review` | 110 | `$code-review`: eight review angles, concrete findings, current-head merge gate |
| `brainstorm` | 27 | `$brainstorm`: requirements, approaches, durable decision document |
| `plan-technical-review` | 25 | `$plan-technical-review`: simplicity, VGV, and plan-splitting roles |
| `plan` | 24 | `$plan`: implementation tasks and observable success criteria |
| `build` | 20 | `$build`: implementation, validation, five quality-review roles, authorized shipping |
| `review` | 6 | `$review`: VGV, architecture, tests, and simplicity with one findings report |
| `figma:figma-use` | 5 | `$figma-use` and the configured Figma MCP server |
| `artifact-design` | 4 | Installed `visualize` for interactive artifacts; Sites for websites; artifact-specific document skills |
| `pcb-layout` | 3 | `$pcb-layout`: KiCad placement, critical routing, DRC and rendering |
| `create-pr` | 2 | `$create-pr`: scoped staging, commit, push, issue links, CI and review gates |
| `figma:figma-create-new-file` | 2 | `$figma-create-new-file` with Figma MCP |
| `run` | 1 | `$run`: Segno development app, fake radios, and enclosure viewer |
| `refine-approach` | 1 | `$refine-approach`: improve the existing document without changing accepted intent |
| `orchestration` | 1 | Existing `$orchestration` and `$orca-cli` for Orca-managed work |
| `figma:figma-generate-library` | 1 | `$figma-generate-library` with its complete API references |
| `graphify` | Read/injected | `$graphify`: existing graph queries, AST/semantic extraction, incremental updates and exports |
| `claude-automation-recommender` | Injected | OpenAI Docs and Skill Creator for Codex setup; this inventory and native hook configuration |

Figma's linked `figma-generate-design`, `figma-use-slides`, and
`figma-code-connect` skills are included so the observed workflows have all
their referenced dependencies. Authentication and actual server capabilities
remain separate from having skill instructions installed.

## Shared VGV and development library

These skills were already present in `~/.agents/skills`; many were also
symlinked into Claude. They remain discoverable, with unsupported Claude
frontmatter removed and host-specific workflow dependencies ported:

- Delivery: `brainstorm`, `plan`, `plan-technical-review`, `refine-approach`,
  `build`, `hotfix`, `review`, `create-pr`, `rebase`, `create`, `debrief`.
- Flutter/Dart: `accessibility`, `animations`, `bloc`, `create-project`,
  `dart-flutter-sdk-upgrade`, `green-gate`, `internationalization`,
  `layered-architecture`, `license-compliance`, `material-theming`, `navigation`,
  `static-security`, `testing`, `ui-package`, `very-good-analysis-upgrade`.
- Writing and coordination: `elements-of-style`, `orca-cli`, `orchestration`.

The `green-gate` workflow now uses the project's working runner and coverage
policy. It no longer mandates the broken Very Good MCP test parser. Workflow
transitions honor existing authorization, use `$skill` invocations, and do not
require Claude's `/clear` or repeat approval already given.

## Review and research agents

`$workflow-agents` contains the ten original VGV role definitions as explicit
reference files. Calling skills pass those definitions to Codex subagents,
inherit the current model, respect the available concurrency, and wait for all
results. A failed role makes the review incomplete.

| Claude role | Observed calls | Codex role reference |
| --- | ---: | --- |
| VGV review | 70 | `vgv-review-agent.md` |
| Code simplicity | 67 | `code-simplicity-review-agent.md` |
| Test quality | 42 | `test-quality-review-agent.md` |
| Architecture review | 40 | `architecture-review-agent.md` |
| PR readiness | 35 | `pr-readiness-review-agent.md` |
| Plan splitting | 24 | `plan-splitting-agent.md` |
| User-flow analysis | 2 | `user-flow-analysis-agent.md` |
| Codebase review | Referenced by workflow | `codebase-review-agent.md` |
| Official-docs research | Referenced by workflow | `official-docs-research-agent.md` |
| Best-practices research | Referenced by workflow | `best-practices-research-agent.md` |

Generic `general-purpose`, `Explore`, `Plan`, and unspecified Claude agents map
to bounded Codex subagent tasks, not invented registered agent types. Claude's
`ReportFindings` UI is replaced by a readable report and Codex file/line links.
The code-review port retains all eight angles and verifies candidates before
reporting; it does not impose a minimum finding count.

## Hooks and recurring workflow behavior

| Previous behavior | Codex implementation |
| --- | --- |
| Root Claude instructions | `AGENTS.md` is canonical; `CLAUDE.md` points to it |
| Tracking reminder on every prompt | `.codex/hooks.json` → `tool/codex/session_context.py` |
| Build/test context after compaction | Same hook on `SessionStart`, including `compact` |
| Format Dart after edits | `.codex/hooks.json` → `tool/codex/after_patch.py` for `apply_patch` |
| VGV post-edit analysis | Same hook analyzes the explicitly patched Dart files after formatting |
| CLI test/scaffold blockers | Removed from the Codex workflow; use the documented working commands |
| `.claude/launch.json` enclosure viewer | `$run`, using the existing output directory on localhost:8765 |
| Vibe Island notifications | Existing user-level Codex hooks already call the bridge with `--source codex` |
| Orca session/terminal coordination | Existing Orca skills; Codex task/terminal tools for Codex-owned tasks |
| Cross-session memory / claude-mem search | Private `$segno-context` index and historical references; narrow local history search |
| Fresh-context phase handoff | Explicit Codex task creation when requested, with artifact paths and accepted decisions |

The patch hook excludes paths outside this checkout, symlinks escaping it,
worktrees, build outputs, and vendored sources. It refuses to format a package
before dependency resolution and reports command failures. Shell writes and
non-patch tools still require explicit formatting and the full final checks in
`AGENTS.md`; the hook is not a replacement for CI.

## Tool connections

`.codex/config.toml` configures the existing Dart and Very Good CLI executables,
the local Fusion MCP endpoint, and Figma's remote MCP endpoint. The existing
user-level Pencil/Pen server is retained. No credentials are copied.

| Observed Claude tools | Codex route |
| --- | --- |
| Dart package search, package URIs, DTD (11 calls) | Dart MCP (`dart mcp-server`) |
| Very Good CLI templates, dependency/license tooling | Very Good CLI MCP (`very_good mcp`); ordinary CLI tests |
| Fusion (2,523 calls across two provider names) | `fusion` MCP; read `hardware/enclosure/FUSION_MODELS.md` |
| Pencil/Pen (1,448 calls) | Existing `pencil` MCP; `segno-ui.pen` remains the design source |
| Figma (582 calls) | `figma` MCP plus the migrated Figma skills |
| Claude Browser / Chrome tools | Installed Codex browser/computer-use tools; use their supported APIs |
| Native computer use (506 calls) | Depends on the current host's enabled surfaces; this task exposes browser control only |
| Claude session/directory management | Codex task tools, or Orca CLI for Orca-managed state |
| Visualize (15 calls) | Installed `visualize` skill |
| Canva remote design tools (31 calls) | Canva plugin is available but not connected; connection requested from the user |
| claude-mem search/observations (6 calls) | Private context notes and targeted historical transcript searches |

Do not claim a live edit, native UI interaction, or remote service works from a
configuration file alone. Figma completed Codex OAuth authorization during this migration. Fusion
completed a live handshake with its running add-in. Canva editing awaits its separate connection decision; native desktop control
is unavailable in this task.

## Historical items deliberately not revived

The saved memory records that `ponytail` and `i-have-adhd` were removed by the
user on 2026-07-22. Their prompts appear in older sessions; their behavior is
not restored. Other globally installed Claude skills with no project-specific
use evidence are not treated as requirements for this repository. Existing
Codex document, PDF, spreadsheet, presentation, browser, research and image
capabilities cover those general task categories when requested.

## Verified on this machine

- Codex runtime discovered all **41 personal skills** with no loading errors.
- All 41 skill entrypoints passed the Skill Creator validator.
- The private context skill preserves **81 memory files**; the role library
  contains all **10 VGV agent definitions**.
- Codex listed live tools for **Dart, Very Good CLI, Fusion, Pencil, and Figma**.
  Figma OAuth completed successfully, including `use_figma` and `create_new_file`.
- **Nine hook regression tests** passed. Real Dart formatting/analysis and
  Graphify's offline Dart extraction passed in temporary fixtures.
- Spell-check passed on all nine changed workflow/configuration files; Git's
  whitespace check passed.
- All three project hooks loaded without parse errors and remain **untrusted**
  pending the user's native Codex hook review. They do not run until trusted.
- The existing Vibe Island subagent-stop notification hook also awaits trust;
  the other existing Vibe Island hooks were already trusted.
- A `codex-hooks` CI job runs the regression suite on future pushes/PRs.

## Activation and verification

- Start a fresh Codex task after installing skills, or reload skill discovery.
- From this repository, open `/hooks` in Codex CLI and review/trust the three
  new hook definitions. Codex skips untrusted hooks; installation does not
  silently grant trust.
- Check `/mcp` or the desktop MCP settings after reloading the task. Figma is
  authenticated; future sign-ins use `codex mcp login figma`. Keep Fusion's
  add-in running when using its tools.
- Hook regression checks: `python3 -m unittest discover -s tool/codex/test -v`.
- Skill validation: the bundled Skill Creator `quick_validate.py` for each
  migrated skill. Runtime discovery is checked through Codex `skills/list`.

The migration's private file manifest and backups are kept under
`~/.codex/migrations/segno-2026-09-04/`, outside the repository. Application code
and pre-existing macOS/iOS changes are outside this migration.

The implementation follows the official documentation for
[skill discovery](https://learn.chatgpt.com/docs/build-skills),
[project instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md),
[hooks and trust](https://learn.chatgpt.com/docs/hooks), and
[MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
