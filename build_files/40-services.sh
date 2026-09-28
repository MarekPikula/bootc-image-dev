#!/usr/bin/bash
# Enables our units and masks the ones that conflict with the VM's design.
set -euo pipefail

# Image-owned enablement (no [Install] in the unit), see the unit's header.
ln -s ../android-dev-firstboot.service \
  /usr/lib/systemd/system/multi-user.target.wants/android-dev-firstboot.service

# plasma-setup: KDE's first-boot wizard, which creates its own admin user.
#   android-dev-firstboot.service replaces it.
# avahi, cups, geoclue: root daemons that reach the network on behalf of
#   desktop users, outside dev's nftables rule. Not needed in this VM.
systemctl mask \
  plasma-setup.service \
  avahi-daemon.service avahi-daemon.socket \
  cups.service cups.socket cups.path cups-browsed.service \
  geoclue.service
