"""Read-only, same-repository review lineage resolution for replacement prompts."""
import hashlib
import sys
from pathlib import Path

from review_record import check, fields, metadata


def resolve(repo: Path, store: Path, name: str, recorded: str = '') -> Path:
    if not name or name in {'.', '..'} or '/' in name or '\0' in name:
        raise ValueError(f'invalid source task identity {name!r}')
    candidates = [store / name, store / '.archive' / name, repo / '.agent' / name]
    valid = []
    for path in candidates:
        if not path.exists():
            continue
        if path.resolve() != path.absolute():
            raise ValueError(f'source path escape: {path}')
        saved_repo, saved_name = metadata(path, 'repo-root'), metadata(path, 'task-name')
        if saved_repo and Path(saved_repo).resolve() != repo.resolve():
            raise ValueError(f'cross-repo source identity: {path}')
        if saved_name and saved_name != name:
            raise ValueError(f'conflicting task identity: {path}')
        reason = check(path, name)
        if reason:
            raise ValueError(f'{path}/review.md: {reason}')
        valid.append(path)
    if recorded:
        saved = Path(recorded).resolve()
        if saved.name != 'review.md' or saved.parent not in candidates:
            raise ValueError(f'recorded source path is outside the same-repo task identity: {recorded}')
    if not valid:
        raise ValueError(f'missing source review for {name}; restore same-repo source evidence')
    if len(valid) > 1:
        raise ValueError(f'ambiguous active/archive/legacy sources for {name}: {valid}')
    return valid[0]


def lineage(repo: Path, store: Path, name: str) -> str:
    seen, records, hashes = set(), [], {}
    recorded = ''
    while name:
        if name in seen:
            raise ValueError(f'source lineage cycle at {name}')
        seen.add(name)
        path = resolve(repo, store, name, recorded)
        text = (path / 'review.md').read_text()
        digest = hashlib.sha256(text.encode()).hexdigest()
        data = fields(text)
        identity = f'{path}/review.md; sha256={digest}; attempt={data.get("attempt", "legacy unknown")}; code={data.get("reviewed code", "legacy unknown")}'
        records.append('\nSource evidence: ' + identity)
        if digest in hashes:
            records.append('Same evidence as ' + hashes[digest] + '; retain both origins.')
        else:
            hashes[digest] = str(path)
            records.append(text)
        name = metadata(path, 'prototype-source')
        recorded = metadata(path, 'prototype-review')
    return '\n'.join(records)


if __name__ == '__main__':
    try:
        print(lineage(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), sys.argv[3]))
    except (OSError, ValueError) as error:
        print(f'Source review planning blocker: {error}. Restore evidence or Run Review; do not clean up source work.', file=sys.stderr)
        sys.exit(1)
