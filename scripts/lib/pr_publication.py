"""Reviewed task contribution policy shared by the CLI and local dashboard."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import difflib
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile

import re
from pathlib import Path

import review_record as review


def eligibility(task: Path, repo: Path, *, read_config=review.config_value) -> str:
    """Fail closed without changing the review/prototype consumers' thresholds."""
    try:
        plan = (task / 'plan.md').read_text()
        visible = review.visible_review(plan)
        if re.search(r'USER ANSWER\s+\((?:UNRESOLVED|PROVIDED)\):', plan):
            return 'Reconcile pending answers with paw edit first.'
        if len(re.findall(r'^## Current Status\s*$', visible, re.M)) != 1:
            return 'plan.md needs exactly one Current Status section.'
        status = review.section(plan, 'Current Status')
        for label, expected in [('Estimated completion', '100%'), ('Next work', 'Review.')]:
            values = re.findall(r'^- ' + label + r': (.*)$', status, re.M)
            if len(values) != 1 or (values[0] != expected if label == 'Estimated completion' else not values[0].startswith(expected)):
                return 'Complete implementation and final validation before publication.'
        if re.search(r'^\s*- \[ \]', visible, re.M):
            return 'plan.md still has unfinished checklist items.'
        for run in (task / 'runs').glob('*.gitconfig'):
            if read_config(run, 'status') == 'running':
                return 'A PAW run is active; finish or reconcile its run record first.'
            if read_config(run, 'subcommand') in {'implement', 'diagnose', 'prototype'} and run.stat().st_mtime_ns > (task / 'review.md').stat().st_mtime_ns:
                return 'A newer implementation/diagnose/replacement run invalidated this review; run Review again.'
        reason = review.check(task, task.name, check_stale=False)
        if not reason and review.stale(task, read_config):
            reason = 'review.md predates the replacement plan'
        if reason:
            return 'Run Review again: ' + reason
        text = (task / 'review.md').read_text()
        data = review.fields(text)
        if review.grade_rank(data['grade']) < review.grade_rank('A-'):
            return 'Publication requires independent review grade A- or higher.'
        if not re.fullmatch(r'(?:- )?None\.?', review.section(text, 'Blocking Production-Readiness Issues').strip(), re.I):
            return 'Review must explicitly record no production blockers: None.'
        if data.get('completion', '').lower() != 'complete' or not (task / '.review-attempt').is_file():
            return 'Legacy review lacks completed attempt evidence; run Review again.'
        if data.get('reviewed code') != review.code_identity(repo):
            return 'Reviewed code differs from this worktree; run Review again.'
        return ''
    except (OSError, UnicodeError, ValueError, KeyError) as error:
        return f'Cannot establish publication eligibility: {error}'


def contribution(task: Path, identity: str) -> str:
    """Explicit task-scoped content prevents publishing an entire shared plan body."""
    text = (task / 'plan.md').read_text()
    content = review.section(text, 'PR Contribution').strip()
    for label in ('Outcome', 'Validation', 'Risks', 'Visual'):
        values = re.findall(r'^- ' + label + r': (.+)$', content, re.M)
        if len(values) != 1 or not review.resolved(values[0]) or re.search(r'\b(?:TODO|placeholder|planned|not implemented)\b', values[0], re.I):
            raise ValueError(f'{task / "plan.md"}: add one concrete - {label}: field under ## PR Contribution; only describe this reviewed task.')
    grade = review.fields((task / 'review.md').read_text())['grade']
    return f'<!-- PAW:CONTRIBUTION {identity} -->\n## Task: {task.name}\n\n{content}\n- Independent review: {grade}; no production blockers.\n<!-- /PAW:CONTRIBUTION {identity} -->'


def merge_contribution(body: str, block: str, identity: str) -> str:
    start, end = f'<!-- PAW:CONTRIBUTION {identity} -->', f'<!-- /PAW:CONTRIBUTION {identity} -->'
    if body.count(start) != body.count(end) or body.count(start) > 1:
        raise ValueError('Ambiguous managed contribution boundaries; repair the body before preview.')
    if start in body:
        before, rest = body.split(start)
        _, after = rest.split(end)
        return before + block + after
    return body + ('\n\n' if body else '') + block + '\n'


