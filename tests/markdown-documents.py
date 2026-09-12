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
    def test_source_B1_exact_fenced_example(self):
        original = ('## Implementation Phases\n```markdown\n- [x] Example only\n'
                    '  Progress: example\n```\n- [ ] Real work\n')
        with tempfile.TemporaryDirectory() as temporary:
            task = Path(temporary)
            (task / 'plan.md').write_text(original)
            self.assertEqual(docs.compact(task), 0)
            self.assertEqual((task / 'plan.md').read_text(), original)

    def test_fence_matrix_preserves_examples_and_real_record_boundaries(self):
        for marker, indent, closed in [('```', '', True), ('~~~~', '   ', True),
                                       ('````', ' ', True), ('~~~', '  ', False)]:
            with self.subTest(marker=marker, indent=indent, closed=closed), tempfile.TemporaryDirectory() as temporary:
                task = Path(temporary)
                example = (indent + marker + 'markdown\n- [x] Example only\n'
                           '## Current Status\n- [ ] Fake pending\n'
                           + marker[0] * (len(marker) - 1) + '\n'
                           + ('~~~' if marker[0] == '`' else '```') + '\n'
                           + marker + ' trailing text is not a closer\n')
                if closed:
                    example += indent + marker + marker[0] + '  \n'
                real = '- [x] Real done\n  Progress: exact\n'
                tail = '- [ ] Real pending\n## Current Status\n- [x] Outside phases\n'
                original = '## Implementation Phases\n' + real + '- [ ] Existing pending\n' + example + tail
                (task / 'plan.md').write_text(original)
                self.assertEqual(docs.compact(task), 1)
                result = (task / 'plan.md').read_text()
                self.assertIn(example + tail, result)
                self.assertNotIn(real, result)
                self.assertEqual(list(task.glob('completed-phase-*.md'))[0].read_text(),
                                 '# Completed implementation records\n\n' + real)

    def test_fence_owned_by_completed_record_moves_intact(self):
        with tempfile.TemporaryDirectory() as temporary:
            task = Path(temporary)
            record = ('- [x] Done\n  Progress: preserved\n  ~~~~text\n'
                      '## Fake boundary\n- [x] Fake task\n  ~~~\n'
                      '  ~~~~ trailing text\n  ~~~~~\n  After fence\n\n')
            (task / 'plan.md').write_text('## Implementation Phases\n' + record + '- [ ] Pending\n')
            self.assertEqual(docs.compact(task), 1)
            self.assertEqual(list(task.glob('completed-phase-*.md'))[0].read_text(),
                             '# Completed implementation records\n\n' + record)
            self.assertIn('- [ ] Pending', (task / 'plan.md').read_text())

    def test_compact_detail_failure_and_collision_preserve_originals(self):
        for failure in ('write', 'collision', 'symlink'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                task = Path(temporary)
                plan = task / 'plan.md'
                source = '## Implementation Phases\n- [x] Done\n  Progress: original\n'
                plan.write_text(source)
                detail = '# Completed implementation records\n\n- [x] Done\n  Progress: original\n'
                if failure != 'write':
                    name = docs.save_detail(task, 'completed-phase', detail)
                    target = task / name
                    target.unlink()
                    if failure == 'symlink':
                        (task / 'original.md').write_text(detail)
                        target.symlink_to(task / 'original.md')
                    else:
                        target.write_text('conflicting evidence\n')
                    with self.assertRaises(ValueError):
                        docs.compact(task)
                    self.assertEqual(target.read_text(), detail if failure == 'symlink' else 'conflicting evidence\n')
                    self.assertEqual(target.is_symlink(), failure == 'symlink')
                else:
                    with patch.object(docs.os, 'fsync', side_effect=OSError('injected detail failure')):
                        with self.assertRaises(OSError):
                            docs.compact(task)
                    self.assertEqual(list(task.iterdir()), [plan])
                self.assertEqual(plan.read_text(), source)

    def test_concurrent_edit_survives_and_retry_reuses_detail(self):
        with tempfile.TemporaryDirectory() as temporary:
            task = Path(temporary)
            plan = task / 'plan.md'
            source = '## Implementation Phases\n- [x] Done\n  Progress: original\n'
            newer = source + '- [ ] New user edit\n'
            plan.write_text(source)
            replace = docs.atomic_replace
            def concurrent(path, before, after):
                path.write_text(newer)
                return replace(path, before, after)
            with patch.object(docs, 'atomic_replace', side_effect=concurrent):
                with self.assertRaisesRegex(ValueError, 'changed during'):
                    docs.compact(task)
            self.assertEqual(plan.read_text(), newer)
            detail = next(task.glob('completed-phase-*.md'))
            saved = detail.read_bytes()
            self.assertEqual(docs.compact(task), 1)
            self.assertIn('- [ ] New user edit', plan.read_text())
            self.assertEqual(list(task.glob('completed-phase-*.md')), [detail])
            self.assertEqual(detail.read_bytes(), saved)
            self.assertEqual(docs.compact(task), 0)

    def test_foreign_and_nested_evidence_cannot_supply_a_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            task = root / 'task'
            task.mkdir()
            foreign = root / 'foreign.md'
            foreign.write_text('- Browser: passed (rerun)\n')
            (task / 'alias.md').symlink_to(foreign)
            (task / 'nested.md').write_text('<!-- PAW:VALIDATION alias.md -->\n')
            for name in ('../foreign.md', str(foreign), 'alias.md', 'nested.md'):
                plan = task / 'plan.md'
                plan.write_text('## Validation Performed\n### Implementation results\n'
                                '<!-- PAW:VALIDATION ' + name + ' -->\n')
                self.assertEqual(gui.validation_state(docs.validation_text(plan)), 'attention')

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
