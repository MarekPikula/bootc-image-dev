#!/usr/bin/bash
# Packages added to and removed from Kinoite. Its own RUN ahead of
# system_files/, see the Containerfile.
#   squid: dev's only way out (see system_files/usr/lib/android-dev-vm/squid/).
#   java-25-openjdk-devel: command-line Gradle. Android Studio brings its own
#     runtime (also 25). Fedora 44 has no older JDK.
#   git
# Removed, unused in a QEMU VM:
#   vpnc with its NetworkManager and Plasma plugins.
#   usermode: the setuid userhelper, for console apps that ask for root's
#     password (root is locked). Nothing depends on it.
#   open-vm-tools-desktop: VMware guest tools, with the setuid
#     vmware-user-suid-wrapper.
set -euo pipefail

# rpm -e, not dnf remove: it removes exactly these and fails if anything else
# needs them, where dnf would quietly remove that too.
rpm -e vpnc NetworkManager-vpnc plasma-nm-vpnc usermode open-vm-tools-desktop
dnf -y install --setopt=install_weak_deps=False squid java-25-openjdk-devel git

# /var is state, created at boot by tmpfiles.d (CLAUDE.md). squid's own
# tmpfiles.d creates /var/spool/squid. httpd-filesystem (a squid dependency)
# ships an unused, empty /var/www.
rm -rf /var/spool/squid /var/www
# squid's scriptlet adds it to wbpriv, for winbind (NTLM) authentication
# helpers. They're unused here, and the group has no sysusers.d entry.
groupdel wbpriv
