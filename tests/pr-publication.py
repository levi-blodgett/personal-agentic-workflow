"""Publication policy checks use isolated files; never call live GitHub."""
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import json
import os
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/lib'))
import review_record
import pr_publication as publication


class Eligibility(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.task = self.repo / '.agent/task'
        self.task.mkdir(parents=True)
        (self.task / 'plan.md').write_text('## Current Status\n- Estimated completion: 100%\n- Next work: Review.\n')
        self.review = ('## Review Metadata\n- Task: task\n- Scope Reviewed: publication\n'
                       '- Grade: A-\n- Quality Threshold: A-\n- Threshold Result: met\n'
                       '- Completion: complete\n- Attempt: abc\n- Quality Policy Version: 1\n'
                       f'- Reviewed Code: {review_record.code_identity(self.repo)}\n'
                       '## Blocking Production-Readiness Issues\n- None.\n')
        (self.task / 'review.md').write_text(self.review)
        (self.task / '.review-attempt').write_text('abc\tcomplete\n')

    def test_publication_floor_and_blockers(self):
        for grade in ('A-', 'A', 'A+'):
            (self.task / 'review.md').write_text(self.review.replace('Grade: A-', 'Grade: ' + grade))
            self.assertEqual(publication.eligibility(self.task, self.repo), '')
        for before, after in [('Grade: A-', 'Grade: B+'), ('- None.', '- Fix ownership.'),
                              ('Completion: complete', 'Completion: pending'),
                              ('Task: task', 'Task: other'), ('Grade: A-', 'Grade: A-\n- Grade: A'),
                              ('Attempt: abc', 'Attempt: def')]:
            (self.task / 'review.md').write_text(self.review.replace(before, after))
            self.assertTrue(publication.eligibility(self.task, self.repo), after)

    def test_incomplete_pending_stale_and_running_refuse(self):
        plan = self.task / 'plan.md'
        original = plan.read_text()
        for suffix in ('\n- [ ] unfinished\n', '\nUSER ANSWER (PROVIDED): yes\n', '\n## Current Status\n- Estimated completion: 100%\n'):
            plan.write_text(original + suffix)
            self.assertTrue(publication.eligibility(self.task, self.repo))
        plan.write_text(original)
        runs = self.task / 'runs'
        runs.mkdir()
        (runs / 'active.gitconfig').write_text('[paw]\nstatus = running\nsubcommand = implement\n')
        self.assertTrue(publication.eligibility(self.task, self.repo))
        (runs / 'active.gitconfig').write_text('[paw]\nstatus = complete\nsubcommand = diagnose\n')
        self.assertTrue(publication.eligibility(self.task, self.repo))
        (runs / 'active.gitconfig').unlink()
        (self.repo / 'new-code').write_text('changed')
        self.assertTrue(publication.eligibility(self.task, self.repo))


class BodyPolicy(unittest.TestCase):
    def test_two_tasks_replace_once_preserving_human_bytes(self):
        original = 'Human text.\n'
        first = '<!-- PAW:CONTRIBUTION one -->old<!-- /PAW:CONTRIBUTION one -->'
        second = '<!-- PAW:CONTRIBUTION two -->second<!-- /PAW:CONTRIBUTION two -->'
        merged = publication.merge_contribution(publication.merge_contribution(original, first, 'one'), second, 'two')
        changed = publication.merge_contribution(merged, first.replace('old', 'new'), 'one')
        self.assertTrue(changed.startswith(original))
        self.assertIn(second, changed)
        self.assertEqual(changed.count('<!-- PAW:CONTRIBUTION one -->'), 1)
        with self.assertRaises(ValueError):
            publication.merge_contribution(merged + first, first, 'one')

    def test_visuals_reject_examples_and_require_published_images(self):
        diagram = 'This shows the publication transition.\n```mermaid\nflowchart TD\n A --> B\n```'
        self.assertEqual(publication.visual_check(diagram), '')
        self.assertEqual(publication.visual_check(diagram + '\nAnother task shares this visual.'), '')
        for invalid in ('```mermaid\n```', '<!--' + diagram + '-->', '````markdown\n' + diagram + '\n````',
                        'This is a screenshot.\n![Useful changed UI](/tmp/local.png)',
                        'This shows badge status.\n![Build status badge](https://img.shields.io/build)',
                        'This shows the UI.\n![Updated task controls](assets/screen.png)'):
            self.assertTrue(publication.visual_check(invalid), invalid)
        self.assertEqual(publication.visual_check('This shows the changed controls.\n![Updated task controls](assets/screen.png)', lambda p: p == 'assets/screen.png'), '')


class Publication(Eligibility):
    def setUp(self):
        super().setUp()
        self.body = self.repo / '.agent/branch-pr.md'
        self.body.write_text('Unimplemented unrelated plan stays local.\n\n## Visual Evidence\n\nThis shows the publication transition.\n```mermaid\nflowchart TD\n A --> B\n```\n')
        with (self.task / 'plan.md').open('a') as out:
            out.write('\n## PR Contribution\n- Outcome: Reviewed task publication works.\n- Validation: Publication fixtures passed.\n- Risks: External edit races remain.\n- Visual: Branch diagram shows publication transitions.\n')
        self.target = {'repository': 'org/repo', 'head_repository': 'org/repo', 'head': 'org:feature', 'branch': 'feature', 'sha': 'unborn'}
        self.remote = None
        self.calls = []
        self.directory = self.repo / '.agent/receipts'
        self.directory.mkdir()
        from contextlib import nullcontext
        for name, value in [('assignment', lambda *a: (self.repo, 'feature')),
                            ('body_file', lambda *a: self.body),
                            ('branch_lock', lambda *a: nullcontext(self.directory)),
                            ('remote_identity', lambda *a: dict(self.target)),
                            ('lookup', lambda *a: dict(self.remote) if self.remote else None),
                            ('command', self.command), ('store_call', lambda *a: 'task\tlegacy\t' + str(self.task))]:
            mocked = patch.object(publication, name, value)
            mocked.start()
            self.addCleanup(mocked.stop)

    def command(self, repo, *args):
        self.calls.append(args)
        if args[:3] == ('git', 'rev-parse', 'HEAD'):
            return 'unborn'
        if args[:2] == ('git', 'status'):
            return ''
        if args[0] == 'git':
            return str(self.repo / '.git')
        if args[:3] == ('gh', 'pr', 'create'):
            self.assertEqual(args[args.index('--head') + 1], 'feature')
        if args[:2] in [('gh', 'pr')]:
            body = Path(args[args.index('--body-file') + 1]).read_text()
            self.remote = {'number': 123, 'url': 'https://github.com/org/repo/pull/123', 'body': body}
            return self.remote['url']
        self.fail(str(args))

    def test_operation_mode_refusal_preserves_all_publication_bytes(self):
        for mode in (False, True):
            with self.subTest(create_only=mode):
                preview = publication.prepare(self.task, self.repo, create_only=mode)
                before = {str(p): p.read_bytes() for p in self.repo.rglob('*') if p.is_file()}
                with self.assertRaisesRegex(ValueError, 'mode'):
                    publication.publish(self.task, self.repo, preview['token'], create_only=not mode)
                self.assertEqual(before, {str(p): p.read_bytes() for p in self.repo.rglob('*') if p.is_file()})
                self.assertFalse(any(c[0] == 'gh' for c in self.calls))

    def test_create_only_receipt_retry_and_wrong_mode_are_idempotent(self):
        preview = publication.prepare(self.task, self.repo, create_only=True)
        with patch.object(publication, 'record_success', side_effect=OSError('disk full')):
            with self.assertRaisesRegex(ValueError, 'Remote publication succeeded'):
                publication.publish(self.task, self.repo, preview['token'], create_only=True)
        before = {str(p): p.read_bytes() for p in self.repo.rglob('*') if p.is_file()}
        with self.assertRaisesRegex(ValueError, 'mode'):
            publication.publish(self.task, self.repo, preview['token'])
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.repo.rglob('*') if p.is_file()})
        publication.publish(self.task, self.repo, preview['token'], create_only=True)
        publication.publish(self.task, self.repo, preview['token'], create_only=True)
        self.assertEqual(sum(c[:3] == ('gh', 'pr', 'create') for c in self.calls), 1)
        self.assertFalse(any(c[:3] == ('gh', 'pr', 'edit') for c in self.calls))

    def test_missing_invalid_mode_refuses_even_with_rehashed_token(self):
        for mode in (None, 'create', 1, {}, 'update'):
            preview = publication.prepare(self.task, self.repo)
            preview['operation'] = mode
            preview.pop('token')
            token = publication.digest(json.dumps(preview, sort_keys=True))
            preview['token'] = token
            (self.task / 'publication-preview.json').write_text(json.dumps(preview))
            with self.assertRaisesRegex(ValueError, 'mode'):
                publication.publish(self.task, self.repo, token)
            self.assertEqual(list(self.directory.iterdir()), [])
        self.assertFalse(any(c[0] == 'gh' for c in self.calls))

    def test_receipt_mode_and_remote_head_must_still_match(self):
        preview = publication.prepare(self.task, self.repo)
        with patch.object(publication, 'record_success', side_effect=OSError('disk full')):
            with self.assertRaises(ValueError):
                publication.publish(self.task, self.repo, preview['token'])
        receipt = self.directory / (preview['token'] + '.json')
        original = receipt.read_text()
        for operation in (None, 'create-only', 'bogus'):
            receipt.write_text(json.dumps(dict(json.loads(original), operation=operation)))
            before = {str(p): p.read_bytes() for p in self.repo.rglob('*') if p.is_file()}
            with self.assertRaisesRegex(ValueError, 'mode'):
                publication.publish(self.task, self.repo, preview['token'])
            self.assertEqual(before, {str(p): p.read_bytes() for p in self.repo.rglob('*') if p.is_file()})
        receipt.write_text(original)
        self.target['sha'] = 'changed-head'
        with self.assertRaisesRegex(ValueError, 'remote head changed'):
            publication.publish(self.task, self.repo, preview['token'])
        self.assertNotIn('## PR Tracking', (self.task / 'plan.md').read_text())
        self.assertEqual(sum(c[0] == 'gh' for c in self.calls), 1)

    def test_new_pr_invalidates_create_only_before_candidate_writes(self):
        preview = publication.prepare(self.task, self.repo, create_only=True)
        self.remote = dict(number=123, url='https://github.com/org/repo/pull/123', body='New human PR')
        with self.assertRaisesRegex(ValueError, 'Remote branch/PR changed'):
            publication.publish(self.task, self.repo, preview['token'], create_only=True)
        self.assertEqual(list(self.directory.iterdir()), [])
        self.assertFalse(any(c[0] == 'gh' for c in self.calls))

    def test_repeated_visual_refresh_preserves_legacy_and_human_bytes(self):
        human = 'Human introduction.\n\nThis explains the legacy diagram.\n```mermaid\nflowchart LR\n X --> Y\n```\n'
        self.remote = dict(number=123, url='https://github.com/org/repo/pull/123', body=human)
        for node in ('C', 'D', 'E'):
            original_remote = self.remote['body']
            self.body.write_text(self.body.read_text().replace(' A --> B', f' A --> {node}\n {node} --> B'))
            preview = publication.prepare(self.task, self.repo)
            self.assertTrue(preview['candidate'].startswith(human))
            for visual in (' X --> Y', *[line for line in original_remote.splitlines() if '-->' in line]):
                self.assertIn(visual, preview['candidate'])
            publication.publish(self.task, self.repo, preview['token'])
            self.body.write_text(self.body.read_text().replace(f' A --> {node}\n {node} --> B', ' A --> B'))

    def test_oversized_current_and_proposed_body_can_publish(self):
        self.body.write_text(self.body.read_text() + '\n' * 151)
        preview = publication.prepare(self.task, self.repo)
        publication.publish(self.task, self.repo, preview['token'])
        self.assertIsNotNone(self.remote)

    def test_create_repeat_and_second_task_preserve_owner(self):
        first = publication.prepare(self.task, self.repo)
        self.assertNotIn('Unimplemented unrelated', first['candidate'])
        self.assertIn('Unimplemented unrelated', first['local'])
        result = publication.publish(self.task, self.repo, first['token'])
        self.assertEqual(result['url'], 'https://github.com/org/repo/pull/123')
        self.assertIn('## PR Tracking', (self.task / 'plan.md').read_text())
        publication.publish(self.task, self.repo, first['token'])
        self.assertEqual(sum(c[:3] == ('gh', 'pr', 'create') for c in self.calls), 1)
        self.remote['body'] = 'Human-authored intro.\n' + self.remote['body']
        second = self.task.parent / 'second'
        second.mkdir()
        (second / 'plan.md').write_text((self.task / 'plan.md').read_text().split('## PR Tracking')[0])
        (second / 'review.md').write_text(self.review.replace('Task: task', 'Task: second'))
        (second / '.review-attempt').write_text('abc\tcomplete\n')
        preview = publication.prepare(second, self.repo)
        publication.publish(second, self.repo, preview['token'])
        self.assertTrue(self.remote['body'].startswith('Human-authored intro.'))
        self.assertEqual(self.remote['body'].count('## Task: task'), 1)
        self.assertEqual(self.remote['body'].count('## Task: second'), 1)
        self.assertNotIn('## PR Tracking', (second / 'plan.md').read_text())
        repeated = publication.prepare(self.task, self.repo)
        self.assertEqual(repeated['candidate'].count('## Task: task'), 1)
        publication.publish(self.task, self.repo, repeated['token'])
        self.assertFalse(any(c[0] == 'git' and c[1] in {'add', 'commit', 'push', 'checkout', 'switch', 'merge'} for c in self.calls))

    def test_stale_body_review_remote_and_tracking_refuse(self):
        preview = publication.prepare(self.task, self.repo)
        self.body.write_text(self.body.read_text() + '\nHuman edit')
        with self.assertRaisesRegex(ValueError, 'changed since preview'):
            publication.publish(self.task, self.repo, preview['token'])
        preview = publication.prepare(self.task, self.repo)
        self.remote = {'number': 123, 'url': 'https://github.com/org/repo/pull/123', 'body': 'Concurrent human edit.'}
        with self.assertRaisesRegex(ValueError, 'Remote branch/PR changed'):
            publication.publish(self.task, self.repo, preview['token'])
        with self.assertRaisesRegex(ValueError, 'already exists'):
            publication.prepare(self.task, self.repo, create_only=True)
        preview = publication.prepare(self.task, self.repo)
        (self.task / '.review-attempt').write_text('new\trunning\n')
        with self.assertRaisesRegex(ValueError, 'Review again'):
            publication.publish(self.task, self.repo, preview['token'])
        self.assertFalse(any(c[0] == 'gh' for c in self.calls))

    def test_scope_refresh_and_tracking_conflict(self):
        preview = publication.prepare(self.task, self.repo)
        publication.publish(self.task, self.repo, preview['token'])
        self.body.write_text(self.body.read_text().replace(' A --> B', ' A --> C\n C --> B'))
        refreshed = publication.prepare(self.task, self.repo)
        self.assertIn(' A --> C', refreshed['candidate'])
        self.remote = None  # A tracked PR closed/merged; never silently create another.
        preview = publication.prepare(self.task, self.repo)
        with self.assertRaisesRegex(ValueError, 'PR Tracking mismatch'):
            publication.publish(self.task, self.repo, preview['token'])

    def test_tampered_preview_and_recovery_local_edits_refuse(self):
        preview = publication.prepare(self.task, self.repo)
        saved = dict(preview, candidate='Unreviewed replacement')
        (self.task / 'publication-preview.json').write_text(json.dumps(saved))
        with self.assertRaisesRegex(ValueError, 'Preview bytes changed'):
            publication.publish(self.task, self.repo, preview['token'])
        preview = publication.prepare(self.task, self.repo)
        with patch.object(publication, 'record_success', side_effect=OSError('disk full')):
            with self.assertRaises(ValueError):
                publication.publish(self.task, self.repo, preview['token'])
        self.body.write_text('New human local edit')
        with self.assertRaisesRegex(ValueError, 'Local body/review changed'):
            publication.publish(self.task, self.repo, preview['token'])
        self.assertEqual(self.body.read_text(), 'New human local edit')

    def test_remote_success_local_failure_is_recoverable(self):
        preview = publication.prepare(self.task, self.repo)
        with patch.object(publication, 'record_success', side_effect=OSError('disk full')):
            with self.assertRaisesRegex(ValueError, 'Remote publication succeeded'):
                publication.publish(self.task, self.repo, preview['token'])
        publication.publish(self.task, self.repo, preview['token'])
        self.assertEqual(sum(c[:3] == ('gh', 'pr', 'create') for c in self.calls), 1)
        self.assertTrue((self.task / 'publication-result.json').exists())


