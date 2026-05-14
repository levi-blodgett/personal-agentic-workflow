# Shared bats helper for exit-code assertions.
# Load with: load 'helpers/exit_code'

assert_exit_code() {
  local expected="$1"
  if [ "$status" -ne "$expected" ]; then
    echo "Expected exit code $expected but got $status" >&3
    return 1
  fi
}

assert_exits_2() {
  assert_exit_code 2
}
