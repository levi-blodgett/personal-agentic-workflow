"""Bounded linked evidence and interruption-safe completed-phase compaction."""
import hashlib
import os
from pathlib import Path
import re
import tempfile

from markdown_budget import line_count, LIMIT

VALIDATION_LINK = re.compile(r'^<!-- PAW:VALIDATION ([^\n]+) -->$', re.M)


def validation_text(plan: Path) -> str:
    """Read explicitly linked validation only; other history remains on-demand."""
    text = plan.read_text(errors='replace')
    def load(match):
        name = Path(match[1])
        target = plan.parent / name
        if (name.is_absolute() or '..' in name.parts or target.is_symlink()
                or not target.resolve().is_relative_to(plan.parent.resolve())):
            return '- Linked evidence: failed; invalid task-local evidence path ' + match[1]
        try:
            content = target.read_text()
            if VALIDATION_LINK.search(content):
                raise ValueError('nested validation references are not supported')
            return content
        except (OSError, ValueError) as error:
            return f'- Linked evidence: failed; {target}: {error}'
    text = re.sub(r'^\[Validation evidence\]\([^\n]+\)\.\n(?=<!-- PAW:VALIDATION )', '', text, flags=re.M)
    return VALIDATION_LINK.sub(load, text)


def atomic_replace(path: Path, before: bytes, after: bytes) -> None:
    """Keep the original until the full replacement exists; reject observed concurrent edits."""
    if path.is_symlink():
        raise ValueError(f'{path}: cannot replace a symlink document')
    fd, temporary = tempfile.mkstemp(prefix='.paw-document-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(after)
            output.flush()
            os.fsync(output.fileno())
        if path.read_bytes() != before:
            raise ValueError(f'{path}: changed during document update; retry from current bytes')
        os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def save_detail(parent: Path, label: str, content: str) -> str:
    data = content.encode()
    name = f'{label}-{hashlib.sha256(data).hexdigest()[:12]}.md'
    path = parent / name
    fd, temporary = tempfile.mkstemp(prefix='.paw-detail-', dir=parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            if path.is_symlink() or path.read_bytes() != data:
                raise ValueError(f'{path}: conflicting detail; preserve it and inspect')
    finally:
        os.unlink(temporary)
    return name


def compact(task: Path) -> int:
    path = task / 'plan.md'
    before = path.read_bytes()
    lines = before.decode().splitlines(keepends=True)
    kept, completed, current = [], [], []
    active = False
    for line in lines:
        if line.startswith('## '):
            if current:
                completed.append(''.join(current)); current = []
            active = line.startswith('## Implementation Phases')
        if active and line.startswith('- [x]'):
            if current:
                completed.append(''.join(current))
            current = [line]
        elif current and (line.startswith((' ', '\t')) or not line.strip()):
            current.append(line)
        else:
            if current:
                completed.append(''.join(current)); current = []
            kept.append(line)
    if current:
        completed.append(''.join(current))
    if not completed:
        return 0
    # Write each complete checklist record first. Interrupted retries reuse its identity.
    links, groups, group = [], [], '# Completed implementation records\n\n'
    for record in completed:
        if line_count((group + record).encode()) > 140 and group != '# Completed implementation records\n\n':
            groups.append(group)
            group = '# Completed implementation records\n\n'
        group += record
    groups.append(group)
    for group in groups:
        name = save_detail(task, 'completed-phase', group.rstrip() + '\n')
        links.append(f'- [Completed phases]({name})\n')
    after = ''.join(kept).rstrip() + '\n\n### Completed phase details\n' + ''.join(links)
    atomic_replace(path, before, after.encode())
    return len(completed)


if __name__ == '__main__':
    import sys
    try:
        count = compact(Path(sys.argv[1]))
        print(f'compact: archived {count} completed phase(s) into linked files' if count else 'compact: nothing to archive')
    except (OSError, ValueError) as error:
        print(f'error: {error}', file=sys.stderr)
        sys.exit(1)


def split_long_fences(text: str) -> str:
    lines, output, block, fence = text.splitlines(keepends=True), [], [], ''
    for line in lines:
        marker = re.match(r'^(`{3,}|~{3,})', line)
        if not fence:
            if marker:
                fence, block = marker[1], [line]
            else:
                output.append(line)
        else:
            block.append(line)
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence):
                if len(block) > 135:
                    for start in range(1, len(block) - 1, 120):
                        output.extend([block[0], *block[start:min(start+120, len(block)-1)], fence+'\n', '\n'])
                else:
                    output.extend(block)
                block, fence = [], ''
    output.extend(block)
    return ''.join(output)


def detail_pages(text: str) -> list[str]:
    """Split at record/paragraph boundaries outside fences; never truncate a record."""
    lines = split_long_fences(text).splitlines(keepends=True)
    pages, start, safe, fence = [], 0, [], ''
    for index, line in enumerate(lines):
        marker = re.match(r'^\s*(`{3,}|~{3,})', line)
        if not fence and (not line.strip() or line.startswith(('#', '- ', '* '))):
            safe.append(index)
        if marker:
            token = marker[1]
            if not fence:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = ''
        if index - start >= 139:
            choices = [point for point in safe if start < point <= start + 139]
            if not choices:
                raise ValueError('Markdown has an indivisible record over 140 lines; shorten it manually')
            end = choices[-1]
            pages.append(''.join(lines[start:end]))
            start = end
    if start < len(lines):
        pages.append(''.join(lines[start:]))
    return pages


def sections(text: str) -> list[tuple[str, str]]:
    result, heading, body, fence = [], '', [], ''
    for line in text.splitlines(keepends=True):
        marker = re.match(r'^\s*(`{3,}|~{3,})', line)
        if not fence and line.startswith('## '):
            result.append((heading, ''.join(body)))
            heading, body = line, []
        else:
            body.append(line)
        if marker:
            token = marker[1]
            if not fence:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = ''
    result.append((heading, ''.join(body)))
    return result


def migrate_document(path: Path) -> dict:
    """Move valuable reference detail to bounded siblings, retaining policy/status in plans."""
    before = path.read_bytes()
    text = before.decode()
    if line_count(before) <= LIMIT:
        return {}
    parts = sections(text)
    protected = ('Objective', 'Open Questions', 'Implementation Phases', 'Acceptance Criteria',
                 'Current Status', 'Approval Boundaries', 'Non-Goals', 'Risks', 'Prototype Source',
                 'Finding Dispositions', 'Acceptance Evidence', 'Post-Implementation Review',
                 'PR Contribution', 'PR Tracking', 'Visual Evidence', 'Task Review')
    moved = []
    candidates = [(index, heading, body) for index, (heading, body) in enumerate(parts)
                  if heading and heading.strip() not in {'## Visual Evidence', '## PR Tracking', '## PR Contribution'} and not (path.name == 'plan.md' and heading[3:].startswith(protected))
                  and 'PAW:CONTRIBUTION' not in body]
    candidates.sort(key=lambda row: len(row[2].splitlines()), reverse=True)
    for index, heading, body in candidates:
        if line_count(''.join(h + b for h, b in parts).encode()) <= 145:
            break
        if len(body.splitlines()) <= 5:
            continue
        label = re.sub(r'[^a-z0-9]+', '-', heading[3:].lower()).strip('-')[:45]
        pages = detail_pages(body)
        links = []
        for page in pages:
            name = save_detail(path.parent, path.stem + '-' + label, page)
            moved.append(name)
            if heading.strip() == '## Validation Performed' and path.name == 'plan.md':
                links.append(f'[Validation evidence]({name}).\n<!-- PAW:VALIDATION {name} -->\n')
            else:
                links.append(f'[Retained {heading[3:].strip()} details]({name}).\n')
        parts[index] = (heading, '\n' + ''.join(links) + '\n')
    after = ''.join(h + b for h, b in parts)
    if line_count(after.encode()) > 145:
        # Drop redundant blank spacing, retaining paragraph/heading separation.
        after = re.sub(r'\n\n(?=## )', '\n', after)
        after = re.sub(r'(?m)^(## [^\n]+)\n\n', r'\1\n', after)
    if line_count(after.encode()) > LIMIT:
        raise ValueError(f'{path}: protected approved content still exceeds 150; editorial reconciliation required')
    atomic_replace(path, before, after.encode())
    return {'path': str(path), 'before_sha256': hashlib.sha256(before).hexdigest(),
            'after_sha256': hashlib.sha256(after.encode()).hexdigest(),
            'before_lines': line_count(before), 'after_lines': line_count(after.encode()),
            'details': moved}
