"""Canonical task-review evidence reader shared by CLI and GUI.

Completion is structural evidence, not an attestation of truth or quality.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


def metadata(path: Path, key: str) -> str:
    result = subprocess.run(['git', 'config', '--file', str(path / 'metadata.gitconfig'),
                             '--get', 'paw.' + key], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ''


def visible_review(text: str) -> str:
    """Ignore Markdown examples and comments when reading completion evidence."""
    text = re.sub(r'<!--.*?(?:-->|\Z)', '', text, flags=re.S)
    result, fence = [], ''
    for line in text.splitlines():
        match = re.match(r'^ {0,3}(`{3,}|~{3,})', line)
        if fence:
            if match and match[1][0] == fence[0] and len(match[1]) >= len(fence):
                fence = ''
            continue
        if match:
            fence = match[1]
        else:
            result.append(line)
    return '\n'.join(result) + '\n'


def section(text: str, name: str) -> str:
    match = re.search(r'^## ' + re.escape(name) + r'[ \t]*\n(.*?)(?=^## |\Z)', visible_review(text), re.M | re.S)
    return match[1] if match else ''


def fields(text: str) -> dict[str, str]:
    pairs = re.findall(r'^\s*[-*]\s+([^:\n]+):\s*([^\n]*)', section(text, 'Review Metadata'), re.M)
    result = {}
    for key, value in pairs:
        key = key.lower()
        # Duplicate identities or completion assertions are ambiguous.
        result[key] = value.strip() if key not in result else ''
    return result


def normalized_grade(value: str) -> str:
    candidate = value.strip().removesuffix('.').rstrip()
    for wrapper in ('**', '__', '*', '_', '`'):
        if candidate.startswith(wrapper) and candidate.endswith(wrapper):
            candidate = candidate[len(wrapper):-len(wrapper)].strip()
            break
    return candidate.upper() if re.fullmatch(r'[ABCDFabcdf][+-]?', candidate) else ''


def grade_rank(value: str) -> int:
    token = normalized_grade(value)
    base = {'A': 12, 'B': 9, 'C': 6, 'D': 3, 'F': 0}[token[0]]
    return base + (1 if token.endswith('+') and token[0] != 'A' else -1 if token.endswith('-') else 0)


def resolved(value: str) -> bool:
    return bool(value.strip()) and not re.search(r'\b(pending|unknown|tbd|not assessed|not-assessed)\b|<[^>]+>', value, re.I)


def incomplete_reason(text: str, task_name: str) -> str:
    # Review templates use top-level metadata, never quoted/fenced examples.
    text = visible_review(text)
    for name in ('Review Metadata', 'Blocking Production-Readiness Issues'):
        if len(re.findall(r'^## ' + re.escape(name) + r'[ \t]*$', text, re.M)) != 1:
            return 'review needs exactly one ' + name + ' section'
    data = fields(text)
    if data.get('task', '').strip('`') != task_name:
        return 'Review Metadata Task must match ' + task_name
    for key in ('scope reviewed', 'quality threshold', 'threshold result'):
        if not resolved(data.get(key, '')):
            return 'Review Metadata needs resolved ' + key
    if not re.search(r'(?<![A-Za-z])[ABCDF][+-]?(?![A-Za-z])', data['quality threshold']):
        return 'Review Metadata Quality Threshold must name a recognized grade'
    if not re.match(r'(?:met|meets|not met|does not meet|below|above|exceeds|passed|failed)\b', data['threshold result'], re.I):
        return 'Review Metadata Threshold Result must explicitly say met or below/not met'
    if not normalized_grade(data.get('grade', '')):
        return 'Review Metadata needs a recognized Grade'
    threshold = re.search(r'(?<![A-Za-z])([ABCDF][+-]?)(?![A-Za-z])', data['quality threshold'])[1]
    if re.match(r'(?:met|meets|above|exceeds|passed)\b', data['threshold result'], re.I):
        if grade_rank(data['grade']) < grade_rank(threshold):
            return 'Threshold Result claims success below the stated grade threshold'
    blockers = section(text, 'Blocking Production-Readiness Issues').strip()
    if not resolved(blockers):
        return 'Blocking Production-Readiness Issues must explicitly list blockers or None'
    if data.get('quality policy version'):
        for key in ('attempt', 'reviewed code', 'completion'):
            if not resolved(data.get(key, '')):
                return 'Review Metadata needs resolved ' + key
        if data['completion'].lower() != 'complete':
            return 'Review Metadata Completion must be complete'
    return ''


def stale(path: Path, read_config=None) -> bool:
    try:
        read_config = read_config or config_value
        if not read_config(path / 'metadata.gitconfig', 'prototype-status').startswith('planned'):
            return False
        runs = [run.stat().st_mtime for run in (path / 'runs').glob('*.gitconfig')
                if read_config(run, 'subcommand') == 'prototype' and read_config(run, 'status') == 'complete']
        meta = path / 'metadata.gitconfig'
        planned = max(runs, default=meta.stat().st_mtime if meta.exists() else 0)
        return (path / 'review.md').stat().st_mtime <= planned
    except OSError:
        return True  # A disappearing record must never authorize an action.


def config_value(file: Path, key: str) -> str:
    result = subprocess.run(['git', 'config', '--file', str(file), '--get', 'paw.' + key],
                            capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ''


def check(path: Path, task_name: str, *, check_stale=True) -> str:
    try:
        text = (path / 'review.md').read_text()
        reason = incomplete_reason(text, task_name)
        if not reason and check_stale and stale(path):
            reason = 'review.md predates the replacement plan'
        marker = path / '.review-attempt'
        if not reason and marker.exists():
            attempt, state = marker.read_text().strip().split('\t')
            if fields(text).get('attempt') != attempt or state != 'complete':
                reason = 'latest review attempt did not complete successfully'
        return reason
    except (OSError, UnicodeError, ValueError) as error:
        return f'cannot read complete review.md: {error}'


def code_identity(repo: Path) -> str:
    head = subprocess.run(['git', '-C', str(repo), 'rev-parse', 'HEAD'], capture_output=True).stdout.strip().decode() or 'unborn'
    diff = subprocess.run(['git', '-C', str(repo), 'diff', 'HEAD', '--binary'], capture_output=True).stdout
    digest = hashlib.sha256(diff)
    untracked = subprocess.run(['git', '-C', str(repo), 'ls-files', '--others', '--exclude-standard', '-z'], capture_output=True).stdout
    for raw in sorted(untracked.split(b'\0')):
        if not raw or raw.startswith(b'.agent/'):
            continue
        file = repo / os.fsdecode(raw)
        digest.update(raw + b'\0')
        digest.update(os.fsencode(os.readlink(file)) if file.is_symlink() else file.read_bytes())
    return f'{head}; worktree-sha256={digest.hexdigest()} (tracked diff and untracked file bytes; excludes .agent)'



def render_seed(template: Path, task_name: str, attempt: str, repo: Path) -> str:
    """Validate only new seed resources; historical completion rules stay unchanged."""
    try:
        text = template.read_text(encoding='utf-8')
    except (OSError, UnicodeError) as error:
        raise ValueError(f'{template}: expected readable UTF-8 review template: {error}') from error
    slots = {'task': '{{TASK}}', 'attempt': '{{ATTEMPT}}',
             'reviewed code': '{{REVIEWED_CODE}}', 'quality policy version': '{{QUALITY_POLICY_VERSION}}'}
    data = fields(text)
    for key, token in slots.items():
        if data.get(key, '').strip('`') != token:
            raise ValueError(f'{template}: expected Review Metadata {key}: {token}')
    for key in ('completion', 'scope reviewed', 'grade', 'quality threshold', 'threshold result'):
        if data.get(key) != 'pending':
            raise ValueError(f'{template}: expected Review Metadata {key}: pending')
    for name in ('Review Metadata', 'Summary', 'Blocking Production-Readiness Issues',
                 'Validation and Evidence', 'Architectural / Design Choices',
                 'Improvement Opportunities', 'Recommendations'):
        headings = re.findall(r'^## ' + re.escape(name) + r'[ \t]*$', visible_review(text), re.M)
        if len(headings) != 1 or not section(text, name).strip():
            raise ValueError(f'{template}: expected exactly one nonempty {name} section')
    values = {'TASK': task_name, 'ATTEMPT': attempt,
              'REVIEWED_CODE': code_identity(repo), 'QUALITY_POLICY_VERSION': '1'}
    if any(token not in values for token in re.findall(r'\{\{(.*?)\}\}', text)):
        raise ValueError(f'{template}: expected only supported runtime slots')
    return re.sub(r'\{\{([A-Z_]+)\}\}', lambda match: values[match[1]], text)


def begin(path: Path, task_name: str, repo: Path, template: Path | None = None) -> None:
    template = template if template is not None else Path(__file__).resolve().parents[2] / 'templates/review.md'
    attempt = uuid.uuid4().hex
    text = render_seed(template, task_name, attempt, repo)
    review = path / 'review.md'
    if review.exists():
        # Preserve all attempts, including incomplete legacy notes; never truncate first.
        history = path / 'review-history'
        history.mkdir(exist_ok=True)
        with (history / (uuid.uuid4().hex + '.md')).open('xb') as output:
            output.write(review.read_bytes())
            output.flush()
            os.fsync(output.fileno())
    (path / '.review-attempt').write_text(attempt + '\trunning\n')
    with tempfile.NamedTemporaryFile(mode='w', dir=path, delete=False) as output:
        output.write(text)
    os.replace(output.name, review)


def finish(path: Path, task_name: str) -> None:
    text = (path / 'review.md').read_text()
    reason = incomplete_reason(text, task_name)
    attempt, state = (path / '.review-attempt').read_text().strip().split('\t')
    if reason or fields(text).get('quality policy version') != '1' or fields(text).get('attempt') != attempt or state != 'running':
        raise ValueError(reason or 'review attempt identity does not match')
    (path / '.review-attempt').write_text(attempt + '\tcomplete\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['check', 'begin', 'finish'])
    parser.add_argument('path', type=Path)
    parser.add_argument('task')
    parser.add_argument('repo', type=Path, nargs='?', default=Path.cwd())
    parser.add_argument('--template', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'begin':
            begin(args.path, args.task, args.repo, args.template)
        elif args.action == 'finish':
            finish(args.path, args.task)
        else:
            reason = check(args.path, args.task)
            if reason:
                raise ValueError(reason)
    except (OSError, ValueError) as error:
        print(f'Incomplete review: {error}. Run Review again: paw review {args.task}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
