#!/usr/bin/env bats
source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  PLUGIN="$BATS_TEST_TMPDIR/plugin checkout"
  PREFIX="$BATS_TEST_TMPDIR/plugin bin"
  mkdir -p "$PLUGIN/scripts"
  PLUGIN="$(cd -P "$PLUGIN" && pwd)"
  cp "$REPO_ROOT/examples/backend-plugin/Makefile" "$PLUGIN/"
  printf '#!/bin/sh\nprintf "acme-local\\n"\n' > "$PLUGIN/scripts/paw-backend-acme"
  chmod +x "$PLUGIN/scripts/paw-backend-acme"
}

@test "plugin template: default/custom install and repeat uninstall from paths with spaces" {
  make -C "$PLUGIN" help
  make -C "$PLUGIN" install "HOME=$BATS_TEST_TMPDIR/home"
  [ -L "$BATS_TEST_TMPDIR/home/bin/paw-backend-acme" ]
  make -C "$PLUGIN" install "PREFIX=$PREFIX"
  make -C "$PLUGIN" install "PREFIX=$PREFIX"
  [ "$(readlink "$PREFIX/paw-backend-acme")" = "$PLUGIN/scripts/paw-backend-acme" ]
  run "$PREFIX/paw-backend-acme" display-model
  [ "$status" -eq 0 ]
  [ "$output" = acme-local ]
  make -C "$PLUGIN" uninstall "PREFIX=$PREFIX"
  make -C "$PLUGIN" uninstall "PREFIX=$PREFIX"
  [ ! -L "$PREFIX/paw-backend-acme" ]
}

@test "plugin template: custom identity/source and owned dangling uninstall" {
  mv "$PLUGIN/scripts/paw-backend-acme" "$PLUGIN/adapter source"
  make -C "$PLUGIN" install "PREFIX=$PREFIX" PLUGIN_NAME=paw-backend-other 'PLUGIN_SOURCE=adapter source'
  [ "$(readlink "$PREFIX/paw-backend-other")" = "$PLUGIN/adapter source" ]
  rm "$PLUGIN/adapter source"
  make -C "$PLUGIN" uninstall "PREFIX=$PREFIX" PLUGIN_NAME=paw-backend-other 'PLUGIN_SOURCE=adapter source'
  [ ! -L "$PREFIX/paw-backend-other" ]
  run make -C "$PLUGIN" install "PREFIX=$PREFIX" PLUGIN_NAME=../escape
  [ "$status" -ne 0 ]
}

@test "plugin template: conflicts and invalid sources are preserved" {
  local kind action dest="$PREFIX/paw-backend-acme"
  mkdir -p "$PREFIX" "$BATS_TEST_TMPDIR/foreign"
  for kind in file directory link dangling; do
    case "$kind" in
      file) printf keep > "$dest";;
      directory) mkdir "$dest";;
      link) ln -s "$BATS_TEST_TMPDIR/foreign" "$dest";;
      dangling) ln -s "$BATS_TEST_TMPDIR/missing" "$dest";;
    esac
    for action in install uninstall; do
      run make -C "$PLUGIN" "$action" "PREFIX=$PREFIX"
      [ "$status" -ne 0 ]
      [[ "$output" == *"$dest"*"inspect"* ]]
      [ -e "$dest" ] || [ -L "$dest" ]
    done
    if [ "$kind" = directory ]; then rmdir "$dest"; else rm "$dest"; fi
  done
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/foreign")" ]
  chmod -x "$PLUGIN/scripts/paw-backend-acme"
  run make -C "$PLUGIN" install "PREFIX=$PREFIX"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not executable"* ]]
  rm "$PLUGIN/scripts/paw-backend-acme"
  run make -C "$PLUGIN" install "PREFIX=$PREFIX"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing"* ]]
  [ ! -L "$dest" ]
}

