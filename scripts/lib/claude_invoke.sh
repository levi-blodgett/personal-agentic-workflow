#!/usr/bin/env bash
# claude_invoke.sh — backwards-compatibility shim.
#
# The implementation has moved to backends/claude.sh.  Source this file for
# the old function names (claude_run_capture, claude_run_stream,
# parse_usage_tokens, parse_stream_usage_tokens), which are now aliases.

_shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_shim_dir/backends/claude.sh"
unset _shim_dir
