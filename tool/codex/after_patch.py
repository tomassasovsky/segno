#!/usr/bin/env python3
"""Format and analyze Dart files named by a successful Codex patch."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def dart_files(event, root):
    """Resolve only touched, existing Dart files inside this checkout."""
    if event.get('tool_name') != 'apply_patch':
        return []
    patch = event.get('tool_input', {}).get('command', '')
    candidates = []
    for line in patch.splitlines():
        for prefix in ('*** Add File: ', '*** Update File: ', '*** Move to: '):
            if line.startswith(prefix):
                candidates.append(line[len(prefix):])
                break
    cwd = Path(event.get('cwd', root)).resolve()
    files = set()
    for candidate in candidates:
        path = (cwd / candidate).resolve()
        try:
            relative = path.relative_to(root)
        except ValueError:
            continue
        if any(part in {'.claude', '.codex', '.git', '.dart_tool', 'build', 'third_party'}
               for part in relative.parts):
            continue
        nested_checkout = False
        for parent in path.parents:
            if parent == root:
                break
            if (parent / '.git').exists():
                nested_checkout = True
                break
        if nested_checkout:
            continue
        if path.suffix == '.dart' and path.is_file():
            files.add(path)
    return sorted(files)


def package_root(path, root):
    for parent in path.parents:
        if (parent / 'pubspec.yaml').is_file():
            return parent
        if parent == root:
            break
    return None


def check_files(files, root):
    dart = shutil.which('dart')
    if not dart:
        return ['Dart SDK is unavailable; format and analyze the edited files before completion.']
    notes = []
    deadline = time.monotonic() + 45
    for path in files:
        package = package_root(path, root)
        if package is None:
            notes.append(f'No package found for {path}; verify it manually.')
            continue
        if not (package / '.dart_tool/package_config.json').is_file():
            notes.append(f'Resolve dependencies in {package} before formatting {path.name}.')
            continue
        # A formatter failure is visible and does not trigger a destructive retry.
        for args in ([dart, 'format', str(path)], [dart, 'analyze', str(path)]):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                notes.append('Post-patch time budget reached; finish formatting and analysis explicitly.')
                return notes
            try:
                result = subprocess.run(args, cwd=package, text=True,
                                        capture_output=True, timeout=min(20, remaining))
            except (OSError, subprocess.TimeoutExpired) as error:
                notes.append(f'{args[1]} did not complete for {path}: {error}')
                break
            if result.returncode:
                output = (result.stdout + result.stderr)[-4000:]
                notes.append(f'{args[1]} failed for {path}:\n{output}')
                break
    return notes


def main():
    event = json.load(sys.stdin)
    if event.get('hook_event_name') != 'PostToolUse':
        return
    root = Path(__file__).resolve().parents[2]
    files = dart_files(event, root)
    if not files:
        return
    notes = check_files(files, root)
    context = ('Formatted and analyzed patched Dart files: ' +
               ', '.join(str(path.relative_to(root)) for path in files))
    if notes:
        context = 'Dart post-patch checks need attention:\n' + '\n'.join(notes)
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'PostToolUse', 'additionalContext': context,
    }}))


if __name__ == '__main__':
    main()
