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
  # A unit waiting on the console (a first-boot prompt nobody answers) fails
  # this instead of running into the CI step's timeout, which loses the logs.
  state="$(timeout 300 systemctl is-system-running --wait)"
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

# systemd-firstboot runs on our first boot (see its drop-in) and applied the
# firstboot.* credentials from run-vm.sh: the keymap for the console and, as
# converted, the login screen, and the time zone.
firstboot_settings() {
  local status keymap x11 tz
  status="$(localectl status)"
  keymap="$(sed -n 's/^ *VC Keymap: //p' <<<"$status")"
  x11="$(sed -n 's/^ *X11 Layout: //p' <<<"$status")"
  tz="$(timedatectl show -p Timezone --value)"
  [[ $keymap == de && $x11 == de && $tz == Europe/Warsaw ]] || {
    echo "      keymap '$keymap', X11 layout '$x11', time zone '$tz'"
    journalctl -b -u systemd-firstboot.service --no-pager | indent
    return 1
  }
}
check "systemd-firstboot set the keymap (console and login screen) and time zone" firstboot_settings

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
# hang (a hang would mean it's waiting for a password), with output that
# matches $1. polkit's NO reads differently from a prompt nobody answered
# ("Interactive authentication required", "No authentication agent found").
# sudo -n says the same either way, so the image checks cover sudoers.
dev_denied() {
  local want=$1
  shift
  as_dev "$@"
  case $rc in
    0) echo "      $* succeeded as dev" ;;
    124) echo "      $* hung for 30 s" ;;
    255) echo "      $out" ;;
    *) [[ $out == *"$want"* ]] && return 0 || echo "      rc $rc: $out" ;;
  esac
  return 1
}
check "dev: sudo is denied" dev_denied "a password is required" sudo -n true
check "dev: run0 is denied" dev_denied "Access denied" run0 true
check "dev: pkexec is denied" dev_denied "Not authorized" pkexec true

# Also tested in the image, but here PAM runs under SELinux enforcing.
su_refused() {
  as_dev su -c true root
  [[ $out == "su: Permission denied" ]] || { echo "      su: $out"; return 1; }
}
check "dev: su is refused without a password prompt" su_refused

# kargs.d/10-ssh.toml. The test's own sshd-extra.socket comes from the
# ssh.listen credential.
no_auto_ssh() {
  local sockets
  sockets="$(systemctl list-units --all --plain --no-legend 'sshd-*.socket' | cut -d' ' -f1 | xargs)"
  [[ $sockets == sshd-extra.socket && ! -e /run/ssh-unix-local/socket ]] ||
    { echo "      sshd sockets: $sockets"; return 1; }
}
check "no automatic sshd sockets, only the test's own" no_auto_ssh

# dev asks about its own process, a real subject (the image test had to use bus
# names). pkcheck exit 1 means "not authorized", 2 would be an admin prompt.
polkit_denies_dev() {
  # shellcheck disable=SC2016 # $$ is expanded by the inner bash
  as_dev bash -c 'exec pkcheck --action-id org.freedesktop.systemd1.manage-units --process $$'
  ((rc == 1)) || { echo "      pkcheck exit $rc: $out"; return 1; }
}
check "dev: polkit says no to managing units" polkit_denies_dev

