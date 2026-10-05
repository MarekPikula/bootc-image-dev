#!/usr/bin/bash
# Boots a qcow2 of the image headless with qemu/KVM, runs tests/vm/checks.sh
# in it as root over SSH, collects logs and powers it off. The qcow2 itself is
# never modified (the VM writes to a throwaway overlay).
#
# Nothing test-specific is in the image. SMBIOS system credentials make
# systemd-ssh-generator open sshd on TCP 22 and authorize a per-run SSH key.
# They also answer both first-boot prompts: locale, keymap and timezone for
# systemd-firstboot, and throwaway passwords for admin and dev.
#
# Usage: tests/vm/run-vm.sh QCOW2 [LOG_DIR]
# Env: SSH_PORT (default 2222), BOOT_TIMEOUT seconds (default 600).
set -euo pipefail

qcow2="$(readlink -f "${1:?usage: $0 QCOW2 [LOG_DIR]}")"
logs=${2:-$(mktemp -d)}
mkdir -p "$logs"
logs="$(readlink -f "$logs")"
port=${SSH_PORT:-2222}
boot_timeout=${BOOT_TIMEOUT:-600}
cd "$(dirname "$(readlink -f "$0")")/../.."

[[ -w /dev/kvm ]] || { echo "run-vm: /dev/kvm isn't writable" >&2; exit 1; }

# Fedora's and Ubuntu's OVMF paths. Each VARS template sits next to its CODE.
code=
for candidate in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
  [[ -r $candidate && -r ${candidate/CODE/VARS} ]] && { code=$candidate; break; }
done
[[ -n $code ]] || { echo "run-vm: no OVMF (UEFI) firmware found" >&2; exit 1; }

work="$(mktemp -d)"
qemu_pid=
# Under set -e a failed kill (qemu already powered off) would abort the trap
# with status 1 and skip the rm.
trap '[[ -z $qemu_pid ]] || kill "$qemu_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

ssh-keygen -q -t ed25519 -N '' -C run-vm -f "$work/key"
qemu-img create -q -f qcow2 -b "$qcow2" -F qcow2 "$work/disk.qcow2"
cp "${code/CODE/VARS}" "$work/vars.fd"

# -smbios type=11 credential. Base64 keeps commas and spaces out of qemu's
# option parsing.
#
# root's key goes in through tmpfiles.extra, straight to /var/roothome. On
# bootc, ssh.authorized_keys.root writes through the /root symlink before
# tmpfiles creates /var/roothome, so it's lost. ssh.ephemeral-authorized_keys-all
# is refused by SELinux (sshd-session can't read /run/credentials).
cred() {
  printf 'type=11,value=io.systemd.credential.binary:%s=%s' \
    "$1" "$(printf '%s' "$2" | base64 -w0)"
}

# 6 GiB: the VM checks start Android Studio, which takes about 2 GiB.
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4 -m 6144 \
  -drive "if=pflash,format=raw,readonly=on,file=$code" \
  -drive "if=pflash,format=raw,file=$work/vars.fd" \
  -drive "file=$work/disk.qcow2,if=virtio,format=qcow2" \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" \
  -device virtio-net-pci,netdev=net0 \
  -display none -serial "file:$logs/console.log" \
  -smbios "$(cred tmpfiles.extra "d /var/roothome/.ssh 0700 root root -
f~ /var/roothome/.ssh/authorized_keys 0600 root root - $(base64 -w0 "$work/key.pub")")" \
  -smbios "$(cred ssh.listen 22)" \
  -smbios "$(cred firstboot.locale C.UTF-8)" \
  -smbios "$(cred firstboot.keymap us)" \
  -smbios "$(cred firstboot.timezone UTC)" \
  -smbios "$(cred passwd.plaintext-password.admin "$(head -c 18 /dev/urandom | base64)")" \
  -smbios "$(cred passwd.plaintext-password.dev "$(head -c 18 /dev/urandom | base64)")" \
  -daemonize -pidfile "$work/qemu.pid"
qemu_pid="$(cat "$work/qemu.pid")"

# LogLevel stays out of ssh_opts: ssh keeps the first value it's given.
ssh_opts=(-i "$work/key" -p "$port" -o BatchMode=yes -o ConnectTimeout=5
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
guest() {
  ssh "${ssh_opts[@]}" -o LogLevel=ERROR root@127.0.0.1 "$@"
}

echo "run-vm: waiting up to ${boot_timeout}s for SSH"
deadline=$((SECONDS + boot_timeout))
until guest true 2>/dev/null; do
  if ((SECONDS > deadline)); then
    echo "run-vm: no SSH after ${boot_timeout}s, console log: $logs/console.log" >&2
    ssh "${ssh_opts[@]}" -v root@127.0.0.1 true >"$logs/ssh.log" 2>&1 || true
    tail -n 40 "$logs/console.log" >&2 || true
    exit 1
  fi
  sleep 5
done
echo "run-vm: guest is up after ${SECONDS}s"

rc=0
cat tests/lib.sh tests/vm/checks.sh | guest bash -uo pipefail -s || rc=$?

guest journalctl -b --no-pager >"$logs/journal.txt" 2>&1 || true
guest systemctl poweroff 2>/dev/null || true
for _ in {1..60}; do
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 1
done
echo "run-vm: logs in $logs"
exit "$rc"
