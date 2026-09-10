#!/usr/bin/env python3
"""Local-only PAW task dashboard server."""

from __future__ import annotations

import argparse
import html
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse


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


class Task:
    def __init__(self, name: str, source: str, path: Path, repo: Path):
        self.name = name
        self.source = source
        self.path = path
        self.repo = repo
        self.plan = (path / "plan.md").read_text(errors="replace") if (path / "plan.md").exists() else ""
        self.contract = (path / "contract.md").read_text(errors="replace") if (path / "contract.md").exists() else ""
        self.pr = (path / "pr.md").read_text(errors="replace") if (path / "pr.md").exists() else ""

    @property
    def blocked(self) -> bool:
        return bool(re.search(r"USER ANSWER \((UNRESOLVED|PROVIDED)\):", self.plan))

    @property
    def running(self) -> bool:
        for meta in (self.path / "runs").glob("*.gitconfig") if (self.path / "runs").exists() else []:
            if metadata_value(meta, "status") == "running":
                return True
        return False

    @property
    def state(self) -> str:
        if self.running:
            return "running"
        if self.blocked:
            return "blocked"
        return "ready"


def list_tasks(repo: Path, task_home: Path) -> list[Task]:
    tasks: dict[str, Task] = {}
    central_root = task_home / repo_slug(repo)
    if central_root.exists():
        for path in sorted(p for p in central_root.iterdir() if p.is_dir()):
            metadata_repo = metadata_value(path / "metadata.gitconfig", "repo-root")
            if metadata_repo and physical(Path(metadata_repo)) != repo:
                continue
            tasks[path.name] = Task(path.name, "central", path, repo)
    legacy_root = repo / ".agent"
    if legacy_root.exists():
        for path in sorted(p for p in legacy_root.iterdir() if p.is_dir()):
            tasks.setdefault(path.name, Task(path.name, "legacy", path, repo))
    return list(tasks.values())


STYLE = """
body{font:14px/1.45 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;color:#202124;background:#f7f8fa}
header{background:#243447;color:white;padding:20px 28px}main{padding:24px 28px;max-width:1180px;margin:auto}
a{color:#0b57d0;text-decoration:none}table{border-collapse:collapse;width:100%;background:white;border:1px solid #dfe3ea}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #e8ebf0;vertical-align:top}th{background:#edf1f7;font-size:12px;text-transform:uppercase;color:#4b5563}
.pill{display:inline-block;border:1px solid #ccd3dd;border-radius:999px;padding:2px 8px;background:#f8fafc;font-size:12px}.blocked{border-color:#d97706;color:#92400e}.running{border-color:#2563eb;color:#1d4ed8}.ready{border-color:#15803d;color:#166534}
pre{white-space:pre-wrap;background:white;border:1px solid #dfe3ea;padding:16px;overflow:auto}.tabs a{margin-right:14px}.muted{color:#667085}
"""


class Handler(BaseHTTPRequestHandler):
    repo: Path
    task_home: Path

    def send_html(self, body: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(f"<!doctype html><title>PAW</title><style>{STYLE}</style>{body}".encode())

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            return self.index()
        if parsed.path.startswith("/task/"):
            return self.task(unquote(parsed.path.removeprefix("/task/")), parse_qs(parsed.query).get("doc", ["plan"])[0])
        self.send_html("<h1>Not found</h1>", 404)

    def index(self) -> None:
        rows = []
        for task in list_tasks(self.repo, self.task_home):
            done, total = checklist_counts(task.plan)
            rows.append(
                "<tr>"
                f"<td><a href='/task/{quote(task.name)}'>{html.escape(task.name)}</a><br><span class='muted'>{html.escape(str(task.path))}</span></td>"
                f"<td><span class='pill {task.state}'>{task.state}</span><br>{task.source}</td>"
                f"<td>{html.escape(status_field(task.plan, 'Plan position') or '<missing>')}</td>"
                f"<td>{html.escape(status_field(task.plan, 'Estimated completion') or '<missing>')}</td>"
                f"<td>{html.escape(status_field(task.plan, 'Next work') or '<missing>')}</td>"
                f"<td>{html.escape(metadata_value(task.path / 'metadata.gitconfig', 'branch-name') or metadata_value(task.path / 'metadata.gitconfig', 'head-state') or '<none>')}</td>"
                f"<td>{done}/{total}</td><td>{validation_state(task.plan)}</td>"
                "</tr>"
            )
        body = (
            f"<header><h1>PAW Tasks</h1><div>{html.escape(str(self.repo))}</div></header><main>"
            f"<p class='muted'>Central store: {html.escape(str(self.task_home / repo_slug(self.repo)))}</p>"
            "<table><thead><tr><th>Task</th><th>State</th><th>Plan Position</th><th>Completion</th><th>Next Work</th><th>Branch</th><th>Checklist</th><th>Validation</th></tr></thead>"
            f"<tbody>{''.join(rows) or '<tr><td colspan=8>No task packages found.</td></tr>'}</tbody></table></main>"
        )
        self.send_html(body)

    def task(self, name: str, doc: str) -> None:
        matches = [task for task in list_tasks(self.repo, self.task_home) if task.name == name]
        if not matches:
            return self.send_html("<h1>Task not found</h1>", 404)
        task = matches[0]
        content = {"contract": task.contract, "plan": task.plan, "pr": task.pr}.get(doc, task.plan)
        tabs = " ".join(f"<a href='/task/{quote(name)}?doc={tab}'>{tab}.md</a>" for tab in ("contract", "plan", "pr"))
        done, total = checklist_counts(task.plan)
        crash_state = "available" if (task.path / "crash.log").exists() else "none"
        pr_tracking = tracking_summary(task.plan, "PR") or "none"
        issue_tracking = tracking_summary(task.plan, "Issue") or "none"
        body = (
            f"<header><h1>{html.escape(task.name)}</h1><div>{html.escape(str(task.path))}</div></header><main>"
            f"<p><span class='pill {task.state}'>{task.state}</span> <span class='pill'>{task.source}</span> <span class='pill'>{done}/{total} checklist</span></p>"
            "<table><tbody>"
            f"<tr><th>Repo</th><td>{html.escape(str(task.repo))}</td></tr>"
            f"<tr><th>Worktree</th><td>{html.escape(metadata_value(task.path / 'metadata.gitconfig', 'worktree-path') or 'legacy metadata unavailable')}</td></tr>"
            f"<tr><th>PR</th><td>{html.escape(pr_tracking)}</td></tr>"
            f"<tr><th>Issue</th><td>{html.escape(issue_tracking)}</td></tr>"
            f"<tr><th>Crash Log</th><td>{html.escape(crash_state)}</td></tr>"
            "</tbody></table>"
            f"<p class='tabs'>{tabs}</p><pre>{html.escape(content or '(file missing)')}</pre>"
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
    args = parser.parse_args()
    if args.host != "127.0.0.1" and args.host != "localhost":
        raise SystemExit("error: paw gui only supports localhost hosts")
    Handler.repo = physical(Path(args.repo))
    Handler.task_home = physical(Path(args.task_home))
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
