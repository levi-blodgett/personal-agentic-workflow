#!/usr/bin/env bats
# Tests for the shell-driven GitHub Actions review command in scripts/paw.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
PAW="$SCRIPTS_DIR/paw"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.agent"

  SHIM_DIR="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM_DIR"

  export PATH="$SHIM_DIR:$PATH"
  export PAW_HOME="$(cd "$SCRIPTS_DIR/.." && pwd)"
  export PAW_BACKEND=stub

  cd "$REPO"
}

write_fake_review_cmd() {
  local script="$BATS_TEST_TMPDIR/fake-gh-actions-review.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/gh-actions-review.args"
echo "state: undocumented"
EOF
  chmod +x "$script"
  printf '%s\n' "$script"
}

@test "paw gh-actions-review: invokes helper without create flag by default" {
  local review_cmd
  review_cmd=$(write_fake_review_cmd)

  PAW_GH_ACTIONS_REVIEW_CMD="$review_cmd" run "$PAW" gh-actions-review

  [ "$status" -eq 0 ]
  [[ "$output" == *"state: undocumented"* ]]
  [[ ! -s "$BATS_TEST_TMPDIR/gh-actions-review.args" || -z "$(tr -d '\n' < "$BATS_TEST_TMPDIR/gh-actions-review.args")" ]]
}

@test "paw gh-actions-review: forwards the explicit create flag to the helper" {
  local review_cmd
  review_cmd=$(write_fake_review_cmd)

  PAW_GH_ACTIONS_REVIEW_CMD="$review_cmd" run "$PAW" gh-actions-review --create-issue

  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/gh-actions-review.args")" == *"--create-issue"* ]]
}
