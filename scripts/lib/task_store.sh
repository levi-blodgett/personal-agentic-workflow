#!/usr/bin/env bash
# task_store.sh — central and legacy PAW task package resolution helpers.

paw_task_home() {
  if [[ -n "${PAW_TASK_HOME:-}" ]]; then
    printf '%s\n' "$PAW_TASK_HOME"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/paw/tasks\n' "$XDG_STATE_HOME"
  else
    printf '%s/.local/state/paw/tasks\n' "$HOME"
  fi
}

paw_repo_physical_path() {
  local repo_path="${1:-$PWD}"
  cd "$repo_path" && pwd -P
}

paw_repo_common_dir() {
  local repo_path="${1:-$PWD}" raw common_base
  if raw=$(git -C "$repo_path" rev-parse --git-common-dir 2>/dev/null); then
    if [[ "$raw" == /* ]]; then
      common_base="$raw"
    else
      common_base="$(paw_repo_physical_path "$repo_path")/$raw"
    fi
    cd "$common_base" && pwd -P
    return 0
  fi
  paw_repo_physical_path "$repo_path"
}

paw_repo_slug() {
  local repo_path="${1:-$PWD}" physical base safe checksum
  physical="$(paw_repo_common_dir "$repo_path")"
  base="$(basename "$(paw_repo_physical_path "$repo_path")")"
  safe="$(printf '%s\n' "$base" | tr -c '[:alnum:]._' '-' | sed -E 's/^-+//; s/-+$//')"
  [[ -n "$safe" ]] || safe="repo"
  checksum="$(printf '%s' "$physical" | cksum | awk '{print $1}')"
  printf '%s-%s\n' "$safe" "$checksum"
}

paw_task_repo_store() {
  local repo_path="${1:-$PWD}"
  printf '%s/%s\n' "$(paw_task_home)" "$(paw_repo_slug "$repo_path")"
}

paw_task_create_dir() {
  local repo_path="$1" task_name="$2"
  printf '%s/%s\n' "$(paw_task_repo_store "$repo_path")" "$task_name"
}

paw_task_legacy_dir() {
  local repo_path="$1" task_name="$2"
  printf '%s/.agent/%s\n' "$(paw_repo_physical_path "$repo_path")" "$task_name"
}

paw_task_resolve() {
  local repo_path="$1" task_name="$2" central legacy
  central="$(paw_task_create_dir "$repo_path" "$task_name")"
  legacy="$(paw_task_legacy_dir "$repo_path" "$task_name")"
  if [[ -d "$central" ]]; then
    printf '%s\n' "$central"
    return 0
  fi
  if [[ -d "$legacy" ]]; then
    printf '%s\n' "$legacy"
    return 0
  fi
  echo "error: task '$task_name' not found." >&2
  echo "       Expected central task path: $central" >&2
  echo "       Expected legacy task path:  $legacy" >&2
  return 1
}

paw_task_metadata_file() {
  printf '%s/metadata.gitconfig\n' "$1"
}

paw_task_write_metadata() {
  local task_dir="$1" repo_path="$2" task_name="$3" status="${4:-created}" source_path="${5:-}"
  local metadata_file now repo_root common_dir worktree_path branch head_state head_sha
  metadata_file="$(paw_task_metadata_file "$task_dir")"
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  repo_root="$(paw_repo_physical_path "$repo_path")"
  common_dir="$(paw_repo_common_dir "$repo_path")"
  worktree_path="$(paw_repo_physical_path "$repo_path")"
  branch="$(git -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  head_sha="$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$branch" ]]; then
    if [[ -n "$head_sha" ]]; then
      head_state="branch"
    else
      head_state="unborn"
    fi
  else
    head_state="detached"
  fi

  mkdir -p "$task_dir"
  : > "$metadata_file"
  git config --file "$metadata_file" paw.task-name "$task_name"
  git config --file "$metadata_file" paw.repo-root "$repo_root"
  git config --file "$metadata_file" paw.git-common-dir "$common_dir"
  git config --file "$metadata_file" paw.worktree-path "$worktree_path"
  git config --file "$metadata_file" paw.head-state "$head_state"
  git config --file "$metadata_file" paw.created-at "$now"
  if [[ "$status" == "migrated" ]]; then
    git config --file "$metadata_file" paw.migrated-at "$now"
  fi
  if [[ -n "$branch" ]]; then
    git config --file "$metadata_file" paw.branch-name "$branch"
  fi
  if [[ -n "$head_sha" ]]; then
    git config --file "$metadata_file" paw.head-sha "$head_sha"
  fi
  if [[ -n "$source_path" ]]; then
    git config --file "$metadata_file" paw.source-path "$source_path"
  fi
}

paw_task_metadata_get() {
  local task_dir="$1" key="$2"
  git config --file "$(paw_task_metadata_file "$task_dir")" --get "paw.$key" 2>/dev/null || true
}

paw_task_plan_field() {
  local plan_file="$1" label="$2"
  [[ -f "$plan_file" ]] || return 1
  awk -v label="$label" '
    /^## Current Status[[:space:]]*$/ { in_block = 1; next }
    in_block && /^## / { in_block = 0 }
    in_block {
      pattern = "^- " label ":[[:space:]]*"
      if ($0 ~ pattern) {
        sub(pattern, "", $0)
        print $0
        exit
      }
    }
  ' "$plan_file"
}

paw_task_has_pending_user_answers() {
  local task_dir="$1" plan_file
  plan_file="$task_dir/plan.md"
  [[ -f "$plan_file" ]] || return 1
  grep -Fq 'USER ANSWER (UNRESOLVED):' "$plan_file" || grep -Fq 'USER ANSWER (PROVIDED):' "$plan_file"
}

paw_task_running_metadata_is_active() {
  local run_file="$1" base pid
  [[ -f "$run_file" ]] || return 1
  [[ "$(git config --file "$run_file" --get paw.status 2>/dev/null || true)" == "running" ]] || return 1
  base="${run_file##*/}"
  if [[ "$base" =~ -([0-9]+)\.gitconfig$ ]]; then
    pid="${BASH_REMATCH[1]}"
    kill -0 "$pid" 2>/dev/null
    return $?
  fi
  return 0
}

paw_task_has_active_run() {
  local task_dir="$1" run_file
  shopt -s nullglob
  for run_file in "$task_dir"/runs/*.gitconfig; do
    if paw_task_running_metadata_is_active "$run_file"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

paw_task_is_finished() {
  local task_dir="$1" plan_file completion next_work
  plan_file="$task_dir/plan.md"
  [[ -f "$plan_file" ]] || return 1
  completion="$(paw_task_plan_field "$plan_file" "Estimated completion")"
  next_work="$(paw_task_plan_field "$plan_file" "Next work")"
  [[ "$completion" == "100%" && "$next_work" == Review.* ]]
}

paw_task_list() {
  local repo_path="${1:-$PWD}" repo_root repo_store legacy_root task_dir task_name metadata_repo
  repo_root="$(paw_repo_physical_path "$repo_path")"
  repo_store="$(paw_task_repo_store "$repo_path")"
  legacy_root="$repo_root/.agent"

  shopt -s nullglob
  if [[ -d "$repo_store" ]]; then
    for task_dir in "$repo_store"/*/; do
      [[ -d "$task_dir" ]] || continue
      task_dir="${task_dir%/}"
      task_name="${task_dir##*/}"
      metadata_repo="$(paw_task_metadata_get "$task_dir" repo-root)"
      if [[ -n "$metadata_repo" && "$metadata_repo" != "$repo_root" ]]; then
        continue
      fi
      printf '%s\tcentral\t%s\n' "$task_name" "$task_dir"
    done
  fi
  if [[ -d "$legacy_root" ]]; then
    for task_dir in "$legacy_root"/*/; do
      [[ -d "$task_dir" ]] || continue
      task_dir="${task_dir%/}"
      task_name="${task_dir##*/}"
      if [[ -d "$repo_store/$task_name" ]]; then
        continue
      fi
      printf '%s\tlegacy\t%s\n' "$task_name" "$task_dir"
    done
  fi
  shopt -u nullglob
}

paw_task_migrate_repo() {
  local repo_path="${1:-$PWD}" legacy_root task_dir task_name central_dir
  legacy_root="$(paw_repo_physical_path "$repo_path")/.agent"
  if [[ ! -d "$legacy_root" ]]; then
    echo "no legacy .agent/ directory found in $(paw_repo_physical_path "$repo_path")"
    return 0
  fi

  local migrated=0
  shopt -s nullglob
  for task_dir in "$legacy_root"/*/; do
    [[ -d "$task_dir" ]] || continue
    task_dir="${task_dir%/}"
    task_name="${task_dir##*/}"
    central_dir="$(paw_task_create_dir "$repo_path" "$task_name")"
    if [[ -e "$central_dir" ]]; then
      echo "skip: central task already exists: $central_dir"
      continue
    fi
    mkdir -p "$(dirname "$central_dir")"
    cp -R "$task_dir" "$central_dir"
    paw_task_write_metadata "$central_dir" "$repo_path" "$task_name" migrated "$task_dir"
    echo "migrated: $task_dir -> $central_dir"
    migrated=$((migrated + 1))
  done
  shopt -u nullglob

  if [[ "$migrated" -eq 0 ]]; then
    echo "no legacy task packages migrated from $legacy_root"
  fi
}
