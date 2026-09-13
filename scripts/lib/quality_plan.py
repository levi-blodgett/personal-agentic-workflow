"""Opt-in structural checks for quality policy v1; no execution evidence required."""
import re
import sys
from pathlib import Path


def errors(text):
    if not re.search(r'^Quality policy version: 1\s*$', text, re.M):
        return []
    sections = dict(re.findall(r'^## ([^\n]+)\n(.*?)(?=^## |\Z)', text, re.M | re.S))
    problems = []
    table = sections.get('Acceptance Evidence', '')
    rows = [[cell.strip() for cell in line.strip().strip('|').split('|')]
            for line in table.splitlines() if line.strip().startswith('|')]
    if (len(rows) < 3 or rows[0] != ['Criterion', 'Observable behavior', 'Planned check', 'Evidence destination']
            or any(len(row) != 4 or not all(row) for row in rows[2:])):
        problems.append('Acceptance Evidence requires Criterion / Observable behavior / Planned check / Evidence destination and populated planned rows')
    review = sections.get('Post-Implementation Review Requirement', '')
    if not all(re.search(pattern, review, re.I) for pattern in
               [r'independent', r'A-', r'no (?:production )?blockers', r'implementation']):
        problems.append('Post-Implementation Review Requirement must name independent post-implementation Review, A- target and no blockers; preserve explicit inherited thresholds')
    return problems


if __name__ == '__main__':
    path = Path(sys.argv[1])
    problems = errors(path.read_text())
    for problem in problems:
        print(f'  WARN: {path}: {problem}')
    sys.exit(bool(problems))
