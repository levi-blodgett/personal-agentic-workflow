"""Behavior checks for prototype workflow transitions (invoked by Bats)."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('gui_server', Path(__file__).resolve().parents[1] / 'scripts/lib/gui_server.py')
gui = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gui
spec.loader.exec_module(gui)


class PrototypeJourney(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name).resolve()
        self.home = self.repo / 'tasks'
        self.path = self.repo / '.agent' / 'replacement'
        self.path.mkdir(parents=True)
        (self.path / 'plan.md').write_text('## Current Status\n- Estimated completion: 20%\n- Next work: Implement.\n')
        self.handler = object.__new__(gui.Handler)
        self.handler.task_home = self.home

    def meta(self, key, value, path=None):
        subprocess.run(['git', 'config', '--file', str((path or self.path) / 'metadata.gitconfig'), 'paw.' + key, value], check=True)

    def task(self):
        return gui.Task('replacement', 'legacy', self.path, self.repo)

    def test_successful_replacement_uses_normal_workflow(self):
        self.meta('prototype-source', 'source')
        for status in ('planned-source-reverted', 'planned', 'planned-revert-blocked', 'planned-revert-unavailable', ''):
            with self.subTest(status=status):
                self.meta('prototype-status', status)
                task = self.task()
                workflow = gui.task_workflow(task)
                self.assertEqual(workflow.action, 'approve-implementation')
                self.assertIn('data-doc-preview-url=', self.handler.workflow_action_control(task, workflow))
        for status in ('prototyped', 'source-reverted', 'revert-blocked', 'revert-unavailable'):
            self.meta('prototype-status', status)
            self.assertEqual(gui.task_workflow(self.task()).action, 'archive')

    def test_prototype_requires_review_and_collects_instructions(self):
        self.assertIn('review.md', gui.prototype_disabled_reason(self.task()))
        (self.path / 'review.md').write_text('# Review\n- Grade: B\n')
        task = self.task()
        self.assertEqual(gui.prototype_disabled_reason(task), '')
        control = self.handler.workflow_action_control(task, gui.task_workflow(task))
        self.assertIn("class='modal-toggle'", control)
        self.assertIn("name='extras'", control)
        self.assertIn('replacement plan', control)
        self.assertIn(str(self.path), control)

    def test_linked_run_blocks_both_packages_and_uses_source_logs(self):
        source = self.repo / '.agent' / 'source'
        source.mkdir()
        (source / 'plan.md').write_text(self.task().plan)
        self.meta('prototype-source', 'source')
        runs = source / 'runs'
        runs.mkdir()
        meta = runs / '20260911-gui-pending.gitconfig'
        for key, value in [('status', 'running'), ('subcommand', 'prototype')]:
            subprocess.run(['git', 'config', '--file', str(meta), 'paw.' + key, value], check=True)
        own_runs = self.path / 'runs'
        own_runs.mkdir()
        for key, value in [('status', 'running'), ('subcommand', 'prototype')]:
            subprocess.run(['git', 'config', '--file', str(own_runs / 'cli.gitconfig'), 'paw.' + key, value], check=True)
        self.assertTrue(gui.list_repo_tasks(self.repo, self.home)[0].running)
        replacement = next(t for t in gui.list_repo_tasks(self.repo, self.home) if t.name == 'replacement')
        self.assertTrue(replacement.running)
        self.assertEqual(replacement.active_run.metadata, meta)
        self.assertNotEqual(gui.task_workflow(replacement).action, 'approve-implementation')

    def test_launch_tracks_immediately_and_records_early_failure(self):
        script = self.repo / 'paw'
        script.write_text('#!/bin/sh\nsleep 0.3\nexit 7\n')
        script.chmod(0o755)
        with patch.object(gui, 'PAW_SCRIPT', script):
            ok, message = gui.launch_paw(self.repo, self.home, self.path, ['prototype', 'replacement'])
        self.assertTrue(ok, message)
        run = self.task().active_run
        self.assertIsNotNone(run)
        self.assertTrue(gui.active_run_logs(self.path, run).available)
        import time
        deadline = time.monotonic() + 5
        while gui.metadata_value(run.metadata, 'status') == 'running' and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertEqual(gui.metadata_value(run.metadata, 'status'), 'failed')
        self.assertEqual(gui.metadata_value(run.metadata, 'exit-status'), '7')

    def test_navigation_resolves_listed_lineage_and_missing_source(self):
        source = self.repo / '.agent' / 'source'
        source.mkdir()
        (source / 'plan.md').write_text(self.task().plan)
        self.meta('prototype-source', 'source')
        self.meta('prototype-status', 'planned-revert-blocked')
        self.meta('prototype-cleanup-message', 'manual cleanup required')
        tasks = {t.name: t for t in gui.list_repo_tasks(self.repo, self.home)}
        source_html = self.handler.workflow_stage_cell(tasks['source'], gui.task_workflow(tasks['source']))
        self.assertIn('Open replacement', source_html)
        replacement_html = self.handler.workflow_stage_cell(tasks['replacement'], gui.task_workflow(tasks['replacement']))
        self.assertIn('Open source', replacement_html)
        self.assertIn('manual cleanup required', replacement_html)
        (source / 'plan.md').unlink()
        source.rmdir()
        replacement = next(t for t in gui.list_repo_tasks(self.repo, self.home) if t.name == 'replacement')
        content = self.handler.workflow_stage_cell(replacement, gui.task_workflow(replacement))
        self.assertIn('archived or unavailable', content)
        self.assertNotIn('Open source', content)

    def test_incomplete_planning_cannot_offer_approval_or_archive(self):
        for status in ('planning', 'planning-failed'):
            self.meta('prototype-status', status)
            workflow = gui.task_workflow(self.task())
            self.assertEqual(workflow.action, 'edit')
            self.assertIn('planning', workflow.note.lower())
        self.meta('prototype-status', 'planned')
        self.assertEqual(gui.task_workflow(self.task()).action, 'approve-implementation')

    def test_failed_replacement_offers_deliberate_source_retry(self):
        source = self.repo / '.agent' / 'source'
        source.mkdir()
        (source / 'plan.md').write_text(self.task().plan)
        (source / 'review.md').write_text('# Review\n- Grade: B\n')
        self.meta('prototype-source', 'source')
        self.meta('prototype-status', 'planning-failed')
        self.meta('prototype-status', 'source-reverted', source)
        self.path.rename(self.path.with_name('source-prototype'))
        task = next(t for t in gui.list_repo_tasks(self.repo, self.home) if t.name == 'source')
        self.assertEqual(gui.task_workflow(task).action, 'prototype')
        control = self.handler.workflow_action_control(task, gui.task_workflow(task))
        self.assertIn('Reuse existing replacement', control)

    def post(self, action, extras=''):
        self.handler.form_data = lambda: {'extras': extras}
        self.handler.selected_repo = lambda query: (self.repo, '')
        self.handler.resolve_task = lambda *args: next(t for t in gui.list_repo_tasks(self.repo, self.home) if t.path == self.path)
        self.handler.redirect = lambda url: url
        return self.handler.post_task_action('replacement', action)

    def test_stale_approval_rechecks_planning_and_completion(self):
        for status in ('planning', 'planning-failed', 'source-reverted'):
            self.meta('prototype-status', status)
            with patch.object(gui, 'launch_paw') as launch:
                self.post('implement')
                launch.assert_not_called()
        self.meta('prototype-status', 'planned')
        with patch.object(gui, 'launch_paw', return_value=(True, 'started')) as launch:
            self.post('implement', 'must not reach implementation')
            self.assertEqual(launch.call_args.args, (self.repo, self.home, self.path, ['implement', 'replacement']))
        (self.path / 'plan.md').write_text('## Current Status\n- Estimated completion: 100%\n- Next work: Review.\n')
        self.assertEqual(gui.task_workflow(self.task()).action, 'review')
        with patch.object(gui, 'launch_paw') as launch:
            self.post('implement')
            launch.assert_not_called()

    def test_duplicate_launch_and_replacement_action_are_blocked_until_cancel(self):
        (self.path / 'review.md').write_text('# Review\n- Grade: B\n')
        replacement = self.path.with_name('replacement-prototype')
        replacement.mkdir()
        (replacement / 'plan.md').write_text(self.task().plan)
        script = self.repo / 'paw'
        script.write_text('#!/bin/sh\nsleep 20\n')
        script.chmod(0o755)
        with patch.object(gui, 'PAW_SCRIPT', script):
            self.post('prototype', '  preserve whitespace\n')
            run = self.task().active_run
            self.addCleanup(lambda: self.stop_run(run))
            self.assertIn('running', self.post('prototype'))
            source_path = self.path
            self.path = replacement
            self.assertIn('running', self.post('implement'))
            self.handler.post_cancel('replacement-prototype')
            self.assertIsNone(gui.active_run_info(source_path))

    @staticmethod
    def stop_run(run):
        import os
        import signal
        try:
            os.killpg(run.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    def test_start_failure_is_visible_after_reload(self):
        missing = self.repo / 'missing-paw'
        with patch.object(gui, 'PAW_SCRIPT', missing):
            ok, _ = gui.launch_paw(self.repo, self.home, self.path, ['prototype', 'replacement'])
        self.assertFalse(ok)
        self.assertIn('failed', gui.prototype_failure(self.task()))
        self.assertIn('Failed to start PAW', self.handler.prototype_failure_logs(self.task()))

    def test_same_names_in_another_repo_do_not_link(self):
        self.meta('prototype-source', 'source')
        other = self.repo / 'other-repo'
        source = self.home / gui.repo_slug(other) / 'source'
        source.mkdir(parents=True)
        (source / 'plan.md').write_text(self.task().plan)
        self.meta('repo-root', str(other), source)
        task = next(t for t in gui.list_repo_tasks(self.repo, self.home) if t.name == 'replacement')
        self.assertEqual(task.prototype_peers, [])

    def test_registered_path_fallback_keeps_lineage_context(self):
        self.handler.current_repos = lambda: [self.repo]
        central = self.home / gui.repo_slug(self.repo) / 'central'
        central.mkdir(parents=True)
        self.meta('prototype-source', 'replacement', central)
        self.meta('repo-root', str(self.repo), central)
        task = self.handler.resolve_registered_task_path('central', str(central))
        self.assertEqual(task.repo, self.repo)
        self.assertEqual([peer.name for peer in task.prototype_peers], ['replacement'])

    def test_partial_seed_after_early_failure_is_not_ready(self):
        with patch.object(gui, 'PAW_SCRIPT', self.repo / 'missing'):
            gui.launch_paw(self.repo, self.home, self.path, ['prototype', 'replacement'])
        partial = self.path.with_name('replacement-prototype')
        partial.mkdir()
        (partial / 'plan.md').write_text(self.task().plan)
        task = next(t for t in gui.list_repo_tasks(self.repo, self.home) if t.path == partial)
        self.assertEqual(gui.task_workflow(task).action, 'edit')

    def test_failure_clears_only_after_successful_planning_evidence(self):
        with patch.object(gui, 'PAW_SCRIPT', self.repo / 'missing'):
            gui.launch_paw(self.repo, self.home, self.path, ['prototype', 'replacement'])
        replacement = self.path.with_name('replacement-prototype')
        replacement.mkdir()
        self.meta('prototype-source', 'replacement', replacement)
        self.meta('prototype-status', 'planned', replacement)
        source = next(t for t in gui.list_repo_tasks(self.repo, self.home) if t.path == self.path)
        self.assertIn('failed', gui.prototype_failure(source))
        runs = replacement / 'runs'
        runs.mkdir()
        for key, value in [('subcommand', 'prototype'), ('status', 'complete'), ('exit-status', '0')]:
            subprocess.run(['git', 'config', '--file', str(runs / 'recovered.gitconfig'), 'paw.' + key, value], check=True)
        source = next(t for t in gui.list_repo_tasks(self.repo, self.home) if t.path == self.path)
        self.assertEqual(gui.prototype_failure(source), '')

    def test_reused_replacement_does_not_reuse_its_old_review(self):
        import os
        review = self.path / 'review.md'
        review.write_text('# Review\n- Grade: B\n')
        os.utime(review, (1, 1))
        self.meta('prototype-status', 'planned')
        self.assertEqual(gui.task_workflow(self.task()).action, 'approve-implementation')
        (self.path / 'plan.md').write_text('## Current Status\n- Estimated completion: 100%\n- Next work: Review.\n')
        self.assertEqual(gui.task_workflow(self.task()).action, 'review')
        review.write_text('# Review\n- Grade: B\n')
        self.assertEqual(gui.task_workflow(self.task()).action, 'prototype')


if __name__ == '__main__':
    unittest.main()
