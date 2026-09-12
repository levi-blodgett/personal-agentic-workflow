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

    def test_named_future_outcomes_stay_recorded(self):
        for result in ('expected to run later', 'must run later', 'should run later',
                       'will run later', 'run later', 'next run pending'):
            for shape in ('- browser: {}', '- tests: passed; browser: {}',
                          '- tests: passed\n  browser: {}'):
                with self.subTest(result=result, shape=shape):
                    body = shape.format(result)
                    self.assertEqual(self.state(body), 'recorded')
                    self.assertIn('validation-recorded', gui.validation_cell(
                        '## Validation Performed\n' + body, '/task/checks'))

    def test_instruction_like_check_names_preserve_outcomes(self):
        for name in ('Run browser', 'next check', 'will check', 'must check',
                     'should check', 'planning-only checks', 'Planning validation only checks'):
            for shape in ('- tests: passed\n- {}: failed',
                          '- tests: passed\n  - {}: failed',
                          '- tests: passed; {}: failed'):
                with self.subTest(name=name, shape=shape):
                    body = shape.format(name)
                    self.assertEqual(self.state(body), 'attention')
                    self.assertIn('validation-attention', gui.validation_cell(
                        '## Validation Performed\n' + body, '/task/checks'))
                    self.assertEqual(self.state(body.replace(': failed', ': unknown')), 'recorded')

    def test_instruction_names_resolve_only_exact_reruns(self):
        rerun = 'passed (rerun; supersedes earlier result)'
        for name in ('Run browser', 'next check', 'will check', 'must check',
                     'should check', 'planning-only checks'):
            for shape in ('- tests: passed; {}: failed', '- tests: passed\n  {}: failed'):
                body = shape.format(name) + '\n- tests: ' + rerun
                with self.subTest(name=name, shape=shape):
                    self.assertEqual(self.state(body), 'attention')
                    self.assertEqual(self.state(body + '\n- ' + name + ': ' + rerun), 'passed')
                    with tempfile.TemporaryDirectory() as directory:
                        path = Path(directory)
                        (path / 'plan.md').write_text('## Validation Performed\n' + body)
                        detail = gui.validation_details(gui.Task('checks', 'legacy', path, path))
                        self.assertIn('validation-attention', detail)
                        self.assertIn(name + ': failed', detail)
                        self.assertIn('Partially superseded record', detail)

    def test_multiline_log_does_not_resolve_failure(self):
        body = '- browser: failed\n- tests: passed\n  Log:\n    browser: passed (rerun; supersedes earlier result)'
        self.assertEqual(self.state(body), 'attention')
        self.assertIn('validation-attention', gui.validation_cell(
            '## Validation Performed\n' + body, '/task/checks'))

    def test_list_shape_and_vocabulary_invariants(self):
        outcomes = {'failed': 'attention', 'unavailable': 'attention',
                    'expected to run later': 'recorded', 'must be rerun': 'recorded',
                    'should run later': 'recorded', 'will run later': 'recorded',
                    'unfamiliar outcome': 'recorded', 'passed': 'passed'}
        for bullet in ('- ', '* ', '1. '):
            for indent in ('', '  ', '    ', '\t'):
                for name in ('browser', 'Run browser', 'next check'):
                    for outcome, expected in outcomes.items():
                        check = indent + bullet + name + ': ' + outcome
                        for body in (check, '- unrelated: passed\n' + check):
                            with self.subTest(body=body):
                                self.assertEqual(self.state(body), expected)

    def test_metadata_blocks_preserve_case_sensitive_peer_reruns(self):
        rerun = 'Run browser: passed (rerun; supersedes earlier result)'
        for indent, deeper in (('  ', '    '), ('\t', '\t\t')):
            for bullet in ('', '- ', '* ', '1. '):
                for block in (deeper + rerun,
                              deeper + '```text\n' + deeper + rerun + '\n' + deeper + '```',
                              deeper + '<!--\n' + deeper + rerun + '\n' + deeper + '-->'):
                    body = '- Run browser: failed\n- tests: passed\n' + indent + bullet + 'Log:\n' + block
                    with self.subTest(body=body):
                        self.assertEqual(self.state(body), 'attention')
                        self.assertEqual(self.state(body + '\n' + indent + rerun.lower()), 'attention')
                        self.assertEqual(self.state(body + '\n' + indent + rerun), 'passed')

    def test_metadata_owns_descendants_and_compound_continuations(self):
        rerun = 'browser: passed (rerun; supersedes earlier result)'
        for key in ('Command', 'Tier', 'Log', 'Note', 'Source', 'Provenance', 'Rationale', 'Validation tier chosen'):
            for label in (key + ':', '- ' + key + ': inline; ' + rerun,
                          key + ': inline', '- tests: passed; ' + key + ':'):
                for descendants in ('    ' + rerun,
                                    '    - deeper:\n\n      - ' + rerun,
                                    '    ### Context\n    - ' + rerun,
                                    '    ### Implementation results\n    - ' + rerun):
                    body = '- browser: failed\n- tests: passed\n  ' + label + '\n' + descendants
                    with self.subTest(key=key, label=label, descendants=descendants):
                        self.assertEqual(self.state(body), 'attention')
                        self.assertEqual(self.state(body + '\n  - ' + rerun), 'passed')
                        self.assertEqual(self.state(body + '\n- ' + rerun), 'passed')
        # A compound metadata tail owns the following indented continuation.
        body = '- browser: failed\n- tests: passed; Log: inline\n  ' + rerun
        self.assertEqual(self.state(body), 'attention')
        # Initial indentation must survive even when a section has no parent bullet.
        self.assertEqual(self.state('  Log:\n    browser: failed\n  tests: passed'), 'passed')

    def test_metadata_scope_and_real_sibling_boundaries(self):
        rerun = 'browser: passed (rerun; supersedes earlier result)'
        for prefix in ('', '- '):
            body = '- browser: failed\n- tests: passed\n  ' + prefix + 'Log:\n    ### Context\n    - ' + rerun
            self.assertEqual(self.state(body + '\n  sibling: failed\n- ' + rerun), 'attention')
            self.assertEqual(self.state(body + '\n  tests: passed\n- ' + rerun), 'passed')
            scoped = '### Context\n- tests: passed\n  Log:\n    ### Implementation results\n    - browser: failed'
            self.assertEqual(self.state(scoped), 'missing')
            self.assertEqual(self.state(scoped + '\n### Implementation results\n- tests: passed'), 'passed')
        self.assertEqual(self.state('- tests: passed; Log: note; browser: failed'), 'passed')
        self.assertEqual(self.state('- tests: failed; Log: note; tests: passed (rerun; supersedes earlier result)'), 'attention')

    def test_diagnostic_rerun_movement_preserves_fragment_history(self):
        rerun = 'Run browser: passed (rerun; supersedes earlier result)'
        hostile = '<script>alert("diagnostic")</script>'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for store in ('central', 'legacy'):
                path = root / store / 'same'
                path.mkdir(parents=True)
                for metadata in ('  Log:', '  - Note: inline', '  tests: passed; Source: inline'):
                    first = '- tests: passed; Run browser: failed'
                    body = first + '\n' + metadata + '\n    ' + hostile + '\n    ' + rerun
                    for later, expected in (('', 'attention'),
                                            ('\n- tests: passed (rerun; supersedes earlier result)', 'attention'),
                                            ('\n  ' + rerun, 'passed')):
                        plan = '## Validation Performed\n' + body + later
                        (path / 'plan.md').write_text(plan)
                        task = gui.Task('same', store, path, root)
                        detail = gui.validation_details(task)
                        for fragment in (gui.validation_cell(plan, '/task/same'), detail):
                            self.assertIn('validation-' + expected, fragment)
                        self.assertIn(html.escape(body), detail)
                        self.assertNotIn('<script>', detail)
                        self.assertIn('path=' + quote(str(path), safe=''), detail)
                        self.assertIn('active_repo=' + quote(str(root), safe=''), detail)
                        if 'tests: passed (rerun' in later:
                            self.assertIn('Partially superseded record', detail)
                        # An independent peer failure cannot disappear on browser resolution.
                        self.assertEqual(gui.validation_state(plan + '\n  sibling: failed'), 'attention')

    def test_unnamed_instruction_tail_cannot_resolve_failure(self):
        body = '- browser: failed\n- Run tests; browser: passed (rerun; supersedes earlier result)'
        self.assertEqual(self.state(body), 'attention')
        self.assertEqual(self.state(body + '\n- browser: passed (rerun; supersedes earlier result)'), 'passed')

    def test_nested_legacy_list_results_are_not_discarded(self):
        for result, expected in (('lint failed', 'attention'), ('lint passed', 'passed'),
                                 ('lint something unfamiliar', 'recorded')):
            for indent in ('', '  ', '    '):
                with self.subTest(result=result, indent=indent):
                    self.assertEqual(self.state('- tests: passed\n' + indent + '- ' + result), expected)

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
                self.assertIn(reason, gui.validation_details(gui.Task('checks', 'legacy', path, repo)))

    def test_nested_outcomes_and_diagnostic_exclusions(self):
        outcomes = {'passed': 'passed', 'failed': 'attention', 'did not pass': 'attention',
                    'exit 1': 'attention', 'exit 0': 'passed', 'unknown': 'recorded',
                    'not executed': 'recorded', 'not verified': 'recorded', 'pending': 'recorded',
                    'unavailable': 'attention', 'blocked': 'attention', 'skipped': 'recorded',
                    'unfamiliar wording': 'recorded', 'exit code 2': 'attention',
                    'exit status: 3': 'attention', 'not OK': 'attention',
                    'not successful': 'attention', 'passed?': 'recorded',
                    'OK': 'passed', 'succeeded': 'passed', 'successful': 'passed',
                    'failed — planning-only expected output': 'attention'}
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

    def test_partial_resolution_preserves_record_and_active_reason(self):
        body = '- tests: passed\n  browser: failed\n- tests: passed (rerun; supersedes earlier result)'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'plan.md').write_text('## Validation Performed\n' + body)
            detail = gui.validation_details(gui.Task('checks', 'legacy', path, path))
            self.assertIn('Partially superseded record — Needs attention', detail)
            self.assertIn('browser: failed', detail)
            self.assertIn(html.escape(body.split('\n- tests:')[0]), detail)

    def test_metadata_cannot_inject_compound_reruns(self):
        for key in ('Command', 'Log', 'Source', 'Tier', 'Note'):
            body = '- browser: failed\n- ' + key + ': diagnostic; browser: passed (rerun; supersedes earlier result)'
            with self.subTest(key=key):
                self.assertEqual(self.state(body), 'attention')

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
                        ('- tests: passed\n  - lint failed', 'attention', 'lint failed'),
                        ('- tests: passed\n  browser: expected to run later', 'recorded', 'browser: expected'),
                        ('### Context\n- tests: passed', 'missing', 'No executed'),
                    ):
                        plan = '## Validation Performed\n' + body
                        (path / 'plan.md').write_text(plan)
                        task = gui.Task('same', store, path, repo)
                        for rendered in (gui.validation_cell(plan, '/task/same'), gui.validation_details(task)):
                            self.assertIn('validation-' + state, rendered)
                        self.assertIn(reason, gui.validation_details(task))
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
        for body in ('- Run tests', '- Note: not run', '- Command: echo failed'):
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
        for body in ('', '- <check-name>: <outcome>\n  Command: <command>\n  Tier: <tier>\n  Log: <log>', '- <commands/results>', '- TODO', '- Pending.', '- <command> — <result, including counts/output highlights>\n- Code best-practices checklist applied — see `prompts/prompt_instructions.md` "Code Best Practices".'):
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
            '- Planning-only package/document checks: passed.': 'passed',
            '- Tests did not pass.': 'attention', '- Tests: not passed.': 'attention',
            '- Tests: 0 failures, 0 errors.': 'recorded',
            '- Tests: expected passed after implementation.': 'recorded',
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

    def test_dashboard_has_one_linked_status_for_each_state(self):
        from html.parser import HTMLParser
        class Cell(HTMLParser):
            def __init__(self):
                super().__init__()
                self.links, self.text = [], ''
                self.assert_no_paragraph = True
            def handle_starttag(self, tag, attrs):
                if tag == 'a':
                    self.links.append(dict(attrs))
                self.assert_no_paragraph = self.assert_no_paragraph and tag not in ('div', 'p')
            def handle_data(self, data):
                self.text += data
        for body, label in (('', 'Unvalidated'), ('- tests: passed', 'Passed'),
                            ('- tests: failed', 'Attention'), ('- browser: not run', 'Recorded')):
            cell = Cell()
            cell.feed(gui.validation_cell('## Validation Performed\n' + body, '/task/same?path=one&active_repo=repo'))
            self.assertEqual(cell.text, label)
            self.assertEqual(len(cell.links), 1)
            self.assertEqual(cell.links[0]['href'], '/task/same?path=one&active_repo=repo#validation')
            self.assertIn('Validation: ' + label, cell.links[0]['aria-label'])
            self.assertTrue(cell.assert_no_paragraph)

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
            self.assertNotIn('lint', index)
            self.assertNotIn('bad indent', index)
            self.assertIn('#validation', index)
            self.assertIn('Validation: Attention', index)
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
