"""Physical Markdown boundaries and scoped enumeration."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'scripts/lib/markdown_budget.py'
spec = importlib.util.spec_from_file_location('markdown_budget', MODULE)
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)


class BudgetTests(unittest.TestCase):
    def test_physical_boundaries(self):
        for ending in (b'\n', b'\r\n'):
            for final in (True, False):
                for count in (0, 150, 151):
                    data = ending.join([b'<!-- counted -->'] * count)
                    if count and final:
                        data += ending
                    self.assertEqual(budget.line_count(data), count)
        self.assertEqual(budget.line_count(b'\n' * 151), 151)
        self.assertEqual(budget.line_count(b'```\n### Archived Phases\n' + b'\n' * 149), 151)

    def test_task_errors_and_symlink_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            task = root / 'task'
            task.mkdir()
            doc = task / 'nested space' / 'PLAN.MD'
            doc.parent.mkdir()
            doc.write_bytes(b'\n' * 151)
            errors = budget.check_paths(budget.tree_paths(task))
            self.assertIn(str(doc), errors[0])
            self.assertIn('151', errors[0])
            self.assertIn('150', errors[0])
            doc.write_bytes(b'\n' * 150)
            self.assertEqual(budget.check_paths(budget.tree_paths(task)), [])
            outside = root / 'outside'
            outside.mkdir()
            (outside / 'secret.md').write_bytes(b'\n' * 200)
            (task / 'escape').symlink_to(outside, target_is_directory=True)
            self.assertNotIn(outside / 'secret.md', budget.tree_paths(task))
            (task / 'link.md').symlink_to(outside / 'secret.md')
            self.assertIn('symlink', budget.check_paths(budget.tree_paths(task))[0])

    def test_repository_tracks_new_case_and_space_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('ignored/\n')
            (root / 'ignored').mkdir()
            (root / 'ignored/no.md').write_bytes(b'\n' * 151)
            doc = root / 'New doc.MD'
            doc.write_bytes(b'\n' * 151)
            self.assertEqual(budget.repository_paths(root), [doc])
            self.assertTrue(budget.check_paths(budget.repository_paths(root)))
            doc.write_bytes(b'\n' * 150)
            self.assertEqual(budget.check_paths(budget.repository_paths(root)), [])
            subprocess.run(['git', '-C', str(root), 'add', 'New doc.MD'], check=True)
            self.assertEqual(budget.repository_paths(root), [doc])


if __name__ == '__main__':
    unittest.main()
