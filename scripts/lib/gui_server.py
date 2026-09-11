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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse


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

    @property
    def repo_name(self) -> str:
        return self.repo.name or self.slug

    @property
    def branch_context(self) -> str:
        return metadata_value(self.path / "metadata.gitconfig", "branch-name") or metadata_value(
            self.path / "metadata.gitconfig", "head-state"
        )

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


def list_repo_tasks(repo: Path, task_home: Path) -> list[Task]:
    tasks: dict[str, Task] = {}
    central_root = task_home / repo_slug(repo)
    if central_root.exists():
        for path in sorted(p for p in central_root.iterdir() if p.is_dir()):
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
            metadata_repo = metadata_value(path / "metadata.gitconfig", "repo-root")
            repo = physical(Path(metadata_repo)) if metadata_repo else Path(repo_dir.name)
            tasks.append(Task(path.name, "central", path, repo, repo_dir.name))
    return tasks


def list_tasks(repo: Path, task_home: Path, all_repos: bool) -> list[Task]:
    if all_repos:
        return list_all_central_tasks(task_home)
    return list_repo_tasks(repo, task_home)


STYLE = """
body{font:14px/1.45 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;color:#202124;background:#f7f8fa}
header{background:#243447;color:white;padding:20px 28px}main{padding:24px 28px;max-width:1180px;margin:auto}
a{color:#0b57d0;text-decoration:none}table{border-collapse:collapse;width:100%;background:white;border:1px solid #dfe3ea}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #e8ebf0;vertical-align:top}th{background:#edf1f7;font-size:12px;text-transform:uppercase;color:#4b5563}
.pill{display:inline-block;border:1px solid #ccd3dd;border-radius:999px;padding:2px 8px;background:#f8fafc;font-size:12px}.blocked{border-color:#d97706;color:#92400e}.running{border-color:#2563eb;color:#1d4ed8}.ready{border-color:#15803d;color:#166534}
.tabs a{margin-right:14px}.muted{color:#667085}.document{background:white;border:1px solid #dfe3ea;padding:20px;margin:14px 0 24px;overflow:auto}.document h1,.document h2,.document h3{margin:18px 0 10px}.document h1:first-child,.document h2:first-child{margin-top:0}.document pre{background:#f6f8fa;border:1px solid #dfe3ea;padding:12px;overflow:auto}.document code{background:#eef2f7;padding:1px 4px}.document pre code{background:transparent;padding:0}.document blockquote{border-left:4px solid #d0d7de;color:#57606a;margin:12px 0;padding:1px 14px}.document ul,.document ol{padding-left:24px}.document li{margin:3px 0}.document input[type=checkbox]{margin-right:6px}
"""


