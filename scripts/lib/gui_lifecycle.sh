#!/usr/bin/env bash
# gui_lifecycle.sh — local process metadata helpers for `paw gui start|stop|kill`.

paw_gui_state_dir() {
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/paw/gui\n' "$XDG_STATE_HOME"
  else
    printf '%s/.local/state/paw/gui\n' "$HOME"
  fi
}

paw_gui_metadata_file() {
  printf '%s/active.gitconfig\n' "$(paw_gui_state_dir)"
}

paw_gui_process_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

paw_gui_process_matches() {
  local pid="$1" command_line
  paw_gui_process_alive "$pid" || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command_line" == *"gui_server.py"* && "$command_line" == *"--task-home"* ]]
}

paw_gui_metadata_pid() {
  local metadata_file
  metadata_file="$(paw_gui_metadata_file)"
  [[ -f "$metadata_file" ]] || return 1
  git config --file "$metadata_file" --get paw.pid 2>/dev/null
}

paw_gui_clear_metadata() {
  rm -f "$(paw_gui_metadata_file)"
}

paw_gui_active_metadata() {
  local metadata_file pid
  metadata_file="$(paw_gui_metadata_file)"
  [[ -f "$metadata_file" ]] || return 1
  pid="$(paw_gui_metadata_pid || true)"
  if paw_gui_process_matches "$pid"; then
    return 0
  fi
  echo "paw gui: removing stale lifecycle metadata for pid ${pid:-<missing>}" >&2
  paw_gui_clear_metadata
  return 1
}

paw_gui_record_metadata() {
  local pid="$1" host="$2" port="$3" repo_path="$4" task_home="$5" url="$6" stdout_log="$7" stderr_log="$8"
  local metadata_file
  metadata_file="$(paw_gui_metadata_file)"
  mkdir -p "$(dirname "$metadata_file")"
  : > "$metadata_file"
  git config --file "$metadata_file" paw.pid "$pid"
  git config --file "$metadata_file" paw.host "$host"
  git config --file "$metadata_file" paw.port "$port"
  git config --file "$metadata_file" paw.repo-path "$repo_path"
  git config --file "$metadata_file" paw.task-home "$task_home"
  git config --file "$metadata_file" paw.url "$url"
  git config --file "$metadata_file" paw.stdout-log "$stdout_log"
  git config --file "$metadata_file" paw.stderr-log "$stderr_log"
  git config --file "$metadata_file" paw.started-at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
