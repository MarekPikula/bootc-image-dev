#!/usr/bin/bash
# Assertions against a built image, without booting it. Runs every check, then
# exits non-zero if any failed.
#
# Usage: tests/image/checks.sh IMAGE
# In CI the image is in rootful storage, so run it with sudo there.
set -euo pipefail

image=${1:?usage: $0 IMAGE}
cd "$(dirname "$(readlink -f "$0")")/../.."
# shellcheck source=tests/lib.sh
. tests/lib.sh

# expect_meta Labels|Annotations KEY VALUE
expect_meta() {
  local actual
  actual="$(podman image inspect --format "{{ index .$1 \"$2\" }}" "$image")"
  [[ $actual == "$3" ]] || { echo "      $2 is '$actual', expected '$3'"; return 1; }
}

# One offline container serves every in-image check. systemd-sysusers creates
# the accounts first, as it does at boot.
ctr="$(podman run -d --rm --network=none "$image" sleep infinity)"
trap 'podman rm -f -t 0 "$ctr" >/dev/null || true' EXIT
# Captured before sysusers runs: the image itself must not carry the accounts.
# grep exits 1 for no match, which is the expected case, and 2 if it couldn't
# read a file, which must not pass as "no accounts".
shipped_accounts="$(podman exec "$ctr" sh -c 'grep -hE "^(admin|dev):" \
  /etc/passwd /etc/shadow /etc/group /usr/lib/passwd /usr/lib/group; [ $? -le 1 ]')" ||
  { echo "can't read the image's account files" >&2; exit 1; }
out="$(podman exec "$ctr" systemd-sysusers 2>&1)" || { echo "$out" >&2; exit 1; }

# Runs the bash script on stdin inside the image.
in_image() {
  podman exec -i "$ctr" /usr/bin/bash -euo pipefail -s
}

# Every ExecStart= command in the unit text on stdin, in order: an empty
# ExecStart= clears the list.
exec_starts() {
  awk '/^ExecStart=/ { if ($0 == "ExecStart=") n = 0; else cmd[++n] = substr($0, 11) }
    END { for (i = 1; i <= n; i++) print cmd[i] }'
}

# expect_exec_start UNIT COMMAND: with its drop-ins, UNIT runs COMMAND alone.
expect_exec_start() {
  local actual
  actual="$(podman exec "$ctr" systemctl cat "$1" | exec_starts)"
  [[ $actual == "$2" ]] || { echo "      ExecStart= lines:"; indent <<<"$actual"; return 1; }
}

# expect_unit_state STATE UNIT...: systemctl is-enabled says STATE for each.
expect_unit_state() {
  local state=$1 unit actual bad=0
  shift
  for unit; do
    actual="$(podman exec "$ctr" systemctl is-enabled "$unit" 2>&1 || true)"
    [[ $actual == "$state" ]] || { echo "      $unit: $actual"; bad=1; }
  done
  return "$bad"
}

# /sysroot is skipped: it holds the ostree repo's copies of the same files.
privileged_files() {
  in_image <<'EOF'
export LC_ALL=C
find / -xdev -path /sysroot -prune -o -type f -perm /6000 -printf '%m %p\n' | sort -k2
getcap -r /usr /etc 2>/dev/null | sed 's/^/caps /' | sort -k2
EOF
}

# pipefail: the pipeline fails with diff's status.
expect_privileged_files() {
  diff <(grep -v '^#' tests/image/privileged-files.txt) <(privileged_files) | indent
}

no_shipped_accounts() {
  [[ -z $shipped_accounts ]] || { indent <<<"$shipped_accounts"; return 1; }
}

# The prompt sets passwords, so it runs in a throwaway container, not the
# shared one. $1 is the typed input, the rest the tests/image/firstboot.sh
# mode and its argument.
firstboot_prompt() {
  local input=$1
  shift
  podman run --rm -i --network=none -v "$PWD/tests/image:/tests:ro,z" "$image" \
    /tests/firstboot.sh "$@" <<<"$input"
}

# A weak password, a mismatch and dev reusing admin's are rejected first.
expect_firstboot_sets_passwords() {
  local a=Lantern-Quiver-4817-Mosaic b=Harbor-Violet-2093-Kestrel
  firstboot_prompt "$(printf '%s\n' password password "$a" "$a" \
    "$a" "$a" "$b" "${b}x" "$b" "$b")" sets
}

# admin's password came from an earlier boot (or a credential), so only dev's
# is asked for, and it still mustn't be admin's.
expect_firstboot_dev_differs() {
  local a=Lantern-Quiver-4817-Mosaic b=Harbor-Violet-2093-Kestrel
  firstboot_prompt "$(printf '%s\n' "$a" "$a" "$b" "$b")" dev-only "$a"
}

expect_firstboot_gives_up() {
  firstboot_prompt "$(printf '\n%.0s' {1..12})" gives-up
}

base="$(sed -n 's/^BASE_IMAGE=//p' versions.env)"

check "is a bootc image" expect_meta Labels containers.bootc 1
check "built from the base in versions.env" \
  expect_meta Annotations org.opencontainers.image.base.name "$base"

# No credentials in the image (CLAUDE.md). A password field may only hold a
# marker with no hash in it: '!'/'*' characters or '!locked' ('!$6$...' is a
# locked but real hash, which `usermod -U` would restore). The passwd files must
# defer to shadow ('x') or carry such a marker. Kinoite keeps system users in
# /usr/lib/passwd (nss-altfiles), where pam_unix also accepts a hash. An empty
# field means login without a password, except in gshadow (no group password).
check "no passwords in passwd, shadow or gshadow files" in_image <<'EOF'
awk -F: '
  { ok = $2 ~ /^([!*]+|!locked)$/ }
  FILENAME ~ /passwd$/ && $2 == "x" { ok = 1 }
  FILENAME ~ /gshadow$/ && $2 == ""  { ok = 1 }
  !ok { print "      " FILENAME ": " $1; bad = 1 }
  END { exit bad }' /etc/passwd /usr/lib/passwd /etc/shadow /etc/gshadow
EOF
# Fails closed: a find error aborts the snippet (set -e) instead of being
# masked by a pipeline.
check "no authorized_keys files" in_image <<'EOF'
found="$(find / -xdev \( -name authorized_keys -o -name authorized_keys2 \) -print)"
[[ -z $found ]] || { sed 's/^/      /' <<<"$found"; exit 1; }
EOF
check "no SSH host keys" in_image <<'EOF'
! compgen -G '/etc/ssh/ssh_host_*_key' >/dev/null
EOF
check "admin and dev come from sysusers.d at boot, not from the image's files" \
  no_shipped_accounts

# Accounts and privilege (CLAUDE.md: dev must never gain root).
check "admin is UID 1000 and in wheel" in_image <<'EOF'
[[ "$(id -u admin)" == 1000 ]] && id -nG admin | grep -qw wheel
EOF
check "dev is UID 1500 and in no group but its own" in_image <<'EOF'
[[ "$(id -u dev)" == 1500 && "$(id -nG dev)" == dev ]] ||
  { echo "      dev: UID $(id -u dev), groups: $(id -nG dev)"; exit 1; }
EOF
# The Android emulator relies on this instead of kvm group membership.
check "/dev/kvm is world-accessible (udev MODE=0666)" in_image <<'EOF'
grep -qE '^KERNEL=="kvm",.*MODE="0666"' /usr/lib/udev/rules.d/50-udev-default.rules
EOF
check "sudo: no rule for dev" in_image <<'EOF'
sudo -l -U dev 2>&1 | grep -q 'is not allowed to run sudo'
EOF
# Refused outright: "Password:" in the output would mean dev got to try one.
# Control: admin (wheel) still gets the prompt, so su isn't just broken.
check "su: dev is refused before any password prompt, admin isn't" in_image <<'EOF'
su_as() {
  setpriv --reuid="$1" --regid="$1" --init-groups su -c true "$2" </dev/null 2>&1 || true
}
bad=0
for target in root admin; do
  out="$(su_as dev "$target")"
  [[ $out == "su: Permission denied" ]] || { echo "      su $target as dev: $out"; bad=1; }
done
out="$(su_as admin root)"
[[ $out == Password:* ]] || { echo "      su root as admin: $out"; bad=1; }
exit "$bad"
EOF
# The setuid helper polkit agents run to check a password, which would
# otherwise ask for admin's password on dev's behalf and say whether it was
# right (16-polkit-helper.sh). Same control as su.
check "polkit's password helper: dev can't run it, admin can" in_image <<'EOF'
helper_as() {
  printf 'cookie\n' | setpriv --reuid="$1" --regid="$1" --init-groups \
    timeout 10 /usr/lib/polkit-1/polkit-agent-helper-1 admin 2>&1 || true
}
bad=0
out="$(helper_as dev)"
[[ $out != *PAM_PROMPT* && $out == *"Permission denied"* ]] || { echo "      as dev: $out"; bad=1; }
out="$(helper_as admin)"
[[ $out == *PAM_PROMPT_ECHO_OFF* ]] || { echo "      as admin: $out"; bad=1; }
exit "$bad"
EOF
check "polkit: 00-android-dev.rules runs before every other rule" in_image <<'EOF'
first="$(find /etc/polkit-1/rules.d /usr/share/polkit-1/rules.d -name '*.rules' -printf '%f\n' |
  LC_ALL=C sort | head -n1)"
