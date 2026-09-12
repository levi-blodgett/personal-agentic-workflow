"""Hermetic evidence and lineage boundary checks; no model grades asserted."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/lib'))
import review_record as review
import review_lineage as lineage


def complete(name='task', grade='C'):
    return (f'## Review Metadata\n- Task: {name}\n- Scope Reviewed: task delta\n'
            f'- Grade: {grade}\n- Quality Threshold: A- / no blockers\n'
            '- Threshold Result: below threshold\n\n## Blocking Production-Readiness Issues\n'
            '- Preserve immutable bytes and index.\n\n## Recommendations\n'
            '- Keep structural parser invariants; retain resolved code.\n')


class ReviewEvidence(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name).resolve()
        self.store = self.repo / 'store'
        self.path = self.store / 'task'
        self.path.mkdir(parents=True)
        (self.path / 'review.md').write_text(complete())

    def test_complete_adverse_and_formatted_high_grade_are_feedback(self):
        for grade in ('C', '**A-**.', '`B+`'):
            self.assertEqual(review.incomplete_reason(complete(grade=grade), 'task'), '')
        for text in ('# Review', complete(grade='pending'), complete(grade='Banana'),
                     complete().replace('task delta', 'pending'),
                     complete().replace('below threshold', 'pending'),
                     complete().replace('Preserve immutable bytes and index.', 'Pending.'),
                     complete().replace('- Task: task', '- Task: task\n- Task: task')):
            self.assertTrue(review.incomplete_reason(text, 'task'))

    def test_malformed_duplicate_metadata_and_optimistic_threshold_are_incomplete(self):
        self.assertTrue(review.incomplete_reason(complete() + '\n## Review Metadata\n- Grade: pending\n', 'task'))
        self.assertTrue(review.incomplete_reason(complete().replace('below threshold', 'met'), 'task'))
        for fence in ('```', '~~~', '````'):
            self.assertTrue(review.incomplete_reason(fence + 'markdown\n' + complete() + '\n' + fence, 'task'))

    def test_rerun_preserves_exact_prior_bytes_and_cannot_inherit_success(self):
        original = (self.path / 'review.md').read_bytes()
        review.begin(self.path, 'task', self.repo)
        self.assertEqual(next((self.path / 'review-history').glob('*.md')).read_bytes(), original)
        with self.assertRaises(ValueError):
            review.finish(self.path, 'task')  # exit zero with seed is insufficient
        pending = (self.path / 'review.md').read_text()
        attempt = review.fields(pending)['attempt']
        completed = complete() + '\n'
        completed = completed.replace('- Task: task', f'- Task: task\n- Quality Policy Version: 1\n- Attempt: {attempt}\n- Reviewed Code: fixture-sha\n- Completion: complete')
        (self.path / 'review.md').write_text(completed)
        self.assertIn('did not complete', review.check(self.path, 'task'))
        review.finish(self.path, 'task')
        self.assertEqual(review.check(self.path, 'task'), '')
        review.begin(self.path, 'task', self.repo)
        self.assertEqual(len(list((self.path / 'review-history').glob('*.md'))), 2)
        (self.path / 'review.md').write_text(completed)  # stale success from previous attempt
        with self.assertRaises(ValueError):
            review.finish(self.path, 'task')
        self.assertTrue(review.check(self.path, 'task'))

    def test_archive_failure_leaves_original_bytes(self):
        original = (self.path / 'review.md').read_bytes()
        (self.path / 'review-history').write_text('obstruction')
        with self.assertRaises(OSError):
            review.begin(self.path, 'task', self.repo)
        self.assertEqual((self.path / 'review.md').read_bytes(), original)

    def test_archived_source_resolves_with_recorded_old_path(self):
        (self.store / '.archive').mkdir()
        archived = self.store / '.archive/task'
        self.path.rename(archived)
        self.assertEqual(lineage.resolve(self.repo, self.store, 'task', str(self.path / 'review.md')), archived)
        evidence = lineage.lineage(self.repo, self.store, 'task')
        for expected in ('immutable bytes and index', 'structural parser invariants', 'legacy unknown', 'sha256='):
            self.assertIn(expected, evidence)

    def test_missing_ambiguous_escape_cross_repo_and_cycles_are_blockers(self):
        with self.assertRaises(ValueError):
            lineage.resolve(self.repo, self.store, 'missing')
        with self.assertRaises(ValueError):
            lineage.resolve(self.repo, self.store, '../task')
        with self.assertRaises(ValueError):
            lineage.resolve(self.repo, self.store, 'task', '/other/task/review.md')
        other = self.store / '.archive/task'
        other.mkdir(parents=True)
        (other / 'review.md').write_text(complete())
        with self.assertRaises(ValueError):
            lineage.resolve(self.repo, self.store, 'task')
        (other / 'review.md').unlink()
        other.rmdir()
        (self.path / 'metadata.gitconfig').write_text('[paw]\nrepo-root = /other/repo\ntask-name = task\n')
        with self.assertRaises(ValueError):
            lineage.resolve(self.repo, self.store, 'task')
        (self.path / 'metadata.gitconfig').write_text('[paw]\nprototype-source = task\n')
        with self.assertRaisesRegex(ValueError, 'cycle'):
            lineage.lineage(self.repo, self.store, 'task')

    def test_three_replacement_family_plan_mappings_retain_shared_findings(self):
        from quality_plan import errors
        families = {
            'cleanup': ('immutable content and index', 'owned-patch-postconditions'),
            'validation-clarity': ('structural nesting invariants', 'nested-check-outcomes'),
            'validation-reviewing': ('metadata cannot inject a rerun', 'metadata-boundary-reruns'),
        }
        for name, (invariant, check_name) in families.items():
            with self.subTest(family=name):
                plan = ('Quality policy version: 1\n\n## Acceptance Evidence\n'
                        '| Criterion | Observable behavior | Planned check | Evidence destination |\n'
                        '|---|---|---|---|\n'
                        f'| source blocker: {name} | {invariant} | {check_name} | validation/{check_name}.log and code identity |\n'
                        '\n## Post-Implementation Review Requirement\n'
                        'Independent Review after implementation: B+ / no blockers inherited from source; A- target.\n')
                self.assertEqual(errors(plan), [])
                self.assertIn(invariant, plan)
        # Overlapping ancestry is included once per identity, with each origin retained.
        root = self.store / 'root'
        root.mkdir()
        (root / 'review.md').write_text(complete('root'))
        (self.path / 'metadata.gitconfig').write_text('[paw]\nprototype-source = root\n')
        evidence = lineage.lineage(self.repo, self.store, 'task')
        self.assertEqual(evidence.count('Source evidence:'), 2)
        self.assertIn(str(root / 'review.md'), evidence)
        self.assertIn(str(self.path / 'review.md'), evidence)

    def test_post_spawn_failure_example_reaps_owned_child(self):
        # Executable planning example, not a claim about historical launch code.
        import subprocess
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            with self.assertRaises(OSError):
                try:
                    raise OSError('fixture bookkeeping failure after spawn')
                finally:
                    child.terminate()
                    child.wait(timeout=5)
            self.assertIsNotNone(child.poll())
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()


if __name__ == '__main__':
    unittest.main()
