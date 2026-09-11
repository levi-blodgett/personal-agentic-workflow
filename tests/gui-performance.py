"""Isolated GUI work bounds and repeatable HTTP timings; no CI timing thresholds."""
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.request import urlopen

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('gui_server', Path(__file__).resolve().parents[1] / 'scripts/lib/gui_server.py')
gui = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gui
spec.loader.exec_module(gui)


def fixture(root):
    root = root.resolve()
    repo, home = root / 'repo', root / 'tasks'
    repo.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    central = home / gui.repo_slug(repo)
    for i in range(12):
        name = f'task-{i // 2}' + ('-prototype' if i % 2 else '')
        path = central / name
        (path / 'runs').mkdir(parents=True)
        (path / 'plan.md').write_text('## Current Status\n- Estimated completion: 100%\n- Next work: Review.\n## Validation Performed\n- tests: passed\n')
        (path / 'review.md').write_text('# Review\n- Grade: B\n')
        (path / 'metadata.gitconfig').write_text(f'[paw]\nrepo-root = {repo}\nbranch-name = main\n')
        for n in range(3):
            (path / 'runs' / f'2026090{n+1}.gitconfig').write_text('[paw]\nstatus = complete\nsubcommand = implement\nstarted-at = 2026-09-01T00:00:00Z\n')
    return repo, home


def handler(repo, home):
    h = object.__new__(gui.Handler)
    h.repo, h.task_home, h.all_repos = repo, home, False
    h.repo_registry = home / 'registry.gitconfig'
    h.path = '/'
    h.send_html = lambda body, *args: None
    return h


def measure():
    with tempfile.TemporaryDirectory(prefix='paw-gui-performance-') as directory:
        repo, home = fixture(Path(directory))
        h = handler(repo, home)
        with patch.object(gui, 'list_repo_tasks', wraps=gui.list_repo_tasks) as discovery, patch.object(gui.subprocess, 'run', wraps=subprocess.run) as processes:
            start = time.perf_counter()
            h.index()
            render = time.perf_counter() - start
            counts = {'discovery': discovery.call_count, 'subprocesses': processes.call_count}
        class Handler(gui.Handler):
            def log_message(self, *args):
                pass
        Handler.repo, Handler.task_home, Handler.all_repos = repo, home, False
        Handler.repo_registry = home / 'registry.gitconfig'
        server = gui.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            samples = []
            for route in ['/'] * 6 + ['/fragments/tasks'] * 5:
                start = time.perf_counter()
                with urlopen(f'http://127.0.0.1:{server.server_port}{route}') as response:
                    assert b'task-5-prototype' in response.read()
                samples.append(time.perf_counter() - start)
            print(json.dumps(dict(tasks=12, runs=36, render_seconds=render, **counts,
                                  cold=samples[0], warm=samples[1:6], median=statistics.median(samples[1:6]),
                                  fragments=samples[6:]), indent=2))
        finally:
            server.shutdown()
            thread.join()
            server.server_close()


class WorkBounds(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo, self.home = fixture(Path(tmp.name))
        self.handler = handler(self.repo, self.home)

    def test_single_discovery_with_prototype_dialogs(self):
        with patch.object(gui, 'list_repo_tasks', wraps=gui.list_repo_tasks) as discovery:
            self.handler.index()
        self.assertEqual(discovery.call_count, 1)
        self.assertIn('Reuse existing replacement: task-0-prototype', self.handler.index_task_list({}, self.repo))


    def test_all_repo_replacements_stay_scoped(self):
        other, _ = fixture(self.repo.parent / 'other')
        # Move the second repo's central packages into the shared store.
        import shutil
        shutil.move(str(other.parent / 'tasks' / gui.repo_slug(other)), str(self.home))
        self.handler.all_repos = True
        with patch.object(gui, 'list_all_central_tasks', wraps=gui.list_all_central_tasks) as discovery, patch.object(gui, 'list_repo_tasks', wraps=gui.list_repo_tasks) as scoped:
            self.handler.index()
        self.assertEqual(discovery.call_count, 1)
        self.assertEqual(scoped.call_count, 0)
        rendered = self.handler.index_task_list({}, self.repo)
        self.assertEqual(rendered.count('Reuse existing replacement: task-0-prototype'), 2)

    def test_bounded_metadata_reads(self):
        with patch.object(gui.subprocess, 'run', wraps=subprocess.run) as processes:
            self.handler.index()
        files = [call.args[0][call.args[0].index('--file') + 1] for call in processes.call_args_list
                 if '--file' in call.args[0] and 'config' in call.args[0]]
        self.assertEqual(len(files), len(set(files)))

    def test_git_semantics_and_next_request_freshness(self):
        path = self.home / gui.repo_slug(self.repo) / 'task-0'
        meta = path / 'metadata.gitconfig'
        for key, value in [('branch-name', 'first'), ('branch-name', 'last'), ('message', '  escaped "quote"\nsecond line\tend  ')]:
            subprocess.run(['git', 'config', '--file', str(meta), '--add', 'paw.' + key, value], check=True)
        @gui.read_snapshot
        def read():
            return [gui.metadata_value(meta, key) for key in ('branch-name', 'message', 'absent')]
        self.assertEqual(read(), ['last', 'escaped "quote"\nsecond line\tend', ''])
        meta.write_text('broken [')
        self.assertEqual(read(), ['', '', ''])
        meta.unlink()
        self.assertEqual(read(), ['', '', ''])
        for branch, evidence in [('new', 'passed'), ('changed', 'failed')]:
            meta.write_text(f'[paw]\nrepo-root = {self.repo}\nbranch-name = {branch}\n')
            (path / 'plan.md').write_text('## Validation Performed\n- tests: ' + evidence)
            rendered = self.handler.index_task_list({}, self.repo)
            self.assertIn('Branch: ' + branch, rendered)
            self.assertIn('validation-' + ('passed' if evidence == 'passed' else 'attention'), rendered)

    def test_next_request_run_state_and_central_precedence(self):
        path = self.home / gui.repo_slug(self.repo) / 'task-0'
        legacy = self.repo / '.agent' / 'task-0'
        legacy.mkdir(parents=True)
        (legacy / 'plan.md').write_text('LEGACY SHADOW SHOULD NOT APPEAR')
        run = path / 'runs' / 'zz-gui-pending.gitconfig'
        run.write_text('[paw]\nstatus = running\nsubcommand = implement\n')
        rendered = self.handler.index_task_list({}, self.repo)
        self.assertIn("pill running", rendered)
        self.assertNotIn('LEGACY SHADOW', rendered)
        run.write_text('[paw]\nstatus = complete\nsubcommand = implement\n')
        self.assertNotIn("pill running", self.handler.index_task_list({}, self.repo))

    def test_snapshots_are_thread_local_and_reset(self):
        meta = self.repo / 'sample.gitconfig'
        meta.write_text('[paw]\nvalue = before\n')
        @gui.read_snapshot
        def read():
            self.assertEqual(gui.metadata_value(meta, 'value'), 'before')
            meta.write_text('[paw]\nvalue = after\n')
            values = []
            thread = threading.Thread(target=lambda: values.append(gui.metadata_value(meta, 'value')))
            thread.start()
            thread.join()
            self.assertEqual(values, ['after'])
            self.assertEqual(gui.metadata_value(meta, 'value'), 'before')
        read()
        self.assertEqual(gui.metadata_value(meta, 'value'), 'after')


if __name__ == '__main__':
    if '--measure' in sys.argv:
        measure()
    else:
        unittest.main()