[[ $first == 00-android-dev.rules ]] || { echo "      first rules file: $first"; exit 1; }
EOF
check "polkit: dev outside a desktop session gets NO for every action" \
  in_image <tests/image/polkit.sh
check "setuid/setgid files and capabilities match tests/image/privileged-files.txt" \
  expect_privileged_files

# Units.
# Every command the service would run, in order: an empty ExecStart= clears
# the list. Without that line in the drop-in, Kinoite's own
# `bootc upgrade --apply` would still run first and reboot.
check "updates are staged, never applied with a reboot" \
  expect_exec_start bootc-fetch-apply-updates.service "/usr/bin/bootc upgrade --quiet"
check "our units are pulled in from /usr" in_image <<'EOF'
bad=0
for link in system/multi-user.target.wants/android-dev-firstboot.service \
  system/sysinit.target.wants/dev-egress-firewall.service \
  system/multi-user.target.wants/squid.service \
  system/timers.target.wants/bootc-fetch-apply-updates.timer \
  user/graphical-session.target.wants/android-dev-clipboard.service; do
  [[ "$(readlink "/usr/lib/systemd/$link")" == "../${link##*/}" ]] ||
    { echo "      missing: $link"; bad=1; }
done
exit "$bad"
EOF
# The drop-in repeats Fedora's command to add --chrome=no, so a change to
# Fedora's must show up here.
firstboot_without_chrome() {
  local fedora
  fedora="$(podman exec "$ctr" cat /usr/lib/systemd/system/systemd-firstboot.service | exec_starts)"
  expect_exec_start systemd-firstboot.service "$fedora --chrome=no"
}
check "systemd-firstboot runs Fedora's command, plus --chrome=no" firstboot_without_chrome
# Under /usr/lib it would be lib_t and run as init_t, which may not run passwd.
check "first-boot script is labelled bin_t (SELinux)" in_image <<'EOF'
label="$(matchpathcon -n /usr/libexec/android-dev-vm/set-passwords)"
[[ $label == *:bin_t:* ]] || { echo "      label: $label"; exit 1; }
EOF
check "first-boot prompt rejects bad input, then sets both passwords" \
  expect_firstboot_sets_passwords