def visual_check(body: str, image_exists=lambda path: False) -> str:
    """Validate structural visual evidence; Review owns relevance and rendering."""
    body = re.sub(r'<!--.*?(?:-->|\Z)', '', body, flags=re.S)
    lines = body.splitlines()
    fence, language, content, explanation = '', '', [], ''
    for line in lines:
        match = re.match(r'^ {0,3}(`{3,}|~{3,})([^\n]*)$', line)
        if fence:
            if match and match[1][0] == fence[0] and len(match[1]) >= len(fence) and not match[2].strip():
                diagram = '\n'.join(content).strip()
                if language == 'mermaid' and re.match(r'^(?:flowchart|graph|sequenceDiagram|stateDiagram(?:-v2)?|classDiagram|erDiagram|journey|gantt)\b', diagram) and len(content) >= 2 and meaningful(explanation) and not re.search(r'\b(?:TODO|placeholder|example)\b|<[^>]+>', diagram, re.I):
                    return ''
                fence, language, content = '', '', []
            else:
                content.append(line)
            continue
        if match:
            fence, language, content = match[1], match[2].strip(), []
            continue
        image = re.fullmatch(r'!\[([^\]]+)\]\(([^\s)]+)\)', line.strip()) if not line.startswith(('    ', '\t', '>')) else None
        if image and meaningful(explanation) and meaningful(image[1]):
            from urllib.parse import urlparse, unquote
            url = urlparse(image[2])
            path = unquote(url.path)
            if re.search(r'badge|shields\.io|placeholder|example\.(?:com|org)|<|>', image[0], re.I):
                continue
            if url.scheme == 'https' and url.hostname and not url.username and not url.password:
                return ''
            if not url.scheme and not url.netloc and not path.startswith('/') and '..' not in Path(path).parts and image_exists(path.removeprefix('./')):
                return ''
        if line.strip():
            explanation = line.strip()
    return 'Add a relevant Mermaid fence or GitHub-usable screenshot, preceded by a short explanation; Review must inspect relevance/rendering. Repository images must exist in the published head.'


def meaningful(text: str) -> bool:
    return len(text.split()) >= 3 and not re.search(r'\b(?:TODO|placeholder|example|pending)\b|<[^>]+>', text, re.I)




LIB = Path(__file__).resolve().parent


