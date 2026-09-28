# shellcheck shell=bash
# In-guest assertions, run as root by tests/vm/run-vm.sh (bash -s, after
# tests/lib.sh). Covers what the image checks can't: a real first boot under
# systemd and SELinux, and dev's privileges with real processes.

# Keep in sync with REGISTRY_IMAGE in .github/workflows/_build-test.yml.
registry_image=ghcr.io/marekpikula/bootc-image-dev:stable

# Runs a command as dev, with dev's groups and no stdin (so nothing can wait
# for a password), with a 30 s limit. Sets $out and $rc. rc 255 means setpriv
# itself failed (no dev account, no such command), so no check can mistake
# that for a denial. 124 means it hung.
as_dev() {
  rc=0
  out="$(timeout 30 setpriv --reuid=dev --regid=dev --init-groups "$@" </dev/null 2>&1)" || rc=$?
  [[ $out != setpriv:* ]] || rc=255
}

# Boot.
boot_finished() {
  local state
  state="$(systemctl is-system-running --wait)"
  [[ $state == running ]] || {
    echo "      state: $state"
    systemctl --failed --no-legend | indent
    return 1
  }
}
check "boot finished with no failed units" boot_finished

selinux_enforcing() {
  [[ "$(getenforce)" == Enforcing ]]
}
check "SELinux is enforcing" selinux_enforcing

console_kargs() {
  grep -qw 'console=ttyS0,115200n8' /proc/cmdline
}
check "kernel arguments from kargs.d are applied" console_kargs

tracks_registry() {
  local ref
  ref="$(bootc status --json | jq -r '.status.booted.image.image.image')"
  [[ $ref == "$registry_image" ]] || { echo "      tracks: $ref"; return 1; }
}
check "bootc tracks $registry_image" tracks_registry

# First boot and accounts.
# `systemctl show` reports Result=success even for a unit that doesn't exist,
# hence LoadState too.
firstboot_succeeded() {
  local state
  state="$(systemctl show -p LoadState -p Result --value android-dev-firstboot.service | xargs)"
  [[ $state == "loaded success" && -e /var/lib/android-dev-vm/firstboot.done ]] || {
    echo "      load state and result: $state"
    journalctl -b -u android-dev-firstboot.service --no-pager | indent
    return 1
  }
}
check "first-boot unit ran and succeeded" firstboot_succeeded

accounts() {
  [[ "$(id -u admin)" == 1000 && "$(id -nG admin)" == "admin wheel" &&
    "$(id -u dev)" == 1500 && "$(id -nG dev)" == dev ]] || {
    id admin | indent
    id dev | indent
    return 1
  }
}
check "sysusers created admin (1000, wheel) and dev (1500)" accounts

# The passwords came from the credentials run-vm.sh passed.
passwords_set() {
  local user bad=0
  for user in admin dev; do
    [[ "$(getent shadow "$user" | cut -d: -f2)" == \$* ]] || { echo "      $user has no password"; bad=1; }
  done
  return "$bad"
}
check "admin and dev passwords set from credentials (no prompt)" passwords_set

homes() {
  local user got bad=0
  for user in admin dev; do
    got="$(stat -c '%U %a %C' "/var/home/$user" 2>&1)"
    [[ $got == "$user 700 "*:user_home_dir_t:* ]] || { echo "      /var/home/$user: $got"; bad=1; }
  done
  return "$bad"
}
check "homes exist, private, labelled user_home_dir_t" homes

root_locked() {
  [[ "$(getent shadow root | cut -d: -f2)" =~ ^[!*]+$ ]]
}
check "root is still locked after first boot" root_locked

# dev's privileges.

# Passes if dev is denied: a non-zero exit that isn't a setpriv failure or a
# hang (a hang would mean it's waiting for a password).
dev_denied() {
  as_dev "$@"
  case $rc in
    0) echo "      $* succeeded as dev" ;;
    124) echo "      $* hung (waiting for a password?)" ;;
    255) echo "      $out" ;;
    *) return 0 ;;
  esac
  return 1
}
check "dev: sudo is denied" dev_denied sudo -n true
check "dev: run0 is denied" dev_denied run0 true
check "dev: pkexec is denied" dev_denied pkexec true

# Also tested in the image, but here PAM runs under SELinux enforcing.
su_refused() {
  as_dev su -c true root
  [[ $out == "su: Permission denied" ]] || { echo "      su: $out"; return 1; }
}
check "dev: su is refused without a password prompt" su_refused

# dev asks about its own process, a real subject (the image test had to use bus
# names). pkcheck exit 1 means "not authorized", 2 would be an admin prompt.
polkit_denies_dev() {
  # shellcheck disable=SC2016 # $$ is expanded by the inner bash
  as_dev bash -c 'exec pkcheck --action-id org.freedesktop.systemd1.manage-units --process $$'
  ((rc == 1)) || { echo "      pkcheck exit $rc: $out"; return 1; }
}
check "dev: polkit says no to managing units" polkit_denies_dev

# The emulator needs /dev/kvm without kvm membership. The node exists even
# without nested virtualisation (udev static_node), and opening it then fails
# with ENODEV or similar. What matters is that dev isn't refused access.
dev_kvm() {
  local mode
  mode="$(stat -c %a /dev/kvm 2>&1)"
  [[ $mode == 666 ]] || { echo "      /dev/kvm mode: $mode"; return 1; }
  as_dev bash -c 'exec 3<>/dev/kvm'
  ((rc == 0)) || [[ $rc != 124 && $rc != 255 && $out != *"Permission denied"* ]] ||
    { echo "      $out"; return 1; }
}
check "dev may open /dev/kvm (mode 0666)" dev_kvm

finish "vm checks"