check "first-boot prompt: dev's password differs from admin's set earlier" \
  expect_firstboot_dev_differs
check "first-boot prompt gives up after repeated failures, unmarked" \
  expect_firstboot_gives_up
check "sysusers imports the admin and dev password credentials" in_image <<'EOF'
config="$(systemctl cat systemd-sysusers.service)"
for user in admin dev; do
  grep -qx "ImportCredential=passwd.hashed-password.$user" <<<"$config"
done
EOF
# systemd-firstboot skips its root-password prompt when root already has a
# shadow entry, and a locked one keeps root unusable.
check "root is locked" in_image <<'EOF'
field="$(getent shadow root | cut -d: -f2)"
[[ $field =~ ^[!*]+$ ]] || { echo "      root's shadow field: '$field'"; exit 1; }
EOF
# The list and the reasons are in build_files/40-services.sh.
check "units that conflict with the VM's design are masked" expect_unit_state masked \
  plasma-setup.service cups.service cups.socket cups.path cups-browsed.service \
  geoclue.service mcelog.service boot.automount nftables.service \
  systemd-nsresourced.service systemd-nsresourced.socket \
  systemd-mountfsd.service systemd-mountfsd.socket polkit-agent-helper.socket
# avahi runs only when spice-webdavd needs it (40-services.sh), and then with
# no network to use (its config). Disabled also means no D-Bus activation
# alias: is-enabled counts it.
avahi_contained() {
  local conf=/usr/lib/android-dev-vm/avahi/avahi-daemon.conf fedora line bad=0
  expect_unit_state disabled avahi-daemon.service avahi-daemon.socket || bad=1
  # The drop-in repeats Fedora's command to add -f, as for systemd-firstboot.
  fedora="$(podman exec "$ctr" cat /usr/lib/systemd/system/avahi-daemon.service | exec_starts)"
  expect_exec_start avahi-daemon.service "$fedora -f $conf" || bad=1
  for line in allow-interfaces=lo enable-wide-area=no enable-reflector=no; do
    podman exec "$ctr" grep -qx "$line" "$conf" || { echo "      $conf: no $line"; bad=1; }
  done
  return "$bad"
}
check "avahi: disabled, on our config, with lo only and no wide-area DNS" avahi_contained