def command(repo: Path, *args: str) -> str:
    try:
        result = subprocess.run(args, cwd=repo, capture_output=True, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError(f'{args[0]} unavailable or timed out: {error}') from error
    if result.returncode:
        raise ValueError(f'{" ".join(args[:3])} failed: {result.stderr.strip() or result.stdout.strip()}')
    return result.stdout.strip()


def store_call(repo: Path, function: str, *args: str) -> str:
    return command(repo, 'bash', '-c', 'source "$1/task_store.sh"; shift; "$@"', 'paw-publication', str(LIB), function, str(repo), *args)


def atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as out:
        temporary = Path(out.name)
        try:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def assignment(task: Path, repo: Path) -> tuple[Path, str]:
    common = Path(command(repo, 'git', 'rev-parse', '--path-format=absolute', '--git-common-dir')).resolve()
    meta = task / 'metadata.gitconfig'
    if not meta.is_file():
        meta = common / 'paw-task-assignments' / (task.name + '.gitconfig')
    saved = {key: review.config_value(meta, key) for key in ('worktree-path', 'git-common-dir', 'branch-name', 'head-state')}
    if not all(saved.values()) or saved['head-state'] != 'branch' or Path(saved['git-common-dir']).resolve() != common:
        raise ValueError(f'{meta}: missing or mismatched saved repository/branch/worktree assignment; reconcile before publication.')
    worktree = Path(saved['worktree-path']).resolve()
    registered = command(repo, 'git', 'worktree', 'list', '--porcelain')
    if f'worktree {worktree}\n' not in registered + '\n':
        raise ValueError('Saved worktree no longer registered; reconcile assignment.')
    if command(worktree, 'git', 'symbolic-ref', '--short', 'HEAD') != saved['branch-name']:
        raise ValueError('Saved branch is not checked out in its worktree; return manually and retry. PAW never switches branches.')
    return worktree, saved['branch-name']


def body_file(task: Path, repo: Path) -> Path:
    canonical = Path(store_call(repo, 'paw_task_branch_pr_body_file', str(task)))
    if canonical.is_file():
        return canonical
    if (task / 'pr.md').is_file():
        return task / 'pr.md'
    raise ValueError(f'{canonical}: branch PR body is required (legacy task pr.md fallback).')


@contextmanager
def branch_lock(repo: Path, branch: str):
    common = Path(command(repo, 'git', 'rev-parse', '--path-format=absolute', '--git-common-dir'))
    directory = common / 'paw-publication'
    directory.mkdir(exist_ok=True)
    with (directory / (digest(branch) + '.lock')).open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError('Another PAW publication is active on this branch; retry after it finishes.') from error
        yield directory


def remote_identity(repo: Path, branch: str) -> dict:
    repository = json.loads(command(repo, 'gh', 'repo', 'view', '--json', 'nameWithOwner'))['nameWithOwner']
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', repository):
        raise ValueError('gh returned invalid repository identity.')
    remote = command(repo, 'git', 'config', '--get', 'branch.' + branch + '.remote')
    merge = command(repo, 'git', 'config', '--get', 'branch.' + branch + '.merge')
    if remote == '.' or merge != 'refs/heads/' + branch:
        raise ValueError('Tracking mismatch: configure the exact remote head branch manually before publication.')
    remote_url = command(repo, 'git', 'remote', 'get-url', remote)
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?', remote_url)
    if not match:
        raise ValueError('Cannot establish GitHub remote head identity from ' + remote_url)
    head_repo = match[1]
    refs = command(repo, 'git', 'ls-remote', '--heads', remote, 'refs/heads/' + branch).splitlines()
    if len(refs) != 1 or refs[0].split()[1:] != ['refs/heads/' + branch]:
        raise ValueError('Remote branch is absent or ambiguous. Commit and push manually, then preview again.')
    sha = refs[0].split()[0]
    if not re.fullmatch(r'[a-f0-9]{40,64}', sha):
        raise ValueError('Invalid remote head SHA.')
    head = head_repo.split('/')[0] + ':' + branch
    return {'repository': repository, 'head_repository': head_repo, 'head': head, 'branch': branch, 'sha': sha}


def lookup(repo: Path, target: dict) -> dict | None:
    results = json.loads(command(repo, 'gh', 'pr', 'list', '--repo', target['repository'], '--head', target['branch'], '--state', 'open', '--limit', '100', '--json', 'number,url,body,headRefName,headRepository,headRepositoryOwner'))
    if not isinstance(results, list):
        raise ValueError('PR lookup returned malformed results; no creation attempted.')
    if len(results) >= 100:
        raise ValueError('PR lookup reached its result limit; narrow/reconcile branch matches before publication.')
    matches = []
    for result in results:
        head_repo = result.get('headRepository', {})
        owner = result.get('headRepositoryOwner', {}).get('login', '')
        if result.get('headRefName') != target['branch'] or not owner or not head_repo.get('name'):
            raise ValueError('PR lookup returned mismatched or incomplete repository/head identity.')
        if owner + '/' + head_repo['name'] != target['head_repository']:
            continue  # gh list filters branch only; unrelated forks are not matches.
        validate_url(result.get('url', ''), target['repository'])
        matches.append(result)
    if len(matches) > 1:
        raise ValueError('Multiple open PRs match this branch; reconcile before publication.')
    return matches[0] if matches else None


def validate_url(url: str, repository: str) -> str:
    if not re.fullmatch('https://github.com/' + re.escape(repository) + r'/pull/[1-9][0-9]*', url):
        raise ValueError('gh returned an invalid PR link: ' + url)
    return url


def task_identity(task: Path, repo: Path) -> str:
    # Birth identity distinguishes a reused task name from its archived predecessor.
    birth = review.metadata(task, 'created-at') or str(task.stat().st_birthtime if hasattr(task.stat(), 'st_birthtime') else task.stat().st_ino)
    common = command(repo, 'git', 'rev-parse', '--path-format=absolute', '--git-common-dir')
    return digest(common + '\0' + str(task.resolve()) + '\0' + birth)


def snapshot(task: Path, repo: Path, body: Path) -> str:
    chunks = [str(task.resolve()), str(body), body.read_text(), review.code_identity(repo)]
    for file in ('plan.md', 'review.md', '.review-attempt', 'metadata.gitconfig'):
        path = task / file
        chunks.append(path.read_text() if path.exists() else '')
    for run in sorted((task / 'runs').glob('*.gitconfig')):
        chunks.extend([str(run), run.read_text()])
    return digest('\0'.join(chunks))


def image_in_head(repo: Path, target: dict, path: str) -> bool:
    # Ask GitHub for the actual published head, never accept an untracked local file.
    from urllib.parse import quote
    try:
        data = json.loads(command(repo, 'gh', 'api', f'repos/{target["head_repository"]}/contents/{quote(path, safe="/")}?ref={target["sha"]}'))
        return data.get('type') == 'file' and Path(path).suffix.lower() in {'.png', '.jpg', '.jpeg', '.gif', '.webp'}
    except (ValueError, AttributeError):
        return False


def prepare(task: Path, repo: Path, *, create_only=False) -> dict:
    repo, branch = assignment(task, repo)
    with branch_lock(repo, branch):
        reason = eligibility(task, repo)
        if reason:
            raise ValueError(reason)
        body = body_file(task, repo)
        original = body.read_text()
        target = remote_identity(repo, branch)
        current = lookup(repo, target)
        if current and create_only:
            raise ValueError('An open PR already exists; use paw pr-update ' + task.name)
        identity = task_identity(task, repo)
        block = contribution(task, identity)
        # Never adopt unmarked local prose automatically. Only selected reviewed content
        # enters a new PR; an existing PR retains all human text verbatim.
        candidate = merge_contribution(current['body'] if current else '', block, identity)
        local = merge_contribution(original, block, identity)
        # Shared visuals must live outside another task's managed claim. Carry the
        # explicit branch Visual Evidence section only, and preview every byte.
        visual = raw_section(original, 'Visual Evidence')
        if visual and visual not in candidate:
            candidate += '\n\n## Visual Evidence\n\n' + visual + '\n'
        diagnostic = visual_check(candidate, lambda path: image_in_head(repo, target, path))
        if diagnostic:
            raise ValueError(diagnostic + ' Put branch-level evidence under ## Visual Evidence in ' + str(body))
        if command(repo, 'git', 'rev-parse', 'HEAD') != target['sha']:
            raise ValueError('Local HEAD is not the published remote head. Commit/push manually, then preview again.')
        dirty = command(repo, 'git', 'status', '--porcelain')
        code_status = ('Local uncommitted changes are NOT in the PR. Commit/push manually; this action only publishes the body.' if dirty else 'Local HEAD matches the remote branch. This action only publishes the body.')
        result = {'task': str(task.resolve()), 'repo': str(repo), 'branch': branch, 'body_file': str(body),
                  'snapshot': snapshot(task, repo, body), 'target': target, 'current': current,
                  'candidate': candidate, 'local': local, 'original': original, 'review_identity': digest((task / 'review.md').read_text()), 'identity': identity, 'create_only': create_only,
                  'code_status': code_status, 'visual': 'Structural visual check passed; independently verify relevance and rendering.',
                  'adoption': 'Unmarked local prose is preserved locally and excluded from publication. Review the complete candidate and diff.',
                  'diff': ''.join(difflib.unified_diff((current['body'] if current else '').splitlines(True), candidate.splitlines(True), fromfile='remote PR body', tofile='candidate'))}
        token = digest(json.dumps(result, sort_keys=True))
        result['token'] = token
        atomic(task / 'publication-preview.json', json.dumps(result, indent=2))
        return result


def raw_section(text: str, heading: str) -> str:
    # Managed claims can follow a visual section; their opening comment precedes
    # the next heading and must never become part of the shared visual.
    text = re.sub(r'<!-- PAW:CONTRIBUTION ([A-Za-z0-9_-]+) -->.*?<!-- /PAW:CONTRIBUTION \1 -->', '', text, flags=re.S)
    match = re.search(r'^## ' + re.escape(heading) + r'\n(.*?)(?=^## |\Z)', text, re.M | re.S)
    return match[1].strip() if match else ''


def tracking_number(task: Path) -> list[str]:
    result = []
    for file in ('plan.md', 'pr.md'):
        path = task / file
        if path.is_file():
            result.extend(re.findall(r'^- PR Number: #?([0-9]+)\s*$', review.section(path.read_text(), 'PR Tracking'), re.M))
    return result


def publication_owners(repo: Path, number: str) -> list[Path]:
    rows = store_call(repo, 'paw_task_list').splitlines()
    return [Path(row.split('\t')[2]) for row in rows if len(row.split('\t')) == 3 and number in tracking_number(Path(row.split('\t')[2]))]


def record_success(task: Path, repo: Path, preview: dict, url: str) -> None:
    number = url.rsplit('/', 1)[1]
    owners = publication_owners(repo, number)
    if len(owners) > 1:
        raise ValueError('Conflicting PR Tracking owners; reconcile before retry.')
    if not owners:
        plan = task / 'plan.md'
        atomic(plan, plan.read_text().rstrip() + f'\n\n## PR Tracking\n\n- PR Number: #{number}\n- PR URL: {url}\n')
    atomic(Path(preview['body_file']), preview['local'])
    atomic(task / 'publication-result.json', json.dumps({'url': url, 'contributor': preview['identity'], 'token': preview['token']}, indent=2))


def publish(task: Path, repo: Path, token: str) -> dict:
    repo, branch = assignment(task, repo)
    with branch_lock(repo, branch) as directory:
        preview = json.loads((task / 'publication-preview.json').read_text())
        if digest(json.dumps({key: value for key, value in preview.items() if key != 'token'}, sort_keys=True)) != token:
            raise ValueError('Preview bytes changed; prepare and inspect a fresh preview.')
        if preview.get('token') != token or preview.get('task') != str(task.resolve()) or preview.get('repo') != str(repo):
            raise ValueError('Preview identity changed; prepare and inspect a fresh preview.')
        receipt = directory / (token + '.json')
        if receipt.exists():
            if Path(preview['body_file']).read_text() not in {preview['original'], preview['local']} or digest((task / 'review.md').read_text()) != preview['review_identity']:
                raise ValueError('Local body/review changed since remote success; inspect result and prepare again.')
            result = json.loads(receipt.read_text())
            current = lookup(repo, preview['target'])
            if not current or current['url'] != result['url'] or current['body'] != preview['candidate']:
                raise ValueError('Remote result changed since partial success; inspect it and prepare a new preview.')
            # Bookkeeping can have changed plan/body bytes after remote success.
            record_success(task, repo, preview, result['url'])
            return result
        reason = eligibility(task, repo)
        if reason:
            raise ValueError(reason)
        body = body_file(task, repo)
        if snapshot(task, repo, body) != preview['snapshot']:
            raise ValueError('Body, review or task changed since preview; prepare again.')
        target = remote_identity(repo, branch)
        current = lookup(repo, target)
        if target != preview['target'] or current != preview['current']:
            raise ValueError('Remote branch/PR changed since preview; prepare again.')
        own_numbers = tracking_number(task)
        if own_numbers and (not current or any(n != str(current['number']) for n in own_numbers)):
            raise ValueError('PR Tracking mismatch (possibly closed/merged); reconcile before publication.')
        # Retain exact candidate bytes before mutation, even if gh succeeds but a
        # following local write fails. Retrying a fresh preview resolves remote state.
        owners = publication_owners(repo, str(current['number'])) if current else []
        if len(owners) > 1:
            raise ValueError('Conflicting PR Tracking owners; reconcile before publication.')
        candidate_file = directory / (token + '.md')
        atomic(candidate_file, preview['candidate'])
        if snapshot(task, repo, body) != preview['snapshot'] or eligibility(task, repo):
            raise ValueError('Task/body/review changed while checking remote state; prepare again.')
        if current:
            command(repo, 'gh', 'pr', 'edit', str(current['number']), '--repo', target['repository'], '--body-file', str(candidate_file))
            url = current['url']
        else:
            url = command(repo, 'gh', 'pr', 'create', '--repo', target['repository'], '--head', target['branch'] if target['head_repository'] == target['repository'] else target['head'], '--draft', '--title', 'Feature: ' + task.name.replace('-', ' '), '--body-file', str(candidate_file))
            validate_url(url, target['repository'])
        result = {'url': url, 'token': token, 'message': 'PR body published; task remains active. ' + preview['code_status']}
        try:
            atomic(receipt, json.dumps(result, indent=2))
            record_success(task, repo, preview, url)
        except (OSError, ValueError) as error:
            raise ValueError(f'Remote publication succeeded: {url}. Local bookkeeping failed: {error}. Candidate retained at {candidate_file}; retry this token or prepare again, resolving the existing PR.') from error
        return result


def main() -> int:
    parser = argparse.ArgumentParser(description='Preview and explicitly publish a reviewed task contribution; never commit or push.')
    parser.add_argument('task', type=Path)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--create-only', action='store_true')
    parser.add_argument('--publish', metavar='PREVIEW_TOKEN')
    args = parser.parse_args()
    try:
        if args.publish:
            result = publish(args.task, args.repo, args.publish)
            print(result['message'] + '\n' + result['url'])
        else:
            result = prepare(args.task, args.repo, create_only=args.create_only)
            print(f"Repository: {result['target']['repository']} / head {result['target']['head']}\n{result['code_status']}\n{result['adoption']}\n{result['visual']}\n\n{result['diff']}\nCandidate:\n{result['candidate']}\n")
            command_name = 'pr-submit' if args.create_only else 'pr-update'
            print(f"After inspecting this preview, publish explicitly: paw {command_name} {args.task.name} --publish {result['token']}")
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f'PR publication blocked: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