# The allowlist in 00-android-dev.rules needs dev's active local session, which
# the image test can't create. A session on tty8 stands in for the desktop:
# PAM's login stack, as on a text console, made active with chvt (tty1-6 would
# get logind's automatic getty, which hangs it up). Every action must be NO
# (never an admin prompt), except exactly the ones listed here. A new action or
# a widened rule fails until it's reviewed and added.
session_allowlist="org.freedesktop.RealtimeKit1.acquire-high-priority
org.freedesktop.RealtimeKit1.acquire-real-time
org.freedesktop.login1.inhibit-block-idle
org.freedesktop.login1.inhibit-block-shutdown
org.freedesktop.login1.inhibit-block-sleep
org.freedesktop.login1.inhibit-delay-shutdown
org.freedesktop.login1.inhibit-delay-sleep
org.freedesktop.login1.inhibit-handle-hibernate-key
org.freedesktop.login1.inhibit-handle-lid-switch
org.freedesktop.login1.inhibit-handle-power-key
org.freedesktop.login1.inhibit-handle-reboot-key
org.freedesktop.login1.inhibit-handle-suspend-key
org.freedesktop.login1.power-off
org.freedesktop.login1.reboot
org.freedesktop.login1.set-wall-message
org.freedesktop.login1.suspend
org.freedesktop.udisks2.eject-media
org.freedesktop.udisks2.filesystem-mount"
polkit_in_session() {
  local pid session action rc yes="" bad=0
  systemd-run -q --unit=dev-tty8 -p PAMName=login -p User=dev -p TTYPath=/dev/tty8 \
    -p StandardInput=tty-force -p StandardOutput=tty -p TTYVHangup=yes /usr/bin/sleep infinity
  chvt 8
  # Until the session is in the foreground and its process runs as dev. The
  # session is registered while the process is still root, before the exec.
  for _ in {1..100}; do
    pid="$(systemctl show -p MainPID --value dev-tty8)"
    session="$(ps -o lsession= -p "$pid" | xargs)"
    [[ "$(ps -o user=,comm= -p "$pid" | xargs)" == "dev sleep" &&
      "$(loginctl show-session -p Active --value "$session" 2>/dev/null)" == yes ]] && break
    sleep 0.1
  done
  if [[ "$(ps -o user= -p "$pid" | xargs)" != dev ||
    "$(loginctl show-session -p Active -p Remote -p Seat "$session" | LC_ALL=C sort | xargs)" != \
    "Active=yes Remote=no Seat=seat0" ]]; then
    echo "      no active local session for dev: $(loginctl show-session "$session" 2>&1 | xargs)"
    bad=1
  else
    for action in $(pkaction); do
      rc=0
      pkcheck --action-id "$action" --process "$pid" >/dev/null 2>&1 || rc=$?
      case $rc in
        0) yes+="$action"$'\n' ;;
        1) ;;
        *) echo "      $action: pkcheck exit $rc"; bad=1 ;;
      esac
    done
    diff <(echo "$session_allowlist") <(printf '%s' "$yes" | LC_ALL=C sort) | indent || bad=1
  fi
  systemctl stop dev-tty8
  chvt 1
  return "$bad"
}
check "dev's active session: polkit says yes to exactly the allowlist, no to the rest" polkit_in_session

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

