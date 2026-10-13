#!/usr/bin/bash
# Packages added to and removed from Kinoite. Its own RUN ahead of
# system_files/, see the Containerfile.
#   squid: dev's only way out (see system_files/usr/lib/android-dev-vm/squid/).
#   java-25-openjdk-devel: command-line Gradle. Android Studio brings its own
#     runtime (also 25). Fedora 44 has no older JDK.
#   git
#   claude-code: from Anthropic's dnf repo, see below.
# Already in Kinoite, and asserted by tests/image/checks.sh: bubblewrap and
# socat, which Claude Code's optional sandbox needs.
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

# Claude Code, from the repo in versions.env. Its signing key is
# claude-code.asc next to this script, so a new key comes through a PR. dnf
# imports every key in that file into rpm's keyring (where it stays), so it
# must hold the pinned key and nothing else: no second key, no subkey.
key=/ctx/claude-code.asc
fingerprints="$(gpg --homedir "$(mktemp -d -p /run)" --show-keys --with-colons "$key" |
  awk -F: '$1 == "fpr" { print $10 }')"
[[ $fingerprints == "${CLAUDE_CODE_KEY_FINGERPRINT:?}" ]] ||
  { echo "claude-code.asc: unexpected key(s): $fingerprints" >&2; exit 1; }
packages() { rpm -qa --qf '%{NAME}\n' | sort -u; }
before="$(packages)"
# --repo: this transaction sees only Anthropic's repo. repo_gpgcheck: the
# repo's metadata is signed too.
dnf -y install --repofrompath="claude-code,${CLAUDE_CODE_REPO:?}" --repo=claude-code \
  --setopt=claude-code.gpgcheck=1 --setopt=claude-code.repo_gpgcheck=1 \
  --setopt="claude-code.gpgkey=file://$key" claude-code
# claude-code needs only glibc. An Obsoletes: in it could still remove or
# replace other packages, so the transaction must have added claude-code and
# changed nothing else.
changed="$(diff <(echo "$before") <(packages) | grep '^[<>]' || true)"
[[ $changed == "> claude-code" ]] ||
  { printf 'claude-code changed other packages:\n%s\n' "$changed" >&2; exit 1; }
