#!/usr/bin/bash
# Packages added to Kinoite. Its own RUN ahead of system_files/, see the
# Containerfile.
#   squid: dev's only way out (see system_files/usr/lib/android-dev-vm/squid/).
set -euo pipefail

dnf -y install --setopt=install_weak_deps=False squid

# httpd-filesystem (a squid dependency) ships an empty /var/www, which bootc
# container lint flags.
rm -rf /var/www
# squid's scriptlet adds it to wbpriv, for winbind (NTLM) authentication
# helpers. They're unused here, and the group has no sysusers.d entry.
groupdel wbpriv
