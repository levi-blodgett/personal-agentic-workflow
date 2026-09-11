#!/usr/bin/env python3
"""Local-only PAW task dashboard server."""

from __future__ import annotations

import argparse
import html
import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlencode, urlparse


PAW_SCRIPT = Path(__file__).resolve().parents[1] / "paw"
TASK_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def git_value(repo: Path, *args: str) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


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

    fallback_files = [task_path / name for name in ("plan.md", "contract.md", "pr.md", "metadata.gitconfig", "crash.log")]
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
    stdout_log = runs_dir / f"{stamp}-gui-{os.getpid()}-{slug}.stdout.log"
    stderr_log = runs_dir / f"{stamp}-gui-{os.getpid()}-{slug}.stderr.log"
    env = os.environ.copy()
    env["PAW_TASK_HOME"] = str(task_home)
    stdout = None
    stderr = None
    try:
        stdout = stdout_log.open("w")
        stderr = stderr_log.open("w")
        subprocess.Popen(
            [str(PAW_SCRIPT), *args],
            cwd=str(repo),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
    except Exception as exc:
        return False, f"failed to start paw {' '.join(args)}: {exc}"
    finally:
        if stdout:
            stdout.close()
        if stderr:
            stderr.close()
    return True, f"started paw {' '.join(args)}; logs: {stdout_log}, {stderr_log}"


class Task:
    def __init__(self, name: str, source: str, path: Path, repo: Path, slug: str = ""):
        self.name = name
        self.source = source
        self.path = path
        self.repo = repo
        self.slug = slug or repo_slug(repo)
        self.plan = (path / "plan.md").read_text(errors="replace") if (path / "plan.md").exists() else ""
        self.contract = (path / "contract.md").read_text(errors="replace") if (path / "contract.md").exists() else ""
        self.pr = (path / "pr.md").read_text(errors="replace") if (path / "pr.md").exists() else ""
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
    def prototype_status(self) -> str:
        return metadata_value(self.path / "metadata.gitconfig", "prototype-status")

    @property
    def prototype_source(self) -> str:
        return metadata_value(self.path / "metadata.gitconfig", "prototype-source")

    @property
    def blocked(self) -> bool:
        return bool(re.search(r"USER ANSWER \((UNRESOLVED|PROVIDED)\):", self.plan))

    @property
    def running(self) -> bool:
        for meta in (self.path / "runs").glob("*.gitconfig") if (self.path / "runs").exists() else []:
            if running_metadata_is_active(meta):
                return True
        return False

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


def task_workflow(task: Task) -> TaskWorkflow:
    plan_position = status_field(task.plan, "Plan position") or "<missing>"
    next_work = status_field(task.plan, "Next work") or "<missing>"
    if task.running:
        return TaskWorkflow("Running", "Wait for run", "", "A PAW subprocess is active.", f"{task.name} already has a running PAW subprocess")
    if not task.plan:
        return TaskWorkflow("Missing plan", "Edit", "edit", "plan.md is missing.", "plan.md missing")
    if task.blocked:
        return TaskWorkflow("Needs edit", "Edit", "edit", plan_position, "USER ANSWER placeholders remain")
    if task.prototype_status or task.prototype_source:
        return TaskWorkflow("Prototype", "Archive", "archive", next_work)
    if task.review:
        return TaskWorkflow("Reviewed", "Prototype", "prototype", next_work)
    if task.finished:
        return TaskWorkflow("Review", "Review", "review", next_work)
    return TaskWorkflow("Implement", "Implement", "implement", next_work)


def list_repo_tasks(repo: Path, task_home: Path) -> list[Task]:
    tasks: dict[str, Task] = {}
    central_root = task_home / repo_slug(repo)
    if central_root.exists():
        for path in sorted(p for p in central_root.iterdir() if p.is_dir()):
            if path.name == ".archive":
                continue
            metadata_repo = metadata_value(path / "metadata.gitconfig", "repo-root")
            if metadata_repo and physical(Path(metadata_repo)) != repo:
                continue
            tasks[path.name] = Task(path.name, "central", path, repo, central_root.name)
    legacy_root = repo / ".agent"
    if legacy_root.exists():
        for path in sorted(p for p in legacy_root.iterdir() if p.is_dir()):
            tasks.setdefault(path.name, Task(path.name, "legacy", path, repo))
    return list(tasks.values())


def list_all_central_tasks(task_home: Path) -> list[Task]:
    tasks: list[Task] = []
    if not task_home.exists():
        return tasks
    for repo_dir in sorted(p for p in task_home.iterdir() if p.is_dir()):
        for path in sorted(p for p in repo_dir.iterdir() if p.is_dir()):
            if path.name == ".archive":
                continue
            metadata_repo = metadata_value(path / "metadata.gitconfig", "repo-root")
            repo = physical(Path(metadata_repo)) if metadata_repo else Path(repo_dir.name)
            tasks.append(Task(path.name, "central", path, repo, repo_dir.name))
    return tasks


def list_tasks(repo: Path, task_home: Path, all_repos: bool) -> list[Task]:
    if all_repos:
        return sort_tasks_by_recent_activity(list_all_central_tasks(task_home))
    return sort_tasks_by_recent_activity(list_repo_tasks(repo, task_home))


STYLE = """
body{font:14px/1.45 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;color:#202124;background:#f7f8fa}
.shell{width:min(100% - 32px,1600px);margin-inline:auto}.site-header{background:#243447;color:white;padding:10px 0}.header-row{display:flex;align-items:center;gap:14px;flex-wrap:wrap}.site-header h1{font-size:20px;line-height:1.2;margin:0}.home-link{color:white;text-decoration:none;border:1px solid rgba(255,255,255,.35);border-radius:6px;padding:4px 8px}.home-link:hover{background:rgba(255,255,255,.12)}.header-context{color:#cbd5e1;font-size:13px;margin-left:auto}main.shell{padding-block:20px}
a{color:#0b57d0;text-decoration:none}button,.button{border:1px solid #b8c0cc;background:white;color:#1f2937;border-radius:6px;padding:5px 9px;font:inherit;cursor:pointer}.button{display:inline-block}button:hover,.button:hover{background:#f3f6fa}button:focus-visible,.button:focus-visible,.home-link:focus-visible{outline:3px solid #93c5fd;outline-offset:2px}.danger{border-color:#dc2626;color:#991b1b}.primary{border-color:#0b57d0;color:#0b57d0;background:#eff6ff}
table{border-collapse:collapse;width:100%;background:white;border:1px solid #dfe3ea}.table-wrap{overflow-x:auto;margin:12px 0 20px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #e8ebf0;vertical-align:top}th{background:#edf1f7;font-size:12px;text-transform:uppercase;color:#4b5563}
.pill{display:inline-block;border:1px solid #ccd3dd;border-radius:999px;padding:2px 8px;background:#f8fafc;font-size:12px}.blocked{border-color:#d97706;color:#92400e}.running{border-color:#2563eb;color:#1d4ed8}.ready{border-color:#15803d;color:#166534}.complete{border-color:#6d28d9;color:#5b21b6}
.review-grade{display:inline-block;border:1px solid #ccd3dd;border-radius:999px;background:#f8fafc;padding:2px 8px;font-size:12px;font-weight:600}.grade-a{border-color:#15803d;color:#166534;background:#f0fdf4}.grade-b{border-color:#0b57d0;color:#1d4ed8;background:#eff6ff}.grade-c{border-color:#d97706;color:#92400e;background:#fffbeb}.grade-d{border-color:#ea580c;color:#9a3412;background:#fff7ed}.grade-f{border-color:#dc2626;color:#991b1b;background:#fef2f2}.grade-unknown{border-color:#6b7280;color:#374151;background:#f9fafb}
.toolbar{display:flex;align-items:end;justify-content:space-between;gap:10px;flex-wrap:wrap;margin:14px 0}.toolbar-fields,.top-actions{display:flex;align-items:end;gap:8px;flex-wrap:wrap}.toolbar label{display:grid;gap:3px;font-size:12px;color:#475467}.toolbar select,.toolbar input{font:inherit;border:1px solid #cbd5e1;border-radius:6px;padding:5px 8px;background:white}.flash,.flash-error{border:1px solid #bfdbfe;border-radius:6px;background:#eff6ff;color:#1e3a8a;padding:8px 10px}.flash-error{border-color:#fecaca;background:#fef2f2;color:#991b1b}.metric-chip,.validation-chip{display:inline-flex;align-items:center;justify-content:center;min-width:3.2em;border-radius:999px;border:1px solid #ccd3dd;background:#f8fafc;padding:2px 8px;font-size:12px}.validation-passed{border-color:#16a34a;color:#166534}.validation-attention{border-color:#d97706;color:#92400e}.validation-missing{border-color:#b8c0cc;color:#667085}.validation-recorded{border-color:#0b57d0;color:#1d4ed8}
.task-title{font-weight:600}.task-subtle{margin-top:4px}.repo-name{font-weight:600}.path-disclosure{margin-top:5px;font-size:12px;color:#667085}.path-disclosure summary{cursor:pointer;color:#3b495c}.path-disclosure code{display:block;margin-top:5px;white-space:nowrap;overflow:auto;max-width:42rem}.path-disclosure dl{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 10px;margin:6px 0 0}.path-disclosure dt{font-weight:600;color:#475467}.path-disclosure dd{margin:0;min-width:0}
.tabs a{margin-right:14px}.muted{color:#667085}.document{background:white;border:1px solid #dfe3ea;border-radius:8px;padding:20px;margin:14px 0 24px;overflow:auto}.document h1,.document h2,.document h3{margin:18px 0 10px}.document h1:first-child,.document h2:first-child{margin-top:0}.document pre{background:#f6f8fa;border:1px solid #dfe3ea;padding:12px;overflow:auto}.document code{background:#eef2f7;padding:1px 4px}.document pre code{background:transparent;padding:0}.document blockquote{border-left:4px solid #d0d7de;color:#57606a;margin:12px 0;padding:1px 14px}.document ul,.document ol{padding-left:24px}.document li{margin:3px 0}.document input[type=checkbox]{margin-right:6px}.document table{border:1px solid #dfe3ea}.document tr:nth-child(even),.table-wrap tbody tr:nth-child(even){background:#fbfcfe}
.action-row{display:flex;gap:6px;align-items:center;flex-wrap:wrap}.workflow-cell{min-width:150px}.workflow-label{font-weight:600}.workflow-note{margin-top:4px}.workflow-actions{margin-top:8px}.disabled-action{display:inline-block;border:1px solid #ccd3dd;border-radius:6px;padding:5px 9px;background:#f8fafc;color:#667085}.modal-toggle{display:inline-block}.modal-toggle>summary{list-style:none}.modal-toggle>summary::-webkit-details-marker{display:none}.modal-panel{position:fixed;inset:0;background:rgba(15,23,42,.38);z-index:20;display:flex;align-items:center;justify-content:center;padding:20px}.modal-body{background:white;color:#202124;border:1px solid #cfd7e3;border-radius:8px;box-shadow:0 18px 55px rgba(15,23,42,.28);max-width:720px;width:min(720px,100%);max-height:84vh;overflow:auto;padding:18px}.modal-body textarea{width:100%;box-sizing:border-box}.inline-form{display:inline}.doc-preview{margin-top:18px}.doc-preview:empty{display:none}
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
      if (target.matches(":focus-within")) return;
      try {
        const response = await fetch(refreshUrl, {cache: "no-store"});
        if (!response.ok) return;
        target.innerHTML = await response.text();
      } catch (_error) {
        // Keep the last good view when the local server is stopping or busy.
      }
    };
    window.setInterval(refresh, interval);
  });
});
</script>
"""


def page_header(title: str, context: str = "") -> str:
    context_html = f"<span class='header-context'>{html.escape(context)}</span>" if context else ""
    return (
        "<header class='site-header'><div class='shell header-row'>"
        f"<a class='home-link' href='/'>Home</a><h1>{html.escape(title)}</h1>{context_html}"
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

    def task_url(self, task: Task, message: str = "", level: str = "notice") -> str:
        url = f"/task/{quote(task.name)}?path={quote(str(task.path), safe='')}"
        if message:
            url += f"&{self.flash_query(message, level)}"
        return url

    def resolve_task(self, name: str, path_value: str = "") -> Task | None:
        all_tasks = list_tasks(self.repo, self.task_home, self.all_repos)
        if path_value:
            matches = [task for task in all_tasks if str(task.path) == path_value and task.name == name]
        else:
            matches = [task for task in all_tasks if task.name == name]
        return matches[0] if matches else None

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            return self.index()
        if parsed.path == "/fragments/tasks":
            return self.tasks_fragment(parse_qs(parsed.query))
        if parsed.path.startswith("/fragments/task-doc/"):
            query = parse_qs(parsed.query)
            return self.task_doc_fragment(
                unquote(parsed.path.removeprefix("/fragments/task-doc/")),
                query.get("doc", ["plan"])[0],
                query.get("path", [""])[0],
            )
        if parsed.path.startswith("/fragments/task/"):
            query = parse_qs(parsed.query)
            return self.task_fragment(
                unquote(parsed.path.removeprefix("/fragments/task/")),
                query.get("doc", ["plan"])[0],
                query.get("path", [""])[0],
            )
        if parsed.path.startswith("/task/"):
            query = parse_qs(parsed.query)
            return self.task(
                unquote(parsed.path.removeprefix("/task/")),
                query.get("doc", ["plan"])[0],
                query.get("path", [""])[0],
                query.get("message", [""])[0],
                query.get("level", ["notice"])[0],
            )
        self.send_html("<h1>Not found</h1>", 404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/actions/plan":
            return self.post_plan()
        if parsed.path == "/actions/implement-batch":
            return self.post_implement_batch()
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
        if parsed.path.startswith("/task/") and parsed.path.endswith("/delete"):
            name = unquote(parsed.path.removeprefix("/task/").removesuffix("/delete"))
            return self.post_delete(name)
        self.send_html("<h1>Not found</h1>", 404)

    def post_plan(self) -> None:
        form = self.form_data()
        task_name = form.get("task_name", "").strip()
        prompt = form.get("prompt", "").strip()
        if not valid_task_name(task_name):
            return self.redirect(f"/?{self.flash_query('invalid task name', 'error')}")
        if not prompt:
            return self.redirect(f"/?{self.flash_query('prompt is required', 'error')}")
        task_path = self.task_home / repo_slug(self.repo) / task_name
        ok, message = launch_paw(self.repo, self.task_home, task_path, ["plan", task_name, prompt])
        self.redirect(f"/?{self.flash_query(message, 'notice' if ok else 'error')}")

    def post_implement_batch(self) -> None:
        form = self.form_values()
        selected_paths = [value for value in form.get("task", []) if value]
        if not selected_paths:
            return self.redirect(f"/?{self.flash_query('select at least one unfinished task', 'error')}")
        tasks_by_path = {str(task.path): task for task in list_tasks(self.repo, self.task_home, self.all_repos)}
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
            if task.blocked:
                errors.append(f"{task.name} has USER ANSWER placeholders")
            elif task.running:
                errors.append(f"{task.name} is already running")
            elif task.finished:
                errors.append(f"{task.name} is already complete")
            elif not task.plan:
                errors.append(f"{task.name} has no plan.md")
            else:
                selected.append(task)
        if errors:
            return self.redirect(f"/?{self.flash_query('batch implement blocked: ' + '; '.join(errors), 'error')}")

        messages: list[str] = []
        ok_all = True
        for task in selected:
            ok, message = launch_paw(task.repo, self.task_home, task.path, ["implement", task.name])
            ok_all = ok_all and ok
            messages.append(f"{task.name}: {message}")
        level = "notice" if ok_all else "error"
        prefix = f"batch implement started {len(selected)} task(s)"
        self.redirect(f"/?{self.flash_query(prefix + ': ' + '; '.join(messages), level)}")

    def post_task_action(self, name: str, subcommand: str) -> None:
        form = self.form_data()
        task = self.resolve_task(name, form.get("path", ""))
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        if subcommand == "implement" and task.blocked:
            return self.redirect(self.task_url(task, "implement blocked: reconcile USER ANSWER placeholders first", "error"))
        if task.running:
            return self.redirect(self.task_url(task, f"{task.name} already has a running PAW subprocess", "error"))
        args = [subcommand, task.name]
        extras = "" if subcommand == "implement" else form.get("extras", "").strip()
        if extras and subcommand != "archive":
            args.append(extras)
        ok, message = launch_paw(task.repo, self.task_home, task.path, args)
        if subcommand == "archive" and ok:
            return self.redirect(f"/?{self.flash_query(message, 'notice')}")
        self.redirect(self.task_url(task, message, "notice" if ok else "error"))

    def post_delete(self, name: str) -> None:
        form = self.form_data()
        task = self.resolve_task(name, form.get("path", ""))
        if not task:
            named_task = self.resolve_task(name, "")
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
        message = query.get("message", [""])[0]
        level = query.get("level", ["notice"])[0]
        scope = "All task stores" if self.all_repos else f"{self.repo.name or 'repo'} repo"
        central_note = str(self.task_home) if self.all_repos else str(self.task_home / repo_slug(self.repo))
        refresh_query = {
            key: query.get(key, [""])[0]
            for key in ("state", "repo", "completion")
            if query.get(key, [""])[0]
        }
        refresh_url = "/fragments/tasks"
        if refresh_query:
            refresh_url += "?" + urlencode(refresh_query)
        body = (
            f"{page_header('PAW Tasks', scope)}<main class='shell'>"
            f"{self.flash_html(message, level)}"
            f"<p class='muted'>Central store {path_disclosure('Central store', central_note)}</p>"
            f"{self.index_filters(query)}"
            f"{self.new_plan_modal()}"
            f"<div id='task-list' data-paw-refresh-url=\"{html_attr(refresh_url)}\" data-paw-refresh-interval-ms=\"2500\">"
            f"{self.index_task_list(query)}"
            "</div><div class='doc-preview' data-doc-preview></div></main>"
        )
        self.send_html(body)

    def tasks_fragment(self, query: dict[str, list[str]]) -> None:
        self.send_fragment(self.index_task_list(query))

    def index_filters(self, query: dict[str, list[str]]) -> str:
        state_filter = query.get("state", [""])[0]
        completion_filter = query.get("completion", [""])[0]
        all_tasks = list_tasks(self.repo, self.task_home, self.all_repos)
        state_options = sorted({task.state for task in all_tasks})
        completion_options = sorted(
            {status_field(task.plan, "Estimated completion") for task in all_tasks if status_field(task.plan, "Estimated completion")}
        )
        state_select = "".join([option_tag("", "Any state", state_filter), *(option_tag(state, state, state_filter) for state in state_options)])
        completion_select = "".join(
            [option_tag("", "Any completion", completion_filter), *(option_tag(value, value, completion_filter) for value in completion_options)]
        )
        return (
            "<form class='toolbar' method='get'>"
            "<div class='toolbar-fields'>"
            f"<label>State <select name=\"state\">{state_select}</select></label>"
            f"<label>Repo <input name=\"repo\" value=\"{html_attr(query.get('repo', [''])[0])}\"></label>"
            f"<label>Completion <select name=\"completion\">{completion_select}</select></label>"
            "</div><div class='top-actions'>"
            "<button type='submit'>Filter</button><a class='button' href='/'>Clear</a>"
            "</div></form>"
        )

    def new_plan_modal(self) -> str:
        return (
            "<details class='modal-toggle'><summary><span class='button primary'>Plan</span></summary>"
            "<div class='modal-panel'><div class='modal-body'>"
            "<form method='post' action='/actions/plan'>"
            "<h2>Plan</h2>"
            "<p><label>Task name <input name='task_name' required pattern='[A-Za-z0-9._-]+'></label></p>"
            "<p><label>Prompt<br><textarea name='prompt' required rows='4'></textarea></label></p>"
            "<p class='action-row'><button type='submit'>Plan</button><button type='button' onclick='this.closest(\"details\").removeAttribute(\"open\")'>Close</button></p>"
            "</form></div></div></details>"
        )

    def extras_modal(self, task: Task, action: str, label: str) -> str:
        action_path = f"/task/{quote(task.name)}/{action}"
        return (
            "<details class='modal-toggle'>"
            f"<summary><span class='button'>{html.escape(label)}</span></summary>"
            "<div class='modal-panel'><div class='modal-body'>"
            f"<form method='post' action='{action_path}'>"
            f"<h2>{html.escape(label)} {html.escape(task.name)}</h2>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            "<p><label>Extra instructions<br><textarea name='extras' rows='4'></textarea></label></p>"
            f"<p class='action-row'><button type='submit'>{html.escape(label)}</button><button type='button' onclick='this.closest(\"details\").removeAttribute(\"open\")'>Close</button></p>"
            "</form></div></div></details>"
        )

    def implement_form(self, task: Task) -> str:
        return (
            f"<form class='inline-form' method='post' action='/task/{quote(task.name)}/implement'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            "<button type='submit'>Implement</button></form>"
        )

    def action_form(self, task: Task, action: str, label: str) -> str:
        return (
            f"<form class='inline-form' method='post' action='/task/{quote(task.name)}/{action}'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<button type='submit'>{html.escape(label)}</button></form>"
        )

    def archive_form(self, task: Task) -> str:
        return (
            f"<form class='inline-form' method='post' action='/task/{quote(task.name)}/archive'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            "<button type='submit'>Archive</button></form>"
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
            "<input type='hidden' name='confirm' value='yes'>"
            "<p class='action-row'><button class='danger' type='submit'>Delete</button><button type='button' onclick='this.closest(\"details\").removeAttribute(\"open\")'>Cancel</button></p>"
            "</form></div></div></details>"
        )

    def task_actions(self, task: Task, include_docs: bool = False) -> str:
        detail_href = f"/task/{quote(task.name)}?path={quote(str(task.path), safe='')}"
        pieces = [f"<a class='button' href='{detail_href}'>Open</a>"]
        if include_docs:
            for doc in ("contract", "plan", "pr"):
                preview_url = f"/fragments/task-doc/{quote(task.name)}?path={quote(str(task.path), safe='')}&doc={doc}"
                pieces.append(f"<button type='button' data-doc-preview-url='{html_attr(preview_url)}'>{doc}.md</button>")
        pieces.extend(
            [
                self.extras_modal(task, "edit", "Edit"),
                self.implement_form(task),
                self.delete_modal(task),
            ]
        )
        if not include_docs:
            pieces.extend([self.extras_modal(task, "review", "Review"), self.extras_modal(task, "prototype", "Prototype"), self.archive_form(task)])
        return f"<div class='action-row'>{''.join(pieces)}</div>"

    def workflow_action_control(self, task: Task, workflow: TaskWorkflow) -> str:
        if workflow.action == "edit":
            return self.extras_modal(task, "edit", workflow.next_label)
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
        return f"<div class='workflow-cell'>{''.join(parts)}</div>"

    def workflow_next_cell(self, task: Task, workflow: TaskWorkflow) -> str:
        reason = f"<div class='workflow-note muted'>{html.escape(workflow.disabled_reason)}</div>" if workflow.disabled_reason else ""
        note = f"<div class='workflow-note muted'>{html.escape(workflow.note)}</div>" if workflow.note else ""
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

    def index_task_list(self, query: dict[str, list[str]]) -> str:
        state_filter = query.get("state", [""])[0]
        repo_filter = query.get("repo", [""])[0].strip().lower()
        completion_filter = query.get("completion", [""])[0]
        all_tasks = list_tasks(self.repo, self.task_home, self.all_repos)
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
            task_href = f"/task/{quote(task.name)}?path={quote(str(task.path), safe='')}"
            branch = task.branch_context or "<none>"
            selector = (
                f"<input form='batch-implement-form' type='checkbox' name='task' value='{html_attr(str(task.path))}' aria-label='Select {html_attr(task.name)}'>"
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
            "<form id='batch-implement-form' method='post' action='/actions/implement-batch'></form>"
            "<div class='top-actions'><button form='batch-implement-form' type='submit'>Implement selected</button></div>"
            "<div class='table-wrap'><table><thead><tr><th>Select</th><th>Task</th><th>Repo</th><th>Stage</th><th>Next</th><th>Completion</th><th>Checklist</th><th>Validation</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows) or '<tr><td colspan=9>No task packages found.</td></tr>'}</tbody></table></div>"
        )

    def flash_html(self, message: str, level: str = "notice") -> str:
        if not message:
            return ""
        class_name = "flash-error" if level == "error" else "flash"
        return f"<p class='{class_name}'>{html.escape(message)}</p>"

    def task(self, name: str, doc: str, path_value: str = "", message: str = "", level: str = "notice") -> None:
        task = self.resolve_task(name, path_value)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        path_query = quote(str(task.path), safe="")
        selected_doc = doc_name(doc)
        refresh_url = f"/fragments/task/{quote(task.name)}?path={path_query}&doc={quote(selected_doc)}"
        body = (
            f"{page_header(task.name, task.repo_name)}<main class='shell'>"
            f"{self.flash_html(message, level)}"
            f"{self.task_actions(task)}"
            f"<div id='task-detail' data-paw-refresh-url=\"{html_attr(refresh_url)}\" data-paw-refresh-interval-ms=\"2500\">"
            f"{self.task_detail(task, selected_doc)}"
            "</div></main>"
        )
        self.send_html(body)

    def task_fragment(self, name: str, doc: str, path_value: str = "") -> None:
        task = self.resolve_task(name, path_value)
        if not task:
            return self.send_fragment("<h1>Task not found</h1>", 404)
        self.send_fragment(self.task_detail(task, doc_name(doc)))

    def task_doc_fragment(self, name: str, doc: str, path_value: str = "") -> None:
        task = self.resolve_task(name, path_value)
        if not task:
            return self.send_fragment("<h1>Task not found</h1>", 404)
        selected_doc = doc_name(doc)
        content = self.task_doc_content(task, selected_doc)
        self.send_fragment(
            "<div class='modal-panel'><div class='modal-body'>"
            f"<h2>{html.escape(task.name)} / {html.escape(selected_doc)}.md</h2>"
            "<p><button type='button' onclick='this.closest(\"[data-doc-preview]\").innerHTML=\"\"'>Close</button></p>"
            f"<div class='document'>{render_markdown(content)}</div>"
            "</div></div>"
        )

    def task_doc_content(self, task: Task, doc: str) -> str:
        return {"contract": task.contract, "plan": task.plan, "pr": task.pr, "review": task.review}.get(doc, task.plan)

    def task_detail(self, task: Task, doc: str) -> str:
        selected_doc = doc_name(doc)
        content = self.task_doc_content(task, selected_doc)
        path_query = quote(str(task.path), safe="")
        doc_tabs = ["contract", "plan", "pr"]
        if task.review:
            doc_tabs.append("review")
        tabs = " ".join(f"<a href='/task/{quote(task.name)}?path={path_query}&doc={tab}'>{tab}.md</a>" for tab in doc_tabs)
        done, total = checklist_counts(task.plan)
        crash_state = "available" if (task.path / "crash.log").exists() else "none"
        pr_tracking = tracking_summary(task.plan, "PR") or "none"
        issue_tracking = tracking_summary(task.plan, "Issue") or "none"
        prototype_status = task.prototype_status or "none"
        prototype_source = task.prototype_source or "none"
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
            f"<tr><th>Crash Log</th><td>{html.escape(crash_state)}</td></tr>"
            "</tbody></table></div>"
            f"<p class='tabs'>{tabs}</p><div class='document'>{render_markdown(content)}</div>"
            "<h2>Run History</h2><div class='table-wrap'><table><thead><tr><th>Subcommand</th><th>Status</th><th>Backend</th><th>Model</th><th>Started</th><th>Ended</th><th>Exit</th></tr></thead>"
            f"<tbody>{run_rows(task.path)}</tbody></table></div>"
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