# Network containment (CLAUDE.md): dev reaches the network only through Squid.
# The rule matches UID 1500 only. A subordinate range would let dev run
# processes under other UIDs (podman unshare, podman run --user), which it
# wouldn't match.
check "dev has no subordinate UIDs or GIDs" in_image <<'EOF'
# A missing file has no ranges (-s). The output decides, not grep's status.
found="$(grep -sHE '^(dev|1500):' /etc/subuid /etc/subgid || true)"
[[ -z $found ]] || { sed 's/^/      /' <<<"$found"; exit 1; }
EOF
# nft -c needs CAP_NET_ADMIN. --network=none keeps it inside an empty netns.
check "egress rule parses (the image's nft)" \
  podman run --rm --network=none --cap-add NET_ADMIN "$image" \
  nft -c -f /usr/lib/android-dev-vm/nftables/dev-egress.nft
check "fail closed: user sessions require the egress rule" in_image <<'EOF'
config="$(systemctl cat systemd-user-sessions.service)"
grep -qx 'Requires=dev-egress-firewall.service' <<<"$config"
grep -qx 'After=dev-egress-firewall.service' <<<"$config"
EOF
# At boot /run/nologin comes from systemd's tmpfiles entry, and only
# systemd-user-sessions removes it. Without the entry a rule that failed to
# load would leave nothing to refuse logins. (No grep -q: under pipefail, its
# early exit could fail the pipeline.)
check "fail closed: /run/nologin is created at boot" in_image <<'EOF'
systemd-tmpfiles --cat-config | grep -E '^f\+?!? +/run/nologin ' >/dev/null
EOF
# Without the rule, /run/nologin stays. It only helps where PAM checks it.
check "fail closed: pam_nologin guards the login screen, login and sshd" in_image <<'EOF'
bad=0
for stack in /usr/lib/pam.d/plasmalogin /usr/lib/pam.d/plasmalogin-autologin \
  /etc/pam.d/login /etc/pam.d/sshd; do
  grep -qE '^account\s+required\s+pam_nologin\.so' "$stack" ||
    { echo "      no pam_nologin: $stack"; bad=1; }
