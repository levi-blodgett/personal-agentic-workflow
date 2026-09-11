#!/usr/bin/env bash
# helpers/hermetic.bash — enforce a locale- and timezone-neutral environment
# for every bats test file that sources this helper.
#
# Source at the top of each *.bats file (before any @test blocks):
#   source "$(dirname "$BATS_TEST_FILENAME")/helpers/hermetic.bash"
#
# Guarantees:
#   - LC_ALL=C, LANG=C: awk arithmetic and string comparison are byte-order safe.
#   - TZ=UTC: date/timestamp output is deterministic.
#   - All PAW_* env vars are unset so tests start from a clean default state.

export LC_ALL=C
export LANG=C
export TZ=UTC

unset PAW_HOME PAW_MODEL PAW_MODEL_PLAN PAW_MODEL_NEW PAW_MODEL_CONTEXT \
      PAW_MODEL_EDIT PAW_MODEL_RUN PAW_MAX_TURNS PAW_STREAM \
      PAW_BACKEND PAW_LINT_LENGTH PAW_COMPACT_KEEP PAW_INSTRUCTIONS \
      PAW_GH_COMMENTS_CMD PAW_CODEX_DANGEROUS \
      PAW_STUB_MUTATE_FILE PAW_STUB_MUTATE_CONTENT \
      2>/dev/null || true
