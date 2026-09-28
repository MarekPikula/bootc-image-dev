#!/usr/bin/bash
# Runs inside the image (tests/image/checks.sh feeds it on stdin), after
# systemd-sysusers has created the accounts. Starts a system bus and polkitd,
# then asks polkit about every registered action:
#   - dev gets NO for all of them (never "challenge", which would mean an admin
#     prompt). The subjects here have no login session, like a background
#     service, so even 00-android-dev.rules' allowlist must say NO. That
#     allowlist needs dev's active desktop session and is checked by hand.
#   - controls: admin gets an implicit YES that dev is denied, and root gets
#     YES, so the NOs come from our rule and not from a broken setup.
# Prints mismatches and exits non-zero if there are any.
set -euo pipefail

mkdir -p /run/dbus
dbus-daemon --system --fork
/usr/lib/polkit-1/polkitd --no-debug &
gdbus wait --system --timeout 5 org.freedesktop.PolicyKit1 ||
  { echo "      polkitd did not start"; exit 1; }

# Subjects are system-bus connections held open as each user: polkitd takes
# their UID from the bus daemon. (Process subjects would need /proc, which
# isn't reliable in nested containers.)
subjects=(dev admin root)
for user in "${subjects[@]}"; do
  setpriv --reuid="$user" --regid="$user" --init-groups \
    gdbus monitor --system --dest org.freedesktop.DBus >/dev/null 2>&1 &
done

# Map bus names to users until every subject is connected. The first match
# wins, so busctl's own short-lived connection (listed last) is never used.
declare -A bus_name
all_connected() {
  local user
  for user in "${subjects[@]}"; do
    [[ -n ${bus_name[$user]:-} ]] || return 1
  done
}
for _ in {1..100}; do
  for name in $(busctl --system list --no-legend --unique | cut -d' ' -f1); do
    uid="$(busctl --system call org.freedesktop.DBus / org.freedesktop.DBus \
      GetConnectionUnixUser s "$name" 2>/dev/null | cut -d' ' -f2)" || continue
    user="$(id -nu "$uid")"
    [[ -n ${bus_name[$user]:-} ]] || bus_name[$user]=$name
  done
  all_connected && break
  sleep 0.05
done
all_connected || { echo "      subjects not all on the bus: ${!bus_name[*]}"; exit 1; }

# pkcheck exit codes: 0 authorized, 1 not authorized, 2 challenge.
result() {
  local rc=0
  pkcheck --action-id "$2" --system-bus-name "${bus_name[$1]}" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) echo YES ;;
    1) echo NO ;;
    2) echo CHALLENGE ;;
    *) echo "ERROR($rc)" ;;
  esac
}

bad=0
expect() {
  local actual
  actual="$(result "$1" "$2")"
  if [[ $actual != "$3" ]]; then
    echo "      $1 $2: $actual, expected $3"
    bad=1
  fi
}

mapfile -t actions < <(pkaction)
((${#actions[@]} > 100)) || { echo "      only ${#actions[@]} polkit actions registered"; exit 1; }
for action in "${actions[@]}"; do
  expect dev "$action" NO
done
expect admin org.freedesktop.login1.set-self-linger YES
expect root org.freedesktop.systemd1.manage-units YES

echo "      checked ${#actions[@]} actions for dev"
exit "$bad"
