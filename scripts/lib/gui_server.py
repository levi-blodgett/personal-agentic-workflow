#!/usr/bin/env python3
"""Local-only PAW task dashboard server."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import signal
import shutil
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from functools import cached_property, wraps
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlencode, urlparse


# Imported by path as well as launched directly by the CLI/server.
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import review_record
import markdown_documents
import pr_publication


PAW_SCRIPT = Path(__file__).resolve().parents[1] / "paw"
TASK_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
LOG_TAIL_BYTES = 64 * 1024


QUEUE_LOCK = threading.RLock()


@contextmanager
def queue_lock():
    """Serialize queue reads and mutations within the threaded GUI server."""
    with QUEUE_LOCK:
        yield


# Only GET/render entrypoints establish a snapshot; POST guards always read live.
_READ_SNAPSHOT: ContextVar[dict | None] = ContextVar("gui_read_snapshot", default=None)


def read_snapshot(function):
    @wraps(function)
    def render(*args, **kwargs):
        if _READ_SNAPSHOT.get() is not None:
            return function(*args, **kwargs)
        token = _READ_SNAPSHOT.set({})
        try:
            return function(*args, **kwargs)
        finally:
            _READ_SNAPSHOT.reset(token)
    return render


def snapshot_value(key, read):
    snapshot = _READ_SNAPSHOT.get()
    if snapshot is None:
        return read()
    if key not in snapshot:
        snapshot[key] = read()
    return snapshot[key]


def git_value(repo: Path, *args: str) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def git_ok(repo: Path, *args: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0
    except Exception:
        return False


def physical(path: Path) -> Path:
    return path.expanduser().resolve()


def cksum(text: str) -> str:
    output = subprocess.check_output(["cksum"], input=text, text=True).split()
    return output[0]


def repo_common_dir(repo: Path) -> Path:
    raw = git_value(repo, "rev-parse", "--git-common-dir")
    if not raw:
        return physical(repo)
    common = Path(raw)
    if not common.is_absolute():
        common = repo / common
    return physical(common)


def repo_slug(repo: Path) -> str:
    safe = re.sub(r"[^A-Za-z0-9._]+", "-", physical(repo).name).strip("-") or "repo"
    return f"{safe}-{cksum(str(repo_common_dir(repo)))}"


def gui_state_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME")
    if root:
        return physical(Path(root) / "paw" / "gui")
    return physical(Path.home() / ".local" / "state" / "paw" / "gui")


def registry_path() -> Path:
    return gui_state_dir() / "repos.gitconfig"


def read_repo_registry(file: Path, startup_repo: Path) -> list[Path]:
    repos = [physical(startup_repo)]
    if file.exists():
        try:
            output = subprocess.check_output(
                ["git", "config", "--file", str(file), "--get-all", "paw.repo"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
            repos.extend(physical(Path(line)) for line in output.splitlines() if line.strip())
        except subprocess.CalledProcessError:
            pass
    unique: list[Path] = []
    seen: set[str] = set()
    for repo in repos:
        key = str(repo)
        if key not in seen:
            unique.append(repo)
            seen.add(key)
    return unique


def write_repo_registry(file: Path, repos: list[Path]) -> None:
    file.parent.mkdir(parents=True, exist_ok=True)
    if file.exists():
        file.unlink()
    for repo in repos:
        subprocess.run(["git", "config", "--file", str(file), "--add", "paw.repo", str(repo)], check=True)


def add_repo_to_registry(file: Path, startup_repo: Path, repo: Path) -> None:
    repos = read_repo_registry(file, startup_repo)
    if all(existing != repo for existing in repos):
        repos.append(repo)
    write_repo_registry(file, repos)


def normalize_git_repo(raw_path: str) -> tuple[Path | None, str]:
    if not raw_path.strip():
        return None, "repo path is required"
    candidate = physical(Path(raw_path.strip()))
    if not candidate.exists():
        return None, f"repo path does not exist: {candidate}"
    if not candidate.is_dir():
        return None, f"repo path is not a directory: {candidate}"
    root = git_value(candidate, "rev-parse", "--show-toplevel")
    if not root:
        return None, f"repo path is not a Git repo: {candidate}"
    return physical(Path(root)), ""


def metadata_value(file: Path, key: str) -> str:
    if _READ_SNAPSHOT.get() is not None:
        values = snapshot_value(("metadata", file), lambda: metadata_values(file))
        return values.get(f"paw.{key}", "")
    if not file.exists():
        return ""
    try:
        return subprocess.check_output(
            ["git", "config", "--file", str(file), "--get", f"paw.{key}"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return ""


def metadata_values(file: Path) -> dict[str, str]:
    if not file.exists():
        return {}
    try:
        output = subprocess.check_output(
            ["git", "config", "--null", "--file", str(file), "--list"],
            text=True, stderr=subprocess.DEVNULL,
        )
        # Git emits key/newline/value/NUL; last duplicate wins, as with --get.
        return {key: value.strip() for record in output.split("\0") if record
                for key, _, value in [record.partition("\n")]}
    except Exception:
        return {}


def parse_timestamp(value: str) -> float:
    if not value:
        return 0.0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def parse_log_filename_timestamp(path: Path) -> float:
    match = re.match(r"^([0-9]{8}T[0-9]{6}Z)-gui-", path.name)
    if not match:
        return 0.0
    try:
        return datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return 0.0


def file_mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def running_metadata_is_active(meta: Path) -> bool:
    if metadata_value(meta, "status") != "running":
        return False
    match = re.search(r"-([0-9]+)\.gitconfig$", meta.name)
    if not match:
        return True
    try:
        os.kill(int(match.group(1)), 0)
        return True
    except OSError:
        return False


@dataclass(frozen=True)
class ActiveRun:
    metadata: Path
    pid: int | None
    active: bool

    @property
    def cancellable(self) -> bool:
        return self.active and self.pid is not None


@dataclass(frozen=True)
class ActiveRunLogs:
    stdout: Path | None
    stderr: Path | None

    @property
    def available(self) -> bool:
        return self.stdout is not None or self.stderr is not None


def active_run_info(task_path: Path) -> ActiveRun | None:
    runs_dir = task_path / "runs"
    if not runs_dir.exists():
        return None
    for meta in sorted(runs_dir.glob("*.gitconfig"), reverse=True):
        if metadata_value(meta, "status") != "running":
            continue
        match = re.search(r"-([0-9]+)\.gitconfig$", meta.name)
        if not match:
            return ActiveRun(meta, None, True)
        pid = int(match.group(1))
        try:
            os.kill(pid, 0)
        except OSError:
            continue
        return ActiveRun(meta, pid, True)
    return None


def task_local_run_file(task_path: Path, path: Path) -> Path | None:
    try:
        resolved_task = physical(task_path)
        resolved_runs = resolved_task / "runs"
        resolved_path = physical(path)
        resolved_path.relative_to(resolved_runs)
    except Exception:
        return None
    if not resolved_path.is_file():
        return None
    return resolved_path


def active_run_logs(task_path: Path, run: ActiveRun | None) -> ActiveRunLogs | None:
    if not run or not run.cancellable:
        return None
    runs_dir = task_path / "runs"
    if not runs_dir.exists():
        return ActiveRunLogs(None, None)
    subcommand = metadata_value(run.metadata, "subcommand")
    start_time = parse_timestamp(metadata_value(run.metadata, "start-time"))
    patterns = []
    if subcommand:
        patterns.append(f"*-gui-*-{subcommand}-{task_path.name}.stdout.log")
    patterns.append("*-gui-*.stdout.log")
    for pattern in patterns:
        for stdout in sorted(runs_dir.glob(pattern), key=file_mtime, reverse=True):
            log_time = parse_log_filename_timestamp(stdout)
            if start_time and log_time and abs(start_time - log_time) > 300:
                continue
            safe_stdout = task_local_run_file(task_path, stdout)
            if not safe_stdout:
                continue
            stderr = stdout.with_name(stdout.name.removesuffix(".stdout.log") + ".stderr.log")
            safe_stderr = task_local_run_file(task_path, stderr)
            return ActiveRunLogs(safe_stdout, safe_stderr)
    return ActiveRunLogs(None, None)


def tail_text(path: Path | None) -> tuple[str, str]:
    if path is None:
        return "unavailable", ""
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            if size > LOG_TAIL_BYTES:
                handle.seek(size - LOG_TAIL_BYTES)
            data = handle.read(LOG_TAIL_BYTES)
    except OSError as exc:
        return "unavailable", f"could not read log: {exc}"
    text = data.decode("utf-8", errors="replace")
    if not text:
        return "empty", "(empty)"
    prefix = "[showing last 64 KiB]\n" if size > LOG_TAIL_BYTES else ""
    return "available", prefix + text


def process_command(pid: int) -> str:
    try:
        return subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def process_looks_like_paw(pid: int) -> bool:
    command = process_command(pid)
    if not command:
        return False
    normalized = command.replace("\\", "/")
    return "scripts/paw" in normalized or re.search(r"(^|[/\s])paw(?:\s|$|-)", normalized) is not None


def mark_run_cancelled(meta: Path, exit_status: int = 143) -> None:
    if not meta.exists():
        return
    subprocess.run(["git", "config", "--file", str(meta), "paw.status", "cancelled"], check=False)
    subprocess.run(["git", "config", "--file", str(meta), "paw.end-time", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())], check=False)
    subprocess.run(["git", "config", "--file", str(meta), "paw.exit-status", str(exit_status)], check=False)


def section_body(markdown: str, heading: str) -> str:
    lines = markdown.splitlines()
    wanted = f"## {heading}"
    body: list[str] = []
    in_section = False
    for line in lines:
        if line.strip() == wanted:
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if in_section:
            body.append(line)
    return "\n".join(body).strip()


def status_field(plan: str, label: str) -> str:
    body = section_body(plan, "Current Status")
    for line in body.splitlines():
        prefix = f"- {label}:"
        if line.startswith(prefix):
            return line[len(prefix) :].strip()
    return ""


def checklist_counts(plan: str) -> tuple[int, int]:
    body = section_body(plan, "Implementation Phases / Checklist") or section_body(plan, "Implementation Phases")
    total = len(re.findall(r"(?m)^- \[[ x]\]", body))
    done = len(re.findall(r"(?m)^- \[x\]", body))
    return done, total


def validation_entries(body: str) -> list[str]:
    """Keep complete source records, including indented/fenced diagnostics."""
    entries, current = [], []
    fence = ""
    comment = False
    for line in body.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if current and not fence and not comment and line and not line[0].isspace():
            entries.append("\n".join(current).strip("\n"))
            current = []
        current.append(line)
        if marker:
            token = marker[1]
            if not fence:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = ""
        if not fence:
            if "<!--" in line:
                comment = True
            if "-->" in line:
                comment = False
    if current:
        entries.append("\n".join(current).strip("\n"))
    return [entry for entry in entries if entry.strip()]


def _validation_lines(source: str):
    """Exclude diagnostic blocks from parsing, never from displayed source."""
    source = re.sub(r"<!--.*?(?:-->|$)", "", source, flags=re.S)
    fence = ""
    for line in source.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            token = marker[1]
            if not fence:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = ""
            continue
        if not fence and line.strip():
            yield line


@dataclass
class _ValidationCheck:
    source_index: int
    kind: str
    scope: str
    name: str
    outcome: str
    diagnostic: str
    text: str
    rerun: bool = False
    superseded: bool = False


_VALIDATION_METADATA = {"note", "provenance", "source", "rationale", "command", "tier", "log", "validation tier chosen"}


def _validation_check(text: str, source_index: int, scope: str) -> _ValidationCheck:
    clean = re.sub(r"^(?:[-*]|\d+\.)\s+", "", text.strip())
    named = re.match(r"([^:]*):\s*(.*)", clean)
    name = named[1].strip(" `") if named else ""
    result = named[2] if named else clean
    outcome, diagnostic = _validation_outcome(result, named=bool(name))
    if (re.fullmatch(r"<[^>]+>:\s*<[^>]+>", clean)
            or name.lower() in _VALIDATION_METADATA):
        outcome = "missing"
    kind = "context" if outcome == "missing" else "check"
    rerun = (diagnostic.strip().lower().rstrip(".") == "(rerun; supersedes earlier result)"
             and not re.search(r",|\s(?:and|or|/|&)\s", name, re.I))
    return _ValidationCheck(source_index, kind, scope, name, outcome, diagnostic, clean, rerun)


def _validation_outcome(text: str, *, named: bool) -> tuple[str, str]:
    """Read an explicit prefix; unknown named results cannot borrow tail outcomes."""
    text = text.strip()
    adverse = (r"failed|failures?|errors?|blocked|unavailable|did not pass|not (?:all (?:checks )?)?passed|"
               r"not (?:ok|successful|succeeded)|[1-9]\d* (?:failures?|errors?)|"
               r"exit(?: code| status)?[ :=]+[1-9]\d*")
    success = r"passed|ok|succeeded|successful|exit(?: code| status)?[ :=]+0"
    for pattern, outcome in ((adverse, "attention"), (success, "passed")):
        match = re.match(r"(?:" + pattern + r")(?![\w/-]|\.(?=\S))", text.rstrip("."), re.I)
        if match:
            tail = text[match.end():].strip()
            return ("recorded" if outcome == "passed" and tail.startswith("?") else outcome), tail
    if named:
        return "recorded", text
    if re.match(r"(?:run |will |must |should |expected |next |code best-practices checklist applied)", text, re.I):
        return "missing", text
    if re.fullmatch(r"(?:<[^>]+>(?:\s*—\s*<[^>]+>)?|todo|pending|not yet recorded)[.]?", text, re.I):
        return "missing", text
    if re.search(r"\bplanning[- ]only\b|\bplanning (?:investigation|validation) only\b", text, re.I):
        return "missing", text
    if re.search(r"\b(?:not (?:yet )?(?:run|executed)|has not run|no validation (?:has been )?(?:run|executed))\b", text, re.I):
        return "missing", text
    # Limited legacy command/check + outcome form, with the same prefix recognizer.
    legacy = re.match(r"^(`[^`]+`|(?:make|bats|python3?|node|lint|tests?)\b[^:;]*?)\s+(" + adverse + "|" + success + r")(?![\w/-]|\.(?=\S))", text.rstrip("."), re.I)
    if legacy and not re.search(r"\b(?:expected|will|must|should|would|not)\b", legacy[1], re.I):
        return _validation_outcome(text[legacy.start(2):], named=True)
    return "recorded", text


def validation_aggregate(states: set[str]) -> str:
    if "attention" in states:
        return "attention"
    if "recorded" in states or {"passed", "missing"} <= states:
        return "recorded"
    return "passed" if "passed" in states else "missing"


def _validation_scope(line: str) -> str:
    marker = re.sub(r"^(?:#{3,6}|[-*])\s+", "", line).strip().strip("* :.").lower()
    if marker in {"context", "development history"}:
        return marker
    if marker == "implementation results":
        return "implementation"
    if re.fullmatch(r"planning (?:investigation|validation) only", marker):
        return "context"
    return ""


def _validation_records(sources: list[str]):
    """Yield real records with source identity after diagnostic ownership is resolved."""
    metadata_indent = None
    for index, source in enumerate(sources):
        for line in _validation_lines(source):
            indent = len(line.expandtabs(4)) - len(line.expandtabs(4).lstrip())
            if metadata_indent is not None:
                if indent > metadata_indent:
                    continue
                metadata_indent = None
            parts = []
            # A semicolon starts another check only with an explicit named result.
            for part in re.split(r";\s*(?=[^;():]+:)", line):
                clean = re.sub(r"^(?:[-*]|\d+\.)\s+", "", part.strip())
                name = clean.partition(":")[0].strip(" `").lower()
                if ":" in clean and name in _VALIDATION_METADATA:
                    metadata_indent = indent
                    break
                parts.append(part)
            yield index, parts, indent


def _validation_checks(sources: list[str]) -> list[_ValidationCheck]:
    checks = []
    scope = "implementation"
    for index, parts, indent in _validation_records(sources):
        for line in parts:
            boundary = _validation_scope(line) if indent == 0 else ""
            if boundary:
                scope = boundary
            if boundary or line.lstrip().startswith("#"):
                checks.append(_ValidationCheck(index, "context", scope, "", "missing", "", line))
                break
            if (indent and not re.match(r"\s*(?:[-*]|\d+\.)\s+", line)
                    and not re.search(r":| [—–] ", line)):
                continue
            check = _validation_check(line, index, scope)
            checks.append(check)
            if check.kind == "context":
                break  # Unnamed instructions cannot introduce compound execution tails.
    return checks


def _validation_sources(plan: str) -> list[str]:
    # Section boundaries apply only outside fenced/commented diagnostic records.
    sources = []
    active = False
    for source in validation_entries(plan):
        headline = next(_validation_lines(source), "")
        if headline == "## Validation Performed":
            active = True
            remainder = source.partition("\n")[2].strip("\n")
            if remainder:
                sources.append(remainder)
        elif active and headline.startswith("## "):
            break
        elif active:
            sources.append(source)
    return sources


def validation_summary(plan: str) -> dict:
    sources = _validation_sources(plan)
    checks = _validation_checks(sources)
    executed = [check for check in checks if check.scope == "implementation" and check.kind == "check"]
    for position, check in enumerate(executed):
        if check.name and check.outcome == "passed" and check.rerun:
            for previous in executed[:position]:
                if previous.name == check.name:
                    previous.superseded = True
    entries = []
    for index, source in enumerate(sources):
        owned = [check for check in executed if check.source_index == index]
        active = [check for check in owned if not check.superseded]
        entries.append({"source": source, "outcome": validation_aggregate({check.outcome for check in active}),
                        "superseded": bool(owned) and not active,
                        "partially_superseded": bool(active) and len(active) < len(owned)})
    state = validation_aggregate({check.outcome for check in executed if not check.superseded})
    return {"state": state, "entries": entries, "checks": checks}


def validation_state(plan: str) -> str:
    return validation_summary(plan)["state"]


def validation_reason(summary: dict) -> str:
    state = summary["state"]
    if state in {"attention", "recorded"}:
        unresolved = [check for check in summary["checks"]
                      if check.scope == "implementation" and check.kind == "check"
                      and check.outcome == state and not check.superseded]
        headline = " ".join(unresolved[0].text.split())
        suffix = f" (+{len(unresolved) - 1} more)" if len(unresolved) > 1 else ""
        prefix = "Unresolved / ambiguous: " if state == "recorded" else ""
        return prefix + headline[:180] + ("…" if len(headline) > 180 else "") + suffix
    return {
        "missing": "No executed implementation validation results recorded.",
        "passed": "Recorded checks passed; current-run freshness is not established.",
    }[state]


def validation_cell(plan: str, task_href: str) -> str:
    summary = validation_summary(plan)
    label = {"passed": "Passed", "attention": "Attention", "recorded": "Recorded", "missing": "Unvalidated"}[summary["state"]]
    return (f"<a class='validation-status' href='{html_attr(task_href)}#validation' "
            f"aria-label='Validation: {label}; open task evidence'>{validation_chip(summary['state'])}</a>")


def validation_details(task: Task) -> str:
    source_href = (f"/task/{quote(task.name)}?path={quote(str(task.path), safe='')}"
                   f"&active_repo={quote(str(task.repo), safe='')}&doc=plan#validation-source")
    summary = validation_summary(task.validation_plan)
    records = []
    for entry in summary["entries"]:
        label = "Superseded record" if entry["superseded"] else {
            "attention": "Needs attention", "passed": "Recorded success",
            "recorded": "Unclassified / skipped", "missing": "No execution evidence / context",
        }[entry["outcome"]]
        if entry["partially_superseded"]:
            label = "Partially superseded record — " + label
        records.append(f"<li><strong>{label}</strong><pre class='validation-evidence'>{html.escape(entry['source'])}</pre></li>")
    return (
        "<details id='validation' aria-labelledby='validation-heading'>"
        "<summary id='validation-heading'>Validation details "
        f"{validation_chip(summary['state'])}</summary><p>{html.escape(validation_reason(summary))}</p>"
        "<p>Recorded from plan.md → Validation Performed. These records do not prove "
        "current-run freshness or that all required checks ran. Planning-only checks do not establish implementation success.</p>"
        "<p>Original records below retain check names and diagnostics where supplied. "
        "Check names or reasons absent from a record are not supplied; no details are inferred.</p>"
        f"<p><a href='{html_attr(source_href)}'>Open plan.md source</a></p>"
        f"<ul>{''.join(records)}</ul>"
        + ("" if records else "<p>No validation evidence has been recorded.</p>")
        + "</details>"
    )


def html_attr(value: str) -> str:
    return html.escape(value, quote=True)


def option_tag(value: str, label: str, selected: str) -> str:
    selected_attr = " selected" if value == selected else ""
    return f"<option value='{html_attr(value)}'{selected_attr}>{html.escape(label)}</option>"


def path_disclosure(label: str, value: str) -> str:
    return f"<details class='path-disclosure'><summary>{html.escape(label)}</summary><code>{html.escape(value)}</code></details>"


def repo_disclosure(task: Task, branch: str) -> str:
    return (
        "<details class='path-disclosure'><summary>Repo details</summary>"
        "<dl>"
        f"<dt>Repo path</dt><dd><code>{html.escape(str(task.repo))}</code></dd>"
        f"<dt>Slug</dt><dd><code>{html.escape(task.slug)}</code></dd>"
        f"<dt>Task store</dt><dd><code>{html.escape(str(task.path.parent))}</code></dd>"
        f"<dt>Branch</dt><dd>{html.escape(branch)}</dd>"
        "</dl></details>"
    )


def validation_chip(state: str) -> str:
    class_name = f"validation-{state}" if state in {"passed", "attention", "missing", "recorded"} else "validation-recorded"
    label = "Unvalidated" if state == "missing" else state.title()
    return f"<span class='validation-chip {class_name}'>{html.escape(label)}</span>"


def review_grade(review: str) -> str:
    body = section_body(review, "Review Metadata")
    if not body:
        return ""
    for line in body.splitlines():
        match = re.match(r"^\s*[-*]\s+Grade:\s*(.*?)\s*$", line, re.IGNORECASE)
        if match:
            grade = match.group(1).strip()
            return "" if not grade or grade.lower() == "pending" else (_normalized_grade(grade) or grade)
    return ""


def _normalized_grade(value: str) -> str:
    return review_record.normalized_grade(value)


def review_grade_class(grade: str) -> str:
    token = _normalized_grade(grade)
    return f"grade-{token[0].lower()}" if token else "grade-unknown"


def grade_rank(grade: str) -> int | None:
    token = _normalized_grade(grade)
    if not token:
        return None
    base = {"A": 12, "B": 9, "C": 6, "D": 3, "F": 0}[token[0]]
    if token.endswith('+') and token[0] != 'A':
        base += 1
    elif token.endswith('-'):
        base -= 1
    return base


def prototype_disabled_reason(task: "Task") -> str:
    if not (task.path / "review.md").is_file():
        return "Run Review first: this task has no review.md."
    if task.review_is_stale:
        return "Run Review again: review.md predates the replacement plan."
    reason = task.review_incomplete_reason
    if reason:
        return "Run Review again: " + reason + "."
    grade = review_grade(task.review)
    rank = grade_rank(grade)
    if rank is not None and rank >= 11:
        return f"Prototype disabled for review grade {grade}; A- or higher does not need a prototype."
    return ""


def pending_answer_questions(plan: str) -> list[str]:
    questions: list[str] = []
    lines = plan.splitlines()
    marker_re = re.compile(r"USER ANSWER(?:\s+---)?\s+\((UNRESOLVED|PROVIDED)\):")
    bullet_re = re.compile(r"^(\s*)[-*]\s+(.*\S)\s*$")
    for index, line in enumerate(lines):
        if not marker_re.search(line):
            continue
        marker_indent = len(line) - len(line.lstrip())
        for previous in range(index - 1, -1, -1):
            candidate = lines[previous].strip()
            if not candidate:
                continue
            match = bullet_re.match(lines[previous])
            if match and len(match.group(1)) < marker_indent and not marker_re.search(match.group(2)):
                question = match.group(2).strip()
                questions.append(question)
            break
    return questions


def answer_extras(task: Task, answers: str, extras: str) -> str:
    parts: list[str] = []
    if answers:
        questions = task.answer_questions
        question_lines = "\n".join(f"- {question}" for question in questions) if questions else "- <question text not parsed>"
        parts.append(
            "\n".join(
                [
                    f"Question answers submitted from the GUI for {task.name}:",
                    question_lines,
                    "",
                    answers,
                ]
            )
        )
    if extras:
        parts.append(extras)
    return "\n\n".join(parts)


def render_inline(text: str) -> str:
    placeholders: list[str] = []

    def keep(value: str) -> str:
        placeholders.append(value)
        return f"\000{len(placeholders) - 1}\000"

    escaped = html.escape(text)
    escaped = re.sub(r"`([^`]+)`", lambda m: keep(f"<code>{m.group(1)}</code>"), escaped)

    def link_repl(match: re.Match[str]) -> str:
        label = render_inline(match.group(1))
        href = html.unescape(match.group(2)).strip()
        if not re.match(r"^(https?://|mailto:|#|/)", href):
            return match.group(0)
        return keep(f'<a href="{html_attr(href)}" rel="noreferrer">{label}</a>')

    escaped = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link_repl, escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", lambda m: keep(f"<strong>{m.group(1)}</strong>"), escaped)
    escaped = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", lambda m: keep(f"<em>{m.group(1)}</em>"), escaped)
    for index, value in enumerate(placeholders):
        escaped = escaped.replace(f"\000{index}\000", value)
    return escaped


def render_paragraph(lines: list[str]) -> str:
    return f"<p>{render_inline(' '.join(line.strip() for line in lines))}</p>"


def render_table(lines: list[str]) -> str:
    rows = []
    for line in lines:
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        rows.append(cells)
    if len(rows) < 2 or not all(re.match(r"^:?-{3,}:?$", cell) for cell in rows[1]):
        return "\n".join(render_paragraph([line]) for line in lines)
    header = "".join(f"<th>{render_inline(cell)}</th>" for cell in rows[0])
    body_rows = []
    for row in rows[2:]:
        body_rows.append("<tr>" + "".join(f"<td>{render_inline(cell)}</td>" for cell in row) + "</tr>")
    return f"<table><thead><tr>{header}</tr></thead><tbody>{''.join(body_rows)}</tbody></table>"


def render_list(lines: list[str]) -> str:
    ordered = all(re.match(r"^\s*\d+\.\s+", line) for line in lines)
    tag = "ol" if ordered else "ul"
    items = []
    for line in lines:
        text = re.sub(r"^\s*(?:[-*+]\s+|\d+\.\s+)", "", line)
        checkbox = ""
        checked = re.match(r"^\[(x|X| )\]\s+(.*)$", text)
        if checked:
            checkbox = '<input type="checkbox" checked disabled> ' if checked.group(1).lower() == "x" else '<input type="checkbox" disabled> '
            text = checked.group(2)
        items.append(f"<li>{checkbox}{render_inline(text)}</li>")
    return f"<{tag}>{''.join(items)}</{tag}>"


def render_markdown(markdown: str) -> str:
    if not markdown:
        return "<p class='muted'>(file missing)</p>"

    lines = markdown.splitlines()
    blocks: list[str] = []
    paragraph: list[str] = []
    index = 0

    def flush_paragraph() -> None:
        if paragraph:
            blocks.append(render_paragraph(paragraph.copy()))
            paragraph.clear()

    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if not stripped:
            flush_paragraph()
            index += 1
            continue

        fence = re.match(r"^```([\w.+-]*)\s*$", stripped)
        if fence:
            flush_paragraph()
            lang = fence.group(1)
            code_lines = []
            index += 1
            while index < len(lines) and lines[index].strip() != "```":
                code_lines.append(lines[index])
                index += 1
            if index < len(lines):
                index += 1
            class_attr = f' class="language-{html_attr(lang)}"' if lang else ""
            blocks.append(f"<pre><code{class_attr}>{html.escape(chr(10).join(code_lines))}</code></pre>")
            continue

        heading = re.match(r"^(#{1,6})\s+(.+)$", stripped)
        if heading:
            flush_paragraph()
            level = len(heading.group(1))
            blocks.append(f"<h{level}>{render_inline(heading.group(2).strip())}</h{level}>")
            index += 1
            continue

        if re.match(r"^(-{3,}|\*{3,}|_{3,})$", stripped):
            flush_paragraph()
            blocks.append("<hr>")
            index += 1
            continue

        if stripped.startswith(">"):
            flush_paragraph()
            quote_lines = []
            while index < len(lines) and lines[index].strip().startswith(">"):
                quote_lines.append(re.sub(r"^\s*>\s?", "", lines[index]))
                index += 1
            blocks.append(f"<blockquote>{render_markdown(chr(10).join(quote_lines))}</blockquote>")
            continue

        if "|" in stripped and index + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{3,}:?", lines[index + 1]):
            flush_paragraph()
            table_lines = []
            while index < len(lines) and "|" in lines[index].strip() and lines[index].strip():
                table_lines.append(lines[index])
                index += 1
            blocks.append(render_table(table_lines))
            continue

        if re.match(r"^\s*(?:[-*+]\s+|\d+\.\s+)", line):
            flush_paragraph()
            list_lines = []
            while index < len(lines) and re.match(r"^\s*(?:[-*+]\s+|\d+\.\s+)", lines[index]):
                list_lines.append(lines[index])
                index += 1
            blocks.append(render_list(list_lines))
            continue

        paragraph.append(line)
        index += 1

    flush_paragraph()
    return "\n".join(blocks)


def tracking_summary(markdown: str, kind: str) -> str:
    body = section_body(markdown, f"{kind} Tracking")
    number = ""
    url = ""
    for line in body.splitlines():
      if f"{kind} Number:" in line:
          number = line.split(":", 1)[1].strip()
      if f"{kind} URL:" in line:
          url = line.split(":", 1)[1].strip()
    if number and url:
        return f"{number} {url}"
    return number or url


def run_rows(task_path: Path, history_url: str = "") -> str:
    runs_dir = task_path / "runs"
    rows: list[str] = []
    if runs_dir.exists():
        for meta in sorted(runs_dir.glob("*.gitconfig"), reverse=True):
            if not task_local_run_file(task_path, meta):
                continue
            action = (f"<a href='{html_attr(history_url + '&run=' + quote(meta.name, safe='') + '#run-logs')}'>Logs</a>"
                      if "-gui-" in meta.name else "Unavailable: backend capture not saved")
            rows.append(
                "<tr>"
                f"<td>{html.escape(metadata_value(meta, 'subcommand') or meta.stem)}</td>"
                f"<td>{html.escape(metadata_value(meta, 'status') or '<missing>')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'backend') or '')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'model') or '')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'start-time') or '')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'end-time') or '')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'exit-status') or '')}</td>"
                f"<td>{action}</td>"
                "</tr>"
            )
    return "".join(rows) or "<tr><td colspan=8>No runs recorded.</td></tr>"


def legacy_history_logs(task_path: Path, metadata: Path) -> tuple[ActiveRunLogs, str]:
    unavailable = ActiveRunLogs(None, None), "Unavailable: ambiguous or missing legacy GUI capture."
    command = metadata_value(metadata, "subcommand")
    started = parse_timestamp(metadata_value(metadata, "start-time"))
    selected_end = parse_timestamp(metadata_value(metadata, "end-time"))
    if not command or not re.fullmatch(r"[a-z-]+", command) or not started or (selected_end and selected_end < started):
        return unavailable
    # Old producers recorded seconds, not an association. Require the same second
    # and reject overlapping operations rather than borrowing the live heuristic.
    candidates = set()
    for stream in ("stdout", "stderr"):
        for log in metadata.parent.glob(f"*-gui-*-{command}-{task_path.name}.{stream}.log"):
            if parse_log_filename_timestamp(log) == started and task_local_run_file(task_path, log):
                candidates.add(log.name.removesuffix(f".{stream}.log"))
    if len(candidates) != 1:
        return unavailable
    stem = candidates.pop()
    for peer in metadata.parent.glob("*-gui-*.gitconfig"):
        if peer == metadata:
            continue
        if not task_local_run_file(task_path, peer):
            return unavailable
        if any(metadata_value(peer, stream + "-log") == stem + f".{stream}.log" for stream in ("stdout", "stderr")):
            return unavailable
        peer_command = metadata_value(peer, "subcommand")
        if not peer_command:
            return unavailable
        if peer_command != command:
            continue
        peer_start = parse_timestamp(metadata_value(peer, "start-time"))
        peer_end = parse_timestamp(metadata_value(peer, "end-time"))
        if peer_end and peer_end < peer_start:
            return unavailable
        if not peer_start or not ((peer_end and peer_end < started) or (selected_end and selected_end < peer_start)):
            return unavailable
    return ActiveRunLogs(*(task_local_run_file(task_path, metadata.parent / (stem + f".{stream}.log"))
                           for stream in ("stdout", "stderr"))), "GUI operation output (unique legacy capture; second precision)."


def history_logs(task_path: Path, selector: str) -> tuple[ActiveRunLogs, str]:
    unavailable = ActiveRunLogs(None, None)
    if not selector or Path(selector).name != selector or "\\" in selector or "\x00" in selector:
        return unavailable, "Selected run unavailable: invalid record."
    metadata = task_path / "runs" / selector
    if metadata not in (task_path / "runs").glob("*.gitconfig") or not task_local_run_file(task_path, metadata):
        return unavailable, "Selected run unavailable: missing or unsafe record."
    if "-gui-" not in selector:
        return unavailable, "Unavailable: backend capture not saved."
    values = metadata_values(metadata)
    if not any("paw." + stream + "-log" in values for stream in ("stdout", "stderr")):
        return legacy_history_logs(task_path, metadata)
    streams = []
    for stream in ("stdout", "stderr"):
        reference = metadata_value(metadata, stream + "-log")
        safe = reference and Path(reference).name == reference and "\\" not in reference and "\x00" not in reference
        streams.append(task_local_run_file(task_path, metadata.parent / reference) if safe else None)
    return ActiveRunLogs(*streams), "GUI operation output (saved capture)."


def recent_activity(task_path: Path) -> float:
    run_times: list[float] = []
    runs_dir = task_path / "runs"
    if runs_dir.exists():
        for meta in runs_dir.glob("*.gitconfig"):
            run_times.extend(
                parse_timestamp(metadata_value(meta, key))
                for key in ("end-time", "start-time")
            )
            run_times.append(file_mtime(meta))
    latest_run = max(run_times, default=0.0)
    if latest_run:
        return latest_run

    metadata = task_path / "metadata.gitconfig"
    metadata_times = [
        parse_timestamp(metadata_value(metadata, "migrated-at")),
        parse_timestamp(metadata_value(metadata, "created-at")),
    ]
    latest_metadata = max(metadata_times, default=0.0)
    if latest_metadata:
        return latest_metadata

    fallback_files = [task_path / name for name in ("plan.md", "contract.md", "metadata.gitconfig", "crash.log")]
    return max((file_mtime(path) for path in fallback_files), default=0.0)


def sort_tasks_by_recent_activity(tasks: list["Task"]) -> list["Task"]:
    return sorted(tasks, key=lambda task: (-task.activity_time, task.repo_name, task.name, str(task.path)))


def valid_task_name(name: str) -> bool:
    return bool(TASK_NAME_RE.match(name)) and name not in {".", ".."} and "/" not in name and "\x00" not in name


def latest_run_log_dir(task_path: Path) -> Path:
    runs_dir = task_path / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    return runs_dir


def launch_paw(repo: Path, task_home: Path, task_path: Path, args: list[str]) -> tuple[bool, str]:
    runs_dir = latest_run_log_dir(task_path)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    slug = "-".join(args[:2]) if len(args) >= 2 else "paw"
    log_id = f"{os.getpid()}-{time.time_ns()}"
    stdout_log = runs_dir / f"{stamp}-gui-{log_id}-{slug}.stdout.log"
    stderr_log = runs_dir / f"{stamp}-gui-{log_id}-{slug}.stderr.log"
    env = os.environ.copy()
    env["PAW_TASK_HOME"] = str(task_home)
    stdout = None
    stderr = None
    try:
        stdout = stdout_log.open("w")
        stderr = stderr_log.open("w")
        process = subprocess.Popen(
            [str(PAW_SCRIPT), *args],
            cwd=str(repo),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
        if args[0] == "archive":
            threading.Thread(target=process.wait, daemon=True).start()
            return True, f"started paw {' '.join(args)}; logs: {stdout_log}, {stderr_log}"
        metadata = runs_dir / f"{stamp}-gui-{time.time_ns()}-{process.pid}.gitconfig"
        for key, value in {"status": "running", "subcommand": args[0],
                           "start-time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                           "stdout-log": stdout_log.name, "stderr-log": stderr_log.name,
                           "prototype-replacement-name": args[1] + "-prototype" if args[0] == "prototype" else ""}.items():
            subprocess.run(["git", "config", "--file", str(metadata), f"paw.{key}", value], check=True)
        threading.Thread(target=finish_gui_run, args=(process, metadata), daemon=True).start()
    except Exception as exc:
        if stderr:
            stderr.write(f"Failed to start PAW: {exc}\n")
            stderr.flush()
        metadata = runs_dir / f"{stamp}-gui-{time.time_ns()}-failed.gitconfig"
        for key, value in {"status": "failed", "subcommand": args[0], "exit-status": "start-failed",
                           "stdout-log": stdout_log.name, "stderr-log": stderr_log.name,
                           "prototype-replacement-name": args[1] + "-prototype" if args[0] == "prototype" else ""}.items():
            subprocess.run(["git", "config", "--file", str(metadata), f"paw.{key}", value], check=False)
        return False, f"failed to start paw {' '.join(args)}: {exc}"
    finally:
        if stdout:
            stdout.close()
        if stderr:
            stderr.close()
    return True, f"started paw {' '.join(args)}; logs: {stdout_log}, {stderr_log}"


def finish_gui_run(process: subprocess.Popen, metadata: Path) -> None:
    code = process.wait()
    if metadata_value(metadata, "status") == "cancelled":
        return
    for key, value in {"status": "completed" if code == 0 else "failed", "exit-status": str(code),
                       "end-time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}.items():
        subprocess.run(["git", "config", "--file", str(metadata), f"paw.{key}", value], check=False)


def queue_root(task_home: Path, repo: Path) -> Path:
    return task_home / repo_slug(repo) / ".queue"


def queue_item_dir(task_home: Path, repo: Path, task_name: str) -> Path:
    return queue_root(task_home, repo) / task_name


@dataclass(frozen=True)
class QueuedPlan:
    task_name: str
    path: Path
    prompt: str
    created_at: str


@queue_lock()
def list_queued_plans(task_home: Path, repo: Path) -> list[QueuedPlan]:
    root = queue_root(task_home, repo)
    if not root.exists():
        return []
    items: list[QueuedPlan] = []
    for path in sorted(p for p in root.iterdir() if p.is_dir()):
        task_name = metadata_value(path / "metadata.gitconfig", "task-name") or path.name
        if not valid_task_name(task_name):
            continue
        prompt = (path / "prompt.txt").read_text(errors="replace") if (path / "prompt.txt").exists() else ""
        items.append(QueuedPlan(task_name, path, prompt, metadata_value(path / "metadata.gitconfig", "created-at")))
    return items


@queue_lock()
def write_queued_plan(task_home: Path, repo: Path, task_name: str, prompt: str) -> None:
    item = queue_item_dir(task_home, repo, task_name)
    item.mkdir(parents=True, exist_ok=False)
    (item / "prompt.txt").write_text(prompt + "\n")
    meta = item / "metadata.gitconfig"
    subprocess.run(["git", "config", "--file", str(meta), "paw.task-name", task_name], check=True)
    subprocess.run(["git", "config", "--file", str(meta), "paw.repo-root", str(repo)], check=True)
    subprocess.run(["git", "config", "--file", str(meta), "paw.created-at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())], check=True)


@queue_lock()
def update_queued_plan(task_home: Path, repo: Path, original: str, task_name: str, prompt: str) -> None:
    if not valid_task_name(original) or not valid_task_name(task_name):
        raise ValueError("invalid task name")
    if not prompt.strip():
        raise ValueError("prompt is required")
    item = queue_item_dir(task_home, repo, original)
    destination = queue_item_dir(task_home, repo, task_name)
    if item.is_symlink() or not (item / "prompt.txt").is_file():
        raise ValueError("queued plan prompt not found")
    if original != task_name and (destination.exists() or destination.is_symlink()):
        raise ValueError(f"queued plan prompt already exists for {task_name}")
    # Stage the complete replacement before touching the original prompt.
    with tempfile.TemporaryDirectory(prefix=".queue-edit-", dir=item.parent) as staging:
        staged = Path(staging)
        (staged / "prompt.txt").write_text(prompt)
        if original == task_name:
            (staged / "prompt.txt").replace(item / "prompt.txt")
            return
        meta = item / "metadata.gitconfig"
        if meta.exists():
            shutil.copyfile(meta, staged / "metadata.gitconfig")
        subprocess.run(["git", "config", "--file", str(staged / "metadata.gitconfig"), "paw.task-name", task_name], check=True)
        destination.mkdir(exist_ok=False)
        try:
            for path in staged.iterdir():
                path.replace(destination / path.name)
        except OSError:
            shutil.rmtree(destination)
            raise
        shutil.rmtree(item)


def prototype_run_replacement_name(path: Path) -> str:
    runs = (meta for meta in (path / "runs").glob("*-gui-*.gitconfig")
            if metadata_value(meta, "subcommand") == "prototype")
    latest = max(runs, key=file_mtime, default=None)
    return metadata_value(latest, "prototype-replacement-name") if latest else ""


class Task:
    def __init__(self, name: str, source: str, path: Path, repo: Path, slug: str = "", task_home: Path | None = None):
        self.task_home = task_home
        self.name = name
        self.source = source
        self.path = path
        self.repo = repo
        self.slug = slug or repo_slug(repo)
        self.plan = (path / "plan.md").read_text(errors="replace") if (path / "plan.md").exists() else ""
        self.contract = (path / "contract.md").read_text(errors="replace") if (path / "contract.md").exists() else ""
        self.review = (path / "review.md").read_text(errors="replace") if (path / "review.md").exists() else ""
        self.activity_time = recent_activity(path)

    @cached_property
    def validation_plan(self) -> str:
        return markdown_documents.validation_text(self.path / "plan.md") if (self.path / "plan.md").exists() else ""

    @property
    def repo_name(self) -> str:
        return self.repo.name or self.slug

    @property
    def branch_context(self) -> str:
        return metadata_value(self.path / "metadata.gitconfig", "branch-name") or metadata_value(
            self.path / "metadata.gitconfig", "head-state"
        )

    @property
    def saved_branch_name(self) -> str:
        return metadata_value(self.path / "metadata.gitconfig", "branch-name")

    @cached_property
    def prototype_status(self) -> str:
        return metadata_value(self.path / "metadata.gitconfig", "prototype-status")

    @cached_property
    def prototype_source(self) -> str:
        return metadata_value(self.path / "metadata.gitconfig", "prototype-source")

    @cached_property
    def prototype_cleanup_message(self) -> str:
        return metadata_value(self.path / "metadata.gitconfig", "prototype-cleanup-message")

    @cached_property
    def review_is_stale(self) -> bool:
        return (self.path / "review.md").is_file() and review_record.stale(self.path, metadata_value)

    @cached_property
    def review_incomplete_reason(self) -> str:
        return review_record.check(self.path, self.name, check_stale=False)

    @cached_property
    def publication_reason(self) -> str:
        return pr_publication.eligibility(self.path, self.repo, read_config=metadata_value)

    @property
    def blocked(self) -> bool:
        return bool(re.search(r"USER ANSWER(?:\s+---)?\s+\((UNRESOLVED|PROVIDED)\):", self.plan))

    @property
    def answer_questions(self) -> list[str]:
        return pending_answer_questions(self.plan)

    @cached_property
    def own_run(self) -> ActiveRun | None:
        return active_run_info(self.path)

    @cached_property
    def active_run(self) -> ActiveRun | None:
        own = self.own_run
        if own and ("-gui-" in own.metadata.name or metadata_value(own.metadata, "subcommand") != "prototype"):
            return own
        for peer in self.prototype_peers:
            run = peer.own_run
            if run and metadata_value(run.metadata, "subcommand") == "prototype":
                if own is None or "-gui-" in run.metadata.name:
                    return run
        return own

    @cached_property
    def prototype_peers(self) -> list[Task]:
        if self.task_home is None:
            return []
        peers = getattr(self, "_peers", None)
        if peers is None:
            peers = list_repo_tasks(self.repo, self.task_home)
        replacement = metadata_value(self.path / "metadata.gitconfig", "prototype-replacement")
        return [peer for peer in peers if peer.path != self.path and (
            peer.name == self.prototype_source or peer.prototype_source == self.name
            or (replacement and str(peer.path) == replacement)
            or prototype_run_replacement_name(peer.path) == self.name
            or prototype_run_replacement_name(self.path) == peer.name
        )]

    @property
    def running(self) -> bool:
        return self.active_run is not None

    @property
    def finished(self) -> bool:
        return status_field(self.plan, "Estimated completion") == "100%" and status_field(self.plan, "Next work").startswith("Review.")

    @property
    def state(self) -> str:
        if self.running:
            return "running"
        if self.blocked:
            return "blocked"
        if self.finished:
            return "complete"
        return "ready"


@dataclass(frozen=True)
class TaskWorkflow:
    stage: str
    next_label: str
    action: str
    note: str = ""
    disabled_reason: str = ""


def view_pr_branch(task: Task) -> str:
    branch = task.saved_branch_name
    if not branch:
        return ""
    if git_ok(task.repo, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"):
        return branch
    return ""


def latest_gui_run(task: Task) -> Path | None:
    return max((meta for meta in (task.path / "runs").glob("*-gui-*.gitconfig")
                if metadata_value(meta, "subcommand") == "prototype"), key=file_mtime, default=None)


def prototype_failure(task: Task) -> str:
    meta = latest_gui_run(task)
    if meta:
        if any(peer.prototype_source == task.name and peer.prototype_status.startswith("planned")
               and any(file_mtime(run) > file_mtime(meta)
                       and metadata_value(run, "subcommand") == "prototype"
                       and metadata_value(run, "status") == "complete"
                       and metadata_value(run, "exit-status") == "0"
                       for run in (peer.path / "runs").glob("*.gitconfig"))
               for peer in task.prototype_peers):
            return ""
        status = metadata_value(meta, "status")
        if status in {"failed", "cancelled"} or (status == "running" and not active_run_info(task.path)):
            return "Prototype planning failed, was cancelled, or stopped. Inspect run logs and retry explicitly."
    return ""


def task_workflow(task: Task) -> TaskWorkflow:
    plan_position = status_field(task.plan, "Plan position") or "<missing>"
    next_work = status_field(task.plan, "Next work") or "<missing>"
    if task.running:
        run = task.active_run
        if run and run.cancellable:
            return TaskWorkflow("Running", "Cancel", "cancel", "A PAW subprocess is active.", "")
        return TaskWorkflow(
            "Running",
            "Wait for run",
            "",
            "A PAW subprocess is active.",
            f"{task.name} has running metadata without a live cancellable PID",
        )
    if not task.plan:
        return TaskWorkflow("Missing plan", "Edit", "edit", "plan.md is missing.", "plan.md missing")
    if task.blocked:
        return TaskWorkflow("Needs edit", "Answer Questions", "edit", plan_position, "USER ANSWER placeholders remain")
    incomplete_origin = any(prototype_run_replacement_name(peer.path) == task.name and prototype_failure(peer)
                            for peer in task.prototype_peers)
    if task.prototype_status in {"planning", "planning-failed"} or incomplete_origin:
        return TaskWorkflow("Needs edit", "Edit replacement plan", "edit",
                            "Replacement planning has not succeeded. Inspect logs; edit/reconcile this plan or retry Use as Prototype from the source.")
    failed_replacement = any(peer.prototype_source == task.name and peer.prototype_status in {"planning", "planning-failed"}
                             for peer in task.prototype_peers)
    failure = prototype_failure(task)
    if failed_replacement or failure:
        reason = prototype_disabled_reason(task)
        return TaskWorkflow("Planning incomplete", "Retry Use as Prototype", "" if reason else "prototype",
                            failure or "Replacement planning has not succeeded. Retry reuses the existing package.", reason)
    if task.prototype_status in {"prototyped", "source-reverted", "revert-blocked", "revert-unavailable"}:
        return TaskWorkflow("Prototype", "Archive", "archive", next_work)
    if task.review and not task.review_is_stale and task.review_incomplete_reason:
        return TaskWorkflow("Review incomplete", "Run Review", "review", prototype_disabled_reason(task))
    if task.review and task.finished and not task.review_is_stale and review_grade(task.review) in {"A-", "A", "A+"}:
        reason = task.publication_reason
        if not reason:
            return TaskWorkflow("Reviewed", "Update PR", "pr-preview", "Publish a reviewed contribution or archive this task.")
        if review_grade(task.review) in {"A-", "A", "A+"}:
            return TaskWorkflow("Reviewed", "Update PR", "", next_work, reason)
    if task.review and not task.review_is_stale:
        reason = prototype_disabled_reason(task)
        if reason:
            return TaskWorkflow("Reviewed", "Use as Prototype", "", next_work, reason)
        return TaskWorkflow("Reviewed", "Use as Prototype", "prototype", next_work)
    if task.finished:
        return TaskWorkflow("Review", "Review", "review", next_work)
    return TaskWorkflow("Implement", "Approve Implementation", "approve-implementation", next_work)


def list_repo_tasks(repo: Path, task_home: Path) -> list[Task]:
    tasks: dict[str, Task] = {}
    central_root = task_home / repo_slug(repo)
    if central_root.exists():
        for path in sorted(p for p in central_root.iterdir() if p.is_dir()):
            if path.name in {".archive", ".queue"}:
                continue
            metadata_repo = metadata_value(path / "metadata.gitconfig", "repo-root")
            if metadata_repo and physical(Path(metadata_repo)) != repo:
                continue
            tasks[path.name] = Task(path.name, "central", path, repo, central_root.name, task_home)
    legacy_root = repo / ".agent"
    if legacy_root.exists():
        for path in sorted(p for p in legacy_root.iterdir() if p.is_dir()):
            tasks.setdefault(path.name, Task(path.name, "legacy", path, repo, task_home=task_home))
    result = list(tasks.values())
    for task in result:
        task._peers = result
    return result


def list_all_central_tasks(task_home: Path) -> list[Task]:
    tasks: list[Task] = []
    if not task_home.exists():
        return tasks
    for repo_dir in sorted(p for p in task_home.iterdir() if p.is_dir()):
        for path in sorted(p for p in repo_dir.iterdir() if p.is_dir()):
            if path.name in {".archive", ".queue"}:
                continue
            metadata_repo = metadata_value(path / "metadata.gitconfig", "repo-root")
            repo = physical(Path(metadata_repo)) if metadata_repo else Path(repo_dir.name)
            tasks.append(Task(path.name, "central", path, repo, repo_dir.name, task_home))
    for task in tasks:
        task._peers = [peer for peer in tasks if peer.repo == task.repo]
    return tasks


def list_tasks(repo: Path, task_home: Path, all_repos: bool) -> list[Task]:
    return snapshot_value(("tasks", repo, task_home, all_repos),
                          lambda: discover_tasks(repo, task_home, all_repos))


def discover_tasks(repo: Path, task_home: Path, all_repos: bool) -> list[Task]:
    if all_repos:
        return sort_tasks_by_recent_activity(list_all_central_tasks(task_home))
    return sort_tasks_by_recent_activity(list_repo_tasks(repo, task_home))


def list_repo_archived_tasks(repo: Path, task_home: Path) -> list[Task]:
    tasks: list[Task] = []
    archive_root = task_home / repo_slug(repo) / ".archive"
    if not archive_root.exists():
        return tasks
    for path in sorted(p for p in archive_root.iterdir() if p.is_dir()):
        metadata_repo = metadata_value(path / "metadata.gitconfig", "repo-root")
        if metadata_repo and physical(Path(metadata_repo)) != repo:
            continue
        tasks.append(Task(path.name, "archived", path, repo, archive_root.parent.name))
    return tasks


def list_all_archived_tasks(task_home: Path) -> list[Task]:
    tasks: list[Task] = []
    if not task_home.exists():
        return tasks
    for repo_dir in sorted(p for p in task_home.iterdir() if p.is_dir()):
        archive_root = repo_dir / ".archive"
        if not archive_root.exists():
            continue
        for path in sorted(p for p in archive_root.iterdir() if p.is_dir()):
            metadata_repo = metadata_value(path / "metadata.gitconfig", "repo-root")
            repo = physical(Path(metadata_repo)) if metadata_repo else Path(repo_dir.name)
            tasks.append(Task(path.name, "archived", path, repo, repo_dir.name))
    return tasks


def list_archived_tasks(repo: Path, task_home: Path, all_repos: bool) -> list[Task]:
    tasks = list_all_archived_tasks(task_home) if all_repos else list_repo_archived_tasks(repo, task_home)
    return sort_tasks_by_recent_activity(tasks)


STYLE = """
:root{color-scheme:light;--space:12px;--ink:#202c3d;--muted:#526174;--surface:#ffffff;--canvas:#f5f7fa;--line:#dfe5ed;--control:#788598;--subtle:#eef2f6;--stripe:#fbfcfe;--hover:#e7edf5;--link:#0b57d0;--focus:#2454c6;--accent:#2454c6;--accent-hover:#1d43a2;--red:#991b1b;--red-bg:#fef2f2;--blue-bg:#eff6ff;--amber:#78500b;--amber-bg:#fffbeb;--amber-hover:#fef3c7;--green:#166534;--green-bg:#f0fdf4;--purple:#5b21b6;--orange:#9a3412;--orange-bg:#fff7ed;--log-bg:#0f172a;--log-ink:#e5e7eb;--header:#243447;}
@media(prefers-color-scheme:dark){:root:not([data-theme=light]){color-scheme:dark;--space:12px;--ink:#e5eaf2;--muted:#b4c0d2;--surface:#1b2432;--canvas:#111821;--line:#394659;--control:#8292a8;--subtle:#263244;--stripe:#202b3b;--hover:#33435a;--link:#9fc2ff;--focus:#9fc2ff;--accent:#315db5;--accent-hover:#294f9d;--red:#ffb4b4;--red-bg:#3b242c;--blue-bg:#21334d;--amber:#f5ce87;--amber-bg:#372f22;--amber-hover:#493a23;--green:#97e0b2;--green-bg:#20382d;--purple:#d5b5ff;--orange:#ffc49c;--orange-bg:#3c2b22;--log-bg:#101720;--log-ink:#e5eaf2;--header:#1b2432;}}
:root[data-theme=dark]{color-scheme:dark;--space:12px;--ink:#e5eaf2;--muted:#b4c0d2;--surface:#1b2432;--canvas:#111821;--line:#394659;--control:#8292a8;--subtle:#263244;--stripe:#202b3b;--hover:#33435a;--link:#9fc2ff;--focus:#9fc2ff;--accent:#315db5;--accent-hover:#294f9d;--red:#ffb4b4;--red-bg:#3b242c;--blue-bg:#21334d;--amber:#f5ce87;--amber-bg:#372f22;--amber-hover:#493a23;--green:#97e0b2;--green-bg:#20382d;--purple:#d5b5ff;--orange:#ffc49c;--orange-bg:#3c2b22;--log-bg:#101720;--log-ink:#e5eaf2;--header:#1b2432;}
.theme-control{display:none;font-size:12px;align-items:center;gap:6px}.js .theme-control{display:inline-flex}
input,select,textarea{font:inherit;color:var(--ink);background:var(--surface);border:1px solid var(--control);padding:5px 8px}input::placeholder,textarea::placeholder{color:var(--muted);opacity:1}
button:disabled,input:disabled,select:disabled,textarea:disabled{color:var(--muted);background:var(--subtle);opacity:1}

body{font:14px/1.45 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;color:var(--ink);background:var(--canvas)}
.shell{width:min(100% - 32px,1600px);margin-inline:auto}.site-header{background:var(--header);color:var(--surface);padding:10px 0}.header-row{display:flex;align-items:center;gap:14px;flex-wrap:wrap}.site-header h1{font-size:20px;line-height:1.2;margin:0}.home-link{color:var(--surface);text-decoration:none;border:1px solid rgba(255,255,255,.35);border-radius:6px;padding:4px 8px}.home-link:hover{background:rgba(255,255,255,.12)}.header-context{color:var(--muted);font-size:13px;margin-left:auto}main.shell{padding-block:20px}
a{color:var(--link);text-decoration:none}button,.button{border:1px solid var(--control);background:var(--surface);color:var(--ink);border-radius:6px;padding:5px 9px;font:inherit;cursor:pointer}.button{display:inline-block}button:hover,.button:hover{background:var(--hover)}button:focus-visible,.button:focus-visible,.home-link:focus-visible{outline:3px solid var(--focus);outline-offset:2px}.danger{border-color:var(--red);color:var(--red)}.primary{border-color:var(--link);color:var(--link);background:var(--blue-bg)}
table{border-collapse:collapse;width:100%;background:var(--surface);border:1px solid var(--line)}.table-wrap{overflow-x:auto;margin:12px 0 20px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);vertical-align:top}th{background:var(--subtle);font-size:12px;text-transform:uppercase;color:var(--muted)}
.pill{display:inline-block;border:1px solid var(--control);border-radius:999px;padding:2px 8px;background:var(--subtle);font-size:12px}.blocked{border-color:var(--amber);color:var(--amber)}.running{border-color:var(--focus);color:var(--link)}.ready{border-color:var(--green);color:var(--green)}.complete{border-color:var(--purple);color:var(--purple)}
.review-grade{display:inline-block;border:1px solid var(--control);border-radius:999px;background:var(--subtle);padding:2px 8px;font-size:12px;font-weight:600}.grade-a{border-color:var(--green);color:var(--green);background:var(--green-bg)}.grade-b{border-color:var(--link);color:var(--link);background:var(--blue-bg)}.grade-c{border-color:var(--amber);color:var(--amber);background:var(--amber-bg)}.grade-d{border-color:var(--orange);color:var(--orange);background:var(--orange-bg)}.grade-f{border-color:var(--red);color:var(--red);background:var(--red-bg)}.grade-unknown{border-color:var(--control);color:var(--muted);background:var(--subtle)}
.toolbar{display:flex;align-items:end;justify-content:space-between;gap:10px;flex-wrap:wrap;margin:14px 0}.toolbar-fields,.top-actions,.dashboard-actions{display:flex;align-items:end;gap:8px;flex-wrap:wrap}.dashboard-actions{margin:14px 0}.toolbar label{display:grid;gap:3px;font-size:12px;color:var(--muted)}.toolbar select,.toolbar input{font:inherit;border:1px solid var(--control);border-radius:6px;padding:5px 8px;background:var(--surface)}.filter-disclosure{margin:14px 0}.filter-disclosure>summary{cursor:pointer;color:var(--muted)}.filter-disclosure .toolbar{margin:8px 0 0}.flash,.flash-error{border:1px solid var(--blue-bg);border-radius:6px;background:var(--blue-bg);color:var(--link);padding:8px 10px}.flash-error{border-color:var(--red);background:var(--red-bg);color:var(--red)}.metric-chip,.validation-chip{display:inline-flex;align-items:center;justify-content:center;min-width:3.2em;border-radius:999px;border:1px solid var(--control);background:var(--subtle);padding:2px 8px;font-size:12px}.validation-status{display:inline-block;white-space:nowrap}.validation-evidence{white-space:pre-wrap;overflow-wrap:anywhere;max-width:100%;overflow:auto}.validation-passed{border-color:var(--green);color:var(--green)}.validation-attention{border-color:var(--amber);color:var(--amber)}.validation-missing{border-color:var(--control);color:var(--muted)}.validation-recorded{border-color:var(--link);color:var(--link)}
.task-title{font-weight:600}.task-subtle{margin-top:4px}.repo-name{font-weight:600}.path-disclosure{margin-top:5px;font-size:12px;color:var(--muted)}.path-disclosure summary{cursor:pointer;color:var(--muted)}.path-disclosure code{display:block;margin-top:5px;white-space:nowrap;overflow:auto;max-width:42rem}.path-disclosure dl{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 10px;margin:6px 0 0}.path-disclosure dt{font-weight:600;color:var(--muted)}.path-disclosure dd{margin:0;min-width:0}
.tabs a{margin-right:14px}.muted{color:var(--muted)}.document{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:20px;margin:14px 0 24px;overflow:auto}.document h1,.document h2,.document h3{margin:18px 0 10px}.document h1:first-child,.document h2:first-child{margin-top:0}.document pre{background:var(--subtle);border:1px solid var(--line);padding:12px;overflow:auto}.document code{background:var(--subtle);padding:1px 4px}.document pre code{background:transparent;padding:0}.document blockquote{border-left:4px solid var(--line);color:var(--muted);margin:12px 0;padding:1px 14px}.document ul,.document ol{padding-left:24px}.document li{margin:3px 0}.document input[type=checkbox]{margin-right:6px}.document table{border:1px solid var(--line)}.document tr:nth-child(even),.table-wrap tbody tr:nth-child(even){background:var(--stripe)}
.log-stream{display:grid;gap:14px;margin:14px 0 24px}.log-panel{background:var(--surface);border:1px solid var(--line);border-radius:8px;overflow:hidden}.log-panel h3{font-size:13px;text-transform:uppercase;color:var(--muted);background:var(--subtle);margin:0;padding:8px 12px}.log-panel pre{margin:0;max-height:45vh;overflow:auto;padding:12px;background:var(--log-bg);color:var(--log-ink);white-space:pre-wrap}
.action-row{display:flex;gap:6px;align-items:center;flex-wrap:wrap}.workflow-cell{min-width:150px}.workflow-label{font-weight:600}.workflow-note{margin-top:4px}.workflow-actions{margin-top:8px}.disabled-action{display:inline-block;border:1px solid var(--control);border-radius:6px;padding:5px 9px;background:var(--subtle);color:var(--muted)}.modal-toggle{display:inline-block}.modal-toggle>summary{list-style:none}.modal-toggle>summary::-webkit-details-marker{display:none}.modal-panel{position:fixed;inset:0;background:rgba(15,23,42,.38);z-index:20;display:flex;align-items:center;justify-content:center;padding:20px}.modal-body{background:var(--surface);color:var(--ink);border:1px solid var(--line);border-radius:8px;box-shadow:0 18px 55px rgba(15,23,42,.28);max-width:720px;width:min(720px,100%);max-height:84vh;overflow:auto;padding:18px}.modal-body textarea{width:100%;box-sizing:border-box}.queued-prompt{white-space:pre-wrap;overflow-wrap:anywhere;min-width:18ch;max-width:60ch;margin:0}.publication-candidate{white-space:pre-wrap;overflow-wrap:anywhere}.inline-form{display:inline}.doc-preview{margin-top:18px}.doc-preview:empty{display:none}
body{color:var(--ink);background:var(--canvas)}*{box-sizing:border-box}main.shell{padding-block:16px}.site-header{background:var(--surface);color:var(--ink);border-bottom:1px solid var(--line);padding:14px 0}.site-header h1{order:-1;font-size:18px}.home-link{color:var(--muted);border:0;padding:4px}.home-link:hover{background:var(--canvas)}.header-context{color:var(--muted)}
button,.button,input,select,textarea{border-radius:7px}button,.button{white-space:nowrap}button,.button{padding:6px 10px}a:hover{text-decoration:underline}:focus-visible{outline:3px solid var(--focus);outline-offset:3px}.primary{background:var(--accent);border-color:var(--focus);color:#fff}.primary:hover{background:var(--accent-hover)}.archive{background:var(--amber-bg);border-color:var(--amber);color:var(--amber)}.archive:hover{background:var(--amber-hover)}.danger{background:var(--red-bg)}.lifecycle-actions{margin-top:10px;flex-wrap:nowrap}.task-utilities{font-size:13px}.row-tools>summary{cursor:pointer;color:var(--link);padding-block:4px}.row-tools .task-utilities{margin-top:8px}.empty-state{padding:24px;background:var(--surface);border:1px solid var(--line);border-radius:8px}.task-count{font-size:13px;margin:14px 0 0}
#dashboard-controls{display:flex;align-items:center;gap:12px;flex-wrap:wrap}#dashboard-controls>.repo-toolbar{margin:0}.repo-toolbar label{display:flex;align-items:center;gap:8px}.repo-toolbar select{width:clamp(160px,25vw,360px);max-width:100%;font-size:14px}.repo-toolbar{align-items:center}.repo-management,.filter-disclosure{margin:0;font-size:13px}.repo-management>summary,.filter-disclosure>summary{cursor:pointer;padding:7px}.repo-management[open],.filter-disclosure[open]{flex-basis:100%}.dashboard-actions{margin:0;gap:var(--space);align-items:center}.js .switch-fallback{display:none}[hidden]{display:none!important}.queue-trigger{font-size:13px}.toolbar label{max-width:100%;min-width:0}.toolbar input{max-width:100%}[data-action-feedback]:empty{display:none}[data-transient-message],[data-action-feedback]{position:relative;overflow-wrap:anywhere;padding-right:48px}[data-message-dismiss]{display:none;position:absolute;right:6px;top:4px;min-width:32px;min-height:32px;padding:2px;color:inherit;background:transparent;border:0}.js [data-message-dismiss]{display:block}[data-message-dismiss]::before{content:"×";font-size:22px}.table-wrap{max-width:100%;border-radius:8px}#task-list .dashboard-table{min-width:1180px;table-layout:fixed}.dashboard-table>colgroup>.task-column{width:18%}.dashboard-table>colgroup>.repo-column{width:17%}.dashboard-table>colgroup>.stage-column{width:12%}.dashboard-table>colgroup>.next-column{width:16%}.dashboard-table>colgroup>.completion-column{width:7%}.dashboard-table>colgroup>.checklist-column{width:6%}.dashboard-table>colgroup>.validation-column{width:9%}.dashboard-table>colgroup>.actions-column{width:15%}.dashboard-table>tbody>tr>td{overflow-wrap:anywhere}.dashboard-table .workflow-cell{min-width:0}.dashboard-table .workflow-actions button{max-width:100%;white-space:normal}.dashboard-stage{line-height:20px;font-size:12px}.dashboard-stage>span,.dashboard-stage>a{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.dashboard-stage>.pill{padding:0;border:0;border-radius:0;background:transparent;font-size:inherit}.prototype-warning{color:var(--amber);font-weight:600}.modal-body .table-wrap table{min-width:560px}th{background:var(--subtle);letter-spacing:.035em}th,td{padding:10px}.task-title{overflow-wrap:anywhere}.modal-panel{padding:16px}.modal-body{border-radius:12px;max-height:calc(100dvh - 32px);width:min(760px,100%);padding:20px;overscroll-behavior:contain;overflow-wrap:anywhere}.modal-body h2{font-size:19px;margin:0 0 12px}.modal-body input{max-width:100%}.modal-body code{overflow-wrap:anywhere}.modal-body .document{padding:14px}.modal-body .action-row{position:sticky;bottom:-20px;padding-block:12px;background:var(--surface)}.plan-destination{font-size:13px;color:var(--muted)}.plan-destination code{font-size:12px}.task-metadata{margin:14px 0}.task-metadata>summary{cursor:pointer;font-weight:600}.tabs{display:flex;gap:16px;flex-wrap:wrap}.tabs a{margin:0;padding:6px 2px;border-bottom:3px solid transparent}.tabs a[aria-current=page]{border-bottom-color:var(--link);font-weight:600}
@media(max-width:1180px){#task-list .dashboard-table{min-width:0;border:0;background:transparent}.dashboard-table colgroup{display:none}.dashboard-table thead{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)}.dashboard-table tbody{display:grid;gap:14px}.dashboard-table tbody>tr{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);border:1px solid var(--line);border-radius:8px;background:var(--surface)}.dashboard-table>tbody>tr>td{display:block;min-width:0;border:0}.dashboard-table td::before{content:attr(data-label);display:block;color:var(--muted);font-size:12px;font-weight:600;margin-bottom:4px}.dashboard-table .path-disclosure code{white-space:normal;overflow-wrap:anywhere}.dashboard-stage>span,.dashboard-stage>a{white-space:normal}.dashboard-table .lifecycle-actions{flex-wrap:wrap}}
@media(max-width:480px){.dashboard-table tbody>tr{grid-template-columns:minmax(0,1fr)}.repo-toolbar label{flex-wrap:wrap}.repo-toolbar select{flex-basis:100%}}
@media(max-width:640px){#dashboard-controls{gap:8px}.repo-toolbar{width:100%}.repo-toolbar label{flex:1}.repo-toolbar select{width:100%}.dashboard-actions{width:100%}.modal-panel{padding:10px}.modal-body{max-height:calc(100dvh - 20px);padding:14px}.modal-body .action-row{bottom:-14px}.header-row{gap:12px}.site-header h1{overflow-wrap:anywhere}.toolbar-fields{max-width:100%}}
@media (max-width:640px){.shell{width:min(100% - 20px,1600px)}.header-context{margin-left:0;flex-basis:100%}}
"""

# Run before body parsing; CSS handles live OS changes whenever no override is set.
THEME_INIT = """
<script>
(() => {
  let preference = 'system';
  try { preference = localStorage.getItem('paw.gui.theme') || 'system'; } catch (_) {}
  if (preference === 'light' || preference === 'dark') document.documentElement.dataset.theme = preference;
})();
</script>
"""

SCRIPT = """
<script>
document.addEventListener("DOMContentLoaded", () => {
  document.documentElement.classList.add('js');
  const themeSelect = document.querySelector('[data-theme-select]');
  if (themeSelect) {
    themeSelect.value = document.documentElement.dataset.theme || 'system';
    themeSelect.addEventListener('change', () => {
      const preference = themeSelect.value;
      if (preference === 'system') delete document.documentElement.dataset.theme;
      else document.documentElement.dataset.theme = preference;
      try { localStorage.setItem('paw.gui.theme', preference); } catch (_) {}
    });
  }
  function revealValidation() {
    if (location.hash !== '#validation') return;
    const details = document.getElementById('validation');
    if (details) {
      details.open = true;
      details.scrollIntoView();
    }
  }
  revealValidation();
  window.addEventListener('hashchange', revealValidation);
  const pollers = new Map();
  let generation = 0;
  let submitting = false;
  let modalEpoch = 0;

  // Keys are local to siblings; row identity includes the resolved task path.
  function key(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return node.nodeName;
    const form = node.matches('form') ? node : node.querySelector('form');
    const identity = node.dataset.pawKey || node.dataset.pawRefreshUrl || node.id;
    if (identity) return node.tagName + ':' + identity;
    if (node.matches('form, details') && form) {
      return node.tagName + ':' + form.getAttribute('action') + ':' +
        ['path', 'active_repo', 'original_task_name', 'task_name'].map(name =>
          form.querySelector('input[type=hidden][name="' + name + '"]')?.value || '').join(':');
    }
    if (node.matches('details')) return 'DETAILS:' + node.querySelector('summary')?.textContent;
    return node.tagName + ':' + (node.getAttribute('name') || node.className || '');
  }

  function patch(current, fresh, root) {
    if (current.nodeType !== Node.ELEMENT_NODE) {
      if (current.nodeValue !== fresh.nodeValue) current.nodeValue = fresh.nodeValue;
      return;
    }
    // A nested live target owns its content and its outstanding request.
    if (current !== root && current.dataset.pawRefreshUrl) return;
    const editable = current.matches('input:not([type=hidden]), textarea, select');
    const dirty = editable && (current === document.activeElement ||
      (current.matches('input') ? current.value !== current.defaultValue || current.checked !== current.defaultChecked :
        current.matches('textarea') ? current.value !== current.defaultValue :
          [...current.options].some(option => option.selected !== option.defaultSelected)));
    for (const attribute of [...current.attributes]) {
      if (attribute.name === 'open' || attribute.name === 'inert' || (dirty && attribute.name === 'value')) continue;
      if (!fresh.hasAttribute(attribute.name)) current.removeAttribute(attribute.name);
    }
    for (const attribute of fresh.attributes) {
      if (attribute.name === 'open' || attribute.name === 'inert' || (dirty && attribute.name === 'value')) continue;
      if (current.getAttribute(attribute.name) !== attribute.value) current.setAttribute(attribute.name, attribute.value);
    }
    if (!(dirty && current.matches('textarea, select'))) reconcile(current, fresh, root);
    if (editable && !dirty) {
      current.value = fresh.value;
      if (current.matches('input')) current.checked = fresh.checked;
    }
  }

  function reconcile(target, fresh, root = target) {
    const available = [...target.childNodes];
    let cursor = target.firstChild;
    for (const incoming of [...fresh.childNodes]) {
      const index = available.findIndex(node => key(node) === key(incoming));
      const node = index < 0 ? incoming.cloneNode(true) : available.splice(index, 1)[0];
      if (node !== cursor) target.insertBefore(node, cursor);
      if (index >= 0) patch(node, incoming, root);
      cursor = node.nextSibling;
    }
    available.forEach(node => node.remove());
  }

  function apply(target, content) {
    const template = document.createElement('template');
    template.innerHTML = content;
    const focus = document.activeElement;
    const caret = focus && typeof focus.selectionStart === 'number' ?
      [focus.selectionStart, focus.selectionEnd, focus.selectionDirection] : null;
    const page = [window.scrollX, window.scrollY];
    const scroll = [target, ...target.querySelectorAll('*')].map(node => ({
      node, x: node.scrollLeft, y: node.scrollTop,
      follow: node.matches('.log-panel pre') && node.scrollHeight - node.clientHeight - node.scrollTop <= 3,
    }));
    reconcile(target, template.content);
    if (focus?.isConnected && !focus.disabled && document.activeElement !== focus) focus.focus({preventScroll: true});
    if (caret && focus.isConnected) focus.setSelectionRange(...caret);
    scroll.forEach(({node, x, y, follow}) => {
      if (node.isConnected) { node.scrollLeft = x; node.scrollTop = follow ? node.scrollHeight : y; }
    });
    window.scrollTo(...page);
    discover();
  }

  async function refresh(target, state) {
    if (state.busy || submitting || !target.isConnected) return;
    state.busy = true;
    const version = generation;
    try {
      const response = await fetch(state.url, {cache: 'no-store'});
      if (!response.ok) return;
      const content = await response.text();
      if (version !== generation || !target.isConnected || pollers.get(target) !== state) return;
      if (content !== state.content) { apply(target, content); state.content = content; }
    } catch (_error) {
      // Keep the last usable view; the next scheduled read can recover.
    } finally { state.busy = false; }
  }

  function discover() {
    syncModal();
    for (const [target, state] of pollers) {
      if (!target.isConnected || target.dataset.pawRefreshUrl !== state.url) {
        clearInterval(state.timer);
        pollers.delete(target);
      }
    }
    document.querySelectorAll('[data-paw-refresh-url]').forEach(target => {
      if (pollers.has(target)) return;
      const state = {url: target.dataset.pawRefreshUrl, busy: false, content: null};
      state.timer = setInterval(() => refresh(target, state), Number(target.dataset.pawRefreshIntervalMs || 2500));
      pollers.set(target, state);
    });
  }

  document.addEventListener('change', event => {
    if (event.target.matches('[data-repo-switch] select')) event.target.form.requestSubmit();
  });
  document.addEventListener('click', event => {
    if (!event.target.closest('[data-open-queue]')) return;
    event.preventDefault();
    const plan = document.querySelector('[data-new-plan]');
    plan.open = true;
    plan.querySelector('#queued-plans')?.scrollIntoView({block: 'nearest'});
  });
  const preview = document.querySelector('[data-doc-preview]');
  let previewRequest = 0;
  let modal = null;
  let modalOpener = null;
  let pageScroll = null;
  let previousOverflow = '';
  const inertNodes = new Map();
  let previewController = null;
  function invalidatePreview() {
    previewRequest++;
    previewController?.abort();
    previewController = null;
  }
  function restoreBackground() {
    for (const [node, inert] of inertNodes) node.inert = inert;
    inertNodes.clear();
  }
  function isolateDialog(panel) {
    restoreBackground();
    for (let node = panel; node.parentElement; node = node.parentElement) {
      for (const sibling of node.parentElement.children) {
        if (sibling === node) continue;
        inertNodes.set(sibling, sibling.inert);
        sibling.inert = true;
      }
    }
  }
  function focusable(panel) {
    return [...panel.querySelectorAll('button, a[href], input, select, textarea, summary, [tabindex]')]
      .filter(node => !node.disabled && node.tabIndex >= 0 && !node.closest('[inert]') && node.getClientRects().length);
  }
  function closeModal(returnFocus = true) {
    if (!modal) return;
    modalEpoch++;
    const old = modal;
    modal = null;
    if (old.closest('[data-doc-preview]')) {
      invalidatePreview();
      preview.replaceChildren();
    } else {
      const details = old.closest('details.modal-toggle');
      if (details) details.open = false;
    }
    restoreBackground();
    document.body.style.overflow = previousOverflow;
    if (pageScroll) window.scrollTo(...pageScroll);
    pageScroll = null;
    const fallback = document.querySelector('[data-new-plan] summary, .home-link');
    if (returnFocus) (modalOpener?.isConnected ? modalOpener : fallback)?.focus({preventScroll: true});
    modalOpener = null;
  }
  function labelDialog(panel) {
    const body = panel.querySelector('.modal-body');
    body.setAttribute('role', 'dialog');
    body.setAttribute('aria-modal', 'true');
    body.setAttribute('aria-label', body.querySelector('h2')?.textContent || 'Task action');
    body.tabIndex = -1;
    return body;
  }
  function openModal(panel, opener = document.activeElement) {
    if (modal === panel) { isolateDialog(panel); return; }
    closeModal(false);
    modalEpoch++;
    modal = panel;
    modalOpener = opener;
    pageScroll = [window.scrollX, window.scrollY];
    previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    const body = labelDialog(panel);
    isolateDialog(panel);
    (focusable(panel)[0] || body).focus({preventScroll: true});
  }
  function syncModal() {
    if (modal && (!modal.isConnected || (modal.closest('details.modal-toggle') && !modal.closest('details.modal-toggle').open))) {
      closeModal();
    }
    if (modal) { labelDialog(modal); isolateDialog(modal); }
  }
  document.addEventListener('toggle', event => {
    if (!event.target.matches('details.modal-toggle')) return;
    if (event.target.open) openModal(event.target.querySelector('.modal-panel'), event.target.querySelector('summary'));
    else syncModal();
  }, true);
  document.addEventListener('click', event => {
    if (event.target.matches('.modal-panel') || event.target.closest('[data-modal-close]')) {
      event.preventDefault();
      closeModal();
    }
  });
  document.addEventListener('keydown', event => {
    if (!modal) return;
    if (event.key === 'Escape') { event.preventDefault(); closeModal(); }
    if (event.key !== 'Tab') return;
    const items = focusable(modal);
    const first = items[0] || modal.querySelector('.modal-body');
    const last = items.at(-1) || first;
    if (event.shiftKey && (document.activeElement === first || !items.includes(document.activeElement))) {
      event.preventDefault(); last.focus();
    } else if (!event.shiftKey && (document.activeElement === last || !items.includes(document.activeElement))) {
      event.preventDefault(); first.focus();
    }
  });
  document.addEventListener('focusin', event => {
    if (modal && !modal.contains(event.target)) (focusable(modal)[0] || modal.querySelector('.modal-body')).focus();
  });
  window.addEventListener('pagehide', invalidatePreview);
  document.addEventListener('click', async event => {
    const trigger = event.target.closest('[data-doc-preview-url]');
    if (!trigger || !preview) return;
    event.preventDefault();
    closeModal(false);
    invalidatePreview();
    const request = previewRequest;
    previewController = new AbortController();
    preview.innerHTML = '<div class="modal-panel"><div class="modal-body"><h2>Document preview</h2><button type="button" data-modal-close>Close</button><p role="status">Loading…</p></div></div>';
    openModal(preview.firstElementChild, trigger);
    try {
      const response = await fetch(trigger.dataset.docPreviewUrl, {cache: 'no-store', signal: previewController.signal});
      if (!response.ok) throw new Error('Preview unavailable; try again.');
      const content = await response.text();
      if (request !== previewRequest) return;
      // Keep the active backdrop, scroll lock and opener while replacing loading content.
      const template = document.createElement('template');
      template.innerHTML = content;
      const body = template.content.querySelector('.modal-body');
      if (!body) throw new Error('Preview unavailable; try again.');
      modal.replaceChildren(body);
      labelDialog(modal);
      (focusable(modal)[0] || body).focus({preventScroll: true});
      discover();
    } catch (error) {
      if (request === previewRequest) preview.querySelector('[role=status]').textContent = error.message;
    }
  });
  const messageTimers = new WeakMap();
  function clearMessage(target) {
    clearTimeout(messageTimers.get(target));
    messageTimers.delete(target);
    if (target.contains(document.activeElement)) {
      document.querySelector('[data-new-plan] summary, .home-link, header a')?.focus({preventScroll: true});
    }
    if (target.hasAttribute('data-action-feedback')) {
      target.replaceChildren();
      target.className = '';
    } else target.remove();
  }
  function armMessage(target) {
    clearTimeout(messageTimers.get(target));
    const timer = setTimeout(() => {
      if (messageTimers.get(target) === timer) clearMessage(target);
    }, 5000);
    messageTimers.set(target, timer);
    target.querySelector('[data-message-dismiss]').onclick = () => clearMessage(target);
  }
  document.querySelectorAll('[data-transient-message]').forEach(armMessage);

  function feedback(message, ok, link = '') {
    const target = document.querySelector('[data-action-feedback]');
    clearMessage(target);
    if (!message && !link) return;
    target.className = ok ? 'flash' : 'flash-error';
    target.replaceChildren(document.createTextNode(message));
    if (link) {
      const anchor = document.createElement('a');
      anchor.href = link;
      anchor.textContent = 'Open PR';
      target.append(' ', anchor);
    }
    const close = document.createElement('button');
    close.type = 'button';
    close.dataset.messageDismiss = '';
    close.setAttribute('aria-label', 'Dismiss message');
    target.append(close);
    armMessage(target);
  }

  function switchRepo(repo) {
    closeModal();
    invalidatePreview();
    document.querySelectorAll('[name="task"]:checked').forEach(input => { input.checked = false; });
    const url = new URL(location.href);
    url.searchParams.set('active_repo', repo);
    history.replaceState(null, '', url);
    const archive = document.querySelector('header a[href^="/archive"]');
    if (archive) archive.href = '/archive?active_repo=' + encodeURIComponent(repo);
    const context = document.querySelector('.header-context');
    if (context && context.textContent !== 'All task stores') context.textContent = (repo.split('/').pop() || 'repo') + ' repo';
    document.querySelectorAll('[data-paw-refresh-url]').forEach(target => {
      const refreshUrl = new URL(target.dataset.pawRefreshUrl, location.href);
      refreshUrl.searchParams.set('active_repo', repo);
      target.dataset.pawRefreshUrl = refreshUrl.pathname + refreshUrl.search;
    });
    discover();
  }

  document.addEventListener('submit', async event => {
    const form = event.target;
    if (!document.querySelector('[data-action-feedback]') || form.method !== 'post') return;
    event.preventDefault();
    if (submitting) return;
    const button = event.submitter;
    // FormData includes controls outside the form associated through form=.
    const data = new FormData(form);
    if (button?.name) data.append(button.name, button.value);
    data.set('dashboard_return', location.pathname + location.search);
    const body = new URLSearchParams(data);
    const overlay = form.closest('details');
    const inPreview = form.closest('[data-doc-preview]');
    const submittedEpoch = modalEpoch;
    submitting = true;
    generation++;
    previewRequest++;
    const controls = [...form.elements].filter(control => !control.matches('[data-modal-close]'))
      .map(control => [control, control.disabled]);
    controls.forEach(([control]) => { control.disabled = true; });
    feedback('Submitting…', true);
    try {
      const response = await fetch(form.action, {
        method: 'POST', headers: {'Accept': 'application/json'}, body,
      });
      const result = await response.json();
      if (typeof result.ok !== 'boolean' || typeof result.message !== 'string') throw new Error('Invalid action response');
      feedback(result.message, result.ok, result.link);
      if (result.ok && result.preview) {
        if (submittedEpoch === modalEpoch && preview) {
          preview.innerHTML = result.preview;
          openModal(preview.firstElementChild, button);
        }
      } else if (result.ok) {
        form.reset();
        if (modal?.contains(form)) closeModal();
        if (overlay) overlay.open = false;
        if (inPreview?.contains(form)) { invalidatePreview(); inPreview.replaceChildren(); }
        if (typeof result.active_repo === 'string') switchRepo(result.active_repo);
      }
    } catch (_error) {
      feedback('Could not confirm the action result. Check task state before retrying; your input has been retained.', false);
    } finally {
      controls.forEach(([control, disabled]) => { control.disabled = disabled; });
      submitting = false;
      generation++;
      for (const [target, state] of pollers) refresh(target, state);
    }
  });
  discover();
});
</script>
"""


def page_header(title: str, context: str = "", active_repo: Path | None = None) -> str:
    context_html = f"<span class='header-context'>{html.escape(context)}</span>" if context else ""
    archive_href = "/archive"
    if active_repo is not None:
        archive_href += f"?active_repo={quote(str(active_repo), safe='')}"
    return (
        "<header class='site-header'><div class='shell header-row'>"
        f"<a class='home-link' href='/'>Home</a><a class='home-link' href='{archive_href}'>Archived</a><h1>{html.escape(title)}</h1>{context_html}"
        "<label class='theme-control'>Theme <select data-theme-select aria-label='Theme'>"
        "<option value='system'>System</option><option value='light'>Light</option>"
        "<option value='dark'>Dark</option></select></label></div></header>"
    )


def stable_id(*parts: str) -> str:
    return "paw-" + cksum("|".join(parts))


def linked_doc_name(value: str) -> bool:
    return bool(re.fullmatch(r"(?:plan|contract|review|completed-phase)-[a-z0-9-]*[a-f0-9]{12}", value))


def doc_name(value: str) -> str:
    return value if value in {"contract", "plan", "pr", "review"} or linked_doc_name(value) else "plan"


def render_task_markdown(task: Task, content: str) -> str:
    def link(match):
        name = match[1]
        if not linked_doc_name(name):
            return match[0]
        query = urlencode({"path": str(task.path), "active_repo": str(task.repo), "doc": name})
        return '](/task/' + quote(task.name) + '?' + query + ')'
    return render_markdown(re.sub(r'\]\(([a-z0-9-]+)\.md\)', link, content))


class Handler(BaseHTTPRequestHandler):
    repo: Path
    task_home: Path
    all_repos: bool
    repo_registry: Path

    def send_html(self, body: str, code: int = 200) -> None:
        if self.command == "POST" and code >= 400:
            message = html.unescape(re.sub(r"<[^>]*>", "", body))
            if self.asynchronous_action():
                return self.action_result(False, message, code=code)
            if getattr(self, "dashboard_return", ""):
                return self.redirect("/?" + self.flash_query(message, "error"))
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        document = (
            '<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>PAW</title>{THEME_INIT}<style>{STYLE}</style></head>'
            f'<body>{body}{SCRIPT}</body></html>'
        )
        self.wfile.write(document.encode())

    def send_fragment(self, body: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body.encode())

    def asynchronous_action(self) -> bool:
        return self.command == "POST" and "application/json" in self.headers.get("Accept", "")

    def action_result(self, ok: bool, message: str, link: str = "", code: int = 200,
                      active_repo: str | None = None, preview: str = "") -> None:
        result = {"ok": ok, "message": message}
        if preview:
            result["preview"] = preview
        if link:
            result["link"] = link
        if active_repo is not None:
            result["active_repo"] = active_repo
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(json.dumps(result).encode())

    def dashboard_context(self, value: str) -> str:
        parsed = urlparse(value)
        if parsed.scheme or parsed.netloc or parsed.path != "/":
            return ""
        query = parse_qs(parsed.query)
        repo, _ = self.selected_repo(query)
        allowed = {key: query[key][0] for key in ("state", "repo", "completion") if query.get(key)}
        allowed["active_repo"] = str(repo)
        return "/?" + urlencode(allowed)

    def redirect(self, location: str) -> None:
        result_query = parse_qs(urlparse(location).query)
        message = result_query.get("message", [""])[0]
        ok = result_query.get("level", ["notice"])[0] != "error"
        added_repo = None
        if urlparse(self.path).path == "/actions/repos/add" and ok:
            added_repo = str(self.selected_repo(result_query)[0])
        if self.asynchronous_action():
            return self.action_result(ok, message, active_repo=added_repo)
        context = getattr(self, "dashboard_return", "")
        if context:
            query = parse_qs(urlparse(context).query)
            if added_repo is not None:
                query["active_repo"] = [added_repo]
            query.update({key: result_query[key] for key in ("message", "level", "pr_url") if key in result_query})
            location = "/?" + urlencode(query, doseq=True)
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def form_data(self) -> dict[str, str]:
        values = self.form_values()
        return {key: value[0] if value else "" for key, value in values.items()}

    def form_values(self) -> dict[str, list[str]]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        values = parse_qs(raw, keep_blank_values=True)
        self.dashboard_return = self.dashboard_context(values.get("dashboard_return", [""])[0])
        return values

    def flash_query(self, message: str, level: str = "notice") -> str:
        return f"message={quote(message)}&level={quote(level)}"

    def active_repo_query(self, repo: Path) -> str:
        return "" if repo == self.repo else f"active_repo={quote(str(repo), safe='')}"

    def with_active_repo(self, repo: Path, query: str = "") -> str:
        active = self.active_repo_query(repo)
        pieces = [piece for piece in (active, query) if piece]
        return "/?" + "&".join(pieces) if pieces else "/"

    def current_repos(self) -> list[Path]:
        return read_repo_registry(self.repo_registry, self.repo)

    def selected_repo(self, query: dict[str, list[str]]) -> tuple[Path, str]:
        selected = query.get("active_repo", [""])[0]
        if not selected:
            return self.repo, ""
        try:
            requested = physical(Path(selected))
        except Exception:
            return self.repo, f"selected repo is invalid and was reset: {selected}"
        repos = self.current_repos()
        if requested in repos:
            return requested, ""
        return self.repo, f"selected repo is not registered and was reset: {requested}"

    def task_url(self, task: Task, message: str = "", level: str = "notice") -> str:
        url = f"/task/{quote(task.name)}?path={quote(str(task.path), safe='')}"
        if message:
            url += f"&{self.flash_query(message, level)}"
        return url

    def resolve_task(self, name: str, path_value: str = "", active_repo: Path | None = None) -> Task | None:
        lookup_repo = active_repo or self.repo
        all_tasks = list_tasks(lookup_repo, self.task_home, self.all_repos)
        if path_value:
            matches = [task for task in all_tasks if str(task.path) == path_value and task.name == name]
            if not matches:
                task = self.resolve_registered_task_path(name, path_value)
                if task:
                    return task
        else:
            matches = [task for task in all_tasks if task.name == name]
        return matches[0] if matches else None

    def resolve_registered_task_path(self, name: str, path_value: str) -> Task | None:
        if not valid_task_name(name):
            return None
        try:
            task_path = physical(Path(path_value))
        except Exception:
            return None
        if not task_path.is_dir() or task_path.name != name:
            return None
        for repo in self.current_repos():
            central_root = self.task_home / repo_slug(repo)
            if task_path == central_root / name:
                metadata_repo = metadata_value(task_path / "metadata.gitconfig", "repo-root")
                if metadata_repo and physical(Path(metadata_repo)) != repo:
                    return None
                return Task(name, "central", task_path, repo, central_root.name, self.task_home)
            if task_path == repo / ".agent" / name:
                return Task(name, "legacy", task_path, repo, task_home=self.task_home)
        return None

    @read_snapshot
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            return self.index()
        if parsed.path == "/archive":
            return self.archive_index()
        if parsed.path == "/fragments/tasks":
            return self.tasks_fragment(parse_qs(parsed.query))
        if parsed.path == "/fragments/dashboard-controls":
            query = parse_qs(parsed.query)
            active_repo, _ = self.selected_repo(query)
            return self.send_fragment(self.dashboard_forms(
                self.index_filters(query, active_repo) + self.dashboard_actions(active_repo), query))
        if parsed.path.startswith("/fragments/task-doc/"):
            query = parse_qs(parsed.query)
            return self.task_doc_fragment(
                unquote(parsed.path.removeprefix("/fragments/task-doc/")),
                query.get("doc", ["plan"])[0],
                query.get("path", [""])[0],
                query.get("active_repo", [""])[0],
                query.get("approve", [""])[0],
            )
        if parsed.path.startswith("/fragments/task-stream/"):
            query = parse_qs(parsed.query)
            return self.task_stream_fragment(
                unquote(parsed.path.removeprefix("/fragments/task-stream/")),
                query.get("path", [""])[0],
                query.get("active_repo", [""])[0],
            )
        if parsed.path.startswith("/fragments/task/"):
            query = parse_qs(parsed.query)
            return self.task_fragment(
                unquote(parsed.path.removeprefix("/fragments/task/")),
                query.get("doc", ["plan"])[0],
                query.get("path", [""])[0],
                query.get("active_repo", [""])[0],
                query.get("run", [""])[0],
            )
        if parsed.path.startswith("/task/") and parsed.path.endswith("/stream"):
            query = parse_qs(parsed.query)
            return self.task_stream(
                unquote(parsed.path.removeprefix("/task/").removesuffix("/stream")),
                query.get("path", [""])[0],
                query.get("active_repo", [""])[0],
            )
        if parsed.path.startswith("/task/"):
            query = parse_qs(parsed.query)
            return self.task(
                unquote(parsed.path.removeprefix("/task/")),
                query.get("doc", ["plan"])[0],
                query.get("path", [""])[0],
                query.get("active_repo", [""])[0],
                query.get("message", [""])[0],
                query.get("level", ["notice"])[0],
                query.get("run", [""])[0],
            )
        self.send_html("<h1>Not found</h1>", 404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/actions/plan":
            return self.post_plan()
        if parsed.path == "/actions/repos/add":
            return self.post_add_repo()
        if parsed.path == "/actions/queue/trigger":
            return self.post_queue_trigger()
        if parsed.path == "/actions/queue/edit":
            return self.post_queue_edit()
        if parsed.path == "/actions/queue/delete":
            return self.post_queue_delete()
        if parsed.path.startswith("/task/") and parsed.path.endswith("/edit"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/edit"))
            return self.post_task_action(name, "edit")
        if parsed.path.startswith("/task/") and parsed.path.endswith("/implement"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/implement"))
            return self.post_task_action(name, "implement")
        if parsed.path.startswith("/task/") and parsed.path.endswith("/review"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/review"))
            return self.post_task_action(name, "review")
        if parsed.path.startswith("/task/") and parsed.path.endswith("/prototype"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/prototype"))
            return self.post_task_action(name, "prototype")
        if parsed.path.startswith("/task/") and parsed.path.endswith("/archive"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/archive"))
            return self.post_task_action(name, "archive")
        if parsed.path.startswith("/task/") and parsed.path.endswith("/cancel"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/cancel"))
            return self.post_cancel(name)
        for action in ("pr-preview", "pr-update"):
            if parsed.path.startswith("/task/") and parsed.path.endswith("/" + action):
                name = unquote(parsed.path.removeprefix("/task/").removesuffix("/" + action))
                return self.post_pr_publication(name, action)
        if parsed.path.startswith("/task/") and parsed.path.endswith("/view-pr"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/view-pr"))
            return self.post_view_pr(name)
        if parsed.path.startswith("/archive/") and parsed.path.endswith("/unarchive"):
            name = unquote(parsed.path.removeprefix("/archive/").removesuffix("/unarchive"))
            return self.post_unarchive(name)
        if parsed.path.startswith("/task/") and parsed.path.endswith("/delete"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/delete"))
            return self.post_delete(name)
        self.send_html("<h1>Not found</h1>", 404)

    def post_plan(self) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task_name = form.get("task_name", "").strip()
        prompt = form.get("prompt", "").strip()
        action = form.get("plan_action", "plan")
        if not valid_task_name(task_name):
            return self.redirect(self.with_active_repo(active_repo, self.flash_query("invalid task name", "error")))
        if not prompt:
            return self.redirect(self.with_active_repo(active_repo, self.flash_query("prompt is required", "error")))
        task_path = self.task_home / repo_slug(active_repo) / task_name
        if action == "queue":
            try:
                write_queued_plan(self.task_home, active_repo, task_name, prompt)
            except FileExistsError:
                return self.redirect(self.with_active_repo(active_repo, self.flash_query(f"queued plan prompt already exists for {task_name}", "error")))
            return self.redirect(self.with_active_repo(active_repo, self.flash_query(f"queued plan prompt {task_name}", "notice")))
        ok, message = launch_paw(active_repo, self.task_home, task_path, ["plan", task_name, prompt])
        self.redirect(self.with_active_repo(active_repo, self.flash_query(message, "notice" if ok else "error")))

    def post_add_repo(self) -> None:
        form = self.form_data()
        repo, error = normalize_git_repo(form.get("repo_path", ""))
        if error or repo is None:
            return self.redirect(f"/?{self.flash_query(error, 'error')}")
        add_repo_to_registry(self.repo_registry, self.repo, repo)
        self.redirect(self.with_active_repo(repo, self.flash_query(f"added repo {repo}", "notice")))

    def post_queue_edit(self) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task_name = form.get("task_name", "").strip()
        try:
            update_queued_plan(self.task_home, active_repo, form.get("original_task_name", "").strip(), task_name, form.get("prompt", ""))
        except (ValueError, OSError, subprocess.CalledProcessError) as exc:
            return self.redirect(self.with_active_repo(active_repo, self.flash_query(f"could not update queued plan: {exc}", "error")))
        self.redirect(self.with_active_repo(active_repo, self.flash_query(f"updated queued plan {task_name}", "notice")))

    @queue_lock()
    def post_queue_trigger(self) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task_name = form.get("task_name", "").strip()
        item = queue_item_dir(self.task_home, active_repo, task_name)
        prompt_file = item / "prompt.txt"
        if not valid_task_name(task_name) or not prompt_file.exists():
            return self.redirect(self.with_active_repo(active_repo, self.flash_query("queued plan prompt not found", "error")))
        prompt = prompt_file.read_text(errors="replace").strip()
        task_path = self.task_home / repo_slug(active_repo) / task_name
        ok, message = launch_paw(active_repo, self.task_home, task_path, ["plan", task_name, prompt])
        if ok:
            shutil.rmtree(item)
            message = f"triggered queued plan {task_name}: {message}"
        self.redirect(self.with_active_repo(active_repo, self.flash_query(message, "notice" if ok else "error")))

    @queue_lock()
    def post_queue_delete(self) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task_name = form.get("task_name", "").strip()
        item = queue_item_dir(self.task_home, active_repo, task_name)
        if not valid_task_name(task_name) or not item.exists():
            return self.redirect(self.with_active_repo(active_repo, self.flash_query("queued plan prompt not found", "error")))
        shutil.rmtree(item)
        self.redirect(self.with_active_repo(active_repo, self.flash_query(f"removed queued plan {task_name}", "notice")))

    @queue_lock()
    def post_task_action(self, name: str, subcommand: str) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task = self.resolve_task(name, form.get("path", ""), active_repo)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        if subcommand == "implement" and task.blocked:
            return self.redirect(self.task_url(task, "implement blocked: reconcile USER ANSWER placeholders first", "error"))
        if task.running:
            return self.redirect(self.task_url(task, f"{task.name} already has a running PAW subprocess", "error"))
        if subcommand == "prototype":
            reason = prototype_disabled_reason(task)
            if reason:
                return self.redirect(self.task_url(task, f"prototype blocked: {reason}", "error"))
        if subcommand == "prototype":
            replacements = [peer for peer in list_repo_tasks(task.repo, self.task_home)
                            if peer.name == task.name + "-prototype"]
            if any(peer.running for peer in replacements):
                return self.redirect(self.task_url(task, "replacement already has a running PAW subprocess", "error"))
        if subcommand == "implement" and task_workflow(task).action != "approve-implementation":
            return self.redirect(self.task_url(task, "implement blocked: current task is not ready for approval", "error"))
        args = [subcommand, task.name]
        extras = "" if subcommand == "implement" else form.get("extras", "")
        if subcommand == "edit" and task.blocked:
            extras = answer_extras(task, form.get("answers", "").strip(), extras)
        if extras and subcommand != "archive":
            args.append(extras)
        ok, message = launch_paw(task.repo, self.task_home, task.path, args)
        if subcommand == "archive" and ok:
            return self.redirect(f"/?{self.flash_query(message, 'notice')}")
        self.redirect(self.task_url(task, message, "notice" if ok else "error"))

    def post_pr_publication(self, name: str, action: str) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task = self.resolve_task(name, form.get("path", ""), active_repo)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        try:
            if task.running:
                raise ValueError("A PAW run is active; finish it before publication.")
            if action == "pr-update":
                result = pr_publication.publish(task.path, task.repo, form.get("token", ""), create_only=False)
                if self.asynchronous_action():
                    return self.action_result(True, result["message"], result["url"])
                return self.send_html(page_header("PR updated", active_repo=task.repo) +
                                      "<main class='shell'><p>" + html.escape(result["message"]) +
                                      f"</p><p><a href='{html_attr(result['url'])}'>Open PR</a></p>" +
                                      self.archive_form(task) + "</main>")
            result = pr_publication.prepare(task.path, task.repo, create_only=False)
            content = self.pr_preview_panel(task, result)
            if self.asynchronous_action():
                return self.action_result(True, "Inspect the candidate before publishing.", preview=content)
            return self.send_html(page_header("PR preview", active_repo=task.repo) +
                                  "<main class='shell'>" + content.replace("class='modal-panel'", "class='publication-panel'").replace("class='modal-body'", "class='publication-body'") + self.archive_form(task) + "</main>")
        except (ValueError, OSError, KeyError, TypeError) as error:
            return self.redirect(self.task_url(task, f"Update PR blocked: {error}", "error"))

    def pr_preview_panel(self, task: Task, result: dict) -> str:
        identity = result["target"]["repository"] + " / " + result["target"]["head"]
        remote = result["current"]
        return (
            "<div class='modal-panel'><div class='modal-body'><h2>Update PR preview</h2>"
            f"<p>{html.escape(identity)} — {('PR #' + str(remote['number'])) if remote else 'Create draft'}</p>"
            f"<p>Mode: {html.escape(result['operation'])}</p><p>{html.escape(result['code_status'])}</p><p>{html.escape(result['adoption'])}</p>"
            f"<p>{html.escape(result['visual'])}</p>"
            f"<details><summary>Body changes</summary><pre>{html.escape(result['diff'])}</pre></details>"
            f"<h3>Exact candidate body</h3><pre class='publication-candidate'>{html.escape(result['candidate'])}</pre>"
            f"<form method='post' action='/task/{quote(task.name)}/pr-update'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            f"<input type='hidden' name='token' value='{html_attr(result['token'])}'>"
            "<button type='submit'>Publish PR body</button> "
            "<button type='button' data-modal-close>Close</button></form></div></div>"
        )

    def post_view_pr(self, name: str) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task = self.resolve_task(name, form.get("path", ""), active_repo)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        branch = view_pr_branch(task)
        if not branch:
            return self.redirect(self.task_url(task, "View PR unavailable: saved branch is missing or no longer exists locally", "error"))
        try:
            result = subprocess.run(
                ["gh", "pr", "view", branch, "--json", "url", "--jq", ".url"],
                cwd=str(task.repo),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        except FileNotFoundError:
            return self.redirect(self.task_url(task, "View PR unavailable: gh is not installed or not on PATH", "error"))
        except OSError as exc:
            return self.redirect(self.task_url(task, f"View PR unavailable: gh failed to start: {exc}", "error"))
        pr_url = result.stdout.strip()
        if result.returncode != 0:
            details = result.stderr.strip() or pr_url
            diagnostic = details.lower()
            if result.returncode == 4 or any(marker in diagnostic for marker in (
                "gh auth", "gh_token", "github_token", "authentication", "bad credentials",
            )):
                message = f"View PR unavailable: gh authentication/configuration failed: {details or 'authentication required'}"
            elif re.match(r"^no pull requests? found(?:\s|$)", diagnostic):
                message = f"No current PR found for branch {branch}"
            else:
                details = details or f"exit status {result.returncode}; no diagnostic output"
                message = f"View PR unavailable: gh lookup failed for branch {branch}: {details}"
            return self.redirect(self.task_url(task, message, "error"))
        if not re.match(r"^https?://", pr_url):
            return self.redirect(self.task_url(task, f"View PR unavailable: gh returned an invalid PR URL for branch {branch}", "error"))
        if self.asynchronous_action():
            return self.action_result(True, f"Current PR for {task.name}", pr_url)
        if getattr(self, "dashboard_return", ""):
            return self.redirect("/?" + self.flash_query(f"Current PR for {task.name}") + "&pr_url=" + quote(pr_url, safe=""))
        body = (
            f"{page_header(f'Current PR for {task.name}', task.repo_name, task.repo)}<main class='shell'>"
            f"<p><a class='button' href='{html_attr(self.task_url(task))}'>Task</a></p>"
            f"<h2>Current PR for {html.escape(task.name)}</h2>"
            f"<p><a href='{html_attr(pr_url)}'>{html.escape(pr_url)}</a></p>"
            "</main>"
        )
        self.send_html(body)

    def post_cancel(self, name: str) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task = self.resolve_task(name, form.get("path", ""), active_repo)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        run = task.active_run
        if not run:
            return self.redirect(self.task_url(task, f"{task.name} has no active PAW run to cancel", "error"))
        if not run.cancellable or run.pid is None:
            return self.redirect(self.task_url(task, f"{task.name} has running metadata without a live cancellable PID", "error"))
        if not process_looks_like_paw(run.pid):
            return self.redirect(self.task_url(task, f"cancel blocked: recorded pid {run.pid} is not a verified PAW process", "error"))

        try:
            pgid = os.getpgid(run.pid)
            if pgid == run.pid:
                os.killpg(pgid, signal.SIGTERM)
            else:
                os.kill(run.pid, signal.SIGTERM)
        except ProcessLookupError:
            return self.redirect(self.task_url(task, f"{task.name} run already exited", "notice"))
        except PermissionError:
            return self.redirect(self.task_url(task, f"cancel blocked: permission denied for pid {run.pid}", "error"))

        for _ in range(10):
            try:
                os.kill(run.pid, 0)
            except OSError:
                mark_run_cancelled(run.metadata)
                return self.redirect(self.task_url(task, f"cancelled {task.name}", "notice"))
            time.sleep(0.1)
        if process_looks_like_paw(run.pid):
            try:
                os.kill(run.pid, signal.SIGKILL)
            except OSError:
                pass
            mark_run_cancelled(run.metadata, 137)
            return self.redirect(self.task_url(task, f"cancelled {task.name} after SIGKILL fallback", "notice"))
        return self.redirect(self.task_url(task, f"cancel incomplete: recorded pid {run.pid} changed before exit", "error"))

    def post_delete(self, name: str) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task = self.resolve_task(name, form.get("path", ""), active_repo)
        if not task:
            named_task = self.resolve_task(name, "", active_repo)
            if named_task:
                return self.redirect(self.task_url(named_task, "delete rejected: stale task path", "error"))
            return self.send_html("<h1>Task not found</h1>", 404)
        if task.running:
            return self.redirect(self.task_url(task, "delete blocked while a PAW subprocess is running", "error"))
        if form.get("confirm", "") != "yes":
            return self.redirect(self.task_url(task, "delete confirmation is required", "error"))
        submitted = form.get("path", "")
        if submitted != str(task.path):
            return self.redirect(self.task_url(task, "delete rejected: stale task path", "error"))
        shutil.rmtree(task.path)
        self.redirect(f"/?{self.flash_query(f'deleted task {task.name}', 'notice')}")

    @read_snapshot
    def index(self) -> None:
        query = parse_qs(urlparse(self.path).query)
        active_repo, repo_error = self.selected_repo(query)
        message = query.get("message", [""])[0]
        level = query.get("level", ["notice"])[0]
        if repo_error:
            message = repo_error if not message else f"{repo_error}; {message}"
            level = "error"
        scope = "All task stores" if self.all_repos else f"{active_repo.name or 'repo'} repo"
        central_note = str(self.task_home) if self.all_repos else str(self.task_home / repo_slug(active_repo))
        refresh_query = {
            key: query.get(key, [""])[0]
            for key in ("active_repo", "state", "repo", "completion")
            if query.get(key, [""])[0]
        }
        refresh_url = "/fragments/tasks"
        if refresh_query:
            refresh_url += "?" + urlencode(refresh_query)
        pr_url = query.get("pr_url", [""])[0]
        pr_link = f"<p><a href='{html_attr(pr_url)}'>Open PR</a></p>" if re.match(r"^https?://", pr_url) else ""
        body = (
            f"{page_header('PAW Tasks', scope, active_repo)}<main class='shell'>"
            f"{self.flash_html(message, level)}{pr_link}"
            "<p data-action-feedback role='status' aria-live='polite' aria-atomic='true'></p>"
            f"<div id='dashboard-controls' data-paw-refresh-url='{html_attr(refresh_url.replace('/fragments/tasks', '/fragments/dashboard-controls'))}'>"
            f"{self.index_filters(query, active_repo)}"
            f"{self.dashboard_actions(active_repo)}</div>"
            f"<div id='task-list' data-paw-refresh-url=\"{html_attr(refresh_url)}\" data-paw-refresh-interval-ms=\"2500\">"
            f"{self.index_task_list(query, active_repo)}"
            "</div><div class='doc-preview' data-doc-preview></div></main>"
        )
        self.send_html(self.dashboard_forms(body, query))

    def archive_index(self) -> None:
        query = parse_qs(urlparse(self.path).query)
        active_repo, repo_error = self.selected_repo(query)
        message = query.get("message", [""])[0]
        level = query.get("level", ["notice"])[0]
        if repo_error:
            message = repo_error if not message else f"{repo_error}; {message}"
            level = "error"
        scope = "All task stores" if self.all_repos else f"{active_repo.name or 'repo'} repo"
        body = (
            f"{page_header('Archived Tasks', scope, active_repo)}<main class='shell'>"
            f"{self.flash_html(message, level)}"
            f"{self.repo_selector(active_repo)}"
            f"{self.archived_task_list(active_repo)}"
            "</main>"
        )
        self.send_html(body)

    def dashboard_forms(self, body: str, query: dict[str, list[str]]) -> str:
        context = self.dashboard_context("/?" + urlencode(query, doseq=True))
        hidden = f"<input type='hidden' name='dashboard_return' value='{html_attr(context)}'>"
        return re.sub(r"(<form\b[^>]*method=['\"]post['\"][^>]*>)", lambda match: match[0] + hidden, body)

    def tasks_fragment(self, query: dict[str, list[str]]) -> None:
        active_repo, error = self.selected_repo(query)
        if error:
            active_repo = self.repo
        self.send_fragment(self.dashboard_forms(self.index_task_list(query, active_repo), query))

    def repo_selector(self, active_repo: Path) -> str:
        repos = self.current_repos()
        labels = {repo: repo.name if sum(other.name == repo.name for other in repos) == 1
                  else (str(Path(repo.parent.name) / repo.name) if sum(other.parts[-2:] == repo.parts[-2:] for other in repos) == 1
                        else str(repo)) for repo in repos}
        options = "".join(option_tag(str(repo), labels[repo], str(active_repo)) for repo in repos)
        query = parse_qs(urlparse(self.path).query)
        filters = "".join(f"<input type='hidden' name='{key}' value='{html_attr(query[key][0])}'>"
                          for key in ("state", "repo", "completion") if query.get(key))
        return (
            "<form class='toolbar repo-toolbar' method='get' data-repo-switch>"
            f"{filters}<label>Active repo <select name=\"active_repo\">{options}</select></label>"
            "<button type='submit' class='switch-fallback'>Switch</button></form>"
            "<details class='repo-management'><summary>Manage repos</summary>"
            f"{path_disclosure('Active repo path', str(active_repo))}"
            "<form class='toolbar' method='post' action='/actions/repos/add'>"
            "<label>Add repo path <input name='repo_path' required></label>"
            "<button type='submit'>Add repo</button></form></details>"
        )

    def index_filters(self, query: dict[str, list[str]], active_repo: Path) -> str:
        state_filter = query.get("state", [""])[0]
        completion_filter = query.get("completion", [""])[0]
        all_tasks = list_tasks(active_repo, self.task_home, self.all_repos)
        state_options = sorted({task.state for task in all_tasks})
        completion_options = sorted(
            {status_field(task.plan, "Estimated completion") for task in all_tasks if status_field(task.plan, "Estimated completion")}
        )
        state_select = "".join([option_tag("", "Any state", state_filter), *(option_tag(state, state, state_filter) for state in state_options)])
        completion_select = "".join(
            [option_tag("", "Any completion", completion_filter), *(option_tag(value, value, completion_filter) for value in completion_options)]
        )
        repo_filter = query.get("repo", [""])[0]
        open_attr = " open" if state_filter or completion_filter or repo_filter else ""
        return (
            f"{self.repo_selector(active_repo)}"
            f"<details class='filter-disclosure'{open_attr}><summary>Filter tasks{' · Active' if open_attr else ''}</summary>"
            "<form class='toolbar' method='get'>"
            "<div class='toolbar-fields'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(active_repo))}'>"
            f"<label>State <select name=\"state\">{state_select}</select></label>"
            f"<label>Repo filter <input name=\"repo\" value=\"{html_attr(repo_filter)}\"></label>"
            f"<label>Completion <select name=\"completion\">{completion_select}</select></label>"
            "</div><div class='top-actions'>"
            f"<button type='submit'>Filter</button>{self.clear_filters_link(active_repo)}"
            "</div></form></details>"
        )

    def clear_filters_link(self, active_repo: Path) -> str:
        return (f"<a class='button' data-clear-filters href='/?active_repo={quote(str(active_repo), safe='')}'>"
                "Clear filters</a>")

    def new_plan_modal(self, active_repo: Path) -> str:
        queued = self.queued_plan_list(active_repo)
        return (
            "<details class='modal-toggle' data-new-plan><summary><span class='button primary'>New Plan</span></summary>"
            "<div class='modal-panel'><div class='modal-body'>"
            "<form method='post' action='/actions/plan'>"
            "<h2>New Plan</h2>"
            f"<p class='plan-destination'>Destination: <strong>{html.escape(active_repo.name)}</strong>"
            f"<br><code>{html.escape(str(active_repo))}</code></p>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(active_repo))}'>"
            "<p><label>Task name <input name='task_name' required pattern='[A-Za-z0-9._-]+'></label></p>"
            "<p><label>Prompt<br><textarea name='prompt' required rows='4'></textarea></label></p>"
            "<p class='action-row'><button type='submit' name='plan_action' value='plan'>Plan</button>"
            "<button type='submit' name='plan_action' value='queue' title='Save this prompt locally so planning can be started later'>Queue</button>"
            "<button type='button' data-modal-close onclick='this.closest(\"details\").removeAttribute(\"open\")'>Close</button></p>"
            f"</form>{queued}</div></div></details>"
        )

    def dashboard_actions(self, active_repo: Path) -> str:
        return (
            "<div class='dashboard-actions'>"
            f"{self.new_plan_modal(active_repo)}"
            f"<a class='queue-trigger' href='#queued-plans' data-open-queue>Queued Plans ({len(list_queued_plans(self.task_home, active_repo))})</a>"
            "</div>"
        )

    def queued_plan_list(self, active_repo: Path) -> str:
        items = list_queued_plans(self.task_home, active_repo)
        if not items:
            return ""
        rows = []
        for item in items:
            rows.append(
                f"<tr data-paw-key='{html_attr(str(active_repo) + ':' + item.task_name)}'>"
                f"<td><span class='task-title'>{html.escape(item.task_name)}</span></td>"
                f"<td><pre class='queued-prompt'>{html.escape(item.prompt)}</pre></td>"
                "<td><div class='action-row'>"
                "<details><summary>Edit</summary>"
                "<form method='post' action='/actions/queue/edit'>"
                f"<input type='hidden' name='active_repo' value='{html_attr(str(active_repo))}'>"
                f"<input type='hidden' name='original_task_name' value='{html_attr(item.task_name)}'>"
                f"<label>Task name <input name='task_name' value='{html_attr(item.task_name)}' required></label>"
                f"<label>Prompt <textarea name='prompt' rows='8' required>{html.escape(item.prompt)}</textarea></label>"
                "<button type='submit'>Save</button></form></details>"
                "<form class='inline-form' method='post' action='/actions/queue/trigger'>"
                f"<input type='hidden' name='active_repo' value='{html_attr(str(active_repo))}'>"
                f"<input type='hidden' name='task_name' value='{html_attr(item.task_name)}'>"
                "<button type='submit'>Plan</button></form>"
                "<form class='inline-form' method='post' action='/actions/queue/delete'>"
                f"<input type='hidden' name='active_repo' value='{html_attr(str(active_repo))}'>"
                f"<input type='hidden' name='task_name' value='{html_attr(item.task_name)}'>"
                "<button type='submit'>Remove</button></form>"
                "</div></td></tr>"
            )
        return (
            "<h3 id='queued-plans'>Queued Plans</h3><div class='table-wrap'><table><thead><tr><th>Task</th><th>Prompt</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody></table></div>"
        )

    def extras_modal(self, task: Task, action: str, label: str) -> str:
        action_path = f"/task/{quote(task.name)}/{action}"
        questions = task.answer_questions if action == "edit" and task.blocked else []
        default_extras = ""
        question_block = (
            "<p>Create or reuse a replacement plan from this review. After planning succeeds, "
            "PAW attempts conservative source cleanup. Approve the replacement separately.</p>"
            if action == "prototype" else ""
        )
        answers_block = ""
        if action == "prototype":
            peers = getattr(task, "_peers", None)
            if peers is None:
                peers = list_repo_tasks(task.repo, self.task_home)
            replacements = [peer for peer in peers
                            if peer.name == task.name + "-prototype"]
            if replacements:
                question_block += f"<p>Reuse existing replacement: {html.escape(replacements[0].name)}. Existing documents are retained for the planning run.</p>"
        if action == "edit" and task.blocked:
            default_extras = (
                "Answer/reconcile the listed USER ANSWER placeholders in plan.md as part of this edit run. "
                "Do not change implementation files."
            )
            if questions:
                items = "".join(f"<li>{html.escape(question)}</li>" for question in questions)
                question_block = f"<div class='question-list'><h3>Pending questions</h3><ol>{items}</ol></div>"
            answers_block = "<p><label>Answers<br><textarea name='answers' rows='5'></textarea></label></p>"
        return (
            "<details class='modal-toggle'>"
            f"<summary><span class='button'>{html.escape(label)}</span></summary>"
            "<div class='modal-panel'><div class='modal-body'>"
            f"<form method='post' action='{action_path}'>"
            f"<h2>{html.escape(label)} {html.escape(task.name)}</h2>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            f"{question_block}"
            f"{answers_block}"
            f"<p><label>Extra instructions<br><textarea name='extras' rows='4'>{html.escape(default_extras)}</textarea></label></p>"
            f"<p class='action-row'><button type='submit'>{html.escape(label)}</button><button type='button' data-modal-close onclick='this.closest(\"details\").removeAttribute(\"open\")'>Close</button></p>"
            "</form></div></div></details>"
        )

    def approve_implementation_button(self, task: Task, label: str = "Approve Implementation") -> str:
        preview_url = (
            f"/fragments/task-doc/{quote(task.name)}?path={quote(str(task.path), safe='')}"
            f"&doc=plan&approve=implementation&active_repo={quote(str(task.repo), safe='')}"
        )
        return f"<button type='button' data-doc-preview-url='{html_attr(preview_url)}'>{html.escape(label)}</button>"

    def action_form(self, task: Task, action: str, label: str) -> str:
        return (
            f"<form class='inline-form' method='post' action='/task/{quote(task.name)}/{action}'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            f"<button type='submit'>{html.escape(label)}</button></form>"
        )

    def view_pr_form(self, task: Task) -> str:
        return self.action_form(task, "view-pr", "View PR")

    def archive_form(self, task: Task) -> str:
        return (
            f"<form class='inline-form' method='post' action='/task/{quote(task.name)}/archive'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            "<button class='archive' type='submit'>Archive</button></form>"
        )

    def cancel_form(self, task: Task) -> str:
        return (
            f"<form class='inline-form' method='post' action='/task/{quote(task.name)}/cancel'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            "<button class='danger' type='submit'>Cancel</button></form>"
        )

    def stream_url(self, task: Task) -> str:
        return f"/task/{quote(task.name)}/stream?path={quote(str(task.path), safe='')}&active_repo={quote(str(task.repo), safe='')}"

    def task_stream_link(self, task: Task) -> str:
        return f"<a class='button' href='{html_attr(self.stream_url(task))}'>Stream</a>"

    def streamable(self, task: Task) -> bool:
        logs = active_run_logs(task.active_run.metadata.parent.parent, task.active_run) if task.active_run else None
        return bool(logs and logs.available)

    def unarchive_form(self, task: Task) -> str:
        return (
            f"<form class='inline-form' method='post' action='/archive/{quote(task.name)}/unarchive'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            "<button type='submit'>Unarchive</button></form>"
        )

    def delete_modal(self, task: Task) -> str:
        return (
            "<details class='modal-toggle'>"
            "<summary><span class='button danger'>Delete</span></summary>"
            "<div class='modal-panel'><div class='modal-body'>"
            f"<form method='post' action='/task/{quote(task.name)}/delete'>"
            f"<h2>Delete {html.escape(task.name)}</h2>"
            "<p>Are you sure?</p>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            "<input type='hidden' name='confirm' value='yes'>"
            "<p class='action-row'><button class='danger' type='submit'>Delete</button><button type='button' data-modal-close onclick='this.closest(\"details\").removeAttribute(\"open\")'>Cancel</button></p>"
            "</form></div></div></details>"
        )

    def task_actions(self, task: Task, include_docs: bool = False) -> str:
        active_query = f"&active_repo={quote(str(task.repo), safe='')}"
        pieces = []
        if view_pr_branch(task):
            pieces.append(self.view_pr_form(task))
        if self.streamable(task):
            pieces.append(self.task_stream_link(task))
        if include_docs:
            for doc in ("plan",):
                preview_url = f"/fragments/task-doc/{quote(task.name)}?path={quote(str(task.path), safe='')}&doc={doc}{active_query}"
                pieces.append(f"<button type='button' data-doc-preview-url='{html_attr(preview_url)}' aria-label='Preview plan for {html_attr(task.name)}'>Preview plan</button>")
        edit_label = "Answer Questions" if task.blocked else "Edit"
        if not include_docs or task_workflow(task).action != "edit":
            pieces.append(self.extras_modal(task, "edit", edit_label))
        if not include_docs and task_workflow(task).action == "approve-implementation":
            pieces.append(self.approve_implementation_button(task))
        if not include_docs:
            prototype_reason = prototype_disabled_reason(task)
            prototype_control = (
                f"<span class='disabled-action' title='{html_attr(prototype_reason)}'>Use as Prototype</span>"
                if prototype_reason
                else self.extras_modal(task, "prototype", "Use as Prototype")
            )
            pieces.extend([self.extras_modal(task, "review", "Review"), prototype_control])
        utilities = f"<div class='task-utilities action-row'>{''.join(pieces)}</div>"
        if include_docs:
            utilities = (f"<details class='row-tools' data-paw-key='tools:{html_attr(str(task.path))}'>"
                         f"<summary aria-label='Tools for {html_attr(task.name)}'>Tools</summary>{utilities}</details>")
        return (utilities +
                f"<div class='lifecycle-actions action-row'>{self.archive_form(task)}{self.delete_modal(task)}</div>")

    def workflow_action_control(self, task: Task, workflow: TaskWorkflow) -> str:
        if workflow.action == "pr-preview":
            return "<div class='action-row'>" + self.action_form(task, "pr-preview", "Update PR") + self.archive_form(task) + "</div>"
        if workflow.next_label == "Update PR":
            return f"<span class='disabled-action' title='{html_attr(workflow.disabled_reason)}'>Update PR</span>" + self.archive_form(task)
        if workflow.action in {"edit", "prototype"}:
            return self.extras_modal(task, workflow.action, workflow.next_label)
        if workflow.action == "cancel":
            pieces = []
            if self.streamable(task):
                pieces.append(self.task_stream_link(task))
            pieces.append(self.cancel_form(task))
            return f"<div class='action-row'>{''.join(pieces)}</div>"
        if workflow.action == "approve-implementation":
            return self.approve_implementation_button(task, workflow.next_label)
        if workflow.action in {"implement", "review", "prototype", "archive"}:
            return self.action_form(task, workflow.action, workflow.next_label)
        reason = workflow.disabled_reason or "Action unavailable"
        return f"<span class='disabled-action' title='{html_attr(reason)}'>{html.escape(workflow.next_label)}</span>"

    def dashboard_stage_cell(self, task: Task, workflow: TaskWorkflow) -> str:
        statuses = [task.prototype_status, *(peer.prototype_status for peer in task.prototype_peers)]
        warning = any(any(word in status for word in ("blocked", "unavailable", "failed", "planning")) for status in statuses)
        warning = warning or workflow.stage == "Planning incomplete"
        indicator = "Needs attention" if warning else "Prototype"
        prototype = task.prototype_source or task.prototype_status or task.prototype_peers or warning
        note = f"<span class='{'prototype-warning' if warning else 'muted'}'>{indicator}</span>" if prototype else ""
        return (f"<div class='dashboard-stage'><span class='pill {task.state}'>Stage: {html.escape(workflow.stage)}</span>{note}"
                f"<a href='{html_attr(self.task_url(task) + '&active_repo=' + quote(str(task.repo), safe=''))}' aria-label='Stage details and lineage for {html_attr(task.name)}'>Details / lineage</a></div>")

    def workflow_stage_cell(self, task: Task, workflow: TaskWorkflow) -> str:
        parts = [
            f"<div><span class='pill {task.state}'>Stage: {html.escape(workflow.stage)}</span></div>",
            f"<div class='workflow-note muted'>{html.escape(status_field(task.plan, 'Plan position') or '<missing>')}</div>",
            f"<div class='workflow-note muted'>{html.escape(task.source)}</div>",
        ]
        if task.prototype_status or task.prototype_source:
            label = task.prototype_status or "prototyped"
            if task.prototype_source:
                label = f"{label} from {task.prototype_source}"
            parts.append(f"<div class='workflow-note'><span class='pill'>{html.escape(label)}</span></div>")
            if task.prototype_cleanup_message:
                parts.append(f"<div class='workflow-note muted'>{html.escape(task.prototype_cleanup_message)}</div>")
        peers = task.prototype_peers
        for peer in peers:
            label = "Open source" if peer.name == task.prototype_source else "Open replacement"
            parts.append(f"<div class='workflow-note'><a href='{html_attr(self.task_url(peer))}'>{label}: {html.escape(peer.name)}</a></div>")
            if label == "Open replacement" and peer.prototype_status:
                parts.append(f"<div class='workflow-note'>{html.escape(peer.prototype_status)}: {html.escape(peer.prototype_cleanup_message)}</div>")
        if task.prototype_source and not any(peer.name == task.prototype_source for peer in peers):
            parts.append(f"<div class='workflow-note'>Source {html.escape(task.prototype_source)} is archived or unavailable.</div>")
        return f"<div class='workflow-cell'>{''.join(parts)}</div>"

    def workflow_next_cell(self, task: Task, workflow: TaskWorkflow) -> str:
        reason = f"<div class='workflow-note muted'>{html.escape(workflow.disabled_reason)}</div>" if workflow.disabled_reason else ""
        note_text = "" if workflow.note == "Review." and workflow.stage in {"Review", "Reviewed", "Prototype"} else workflow.note
        note = f"<div class='workflow-note muted'>{html.escape(note_text)}</div>" if note_text else ""
        grade = review_grade(task.review) if workflow.stage == "Reviewed" else ""
        grade_badge = (
            f"<div class='workflow-note'><span class='review-grade {review_grade_class(grade)}'>Review grade: {html.escape(grade)}</span></div>"
            if grade
            else ""
        )
        return (
            "<div class='workflow-cell'>"
            f"<div class='workflow-label'>Next: {html.escape(workflow.next_label)}</div>"
            f"{grade_badge}{note}{reason}"
            f"<div class='workflow-actions'>{self.workflow_action_control(task, workflow)}</div>"
            "</div>"
        )

    @read_snapshot
    def index_task_list(self, query: dict[str, list[str]], active_repo: Path) -> str:
        state_filter = query.get("state", [""])[0]
        repo_filter = query.get("repo", [""])[0].strip().lower()
        completion_filter = query.get("completion", [""])[0]
        all_tasks = list_tasks(active_repo, self.task_home, self.all_repos)
        rows = []
        for task in all_tasks:
            done, total = checklist_counts(task.plan)
            completion = status_field(task.plan, "Estimated completion") or "<missing>"
            repo_text = " ".join((task.repo_name, str(task.repo), task.slug)).lower()
            if state_filter and task.state != state_filter:
                continue
            if repo_filter and repo_filter not in repo_text:
                continue
            if completion_filter and completion != completion_filter:
                continue
            task_href = f"/task/{quote(task.name)}?path={quote(str(task.path), safe='')}&active_repo={quote(str(task.repo), safe='')}"
            branch = task.branch_context or "<none>"
            workflow = task_workflow(task)
            rows.append(
                f"<tr data-paw-key='{html_attr(str(task.path))}' role='row'>"
                f"<td role='cell' data-label='Task'><a class='task-title' href='{task_href}'>{html.escape(task.name)}</a>{path_disclosure('Task path', str(task.path))}</td>"
                f"<td role='cell' data-label='Repo'><div class='repo-name'>{html.escape(task.repo_name)}</div><div class='task-subtle muted'>Branch: {html.escape(branch)}</div>{repo_disclosure(task, branch)}</td>"
                f"<td role='cell' data-label='Stage'>{self.dashboard_stage_cell(task, workflow)}</td>"
                f"<td role='cell' data-label='Next'>{self.workflow_next_cell(task, workflow)}</td>"
                f"<td role='cell' data-label='Completion'><span class='metric-chip'>{html.escape(completion)}</span></td>"
                f"<td role='cell' data-label='Checklist'><span class='metric-chip'>{done}/{total}</span></td><td role='cell' data-label='Validation'>{validation_cell(task.validation_plan, task_href)}</td>"
                f"<td role='cell' data-label='Actions'>{self.task_actions(task, include_docs=True)}</td>"
                "</tr>"
            )
        filtered = bool(state_filter or repo_filter or completion_filter)
        count = f"<p class='task-count muted'>{len(rows)} of {len(all_tasks)} tasks{' · Filters active' if filtered else ''}</p>"
        if not rows:
            if all_tasks:
                message = f"No tasks match these filters.</p><p>{self.clear_filters_link(active_repo)}"
            else:
                scope = "central task stores" if self.all_repos else "this repository"
                message = (f"No task packages in {scope} yet.</p><p>"
                           "<a href='#dashboard-controls'>Create a New Plan</a> for the selected Active repo.")
            return count + f"<div class='empty-state'><p>{message}</p></div>"
        return (
            count + "<div class='table-wrap'><table class='dashboard-table' role='table' aria-label='Tasks'><colgroup>"
            "<col class='task-column'><col class='repo-column'><col class='stage-column'><col class='next-column'>"
            "<col class='completion-column'><col class='checklist-column'><col class='validation-column'><col class='actions-column'>"
            "</colgroup><thead role='rowgroup'><tr role='row'><th scope='col' role='columnheader'>Task</th><th scope='col' role='columnheader'>Repo</th><th scope='col' role='columnheader'>Stage</th><th scope='col' role='columnheader'>Next</th><th scope='col' role='columnheader'>Completion</th><th scope='col' role='columnheader'>Checklist</th><th scope='col' role='columnheader'>Validation</th><th scope='col' role='columnheader'>Actions</th></tr></thead>"
            f"<tbody role='rowgroup'>{''.join(rows)}</tbody></table></div>"
        )

    def flash_html(self, message: str, level: str = "notice") -> str:
        if not message:
            return ""
        class_name = "flash-error" if level == "error" else "flash"
        return (f"<p class='{class_name}' data-transient-message role='status'>{html.escape(message)}"
                "<button type='button' data-message-dismiss aria-label='Dismiss message'></button></p>")

    def task(self, name: str, doc: str, path_value: str = "", active_repo_value: str = "", message: str = "", level: str = "notice", selected_run: str = "") -> None:
        active_repo, _ = self.selected_repo({"active_repo": [active_repo_value]})
        task = self.resolve_task(name, path_value, active_repo)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        path_query = quote(str(task.path), safe="")
        selected_doc = doc_name(doc)
        refresh_url = f"/fragments/task/{quote(task.name)}?path={path_query}&doc={quote(selected_doc)}&active_repo={quote(str(task.repo), safe='')}&run={quote(selected_run, safe='')}"
        body = (
            f"{page_header(task.name, task.repo_name, task.repo)}<main class='shell'>"
            f"{self.flash_html(message, level)}"
            "<p data-action-feedback role='status' aria-live='polite' aria-atomic='true'></p>"
            f"{self.task_actions(task)}"
            f"<div id='task-detail' data-paw-refresh-url=\"{html_attr(refresh_url)}\" data-paw-refresh-interval-ms=\"2500\">"
            f"{self.task_detail(task, selected_doc, selected_run)}"
            "</div><div class='doc-preview' data-doc-preview></div></main>"
        )
        self.send_html(body)

    def task_fragment(self, name: str, doc: str, path_value: str = "", active_repo_value: str = "", selected_run: str = "") -> None:
        active_repo, _ = self.selected_repo({"active_repo": [active_repo_value]})
        task = self.resolve_task(name, path_value, active_repo)
        if not task:
            return self.send_fragment("<h1>Task not found</h1>", 404)
        self.send_fragment(self.task_detail(task, doc_name(doc), selected_run))

    def task_stream(self, name: str, path_value: str = "", active_repo_value: str = "") -> None:
        active_repo, _ = self.selected_repo({"active_repo": [active_repo_value]})
        task = self.resolve_task(name, path_value, active_repo)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        refresh_url = (
            f"/fragments/task-stream/{quote(task.name)}?path={quote(str(task.path), safe='')}"
            f"&active_repo={quote(str(task.repo), safe='')}"
        )
        body = (
            f"{page_header(f'{task.name} Logs', task.repo_name, task.repo)}<main class='shell'>"
            f"<p><a class='button' href='{html_attr(self.task_url(task))}'>Task</a></p>"
            f"<h2>Live Run Logs</h2>"
            f"<div data-paw-refresh-url=\"{html_attr(refresh_url)}\" data-paw-refresh-interval-ms=\"1500\">"
            f"{self.task_stream_html(task)}"
            "</div></main>"
        )
        self.send_html(body)

    def task_stream_fragment(self, name: str, path_value: str = "", active_repo_value: str = "") -> None:
        active_repo, _ = self.selected_repo({"active_repo": [active_repo_value]})
        task = self.resolve_task(name, path_value, active_repo)
        if not task:
            return self.send_fragment("<h1>Task not found</h1>", 404)
        self.send_fragment(self.task_stream_html(task))

    def task_stream_html(self, task: Task) -> str:
        run = task.active_run
        if not run or not run.cancellable:
            return "<p class='muted'>No active PAW run is available for streaming.</p>"
        logs = active_run_logs(run.metadata.parent.parent, run)
        if not logs or not logs.available:
            return "<p class='muted'>The active PAW run has no GUI stdout/stderr logs available yet.</p>"
        subcommand = metadata_value(run.metadata, "subcommand") or run.metadata.stem
        started = metadata_value(run.metadata, "start-time") or "unknown start time"
        return (
            f"<p class='muted'>Streaming {html.escape(subcommand)} started {html.escape(started)}. Refreshes locally while the task is active.</p>"
            f"<div class='log-stream' data-paw-key='{html_attr(str(run.metadata))}'>"
            f"{self.log_panel('stdout', logs.stdout)}"
            f"{self.log_panel('stderr', logs.stderr)}"
            "</div>"
        )

    def log_panel(self, label: str, path: Path | None) -> str:
        state, text = tail_text(path)
        title = f"{label} ({state})"
        log_path = path_disclosure(f"{label} log path", str(path)) if path else ""
        return (
            f"<section class='log-panel' data-paw-key='{html_attr(label + ':' + str(path))}'>"
            f"<h3>{html.escape(title)}</h3>"
            f"{log_path}"
            f"<pre><code>{html.escape(text)}</code></pre>"
            "</section>"
        )

    def resolve_archived_task(self, name: str, path_value: str, active_repo: Path) -> Task | None:
        if not valid_task_name(name):
            return None
        try:
            archived_path = physical(Path(path_value))
        except Exception:
            return None
        for task in list_archived_tasks(active_repo, self.task_home, self.all_repos):
            if task.name == name and task.path == archived_path:
                return task
        return None

    def post_unarchive(self, name: str) -> None:
        form = self.form_data()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", "")]})
        task = self.resolve_archived_task(name, form.get("path", ""), active_repo)
        if not task:
            return self.redirect(f"/archive?{self.flash_query('unarchive rejected: archived task path is not listed', 'error')}")
        archive_root = self.task_home / task.slug / ".archive"
        active_dest = self.task_home / task.slug / task.name
        try:
            task.path.relative_to(archive_root)
        except ValueError:
            return self.redirect(f"/archive?{self.flash_query('unarchive rejected: archive path is outside the central task store', 'error')}")
        if active_dest.exists():
            return self.redirect(f"/archive?{self.flash_query(f'unarchive blocked: active task already exists for {task.name}', 'error')}")
        shutil.move(str(task.path), str(active_dest))
        meta = active_dest / "metadata.gitconfig"
        if meta.exists():
            subprocess.run(["git", "config", "--file", str(meta), "--unset", "paw.archived-at"], check=False)
            subprocess.run(["git", "config", "--file", str(meta), "paw.unarchived-at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())], check=False)
        self.redirect(self.with_active_repo(task.repo, self.flash_query(f"unarchived task {task.name}", "notice")))

    def archived_task_list(self, active_repo: Path) -> str:
        rows = []
        for task in list_archived_tasks(active_repo, self.task_home, self.all_repos):
            branch = task.branch_context or "<none>"
            rows.append(
                "<tr>"
                f"<td><span class='task-title'>{html.escape(task.name)}</span>{path_disclosure('Task path', str(task.path))}</td>"
                f"<td><div class='repo-name'>{html.escape(task.repo_name)}</div><div class='task-subtle muted'>Branch: {html.escape(branch)}</div>{repo_disclosure(task, branch)}</td>"
                f"<td><span class='metric-chip'>{html.escape(status_field(task.plan, 'Estimated completion') or '<missing>')}</span></td>"
                f"<td>{self.unarchive_form(task)}</td>"
                "</tr>"
            )
        empty = "<tr><td colspan=4>No archived task packages found.</td></tr>"
        return (
            "<div class='table-wrap'><table><thead><tr><th>Task</th><th>Repo</th><th>Completion</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows) or empty}</tbody></table></div>"
        )

    def approval_panel(self, task: Task) -> str:
        if task_workflow(task).action != "approve-implementation":
            return "<p>Implementation approval unavailable: refresh and resolve the task’s current next step.</p>"
        plan_path = task.path / "plan.md"
        edit_extras = "Review and refine plan.md before implementation approval. Do not change implementation files."
        return (
            "<div class='approval-panel'>"
            f"<h3>Approve implementation for {html.escape(task.name)}</h3>"
            "<p class='muted'>Review the plan before starting implementation. You can revise it through paw edit or update the file manually.</p>"
            "<div class='action-row'>"
            f"<form class='inline-form' method='post' action='/task/{quote(task.name)}/edit'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            f"<input type='hidden' name='extras' value='{html_attr(edit_extras)}'>"
            "<button type='submit'>Edit Plan</button></form>"
            f"<form class='inline-form' method='post' action='/task/{quote(task.name)}/implement'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(task.repo))}'>"
            "<button type='submit'>Approve Implementation</button></form>"
            "<button type='button' data-modal-close>Close</button>"
            "</div>"
            "<details><summary>Manual plan path</summary>"
            f"<pre><code>{html.escape(str(plan_path))}</code></pre>"
            "</details>"
            "</div>"
        )

    def task_doc_fragment(self, name: str, doc: str, path_value: str = "", active_repo_value: str = "", approve: str = "") -> None:
        active_repo, _ = self.selected_repo({"active_repo": [active_repo_value]})
        task = self.resolve_task(name, path_value, active_repo)
        if not task:
            return self.send_fragment("<h1>Task not found</h1>", 404)
        selected_doc = doc_name(doc)
        content = self.task_doc_content(task, selected_doc)
        approval = self.approval_panel(task) if selected_doc == "plan" and approve == "implementation" else ""
        self.send_fragment(
            "<div class='modal-panel'><div class='modal-body'>"
            f"<h2>{html.escape(task.name)} / {html.escape(selected_doc)}.md</h2>"
            "<p><button type='button' data-modal-close>Close</button></p>"
            f"<div class='document'>{render_task_markdown(task, content)}</div>"
            f"{approval}"
            "</div></div>"
        )

    def task_doc_content(self, task: Task, doc: str) -> str:
        if linked_doc_name(doc):
            path = task.path / (doc + ".md")
            try:
                if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
                    raise ValueError("linked history unavailable: expected a task-local regular Markdown file <=1 MiB")
                return path.read_text(errors="replace")
            except (OSError, ValueError) as error:
                return f"Linked history unavailable: {error}"
        return {"contract": task.contract, "plan": task.plan, "review": task.review}.get(doc, task.plan)

    def task_detail(self, task: Task, doc: str, selected_run: str = "") -> str:
        selected_doc = doc_name(doc)
        content = self.task_doc_content(task, selected_doc)
        path_query = quote(str(task.path), safe="")
        doc_tabs = ["contract", "plan"]
        if task.review:
            doc_tabs.append("review")
        active_query = f"&active_repo={quote(str(task.repo), safe='')}"
        run_query = f"&run={quote(selected_run, safe='')}" if selected_run else ""
        history_url = f"/task/{quote(task.name)}?path={path_query}&doc={selected_doc}{active_query}"
        tabs = " ".join(
            f"<a href='/task/{quote(task.name)}?path={path_query}&doc={tab}{active_query}{run_query}'"
            f"{' aria-current=page' if tab == selected_doc else ''}>{tab}.md</a>" for tab in doc_tabs
        )
        done, total = checklist_counts(task.plan)
        crash_state = "available" if (task.path / "crash.log").exists() else "none"
        pr_tracking = tracking_summary(task.plan, "PR") or "none"
        issue_tracking = tracking_summary(task.plan, "Issue") or "none"
        prototype_status = task.prototype_status or "none"
        prototype_source = task.prototype_source or "none"
        prototype_cleanup_message = task.prototype_cleanup_message or "none"
        return (
            f"<p><span class='pill {task.state}'>{task.state}</span> <span class='pill'>{task.source}</span> <span class='pill'>{done}/{total} checklist</span></p>"
            f"{self.workflow_stage_cell(task, task_workflow(task))}"
            "<details class='task-metadata'><summary>Task metadata</summary>"
            "<div class='table-wrap'><table><tbody>"
            f"<tr><th>Task</th><td>{path_disclosure('Task path', str(task.path))}</td></tr>"
            f"<tr><th>Repo</th><td><strong>{html.escape(task.repo_name)}</strong>{path_disclosure('Repo path', str(task.repo))}</td></tr>"
            f"<tr><th>Repo Slug</th><td>{path_disclosure('Repo slug', task.slug)}</td></tr>"
            f"<tr><th>Worktree</th><td>{path_disclosure('Worktree path', metadata_value(task.path / 'metadata.gitconfig', 'worktree-path') or 'legacy metadata unavailable')}</td></tr>"
            f"<tr><th>PR</th><td>{html.escape(pr_tracking)}</td></tr>"
            f"<tr><th>Issue</th><td>{html.escape(issue_tracking)}</td></tr>"
            f"<tr><th>Prototype</th><td>{html.escape(prototype_status)}"
            f"{' from ' + html.escape(prototype_source) if prototype_source != 'none' else ''}</td></tr>"
            f"<tr><th>Prototype Cleanup</th><td>{html.escape(prototype_cleanup_message)}</td></tr>"
            f"<tr><th>Crash Log</th><td>{html.escape(crash_state)}</td></tr>"
            "</tbody></table></div></details>"
            f"{validation_details(task)}"
            f"<p class='tabs'>{tabs}</p><div id='validation-source' class='document'>{render_task_markdown(task, content)}</div>"
            f"{self.live_stream_section(task)}"
            f"{self.prototype_failure_logs(task)}"
            "<h2>Run History</h2><div class='table-wrap'><table><thead><tr><th>Subcommand</th><th>Status</th><th>Backend</th><th>Model</th><th>Started</th><th>Ended</th><th>Exit</th><th>Output</th></tr></thead>"
            f"<tbody>{run_rows(task.path, history_url)}</tbody></table></div>"
            f"{self.history_section(task, selected_run, history_url)}"
        )

    def history_section(self, task: Task, selector: str, history_url: str) -> str:
        if not selector:
            return ""
        logs, message = history_logs(task.path, selector)
        return (
            f"<section id='run-logs' data-paw-key='history:{html_attr(selector)}'>"
            "<h2>Saved Run Logs</h2>"
            f"<p>{html.escape(selector)} — {html.escape(message)}</p>"
            f"<p><a class='button' href='{html_attr(history_url)}'>Close logs</a></p>"
            f"<div class='log-stream'>{self.log_panel('stdout', logs.stdout)}"
            f"{self.log_panel('stderr', logs.stderr)}</div></section>"
        )

    def prototype_failure_logs(self, task: Task) -> str:
        owners = [task, *task.prototype_peers]
        for owner in owners:
            if not prototype_failure(owner):
                continue
            logs = sorted((owner.path / "runs").glob("*-gui-*-prototype-*.stdout.log"), key=file_mtime, reverse=True)
            if logs:
                stdout = task_local_run_file(owner.path, logs[0])
                stderr = task_local_run_file(owner.path, logs[0].with_name(logs[0].name.replace(".stdout.log", ".stderr.log")))
                return "<h2>Prototype planning logs</h2>" + self.log_panel("stdout", stdout) + self.log_panel("stderr", stderr)
        return ""

    def live_stream_section(self, task: Task) -> str:
        if not self.streamable(task):
            return ""
        refresh_url = (
            f"/fragments/task-stream/{quote(task.name)}?path={quote(str(task.path), safe='')}"
            f"&active_repo={quote(str(task.repo), safe='')}&run={quote(str(task.active_run.metadata), safe='')}"
        )
        return (
            "<h2>Live Run Logs</h2>"
            f"<p>{self.task_stream_link(task)}</p>"
            f"<div data-paw-refresh-url=\"{html_attr(refresh_url)}\" data-paw-refresh-interval-ms=\"1500\">"
            f"{self.task_stream_html(task)}"
            "</div>"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--task-home", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--all", action="store_true", help="show every central task store instead of only --repo")
    args = parser.parse_args()
    if args.host != "127.0.0.1" and args.host != "localhost":
        raise SystemExit("error: paw gui only supports localhost hosts")
    Handler.repo = physical(Path(args.repo))
    Handler.task_home = physical(Path(args.task_home))
    Handler.all_repos = args.all
    Handler.repo_registry = registry_path()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    host, port = server.server_address[:2]
    print(f"paw gui: http://{host}:{port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
