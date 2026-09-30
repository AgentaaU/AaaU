#!/bin/sh
# Exercise the client `--user` option without a running server.
set -eu
client="$1"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

"$client" --help=plain >"$work/help"
grep -F -- '--user=USER' "$work/help"
# The documented default keeps the historical `agent` account.
grep -F -- 'absent=agent' "$work/help"

# A named account is accepted and the connection failure is reported cleanly
# (no argument-parsing error).
if "$client" -s "$work/missing.sock" --user researcher >"$work/out" 2>&1; then
  echo "Unexpected success connecting to a missing socket" >&2
  exit 1
fi
grep -F -- 'Cannot connect to AaaU server' "$work/out"
echo 'PASS: client --user option'