# Every listening socket, as "protocol address process". dev reaches all of them
# over loopback, so a new one gets reviewed here (docs/security-model.md,
# Services on loopback). Port 22 is the test's own sshd. Squid's UDP sockets
# on random ports are its DNS client. spice-webdavd and avahi run because the
# test VM has Boxes' folder-sharing port (run-vm.sh). avahi's socket is bound
# to every address, but it uses only lo. Runs before anything dev starts.
expected_listeners="tcp 0.0.0.0:22 systemd
tcp 127.0.0.1:3128 squid
tcp 127.0.0.1:9843 spice-webdavd
tcp 127.0.0.53%lo:53 systemd-resolve
tcp 127.0.0.54:53 systemd-resolve
udp 0.0.0.0:5353 avahi-daemon
udp 127.0.0.1:323 chronyd
udp 127.0.0.53%lo:53 systemd-resolve
udp 127.0.0.54:53 systemd-resolve
udp [::1]:323 chronyd
udp [::]:5353 avahi-daemon"
listeners() {
  ss -Hlntup | awk '{
    match($0, /users:\(\("[^"]+"/)
    p = substr($0, RSTART + 9, RLENGTH - 10)
    if (!($1 == "udp" && p == "squid")) print $1, $5, p
  }' | LC_ALL=C sort -u
}
listeners_reviewed() {
  diff <(echo "$expected_listeners") <(listeners) | indent
}
check "only the reviewed services listen" listeners_reviewed

# firewalld owns only its own table, so a reload must leave ours alone.
# Listed first, then matched: grep -q at the end of a pipeline can kill nft
# with SIGPIPE, which pipefail turns into a failure.
egress_rule_loaded() {
  local chain
  firewall-cmd --reload >/dev/null || return 1
  chain="$(nft list chain inet dev_egress output)" || return 1
  [[ $chain == *"meta skuid 1500 "*counter* ]] || { indent <<<"$chain"; return 1; }
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
  dev_denied "" bash -c "$1" || return 1
  (("$(dev_stopped_packets)" > before)) || { echo "      not stopped by the rule: $out"; return 1; }
}
check "dev: direct TCP over IPv4 is blocked" dev_blocked 'exec 3<>/dev/tcp/1.1.1.1/443'
check "dev: direct TCP over IPv6 is blocked" dev_blocked 'exec 3<>/dev/tcp/2606:4700:4700::1111/443'
check "dev: direct UDP (DNS to 1.1.1.1) is blocked" dev_blocked 'exec 3>/dev/udp/1.1.1.1/53; printf x >&3'
check "dev: ICMP is blocked" dev_blocked 'ping -c 1 -W 1 1.1.1.1'
# bubblewrap, as Claude Code's sandbox and Flatpak use it: UID 0 inside the
# user namespace is still UID 1500 to the rule.
check "dev: direct TCP from a user namespace (bubblewrap) is blocked" dev_blocked \
  'bwrap --ro-bind / / --dev /dev --unshare-user --uid 0 bash -c "exec 3<>/dev/tcp/1.1.1.1/443"'

# As dev with a clean login environment, so the proxy comes from profile.d.
as_dev_login() {
  as_dev env -i HOME=/var/home/dev USER=dev LOGNAME=dev PATH=/usr/bin bash -lc "$1"
}

# Passes if the last line of $out is $1.
last_line_is() {
  [[ ${out##*$'\n'} == "$1" ]] || { echo "      rc $rc: $out"; return 1; }
}

# $1: host[:port], $2: the CONNECT status Squid must answer with.
via_proxy() {
  as_dev_login "curl -sS -o /dev/null --max-time 30 -w '%{http_connect}' https://$1/"
  last_line_is "$2"
}
check "dev: dl.google.com through Squid" via_proxy dl.google.com 200
check "dev: api.anthropic.com through Squid" via_proxy api.anthropic.com 200
# Through .googleapis.com: the Flutter SDK's downloads.
check "dev: storage.googleapis.com through Squid" via_proxy storage.googleapis.com 200
check "dev: example.com refused by Squid (403)" via_proxy example.com 403
check "dev: IP literals refused by Squid (403)" via_proxy 1.1.1.1 403
check "dev: ports other than 443 refused by Squid (403)" via_proxy dl.google.com:8443 403

# HTTPS only: a plain HTTP request is refused even to an allowlisted host.
plain_http_refused() {
  as_dev_login "curl -sS -o /dev/null --max-time 30 -w '%{http_code}' http://dl.google.com/"
  last_line_is 403
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

# Command-line JVMs such as Gradle ignore the proxy variables and take it from
# JAVA_TOOL_OPTIONS instead.
java_via_proxy() {
  cat >/tmp/Fetch.java <<'EOF'
public class Fetch {
  public static void main(String[] args) throws Exception {
    var c = (java.net.HttpURLConnection) java.net.URI.create(args[0]).toURL().openConnection();
    System.out.println(c.getResponseCode());
  }
}
EOF
  chmod 0644 /tmp/Fetch.java
  as_dev_login 'java /tmp/Fetch.java https://dl.google.com/android/repository/repository2-3.xml'
  last_line_is 200
}
check "dev: command-line Java reaches dl.google.com through Squid" java_via_proxy

# CONNECT requests Squid tunnelled to $1.
squid_tunnels() {
  awk -v host="$1" '$4 == "TCP_TUNNEL/200" && $7 == host' /var/log/squid/access.log | wc -l
}

# Android Studio, with dev's session environment, in a headless KWin. On first
# start it fetches the SDK lists from dl.google.com: that must go through Squid
# (Studio takes the proxy from JAVA_TOOL_OPTIONS), with no direct attempt, and
# in that first minute Squid must refuse nothing it asks for except its
# plain-HTTP connectivity check (HTTPS only, see squid.conf).
studio_uses_proxy() {
  local tunnels stopped log_lines refused _ ok=1
  tunnels="$(squid_tunnels dl.google.com:443)"
  stopped="$(dev_stopped_packets)"
  log_lines="$(wc -l </var/log/squid/access.log)"
  systemctl start user@1500.service
  systemd-run -M dev@ --user --unit=studio-check --collect --quiet \
    kwin_wayland --virtual --xwayland --socket=studio-check \
    --exit-with-session=/usr/bin/android-studio ||
    { echo "      couldn't start Studio's unit"; return 1; }
  for _ in {1..36}; do
    (("$(squid_tunnels dl.google.com:443)" > tunnels)) && { ok=0; break; }
    systemctl --user -M dev@ is-active --quiet studio-check.service || {
      echo "      KWin or Studio exited early:"
      journalctl -b _UID=1500 -n 20 --no-pager | indent
      return 1
    }
    sleep 5
  done
  # Then a little longer, for the marketplace and docs requests.
  ((ok == 0)) && sleep 30
  systemctl --user -M dev@ stop studio-check.service 2>/dev/null
  # Squid logs a tunnel when it closes, and a connection Studio kept open
  # closes only now.
  ((ok == 0)) || { sleep 5; (("$(squid_tunnels dl.google.com:443)" > tunnels)) && ok=0; }
  ((ok == 0)) || { echo "      no tunnel to dl.google.com within 3 minutes"; return 1; }
  (("$(dev_stopped_packets)" == stopped)) || { echo "      Studio tried direct connections"; return 1; }
  refused="$(tail -n "+$((log_lines + 1))" /var/log/squid/access.log |
    awk '$4 ~ /^TCP_DENIED\// && $7 !~ /^http:\/\/play\.google\.com\// { print $7 }' | sort -u)"
  [[ -z $refused ]] || { echo "      Squid refused:"; indent <<<"$refused"; return 1; }
}
check "Android Studio starts and goes through Squid" studio_uses_proxy

# The run above logged the plugins Studio loaded. Its log lives in a directory
# named after Studio's version.
studio_loaded_plugins() {
  local loaded id name jar xml bad=0
  loaded="$(grep -hs 'Loaded bundled plugins:' /var/home/dev/.cache/Google/*/log/idea.log)" ||
    { echo "      no list of loaded plugins in Studio's log"; return 1; }
  while read -r id _; do
    xml=
    for jar in "/usr/lib/android-studio/plugins/$id"/lib/*.jar; do
      xml="$(unzip -p "$jar" META-INF/plugin.xml 2>/dev/null)" && break
    done
    name="$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' <<<"$xml" | head -n 1)"
    [[ -n $name && $loaded == *" $name ("* ]] || { echo "      not loaded: $id (${name:-no name})"; bad=1; }
  done < <(grep -vE '^\s*(#|$)' /usr/lib/android-dev-vm/studio-plugins.txt)
  return "$bad"
}
check "Android Studio loaded the plugins in studio-plugins.txt" studio_loaded_plugins

# Studio's first start above ran its own setup in the profile it made (the
# dl.google.com tunnel). From the second start, /usr/bin/android-studio turns
# on automatic plugin updates. --version starts nothing, but goes through it.
studio_plugins_auto_update() {
  as_dev /usr/bin/android-studio --version
  ((rc == 0)) || { echo "      rc $rc: $out"; return 1; }
  grep -qs '<option name="PLUGINS_AUTO_UPDATE" value="true" />' \
    /var/home/dev/.config/Google/AndroidStudio*/options/updates.xml ||
    { cat /var/home/dev/.config/Google/AndroidStudio*/options/updates.xml 2>&1 | indent; return 1; }
}
check "Android Studio updates plugins automatically for dev" studio_plugins_auto_update

# Boxes (PLAN.md). run-vm.sh adds the virtio ports Boxes adds, so udev has
# started spice-webdavd, and with it avahi, which must use lo alone.
boxes_shared_folders() {
  local unit ifaces
  for unit in spice-webdavd.service avahi-daemon.service; do
    systemctl is-active --quiet "$unit" ||
      { systemctl status --no-pager "$unit" 2>&1 | indent; return 1; }
  done
  ifaces="$(journalctl -b -u avahi-daemon.service -o cat |
    sed -n 's/^New relevant interface \([^ ]*\) for mDNS\.$/\1/p' | LC_ALL=C sort -u)"
  [[ $ifaces == $'lo.IPv4\nlo.IPv6' ]] || { echo "      avahi's interfaces: ${ifaces//$'\n'/ }"; return 1; }
}
check "Boxes folder sharing: spice-webdavd runs, avahi only on lo" boxes_shared_folders

# Claude Code with no proxy in its environment: the managed settings alone
# must send it through Squid, with no direct attempt. The VM has no login, so
# a dummy key makes it call the API. The API refuses the key, and the tunnel
# is what counts.
claude_uses_proxy() {
  local tunnels stopped _
  tunnels="$(squid_tunnels api.anthropic.com:443)"
  stopped="$(dev_stopped_packets)"
  as_dev env -i HOME=/var/home/dev PATH=/usr/bin ANTHROPIC_API_KEY=dummy claude -p hi
  ((rc != 124 && rc != 255)) || { echo "      rc $rc: $out"; return 1; }
  (("$(dev_stopped_packets)" == stopped)) || { echo "      Claude Code tried direct connections"; return 1; }
  # Squid logs a tunnel when it closes.
  for _ in {1..10}; do
    (("$(squid_tunnels api.anthropic.com:443)" > tunnels)) && return 0
    sleep 1
  done
  echo "      no tunnel to api.anthropic.com, rc $rc: $out"
  return 1
}
check "Claude Code takes the proxy from its managed settings" claude_uses_proxy

# DISABLE_UPDATES in the managed settings. Without it, `claude install` would
# download a self-updating copy into dev's home, which comes first on PATH. A
# login shell, so the proxy is there to download it with.
claude_no_own_copy() {
  as_dev_login 'claude install stable'
  ((rc != 124 && rc != 255)) || { echo "      rc $rc: $out"; return 1; }
  [[ ! -e /var/home/dev/.local/bin/claude && ! -e /var/home/dev/.local/share/claude ]] ||
    { echo "      claude install put a copy in dev's home: $out"; return 1; }
}
check "dev: claude install doesn't install its own copy" claude_no_own_copy

# Updates: the timer is armed, and the service it starts only stages (no
# --apply, which would reboot).
updates_stage_only() {
  local exec_start
  exec_start="$(systemctl show -p ExecStart --value bootc-fetch-apply-updates.service)"
  # Exactly one command, so no `bootc upgrade --apply` runs before it.
  [[ $exec_start != *"argv[]="*"argv[]="* &&
    $exec_start == *"argv[]=/usr/bin/bootc upgrade --quiet ;"* ]] ||
    { echo "      ExecStart: $exec_start"; return 1; }
  systemctl is-active --quiet bootc-fetch-apply-updates.timer ||
    { echo "      timer: $(systemctl is-active bootc-fetch-apply-updates.timer)"; return 1; }
}
check "updates: the timer is armed and only stages" updates_stage_only

# See boot.automount in build_files/40-services.sh.
boot_not_automounted() {
  ! findmnt -t autofs /boot >/dev/null || { findmnt /boot | indent; return 1; }
}
check "updates: /boot isn't an automount" boot_not_automounted

# plymouthd can hang while quitting the boot splash. plymouth-quit.service
# then times out after 20 s, and its drop-in must kill plymouthd, or the boot
# (and the first-boot prompt, which comes after it) would wait forever.
# Simulated with a stopped plymouthd and a restart of the unit.
plymouth_hang_killed() {
  local pid start bad=0
  [[ " $(systemctl show -p After --value android-dev-firstboot.service) " == *" plymouth-quit.service "* ]] ||
    { echo "      the first-boot unit doesn't start after plymouth-quit.service"; bad=1; }
  plymouthd --mode=boot --pid-file=/run/plymouth/pid ||
    { echo "      couldn't start plymouthd"; return 1; }
  pid="$(cat /run/plymouth/pid)"
  kill -STOP "$pid"
  start=$SECONDS
  systemctl restart plymouth-quit.service 2>/dev/null
  # Under 15 s, the quit didn't hang, and the check proves nothing.
  ((SECONDS - start >= 15)) || { echo "      plymouth quit didn't hang"; bad=1; }
  systemctl reset-failed plymouth-quit.service
  if kill -0 "$pid" 2>/dev/null; then
    echo "      plymouthd is still there"
    kill -KILL "$pid"
    bad=1
  fi
  return "$bad"
}
check "a plymouthd that hangs while quitting gets killed" plymouth_hang_killed

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
  # dev's user manager, which lingering would start without a login.
  if systemctl start user@1500.service 2>/dev/null; then
    echo "      user@1500.service started without the rule's unit"
    bad=1
  fi
  rm -r "$dropin"
  systemctl daemon-reload
  systemctl start systemd-user-sessions.service || bad=1
  [[ ! -e /run/nologin ]] || { echo "      /run/nologin left after restoring"; bad=1; }
  return "$bad"
}
check "fail closed: no user sessions or dev user manager without the rule's unit" fail_closed

finish "vm checks"