install_seam() {
  cp "$REPO_ROOT/tests/fixtures/backend-plugins/paw-backend-fixture-plugin" "$PLUGIN/scripts/adapter"
  # This test adapter resolves its own source before reading a sibling resource.
  cat > "$PLUGIN/scripts/paw-backend-acme" <<'SH'
#!/usr/bin/env bash
set -eu
source_path="${BASH_SOURCE[0]}"
while [ -L "$source_path" ]; do
  source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
  target="$(readlink "$source_path")"
  case "$target" in /*) source_path="$target";; *) source_path="$source_dir/$target";; esac
done
source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
if [ "${1:-}" = display-model ]; then
  [ "${NO_OPTIONAL:-0}" != 1 ] || exit 2
  cat "$source_dir/model.txt"
elif [ "${1:-}" = usage-banner ]; then
  exit 2
else
  "$source_dir/adapter" "$@"
  exit "${PLUGIN_EXIT:-0}"
fi
SH
  printf 'sibling-resource-model\n' > "$PLUGIN/scripts/model.txt"
  chmod +x "$PLUGIN/scripts/adapter" "$PLUGIN/scripts/paw-backend-acme"
  make -C "$PLUGIN" install "PREFIX=$PREFIX"
  make -C "$REPO_ROOT" install "PREFIX=$PREFIX"
  mkdir -p "$BATS_TEST_TMPDIR/third repo/.agent/plugin-task"
  cp "$REPO_ROOT/tests/fixtures/sample-task-valid/plan.md" "$BATS_TEST_TMPDIR/third repo/.agent/plugin-task/plan.md"
  export HOME="$BATS_TEST_TMPDIR/home" PAW_TASK_HOME="$BATS_TEST_TMPDIR/task store"
  export PATH="$PREFIX:$PATH" PAW_BACKEND=acme
  unset PAW_HOME
  cd "$BATS_TEST_TMPDIR/third repo"
}

@test "installed PAW: symlinked plugin resolves siblings and captures/streams from third directory" {
  install_seam
  run paw model -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend:   acme"*"sibling-resource-model"* ]]
  run paw implement plugin-task
  [ "$status" -eq 0 ]
  [[ "$output" == *fixture-plugin-ok* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/fixture-plugin.prompt")" == *PAW:IMPLEMENT* ]]
  run env PAW_STREAM=1 paw implement plugin-task
  [ "$status" -eq 0 ]
  [[ "$output" == *'[fixture-plugin stream output]'* ]]
  # Direct protocol seam also verifies quoted output/argument paths.
  run paw-backend-acme run-capture "$BATS_TEST_TMPDIR/output file.json" 'prompt with spaces'
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fixture-plugin.prompt")" = 'prompt with spaces' ]
  [ "$(jq -r .result "$BATS_TEST_TMPDIR/output file.json")" = fixture-plugin-ok ]
  ln -s paw-backend-acme "$PREFIX/relative-plugin"
  ln -s "$PREFIX/relative-plugin" "$PREFIX/chained-plugin"
  run "$PREFIX/chained-plugin" display-model
  [ "$status" -eq 0 ]
  [ "$output" = sibling-resource-model ]
}

@test "installed PAW: plugin failure, optional fallback, missing mode and builtin precedence" {
  install_seam
  run env PLUGIN_EXIT=7 paw implement plugin-task
  [ "$status" -eq 7 ]
  run env PLUGIN_EXIT=7 PAW_STREAM=1 paw implement plugin-task
  [ "$status" -eq 7 ]
  run env NO_OPTIONAL=1 PAW_MODEL=fallback-model paw model
  [ "$status" -eq 0 ]
  [[ "$output" == *fallback-model* ]]
  [[ "$output" != *sibling-resource-model* ]]
  ln -s "$PLUGIN/scripts/paw-backend-acme" "$PREFIX/paw-backend-stub"
  run env PAW_BACKEND=stub paw model
  [ "$status" -eq 0 ]
  [[ "$output" != *sibling-resource-model* ]]
  chmod -x "$PLUGIN/scripts/paw-backend-acme"
  run paw model
  [ "$status" -ne 0 ]
  [[ "$output" == *paw-backend-acme*'on PATH'* ]]
  rm "$PLUGIN/scripts/paw-backend-acme"
  run paw model
  [ "$status" -ne 0 ]
  [[ "$output" == *paw-backend-acme*'on PATH'* ]]
}