class Handler(BaseHTTPRequestHandler):
    repo: Path
    task_home: Path
    all_repos: bool

    def send_html(self, body: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(f"<!doctype html><title>PAW</title><style>{STYLE}</style>{body}".encode())

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
        extras = form.get("extras", "").strip()
        args = [subcommand, task.name]
        if extras:
            args.append(extras)
        ok, message = launch_paw(task.repo, self.task_home, task.path, args)
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
        if form.get("confirm", "") != task.name:
            return self.redirect(self.task_url(task, "delete confirmation must match the task name", "error"))
        submitted = form.get("path", "")
        if submitted != str(task.path):
            return self.redirect(self.task_url(task, "delete rejected: stale task path", "error"))
        shutil.rmtree(task.path)
        self.redirect(f"/?{self.flash_query(f'deleted task {task.name}', 'notice')}")

    def index(self) -> None:
        query = parse_qs(urlparse(self.path).query)
        message = query.get("message", [""])[0]
        level = query.get("level", ["notice"])[0]
        state_filter = query.get("state", [""])[0]
        repo_filter = query.get("repo", [""])[0].strip().lower()
        completion_filter = query.get("completion", [""])[0]
        all_tasks = list_tasks(self.repo, self.task_home, self.all_repos)
        state_options = sorted({task.state for task in all_tasks})
        completion_options = sorted(
            {status_field(task.plan, "Estimated completion") for task in all_tasks if status_field(task.plan, "Estimated completion")}
        )
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
                f"<input type='checkbox' name='task' value='{html_attr(str(task.path))}' aria-label='Select {html_attr(task.name)}'>"
                if task.batch_eligible
                else ""
            )
            rows.append(
                "<tr>"
                f"<td>{selector}</td>"
                f"<td><a href='{task_href}'>{html.escape(task.name)}</a><br><span class='muted'>{html.escape(str(task.path))}</span></td>"
                f"<td>{html.escape(task.repo_name)}<br><span class='muted'>{html.escape(str(task.repo))}</span><br><span class='muted'>{html.escape(task.slug)}</span><br><span class='muted'>Branch: {html.escape(branch)}</span></td>"
                f"<td><span class='pill {task.state}'>{task.state}</span><br>{task.source}</td>"
                f"<td>{html.escape(status_field(task.plan, 'Plan position') or '<missing>')}</td>"
                f"<td>{html.escape(completion)}</td>"
                f"<td>{html.escape(status_field(task.plan, 'Next work') or '<missing>')}</td>"
                f"<td>{done}/{total}</td><td>{validation_state(task.plan)}</td>"
                "</tr>"
            )
        state_select = "".join([option_tag("", "Any state", state_filter), *(option_tag(state, state, state_filter) for state in state_options)])
        completion_select = "".join(
            [option_tag("", "Any completion", completion_filter), *(option_tag(value, value, completion_filter) for value in completion_options)]
        )
        scope = "All central task stores" if self.all_repos else str(self.repo)
        central_note = str(self.task_home) if self.all_repos else str(self.task_home / repo_slug(self.repo))
        body = (
            f"<header><h1>PAW Tasks</h1><div>{html.escape(scope)}</div></header><main>"
            f"{self.flash_html(message, level)}"
            f"<p class='muted'>Central store: {html.escape(central_note)}</p>"
            "<form method='get'>"
            f"<p><label>State <select name=\"state\">{state_select}</select></label> "
            f"<label>Repo <input name=\"repo\" value=\"{html_attr(query.get('repo', [''])[0])}\"></label> "
            f"<label>Completion <select name=\"completion\">{completion_select}</select></label> "
            "<button type='submit'>Filter</button> <a href='/'>Clear</a></p>"
            "</form>"
            "<form method='post' action='/actions/plan'>"
            "<h2>New Plan</h2>"
            "<p><label>Task name <input name='task_name' required pattern='[A-Za-z0-9._-]+'></label></p>"
            "<p><label>Prompt<br><textarea name='prompt' required rows='4'></textarea></label></p>"
            "<p><button type='submit'>Start plan</button></p>"
            "</form>"
            "<form method='post' action='/actions/implement-batch'>"
            "<p><button type='submit'>Start selected implementations</button></p>"
            "<table><thead><tr><th>Select</th><th>Task</th><th>Repo</th><th>State</th><th>Plan Position</th><th>Completion</th><th>Next Work</th><th>Checklist</th><th>Validation</th></tr></thead>"
            f"<tbody>{''.join(rows) or '<tr><td colspan=9>No task packages found.</td></tr>'}</tbody></table></form></main>"
        )
        self.send_html(body)

    def flash_html(self, message: str, level: str = "notice") -> str:
        if not message:
            return ""
        class_name = "flash-error" if level == "error" else "flash"
        return f"<p class='{class_name}'>{html.escape(message)}</p>"

    def task(self, name: str, doc: str, path_value: str = "", message: str = "", level: str = "notice") -> None:
        task = self.resolve_task(name, path_value)
        if not task:
            return self.send_html("<h1>Task not found</h1>", 404)
        content = {"contract": task.contract, "plan": task.plan, "pr": task.pr}.get(doc, task.plan)
        path_query = quote(str(task.path), safe="")
        tabs = " ".join(f"<a href='/task/{quote(name)}?path={path_query}&doc={tab}'>{tab}.md</a>" for tab in ("contract", "plan", "pr"))
        done, total = checklist_counts(task.plan)
        crash_state = "available" if (task.path / "crash.log").exists() else "none"
        pr_tracking = tracking_summary(task.plan, "PR") or "none"
        issue_tracking = tracking_summary(task.plan, "Issue") or "none"
        body = (
            f"<header><h1>{html.escape(task.name)}</h1><div>{html.escape(str(task.path))}</div></header><main>"
            f"{self.flash_html(message, level)}"
            f"<p><span class='pill {task.state}'>{task.state}</span> <span class='pill'>{task.source}</span> <span class='pill'>{done}/{total} checklist</span></p>"
            "<table><tbody>"
            f"<tr><th>Repo</th><td>{html.escape(str(task.repo))}</td></tr>"
            f"<tr><th>Repo Slug</th><td>{html.escape(task.slug)}</td></tr>"
            f"<tr><th>Worktree</th><td>{html.escape(metadata_value(task.path / 'metadata.gitconfig', 'worktree-path') or 'legacy metadata unavailable')}</td></tr>"
            f"<tr><th>PR</th><td>{html.escape(pr_tracking)}</td></tr>"
            f"<tr><th>Issue</th><td>{html.escape(issue_tracking)}</td></tr>"
            f"<tr><th>Crash Log</th><td>{html.escape(crash_state)}</td></tr>"
            "</tbody></table>"
            f"<form method='post' action='/task/{quote(task.name)}/edit'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            "<h2>Edit Plan</h2><p><label>Extra instructions<br><textarea name='extras' rows='3'></textarea></label></p>"
            "<p><button type='submit'>Start edit</button></p></form>"
            f"<form method='post' action='/task/{quote(task.name)}/implement'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            "<h2>Implement</h2><p><label>Extra instructions<br><textarea name='extras' rows='3'></textarea></label></p>"
            "<p><button type='submit'>Start implement</button></p></form>"
            f"<form method='post' action='/task/{quote(task.name)}/delete'>"
            f"<input type='hidden' name='path' value='{html_attr(str(task.path))}'>"
            f"<h2>Delete Task</h2><p><label>Type {html.escape(task.name)} <input name='confirm'></label></p>"
            "<p><button type='submit'>Delete task</button></p></form>"
            f"<p class='tabs'>{tabs}</p><div class='document'>{render_markdown(content)}</div>"
            "<h2>Run History</h2><table><thead><tr><th>Subcommand</th><th>Status</th><th>Backend</th><th>Model</th><th>Started</th><th>Ended</th><th>Exit</th></tr></thead>"
            f"<tbody>{run_rows(task.path)}</tbody></table></main>"
        )
        self.send_html(body)


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
