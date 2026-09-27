#!/usr/bin/env bash
#
# Run the test suite under Bisect_ppx and fail when the aggregate line
# coverage drops below COVERAGE_MIN (default: 90).
#
# Usage:
#   contrib/check-coverage.sh
#   COVERAGE_MIN=80 contrib/check-coverage.sh
#
# The privileged (agent-spawning) tests need root and are skipped by default;
# the unprivileged subset measures somewhat lower.  Unprivileged runners can
# lower COVERAGE_MIN (the GitLab job does), while the privileged Forgejo
# runner enforces the 90% default.
#
# Set COVERAGE_REPORT_FILE to also write a Markdown report (used by the PR
# comment step).

set -euo pipefail

cd "$(dirname "$0")/.."

MIN="${COVERAGE_MIN:-90}"

if ! command -v bisect-ppx-report >/dev/null 2>&1; then
  echo "bisect-ppx-report not found; install the coverage tool with:" >&2
  echo "  opam install bisect_ppx_ng" >&2
  exit 1
fi

# Agent-spawning tests need root; keep coverage runs unprivileged by default.
export AAAU_SKIP_PRIVILEGED_TESTS="${AAAU_SKIP_PRIVILEGED_TESTS:-1}"

# Drop counters from previous runs so the report reflects this invocation.
find . -name '*.coverage' -delete 2>/dev/null || true

dune runtest --instrument-with bisect_ppx_ng --force

summary="$(bisect-ppx-report summary)"
printf '%s\n' "$summary"
per_file="$(bisect-ppx-report summary --per-file)"
printf '%s\n' "$per_file"

percentage="$(printf '%s\n' "$summary" \
  | sed -n 's/.*(\([0-9][0-9.]*\)%).*/\1/p' \
  | tail -n 1)"
counts="$(printf '%s\n' "$summary" | grep -oE '[0-9]+/[0-9]+' | tail -n 1)"
if [ -z "$counts" ]; then
  counts="0/0"
fi
covered="${counts%%/*}"
total="${counts##*/}"

if [ -z "$percentage" ]; then
  echo "Could not parse a coverage percentage from: $summary" >&2
  exit 1
fi

echo "Coverage: ${percentage}% (minimum ${MIN}%)"

# Optionally write a Markdown report for the PR comment step.
if [ -n "${COVERAGE_REPORT_FILE:-}" ]; then
  files="$(printf '%s\n' "$per_file" | awk '$NF ~ /\.ml$/' | wc -l | tr -d ' ')"
  meets="✅ meets the ${MIN}% line-coverage threshold"
  if ! awk -v actual="$percentage" -v minimum="$MIN" \
       'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
    meets="❌ below the ${MIN}% line-coverage threshold"
  fi
  {
    echo "## Test coverage"
    echo
    echo "**Lines: ${percentage}%** (${counts}) — ${meets}"
    echo
    echo "| Metric | Coverage | Covered / Total |"
    echo "| --- | ---: | ---: |"
    echo "| Lines | ${percentage}% | ${covered} / ${total} |"
    echo
    echo "<details>"
    echo "<summary>Per-file breakdown (${files} files)</summary>"
    echo
    echo "| File | Lines |"
    echo "| --- | ---: |"
    printf '%s\n' "$per_file" \
      | awk '$NF ~ /\.ml$/ { printf "| `%s` | %s%% (%s) |\n", $NF, $1, $3 }'
    echo
    echo "</details>"
  } > "$COVERAGE_REPORT_FILE"
  echo "Wrote coverage report to $COVERAGE_REPORT_FILE"
fi

if awk -v actual="$percentage" -v minimum="$MIN" \
     'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
  echo "Coverage check passed."
else
  echo "Coverage ${percentage}% is below the required ${MIN}%." >&2
  exit 1
fi
