#!/bin/sh
# Regression: the installed bridge must be able to host more than one UID.
set -eu
unit="$1"
value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2) }' "$unit"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

[ "$(value User)" = root ] || fail 'managed bridge cannot switch agent UIDs'
[ "$(value Group)" = root ] || fail 'managed bridge must not retain an agent group'
[ "$(value NoNewPrivileges)" = true ] || fail 'agents could gain privileges through exec'
caps=" $(value CapabilityBoundingSet) "
for cap in CAP_SETUID CAP_SETGID CAP_CHOWN CAP_FOWNER CAP_DAC_OVERRIDE CAP_KILL; do
  case "$caps" in
    *" $cap "*) ;;
    *) fail "bridge lacks $cap for account switching and session lifecycle" ;;
  esac
done
[ -z "$(value AmbientCapabilities)" ] || fail 'capabilities could survive agent exec'
case " $(value ReadWritePaths) " in
  *' /home '*) ;;
  *) fail 'additional agent homes remain read-only' ;;
esac
[ -z "$(value SupplementaryGroups)" ] || fail 'bridge retains unnecessary supplementary groups'
echo 'PASS: managed service supports isolated per-session users'