class RemoteBoundary(unittest.TestCase):
    def test_lookup_absence_errors_ambiguity_and_fork_identity(self):
        target = {'repository': 'base/repo', 'head_repository': 'fork/repo', 'head': 'fork:feature', 'branch': 'feature'}
        pr = {'number': 12, 'url': 'https://github.com/base/repo/pull/12', 'body': 'human', 'headRefName': 'feature', 'headRepository': {'name': 'repo'}, 'headRepositoryOwner': {'login': 'fork'}}
        for records, valid in [([], True), ([pr], True), ([pr, pr], False), ([dict(pr, headRefName='other')], False), ([dict(pr, url='javascript:alert(1)')], False)]:
            with patch.object(publication, 'command', return_value=json.dumps(records)) as call:
                if valid:
                    self.assertEqual(publication.lookup(Path('.'), target), records[0] if records else None)
                    args = call.call_args.args
                    self.assertEqual(args[args.index('--head') + 1], 'feature')
                else:
                    with self.assertRaises(ValueError):
                        publication.lookup(Path('.'), target)
        with patch.object(publication, 'command', side_effect=ValueError('gh authentication failed')):
            with self.assertRaisesRegex(ValueError, 'authentication'):
                publication.lookup(Path('.'), target)

    def test_task_birth_and_repository_identity_do_not_reuse_archive(self):
        with tempfile.TemporaryDirectory() as root:
            repo = Path(root)
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            task = repo / 'task'
            task.mkdir()
            (task / 'metadata.gitconfig').write_text('[paw]\ncreated-at = first\n')
            first = publication.task_identity(task, repo)
            task.rename(repo / 'archived-task')
            task.mkdir()
            (task / 'metadata.gitconfig').write_text('[paw]\ncreated-at = second\n')
            self.assertNotEqual(first, publication.task_identity(task, repo))
            other = repo / 'other'
            other.mkdir()
            subprocess.run(['git', 'init', '-q', str(other)], check=True)
            self.assertNotEqual(publication.task_identity(task, repo), publication.task_identity(task, other))

    def test_process_and_remote_tracking_diagnostics(self):
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            publication.command(Path('.'), '/nonexistent/paw-fixture-gh')
        target_repo = Path('.')
        def response(repo, *args):
            if args[:3] == ('gh', 'repo', 'view'):
                return '{"nameWithOwner":"base/repo"}'
            if args[:3] == ('git', 'config', '--get'):
                return 'origin' if args[-1].endswith('.remote') else 'refs/heads/feature'
            if args[:3] == ('git', 'remote', 'get-url'):
                return 'git@github.com:fork/repo.git'
            return ''
        with patch.object(publication, 'command', side_effect=response):
            with self.assertRaisesRegex(ValueError, 'Remote branch is absent'):
                publication.remote_identity(target_repo, 'feature')
        def mismatched(repo, *args):
            return 'refs/heads/other' if args[-1].endswith('.merge') else response(repo, *args)
        with patch.object(publication, 'command', side_effect=mismatched):
            with self.assertRaisesRegex(ValueError, 'Tracking mismatch'):
                publication.remote_identity(target_repo, 'feature')

    def test_branch_lock_rejects_duplicate_and_releases_after_failure(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(publication, 'command', return_value=root):
                with publication.branch_lock(Path(root), 'feature'):
                    with self.assertRaisesRegex(ValueError, 'Another PAW publication'):
                        with publication.branch_lock(Path(root), 'feature'):
                            self.fail('lock acquired twice')
                with publication.branch_lock(Path(root), 'feature'):
                    pass


class HttpPublication(Publication):
    def test_http_native_json_and_forged_grade_parity(self):
        import gui_server
        import threading
        from http.server import ThreadingHTTPServer
        from urllib.request import Request, urlopen
        from urllib.parse import urlencode
        class Handler(gui_server.Handler):
            repo = self.repo
            task_home = self.repo / 'store'
            repo_registry = self.repo / '.agent/registry'
            all_repos = False
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f'http://127.0.0.1:{server.server_port}'
        def post(action, token='', native=False):
            request = Request(base + '/task/task/' + action, data=urlencode({'path': str(self.task), 'active_repo': str(self.repo), 'token': token}).encode(), headers={'Accept': 'text/html' if native else 'application/json'})
            with urlopen(request) as response:
                text = response.read().decode()
                return text if native else json.loads(text)
        page = urlopen(base).read().decode()
        self.assertIn('Update PR', page)
        self.assertIn('/task/task/archive', page)
        self.assertFalse(any(c[0] == 'gh' for c in self.calls))
        native = post('pr-preview', native=True)
        self.assertIn('publication-panel', native)
        self.assertIn('Publish PR body', native)
        wrong_mode = publication.prepare(self.task, self.repo, create_only=True)
        blocked_mode = post('pr-update', wrong_mode['token'])
        self.assertFalse(blocked_mode['ok'])
        self.assertIn('mode', blocked_mode['message'])
        self.assertIsNone(self.remote)
        candidate = post('pr-preview')
        self.assertTrue(candidate['ok'])
        self.assertIn('Exact candidate body', candidate['preview'])
        token = json.loads((self.task / 'publication-preview.json').read_text())['token']
        result = post('pr-update', token)
        self.assertTrue(result['ok'])
        self.assertEqual(result['link'], 'https://github.com/org/repo/pull/123')
        self.assertTrue(self.task.exists())
        (self.task / 'review.md').write_text(self.review.replace('Grade: A-', 'Grade: B+'))
        blocked = post('pr-preview')
        self.assertFalse(blocked['ok'])
        self.assertIn('Review', blocked['message'])


if __name__ == '__main__':
    unittest.main()
