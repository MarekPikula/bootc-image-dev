# shellcheck shell=sh
# Proxy settings for dev's login shells (tty, SSH). Sessions started from
# Plasma get them from the systemd --user generator (60-dev-proxy) instead.
if [ "$(id -u)" = 1500 ]; then
  set -a
  # shellcheck source=system_files/usr/lib/android-dev-vm/proxy.env
  . /usr/lib/android-dev-vm/proxy.env
  set +a
fi
