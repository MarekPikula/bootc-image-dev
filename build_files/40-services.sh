#!/usr/bin/bash
# Enables our units and masks the ones that conflict with the VM's design.
set -euo pipefail

# Image-owned enablement: symlinks in /usr, which neither `systemctl disable`
# nor a preset reset can remove. See android-dev-firstboot.service's header.
wants() {
  mkdir -p "/usr/lib/systemd/system/$1.wants"
  ln -s "../$2" "/usr/lib/systemd/system/$1.wants/$2"
}
wants multi-user.target android-dev-firstboot.service
wants sysinit.target dev-egress-firewall.service
wants multi-user.target squid.service
# Kinoite ships the update timer but doesn't enable it. Its service only stages
# updates here (see its drop-in).
wants timers.target bootc-fetch-apply-updates.timer

# plasma-setup: KDE's first-boot wizard, which creates its own admin user.
#   android-dev-firstboot.service replaces it.
# cups, geoclue: root daemons that reach the network on behalf of desktop
#   users, outside dev's nftables rule. Not needed in this VM.
# mcelog: machine checks belong to the host. On AMD hosts it fails at boot
#   ("CPU is unsupported"), leaving the system degraded.
# boot.automount: systemd-gpt-auto-generator's ESP automount, which ends up in
#   front of ostree's /boot. It can be gone when ostree-finalize-staged runs
#   at shutdown, which drops the staged update. bootupd mounts the ESP
#   itself. See PLAN.md, Updates.
# nftables.service: Fedora's static firewall. Disabled, but its reload and
#   stop run `nft flush ruleset`, which would delete dev's rule while dev's
#   sessions keep running. firewalld only touches its own table.
# systemd-nsresourced, systemd-mountfsd: hand out transient UID ranges and
#   mounts to unprivileged users. Processes under such a UID aren't matched by
#   dev's rule, so only 00-android-dev.rules' NO stands in the way. Nothing in
#   this VM uses them.
# polkit-agent-helper.socket: lets anyone run polkit's password helper as root
#   through a socket, around 16-polkit-helper.sh's wheel-only mode. Disabled
#   already, masked so it stays off.
systemctl mask \
  plasma-setup.service \
  cups.service cups.socket cups.path cups-browsed.service \
  geoclue.service \
  mcelog.service \
  boot.automount \
  nftables.service \
  systemd-nsresourced.service systemd-nsresourced.socket \
  systemd-mountfsd.service systemd-mountfsd.socket \
  polkit-agent-helper.socket

# avahi: spice-webdavd requires it, and udev starts spice-webdavd when Boxes
# shares a folder. Disabled otherwise (Fedora's preset enables it), which also
# removes the alias D-Bus activation goes through. Its config (see its
# drop-in) keeps it off the network either way.
systemctl disable avahi-daemon.service avahi-daemon.socket
