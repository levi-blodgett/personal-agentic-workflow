#!/usr/bin/env python3
"""Local-only PAW task dashboard server."""

from __future__ import annotations

import argparse
import html
import os
import re
import signal
import shutil
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from functools import cached_property
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlencode, urlparse


PAW_SCRIPT = Path(__file__).resolve().parents[1] / "paw"
TASK_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
LOG_TAIL_BYTES = 64 * 1024


QUEUE_LOCK = threading.RLock()


@contextmanager
def queue_lock():
    """Serialize queue reads and mutations within the threaded GUI server."""
    with QUEUE_LOCK:
        yield


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
    if not file.exists():
        return ""
    try:
        return subprocess.check_output(
            ["git", "config", "--file", str(file), "--get", f"paw.{key}"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return ""


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
            data = handle.read()
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


def validation_state(plan: str) -> str:
    body = section_body(plan, "Validation Performed")
    if not body:
        return "missing"
    lowered = body.lower()
    if "fail" in lowered or "error" in lowered:
        return "attention"
    if "passed" in lowered or "ok" in lowered:
        return "passed"
    return "recorded"


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
    return f"<span class='validation-chip {class_name}'>{html.escape(state)}</span>"


def review_grade(review: str) -> str:
    body = section_body(review, "Review Metadata")
    if not body:
        return ""
    for line in body.splitlines():
        match = re.match(r"^\s*[-*]\s+Grade:\s*(.*?)\s*$", line, re.IGNORECASE)
        if match:
            grade = match.group(1).strip()
            return "" if not grade or grade.lower() == "pending" else grade
    return ""


def review_grade_class(grade: str) -> str:
    match = re.match(r"^\s*([A-Fa-f])(?:\b|[-+]|/|$)", grade)
    if not match:
        return "grade-unknown"
    return f"grade-{match.group(1).lower()}"


def grade_rank(grade: str) -> int | None:
    match = re.match(r"^\s*([A-Fa-f])\s*([+-]?)", grade)
    if not match:
        return None
    base = {"A": 12, "B": 9, "C": 6, "D": 3, "F": 0}.get(match.group(1).upper())
    if base is None:
        return None
    suffix = match.group(2)
    if suffix == "+" and match.group(1).upper() != "A":
        base += 1
    elif suffix == "-":
        base -= 1
    return base


def prototype_disabled_reason(task: "Task") -> str:
    if not (task.path / "review.md").is_file():
        return "Run Review first: this task has no review.md."
    if task.review_is_stale:
        return "Run Review again: review.md predates the replacement plan."
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


def run_rows(task_path: Path) -> str:
    runs_dir = task_path / "runs"
    rows: list[str] = []
    if runs_dir.exists():
        for meta in sorted(runs_dir.glob("*.gitconfig"), reverse=True):
            rows.append(
                "<tr>"
                f"<td>{html.escape(metadata_value(meta, 'subcommand') or meta.stem)}</td>"
                f"<td>{html.escape(metadata_value(meta, 'status') or '<missing>')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'backend') or '')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'model') or '')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'start-time') or '')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'end-time') or '')}</td>"
                f"<td>{html.escape(metadata_value(meta, 'exit-status') or '')}</td>"
                "</tr>"
            )
    return "".join(rows) or "<tr><td colspan=7>No runs recorded.</td></tr>"


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
                           "prototype-replacement-name": args[1] + "-prototype" if args[0] == "prototype" else ""}.items():
            subprocess.run(["git", "config", "--file", str(metadata), f"paw.{key}", value], check=True)
        threading.Thread(target=finish_gui_run, args=(process, metadata), daemon=True).start()
    except Exception as exc:
        if stderr:
            stderr.write(f"Failed to start PAW: {exc}\n")
            stderr.flush()
        metadata = runs_dir / f"{stamp}-gui-{time.time_ns()}-failed.gitconfig"
        for key, value in {"status": "failed", "subcommand": args[0], "exit-status": "start-failed",
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
        if not self.prototype_status.startswith("planned") or not (self.path / "review.md").exists():
            return False
        planning_runs = [file_mtime(run) for run in (self.path / "runs").glob("*.gitconfig")
                         if metadata_value(run, "subcommand") == "prototype"
                         and metadata_value(run, "status") == "complete"]
        planned_at = max(planning_runs, default=file_mtime(self.path / "metadata.gitconfig"))
        return file_mtime(self.path / "review.md") <= planned_at

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
    def batch_eligible(self) -> bool:
        return bool(self.plan) and not self.blocked and not self.running and not self.finished

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
body{font:14px/1.45 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;color:#202124;background:#f7f8fa}
.shell{width:min(100% - 32px,1600px);margin-inline:auto}.site-header{background:#243447;color:white;padding:10px 0}.header-row{display:flex;align-items:center;gap:14px;flex-wrap:wrap}.site-header h1{font-size:20px;line-height:1.2;margin:0}.home-link{color:white;text-decoration:none;border:1px solid rgba(255,255,255,.35);border-radius:6px;padding:4px 8px}.home-link:hover{background:rgba(255,255,255,.12)}.header-context{color:#cbd5e1;font-size:13px;margin-left:auto}main.shell{padding-block:20px}
a{color:#0b57d0;text-decoration:none}button,.button{border:1px solid #b8c0cc;background:white;color:#1f2937;border-radius:6px;padding:5px 9px;font:inherit;cursor:pointer}.button{display:inline-block}button:hover,.button:hover{background:#f3f6fa}button:focus-visible,.button:focus-visible,.home-link:focus-visible{outline:3px solid #93c5fd;outline-offset:2px}.danger{border-color:#dc2626;color:#991b1b}.primary{border-color:#0b57d0;color:#0b57d0;background:#eff6ff}
table{border-collapse:collapse;width:100%;background:white;border:1px solid #dfe3ea}.table-wrap{overflow-x:auto;margin:12px 0 20px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #e8ebf0;vertical-align:top}th{background:#edf1f7;font-size:12px;text-transform:uppercase;color:#4b5563}
.pill{display:inline-block;border:1px solid #ccd3dd;border-radius:999px;padding:2px 8px;background:#f8fafc;font-size:12px}.blocked{border-color:#d97706;color:#92400e}.running{border-color:#2563eb;color:#1d4ed8}.ready{border-color:#15803d;color:#166534}.complete{border-color:#6d28d9;color:#5b21b6}
.review-grade{display:inline-block;border:1px solid #ccd3dd;border-radius:999px;background:#f8fafc;padding:2px 8px;font-size:12px;font-weight:600}.grade-a{border-color:#15803d;color:#166534;background:#f0fdf4}.grade-b{border-color:#0b57d0;color:#1d4ed8;background:#eff6ff}.grade-c{border-color:#d97706;color:#92400e;background:#fffbeb}.grade-d{border-color:#ea580c;color:#9a3412;background:#fff7ed}.grade-f{border-color:#dc2626;color:#991b1b;background:#fef2f2}.grade-unknown{border-color:#6b7280;color:#374151;background:#f9fafb}
.toolbar{display:flex;align-items:end;justify-content:space-between;gap:10px;flex-wrap:wrap;margin:14px 0}.toolbar-fields,.top-actions,.dashboard-actions{display:flex;align-items:end;gap:8px;flex-wrap:wrap}.dashboard-actions{margin:14px 0}.toolbar label,.selected-actions label{display:grid;gap:3px;font-size:12px;color:#475467}.selected-actions .checkbox-label{display:flex;align-items:center;gap:5px;padding-bottom:6px}.toolbar select,.toolbar input,.selected-actions select{font:inherit;border:1px solid #cbd5e1;border-radius:6px;padding:5px 8px;background:white}.filter-disclosure{margin:14px 0}.filter-disclosure>summary{cursor:pointer;color:#3b495c}.filter-disclosure .toolbar{margin:8px 0 0}.flash,.flash-error{border:1px solid #bfdbfe;border-radius:6px;background:#eff6ff;color:#1e3a8a;padding:8px 10px}.flash-error{border-color:#fecaca;background:#fef2f2;color:#991b1b}.metric-chip,.validation-chip{display:inline-flex;align-items:center;justify-content:center;min-width:3.2em;border-radius:999px;border:1px solid #ccd3dd;background:#f8fafc;padding:2px 8px;font-size:12px}.validation-passed{border-color:#16a34a;color:#166534}.validation-attention{border-color:#d97706;color:#92400e}.validation-missing{border-color:#b8c0cc;color:#667085}.validation-recorded{border-color:#0b57d0;color:#1d4ed8}
.task-title{font-weight:600}.task-subtle{margin-top:4px}.repo-name{font-weight:600}.path-disclosure{margin-top:5px;font-size:12px;color:#667085}.path-disclosure summary{cursor:pointer;color:#3b495c}.path-disclosure code{display:block;margin-top:5px;white-space:nowrap;overflow:auto;max-width:42rem}.path-disclosure dl{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 10px;margin:6px 0 0}.path-disclosure dt{font-weight:600;color:#475467}.path-disclosure dd{margin:0;min-width:0}
.tabs a{margin-right:14px}.muted{color:#667085}.document{background:white;border:1px solid #dfe3ea;border-radius:8px;padding:20px;margin:14px 0 24px;overflow:auto}.document h1,.document h2,.document h3{margin:18px 0 10px}.document h1:first-child,.document h2:first-child{margin-top:0}.document pre{background:#f6f8fa;border:1px solid #dfe3ea;padding:12px;overflow:auto}.document code{background:#eef2f7;padding:1px 4px}.document pre code{background:transparent;padding:0}.document blockquote{border-left:4px solid #d0d7de;color:#57606a;margin:12px 0;padding:1px 14px}.document ul,.document ol{padding-left:24px}.document li{margin:3px 0}.document input[type=checkbox]{margin-right:6px}.document table{border:1px solid #dfe3ea}.document tr:nth-child(even),.table-wrap tbody tr:nth-child(even){background:#fbfcfe}
.log-stream{display:grid;gap:14px;margin:14px 0 24px}.log-panel{background:white;border:1px solid #dfe3ea;border-radius:8px;overflow:hidden}.log-panel h3{font-size:13px;text-transform:uppercase;color:#4b5563;background:#edf1f7;margin:0;padding:8px 12px}.log-panel pre{margin:0;max-height:45vh;overflow:auto;padding:12px;background:#0f172a;color:#e5e7eb;white-space:pre-wrap}
.action-row{display:flex;gap:6px;align-items:center;flex-wrap:wrap}.workflow-cell{min-width:150px}.workflow-label{font-weight:600}.workflow-note{margin-top:4px}.workflow-actions{margin-top:8px}.disabled-action{display:inline-block;border:1px solid #ccd3dd;border-radius:6px;padding:5px 9px;background:#f8fafc;color:#667085}.modal-toggle{display:inline-block}.modal-toggle>summary{list-style:none}.modal-toggle>summary::-webkit-details-marker{display:none}.modal-panel{position:fixed;inset:0;background:rgba(15,23,42,.38);z-index:20;display:flex;align-items:center;justify-content:center;padding:20px}.modal-body{background:white;color:#202124;border:1px solid #cfd7e3;border-radius:8px;box-shadow:0 18px 55px rgba(15,23,42,.28);max-width:720px;width:min(720px,100%);max-height:84vh;overflow:auto;padding:18px}.modal-body textarea{width:100%;box-sizing:border-box}.queued-prompt{white-space:pre-wrap;overflow-wrap:anywhere;min-width:18ch;max-width:60ch;margin:0}.inline-form{display:inline}.doc-preview{margin-top:18px}.doc-preview:empty{display:none}
@media (max-width:640px){.shell{width:min(100% - 20px,1600px)}.header-context{margin-left:0;flex-basis:100%}}
"""

SCRIPT = """
<script>
document.addEventListener("DOMContentLoaded", () => {
  const preview = document.querySelector("[data-doc-preview]");
  if (preview) {
    document.addEventListener("click", async (event) => {
      const trigger = event.target.closest("[data-doc-preview-url]");
      if (!trigger) return;
      event.preventDefault();
      try {
        const response = await fetch(trigger.dataset.docPreviewUrl, {cache: "no-store"});
        if (!response.ok) return;
        preview.innerHTML = await response.text();
      } catch (_error) {
        preview.innerHTML = "<p class='flash-error'>preview failed</p>";
      }
    });
  }
  document.querySelectorAll("[data-paw-refresh-url]").forEach((target) => {
    const interval = Number(target.dataset.pawRefreshIntervalMs || "2500");
    const refreshUrl = target.dataset.pawRefreshUrl;
    const refresh = async () => {
      if (target.matches(":focus-within") || target.querySelector("details.modal-toggle[open]")) return;
      try {
        const response = await fetch(refreshUrl, {cache: "no-store"});
        if (!response.ok) return;
        const content = await response.text();
        if (target.matches(":focus-within") || target.querySelector("details.modal-toggle[open]")) return;
        target.innerHTML = content;
      } catch (_error) {
        // Keep the last good view when the local server is stopping or busy.
      }
    };
    window.setInterval(refresh, interval);
  });
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
        "</div></header>"
    )


def stable_id(*parts: str) -> str:
    return "paw-" + cksum("|".join(parts))


def doc_name(value: str) -> str:
    return value if value in {"contract", "plan", "pr", "review"} else "plan"


class Handler(BaseHTTPRequestHandler):
    repo: Path
    task_home: Path
    all_repos: bool
    repo_registry: Path

    def send_html(self, body: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(f"<!doctype html><title>PAW</title><style>{STYLE}</style>{body}{SCRIPT}".encode())

    def send_fragment(self, body: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body.encode())

    def redirect(self, location: str) -> None:
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def form_data(self) -> dict[str, str]:
        values = self.form_values()
        return {key: value[0] if value else "" for key, value in values.items()}

    def form_values(self) -> dict[str, list[str]]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        return parse_qs(raw, keep_blank_values=True)

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

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            return self.index()
        if parsed.path == "/archive":
            return self.archive_index()
        if parsed.path == "/fragments/tasks":
            return self.tasks_fragment(parse_qs(parsed.query))
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
            )
        self.send_html("<h1>Not found</h1>", 404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/actions/plan":
            return self.post_plan()
        if parsed.path == "/actions/repos/add":
            return self.post_add_repo()
        if parsed.path == "/actions/selected":
            return self.post_selected_action()
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

    def selected_tasks(self, active_repo: Path, selected_paths: list[str]) -> tuple[list[Task], list[str]]:
        if not selected_paths:
            return [], ["select at least one task"]
        tasks_by_path = {str(task.path): task for task in list_tasks(active_repo, self.task_home, self.all_repos)}
        selected: list[Task] = []
        errors: list[str] = []
        seen: set[str] = set()
        for path_value in selected_paths:
            if path_value in seen:
                errors.append(f"{path_value} selected more than once")
                continue
            seen.add(path_value)
            task = tasks_by_path.get(path_value)
            if not task:
                errors.append(f"{path_value} is not a current task")
                continue
            if str(task.path) != path_value:
                errors.append(f"{task.name} path did not match listed task")
            elif task.running:
                errors.append(f"{task.name} is already running")
            elif task.blocked:
                errors.append(f"{task.name} has USER ANSWER placeholders")
            else:
                selected.append(task)
        return selected, errors

    def post_selected_action(self) -> None:
        form = self.form_values()
        active_repo, _ = self.selected_repo({"active_repo": [form.get("active_repo", [""])[0]]})
        action = form.get("selected_action", [""])[0]
        selected_paths = [value for value in form.get("task", []) if value]
        if action not in {"archive", "delete"}:
            return self.redirect(self.with_active_repo(active_repo, self.flash_query("selected action is required", "error")))
        selected, errors = self.selected_tasks(active_repo, selected_paths)
        if action == "archive":
            errors.extend(f"{task.name} is not a central task" for task in selected if task.source != "central")
            errors.extend(
                f"archive already exists for {task.name}"
                for task in selected
                if (self.task_home / task.slug / ".archive" / task.name).exists()
            )
        if action == "delete" and form.get("confirm", [""])[0] != "yes":
            errors.append("delete confirmation is required")
        if errors:
            return self.redirect(self.with_active_repo(active_repo, self.flash_query("selected action blocked: " + "; ".join(errors), "error")))

        if action == "delete":
            for task in selected:
                shutil.rmtree(task.path)
            return self.redirect(self.with_active_repo(active_repo, self.flash_query(f"deleted {len(selected)} selected task(s)", "notice")))

        for task in selected:
            archive_root = self.task_home / task.slug / ".archive"
            archive_root.mkdir(parents=True, exist_ok=True)
            destination = archive_root / task.name
            shutil.move(str(task.path), str(destination))
            meta = destination / "metadata.gitconfig"
            if meta.exists():
                subprocess.run(["git", "config", "--file", str(meta), "paw.archived-at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())], check=False)
        self.redirect(self.with_active_repo(active_repo, self.flash_query(f"archived {len(selected)} selected task(s)", "notice")))

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
        body = (
            f"{page_header('PAW Tasks', scope, active_repo)}<main class='shell'>"
            f"{self.flash_html(message, level)}"
            f"{self.index_filters(query, active_repo)}"
            f"{self.dashboard_actions(active_repo)}"
            f"<div id='task-list' data-paw-refresh-url=\"{html_attr(refresh_url)}\" data-paw-refresh-interval-ms=\"2500\">"
            f"{self.index_task_list(query, active_repo)}"
            "</div><div class='doc-preview' data-doc-preview></div></main>"
        )
        self.send_html(body)

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

    def tasks_fragment(self, query: dict[str, list[str]]) -> None:
        active_repo, error = self.selected_repo(query)
        if error:
            active_repo = self.repo
        self.send_fragment(self.index_task_list(query, active_repo))

    def repo_selector(self, active_repo: Path) -> str:
        options = "".join(option_tag(str(repo), str(repo), str(active_repo)) for repo in self.current_repos())
        return (
            "<form class='toolbar repo-toolbar' method='get'>"
            "<div class='toolbar-fields'>"
            f"<label>Active repo <select name=\"active_repo\">{options}</select></label>"
            "</div><div class='top-actions'>"
            "<button type='submit'>Switch</button>"
            "</div></form>"
            "<form class='toolbar repo-toolbar' method='post' action='/actions/repos/add'>"
            "<div class='toolbar-fields'>"
            "<label>Add repo path <input name='repo_path' required></label>"
            "</div><div class='top-actions'>"
            "<button type='submit'>Add repo</button>"
            "</div></form>"
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
            f"<details class='filter-disclosure'{open_attr}><summary>Filter tasks</summary>"
            "<form class='toolbar' method='get'>"
            "<div class='toolbar-fields'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(active_repo))}'>"
            f"<label>State <select name=\"state\">{state_select}</select></label>"
            f"<label>Repo filter <input name=\"repo\" value=\"{html_attr(repo_filter)}\"></label>"
            f"<label>Completion <select name=\"completion\">{completion_select}</select></label>"
            "</div><div class='top-actions'>"
            "<button type='submit'>Filter</button><a class='button' href='/'>Clear</a>"
            "</div></form></details>"
        )

    def new_plan_modal(self, active_repo: Path) -> str:
        queued = self.queued_plan_list(active_repo)
        return (
            "<details class='modal-toggle'><summary><span class='button primary'>Plan</span></summary>"
            "<div class='modal-panel'><div class='modal-body'>"
            "<form method='post' action='/actions/plan'>"
            "<h2>Plan</h2>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(active_repo))}'>"
            "<p><label>Task name <input name='task_name' required pattern='[A-Za-z0-9._-]+'></label></p>"
            "<p><label>Prompt<br><textarea name='prompt' required rows='4'></textarea></label></p>"
            "<p class='action-row'><button type='submit' name='plan_action' value='plan'>Plan</button>"
            "<button type='submit' name='plan_action' value='queue' title='Save this prompt locally so planning can be started later'>Queue</button>"
            "<button type='button' onclick='this.closest(\"details\").removeAttribute(\"open\")'>Close</button></p>"
            f"</form>{queued}</div></div></details>"
        )

    def dashboard_actions(self, active_repo: Path) -> str:
        return (
            "<div class='dashboard-actions'>"
            f"{self.new_plan_modal(active_repo)}"
            "<form id='selected-action-form' class='selected-actions' method='post' action='/actions/selected'>"
            f"<input type='hidden' name='active_repo' value='{html_attr(str(active_repo))}'>"
            "<label>Selected action <select name='selected_action' required>"
            "<option value=''>Choose action</option><option value='archive'>Archive selected</option><option value='delete'>Delete selected</option>"
            "</select></label>"
            "<label class='checkbox-label'><input type='checkbox' name='confirm' value='yes'> Confirm delete</label>"
            "<button type='submit'>Apply</button></form>"
            "</div>"
        )

    def queued_plan_list(self, active_repo: Path) -> str:
        items = list_queued_plans(self.task_home, active_repo)
        if not items:
            return ""
        rows = []
        for item in items:
            rows.append(
                "<tr>"
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
            "<h3>Queued Plans</h3><div class='table-wrap'><table><thead><tr><th>Task</th><th>Prompt</th><th>Actions</th></tr></thead>"
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
            replacements = [peer for peer in list_repo_tasks(task.repo, self.task_home)
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
            f"<p class='action-row'><button type='submit'>{html.escape(label)}</button><button type='button' onclick='this.closest(\"details\").removeAttribute(\"open\")'>Close</button></p>"
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
            "<button type='submit'>Archive</button></form>"
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
            "<p class='action-row'><button class='danger' type='submit'>Delete</button><button type='button' onclick='this.closest(\"details\").removeAttribute(\"open\")'>Cancel</button></p>"
            "</form></div></div></details>"
        )

    def task_actions(self, task: Task, include_docs: bool = False) -> str:
        active_query = f"&active_repo={quote(str(task.repo), safe='')}"
        pieces = [self.archive_form(task)]
        if view_pr_branch(task):
            pieces.append(self.view_pr_form(task))
        if self.streamable(task):
            pieces.append(self.task_stream_link(task))
        if include_docs:
            for doc in ("plan",):
                preview_url = f"/fragments/task-doc/{quote(task.name)}?path={quote(str(task.path), safe='')}&doc={doc}{active_query}"
                pieces.append(f"<button type='button' data-doc-preview-url='{html_attr(preview_url)}'>{doc}.md</button>")
        edit_label = "Answer Questions" if task.blocked else "Edit"
        pieces.append(self.extras_modal(task, "edit", edit_label))
        if task_workflow(task).action == "approve-implementation":
            pieces.append(self.approve_implementation_button(task))
        pieces.append(self.delete_modal(task))
        if not include_docs:
            prototype_reason = prototype_disabled_reason(task)
            prototype_control = (
                f"<span class='disabled-action' title='{html_attr(prototype_reason)}'>Use as Prototype</span>"
                if prototype_reason
                else self.extras_modal(task, "prototype", "Use as Prototype")
            )
            pieces.extend([self.extras_modal(task, "review", "Review"), prototype_control, self.archive_form(task)])
        return f"<div class='action-row'>{''.join(pieces)}</div>"

    def workflow_action_control(self, task: Task, workflow: TaskWorkflow) -> str:
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
            selector = (
                f"<input form='selected-action-form' type='checkbox' name='task' value='{html_attr(str(task.path))}' aria-label='Select {html_attr(task.name)}'>"
                if task.batch_eligible
                else ""
            )
            workflow = task_workflow(task)
            rows.append(
                "<tr>"
                f"<td>{selector}</td>"
                f"<td><a class='task-title' href='{task_href}'>{html.escape(task.name)}</a>{path_disclosure('Task path', str(task.path))}</td>"
                f"<td><div class='repo-name'>{html.escape(task.repo_name)}</div><div class='task-subtle muted'>Branch: {html.escape(branch)}</div>{repo_disclosure(task, branch)}</td>"
                f"<td>{self.workflow_stage_cell(task, workflow)}</td>"
                f"<td>{self.workflow_next_cell(task, workflow)}</td>"
                f"<td><span class='metric-chip'>{html.escape(completion)}</span></td>"
                f"<td><span class='metric-chip'>{done}/{total}</span></td><td>{validation_chip(validation_state(task.plan))}</td>"
                f"<td>{self.task_actions(task, include_docs=True)}</td>"
                "</tr>"
            )
        return (
            "<div class='table-wrap'><table><thead><tr><th>Select</th><th>Task</th><th>Repo</th><th>Stage</th><th>Next</th><th>Completion</th><th>Checklist</th><th>Validation</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows) or '<tr><td colspan=9>No task packages found.</td></tr>'}</tbody></table></div>"
        )

    def flash_html(self, message: str, level: str = "notice") -> str:
        if not message:
            return ""
        class_name = "flash-error" if level == "error" else "flash"
        return f"<p class='{class_name}'>{html.escape(message)}</p>"

    def task(self, name: str, doc: str, path_value: str = "", active_repo_value: str = "", message: str = "", level: str = "notice") -> None:
        active_repo, _ = self.selected_repo({"active_repo": [active_repo_value]})
        task = self.resolve_task(name, path_value, active_repo)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        path_query = quote(str(task.path), safe="")
        selected_doc = doc_name(doc)
        refresh_url = f"/fragments/task/{quote(task.name)}?path={path_query}&doc={quote(selected_doc)}&active_repo={quote(str(task.repo), safe='')}"
        body = (
            f"{page_header(task.name, task.repo_name, task.repo)}<main class='shell'>"
            f"{self.flash_html(message, level)}"
            f"{self.task_actions(task)}"
            f"<div id='task-detail' data-paw-refresh-url=\"{html_attr(refresh_url)}\" data-paw-refresh-interval-ms=\"2500\">"
            f"{self.task_detail(task, selected_doc)}"
            "</div></main>"
        )
        self.send_html(body)

    def task_fragment(self, name: str, doc: str, path_value: str = "", active_repo_value: str = "") -> None:
        active_repo, _ = self.selected_repo({"active_repo": [active_repo_value]})
        task = self.resolve_task(name, path_value, active_repo)
        if not task:
            return self.send_fragment("<h1>Task not found</h1>", 404)
        self.send_fragment(self.task_detail(task, doc_name(doc)))

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
            "<div class='log-stream'>"
            f"{self.log_panel('stdout', logs.stdout)}"
            f"{self.log_panel('stderr', logs.stderr)}"
            "</div>"
        )

    def log_panel(self, label: str, path: Path | None) -> str:
        state, text = tail_text(path)
        title = f"{label} ({state})"
        log_path = path_disclosure(f"{label} log path", str(path)) if path else ""
        return (
            "<section class='log-panel'>"
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
            "<button type='button' onclick='this.closest(\"[data-doc-preview]\").innerHTML=\"\"'>Close</button>"
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
            "<p><button type='button' onclick='this.closest(\"[data-doc-preview]\").innerHTML=\"\"'>Close</button></p>"
            f"<div class='document'>{render_markdown(content)}</div>"
            f"{approval}"
            "</div></div>"
        )

    def task_doc_content(self, task: Task, doc: str) -> str:
        return {"contract": task.contract, "plan": task.plan, "review": task.review}.get(doc, task.plan)

    def task_detail(self, task: Task, doc: str) -> str:
        selected_doc = doc_name(doc)
        content = self.task_doc_content(task, selected_doc)
        path_query = quote(str(task.path), safe="")
        doc_tabs = ["contract", "plan"]
        if task.review:
            doc_tabs.append("review")
        active_query = f"&active_repo={quote(str(task.repo), safe='')}"
        tabs = " ".join(f"<a href='/task/{quote(task.name)}?path={path_query}&doc={tab}{active_query}'>{tab}.md</a>" for tab in doc_tabs)
        done, total = checklist_counts(task.plan)
        crash_state = "available" if (task.path / "crash.log").exists() else "none"
        pr_tracking = tracking_summary(task.plan, "PR") or "none"
        issue_tracking = tracking_summary(task.plan, "Issue") or "none"
        prototype_status = task.prototype_status or "none"
        prototype_source = task.prototype_source or "none"
        prototype_cleanup_message = task.prototype_cleanup_message or "none"
        return (
            f"<p><span class='pill {task.state}'>{task.state}</span> <span class='pill'>{task.source}</span> <span class='pill'>{done}/{total} checklist</span></p>"
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
            "</tbody></table></div>"
            f"<p class='tabs'>{tabs}</p><div class='document'>{render_markdown(content)}</div>"
            f"{self.live_stream_section(task)}"
            f"{self.prototype_failure_logs(task)}"
            "<h2>Run History</h2><div class='table-wrap'><table><thead><tr><th>Subcommand</th><th>Status</th><th>Backend</th><th>Model</th><th>Started</th><th>Ended</th><th>Exit</th></tr></thead>"
            f"<tbody>{run_rows(task.path)}</tbody></table></div>"
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
            f"&active_repo={quote(str(task.repo), safe='')}"
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
