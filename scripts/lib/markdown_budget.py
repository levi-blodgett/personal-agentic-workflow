"""Optional AI authoring audit of physical Markdown lines; no runtime wiring."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

LIMIT = 150


def line_count(data: bytes) -> int:
    """LF and CRLF are physical line endings; count the unterminated final line."""
    return data.count(b'\n') + int(bool(data) and not data.endswith(b'\n'))


def tree_paths(root: Path) -> list[Path]:
    """Enumerate an explicitly selected package without following directory links."""
    if root.is_symlink():
        raise ValueError(f'{root}: symlink package; select a physical task directory')
    if not root.is_dir():
        raise ValueError(f'{root}: Markdown package directory is missing')
    paths = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(name for name in dirs if name != '.git')
        paths.extend(Path(directory) / name for name in files if name.lower().endswith('.md'))
    return sorted(paths)


def repository_paths(root: Path) -> list[Path]:
    """Tracked and new nonignored Markdown, including dot directories and case variants."""
    result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z', '--cached',
                             '--others', '--exclude-standard'], capture_output=True, check=True)
    paths = set()
    for name in result.stdout.split(b'\0'):
        if not name.lower().endswith(b'.md'):
            continue
        path = root / os.fsdecode(name)
        for parent in path.relative_to(root).parents:
            if (root / parent).is_symlink():
                raise ValueError(f'{path}: symlink directory inside repository scope; use a regular local path')
        if path.exists() or path.is_symlink():
            paths.add(path)
    return sorted(paths)


def check_paths(paths: list[Path]) -> list[str]:
    errors = []
    for path in sorted(set(paths)):
        try:
            if path.is_symlink():
                raise ValueError('symlink Markdown path; use a regular file within the selected scope')
            count = line_count(path.read_bytes())
            if count > LIMIT:
                errors.append(f'{path}: {count} physical lines (limit: {LIMIT}); '
                              'shorten this file or split a coherent topic into a linked Markdown file')
        except (OSError, ValueError) as error:
            errors.append(f'{path}: {error}')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path)
    parser.add_argument('--task', type=Path)
    parser.add_argument('files', nargs='*', type=Path)
    args = parser.parse_args()
    try:
        paths = list(args.files)
        if args.repo:
            paths += repository_paths(args.repo)
        if args.task:
            paths += tree_paths(args.task)
        errors = check_paths(paths)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        errors = [str(error)]
    for error in errors:
        print(f'error: {error}', file=sys.stderr)
    return int(bool(errors))


if __name__ == '__main__':
    sys.exit(main())
