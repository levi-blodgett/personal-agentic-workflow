#!/usr/bin/env bash
# Conservative checkout-owned launcher installation; PREFIX is an executable dir.
set -euo pipefail

action="${1:?expected install or uninstall}"
prefix="${2:?expected executable directory}"
root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_path="$root/scripts/paw"
destination="$prefix/paw"

refuse() {
  printf 'error: %s: %s; inspect the destination and remove it manually if appropriate, then reinstall\n' "$destination" "$1" >&2
  exit 1
}

case "$action" in
  install)
    [[ -f "$source_path" && -x "$source_path" ]] || refuse "source '$source_path' is missing or not executable"
    ;;
  uninstall) ;;
  *) printf 'error: unknown install action: %s\n' "$action" >&2; exit 2 ;;
esac

if [[ -L "$destination" ]] && [[ "$(readlink "$destination")" == "$source_path" ]]; then
  [[ ! -d "$destination" ]] || refuse 'destination points to a directory'
  if [[ "$action" == uninstall ]]; then rm -- "$destination"; fi
elif [[ -e "$destination" || -L "$destination" ]]; then
  refuse 'destination is not the link owned by this checkout'
elif [[ "$action" == install ]]; then
  mkdir -p -- "$prefix"
  ln -s -- "$source_path" "$destination"
fi
