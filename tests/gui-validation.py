"""Recorded validation behavior checks, invoked by Bats."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import html
from urllib.parse import quote
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('gui_server', Path(__file__).resolve().parents[1] / 'scripts/lib/gui_server.py')
gui = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gui
spec.loader.exec_module(gui)


class Validation(unittest.TestCase):
    def state(self, body):
        return gui.validation_state('## Validation Performed\n' + body)

    def test_diagnostic_invariance(self):
        for tail in ('', ' because expected output differs', ' — will need a fix',
                     ' because tests should pass?', ' — browser not executed', '. Expected output differs'):
            with self.subTest(tail=tail):
                self.assertEqual(self.state('- tests: failed' + tail + '\n- lint: passed'), 'attention')

    def test_explicit_incomplete_and_negated_results(self):
        self.assertEqual(self.state('- tests: not passed as expected\n- lint: passed'), 'attention')
        for result in ('not executed', 'not yet executed', 'not run', 'not yet run',
                       'has not run', 'has not been executed', 'skipped', 'unknown'):
            with self.subTest(result=result):
                self.assertEqual(self.state('- browser: ' + result), 'recorded')
                self.assertEqual(self.state('- tests: passed\n- browser: ' + result), 'recorded')

    def test_fragment_incomplete_reason(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / '.agent' / 'checks'
            path.mkdir(parents=True)
            for body, state, reason in (
                ('- tests: passed\n- browser: not executed', 'recorded', 'browser'),
                ('- tests: passed\n- browser: blocked', 'attention', 'browser'),
                ('- tests: passed', 'passed', 'freshness'),
                ('', 'missing', 'No executed'),
            ):
                plan = '## Validation Performed\n' + body
                (path / 'plan.md').write_text(plan)
                for fragment in (gui.validation_cell(plan, '/task/checks'),
                                 gui.validation_details(gui.Task('checks', 'legacy', path, repo))):
                    self.assertIn('validation-' + state, fragment)
                    self.assertIn(reason, fragment)

    def test_nested_outcomes_and_diagnostic_exclusions(self):
        outcomes = {'passed': 'passed', 'failed': 'attention', 'did not pass': 'attention',
                    'exit 1': 'attention', 'exit 0': 'passed', 'unknown': 'recorded',
                    'not executed': 'recorded', 'not verified': 'recorded', 'pending': 'recorded',
                    'unavailable': 'attention', 'blocked': 'attention', 'skipped': 'recorded',
                    'unfamiliar wording': 'recorded'}
        for result, expected in outcomes.items():
            for shape in ('- browser: {}', '- tests: passed; browser: {}',
                          '- tests: passed\n  browser: {}', '- tests: passed\n  - browser: {}'):
                with self.subTest(result=result, shape=shape):
                    self.assertEqual(self.state(shape.format(result)), expected)
        for diagnostic in ('  ```text\n  browser: failed\n  ```',
                           '  ~~~text\n  browser: failed\n  ~~~',
                           '  <!--\n  browser: failed\n  -->',
                           '  <!-- browser: failed -->',
                           '  Command: false\n  Tier: full\n  Log: failed.log'):
            with self.subTest(diagnostic=diagnostic):
                self.assertEqual(self.state('- tests: passed\n' + diagnostic), 'passed')
        self.assertEqual(self.state('```text\nbrowser: failed\n```'), 'missing')

    def test_exact_rerun_identity_and_intent(self):
        rerun = 'passed (rerun; supersedes earlier result)'
        for first in ('- tests: passed; browser: failed', '- tests: passed\n  browser: failed'):
            evidence = first + '\n- tests: ' + rerun
            self.assertEqual(self.state(evidence), 'attention')
            self.assertEqual(self.state(evidence + '\n- browser: ' + rerun), 'passed')
        for later in ('- tests: passed\n  Diagnostic: (rerun; supersedes earlier result)',
                      '- tests: passed because the log says (rerun; supersedes earlier result)',
                      '- tests: passed (rerun; supersedes earlier result); browser: failed',
                      '- tests: passed; browser: passed (rerun; supersedes earlier result)',
                      '- passed (rerun; supersedes earlier result)',
                      '- tests/browser: passed (rerun; supersedes earlier result)'):
            with self.subTest(later=later):
                self.assertEqual(self.state('- tests: failed\n' + later), 'attention')
        self.assertEqual(self.state('- tests: failed\n- tests: passed? (rerun; supersedes earlier result)'), 'attention')
        self.assertEqual(self.state('- tests: failed\n- tests: passed (rerun; supersedes earlier result).'), 'passed')
        self.assertEqual(self.state('- tests: failed\n- tests: passed (RERUN; supersedes earlier result)'), 'passed')
        self.assertEqual(self.state('- tests and browser: failed\n- tests and browser: ' + rerun), 'attention')
        self.assertEqual(self.state('- : failed\n- : passed (rerun; supersedes earlier result)'), 'attention')

    def test_sequential_scope_boundaries(self):
        rerun = '- tests: passed (rerun; supersedes earlier result)'
        for boundary in ('### Context', '### Development history', '- Context:',
                         '- Development history:', '- Planning investigation only.',
                         '- Planning validation only.'):
            with self.subTest(boundary=boundary):
                self.assertEqual(self.state('- tests: passed\n' + boundary), 'passed')
                self.assertEqual(self.state(boundary + '\n- tests: failed'), 'missing')
                self.assertEqual(self.state('- tests: failed\n' + boundary + '\n' + rerun), 'attention')
                for resume in ('### Implementation results', '- Implementation results:'):
                    self.assertEqual(self.state(boundary + '\n- tests: failed\n' + resume + '\n- tests: passed'), 'passed')
        self.assertEqual(self.state('### Context\nRead the old plan.\n### Development history\n- lint: passed'), 'missing')
        self.assertEqual(self.state('- tests: failed\n### Context\n### Notes\n' + rerun), 'attention')

    def test_fragment_identity_scope_and_substitution_invariants(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for store in ('legacy', 'central'):
                for repo_name in ('one', 'two'):
                    repo = root / repo_name
                    path = repo / store / 'same'
                    path.mkdir(parents=True)
                    for body, state, reason in (
                        ('- tests: passed; browser: failed\n- tests: passed (rerun; supersedes earlier result)', 'attention', 'browser: failed'),
                        ('- tests: passed\n  browser: exit 1\n### Development history\n- browser: passed (rerun; supersedes earlier result)', 'attention', 'browser: exit 1'),
                        ('- browser: not executed\n- substitute: passed — approved substitution', 'recorded', 'browser: not executed'),
                        ('### Context\n- tests: passed', 'missing', 'No executed'),
                    ):
                        plan = '## Validation Performed\n' + body
                        (path / 'plan.md').write_text(plan)
                        task = gui.Task('same', store, path, repo)
                        for rendered in (gui.validation_cell(plan, '/task/same'), gui.validation_details(task)):
                            self.assertIn('validation-' + state, rendered)
                            self.assertIn(reason, rendered)
                        detail = gui.validation_details(task)
                        self.assertIn(html.escape(body.splitlines()[0]), detail)
                        self.assertIn('active_repo=' + quote(str(repo), safe=''), detail)

    def test_unknown_results_do_not_borrow_diagnostic_success(self):
        for body in ('- tests: unknown — earlier log said passed',
                     '- tests: unfamiliar wording about passed checks',
                     '- tests: `echo passed`', '- tests: skipped because lint passed',
                     '- tests: passed\n  browser:unrecognized',
                     '- tests: passed\n  browser:',
                     '- tests: passed\n  browser — unknown'):
            with self.subTest(body=body):
                self.assertEqual(self.state(body), 'recorded')
        for body in ('- Run tests: passed', '- Note: not run', '- Command: echo failed'):
            self.assertEqual(self.state(body), 'missing')

    def test_fenced_headings_cannot_truncate_evidence(self):
        body = '- tests: passed\n  ```text\n## Diagnostic heading\n  browser: failed\n  ```\n- browser: failed'
        self.assertEqual(self.state(body), 'attention')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'plan.md').write_text('## Validation Performed\n' + body + '\n## Remaining Work\n- other: failed')
            detail = gui.validation_details(gui.Task('checks', 'legacy', path, path))
            self.assertIn('## Diagnostic heading', detail)
            self.assertNotIn('other: failed', detail)

    def test_no_evidence(self):
        for body in ('', '- <commands/results>', '- TODO', '- Pending.', '- <command> — <result, including counts/output highlights>\n- Code best-practices checklist applied — see `prompts/prompt_instructions.md` "Code Best Practices".'):
            with self.subTest(body=body):
                self.assertEqual(self.state(body), 'missing')
        self.assertIn('Unvalidated', gui.validation_chip('missing'))

    def test_explicit_not_run(self):
        self.assertEqual(self.state('- Validation not run; expected tests passed later.'), 'missing')
        self.assertEqual(self.state('- No validation has been executed.'), 'missing')

    def test_executed_success_boundaries(self):
        cases = {
            '- OK.': 'passed', '- `bats tests/gui-server.bats`: passed.': 'passed',
            '- make check passed with 0 failures and 0 errors.': 'passed',
            '- tokens': 'recorded', '- `check-passed-errors.sh`': 'recorded',
            '- Run make check; expected passed.': 'missing',
            '- Planning-only package/document checks: passed.': 'missing',
            '- Tests did not pass.': 'attention', '- Tests: not passed.': 'attention',
            '- Tests: 0 failures, 0 errors.': 'recorded',
            '- Tests: expected passed after implementation.': 'missing',
            '- Tests: passed?': 'recorded', '- Tests: not successful.': 'attention',
            '- `make check`: not OK.': 'attention',
            '- Tests: not all passed.': 'attention',
            '- Tests: not all checks passed.': 'attention',
            '- Tests: passed, 0 failed.': 'passed',
            '- Tests: exit 1.': 'attention',
            '- Tests: did not fail.': 'recorded',
        }
        for body, expected in cases.items():
            with self.subTest(body=body):
                self.assertEqual(self.state(body), expected)

    def test_mixed_and_historical_results(self):
        cases = {
            '- lint: failed — bad indent\n  file.py:12\n- tests: passed': 'attention',
            '- lint: failed\n- lint: passed': 'attention',
            '- lint: failed\n- lint: passed (rerun; supersedes earlier result)': 'passed',
            '- lint: failed\n- tests: passed (rerun; supersedes earlier result)': 'attention',
            '- browser: unavailable — no tool\n- tests: passed': 'attention',
            '- browser: skipped': 'recorded',
            '- tests: passed\n- browser: unknown': 'recorded',
            '- tests: passed; browser: skipped': 'recorded',
            '- tests: passed\n- Note: source is plan.md.': 'passed',
            '- Planning investigation only.\n- package lint: passed': 'missing',
            '- error handling tests: passed': 'passed',
            '- Reviewed error handling documentation.': 'recorded',
            '- tests: 2 failures': 'attention',
            '- tests: passed\n- browser: not run': 'recorded',
            '- tests: passed; browser: not run': 'recorded',
            '- tests: failed; browser: not run': 'attention',
            '- tests: passed\n  browser: failed': 'attention',
        }
        for body, expected in cases.items():
            with self.subTest(body=body):
                self.assertEqual(self.state(body), expected)

    def test_attention_details(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / '.agent' / 'checks'
            path.mkdir(parents=True)
            (path / 'plan.md').write_text('## Validation Performed\n- lint: failed — bad indent\n  file.py:12')
            task = gui.Task('checks', 'legacy', path, repo)
            handler = object.__new__(gui.Handler)
            handler.task_home = repo / 'tasks'
            handler.all_repos = False
            detail = handler.task_detail(task, 'plan')
            index = handler.index_task_list({}, repo)
            self.assertIn("<details id='validation'", detail)
            self.assertNotRegex(detail, r"<details id='validation'[^>]*\bopen\b")
            self.assertIn("<summary id='validation-heading'>Validation details", detail)
            self.assertIn("id='validation-source'", detail)
            self.assertIn('lint', index)
            self.assertIn('bad indent', index)
            self.assertIn('#validation', index)
            self.assertIn('Validation details', index)
            self.assertIn('file.py:12', detail)
            self.assertIn('Recorded from plan.md', detail)

    def test_evidence_scope_escaping_and_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for store in ('legacy', 'central'):
                for repo_name in ('one', 'two'):
                    repo = root / repo_name
                    path = repo / store / 'same'
                    path.mkdir(parents=True)
                    diagnostic = '<script>alert("bad")</script>' + 'x' * 6000
                    body = '- browser: unavailable\n  ```text\n  ' + diagnostic + '\n  - nested diagnostic\n  ```\n- tests: passed'
                    (path / 'plan.md').write_text('## Validation Performed\n' + body)
                    task = gui.Task('same', store, path, repo)
                    detail = gui.validation_details(task)
                    self.assertIn(html.escape(diagnostic), detail)
                    self.assertNotIn('<script>', detail)
                    self.assertIn('nested diagnostic', detail)
                    self.assertIn('Open plan.md source', detail)
                    self.assertIn('path=' + quote(str(path), safe=''), detail)
                    self.assertIn('active_repo=' + quote(str(repo), safe=''), detail)
                    self.assertIn('not supplied', detail)
                    for evidence, expected in (('', 'No executed'), ('- browser: skipped', 'ambiguous'), ('- OK', 'current-run freshness')):
                        (path / 'plan.md').write_text('## Validation Performed\n' + evidence)
                        self.assertIn(expected, gui.validation_details(gui.Task('same', store, path, repo)))

    def test_fragments_reload_changed_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            path = repo / '.agent' / 'checks'
            path.mkdir(parents=True)
            handler = object.__new__(gui.Handler)
            handler.repo = repo
            handler.task_home = repo / 'tasks'
            handler.all_repos = False
            handler.selected_repo = lambda query: (repo, '')
            fragments = []
            handler.send_fragment = lambda body, code=200: fragments.append(body)
            for body, state in (('', 'missing'), ('- tests: passed', 'passed'),
                                ('tests: passed\nbrowser: failed — no display', 'attention')):
                (path / 'plan.md').write_text('## Validation Performed\n' + body)
                handler.tasks_fragment({})
                handler.task_fragment('checks', 'contract', str(path), str(repo))
                for rendered in fragments[-2:]:
                    self.assertIn('validation-' + state, rendered)
                if state == 'attention':
                    self.assertIn('no display', fragments[-1])


if __name__ == '__main__':
    unittest.main()
