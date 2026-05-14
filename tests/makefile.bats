#!/usr/bin/env bats
# Smoke tests for the repo Makefile.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "make help: exits 0" {
  run make -C "$REPO_ROOT" help

  [ "$status" -eq 0 ]
}

@test "make help: lists every documented target" {
  run make -C "$REPO_ROOT" help

  [ "$status" -eq 0 ]
  [[ "$output" == *"install"* ]]
  [[ "$output" == *"uninstall"* ]]
  [[ "$output" == *"test"* ]]
  [[ "$output" == *"lint"* ]]
  [[ "$output" == *"shellcheck"* ]]
  [[ "$output" == *"check"* ]]
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"ci-deps"* ]]
}

@test "make -n test: recipe mentions bats tests/" {
  run make -C "$REPO_ROOT" -n test

  [ "$status" -eq 0 ]
  [[ "$output" == *"bats tests/"* ]]
}

@test "make -n lint: recipe mentions lint-task.sh" {
  run make -C "$REPO_ROOT" -n lint

  [ "$status" -eq 0 ]
  [[ "$output" == *"lint-task.sh"* ]]
}

@test "make -n shellcheck: recipe mentions shellcheck" {
  run make -C "$REPO_ROOT" -n shellcheck

  [ "$status" -eq 0 ]
  [[ "$output" == *"shellcheck"* ]]
}

@test "make install: creates symlink at PREFIX/paw" {
  local prefix="$BATS_TEST_TMPDIR/prefix"
  mkdir -p "$prefix"

  run make -C "$REPO_ROOT" install "PREFIX=$prefix"

  [ "$status" -eq 0 ]
  [ -L "$prefix/paw" ]
}

@test "make install: symlink points to scripts/paw" {
  local prefix="$BATS_TEST_TMPDIR/prefix-target"
  mkdir -p "$prefix"

  make -C "$REPO_ROOT" install "PREFIX=$prefix"

  local target
  target="$(readlink "$prefix/paw")"
  [[ "$target" == *"scripts/paw" ]]
}

@test "make install: is idempotent (second call succeeds)" {
  local prefix="$BATS_TEST_TMPDIR/prefix-idem"
  mkdir -p "$prefix"

  make -C "$REPO_ROOT" install "PREFIX=$prefix"
  run make -C "$REPO_ROOT" install "PREFIX=$prefix"

  [ "$status" -eq 0 ]
  [ -L "$prefix/paw" ]
}

@test "make uninstall: removes the symlink" {
  local prefix="$BATS_TEST_TMPDIR/prefix-uninst"
  mkdir -p "$prefix"

  make -C "$REPO_ROOT" install "PREFIX=$prefix"
  run make -C "$REPO_ROOT" uninstall "PREFIX=$prefix"

  [ "$status" -eq 0 ]
  [ ! -e "$prefix/paw" ]
}
