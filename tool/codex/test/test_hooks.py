"""Exercise hook payloads and real formatter/analyzer subprocess boundaries."""
# cspell:words gitdir
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HOOK_DIR = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('after_patch', HOOK_DIR / 'after_patch.py')
after_patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(after_patch)


class HookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'lib').mkdir()
        (self.root / 'pubspec.yaml').write_text('name: hook_fixture\n')
        self.source = self.root / 'lib/with spaces.dart'
        self.source.write_text('void main() {}\n')

    def event(self, command, cwd=None):
        return {'hook_event_name': 'PostToolUse', 'tool_name': 'apply_patch',
                'cwd': str(cwd or self.root), 'tool_input': {'command': command}}

    def test_patch_paths_include_add_update_move_and_deduplicate(self):
        command = '\n'.join(['*** Begin Patch', '*** Add File: lib/with spaces.dart',
                             '*** Update File: lib/with spaces.dart',
                             '*** Move to: lib/with spaces.dart', '*** End Patch'])
        self.assertEqual(after_patch.dart_files(self.event(command), self.root), [self.source])

    def test_subdirectory_and_absolute_paths(self):
        event = self.event('*** Update File: with spaces.dart', self.root / 'lib')
        self.assertEqual(after_patch.dart_files(event, self.root), [self.source])
        event = self.event(f'*** Update File: {self.source}')
        self.assertEqual(after_patch.dart_files(event, self.root), [self.source])

    def test_deletions_missing_files_and_non_dart_are_ignored(self):
        event = self.event('*** Delete File: lib/with spaces.dart\n'
                           '*** Add File: missing.dart\n*** Update File: pubspec.yaml')
        self.assertEqual(after_patch.dart_files(event, self.root), [])

    def test_outside_symlinks_and_nested_worktrees_are_ignored(self):
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / 'outside.dart'
            target.write_text('void main() {}')
            (self.root / 'lib/link.dart').symlink_to(target)
            worktree = self.root / '.claude/worktrees/another/lib'
            worktree.mkdir(parents=True)
            (worktree / 'other.dart').write_text('void main() {}')
            event = self.event(f'*** Update File: {target}\n'
                               '*** Update File: lib/link.dart\n'
                               '*** Update File: .claude/worktrees/another/lib/other.dart')
            self.assertEqual(after_patch.dart_files(event, self.root), [])

    def test_unresolved_dependencies_do_not_run_formatter(self):
        with patch.object(after_patch.shutil, 'which', return_value='/fake/dart'), \
                patch.object(after_patch.subprocess, 'run') as run:
            notes = after_patch.check_files([self.source], self.root)
        run.assert_not_called()
        self.assertIn('Resolve dependencies', notes[0])

    def test_nested_git_checkout_is_not_formatted(self):
        nested = self.root / 'another checkout'
        nested.mkdir()
        (nested / '.git').write_text('gitdir: /elsewhere\n')
        (nested / 'app.dart').write_text('void main() {}')
        event = self.event('*** Update File: another checkout/app.dart')
        self.assertEqual(after_patch.dart_files(event, self.root), [])

    def install_fake_dart(self, fail=False):
        (self.root / '.dart_tool').mkdir()
        (self.root / '.dart_tool/package_config.json').write_text('{}')
        binary = self.root / 'bin'
        binary.mkdir()
        dart = binary / 'dart'
        dart.write_text(f'#!{sys.executable}\n'
                        'import json, os, sys\n'
                        'with open(os.environ["DART_CALL_LOG"], "a") as out:\n'
                        ' out.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                        + ('print("format failed"); sys.exit(1)\n' if fail else ''))
        dart.chmod(0o755)
        log = self.root / 'calls.jsonl'
        return {'PATH': str(binary), 'DART_CALL_LOG': str(log)}, log

    def test_format_then_analyze_preserves_space_in_filename(self):
        env, log = self.install_fake_dart()
        with patch.dict(os.environ, env):
            self.assertEqual(after_patch.check_files([self.source], self.root), [])
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(calls, [['format', str(self.source)], ['analyze', str(self.source)]])

    def test_failed_format_is_reported_and_analysis_does_not_run(self):
        env, log = self.install_fake_dart(fail=True)
        with patch.dict(os.environ, env):
            notes = after_patch.check_files([self.source], self.root)
        self.assertIn('format failed', notes[0])
        self.assertEqual(len(log.read_text().splitlines()), 1)

    def test_context_supports_start_compaction_and_prompt_payloads(self):
        for name, source in [('SessionStart', 'startup'), ('SessionStart', 'compact'),
                             ('UserPromptSubmit', None)]:
            with self.subTest(name=name, source=source):
                result = subprocess.run([sys.executable, str(HOOK_DIR / 'session_context.py')],
                                        input=json.dumps({'hook_event_name': name, 'source': source}),
                                        text=True, capture_output=True, check=True)
                output = json.loads(result.stdout)['hookSpecificOutput']
                self.assertEqual(output['hookEventName'], name)
                self.assertTrue(output['additionalContext'])


if __name__ == '__main__':
    unittest.main()
