#!/usr/bin/env python3
"""Restore the small, durable project contract on session start/compaction."""
import json
import sys


def main():
    event = json.load(sys.stdin)
    name = event.get('hook_event_name')
    if name not in {'SessionStart', 'UserPromptSubmit'}:
        return
    context = (
        'Segno: read AGENTS.md and docs/PROGRESS.md "How to build / test". '
        'Use docs/TRACKING.md for issue/stage/autonomy and merge gates. '
        'Use $segno-context for relevant private history and $code-review for '
        'the bug-focused PR gate. CI and review must both pass on the current '
        'head before ready-to-merge. Preserve authorization already given. '
        'Resolve dependencies before formatting and target explicit Dart paths; '
        'never recursively format the repository root or nested worktrees. '
        'Dart tests: /Users/Tomas/development/flutter/bin/flutter test. '
        'Native tests: bash packages/segno_engine/src/test/run_native_tests.sh. '
        'FFI header edits require regeneration and formatting of bindings. '
        'Full workflow index: docs/CODEX_WORKFLOWS.md.'
    )
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': name, 'additionalContext': context,
    }}))


if __name__ == '__main__':
    main()
