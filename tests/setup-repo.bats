#!/usr/bin/env bats
# Tests for scripts/setup-repo.sh

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────

make_git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
}

# ── tests ─────────────────────────────────────────────────────────────────────

@test "setup-repo: adds .agent/ to .git/info/exclude when missing" {
  local repo="$BATS_TEST_TMPDIR/repo"
  make_git_repo "$repo"

  run "$SCRIPTS_DIR/setup-repo.sh" "$repo"

  [ "$status" -eq 0 ]
  grep -qxF '.agent/' "$repo/.git/info/exclude"
}

@test "setup-repo: is idempotent (no duplicate entry on second run)" {
  local repo="$BATS_TEST_TMPDIR/repo"
  make_git_repo "$repo"

  "$SCRIPTS_DIR/setup-repo.sh" "$repo"
  "$SCRIPTS_DIR/setup-repo.sh" "$repo"

  local count
  count=$(grep -cxF '.agent/' "$repo/.git/info/exclude")
  [ "$count" -eq 1 ]
}

@test "setup-repo: exits 1 when path is not a git repo" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$dir"

  run "$SCRIPTS_DIR/setup-repo.sh" "$dir"

  [ "$status" -eq 1 ]
}

@test "setup-repo: exits 1 when path does not exist" {
  run "$SCRIPTS_DIR/setup-repo.sh" "$BATS_TEST_TMPDIR/nonexistent"

  [ "$status" -eq 1 ]
}
