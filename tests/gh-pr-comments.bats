#!/usr/bin/env bats
# Tests for scripts/gh-pr-comments.sh using a PATH-shimmed fake `gh`.
# JSON responses are loaded from tests/fixtures/gh-pr-comments/.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
SCRIPT="$SCRIPTS_DIR/gh-pr-comments.sh"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/gh-pr-comments" && pwd)"

# Fake gh binary: exits non-zero to simulate API failure.
FAKE_GH_FAIL='#!/usr/bin/env bash
echo "error: API call failed" >&2
exit 1'

setup() {
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$FAKE_BIN"

  # Ensure jq is available (skip if not installed).
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not on PATH"
  fi

  export PATH="$FAKE_BIN:$PATH"
}

write_fake_gh_fixture() {
  local fixture_file="$1"
  cat > "$FAKE_BIN/gh" <<SCRIPT
#!/usr/bin/env bash
cat "$fixture_file"
SCRIPT
  chmod +x "$FAKE_BIN/gh"
}

write_fake_gh_fail() {
  printf '%s\n' "$FAKE_GH_FAIL" > "$FAKE_BIN/gh"
  chmod +x "$FAKE_BIN/gh"
}

# ── existing inline-thread tests (must stay passing without modification) ─────

@test "gh-pr-comments: exits 0 and prints unresolved thread with path:line" {
  write_fake_gh_fixture "$FIXTURES_DIR/unresolved.json"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"src/foo.ts:42"* ]]
}

@test "gh-pr-comments: output contains @author formatting" {
  write_fake_gh_fixture "$FIXTURES_DIR/unresolved.json"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"@reviewer1:"* ]]
}

@test "gh-pr-comments: resolved threads are not printed" {
  write_fake_gh_fixture "$FIXTURES_DIR/resolved.json"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" != *"src/bar.ts"* ]]
}

@test "gh-pr-comments: exits 1 when gh exits non-zero" {
  write_fake_gh_fail

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -ne 0 ]
}

@test "gh-pr-comments: exits 2 when no PR number given" {
  write_fake_gh_fixture "$FIXTURES_DIR/unresolved.json"

  run "$SCRIPT"

  [ "$status" -eq 2 ]
}

# ── INLINE prefix ─────────────────────────────────────────────────────────────

@test "gh-pr-comments: unresolved inline thread has INLINE prefix" {
  write_fake_gh_fixture "$FIXTURES_DIR/unresolved.json"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"INLINE src/foo.ts:42"* ]]
}

# ── REVIEW SUMMARY ────────────────────────────────────────────────────────────

@test "gh-pr-comments: REQUEST_CHANGES review emits REVIEW SUMMARY block" {
  write_fake_gh_fixture "$FIXTURES_DIR/review-summary.json"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW SUMMARY @reviewer2 (REQUEST_CHANGES)"* ]]
  [[ "$output" == *"Please fix the auth handling."* ]]
}

@test "gh-pr-comments: APPROVED review with empty body is not printed" {
  # unresolved.json has reviews.nodes = [] — this verifies the filter path.
  # Construct a fixture with an APPROVED review that has an empty body.
  local fixture="$BATS_TEST_TMPDIR/approved-empty.json"
  cat > "$fixture" <<'JSON'
{
  "data": { "repository": { "pullRequest": {
    "reviewThreads": { "nodes": [], "pageInfo": { "hasNextPage": false, "endCursor": null } },
    "reviews": {
      "nodes": [ { "author": { "login": "approver" }, "body": "", "state": "APPROVED" } ],
      "pageInfo": { "hasNextPage": false, "endCursor": null }
    },
    "comments": { "nodes": [], "pageInfo": { "hasNextPage": false, "endCursor": null } }
  } } }
}
JSON
  write_fake_gh_fixture "$fixture"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" != *"REVIEW SUMMARY"* ]]
}

# ── PR COMMENT ────────────────────────────────────────────────────────────────

@test "gh-pr-comments: PR-level comment emits PR COMMENT block" {
  write_fake_gh_fixture "$FIXTURES_DIR/pr-comment.json"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR COMMENT @commenter1"* ]]
  [[ "$output" == *"This needs more tests."* ]]
}

# ── mixed output ──────────────────────────────────────────────────────────────

@test "gh-pr-comments: mixed fixture emits all three block types" {
  write_fake_gh_fixture "$FIXTURES_DIR/mixed.json"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"INLINE src/mixed.ts:7"* ]]
  [[ "$output" == *"REVIEW SUMMARY @reviewer2 (REQUEST_CHANGES)"* ]]
  [[ "$output" == *"PR COMMENT @commenter3"* ]]
}

# ── pagination ────────────────────────────────────────────────────────────────

@test "gh-pr-comments: pagination follows hasNextPage across reviewThreads" {
  local page1="$FIXTURES_DIR/paginated-page1.json"
  local page2="$FIXTURES_DIR/paginated-page2.json"
  # Serve page2 when an `after=` cursor arg is present; otherwise page1.
  cat > "$FAKE_BIN/gh" <<SCRIPT
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == after=* ]]; then
    cat "$page2"
    exit 0
  fi
done
cat "$page1"
SCRIPT
  chmod +x "$FAKE_BIN/gh"

  run "$SCRIPT" 123 --repo owner/repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"INLINE src/page1.ts:1"* ]]
  [[ "$output" == *"INLINE src/page2.ts:2"* ]]
}
