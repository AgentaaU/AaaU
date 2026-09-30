#!/bin/sh
set -eu
server="$1"
work=$(mktemp -d)
name="aaau_test_$$"
created=false
cleanup() {
  if [ "$created" = true ]; then
    loginctl disable-linger "$name" >/dev/null 2>&1 || true
    userdel "$name"
    if getent group "$name" >/dev/null; then groupdel "$name"; fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
expect_failure() {
  pattern="$1"
  shift
  if "$server" create-user "$@" >"$work/output" 2>&1; then
    echo "Unexpected success: $*" >&2
    exit 1
  fi
  grep -F -- "$pattern" "$work/output"
}
"$server" create-user --help=plain >"$work/help"
grep -F -- '--name=USER' "$work/help"
expect_failure "required"
if [ "$(id -u)" != 0 ]; then
  expect_failure "Need root permission" --name "$name"
  echo 'PASS: CLI checks (account creation requires root)'
  exit 0
fi
# A failing useradd must stop provisioning and report a normal failure.
mkdir "$work/tools"
printf '#!/bin/sh\nexit 1\n' >"$work/tools/useradd"
chmod +x "$work/tools/useradd"
PATH="$work/tools:$PATH" expect_failure "Failed to create user" --name "$name" --home "$work/home"
# Exercise real account creation; keep its home inside the temporary directory.
created=true
"$server" create-user --name "$name" --home "$work/home"
[ "$(stat -c %a "$work/home")" = 700 ]
[ "$(stat -c %u "$work/home")" = "$(id -u "$name")" ]
[ "$(stat -c %g "$work/home")" = "$(id -g "$name")" ]
[ "$(id -gn "$name")" = "$name" ]
[ "$(id -Gn "$name")" = "$name" ]
[ "$(getent passwd "$name" | cut -d: -f7)" = /bin/false ]
[ "$(getent shadow "$name" | cut -d: -f2)" = '!' ]
# Re-running either command must enforce the same home and group isolation.
chmod 755 "$work/home"
"$server" create-user --name "$name" --home "$work/other"
[ "$(stat -c %a "$work/home")" = 700 ]
[ ! -e "$work/other" ]
chmod 755 "$work/home"
"$server" init --user "$name" --home "$work/other" --group "$name" \
  --socket "$work/socket/server.sock" --log-dir "$work/log" >"$work/init-output" 2>&1 && exit 1
# The account's own group cannot also be the human control group.
grep -F 'agent primary group must differ' "$work/init-output"
[ "$(stat -c %a "$work/home")" = 700 ]
echo 'PASS: shared account provisioning and existing-account behavior'
