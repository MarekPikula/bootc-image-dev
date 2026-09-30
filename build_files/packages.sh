#!/usr/bin/bash
# Packages added to Kinoite. Its own RUN ahead of system_files/, see the
# Containerfile.
#   squid: dev's only way out (see system_files/usr/lib/android-dev-vm/squid/).
set -euo pipefail

dnf -y install --setopt=install_weak_deps=False squid

# /var is state, created at boot by tmpfiles.d (CLAUDE.md). squid's own
# tmpfiles.d creates /var/spool/squid. httpd-filesystem (a squid dependency)
# ships an unused, empty /var/www.
rm -rf /var/spool/squid /var/www
# squid's scriptlet adds it to wbpriv, for winbind (NTLM) authentication
# helpers. They're unused here, and the group has no sysusers.d entry.
groupdel wbpriv
