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
    124) echo "      $* hung for 30 s" ;;
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

# Network containment.

# firewalld owns only its own table, so a reload must leave ours alone.
egress_rule_loaded() {
  firewall-cmd --reload >/dev/null &&
    nft list chain inet dev_egress output | grep -q 'meta skuid 1500 counter'
}
check "dev's egress rule is loaded and survives a firewalld reload" egress_rule_loaded

# The rule matches UID 1500 only (see tests/image/checks.sh).
no_subids() {
  local found
  found="$(grep -sHE '^(dev|1500):' /etc/subuid /etc/subgid || true)"
  [[ -z $found ]] || { indent <<<"$found"; return 1; }
}
check "dev has no subordinate UIDs or GIDs" no_subids

# Control: without it, the checks below could pass on a VM with no network.
root_direct() {
  curl -sS -o /dev/null --max-time 30 https://dl.google.com/ 2>&1 | indent
}
check "control: root connects directly" root_direct

# Packets the rule has stopped for dev so far, from its counters.
dev_stopped_packets() {
  nft list chain inet dev_egress output | awk '/meta skuid 1500/ && !/oif/ {
    for (i = 1; i < NF; i++) if ($i == "packets") n += $(i + 1)
  } END { print n + 0 }'
}

# Passes if the bash snippet, run as dev, fails without hanging and the rule's
# counters went up. The counters show it was the rule: a missing route or an
# unreachable host would fail too, but prove nothing.
dev_blocked() {
  local before
  before="$(dev_stopped_packets)"
  dev_denied bash -c "$1" || return 1
  (("$(dev_stopped_packets)" > before)) || { echo "      not stopped by the rule: $out"; return 1; }
}
check "dev: direct TCP over IPv4 is blocked" dev_blocked 'exec 3<>/dev/tcp/1.1.1.1/443'
check "dev: direct TCP over IPv6 is blocked" dev_blocked 'exec 3<>/dev/tcp/2606:4700:4700::1111/443'
check "dev: direct UDP (DNS to 1.1.1.1) is blocked" dev_blocked 'exec 3>/dev/udp/1.1.1.1/53; printf x >&3'
check "dev: ICMP is blocked" dev_blocked 'ping -c 1 -W 1 1.1.1.1'

# As dev with a clean login environment, so the proxy comes from profile.d.
as_dev_login() {
  as_dev env -i HOME=/var/home/dev USER=dev LOGNAME=dev PATH=/usr/bin bash -lc "$1"
}

# $1: host[:port], $2: the CONNECT status Squid must answer with.
via_proxy() {
  as_dev_login "curl -sS -o /dev/null --max-time 30 -w '%{http_connect}' https://$1/"
  [[ ${out##*$'\n'} == "$2" ]] || { echo "      rc $rc: $out"; return 1; }
}
check "dev: dl.google.com through Squid" via_proxy dl.google.com 200
check "dev: api.anthropic.com through Squid" via_proxy api.anthropic.com 200
check "dev: example.com refused by Squid (403)" via_proxy example.com 403
check "dev: IP literals refused by Squid (403)" via_proxy 1.1.1.1 403
check "dev: ports other than 443 refused by Squid (403)" via_proxy dl.google.com:8443 403

# HTTPS only: a plain HTTP request is refused even to an allowlisted host.
plain_http_refused() {
  as_dev_login "curl -sS -o /dev/null --max-time 30 -w '%{http_code}' http://dl.google.com/"
  [[ ${out##*$'\n'} == 403 ]] || { echo "      rc $rc: $out"; return 1; }
}
check "dev: plain HTTP refused by Squid (403)" plain_http_refused

# Squid's log writer may lag a moment behind the refusal.
denied_listed() {
  local _
  for _ in {1..10}; do
    as_dev_login android-dev-denied
    [[ $rc == 0 && $out == *" example.com"* ]] && return 0
    sleep 1
  done
  echo "      rc $rc: $out"
  return 1
}
check "dev: android-dev-denied lists example.com" denied_listed

# The generator's output is parsed by systemd, not a shell: check the quoted
# value arrives whole, in a service dev's manager starts.
user_manager_env() {
  local env
  systemctl start user@1500.service
  env="$(systemd-run -M dev@ --user --wait --pipe --quiet printenv)"
  if ! grep -qx 'https_proxy=http://127.0.0.1:3128' <<<"$env" ||
    ! grep -qx 'JAVA_TOOL_OPTIONS=-Dhttp.proxyHost=127.0.0.1 .*-Dhttp.nonProxyHosts=localhost|127.0.0.1|\[::1\]' <<<"$env"; then
    grep -iE 'proxy|java' <<<"$env" | indent
    return 1
  fi
}
check "dev's systemd --user environment has the proxy settings" user_manager_env

# Fail closed, as at boot: when the rule's unit fails, systemd-user-sessions
# can't start and /run/nologin stays (pam_nologin then refuses everyone but
# root, see tests/image/checks.sh). A runtime drop-in makes the unit fail, and
# everything is put back afterwards. Runs last because it changes state.
fail_closed() {
  local dropin=/run/systemd/system/dev-egress-firewall.service.d bad=0
  mkdir -p "$dropin"
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/false\n' >"$dropin/50-fail.conf"
  systemctl daemon-reload
  # Requires= stops systemd-user-sessions too, which recreates /run/nologin.
  systemctl stop dev-egress-firewall.service
  if systemctl start systemd-user-sessions.service 2>/dev/null; then
    echo "      systemd-user-sessions started without the rule's unit"
    bad=1
  fi
  [[ -e /run/nologin ]] || { echo "      no /run/nologin"; bad=1; }
  rm -r "$dropin"
  systemctl daemon-reload
  systemctl start systemd-user-sessions.service || bad=1
  [[ ! -e /run/nologin ]] || { echo "      /run/nologin left after restoring"; bad=1; }
  return "$bad"
}
check "fail closed: no user sessions without the rule's unit" fail_closed

finish "vm checks"
