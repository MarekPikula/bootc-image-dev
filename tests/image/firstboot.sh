#!/usr/bin/bash
# Runs in a throwaway container of the image (tests/image/checks.sh mounts this
# directory at /tests), with typed input on stdin. Drives the first-boot
# password prompt, then checks the result:
#   firstboot.sh sets          the input has bad passwords first, then good ones
#   firstboot.sh dev-only PW   admin's password is PW already, and the input
#                              tries it for dev first
#   firstboot.sh gives-up      the input never has a valid password
set -uo pipefail

systemd-sysusers >/dev/null 2>&1
[[ $1 != dev-only ]] || printf 'admin:%s\n' "$2" | chpasswd
state="$(mktemp -d)"
STATE_DIRECTORY=$state /usr/libexec/android-dev-vm/set-passwords >/tmp/out 2>&1
rc=$?

bad=0
fail() {
  echo "      $*"
  bad=1
}

case $1 in
  sets)
    ((rc == 0)) || fail "exit $rc"
    for msg in "BAD PASSWORD" "The passwords don't match." \
      "Use a different password from admin's."; do
      grep -qF "$msg" /tmp/out || fail "never said: $msg"
    done
    for user in admin dev; do
      [[ "$(getent shadow "$user" | cut -d: -f2)" == \$* ]] || fail "$user has no password"
      [[ -d /var/home/$user ]] || fail "no home for $user"
    done
    [[ -e $state/firstboot.done ]] || fail "not marked done"
    ;;
  dev-only)
    ((rc == 0)) || fail "exit $rc"
    grep -qF "Use a different password from admin's." /tmp/out || fail "took admin's password for dev"
    ! grep -qF "password for admin" /tmp/out || fail "asked for admin's password again"
    [[ "$(getent shadow dev | cut -d: -f2)" == \$* ]] || fail "dev has no password"
    [[ -e $state/firstboot.done ]] || fail "not marked done"
    ;;
  gives-up)
    ((rc != 0)) || fail "exit 0 although no password was typed"
    [[ ! -e $state/firstboot.done ]] || fail "marked done, so it would never ask again"
    ;;
  *)
    fail "unknown mode: $1"
    ;;
esac

((bad == 0)) || sed 's/^/        /' /tmp/out
exit "$bad"
