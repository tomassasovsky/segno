"""Build or verify the explicit design/context transfer snapshot; no Git writes."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[3]
PACK = Path(__file__).resolve().parent
MANIFEST = PACK / 'transfer-manifest.json'
DIRECTORIES = (
    'docs/design', 'docs/research/segno-looper-x-comparison',
    'docs/brainstorm', 'docs/plan', 'docs/reviews', 'docs/roadmap',
    'docs/handoff/segno-app',
)
FILES = (
    'AGENTS.md', 'CLAUDE.md', 'segno-ui.pen', 'docs/PROGRESS.md',
    'docs/TRACKING.md', 'docs/CODEX_WORKFLOWS.md',
    'hardware/enclosure/FUSION_MODELS.md',
)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def links():
    errors = []
    for document in PACK.glob('*.md'):
        for target in re.findall(r'\]\(([^)]+)\)', document.read_text()):
            target = unquote(target.split('#', 1)[0].strip('<>'))
            if not target or re.match(r'^[a-zA-Z]+:', target):
                continue
            if not (document.parent / target).exists():
                errors.append(f'{document.name}: missing link {target}')
    return errors


def build():
    paths = {ROOT / name for name in FILES}
    for directory in DIRECTORIES:
        paths.update(p for p in (ROOT / directory).rglob('*') if p.is_file())
    paths.discard(MANIFEST)
    paths = {p for p in paths if not any(part in ('__pycache__', '.DS_Store') for part in p.parts)}
    for path in paths:
        if path.is_symlink():
            raise ValueError(f'Review symlink before transfer: {path.relative_to(ROOT)}')
    entries = [{'path':str(p.relative_to(ROOT)), 'bytes':p.stat().st_size, 'sha256':digest(p)}
               for p in sorted(paths)]
    data = {
        'scope':'Design and context snapshot; production source comes from the repository, not this manifest.',
        'baseRevision':subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'excluded':'Unrelated dirty application changes, other worktrees, local runtimes and machine state. Manifest itself is excluded from hashing.',
        'files':entries,
    }
    MANIFEST.write_text(json.dumps(data, indent=2) + '\n')
    print(f'Wrote {len(entries)} paths, {sum(e["bytes"] for e in entries):,} bytes')


def verify():
    data = json.loads(MANIFEST.read_text())
    errors = links()
    for item in data['files']:
        path = ROOT / item['path']
        if not path.is_file():
            errors.append(f'Missing: {item["path"]}')
        elif path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            errors.append(f'Changed: {item["path"]}')
    if errors:
        raise ValueError('\n'.join(errors))
    print(f'PASS: {len(data["files"])} file hashes and handoff Markdown links')


if __name__ == '__main__':
    try:
        if '--write' in sys.argv:
            build()
        verify()
    except (OSError, ValueError, KeyError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
