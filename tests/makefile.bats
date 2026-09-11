#!/usr/bin/env bats
# Smoke tests for the repo Makefile.

# shellcheck source=helpers/hermetic.bash
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures" && pwd)"

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

@test "make install: installed paw help succeeds" {
  local prefix="$BATS_TEST_TMPDIR/prefix-help"
  mkdir -p "$prefix"

  make -C "$REPO_ROOT" install "PREFIX=$prefix"

  run "$prefix/paw" help

  [ "$status" -eq 0 ]
  [[ "$output" == *"paw — personal-agentic-workflow CLI wrapper."* ]]
}

@test "make install: installed paw still resolves external backend plugins on PATH" {
  local prefix="$BATS_TEST_TMPDIR/prefix-plugin"
  local shim_dir="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$prefix" "$shim_dir"

  cp "$FIXTURES_DIR/backend-plugins/paw-backend-fixture-plugin" \
     "$shim_dir/paw-backend-fixture-plugin"
  chmod +x "$shim_dir/paw-backend-fixture-plugin"

  make -C "$REPO_ROOT" install "PREFIX=$prefix"

  run env PATH="$shim_dir:$PATH" \
    PAW_BACKEND=fixture-plugin \
    PAW_FIXTURE_PLUGIN_MODEL=fixture-installed-model \
    "$prefix/paw" model -v

  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:   fixture-plugin"* ]]
  [[ "$output" == *"fixture-installed-model"* ]]
}

@test "make uninstall: removes the symlink" {
  local prefix="$BATS_TEST_TMPDIR/prefix-uninst"
  mkdir -p "$prefix"

  make -C "$REPO_ROOT" install "PREFIX=$prefix"
  run make -C "$REPO_ROOT" uninstall "PREFIX=$prefix"

  [ "$status" -eq 0 ]
  [ ! -e "$prefix/paw" ]
}

@test "make uninstall: is idempotent when paw is already absent" {
  local prefix="$BATS_TEST_TMPDIR/prefix-uninst-idem"
  mkdir -p "$prefix"

  make -C "$REPO_ROOT" install "PREFIX=$prefix"
  make -C "$REPO_ROOT" uninstall "PREFIX=$prefix"

  run make -C "$REPO_ROOT" uninstall "PREFIX=$prefix"

  [ "$status" -eq 0 ]
  [ ! -e "$prefix/paw" ]
}

@test "make help: PREFIX is the executable directory" {
  run make -C "$REPO_ROOT" help
  [ "$status" -eq 0 ]
  [[ "$output" != *"PREFIX/bin"* ]]
}

@test "make install: default HOME/bin works from another directory without PAW_HOME" {
  make -C "$REPO_ROOT" install "HOME=$BATS_TEST_TMPDIR/home"
  cd "$BATS_TEST_TMPDIR"
  run env -u PAW_HOME PAW_BACKEND=stub "$BATS_TEST_TMPDIR/home/bin/paw" model
  [ "$status" -eq 0 ]
}

@test "make install and uninstall: preserve every foreign destination" {
  local kind action prefix="$BATS_TEST_TMPDIR/conflicts"
  mkdir -p "$prefix" "$BATS_TEST_TMPDIR/foreign-dir"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/foreign-file"
  for kind in file directory file-link directory-link dangling-link; do
    case "$kind" in
      file) cp "$BATS_TEST_TMPDIR/foreign-file" "$prefix/paw" ;;
      directory) mkdir "$prefix/paw" ;;
      file-link) ln -s "$BATS_TEST_TMPDIR/foreign-file" "$prefix/paw" ;;
      directory-link) ln -s "$BATS_TEST_TMPDIR/foreign-dir" "$prefix/paw" ;;
      dangling-link) ln -s "$BATS_TEST_TMPDIR/missing" "$prefix/paw" ;;
    esac
    for action in install uninstall; do
      run make -C "$REPO_ROOT" "$action" "PREFIX=$prefix"
      [ "$status" -ne 0 ]
      [[ "$output" == *"$prefix/paw"* ]]
      [[ "$output" == *"inspect"* ]]
      [ -e "$prefix/paw" ] || [ -L "$prefix/paw" ]
    done
    if [ "$kind" = directory ]; then rmdir "$prefix/paw"; else rm "$prefix/paw"; fi
  done
  [ "$(cat "$BATS_TEST_TMPDIR/foreign-file")" = keep ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/foreign-dir")" ]
}

@test "make install: spaces, launcher chains, moved checkout, and owned dangling uninstall" {
  local checkout="$BATS_TEST_TMPDIR/checkout space" prefix="$BATS_TEST_TMPDIR/bin space"
  mkdir -p "$checkout"
  checkout="$(cd -P "$checkout" && pwd)"
  cp "$REPO_ROOT/Makefile" "$checkout/"
  cp -R "$REPO_ROOT/scripts" "$checkout/"
  make -C "$checkout" install "PREFIX=$prefix"
  [ "$(readlink "$prefix/paw")" = "$checkout/scripts/paw" ]
  ln -s paw "$prefix/relative"
  ln -s "$prefix/relative" "$prefix/chain"
  cd "$BATS_TEST_TMPDIR"
  run env -u PAW_HOME PAW_BACKEND=stub "$prefix/chain" help
  [ "$status" -eq 0 ]
  run env -u PAW_HOME PAW_BACKEND=stub "$prefix/chain" model
  [ "$status" -eq 0 ]
  mv "$checkout" "$checkout moved"
  run make -C "$checkout moved" install "PREFIX=$prefix"
  [ "$status" -ne 0 ]
  [ "$(readlink "$prefix/paw")" = "$checkout/scripts/paw" ]
  rm "$prefix/paw" # explicit operator repair after inspection
  make -C "$checkout moved" install "PREFIX=$prefix"
  rm "$checkout moved/scripts/paw"
  make -C "$checkout moved" uninstall "PREFIX=$prefix"
  [ ! -L "$prefix/paw" ]
}

@test "make install: missing and non-executable source preserve the destination" {
  local checkout="$BATS_TEST_TMPDIR/source" prefix="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$checkout/scripts"
  cp "$REPO_ROOT/Makefile" "$checkout/"
  cp "$REPO_ROOT/scripts/install-paw.sh" "$checkout/scripts/"
  for mode in missing non-executable; do
    if [ "$mode" = non-executable ]; then printf '#!/bin/sh\n' > "$checkout/scripts/paw"; fi
    run make -C "$checkout" install "PREFIX=$prefix"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$checkout/scripts/paw"* ]]
    [[ "$output" == *"not executable"* ]]
    [ ! -e "$prefix" ]
  done
}