done
exit "$bad"
EOF
# squid -k parse exits 0 on warnings, and a warning can mean a directive or an
# ACL entry was ignored.
check "Squid config parses without warnings (the image's squid)" in_image <<'EOF'
out="$(squid -k parse -f /usr/lib/android-dev-vm/squid/squid.conf 2>&1)"
! grep -E 'WARNING|ERROR|FATAL' <<<"$out" | sed 's/^/      /' | grep .
EOF
# Squid would match a CONNECT to an IP address listed here, and a bare
# top-level domain (.com) would allow everything under it. Every token on a
# line counts, the way Squid's dstdomain reads them, a trailing dot ignored.
check "allowlist has no IP addresses or bare top-level domains" in_image <<'EOF'
awk '
  /^[[:space:]]*(#|$)/ { next }
  {
    for (i = 1; i <= NF; i++) {
      entry = $i
      sub(/\.$/, "", entry)
      if (entry ~ /^\.?[0-9.]+$/ || entry ~ /:/ || entry ~ /^\.?[^.]+$/) {
        print "      line " NR ": " $0
        bad = 1
      }
    }
  }
  END { exit bad }' /usr/lib/android-dev-vm/squid/allowlist.txt
EOF
check "proxy settings: dev gets them, admin doesn't" in_image <<'EOF'
env_of() {
  setpriv --reuid="$1" --regid="$1" --init-groups env -i HOME=/ bash -c "$2"
}
generator=/usr/lib/systemd/user-environment-generators/60-dev-proxy
login_proxy='bash -lc "echo \$https_proxy"'
bad=0
env_of dev "$generator" | grep -qx 'https_proxy=http://127.0.0.1:3128' ||
  { echo "      generator: nothing for dev"; bad=1; }
[[ -z "$(env_of admin "$generator")" ]] || { echo "      generator: output for admin"; bad=1; }
[[ "$(env_of dev "$login_proxy")" == http://127.0.0.1:3128 ]] ||
  { echo "      profile.d: nothing for dev"; bad=1; }
[[ -z "$(env_of admin "$login_proxy")" ]] || { echo "      profile.d: proxy for admin"; bad=1; }
exit "$bad"
EOF

# Android tooling.
check "Android Studio: launcher, desktop entry, platform updates off" in_image <<'EOF'
[[ "$(readlink -f /usr/bin/android-studio)" == /usr/libexec/android-dev-vm/android-studio ]]
[[ -x /usr/lib/android-studio/bin/studio ]]
desktop-file-validate /usr/share/applications/android-studio.desktop
grep -qx 'ide.no.platform.update=true' /usr/lib/android-studio/bin/idea.properties
EOF
# Studio skips a plugin whose build range leaves out its build, without an
# error. Builds compare part by part, and "*" in until-build matches any.
check "Studio plugins: each one in studio-plugins.txt is installed, for this Studio's build" in_image <<'EOF'
studio=/usr/lib/android-studio
build="$(jq -r .buildNumber "$studio/product-info.json")"
bad=0
while read -r id _; do
  xml=
  for jar in "$studio/plugins/$id"/lib/*.jar; do
    xml="$(unzip -p "$jar" META-INF/plugin.xml 2>/dev/null)" && break
  done
  [[ $xml == *"<id>$id</id>"* ]] || { echo "      $id: not installed"; bad=1; continue; }
  since="$(sed -n 's/.*since-build="\([^"]*\)".*/\1/p' <<<"$xml")"
  until="$(sed -n 's/.*until-build="\([^"]*\)".*/\1/p' <<<"$xml")"
  [[ -n $since ]] && printf '%s\n' "$since" "$build" "${until:-999999}" | sed 's/\*/999999/g' | sort -VC ||
    { echo "      $id: Studio $build, plugin wants ${since:-?} to ${until:-any}"; bad=1; }
done < <(grep -vE '^\s*(#|$)' /usr/lib/android-dev-vm/studio-plugins.txt)
exit "$bad"
EOF
# The tarball ships no desktop entry, so ours copies these from its
# product-info.json, and a Studio update could change them.
check "Android Studio: desktop entry matches product-info.json" in_image <<'EOF'
info=/usr/lib/android-studio/product-info.json
entry=/usr/share/applications/android-studio.desktop
wm_class="$(jq -r '.launch[] | select(.os == "Linux") | .startupWmClass' "$info")"
icon="/usr/lib/android-studio/$(jq -r .svgIconPath "$info")"
grep -qx "StartupWMClass=$wm_class" "$entry" || { echo "      StartupWMClass should be $wm_class"; exit 1; }
grep -qx "Icon=$icon" "$entry" || { echo "      Icon should be $icon"; exit 1; }
EOF
# /etc/firefox/policies is where Firefox looks first, whatever Fedora's
# per-user-policy setting says. The file itself stays image-owned in /usr. A
# Firefox update can rename policy keys, which would switch that part of the
# policy off silently. (Preferences entries aren't checked: Firefox ignores
# those outside its allowed prefixes.)
check "Firefox policy: where Firefox reads it, with keys this Firefox knows" in_image <<'EOF'
policy=/usr/lib/android-dev-vm/firefox/policies.json
[[ "$(readlink -f /etc/firefox/policies/policies.json)" == "$policy" ]]
# unzip warns about omni.ja's layout, so judge the result by whether jq reads it.
unzip -p /usr/lib64/firefox/browser/omni.ja modules/policies/policies-schema.json \
  >/tmp/policies-schema.json 2>/dev/null || true
unknown="$(jq -r --slurpfile schema /tmp/policies-schema.json '
  $schema[0].properties as $known | .policies | to_entries[] | .key as $policy |
  if $known[$policy] == null then $policy
  elif (.value | type) == "object" and $known[$policy].properties != null then
    ((.value | keys) - ($known[$policy].properties | keys))[] | "\($policy).\(.)"
  else empty end' "$policy")"
[[ -z $unknown ]] || { echo "      unknown to this Firefox:"; sed 's/^/        /' <<<"$unknown"; exit 1; }
EOF
check "JDK 25 for command-line Gradle" in_image <<'EOF'
javac -version 2>&1 | grep -q '^javac 25\.'
EOF

# Claude Code.
# gpgcheck already ran in the build. This catches a build that lost it (an
# unsigned package, or one signed by another key), and checks what rpm
# actually imported from claude-code.asc: besides Fedora's key, only the
# pinned one.
claude_signed() {
  local fingerprint keys sig
  fingerprint="$(sed -n 's/^CLAUDE_CODE_KEY_FINGERPRINT=//p' versions.env)"
  fingerprint=${fingerprint,,}
  keys="$(podman exec "$ctr" rpmkeys --list | grep -v ' Fedora (' | cut -d' ' -f1)"
  [[ $keys == "$fingerprint" ]] || { echo "      rpm trusts:"; indent <<<"$keys"; return 1; }
  sig="$(podman exec "$ctr" rpm -q --qf '[%{OPENPGP:pgpsig}\n]' claude-code)"
  grep -qi "Key ID ${fingerprint: -16}\$" <<<"$sig" || { indent <<<"$sig"; return 1; }
}
check "Claude Code: signed with the pinned key, the only extra key rpm trusts" claude_signed
check "Claude Code: runs, owned by the package, sandbox tools present" in_image <<'EOF'
claude --version | sed 's/^/      /'
[[ "$(rpm -qf --qf '%{NAME}' /usr/bin/claude)" == claude-code ]]
# Its optional sandbox needs both. They come with Kinoite. (type -P fails if
# either is missing; command -v only if both are.)
type -P bwrap socat >/dev/null
EOF
# Claude Code reads managed settings from /etc/claude-code only:
# managed-settings.json and a managed-settings.d/ drop-in directory. The image
# ships our file there and nothing else. The file itself stays image-owned in
# /usr. Its proxy settings must be exactly the ones in proxy.env.
check "Claude Code: managed settings turn off updates and set dev's proxy" in_image <<'EOF'
settings=/usr/lib/android-dev-vm/claude-code/managed-settings.json
proxy_env=/usr/lib/android-dev-vm/proxy.env
[[ "$(ls -A /etc/claude-code)" == managed-settings.json ]]
[[ "$(readlink -f /etc/claude-code/managed-settings.json)" == "$settings" ]]
[[ "$(jq -r .env.DISABLE_UPDATES "$settings")" == 1 ]]
names="$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$proxy_env" | sort)"
in_settings="$(jq -r '.env | keys[] | select(startswith("DISABLE_") | not)' "$settings" | sort)"
[[ $in_settings == "$names" ]] ||
  { echo "      variables differ from proxy.env:"; diff <(echo "$names") <(echo "$in_settings") | sed 's/^/        /'; exit 1; }
bad=0
. "$proxy_env"
for name in $names; do
  [[ "$(jq -r --arg name "$name" '.env[$name]' "$settings")" == "${!name}" ]] ||
    { echo "      $name differs from proxy.env"; bad=1; }
done
exit "$bad"
EOF

# disk/build-qcow2.sh passes no --filesystem: Kinoite names no default, so the
# image's install config has to.
check "bootc installs to a btrfs root" in_image <<'EOF'
type="$(bootc install print-configuration | jq -r '."root-fs-type"')"
[[ $type == btrfs ]] || { echo "      root-fs-type: $type"; exit 1; }
EOF

finish "image checks"
