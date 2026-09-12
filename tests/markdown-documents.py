"""History must preserve failed evidence and survive interrupted compaction."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/lib'))
import markdown_documents as docs
import gui_server as gui


class Documents(unittest.TestCase):
    def test_linked_failures_and_missing_evidence_stay_visible(self):
        with tempfile.TemporaryDirectory() as temporary:
            task = Path(temporary)
            plan = task / 'plan.md'
            evidence = '### Implementation results\n- Browser: failed\n  Log: original.log\n- Lint: passed (rerun)\n'
            plan.write_text('## Validation Performed\n' + evidence)
            before = gui.validation_summary(plan.read_text())
            name = docs.save_detail(task, 'validation', evidence)
            plan.write_text('## Validation Performed\n<!-- PAW:VALIDATION ' + name + ' -->\n')
            after = gui.validation_summary(docs.validation_text(plan))
            self.assertEqual(before['state'], after['state'])
            self.assertEqual(before['entries'], after['entries'])
            (task / name).unlink()
            self.assertEqual(gui.validation_state(docs.validation_text(plan)), 'attention')

    def test_history_migration_retains_outcomes_identity_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            task = Path(temporary)
            plan = task / 'plan.md'
            evidence = '### Implementation results\n' + ''.join(
                f'- Browser {i}: failed\n  Command: browser-{i}\n  Tier: broader\n  Log: original-{i}.log at code abc\n'
                for i in range(45))
            plan.write_text('## Current Status\n- Estimated completion: 0%\n'
                            '## Validation Performed\n' + evidence + '## Risks\n- Source B1 remains open.\n')
            before = gui.validation_summary(plan.read_text())
            result = docs.migrate_document(plan)
            after = gui.validation_summary(docs.validation_text(plan))
            self.assertNotEqual(result['before_sha256'], result['after_sha256'])
            self.assertIn('Source B1 remains open', plan.read_text())
            signatures = lambda summary: [(c.name, c.outcome, c.scope, c.superseded) for c in summary['checks'] if c.kind == 'check']
            self.assertEqual(signatures(before), signatures(after))
            self.assertEqual(docs.migrate_document(plan), {})
            for path in task.glob('*.md'):
                self.assertLessEqual(docs.line_count(path.read_bytes()), 150)

    def test_detail_write_failure_retries_without_partial_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            task = Path(temporary)
            with patch.object(docs.os, 'fsync', side_effect=OSError('injected write failure')):
                with self.assertRaises(OSError):
                    docs.save_detail(task, 'completed-phase', 'original evidence\n')
            self.assertEqual(list(task.iterdir()), [])
            name = docs.save_detail(task, 'completed-phase', 'original evidence\n')
            self.assertEqual((task / name).read_text(), 'original evidence\n')

    def test_compact_preserves_oversized_indivisible_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            task = Path(temporary)
            record = '- [x] Complete.\n  Progress: retained.\n' + '  valuable detail\n' * 151
            (task / 'plan.md').write_text('## Implementation Phases\n' + record)
            self.assertEqual(docs.compact(task), 1)
            self.assertTrue(any(record in p.read_text() for p in task.glob('completed-phase-*.md')))

    def test_compact_interrupt_retry_and_idempotency(self):
        with tempfile.TemporaryDirectory() as temporary:
            task = Path(temporary)
            plan = task / 'plan.md'
            source = ('## Implementation Phases\n- [x] Finished behavior.\n'
                      '  Progress: Browser failed; source abc; original.log\n'
                      '- [ ] Next behavior.\n## Current Status\n- Estimated completion: 50%\n')
            plan.write_text(source)
            with patch.object(docs.os, 'replace', side_effect=OSError('injected replacement failure')):
                with self.assertRaises(OSError):
                    docs.compact(task)
            self.assertEqual(plan.read_text(), source)
            self.assertEqual(docs.compact(task), 1)
            first = plan.read_bytes()
            self.assertEqual(docs.compact(task), 0)
            self.assertEqual(plan.read_bytes(), first)
            details = list(task.glob('completed-phase-*.md'))
            self.assertEqual(len(details), 1)
            self.assertIn('Browser failed; source abc; original.log', details[0].read_text())
            self.assertNotIn('- [x]', plan.read_text())
            self.assertIn('- [ ] Next', plan.read_text())


if __name__ == '__main__':
    unittest.main()
