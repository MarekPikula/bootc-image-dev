#!/usr/bin/bash
# Drops file capabilities that would let dev get around its network
# containment. Runs last, after everything else is installed. Nothing in this
# VM needs these helpers.
#
# gst-ptp-helper (GStreamer's PTP clock) has cap_net_admin, which is enough to
#   delete the nftables rule, so a bug in the helper would be a way out.
# arping and ksgrd_network_helper (System Monitor's per-process network
#   statistics) have cap_net_raw and use packet sockets (AF_PACKET). Those
#   bypass the rule's inet output hook: arping, as designed, sends frames of
#   dev's choosing onto the VM's network.
set -euo pipefail

setcap -r /usr/libexec/gstreamer-1.0/gst-ptp-helper
setcap -r /usr/bin/arping
setcap -r /usr/libexec/ksysguard/ksgrd_network_helper
